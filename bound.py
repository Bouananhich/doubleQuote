"""
Reference implementation for UniswapBuyCallback.buyerAssetsBound.

Question the bound answers:
    "What is the largest amount of loan token I can source from my LP position
     right now, such that the cost of unwinding stays within a slippage budget?"

Structure mirrors what the Solidity must do inside a `view`:
    - read pool state          (StateLibrary / slot0 + tick bitmap)
    - burn dL of the position  (SqrtPriceMath)
    - walk ticks for the swap  (TickBitmap + SwapMath.computeSwapStep)
    - binary search on dL      (monotone; free because it is a view)

Floats here for legibility; Solidity uses X96 fixed point.
"""

from bisect import bisect_left, bisect_right
from dataclasses import dataclass, field

Q = 1.0001


def tick_to_sqrt_price(tick: int) -> float:
    return Q ** (tick / 2)


def sqrt_price_to_tick(sp: float) -> int:
    import math
    return int(math.floor(math.log(sp * sp) / math.log(Q)))


# --------------------------------------------------------------------------
# Pool model
# --------------------------------------------------------------------------

@dataclass
class Pool:
    """Minimal v3/v4 concentrated-liquidity pool."""
    sqrt_price: float
    tick: int
    liquidity: float                      # active liquidity at current tick
    fee: float                            # e.g. 0.0005 for 5bps
    tick_net: dict = field(default_factory=dict)   # tick -> liquidityNet

    def initialized_ticks(self):
        return sorted(self.tick_net.keys())

    def clone(self):
        return Pool(self.sqrt_price, self.tick, self.liquidity,
                    self.fee, dict(self.tick_net))

    def remove_liquidity(self, dL: float, lower: int, upper: int):
        """Burn dL over [lower, upper]. Does NOT move the price - it thins the book."""
        self.tick_net[lower] = self.tick_net.get(lower, 0.0) - dL
        self.tick_net[upper] = self.tick_net.get(upper, 0.0) + dL
        if lower <= self.tick < upper:
            self.liquidity -= dL


def burn_amounts(dL: float, sqrt_p: float, lower: int, upper: int):
    """Token amounts returned by burning dL. Standard v3 formulas."""
    sa, sb = tick_to_sqrt_price(lower), tick_to_sqrt_price(upper)
    if sqrt_p <= sa:
        return dL * (1 / sa - 1 / sb), 0.0
    if sqrt_p >= sb:
        return 0.0, dL * (sb - sa)
    return dL * (1 / sqrt_p - 1 / sb), dL * (sqrt_p - sa)


# --------------------------------------------------------------------------
# Swap simulation - the part V4Quoter cannot do from a view
# --------------------------------------------------------------------------

def swap_exact_in(pool: Pool, zero_for_one: bool, amount_in: float) -> float:
    """
    Exact-input swap, walking initialized ticks.
    Mirrors SwapMath.computeSwapStep in a loop.
    """
    remaining = amount_in
    out = 0.0
    sp = pool.sqrt_price
    liq = pool.liquidity
    ticks = pool.initialized_ticks()
    cur_tick = pool.tick

    guard = 0
    while remaining > 1e-18 and liq > 0 and guard < 10_000:
        guard += 1

        # next initialized tick in the direction of travel
        if zero_for_one:
            i = bisect_left(ticks, cur_tick)
            nxt = ticks[i - 1] if i > 0 else None
            sp_target = tick_to_sqrt_price(nxt) if nxt is not None else 1e-18
        else:
            i = bisect_right(ticks, cur_tick)
            nxt = ticks[i] if i < len(ticks) else None
            sp_target = tick_to_sqrt_price(nxt) if nxt is not None else 1e18

        amt_in_less_fee = remaining * (1 - pool.fee)

        if zero_for_one:
            # token0 in, price falls
            sp_next = 1 / (1 / sp + amt_in_less_fee / liq)
            if sp_next < sp_target:                       # crosses the tick
                sp_next = sp_target
                used = liq * (1 / sp_next - 1 / sp)
                out += liq * (sp - sp_next)
                remaining -= used / (1 - pool.fee)
                liq -= pool.tick_net.get(nxt, 0.0)        # crossing downward
                cur_tick = nxt - 1
                sp = sp_next
                continue
            out += liq * (sp - sp_next)
            sp = sp_next
            remaining = 0.0
        else:
            # token1 in, price rises
            sp_next = sp + amt_in_less_fee / liq
            if sp_next > sp_target:
                sp_next = sp_target
                used = liq * (sp_next - sp)
                out += liq * (1 / sp - 1 / sp_next)
                remaining -= used / (1 - pool.fee)
                liq += pool.tick_net.get(nxt, 0.0)        # crossing upward
                cur_tick = nxt
                sp = sp_next
                continue
            out += liq * (1 / sp - 1 / sp_next)
            sp = sp_next
            remaining = 0.0

    return out


# --------------------------------------------------------------------------
# The bound
# --------------------------------------------------------------------------

def source(pool: Pool, dL: float, lower: int, upper: int, loan_is_token0: bool):
    """
    Unwind dL and convert the residual. Returns (sourced, slippage_cost).

    Both denominated in loan token. Cost is measured against the pre-trade
    spot price, so it captures impact plus the swap fee paid to the pool.
    """
    a0, a1 = burn_amounts(dL, pool.sqrt_price, lower, upper)

    # price of token1 in units of token0 is 1/sqrtP^2
    spot_1_in_0 = 1 / (pool.sqrt_price ** 2)

    p = pool.clone()
    p.remove_liquidity(dL, lower, upper)     # thins the book we are about to trade into

    if loan_is_token0:
        direct, residual = a0, a1
        got = swap_exact_in(p, zero_for_one=False, amount_in=residual) if residual > 0 else 0.0
        spot_value = residual * spot_1_in_0
    else:
        direct, residual = a1, a0
        got = swap_exact_in(p, zero_for_one=True, amount_in=residual) if residual > 0 else 0.0
        spot_value = residual / spot_1_in_0

    return direct + got, spot_value - got


