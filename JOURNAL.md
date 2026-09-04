# Journal

Strategic and architectural decisions, with the reasoning that produced them. Append at the
bottom; don't rewrite history — if a decision is reversed, add a new entry saying so and why.

---

## 2026-08-31 — The thesis

The same USDC quotes in two order books at once: passively market-making in a Uniswap pool while
resting as a fixed-rate offer on Midnight, with whichever fires first atomically unwinding the
other.

Midnight offers don't lock capital. The maker signs an offer referencing a callback contract, and
the protocol calls that contract at settlement to source the loan tokens. Morpho ships a reference
implementation parking funds in Morpho Blue; nothing in the protocol restricts the target. Midnight
calls the contract, then checks the tokens arrived.

## 2026-08-31 — `buyerAssetsBound` is the project, not the parking

Initially the interesting part looked like the settlement path. It isn't. The callback interface
has a **quoting** surface as well as a settlement surface, and Blue leaves it completely
unexploited — its implementation is `min(supplyAssets, marketLiquidity, blueBalance)`.

A maker parked in a vault has a boring answer to "how much can you fill?" — their balance. A maker
parked in an LP position has an interesting one, because marginal sourcing cost rises with size.
So: **quote-size-aware market making inside a lending callback.** Instead of defending against bad
execution with a revert, publish the largest size sourceable within a slippage budget. Sandwiching
stops being a patch and becomes the product.

The asymmetry that makes it work: `buyerAssetsBound` is a `view`, called off-chain via `eth_call`,
effectively gas-free, so it can afford real math. `onBuy` is on the taker's gas budget and must
stay cheap. **Model in the view, execute in the callback.**

This is the same observation as the thesis, not a second one: the bound is only non-trivial
*because* the capital is doing double duty.

## 2026-08-31 — Every execution-time decision must derive from on-chain state

Callback data is maker-signed and static. For a maker buy offer, `buyerCallbackData` is
`offer.callbackData`; the taker's `takerCallbackData` only reaches the *seller* callback. The
callback cannot be handed a fresh route, a `minOut`, or a price at execution time.

This is what forces the slippage bound to be a **formula over on-chain state** rather than a
taker-supplied parameter. It is a constraint, but it's also what makes the bound a contribution
rather than a config field.

## 2026-08-31 — Buffer, because dust takes are extractive

`onBuy` is guarded by `msg.sender == MIDNIGHT` and `buyer == OWNER`, so arbitrary contracts can't
call it. But any taker can fire it with a zero-or-dust take, and the real attack is **repeated dust
takes forcing micro-unwind + micro-swap**, bleeding the maker through fees and slippage each time
at the attacker's chosen price. Extractive, not merely annoying.

A loan-token buffer fixes it — serve small fills from the buffer, touch the LP only on shortfall —
and fixes common-case gas at the same time.

## 2026-08-31 — Two findings that only appeared on running the math

From `bound.py`, the validated reference implementation:

**A. Burning liquidity does not move the price — it thins the book you are about to trade into.**
Removing liquidity leaves `sqrtP` unchanged but reduces active `L`. The residual swap then executes
against a *thinner* pool. Naive algebra misses this and understates the cost. The self-impact is
real and self-inflicted.

**B. A hard cap on `dL` is required, independent of the slippage budget.** Burn too much and
`sourced(dL)` stops being monotone, at which point bisection is invalid — it converges on a point
that is neither maximal nor safe. Cap `dL` at a fraction of active liquidity (0.5 works). Verified:
at half-width 50 ticks the uncapped function is non-monotone and the capped one is monotone, and
the cap does not distort the answer where slippage binds first.

## 2026-08-31 — Architecture: abstract base + two adapters, not a venue interface

```
UniswapBuyCallbackBase (abstract)
  ├─ owner / MIDNIGHT immutables, skim, EIP-712 authorization   [from BlueBuyCallback]
  ├─ loan-token buffer accounting
  ├─ onBuy: buffer-first, then _sourceLoanToken(shortfall)
  ├─ buyerAssetsBound: buffer + _sourceableBound(sigma)
  └─ abstract: _sourceLoanToken(uint256), _sourceableBound(uint256)

UniswapV3BuyCallback  -> decreaseLiquidity + collect + pool.swap()
UniswapV4BuyCallback  -> one PoolManager.unlock(): modifyLiquidity + swap + settle net
SourcingMathLib       -> shared bound math, venue-agnostic
```

A venue interface behind an external call was rejected: it adds a trust boundary and gas for
nothing.

**Why v4 earns the second adapter.** v3 needs three token movements to source a fill:
`decreaseLiquidity` → `collect` → `swap`. v4 does it inside a single `PoolManager.unlock()` — burn,
swap the residual, settle **one netted delta**, intermediate token never moves. Same economic
operation, same protocol, two versions, measurably different cost. That gas table is worth one
adapter; it is not worth a second project.

## 2026-08-31 — Immutables are the safety envelope

| Immutable, set at deployment | Per-offer, in `callbackData` |
|---|---|
| `OWNER`, `MIDNIGHT` | Pool / `PoolKey`, position id |
| `IPriceRef` | Tick range |
| Max slippage budget | Buffer policy |
| Swap-route venue | |

The immutable column must **not** be reachable through `callbackData`, because that data is
maker-signed at offer creation — a maker could be socially engineered into signing an offer with a
null oracle.

Corollary on permissioning: **park anywhere, permissionlessly** — restricting to own-pools destroys
the thesis, since a maker forced to migrate liquidity is no longer an existing LP and you've built
a vault with extra steps. Blue whitelists nothing; it enforces one invariant
(`marketParams.loanToken == market.loanToken`), and the analogue here is that one pool currency
must equal the loan token. A maker pointing an offer at a bad pool harms only themselves — the take
reverts if the tokens fail to arrive. But **route and reference are immutable**: a maker signing an
offer that routes through a manipulable pool *is* the sandwich vector.

