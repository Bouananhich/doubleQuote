# Developer feedback — Uniswap

Feedback from building **doubleQuote**, a Midnight buy-callback that parks a lender's capital in a
Uniswap LP position and unwinds it just-in-time to settle a fixed-rate loan.

> **Status: draft.** Entries below are the friction points anticipated from source reading before
> the build started. Each one is either confirmed with a file/line reference and a time cost from
> `FRICTION.log`, or removed, when this is edited on D12. Nothing here should ship unverified.

The integration is unusual in a way that makes it a useful probe: it needs to price a swap from
inside a `view` function, with no ability to receive routing hints at execution time. That pushes
on parts of the surface that a normal router or frontend integration never touches.

---

## 1. `V4Quoter` cannot be called from a `view`

*Status: to verify.*

`V4Quoter` simulates via `_unlockCallback` and reverts with the result — a state-mutating path. Any
protocol exposing a **view-based quote** therefore cannot use it, and must reimplement the swap
loop against initialized ticks (~60–100 lines using `TickMath`, `SwapMath.computeSwapStep` and
`TickBitmap`).

This is the single biggest cost in this project. In our case the reimplementation became the
interesting part, so it worked out — but that was luck, not design. A `view`-callable quoting
primitive would remove the need entirely.

## 2. v4 makes the price oracle a pool you must bootstrap and lock capital into

*Status: to verify.*

v3 gave every pool an oracle for free via `observe()`. In v4 the oracle moved out to a hook, which
means a v4 pool without one has no in-protocol price history — and a hook-based oracle only records
prices for **the pool it is attached to**. Getting a v4-native reference price for pair X therefore
means deploying a hook, creating a pool for X carrying it, seeding it, and attracting enough
genuine volume that arbitrage keeps it honest. `GeomeanOracle.sol` states such pools must use
full-range tick spacing with liquidity **permanently locked**.

An empty oracle pool is worse than no oracle. For any integration that needs a reference price and
isn't itself a major venue, this is a hard blocker, and the practical answer is "keep reading v3".

## 3. A hooked pool can be excellent to park in and unusable to route through, and a contract cannot ask which

*Status: confirmed, and partly already solved off-chain.*

A hook may leave `modifyLiquidity` completely ungated while gating `swap` behind a signed
off-chain quote a contract cannot produce atomically — so the pool is a perfectly good place to
**hold** a position and an impossible place to **execute** against. Concretely, KyberSwap's
FairFlow hook on Base (`0x4440854B…D875c0c4`) has low-14 address bits `0x00C4`: `beforeSwap`,
`afterSwap`, `afterSwapReturnsDelta` and nothing else. Liquidity operations are untouched; every
swap needs a `quoteSigner` signature in `hookData`.

**Credit where due: `Uniswap/hooklist` already records this**, and it was the fastest way to
answer the question. Its schema carries all 14 permission bits plus `swapAccess`
(`none`/`temporal`/`allowlist`/`governance`/`other`), `requiresCustomSwapData`, `vanillaSwap`,
`dynamicFee` and `upgradeable`. That is close to exactly the right vocabulary.

The gap that remains is that this is **off-chain, opt-in, and not the routing allowlist** (the
registry README explicitly says inclusion does not imply routing allowlisting, which is a separate
form). An integrating *contract* still cannot ask "can I route through this pool" at execution
time, and must instead hard-code an answer its deployer looked up by hand.

The asymmetry is common enough to be worth first-class support. Of the **161 Base hooks** in the
registry:

| | count |
|---|---|
| park-friendly but route-hostile (`beforeRemoveLiquidity` unset, swap gated) | **45 (28%)** |
| route-friendly but park-hostile | 10 |
| gate `beforeRemoveLiquidity` at all | 26 |
| require custom swap data | 29 |

Suggestion: expose the `swapAccess` / `requiresCustomSwapData` distinction on-chain — a view on the
hook, or a standard interface hooks can implement — so integrators can check it atomically rather
than trusting a snapshot taken at deployment time.

## 4. Pragma pinning forces multi-profile builds

*Status: to verify.*

| Repo | Implementations | Interfaces |
|---|---|---|
| v3-core / v3-periphery | `=0.7.6` hard pin | `>=0.5.0` / `>=0.7.5` |
| v4-core | `^0.8.24`, except `PoolManager.sol` at `0.8.26` | `^0.8.0` |
| v4-periphery | `^0.8.0`, except `PositionManager.sol` / `V4Router.sol` at `0.8.26` | `^0.8.0` |

`PoolManager.sol` and `PositionManager.sol` are pinned to exactly `0.8.26` while everything around
them is caret. An integrator on a newer solc — ours is on `0.8.34`, following Midnight — cannot
compile them in the same profile.

Mitigation worth documenting somewhere official: **fork-test against a chain where everything is
already deployed and bind through interfaces only.** The interfaces are caret or open-ended and
compile fine; the pin only bites if you're deploying fresh instances locally.

A related sharp edge: v3 *interfaces* are open-ended, but v3 *libraries* often are not.
`OracleLibrary.consult()` is `>=0.5.0 <0.8.0` — an **upper** bound, so it will not compile under
0.8. Same for `PositionValue.principal()` and `LiquidityAmounts`. Each needs ~15 lines of
reimplementation. Taking the equivalent math from **v4-core** instead (`TickMath`,
`SqrtPriceMath`, `SwapMath`, `FullMath`, `TickBitmap`, `StateLibrary`) sidesteps this — the
formulas are identical and those versions are 0.8-native — but that's folklore, not documentation.

## 5. The official truncated-oracle sample no longer compiles, and is `UNLICENSED`

*Status: to verify.*

On `Uniswap/v4-periphery` branch `trunc-oracle`: `TruncGeoOracle.sol` imports
`@uniswap/core-next`, uses a nested `IPoolManager.PoolKey` struct that no longer exists, and is
pinned to `=0.8.19`. The library underneath it, `TruncatedOracle.sol`, is genuinely good — 353
lines, zero imports, `^0.8.19` caret, no v4 types, pure ring-buffer math — but both files carry
`SPDX-License-Identifier: UNLICENSED` while the repository LICENSE is GPL-2.0.

That combination is a real problem for an open-source submission: the useful part is unusable as
written and unclear to vendor. Either the headers are an oversight worth fixing, or the sample
should be marked as unmaintained.

## 6. No library for "largest input I can source within a slippage budget"

*Status: to verify.*

Every piece exists — tick math, swap step, bitmap traversal — but the composition doesn't. The
question "how much can I trade here before it costs me more than N bps?" is a natural one for any
integrator sizing an action against a pool, and everyone asking it writes the bisection themselves.

---

## What worked well

*To fill on D12 from `FRICTION.log`. Placeholder so the file isn't only complaints — the v4
singleton/flash-accounting model genuinely collapses a three-step v3 unwind into one netted
settlement, and that should be said with the gas numbers attached.*