def buyer_assets_bound(pool: Pool, position_liquidity: float, lower: int, upper: int,
                       loan_is_token0: bool, budget_bps: float,
                       buffer: float = 0.0, iters: int = 60, max_share: float = 0.5):
    """
    Largest sourceable amount whose unwind cost stays within budget_bps.

    Monotone in dL, so bisect. This is a view: ~60 iterations of a tick walk
    costs nothing over eth_call.
    """
    budget = budget_bps / 10_000

    # HARD CAP, independent of the slippage budget.
    #
    # Your own position is part of the book you are about to swap into. Burn too
    # much of it and you trade into a hole you just created: `sourced` stops being
    # monotone in dL, and the bisection below is then invalid - it can converge on
    # a point that is neither maximal nor safe. Cap dL at a fraction of active
    # liquidity so the search stays inside the monotone region.
    if lower <= pool.tick < upper:
        position_liquidity = min(position_liquidity, max_share * pool.liquidity)

    def within(dL):
        sourced, cost = source(pool, dL, lower, upper, loan_is_token0)
        return sourced > 0 and (cost / sourced) <= budget

    if within(position_liquidity):
        return buffer + source(pool, position_liquidity, lower, upper, loan_is_token0)[0]

    lo, hi = 0.0, position_liquidity
    for _ in range(iters):
        mid = (lo + hi) / 2
        if within(mid):
            lo = mid
        else:
            hi = mid
    return buffer + source(pool, lo, lower, upper, loan_is_token0)[0]


# --------------------------------------------------------------------------
# Scenario: cbBTC/USDC on Base. USDC (0x8335..) < cbBTC (0xcbb7..) so USDC is token0.
# --------------------------------------------------------------------------

def make_pool(price_usdc_per_cbbtc=60_000.0, depth=2e12, fee=0.0005,
              spacing=10, band=20_000):
    """
    raw price = token1/token0 = cbBTC_raw per USDC_raw, decimals 8 and 6.

    `depth` is active liquidity, calibrated so a ~$100k swap moves price ~40bps,
    which is roughly the observed behaviour of the $7.1M Base 0.05% pool.
    """
    raw = (10 ** 8) / (price_usdc_per_cbbtc * 10 ** 6)
    sp = raw ** 0.5
    t = sqrt_price_to_tick(sp)
    t -= t % spacing

    # Real books are layered: a concentrated core around spot plus a wide tail.
    # A single flat band makes tight positions look artificially dominant.
    net = {}
    for frac, half in [(0.55, 600), (0.30, 3_000), (0.15, band)]:
        lo, hi = t - half, t + half
        net[lo] = net.get(lo, 0.0) + depth * frac
        net[hi] = net.get(hi, 0.0) - depth * frac

    return Pool(sqrt_price=sp, tick=t, liquidity=depth, fee=fee, tick_net=net)


def position(pool: Pool, usdc_notional: float, half_width_ticks: int, spacing=10):
    """Position centred on spot, sized to `usdc_notional` of total value."""
    lower = pool.tick - half_width_ticks
    upper = pool.tick + half_width_ticks
    lower -= lower % spacing
    upper -= upper % spacing
    a0, a1 = burn_amounts(1.0, pool.sqrt_price, lower, upper)   # per unit of L
    spot_1_in_0 = 1 / (pool.sqrt_price ** 2)
    value_per_L = a0 + a1 * spot_1_in_0                          # in USDC raw
    L = (usdc_notional * 10 ** 6) / value_per_L if value_per_L > 0 else 0.0
    return L, lower, upper


if __name__ == "__main__":
    NOTIONAL = 250_000          # $250k of USDC-equivalent parked
    BUDGET = 10                 # 10 bps slippage budget

    print("cbBTC/USDC 0.05% - bound vs range width")
    print(f"{'half-width':>11} {'position L':>14} {'bound (USDC)':>14} "
          f"{'% of full':>10} {'cost@full':>11}")
    print("-" * 66)

    for hw in [50, 100, 200, 400, 800, 1600, 3200]:
        pool = make_pool()
        L, lo, up = position(pool, NOTIONAL, hw)
        full, cost_full = source(pool, L, lo, up, loan_is_token0=True)
        bound = buyer_assets_bound(pool, L, lo, up, True, BUDGET)
        pct = 100 * bound / full if full else 0
        bps = 10_000 * cost_full / full if full else 0
        print(f"{hw:>11} {L:>14,.0f} {bound/1e6:>14,.0f} {pct:>9.1f}% {bps:>10.1f}b")

    print()
    print("Monotonicity check (half-width 400):")
    pool = make_pool()
    L, lo, up = position(pool, NOTIONAL, 400)
    prev = -1
    ok = True
    for f in [i / 20 for i in range(1, 21)]:
        s, c = source(pool, L * f, lo, up, True)
        r = c / s if s else 0
        if r < prev - 1e-12:
            ok = False
        prev = r
        if int(f * 20) % 4 == 0:
            print(f"  dL={f:>4.2f}L  sourced={s/1e6:>12,.0f}  cost={10_000*r:>6.2f} bps")
    print(f"  cost ratio monotone increasing: {ok}")