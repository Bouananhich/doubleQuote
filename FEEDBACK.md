# Developer feedback — Uniswap

Feedback from building **doubleQuote**, a Morpho Midnight maker buy-callback that parks a lender's
capital in a **Uniswap LP position** and unwinds it just-in-time to settle a fixed-rate loan. The
same USDC quotes in two order books at once; whichever fires first atomically unwinds the other.

**Why this integration is a useful probe.** It has to price a swap *from inside a `view` function*,
and it can never be handed a routing hint at execution time — the maker signs the offer once, and
everything the callback does at settlement must derive from on-chain state. There is no off-chain
solver in the loop to compute a `minOut`. That combination pushes on parts of the Uniswap surface
that a normal router or frontend integration never touches: the quoting primitives are all
simulate-and-revert, and the guard has to be reconstructed from libraries that assume they are
running inside a pool.

**Provenance.** Every entry below was hit while building, and was logged at the time in
[`FRICTION.log`](./FRICTION.log) with the expectation recorded *before* the outcome. Each one cites
the file and line in this repo where the workaround lives, so the claims are checkable. Where a
finding is a data point rather than a complaint, it says so. Time costs are wall-clock and honest,
including the ones that were my own error.

---

# A. Quoting from a `view` is the gap

This is the theme. Uniswap ships excellent *simulation* primitives and no *view* primitives, and
the two are not interchangeable.

## A1. Every official quoter is simulate-and-revert, so none can be called from a `view`

`V4Quoter` (and `QuoterV2` before it) works by entering `PoolManager.unlock`, performing the swap,
and reverting with the result encoded in the revert data, which the outer call catches. That is a
state-mutating path by construction — taking the lock is a state write — so the functions are not
`view` and cannot be called from one.

Any protocol that exposes a **view-based quote** therefore cannot use the official quoter at all.
`buyerAssetsBound` in this project is `external view` because Midnight's routing layer calls it
off-chain via `eth_call` on every maker in the book; making it non-view would make quoting a
transaction. So the swap loop has to be reimplemented against initialized ticks.

That reimplementation is [`src/libraries/SourcingMathLib.sol`](./src/libraries/SourcingMathLib.sol)
and [`src/libraries/TickBookLib.sol`](./src/libraries/TickBookLib.sol) — 812 lines across two
libraries whose core is a `pure` swap loop and a tick-book walk, existing to answer a question
`V4Quoter` already answers, in a context where `V4Quoter` cannot be reached.

**Suggested fix:** a `view`-callable quoting library — the swap loop as `pure` math over a
caller-supplied tick snapshot, with the pool reads factored out. Most of it already exists as
internal pieces; what is missing is the composition and the `view` entry point.

*This is the single largest cost in the project. In our case the reimplementation turned out to be
the interesting part, so it worked out — but that was luck, not design.*

## A2. `TickBitmap.nextInitializedTickWithinOneWord` takes storage, which is the one form an external caller cannot have

Expected to reuse it for the multi-tick walk. Its first parameter is
`mapping(int16 => uint256) storage self` — the pool's own storage — so it is callable only from
inside a pool.

