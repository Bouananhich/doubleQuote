# doubleQuote

A Midnight maker buy-callback that parks a lender's capital in a **Uniswap LP position** instead of
a Morpho Blue market, unwinding it just-in-time when a fixed-rate offer is taken. The same USDC
quotes in two order books at once; whichever fires first atomically unwinds the other.

Hackathon project (ETHGlobal, Uniswap track), 4–18 Sep 2026. Solidity / Foundry.

## Docs

| File | What's in it |
|---|---|
| `PLAN.md` | Day-by-day D1–D14 schedule, prep backlog, submission checklist, ranked risks |
| `JOURNAL.md` | Strategic + architectural decisions and the reasoning behind them. **Append here when a design decision gets made or reversed** |
| `FRICTION.log` | Timestamped log of anything that costs time while building against Uniswap. **Append in the moment** — it's the source material for `FEEDBACK.md` |
| `FEEDBACK.md` | Uniswap developer feedback, a required submission artifact. Edited down from `FRICTION.log` on D12 |

Read `JOURNAL.md` before proposing architecture changes — most of the obvious alternatives have
already been considered and rejected there for stated reasons.

## Vocabulary

- **Midnight** — Morpho's fixed-rate lending protocol. A **maker** signs an **offer** that doesn't
  lock capital; it references a **callback** contract the protocol calls at settlement to source
  the loan tokens. A **taker** fills the offer.
- **`onBuy`** — the settlement half of the callback. Runs on the taker's gas. Must return
  `CALLBACK_SUCCESS` or the whole take reverts.
- **`buyerAssetsBound`** — the *quoting* half. `external view`, called off-chain via `eth_call`,
  effectively gas-free. Returns the largest fill this maker can source. **This is the project.**
- **Bound** — the output of `buyerAssetsBound`: largest amount sourceable within a slippage budget.
- **Park / route / reference** — three independently chosen venues. Where the position sits, where
  the residual swap executes, where the price is read.
- **Buffer** — idle loan tokens held by the callback to serve small fills without touching the LP.
- **Residual** — the non-loan-token side returned by burning liquidity, which must be swapped.

## Invariants — do not break these without a `JOURNAL.md` entry

1. **Model in the view, execute in the callback.** Expensive math belongs in `buyerAssetsBound`;
   `onBuy` stays cheap.
2. **Every execution-time decision derives from on-chain state.** `callbackData` is maker-signed at
   offer creation and static — the callback can never be handed a fresh route, `minOut`, or price.
3. **`IPriceRef`, the slippage budget, the route venue, `OWNER` and `MIDNIGHT` are immutables.**
   They must not be reachable through `callbackData`. That column is the safety envelope.
4. **Never read the price reference from a hook on the parked pool.** A hook owner can backdoor the
   feed and profits from breaking it.
5. **Parking is permissionless; routing and referencing are not.** Restricting which pools a maker
   may park in destroys the thesis.
6. **`dL` is capped at a fraction of active liquidity (0.5)** independently of the slippage budget —
   above that, `sourced(dL)` is non-monotone and bisection is invalid.

## Build

```shell
forge build
forge test
```

Targeting solc **0.8.34** / **osaka** evm, following Midnight. Tests are **fork-first against
Base**, binding already-deployed Midnight, v3 and v4 contracts **through interfaces only** — that
keeps it to one compiler profile despite `PoolManager.sol` and `PositionManager.sol` being pinned
to exactly `0.8.26`. Prefer math libraries from **v4-core** even in the v3 adapter; they're
0.8-native and the formulas are identical.

## Layout

```
src/
  interfaces/   IMidnightBuyCallback, IPriceRef
  libraries/    SourcingMathLib — venue-agnostic bound math
  price-refs/   V3TwapRef (production), TruncatedOracleRef (demo), MedianRef (stretch)
test/
script/
```

Planned contracts: `UniswapBuyCallbackBase` (abstract) + `UniswapV3BuyCallback` /
`UniswapV4BuyCallback` + a CREATE2 factory. Forked from `src/periphery/blue-buy-callback/` in
`morpho-org/midnight` — that path is GPL-2.0-or-later, so forking it is fine; Midnight *core* is
BUSL-1.1 and must not be vendored.

## Build order

**v3 first, v4 second, both shipped.** v3 is load-bearing because its native `observe()` makes the
price-reference work straightforward. If a day goes missing, v4 is cut, never v3.