## 2026-08-31 — Park / route / reference are three independently chosen venues

Forced by the KyberSwap FairFlow investigation: their hook leaves LP liquidity ungated (so the
unwind works) but the Aggregator is the sole taker for swaps behind a signed off-chain quote the
callback cannot produce atomically (so routing through it doesn't). A pool can be excellent to park
in and unusable to route through.

Generalised into a design rule: burn in one pool, route the residual elsewhere, read the price from
a third place.

## 2026-08-31 — Never read the price reference from the parked pool's own hook

A hook owner can backdoor the feed and profits from breaking it. `IPriceRef` is an owner-configured
immutable, and the sandwich test then runs unchanged against each implementation — which makes the
oracle comparison **a result rather than a choice**.

Ranked: `V3TwapRef` is the production path and must exist (native `observe()`, no deployment, no
licensing question). `TruncatedOracleRef` is a *demonstration* only — a v4 oracle hook records
prices solely for the pool it's attached to, so it needs a bootstrapped, capital-locked oracle pool
with simulated arbitrage volume. `MedianRef` is decoration.

Do not assume truncation wins. A per-block tick cap also lags *legitimate* fast moves, so it
rejects honest fills — the same fill-reliability objection that ruled out a naive slippage bound.
Measure false-revert rate alongside attack cost.

## 2026-08-31 — Ship both pools: stable is the product, volatile is the stress test

**Parking USDC in cbBTC/USDC is unpriced short gamma on BTC** — the maker quotes a fixed USDC rate
while writing a straddle nobody underwrote, and the exposure is adversely correlated with the job.
When BTC falls the position converts into cbBTC, so USDC sourcing capacity shrinks precisely when
takers most want to hit the offer. The bound is smallest exactly when it needs to be largest.

So the product configuration is a **stable pool**: residual is USDT, the top-up swap is ~1:1,
slippage negligible, sandwich uneconomic.

But **range width, not asset volatility, is the real variable.** High fee APRs come from tight
ranges around peg, and a v3 position that exits its range becomes 100% one token — so the risk is
one-sided. Drift one way leaves you entirely in USDC and the bound is the full balance; drift the
other leaves you entirely in USDT and the bound collapses. Sourcing risk re-enters through **range
exit**, and scales with exactly the parameter that generates the yield.

Hence both: stable answers *would anyone use this*, cbBTC/USDC answers *is it safe when the maker
picks a riskier venue*. One attack script across both — the attacker extracts X in the volatile
pool without the bound, and loses money trying in the stable one.

## 2026-09-04 (D1) — Repo initialised

Foundry project, public from day one rather than day thirteen. `FRICTION.log` started today so
`FEEDBACK.md` is an editing job over real material rather than a memory exercise at the deadline.

Prep window (Mon 31 Aug → Thu 3 Sep) went unused — the fork harness spike, the Base opcode check,
the FairFlow hook permission bits, the Midnight reading and the pool selection all carry into D1.
The harness kill-switch matters more as a result: if the single-profile fork-Base setup isn't green
by end of D2, ship v3 only and say so in the README.

## 2026-09-04 (D1) — Harness green, single profile, kill-switch not needed

The fork-first bet paid off. One Foundry profile at solc 0.8.34 / evm osaka, forking Base at block
**50,875,000**, binding everything through hand-written interfaces. 8/8 in 3.7s. No `deployCode`
dance, no second compiler profile, no `MorphoImport.sol` pattern.

Everything below was verified on-chain rather than taken from documentation or memory:

| | Address | How it was confirmed |
|---|---|---|
| Midnight | `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A` | responds to `configurator()` (non-zero), `feeSetter()`, `feeClaimer()`, `tickSpacingSetter()` |
| v3 Factory | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` | `feeAmountTickSpacing(500) == 10`, `(100) == 1` |
| v3 `NonfungiblePositionManager` | `0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1` | `.factory()` returns the above |
| v4 `PoolManager` | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | ~24KB code |
| v4 `PositionManager` | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` | `.poolManager()` returns the above |

**The USDT variant question is resolved: native USDT** (`0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2`),
not USDT0 or USDT.e. The USDC/USDT **0.01%** pool carries L≈3.93e14 against 7.57e12 in the 0.05%
pool — roughly 50× deeper — so the fee tier choice is made on depth, and depth is what the bound
math is sensitive to. Stress venue is cbBTC/USDC 0.05% (`0xfBB6…43ef`, L≈1.89e12, tick −66813).

Both venues have live v3 oracles (`observe()` over a 1800s window returns distinct cumulatives on
each), which is the `V3TwapRef` dependency and confirms v3 as the load-bearing adapter.

Two things worth recording that aren't in the original notes:

**The osaka question has two halves and only one was interesting.** "Does Base support `clz`" is
answered trivially — Midnight is compiled at osaka and live on Base. The half that actually gates
the build is whether the *fork EVM* executes it, so `ClzProbe` in `ForkSanity.t.sol` exercises
`clz` directly in-fork rather than assuming.

**Morpho publishes no machine-readable deployment list**, so the Midnight address was found by
search and then confirmed by calling four Midnight-specific selectors on it. Recorded here because
the address is now hardcoded in `ForkBase.sol` and the provenance should be auditable.

**Open gap:** `bound.py` — described in the design notes as written and validated on 31 Aug — is
not in this repo. D5 and D6 both cross-check the Solidity against its outputs. It needs recovering
or rewriting before then.