Every integrator quoting a swap from outside reads the bitmap through `tickBitmap(wordPos)` (v3) or
`StateLibrary.getTickBitmap` (v4), and therefore holds a word **by value**: precisely the form the
library does not accept. So the ~20 lines of mask-and-`BitMath` arithmetic get reimplemented —
[`TickBookLib._nextTick`](./src/libraries/TickBookLib.sol#L94-L120) here.

What makes this worse than an ordinary missing overload: the search a quoter must match
*bit-for-bit* is the piece it is forced to copy by hand, and the two upstream formulations differ
between v3 (`(1 << bitPos) - 1 + (1 << bitPos)`) and v4 (`word << (255 - bitPos)`). "Copy the one
from the repo" is already ambiguous.

**Suggested fix:** one line of work — a `pure` overload taking `uint256 word`, with the existing
storage version calling it.

*(cost: ~20m)*

## A3. `SwapMath.computeSwapStep` returns four values, which does not fit in a swap loop

Expected to call it in a loop the way `Pool.swap` does. Stack too deep at 0.8.34 without `--via-ir`:
six arguments plus a four-value destructuring inside a `for` is over the limit.

v4-core's own `Pool.sol` never hits this because it holds the same state in `SwapResult` /
`StepComputations` structs — which reads as house style until you need the function on its own.
Ended up doing the same thing, [`SourcingMathLib.RouteSwap`](./src/libraries/SourcingMathLib.sol#L220),
after first trying block scoping and dropping a parameter.

**Suggested fix:** the four returns are always consumed together — returning a struct would make the
function composable instead of leaving every integrator to rediscover the workaround. Turning on
`--via-ir` is the other answer, and costs a second compiler profile this project deliberately
stayed free of.

*(cost: ~15m)*

## A4. There is no primitive for "the largest input I can source here within a slippage budget"

Every piece exists — tick math, swap step, bitmap traversal — but not the composition. "How much can
I trade before it costs more than N bps?" is a natural question for anyone sizing an action against
a pool, and everyone asking it writes the bisection themselves.

This project is essentially that function
([`SourcingMathLib.boundBySlippage`](./src/libraries/SourcingMathLib.sol#L480)), with one wrinkle
worth passing upstream: `sourced(dL)` is **non-monotone** above roughly half of active liquidity, so
bisection is only valid under a cap. We enforce `dL ≤ 0.5 × L`
([`MAX_ACTIVE_SHARE_WAD`](./src/libraries/SourcingMathLib.sol#L86)) independently of the budget. A
library shipping this would need the same guard, and that property is not documented anywhere.

## A5. An honest quote is RPC-expensive, not gas-expensive — and that cost lands on everyone fork-testing

Expected the multi-tick walk to be free in a `view`: it runs over `eth_call`, so gas is not the
constraint. It is not free against a **forked** node. Each bound now touches up to 128 bitmap words
plus one `ticks()` per initialized tick — all distinct cold storage slots — where the single-step
version touched `slot0` and `liquidity`.

That put CI over the public Base endpoint's rate limit. The failure surfaces as
`EVM error; database error: failed to get storage` against a pool address, which reads as a contract
bug for a minute; nothing near the top of the message names a rate limit.

The general point: **the honest bound is the one that reads the book, and reading the book is what
makes a quoter RPC-expensive.** An official `view` quoter that walks ticks without simulating would
make this cheap for everyone — see A1.

*(cost: ~10m the first time, ~45m the second, all diagnosis)*

---

# B. Price references

## B1. A mean-tick TWAP is quantised to a basis point, and nothing says so

**The most expensive single finding here, and the most fixable.**

Building a reference-relative slippage guard, every *honest* v4 fill failed a 1bp budget. The cause
was not price impact. The v3 pool the reference reads and the v4 pool the residual sells into are
**both at tick 7**, and are still **0.75bp apart on price**.

A tick is a basis point wide. A mean-tick reference lands on a tick boundary while a venue's spot
sits somewhere inside it. Two venues "at the same tick" therefore agree only to within one tick, and
an integrator comparing a TWAP against an execution price is charging that quantisation as slippage.

The consequence is a **floor on the smallest slippage budget anyone can enforce against an
`observe()`-derived reference** — and a corollary this project had to absorb: *a 1bp maker can only
route on the venue they reference.* `OracleLibrary.consult` returns a tick, `getQuoteAtTick`
converts it, and neither mentions the answer is only tick-accurate. Both read as if they were giving
you a price.

**Suggested fix:** a sentence, not code. Say that a mean tick is accurate to one tick of the oracle
pool, and that budgets below that are not meaningful.

*(cost: ~50m, most of it looking for a bug in my own port that did not exist)*

## B2. The canonical TWAP helper is unreachable from 0.8, and the part everyone reimplements is the rounding

`OracleLibrary.consult` is the reference implementation of an arithmetic-mean tick. It is pinned
`>=0.5.0 <0.8.0` — an **upper** bound — so it cannot be compiled in any 0.8 profile. It gets copied
by hand.

That is fine until the one line that is not arithmetic: Solidity's `/` truncates toward zero, and
the mean tick must round **down**, so a negative cumulative delta that does not divide evenly needs
an explicit decrement —
[`V3TwapRef.meanTick`](./src/price-refs/V3TwapRef.sol#L100).

Omit it and the reference is biased **in one direction only**: a systematic tilt on any pair whose
price sits just below tick zero — which is most stable pairs quoted one way round, and invisible on
the same pair quoted the other. It survives a smoke test.

**Suggested fix:** a `pure` mean-tick helper taking the two cumulatives and the window. ~6 lines,
compiles on any 0.8, removes a silent-bias footgun from every 0.8 integration.

*(cost: ~20m)*

## B3. `observe()` fails as a bare string, at the worst possible moment

A pool whose `observationCardinality` cannot reach back far enough reverts `OLD` — a plain `require`
string, no error type, no mention of what window it *could* have served.

For a price reference that distinction is severe. The oracle is not consulted until settlement, so a
badly configured reference **deploys fine, quotes fine** (`buyerAssetsBound` reverting reads as "no
bound available" to a routing layer), **and then reverts every take, on the taker's gas.**

Restated as a constructor probe and a typed
[`InsufficientObservationHistory(pool, window)`](./src/price-refs/V3TwapRef.sol#L44) so it fails at
the only moment anyone can act on it. Cardinality only ever grows, so the constructor check is sound
rather than merely early.

**Suggested fix:** a typed error carrying the oldest servable timestamp. Nothing in the interface
hints that the oracle is the one dependency whose readiness is a *deployment-time* property.

*(cost: ~10m)*

## B4. `slot0` and a realised fill price are quoted in opposite directions, with nothing in the type system to say so

A realised price falls out of a swap as `amountOut / amountIn` — token0 per token1 here.
`slot0.sqrtPriceX96` is token1 per token0. They are reciprocals, so a direct comparison is wrong by
construction, and the failure is quiet: an honest unattacked fill reported a **22.67bp** deviation
against a 10bp budget instead of its real **8.13bp**.

That is a plausible-looking budget breach in a test suite whose entire purpose is finding budget
breaches — it reads as a finding, not a unit error. It only came apart because the *attacked* number
(61.34%) matched an independently-measured 61.86% loss while the honest one matched nothing.

Not a bug — the orientation is documented and consistent. The friction is that both are `uint256`
WADs near `1e18` for a stable pair, and the sign of the error is small for small moves.

**Suggested fix:** a `sqrtPriceX96 → price` helper in the periphery libraries taking the desired
orientation as an argument. Every integrator writes this by hand today.

*(cost: ~25m)*

## B5. There is no way to ask a pool what price a swap just executed at

Wanted the blended realised price over a settlement that hits the route venue twice (a sized burn
plus an escalation). The `Swap` event carries per-swap amounts, so it means decoding two events and
summing. `slot0` afterwards gives the **ending** price, not the average — and for a swap that walks
several ticks those differ by the whole point of the measurement.

Settled on reading the pool's ERC-20 balances before and after and dividing, which is exact and
aggregates naturally — but only works because nothing else moves that pool's balances inside the
transaction. True here since park and route are different pools, and **quietly false for any maker
who routes through the venue they park in.**

The shape: v3 tells you where the price *is* and what each swap *did*, but a callback or a guard
reasoning about execution quality wants the average price of its own fill and must reconstruct it.
Same gap the off-chain `minOut` pattern papers over.

*(cost: ~10m)*

## B6. v4 has no in-protocol price history, and the hook that would provide it is not in the repo

In v3 every pool carries an oracle for free via `observe()`. In v4 that moved out to a hook, so a v4
pool without one has no price history — and a hook oracle only records the pool it is attached to.
Getting a v4-native reference for a pair means deploying a hook, creating a pool carrying it,
seeding it, and attracting enough genuine volume that arbitrage keeps it honest. An empty oracle
pool is worse than no oracle.

`PLAN.md` originally scheduled a `TruncatedOracleRef` on the strength of Uniswap shipping a
reference truncated-tick oracle hook. **It is no longer in `v4-periphery`**: `src/hooks/` on `main`
contains exactly one entry (`permissionedPools`), and `src/libraries/` has no oracle. A code search
returns twenty-odd third-party forks and nothing in a Uniswap-owned repo.

That matters more for a hook than for an ordinary deleted example, because a hook is the one kind of
contract an integrator cannot simply point at — reading a truncated oracle in a fork test means
**deploying** one, which means having its source and knowing its licence. The surviving copies are
MIT, but they are unattributed forks of a deleted file, several of them edited, with no upstream to
diff against.

**Practical consequence for this project: the production price reference reads v3**, and that is the
recommendation any integration needing a reference price will reach independently.

**Suggested fix:** archive rather than delete. A tag, a deprecation note, or an `examples/` repo
would each have been enough to let downstream tell a faithful copy from a modified one.

*(cost: ~25m, and it moved a planned deliverable's source of record)*

---

# C. Hooks: park-friendly and route-hostile are different properties, and a contract cannot ask which

A hook may leave `modifyLiquidity` completely ungated while gating `swap` behind a signed off-chain
quote that a contract cannot produce atomically. The pool is then a perfectly good place to **hold**
a position and an impossible place to **execute** against.

Concretely: KyberSwap's FairFlow hook on Base (`0x4440854B…D875c0c4`) has low-14 address bits
`0x00C4` — `beforeSwap`, `afterSwap`, `afterSwapReturnsDelta`, nothing else. Liquidity operations
untouched; every swap needs a `quoteSigner` signature in `hookData`.

This asymmetry is load-bearing for us, because **parking is permissionless and routing is not** —
restricting which pools a maker may park in would destroy the thesis.

**Credit where due: [`Uniswap/hooklist`](https://github.com/Uniswap/hooklist) already records
this**, and it was the fastest way to answer the question. Its schema carries all 14 permission bits
plus `swapAccess` (`none`/`temporal`/`allowlist`/`governance`/`other`), `requiresCustomSwapData`,
`vanillaSwap`, `dynamicFee` and `upgradeable`. That is close to exactly the right vocabulary.

Of the **161 Base hooks** in the registry at the time of reading (2026-09-04):

| | count |
|---|---|
| park-friendly but route-hostile (`beforeRemoveLiquidity` unset, swap gated) | **45 (28%)** |
| route-friendly but park-hostile | 10 |
| gate `beforeRemoveLiquidity` at all | 26 |
| require custom swap data | 29 |

The gap is that the registry is **off-chain, opt-in, and explicitly not the routing allowlist** (its
README says inclusion does not imply routing allowlisting — a separate form). An integrating
*contract* still cannot ask "can I route through this pool" at execution time, and must hard-code an
answer its deployer looked up by hand.

**Suggested fix:** expose the `swapAccess` / `requiresCustomSwapData` distinction on-chain — a view
on the hook, or a standard interface hooks may implement — so integrators can check atomically
rather than trusting a snapshot taken at deployment time. The vocabulary is already designed; it
just lives in the wrong place for a contract to read.

---

# D. Coming from v3 to v4

## D1. v4 payment goes through Permit2, and a never-used allowance reads as *expired* rather than *absent*

Approved USDC and USDT to the `PositionManager`, encoded `MINT_POSITION` + `SETTLE_PAIR`, called
`modifyLiquidities`. Reverted with `custom error 0xd81b2f2e:` — no name, no args, and the selector
belongs to neither the position manager nor the pool manager. Only a `-vvvv` trace shows the last
frame is `0x000000000022D473…`, i.e. Permit2, and that `0xd81b2f2e` is `AllowanceExpired(uint256)`.

The actual requirement is two approvals: `ERC20.approve(PERMIT2)` then
`PERMIT2.approve(token, positionManager, amount, expiry)` —
[`test/V4ParkedBase.sol#L149-L152`](./test/V4ParkedBase.sol#L149-L152). A plain ERC-20 approval to
the position manager — which is what v3 needs, and therefore what everyone arriving from v3 will
write — **silently does nothing**, and an expiration of `0` from a never-used Permit2 allowance
surfaces as *expired* rather than *not set*.

Notable that the whole action encoding was correct first time. The failure was entirely in the
payment path, which is the part that differs from v3 without saying so.

**Suggested fix:** two separate wins. Decoding the error name in the trace would have saved most of
it. A line at the top of the v4 minting guide — "payment goes through Permit2, here are the two
approvals" — would have saved all of it.

*(cost: ~25m)*

## D2. `MIN_SQRT_RATIO` → `MIN_SQRT_PRICE` is a rename with no migration note

Expected v3's `MIN_SQRT_RATIO`/`MAX_SQRT_RATIO` in v4's `TickMath`. They are `MIN_SQRT_PRICE` /
`MAX_SQRT_PRICE`. Values and tick range are identical — which matters here, because it means **v4's
`TickMath` is safe to point at a v3 pool**, and that is exactly what this project does (v3's own
libraries are pinned `=0.7.6` and cannot compile alongside).

Had to diff the constants by hand to establish it was a rename and not a semantic change. A one-line
note in either repo would have covered it.

*(cost: ~10m)*

## D3. `Currency` has `==` but no `!=`

`Currency` is a user-defined value type with an `==` operator attached and no `!=`, so
`a != b` fails with *"Built-in binary operator != cannot be applied to types Currency and
Currency"*. You write `!(a == b)` —
[`UniswapV4BuyCallbackBase.sol#L197`](./src/UniswapV4BuyCallbackBase.sol#L197).

Solidity has supported `using {f as !=}` since 0.8.19, so this is a one-line omission in
`Currency.sol` rather than a language limit. Trivial to work around, but it reads as "I have the
wrong import" for a minute before it reads as "the operator is missing".

*(cost: ~3m)*

## D4. `LiquidityAmounts` is in periphery, not core

Computing token amounts from a position's liquidity is what every guide and every v3 integration
does. `LiquidityAmounts` is in **v4-periphery**, not v4-core. Taking a periphery dependency for one
pure function that touches no protocol state was not worth it, so it is composed by hand from
`SqrtPriceMath.getAmount0Delta` / `getAmount1Delta` plus the three range cases —
[`SourcingMathLib.amountsForLiquidity`](./src/libraries/SourcingMathLib.sol#L95).

That is ~15 lines that exist in Uniswap's own repos twice already. The core/periphery split is
defensible for contracts; it is odd for pure math with no protocol dependency.

*(cost: ~20m, mostly deciding whether to take the dependency)*

---

# E. Build, licensing, and deployment metadata

## E1. Pragma pinning, and the workaround that is nowhere in the docs

| Repo | Implementations | Interfaces |
|---|---|---|
| v3-core / v3-periphery | `=0.7.6` hard pin | `>=0.5.0` / `>=0.7.5` |
| v4-core | `^0.8.24`, except `PoolManager.sol` at `0.8.26` | `^0.8.0` |
| v4-periphery | `^0.8.0`, except `PositionManager.sol` / `V4Router.sol` at `0.8.26` | `^0.8.0` |

An integrator on a newer solc — ours is `0.8.34`, following Midnight — cannot compile the pinned
implementations in the same profile.

**The mitigation is real and worth documenting officially: fork-test against a chain where
everything is already deployed, and bind through interfaces only.** The interfaces are caret or
open-ended and compile fine; the pin only bites if you deploy fresh instances locally. This whole
project is a single compiler profile because of it.

The cost here was **not** a multi-profile build — it was having to know that workaround exists. It
is not in any Uniswap integration doc I found.

A related sharp edge: v3 *interfaces* are open-ended but v3 *libraries* often are not.
`OracleLibrary.consult`, `PositionValue.principal` and `LiquidityAmounts` all carry `<0.8.0` upper
bounds. Taking the equivalent math from **v4-core** instead (`TickMath`, `SqrtPriceMath`,
`SwapMath`, `FullMath`, `TickBitmap`, `BitMath`) sidesteps it — the formulas are identical and those
versions are 0.8-native — but that is folklore, not documentation.

*(cost: ~25m, mostly writing interfaces by hand)*

## E2. BUSL-1.1 and MIT live in the same tree with no manifest, and the mixing is transitive

`lib/v4-core/src` mixes `PoolManager.sol` (BUSL-1.1) with the libraries and interfaces around it
(MIT). Neither repo ships a machine-readable statement of which is which, so "we only bind the
restrictively-licensed parts through interfaces" — the claim that lets this repo be
GPL-2.0-or-later at all — can only be checked by opening every file an import resolves to.

**And the mixing is not shallow.** `StateLibrary` and `TransientStateLibrary` are MIT, and both
import BUSL-1.1 files — `Position`, `Lock`, `CurrencyReserves`, `NonzeroDeltaCount`. So reading a v4
pool's state *through the library Uniswap provides for it* pulls BUSL into the build whether or not
the integrator ever names a BUSL file.

Nothing is wrong with that — BUSL-1.1 grants copying, redistribution and non-production use
outright. But an integrator who needs to know their BUSL surface (anyone shipping under a copyleft
licence, which is anyone forking Morpho's GPL periphery) **cannot learn it by reading their own
imports**. I got this wrong the first time and had to rewrite the check against Foundry's
`build-info` to get a true answer: **29 direct imports, 64 sources in the actual closure, four of
them BUSL.**

The check now enforced in CI is [`script/check-licenses.py`](./script/check-licenses.py), which
asserts the BUSL set is *enumerated and unchanged* rather than empty.

**Suggested fix:** a `LICENSES.md` at each repo root, or simply a note on `StateLibrary` saying what
it pulls in. The per-file headers are correct and complete — they are just not aggregated anywhere,
and the transitive case is exactly where aggregation would matter most.

*(cost: ~20m, plus ~30m rewriting it after the one-hop version gave a confidently wrong answer)*

## E3. No canonical machine-readable deployment list

Expected an official addresses page or JSON to resolve the v3 factory, `NonfungiblePositionManager`,
v4 `PoolManager` and `PositionManager` on Base. Ended up cross-validating on-chain instead:
`NPM.factory() == v3 factory`, `PositionManager.poolManager() == PoolManager`,
`factory.feeAmountTickSpacing(500) == 10`.

That works and is arguably better practice — but it is a verification step every integrator repeats
from scratch.

*(cost: ~15m)*

---

# F. Smaller sharp edges

| | What happened | Cost |
|---|---|---|
| `positions()` returns a 12-tuple | No struct, so every call site is a line of anonymous commas where a miscount **compiles fine and reads the wrong field**. Wrapped locally on sight. The kind of thing that makes an integration bug silent. | ~5m |
| v3 unwind is two calls and cannot pay out directly | `decreaseLiquidity` credits `tokensOwed`; a second `collect()` moves them. This also makes a *partial* unwind awkward: you size the burn, then `collect` sweeps everything owed **including accrued fees**, so the amount that arrives is not the amount you sized for. | ~15m |
| Adding a submodule silently repointed a remapping | Adding v4-core moved `ds-test/` from `lib/midnight/lib/.../forge-std/` to `lib/v4-core/lib/forge-std/`. Nothing broke, but a transitive dependency of a *new* submodule quietly rebinding a remapping an *existing* dependency relies on is a real hazard. | ~10m |
| Price impact on a concentrated pool is a cliff, not a curve | Wanted a "slightly dislocated" route venue for a test. Aiming via `sqrtPriceLimitX96` at +1% walks straight through the band and empties the far side — the residual sold for **5.87 USDC instead of 2,507**. Nothing in the pool's public surface tells you where the band ends: `liquidity()` is active-tick `L`, which says nothing about how far that `L` extends. Tick-bitmap walking is the only answer. | ~40m |

---

# What worked well

Not everything here is a complaint, and two things genuinely changed the design for the better.

**v4's singleton and flash accounting collapse the unwind.** The v3 path is burn → `collect` →
swap → settle, with the `tokensOwed` two-step in the middle (see F). The v4 equivalent happens
inside a single `unlock` with one netted delta, and the residual swap settles against the same
balance the burn credited without ever moving tokens. For a callback running on the *taker's* gas,
that is not a cosmetic difference. The v4 adapters are
[`UniswapV4BuyCallback.sol`](./src/UniswapV4BuyCallback.sol) and
[`UniswapV4NftBuyCallback.sol`](./src/UniswapV4NftBuyCallback.sol); the gas is measured in
[`test/`](./test/).

**Concentrated liquidity is what makes the whole idea work.** The thesis — that a lender's capital
can sit in an LP position and still honestly quote a fixed-rate loan — depends on being able to
compute, exactly and in a `view`, how much a position yields when partially burned at a known tick.
That is only answerable because v3/v4 positions are deterministic functions of `(L, tickLower,
tickUpper, sqrtPrice)`. A constant-product pool could not support this.

**`Uniswap/hooklist` is the right idea with the right vocabulary.** See section C — the criticism
there is only about *where it lives*, not what it contains.

**v4-core's math libraries are genuinely reusable across versions.** `TickMath`, `SqrtPriceMath`,
`SwapMath`, `FullMath` and `BitMath` are 0.8-native, dependency-light, and correct against a v3 pool
(see D2). Pointing a v4 library at a v3 pool sounds wrong and is fine, and that is a quietly
excellent property.

---

# Appendix: what is not Uniswap's

For honesty about where the time actually went, `FRICTION.log` also records friction that is **not**
Uniswap's and is excluded from the findings above: two Foundry/GitHub Actions issues (fork
throttling flags that silently do not apply to `vm.createSelectFork`, and `actions/cache` declining
to save from a failing job), and two Morpho Midnight issues (offer signatures travelling in an
undocumented `bytes` parameter, and a hash library that forces `via_ir` on its callers). They are
logged there with the same detail and have been reported to their own projects.

The one place that boundary blurs is A5: the RPC cost of an honest quote is a Uniswap-shaped problem
that surfaces as a Foundry-shaped failure.
