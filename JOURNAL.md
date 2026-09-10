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

## 2026-09-04 (D1) — FairFlow verified: green light on parking, red flag on routing

Both halves of the prediction confirmed, from the hook's **address bits** rather than Kyber's
marketing. FairFlow on Base is `UniswapV4KEMHook` at
`0x4440854B2d02C57A0Dc5c58b7A884562D875c0c4` (~10KB deployed; same CREATE2 address on Arbitrum).

Low 14 bits of the address are `0x00C4` → `beforeSwap`, `afterSwap`, `afterSwapReturnsDelta`, and
nothing else.

- **Green light.** `beforeRemoveLiquidity` (bit 9) is **not set**. The hook cannot gate
  `modifyLiquidity` at all — it is a swap-only hook. Parking and unwinding are unaffected. This
  could have killed the idea outright and it does not.
- **Red flag confirmed.** `Uniswap/hooklist` records `requiresCustomSwapData: true`,
  `swapAccess: "other"`, and describes it as enforcing *"signed quotes for exact-input swaps. Each
  swap requires hookData containing a valid signature from an authorized quoteSigner."* A callback
  cannot produce that signature atomically, so routing the residual through this pool is
  impossible.

Cross-checked three ways and all three agree: hand-decoded address bits, the hooklist registry
entry, and Kyber's own description. **Park / route / reference stays as three separate venues.**

## 2026-09-04 (D1) — `Uniswap/hooklist` partially answers the "which pools are usable" complaint

`Uniswap/hooklist` is a public registry of v4 hook deployments recording all 14 permission bits
plus `swapAccess` (`none` / `temporal` / `allowlist` / `governance` / `other`),
`requiresCustomSwapData`, `vanillaSwap`, `dynamicFee` and `upgradeable`. That is very close to the
exact data the design notes complained was unavailable, so FEEDBACK item #3 has been rewritten
rather than dropped: the registry is off-chain, opt-in, and explicitly **not** the routing
allowlist (that is a separate HubSpot form), so a contract still cannot ask "is this pool usable
for X" at execution time.

**The asymmetry is now measured, not hypothesised.** Of 161 Base hooks in the registry:

| | count |
|---|---|
| park-friendly but route-hostile (`beforeRemoveLiquidity` unset, swap gated) | **45 (28%)** |
| route-friendly but park-hostile (swap open, `beforeRemoveLiquidity` set) | 10 |
| gate `beforeRemoveLiquidity` at all | 26 |
| `requiresCustomSwapData` | 29 |

28% is the number that justifies the design rule. A maker's best parking venue being unusable as a
routing venue is the common case on Base, not an edge case discovered via one Kyber pool.

**Also found:** `BackGeoOracle` (`0x59f3…bac4`, Base) is a TWAP oracle hook — but it sets
`beforeRemoveLiquidity`, so it is park-hostile. It is a *reference* candidate only, which is
itself a clean illustration of the three-venue split. Note it backruns swaps and credits surplus
as ERC-6909, so it has its own MEV logic; treat its TWAP with suspicion before adopting.

## 2026-09-04 (D1) — The Graph: routing layer, not `IPriceRef`

Considered using a subgraph as the price reference. **Rejected for that role, adopted for another.**

It cannot back `IPriceRef`. `buyerAssetsBound` is `external view` executing in the EVM; a subgraph
is off-chain GraphQL and unreachable from it. Bridging via Chainlink would turn the reference into
a *push* oracle with an added trust assumption — and the failure mode is not theoretical, since
the April 2026 KelpDAO incident (~$290M) came from manipulated RPC infrastructure feeding exactly
that kind of verification layer. Using an indexed off-chain feed as the manipulation-resistant
reference in a design whose headline demo *is* a price-manipulation attack would be
self-defeating. `V3TwapRef` stays the production path.

Where it does fit is the half of the story currently missing entirely. Morpho's own docstring on
`buyerAssetsBound` says takers get their per-offer amount from a routing layer that is
"asynchronous/offchain, and might not be up to date on the chain's latest state", and that
`buyerAssetsBound` exists so takers can cap against it. **That routing layer is subgraph-shaped**:
index Midnight offers, surface each maker's depth-aware bound, let a taker size a fill. Building it
makes the demo show the whole loop instead of just the settlement half, and it is the natural home
for the D11 frontier chart and the historical yield accrual that risk #6 says cannot be shown live.

## 2026-09-04 (D1) — `bound.py` recovered

The gap flagged this morning is closed: `bound.py` is present at the repo root, 277 lines, but
**untracked**, which is why it read as missing. Committing it is what makes the D5/D6 cross-check
reproducible rather than a local artefact. No rewrite needed.

## 2026-09-04 (D1) — What `UniswapBuyCallbackBase` owns, and four divergences from Blue

`BlueBuyCallback` is the closest thing Midnight has to a reference implementation, so the base was
forked from its shape rather than written fresh. Four places where the fork deliberately parts
company, each because parking in an LP position is not parking in a vault:

**1. No `setAuthorization` / `setAuthorizationWithSig`.** Eleven of Blue's contract's ~120 lines and
eleven of its tests exist to let accounts act on the callback's *Blue* position — the callback holds
supply shares, so somebody has to be able to move them. Dropped whole. There is nothing to
authorise: the leaning (see below) is that the maker never hands the position over.

**2. `skim` is owner-only.** Blue's is permissionless because Blue's callback holds no idle balance,
so sweeping it to the owner cannot hurt anybody. Ours holds the buffer. A permissionless `skim`
would let anyone empty it for the price of one call, immediately before a take, forcing the LP
unwind path — which is *exactly* the dust-take bleed the buffer exists to stop, re-entered through
the front door. Cheapest possible fix, and the tradeoff is losing keeper-sweeps of rewards.

**3. `buyerAssetsBound` returns 0 for any buyer but `OWNER`.** Blue's docstring says it ignores
static reasons the bound might be smaller — wrong loan token, wrong owner — and leaves them to the
routing layer. Reasonable when the bound is a balance lookup; less so when the bound is the
headline output. A non-zero bound for an offer that reverts on take is a wrong answer, and one
comparison in a gas-free `view` is not worth saving.

**4. The buffer is in the base from the start, not bolted on at D3.** It is three lines
(`balanceOf`, compare, source the difference) and it fixes the shape of the abstract hook:
`_sourceLoanToken` takes a *shortfall*, not a total. Discovering that at D3 would have meant
changing the one signature both adapters implement.

What stayed identical: the two guards (`msg.sender == MIDNIGHT`, `buyer == OWNER`), the
`safeApprove`-then-return-`CALLBACK_SUCCESS` tail, and *not* re-checking that the tokens arrived —
Midnight checks that after the callback returns, so a second check spends the taker's gas to revert
on a condition that already reverts.

`InconsistentLoanToken` has no home in the base. Blue's invariant is
`marketParams.loanToken == market.loanToken`; ours is that one currency of the parked pool equals
the loan token, and only an adapter can check that. It moves to v3/v4.

## 2026-09-04 (D1) — The factory key has to cover the whole envelope, not `(owner, salt)`

`BlueBuyCallbackFactory` keys its registry `callbackOf[owner][salt]`. That is sound *there*, and
only there: the callback's constructor takes exactly `(owner, MIDNIGHT, BLUE)`, and the last two are
factory immutables, so `(owner, salt)` already determines the CREATE2 address completely.

It does not survive the fork. Our constructor also takes the safety envelope — `IPriceRef`, the
slippage budget, and whatever routing venue the adapter pins — and those vary per deployment. Copy
Blue's key shape and one owner deploying the same salt with a tighter budget lands at a *different*
address while overwriting the first one's registry slot: a live callback the factory no longer
indexes, and a `callbackOf` that confidently reports the wrong envelope.

So the key is `keccak256(abi.encode(owner, priceRef, maxSlippageWad, venueParams, salt))`, and the
caller's salt is one input to it rather than the key itself. The derived key doubles as the CREATE2
salt, which buys something worth having: **the address becomes a commitment to the envelope.** Two
callbacks at one address cannot disagree about their price reference. Given that the envelope is
the entire safety story — immutables are the safety envelope, and `callbackData` must never reach
them — having it verifiable from the address alone is the property you want a taker or an indexer
to be able to check.

Three tests cover it, one per envelope member (`MAX_SLIPPAGE_WAD`, route venue, `IPriceRef`), each
asserting same-owner-same-salt still yields distinct, separately-indexed callbacks.

The venue-specific half arrives as opaque `bytes venueParams`, so `UniswapBuyCallbackFactoryBase`
never needs to know what a v3 pool address or a v4 `PoolKey` is. Adapter factories keep typed
`create` functions and encode into it.

## 2026-09-04 (D1) — Leaning: the maker keeps custody of the position. Confirm at D2

The base has no owner-withdraw path, which encodes an assumption that should be stated: the maker
**keeps the v3 position NFT** and merely approves the callback for that `tokenId`, rather than
transferring it in.

Why it looks right. `decreaseLiquidity` only needs `isAuthorizedForToken`, and `collect` takes an
arbitrary recipient, so an approved callback can do the whole unwind without ever holding the NFT.
Custody would buy nothing and cost an escape hatch, a rescue path, and an ERC-721 receiver. It is
also the strongest reading of "parking is permissionless": the thesis says a maker forced to migrate
liquidity is no longer an existing LP, and non-custodial parking goes one better — the maker does
not have to move the position at all.

The exposure is that the maker can revoke approval or transfer the NFT out from under a live offer.
That is the same class as pointing an offer at a bad pool: self-harm, and the take reverts when the
loan tokens fail to arrive.

Not settled here because it is really a v3-adapter question and D2 is where the `decreaseLiquidity`
/ `collect` path gets written. If it turns out custody is forced, the base grows a withdraw path and
this entry gets a reversal.

## 2026-09-04 (D1) — `IPriceRef` shape: one function, pair-keyed

`refSqrtPriceX96(token0, token1) -> uint160`, Q64.96, Uniswap's canonical ordering. Pair-keyed
rather than pool-keyed, because park / route / reference are three independently chosen venues and
the caller has no business telling the reference which pool to read. `V3TwapRef` resolves the pair
to its own configured pool and calls `observe()`; `TruncatedOracleRef` resolves it to the oracle
hook's pool. Reverting (`PairNotSupported`) rather than returning a guess makes a missing reference
propagate out of `buyerAssetsBound` as a revert, which a routing layer must read as "no bound
available" — not as zero.

No staleness or window accessor on the interface. Those are properties of a reference, configured at
its deployment, and the callback has no decision to make with them; the D11 comparison table can
read them off each implementation directly.

## 2026-09-05 (D2) — Custody settled: non-custodial, as the D1 leaning guessed

The maker keeps the position NFT and `approve`s the callback for the `tokenId`. Confirmed by
building it rather than by reading: `decreaseLiquidity` gates only on
`_isApprovedOrOwner(msg.sender, tokenId)`, and `collect` takes an arbitrary `recipient`, so the
entire unwind runs with the NFT never leaving the maker's wallet. `ownerOf(tokenId)` is asserted to
still be the maker *after* a full unwind, so the property is tested rather than assumed.

The D1 entry can be read as confirmed, not reversed. The base needs no owner-withdraw path, no
rescue hatch, and no ERC-721 receiver — and the maker's escape hatch is the one they already had,
which is the position manager itself.

Revoking approval under a live offer breaks the maker's own offer and nobody else's; the take
reverts when the tokens fail to arrive. There is a test for that too, because "fails closed" is a
claim worth holding to.

## 2026-09-05 (D2) — v4-core is the math dependency, even for the v3 adapter

Added `lib/v4-core` and took `SqrtPriceMath`, `TickMath`, `FullMath`, `SafeCast` and `FixedPoint96`
from it. All are `^0.8.0`, all compile at 0.8.34/osaka, and none of them transitively reach
`PoolManager.sol` — which is the file pinned to exactly `0.8.26` and the reason the whole project
binds Uniswap through interfaces. Verified by compiling a throwaway probe before writing anything
that depends on it, because "the libraries are probably fine" is how a second compiler profile gets
into a project.

Two things had to be checked by hand rather than assumed:

- v4 renamed the swap-limit constants. `MIN_SQRT_RATIO` / `MAX_SQRT_RATIO` in v3 are
  `MIN_SQRT_PRICE` / `MAX_SQRT_PRICE` in v4. The *values* are identical (`4295128739` and
  `1461446…970342`, tick range ±887272), so v4's `TickMath` is safe to point at a v3 pool. That is
  a rename, not a semantic change, but nothing says so.
- **`LiquidityAmounts` is not in v4-core.** It lives in v4-periphery, which this project does not
  want as a dependency. `SourcingMathLib.amountsForLiquidity` composes the same result from
  `SqrtPriceMath.getAmount0Delta` / `getAmount1Delta` and the three range cases directly.

`SourcingMathLib` now exists, holding the *naive* bound only — position amounts at spot plus the
residual converted at spot, no price impact and no fee. It is knowingly an over-estimate, and the
size of that error is the subject of D5/D6.

## 2026-09-05 (D2) — Swap the whole residual, not just what the fill needs

`_sourceLoanToken` could swap exact-output for precisely the shortfall and leave the rest of the
residual sitting on the callback. It swaps the entire residual instead.

Two reasons. The surplus lands in the **buffer**, which is exactly where surplus loan token wants
to be — the next fill is then served without touching the LP at all, which is the dust-take defence
paying for itself. And no residual dust ever accumulates: a callback that holds three tokens is a
callback somebody has to remember to `skim`.

Verified end-to-end on the fork. A 10k+10k USDC/USDT position, unwound in full, collects
**9,879.99 USDC + 9,999.99 USDT** and the residual swap returns **9,991.47 USDC** — a round-trip
cost of **8.53 USDC, about 8.5bp**, of which 1bp is the pool fee and the rest is the pool's offset
from parity plus impact. Total recovered: 19,871.46 USDC.

That 8.5bp is the number D8 has to beat, and D7 is the test that shows what it becomes when
somebody moves the pool first.

## 2026-09-05 (D2) — What D2 deliberately does not do

Recorded so the gaps read as scheduled rather than missed. Both are called out in the contract's
own natspec:

1. **The unwind is total.** `_sourceLoanToken` burns the whole position whatever the fill size.
   Safe, and it throws away the yield leg on the first non-buffered take. Partial unwind is D3, and
   the base's `shortfall`-shaped hook already has the right signature for it.
2. **The residual swap has no price protection at all** — no `minOut`, sqrt-price limit at the
   extremes. `PRICE_REF` and `MAX_SLIPPAGE_WAD` are held as immutables and not read. This is not an
   oversight to fix quietly: D7's griefing test needs an unprotected version to attack so the cost
   can be *quantified*, and D8 then adds the reference-relative bound and re-runs the same test.

`amount0Min` / `amount1Min` are zero on the burn, and that one *is* correct rather than pending.
Removing liquidity leaves `sqrtP` unchanged, so there is no burn slippage to protect against. What
the burn does is thin the book the residual is about to be swapped into — finding A — and that
lands on the swap, which is where D8's protection goes.

## 2026-09-05 (D3) — Partial unwind: one proportion, because amounts are linear in liquidity

`_sourceLoanToken` now burns the slice the fill needs instead of the whole position. The sizing is
a single proportion rather than a search, and the reason is worth stating: at a fixed price and
range, `getAmount0Delta` / `getAmount1Delta` are **exactly linear in liquidity**. Burning `dL`
returns exactly `dL/L` of each side. So "how much do I burn" reduces to "what fraction of the
position's value do I need", with no iteration.

What is *not* linear is the residual swap, and that is the whole error term — which is where the
rest of this entry goes.

The split follows the D1 rule: sizing is venue-agnostic and lives in `SourcingMathLib`
(`liquidityForTarget`), execution stays in the adapter. `SourcingMathLib` also gets its own
fork-free unit tests, which pin branches and rounding that a fork test cannot, since the live price
moves the answer.

## 2026-09-05 (D3) — An estimate that is too accurate is a bug, if it needs to be conservative

The first working version was strictly worse than D2 and every test still passed. Worth recording
because the failure was invisible in green.

The sizing valued the position at spot and subtracted the route pool's fee. That estimate turns out
to be **very nearly exact** — on the fork, realised sourcing came in **0.2bp** below it, that gap
being price impact. But "nearly exact" means *zero slack*, and the estimate is used to decide how
much to burn *before* the swap happens. So every fill came up a hair short, hit the fallback, burnt
the remaining liquidity, and swapped again. Two burns and two swaps, the position fully drained,
gas up from 304k to 479k. Partial unwind that was never partial.

The tests did not catch it because the D2 assertions encoded the *old* behaviour —
`assertEq(_liquidity(), 0)` was written when a full unwind was correct, so it kept passing for
precisely the wrong reason. The tell was gas, not a red test. Any test that asserts a quantity is
zero should be re-read when the feature that made it zero is the thing being changed.

Fix is `IMPACT_MARGIN_BPS = 25`: size for 25bp more than the shortfall. It is a stand-in for the
impact term, and it is sized from the measurement above rather than picked — about a hundredfold
cushion on the product venue. The cost of the margin is close to nothing, because the surplus is
not lost: it lands in the buffer and serves the next fill. D5/D6 replace the constant with an
actual impact model, and that is what removes the fallback.

The fallback stays regardless. A thin venue can move further than 25bp on a large fill, and failing
a fill the position could have covered is worse than paying for a second burn.

## 2026-09-05 (D3) — Correcting the plan: partial unwind costs gas, it does not save it

`PLAN.md` has D3 as fixing "dust-grief bleed and common-case gas". Half right, and the halves come
from different mechanisms:

| | 5k fill, same position |
|---|---|
| D2, unconditional full unwind | 304,559 gas |
| D3, sized partial burn | 322,243 gas |

Partial unwind is **~18k more expensive** per fill — it adds a `getPool`, a `slot0` and the sizing
math to the taker's bill. What the maker gets for that is their position: 75% of the liquidity is
still earning after a 5k fill instead of 0%. That is the trade, and it is clearly worth it, but it
is not a gas saving and the plan should not have implied it was.

**The common-case gas win is the buffer, and the buffer landed on D1.** A buffered fill touches no
pool at all — no burn, no collect, no swap. That is where the cheap path comes from; partial unwind
is about capital efficiency.

## 2026-09-05 (D3) — The dust-take defence needs a *funded* buffer

Tested and true: with a funded buffer, twenty consecutive dust takes leave the position completely
untouched and the buffer unspent. That is the defence working.

But it only works if the buffer is funded. The surplus a sized burn leaves behind is the 25bp
margin on that fill — a 5k fill leaves ~12 USDC — which is nowhere near enough to absorb a run of
dust takes on its own. An unfunded callback facing dust takes from block one will burn a sliver and
swap on every single one.

So the buffer is a **maker policy**, not an automatic property, and the docs should say so: park
some idle loan token alongside the position or accept the bleed. Sizing that policy properly — how
large a buffer for how much expected dust — is a question for the D9 grief test, which is where the
bleed gets quantified.

## 2026-09-05 (D3, same day) — A one-wei take could destroy the whole position

Found while considering whether to add a maker-configured minimum fill size. The concern was the
dust *bleed*; what turned up was a dust *kill*.

A take of **1 wei of USDC** unwound a 10k+10k position completely: 3,981,161,161,854 liquidity to
zero, the maker's entire LP converted to buffer. One transaction, a millionth of a dollar, no
capital at risk for the attacker, and it defeats the whole of D3.

The mechanism is the D3 fallback, not the per-fill cost. `liquidityForTarget` sizes a 1-wei target
at 401 liquidity units; `getAmount0Delta` rounds down, so 401 units yields **zero** tokens; `sourced
< shortfall` fires; and the fallback — written as "unwind whatever is left and try once more" —
burns the remaining 3.98e12. The fallback's worst case was documented as "the full unwind D2 did
unconditionally", which was true and completely missed that D2 only ever did that for a fill large
enough to warrant it.

The missing invariant is **proportionality**: liquidity burnt must stay tied to the size of the
fill. `_escalationCeiling` now caps any fill's total burn at twice what the sizing said it needed.
Impact would have to run to eight times the 25bp margin before that binds on an honest fill, while a
fill too small to cover its own rounding now reverts `InsufficientSourced` and leaves the position
untouched. Fail closed, which is the same answer this contract gives everywhere else.

Two things worth keeping from how this was found:

**The fallback was reasoned about in the wrong direction.** "Worst case equals the old behaviour"
sounds like a safety argument and is not one, because it compares against the old behaviour under
the *old* trigger conditions. The old full unwind fired for large fills; the new one fired for
absurd ones. When a code path's trigger changes, the bound on its blast radius has to be re-derived,
not inherited.

**It came from taking a design suggestion seriously enough to test it.** The proposal was a
configured minimum fill size, which is a plausible answer to a bleed. Probing whether the bleed was
actually the problem is what surfaced a far worse bug sitting underneath it.

## 2026-09-05 (D3, same day) — Why the fix is not a configured minimum fill size

With the escalation ceiling in, the case for a maker-configured minimum is much weaker than it
looked, and the reasons are worth recording before the idea comes back.

**The per-fill economics are already linear.** After D3, a fill of size X burns proportionally and
swaps roughly X/2 of residual at ~8.5bp. A thousand dust fills therefore cost the maker about what
one fill of the same total costs. Price impact is convex, so many small swaps are, if anything,
*cheaper* per unit than one large one. The superlinear bleed the D1 entry worried about was an
artefact of the unconditional full unwind, and D3 removed it.

**The floor is already there, and it self-calibrates.** A fill too small to source its own rounding
reverts. That is a minimum, expressed in the only unit that actually matters — whether the fill can
pay for its own execution — and it needs no constant, no config, and no guess about the right size.

**A configured minimum has two real costs.** It strands the tail of a partially-filled offer: once
the remainder falls below S, nobody can take it and the maker has to cancel and re-sign. And there
is no channel to advertise it — `buyerAssetsBound` publishes a maximum, the callback interface has
no minimum, so takers would discover S by having transactions revert. A generic Midnight routing
layer would keep offering fills the offer will refuse.

Not ruled out as a maker policy, but it is a product decision with a fillability cost, and it is no
longer load-bearing for safety.

## 2026-09-07 — The integration suite binds deployed Midnight instead of deploying its own

`BlueBuyCallbackIntegrationTest`, the suite deferred from D1, is now forked as
`test/MidnightIntegration.t.sol`. Forked in spirit, not in mechanism, and the difference is a
deliberate choice rather than an accident of the harness.

Upstream deploys a fresh Midnight and a fresh Blue with `deployCode`, then configures both into
whatever shape the test wants — enabling an LLTV, setting the market's tick spacing to 1. That is
the right call for testing Midnight. It is the wrong call for testing an *integration* with
Midnight, because every configuration step the test performs is a step the real deployment might
not permit, and the test would never find out.

Binding the deployed instance found exactly that, immediately:

- **`tickSpacingSetter` is `address(0)`.** Nobody can call `setMarketTickSpacing` — the upstream
  setup line has no counterpart here. Markets keep `DEFAULT_TICK_SPACING` (4), so an offer's tick
  must be a multiple of 4 or it is unreachable. `MAX_TICK` is 6744, which divides by 4, so this
  cost nothing this time; it would have cost a confusing revert on any tick chosen carelessly.
- **Only some parameters are enabled.** Liquidation cursor `0.3e18` is; `0.5e18` and `1e18` are
  not. The market has to be assembled from what the configurator has actually turned on.
- **USDC carries no settlement or continuous fee**, so `buyerAssets == sellerAssets`. Worth an
  assertion rather than an assumption: if that changes, the arithmetic in every take assertion
  changes with it, and it is better to fail on the fee than on the sum.

The general form: a test that configures its dependency into the shape it wants is testing the
shape, not the dependency. Everything the fork will not let us configure is a constraint the
deployed offer would have hit anyway.

What this suite adds over pranking `MIDNIGHT` directly is the second half of settlement. `take()`
pulls `buyerAssets` out of the callback by `transferFrom` *after* `onBuy` returns — an approval
short by one wei passes every earlier test and fails only here.

## 2026-09-07 — The naive bound is already within a basis point on the stable venue

Measured through a real take: `buyerAssetsBound` reads **19,872.71** USDC against **19,871.46** the
position can actually source. The over-promise is 1.25 USDC, **0.63bp**, and it is on the right
side of correct — a taker who believes the bound gets a revert, not a bad fill.

That is a smaller error than the work scheduled to fix it assumes. D5's single-step bound and D6's
tick walk were both justified by the naive version being a knowingly bad over-estimate. On the
product venue it is not: a stable pair whose residual never leaves the active tick range simply
does not generate much of a gap, which is the same property that made the 25bp impact margin a
hundredfold cushion on D3.

This does not cancel D5 or D6, but it relocates the argument for them. The case has to be made on
the **volatile venue**, where the residual swap crosses ticks and range exit is live, and the
frontier chart on D11 should show the two venues side by side or it will look like solving a
problem that was already solved. If the volatile-venue gap also turns out to be small, that is a
finding worth reporting rather than a reason to build the tick walk anyway.

## 2026-09-07 (D4) — v4 forces a custody choice that v3 did not, so both adapters get built

Two facts about v4-core decide the shape of this day, and both were verified in the source rather
than assumed:

- **`PoolManager.modifyLiquidity` keys a position by `owner: msg.sender`** (`PoolManager.sol:161`).
  The only position a contract can burn is one it owns.
- **`unlock` reverts `AlreadyUnlocked` when nested** (`PoolManager.sol:105`). A decrease routed
  through `PositionManager` opens its own unlock, so it cannot share one with our residual swap.

Together those mean the v4 adapter cannot have both of the things v3 gave us for free. Either the
maker keeps an NFT and the settlement takes two unlocks and four token movements — which is what v3
already does, in different syntax — or the callback owns the liquidity directly and the whole
unwind nets inside one unlock, which is the only reason `JOURNAL.md` said v4 earns a second adapter
at all.

**Decision: build both.** The custodial one (`UniswapV4BuyCallback`) is the thesis artifact; the
non-custodial one is the honest comparison. Shipping only the fast path would leave the gas table
comparing a custodial design against a non-custodial one and calling the difference "v4", which is
not what the difference is. Shipping only the NFT path would spend a day proving v4 is not cheaper,
having declined to build the configuration where it is.

The cost is real and is not hidden: this is more than the one day D4 has. It comes out of slack,
and if it eats into D5 the tick walk is the thing that gives, per the ranked risks.

**How the custodial one is constrained.** D1 ruled out an owner-withdraw path on the base because
non-custodial parking made it unnecessary. That reasoning does not reach here, so `unpark` exists —
owner-only, and it takes **no recipient**: the funds' only destinations are back to `OWNER` or into
settling `OWNER`'s own offers. `park` likewise pulls only from `OWNER`. That is weaker than "the
maker never gives up the NFT" and it is the most this design can offer, so it is stated as a
property and tested as one rather than described in a comment.

Native currency is refused outright, at deployment and at parking. Settling ETH needs a payable
path and a `receive` hook, and each new way for value to enter the contract is more surface for the
envelope to cover. It costs the ETH/USDC pools, which are the deepest on v4, and that is a real
limitation rather than an oversight.

## 2026-09-07 (D4) — Where the liquidity actually is: v4 USDC/USDT is 724x thinner than v3

At `FORK_BLOCK` the v4 USDC/USDT 0.01% pool holds **5.43e11** of active liquidity. Its v3
counterpart holds **3.93e14**. Same pair, same fee tier, same chain, same block, and both at tick 7.

This is not a footnote for a project whose thesis is "park where the yield already is". Parking the
v3 fixture's 10k+10k in the v4 pool would make the maker's position seven times the entire pool's
active liquidity, and every residual swap would move the price by more than the sizing margin
covers. The v4 suite parks 2k+2k and fills in the hundreds — sized to the venue, not to v3.

Two consequences worth carrying forward:

- **The gas table has to be labelled honestly.** v3 and v4 are the same operation over different
  plumbing, not the same trade. Comparing a 5,000 fill on v3 against a 500 fill on v4 and reporting
  the gas difference without that caveat would be misleading, and D11 has to say so.
- **It is feedback.** A developer choosing where to build against Uniswap on Base today would find
  the stable-pair liquidity still overwhelmingly in v3. That belongs in `FEEDBACK.md`, stated as a
  measurement rather than a complaint.

## 2026-09-07 (D4) — Two v4 adapters, and the seam between them

`UniswapV4BuyCallbackBase` holds what both share: the route venue immutables, the residual swap,
delta accounting, the escalation ceiling, the burn sizing and the naive bound. What differs is only
*where the liquidity lives and how it is burnt* — which is the smallest possible difference for two
adapters that exist to be compared.

Extracted at the second use rather than up front. Writing the custodial one first and pulling the
base out when the NFT one arrived meant the seam was drawn around code that existed, not code that
was imagined. Risk #1 in `PLAN.md` says that if two adapters share less than about two-thirds of
their logic the abstraction is wrong; these share more than that, and the check is that
`UniswapV4NftBuyCallback` is 10.5KB against the base's contribution to both.

**The netting difference is now a measurement rather than a claim.** Counting ERC-20 `Transfer`
events on the residual token that touch the callback during one settlement:

| | residual transfers | gas, 500 USDC fill |
|---|---|---|
| `UniswapV4BuyCallback` (custodial) | **0** | 296,485 |
| `UniswapV4NftBuyCallback` (NFT) | **2** | 352,065 |

Zero is the interesting number. The custodial adapter does not "end up holding none of the
residual" — it never touches it. The burn credits a delta, the swap consumes the same delta, and no
transfer of the residual token happens at any point in the settlement. That is the thing v4 can do
and v3 structurally cannot, and it is worth exactly one adapter.

The 55,580 gas between them is the price of the maker keeping their NFT. Both numbers belong in
D11's table, and the table needs three columns, not two — v3, v4-NFT, v4-direct — because
v3-vs-v4-direct alone conflates the version difference with the custody difference.

## 2026-09-08 — D5: the single-step bound, and what it turned out to be worth

`SourcingMathLib.boundBySlippage` replaces the naive bound on all three adapters. It simulates the
unwind — burn `dL`, sell the residual on the route venue against a book that `dL` may itself have
thinned — and bisects on `dL` for the largest fill whose cost stays inside `MAX_SLIPPAGE_WAD`.
Both `bound.py` findings are implemented rather than approximated.

**The 0.63bp caveat is resolved, and against expectation.** D4 measured the naive bound
over-promising by 1.25 USDC on the stable venue and flagged that D5 therefore had "very little to
win here". That was the wrong reading. The new bound reads **19,871.458852 USDC**, and bisecting on
the real Midnight `take()` puts the largest settleable fill at **19,871.458852** — headroom **zero,
to the wei**. `MidnightIntegration` now pins both directions: the bound fills, `bound + 1` reverts.

The naive bound was close, but "close" is not the property `buyerAssetsBound` needs. A taker's
routing layer is asynchronous by construction; a bound that is 0.63bp optimistic hands back a
reverted transaction, and one that is defensively pessimistic leaves the maker's capital unreachable.
Exact is a different thing from near, and it is reachable here because the residual swap on a stable
pair never leaves the active tick range — which is exactly the case the single step models.

**Where it actually bites is v4, and hard.** Same maker, same pair, same fee tier: the parked
2k+2k is **59.24%** of that pool's active liquidity (788,956,795,188 against 1,331,759,257,984
post-park). Two things then cut the quote down. `MAX_ACTIVE_SHARE_WAD` refuses to consider burning
past half the book — finding B, without which the bisection would be searching a function that has
stopped rising. Inside that cap, the 1bp budget reaches **245.21 USDC**, about 6% of the position's
~3,950 paper value. The naive bound said 3,950; that number was never reachable by anyone.

So the D4 framing inverts. It is not that the stable venue makes the bound uninteresting — it is
that *depth relative to the maker* is the whole variable, and v3-USDC/USDT and v4-USDC/USDT happen
to sit on opposite sides of it while looking identical on paper. That contrast is the demo.

**Park and route are separate here, and `bound.py` could not assume that.** The reference
implementation models one pool, so burning always thins the book being traded into. In this design
they are independently chosen, so `sourcedFor` subtracts the burn from the route venue's active
liquidity *only* when the parked position is in that venue and in range. Same for the active-share
cap: it binds on the route venue, and an out-of-range position contributes nothing to active
liquidity, so it is not capped at all. Getting this wrong would have been invisible — the numbers
stay plausible either way.

**Cost is measured against the route venue's pre-trade spot**, so it is exactly fee plus impact:
the two things the single step models and can therefore be held to. It deliberately excludes the
park-venue-versus-route-venue dislocation, which is a price question rather than a swap question and
belongs to `PRICE_REF` at D8. Note this moves where the budget bites, never what `sourced` is worth
— `sourced` is the simulated output either way, so the bound stays honest under either reference.

**The bisection predicate is not quite monotone, and that is fine.** A `dL` small enough to round to
zero output fails the budget check too, so the predicate is false-then-true-then-false rather than
monotone. `lo` only ever advances on a *true*, so the search either finds the upper boundary or
returns 0. Under-reporting is the safe direction for a bound; over-reporting is not.

**Still outstanding after D5.** The single step assumes the route venue's active liquidity continues
in the direction of travel, so it over-estimates against a book that thins out past the current tick
range. On the stable venue it does not, which is why the answer is exact. D6's tick walk removes the
assumption; `singleStepOut` returns the post-swap price precisely so that assumption is checkable
rather than trusted.

## 2026-09-08 — D5 review: the bound was quoting 1 wei, and it over-promises off-range

Review comment on the D5 PR: *"`routeIsParkVenue=false` is unit-tested in the library only, never
through the real adapters."* Correct, and the gap was load-bearing. Every adapter-level bound test
quoted a callback whose route venue *was* its parking venue, so the flag was only ever `true` and
each adapter's own derivation of it went unexercised. Asking a distinct-route callback for a bound
for the first time turned up two things.

**A real bug: the bound returned 1 wei where the honest answer was zero.** A callback parked in the
0.01% pool but routing through the 0.05% one, under the fixture's 1bp budget, has no honest bound at
any size — the route fee alone is 5bp, and a fee is *proportional*, so it costs the same fraction of
every fill. The bisection should have found nothing and returned 0. It returned 1.

Two rounding doors, both leading to the same place. At a `dL` small enough, the residual rounds to
zero, and `sourcedFor` returned `(direct, 0)` — zero cost, therefore inside any budget. Closing that
one left the second: for a residual of a few wei, `quote1For0` *itself* rounds to zero, so the
spot value the cost is measured against vanishes and the cost with it. Either way the bisection
latched onto the one size that looked free.

The quote was wrong in both directions at once — `onBuy(1)` reverted as a dust fill, while `onBuy(2)`
succeeded. Fixed with two guards, both in `sourcedFor`: a residual that cannot be priced at all is
not quotable (distinguished from a genuinely one-sided out-of-range position, which is free for real),
and the modelled cost is floored at the fee the venue is certain to charge. The fee floor is the
substantive one: it is what makes "this configuration admits no fill" come out as zero instead of dust.

**A measured limitation, not a bug: off-range, the bound over-promises by 25%.**

| route venue | bound | largest fill that settles | error |
|---|---|---|---|
| 0.01%, = park pool, 3.97e14 active | 19,871.458852 | 19,871.458852 | exact |
| 0.05%, distinct, 7.57e12 active | 19,854.752510 | 14,824.408869 | **+25.33%** |

The single step assumes the route venue's active liquidity continues in the direction of travel.
Selling ~9,930 USDT into 7.57e12 moves the price about 13bp, past initialized ticks, and beyond them
the book is thinner than that assumption. This was documented in `SourcingMathLib` from the start;
what is new is the magnitude, and that it **fails open** — the direction a bound must never fail in.

Two consequences. First, `PLAN.md` said the case for D6's tick walk "has to be made on the volatile
venue". It does not: a thinner pool on the *same stable pair* makes it, which moves D6 from
nice-to-have toward necessary. Second, a conservative cheap guard was considered and rejected —
clamping the modelled swap to the current tick-spacing interval is sound, since liquidity only
changes at multiples of the spacing, but the 0.01% pool has spacing 1, so it would refuse to quote
almost anything on the venue where the model is provably exact. Distinguishing "a tick boundary" from
"an *initialized* tick boundary" needs the bitmap, and that is D6. Pinned in a test with both numbers
rather than half-fixed.

**Method note.** Two of the measurements behind this were initially vacuous and would have shipped as
confident numbers. A bisection helper written as `lo = from; while (hi - lo > 1) ...` never tests
`from` itself, so when every call reverted it returned its own input unchanged — reporting the bound
as the maximum fillable amount, which is exactly the claim under test. Separately, ERC-721 approval
is a single slot per `tokenId`, so a helper that approved each new callback silently revoked the
previous one, and an `onBuy` that reverts on approval satisfies any assertion about what it sourced
by never running. Both produced *plausible* numbers. The lesson is narrow and worth keeping: a probe
must be made to fail on purpose before its output is believed.

## 2026-09-08 — D6: the tick walk, and what the fail-open number was actually measuring

D5 left the bound exact on the deep venue and **+25.33% optimistic** on a thin one, for a single
stated reason: the single step assumes the route venue's active liquidity continues in the direction
of travel, and a concentrated pool's does not. D6 replaces the assumption with a read.

**The shape: a snapshot, not a live walk.** `TickBookLib` reads the route venue's initialized ticks
once, outward from spot in the direction the residual will be sold, into a flat
`SourcingMathLib.TickStep[]`; `multiStepOut` then walks that array with `SwapMath.computeSwapStep`,
crossing ticks and applying each one's `liquidityNet`. Three reasons it is a snapshot rather than the
pool's own loop, in order of weight:

1. **`boundBySlippage` bisects.** It evaluates the residual swap up to 128 times. Reading the book
   inside the swap would make the state reads `O(ticks × 128)`; reading it once makes them
   `O(ticks)`. This is decisive on its own.
2. It keeps `SourcingMathLib` `pure` and venue-agnostic — the library never learns whether the ticks
   came from a v3 pool's storage or a v4 `PoolManager`.
3. It makes the walk testable without a fork, which is where six of the nine new tests live.

The two reads that *are* venue-specific — one bitmap word, one tick's `liquidityNet` — are passed to
`TickBookLib.readBook` as `internal view` function pointers. That writes the walk once for three
adapters with no wrapper contract and no venue enum. It is an unusual construct and it earns its
place here: v3 and v4 differ in exactly those two lines and nothing else.

**Running out of book is not an error, and is never extrapolated over.** The book is finite
(`MAX_STEPS = 128`). A swap that walks off the end comes back `complete = false`, and `sourcedFor`
treats an incomplete walk as *unpriceable* rather than as worth its partial output — so the
bisection shrinks `dL` until the residual fits inside liquidity that was actually read. This is the
whole of the fix. The failure mode being removed is precisely a model that assumed what it could not
see, and replacing one assumption with a smaller one would have removed nothing.

**Results.** Same fork, same position, same 10bp budget:

| route venue | D5 bound | D6 bound | largest fill that settles |
|---|---|---|---|
| 0.01%, = park pool, 3.97e14 active | 19,871.458852 | 19,871.458852 | 19,871.458852 |
| 0.05%, distinct, 7.57e12 active | 19,854.752510 (reverts) | 9,838.854693 (settles) | 14,824.408869 |

The first row is the important one: **the walk costs nothing where the single step was already
right**, still exact to the wei against a real `take()` on the deployed Midnight. The fail-open case
is gone.

**What the remaining 9,838 → 14,824 gap is, since it is not headroom.** The 0.05% pool's entire book
above spot is *eight* initialized ticks, and its liquidity is spent by the last of them. Fills above
the quote settle only by selling the residual into a pool with nothing left in it — at a price no
maker would sign for. Refusing to quote them is the answer rather than a shortfall, and the evidence
is that **widening the budget from 10bp to 5% does not move the number by a wei**: what binds is the
book, not the budget. The bound stopped being purely a slippage limit and became a slippage limit
*and* a solvency limit on the venue, which is what it should have been all along.

**A judgement inside the walk.** Crossing a tick that takes active liquidity to exactly zero is
ordinary — a gap between two liquidity ranges — and the walk carries on across it, because
`computeSwapStep` at `L = 0` consumes nothing and moves the price straight to the next boundary,
which is what a pool does. Only a *negative* result is treated as a malformed book. Refusing at zero
was the first implementation and it was wrong: it would truncate every quote on a venue whose
liquidity is not contiguous, which is most of them. (On the pools here it happened to change
nothing, which is exactly why it needed a unit test rather than a fork measurement.)

**One deliberate inaccuracy, in the safe direction.** Finding A's burn is subtracted from the
starting active liquidity and never added back, so once the walk crosses the parked position's own
boundary tick the burn is counted twice — once there and once in that tick's `liquidityNet`. Modelling
it exactly would mean editing the book to reflect a burn that has not happened. It understates the
book past the boundary, and understating is the direction a bound may err in.

**Cost.** ~3.3KB of runtime per adapter (v3 11,541 → 14,881 B), all of it in a `view` that runs over
`eth_call`. `onBuy` is untouched: model in the view, execute in the callback.

**One test claim had to be narrowed rather than re-pinned.** The v4 active-share test asserted that
the gap between a same-venue and a distinct-venue quote *is* the cap, to 1%. Under a single step at
constant `L` both quotes were linear in the burn and the ratio was exactly the cap; the walk prices
two different books across two different sets of crossed ticks, and those do not cancel. It is now
3% and the claim is that the cap explains the gap, not that it accounts for the last basis point.
Worth flagging as a general shape: an exact identity that held because two things were both linear
stops holding the moment either becomes real, and the honest move is to widen the tolerance and say
why rather than to hunt for a number that makes 1% pass again.

## 2026-09-08 — D6 review: the fallback reopened the hole the walk had just closed

Review comment on the D6 PR: *"empty book falls back to the pre-D6 fail-open model — a route venue
with no ticks beyond spot reopens the exact +25.33% fail-open D6 fixes."* Correct, and the tell was
sitting in my own docstring: *"An empty `routeBook` is the D5 fallback… No adapter takes this path."*
The second sentence was false.

**The mistake was a representation one, not an arithmetic one.** I let one value — an empty array —
carry two meanings that need opposite handling: *no book was read* (a library test calling
`boundBySlippage` directly) and *the book was read and there is nothing in it* (a venue too sparse
for `readBook` to find an initialized tick). Those are not close. The first is a test convenience;
the second is a live route venue whose depth is unknown, which is the case where assuming the
current `L` continues forever is at its most dangerous. The code could not tell them apart, so it
picked the dangerous reading, silently, on precisely the venues the walk was written for.

The fix is a deletion: `sourcedFor` always walks, an empty book prices nothing, and the bound is
zero. **Unreadable is unquotable.** Worth noting that no fork test failed when the fallback came
out — the adapters' pinned numbers are all unchanged — which is the point. The path was unreachable
on *these* pools and reachable on a sparser one, and no measurement here would ever have said so.

**What the fallback was actually buying** was that nineteen D5-era library tests could keep calling
`_params(...)` without a book. That is now paid for honestly, in the test file where it belongs: the
default `_params` carries a book whose first boundary sits 5,000 ticks out, far past anything those
residuals can reach, so the walk provably crosses nothing and reduces to the closed-form single
step. The old numbers still hold and now mean something more specific — *this venue is deep enough
that the book does not bite* rather than *no book was consulted*.

One behaviour genuinely changed. A route venue with zero active liquidity used to quote the direct
side under a 100% budget, on the sound reasoning that a maker authorising the loss of the entire
residual can still source the loan-token half. It now quotes zero at every budget. The reasoning is
still sound; what it lost is the model's standing to assert it, because a venue with no active
liquidity is one the walk cannot price at all. Under-reporting is the safe direction and the
deployable ceiling on `MAX_SLIPPAGE_WAD` is 10%, so nothing reachable is lost. The old test for it
had quietly gone **vacuous** — both sides of its equality became zero and it kept passing — which is
the third time this project has caught that shape, and the reason the replacement asserts a non-zero
control alongside the zero.

**Second finding: the bitmap search had no direct tests.** Also correct. It is arithmetic copied by
hand, because v4-core's `nextInitializedTickWithinOneWord` takes the bitmap as a `mapping storage`
and is therefore uncallable by anyone reading another contract's bitmap through a getter — and v3
and v4 formulate the masks differently, so "copy the one from the repo" is already ambiguous. The
only thing checking it was a fork test asserting a bound several layers downstream, which would
have surfaced an off-by-one in the word arithmetic as a slightly wrong number.

Nine tests now cover it against a `MockTickSource` — a bitmap whose initialized ticks are chosen
rather than inherited from a live pool: ordering outward from spot in both directions, the
`liquidityNet` sign flip, continuation across a word boundary, negative ticks and negative word
indices, the current tick being inclusive downward and exclusive upward, the empty book, the
`MAX_STEPS` truncation, and a fuzz over strict ordering.

**They all passed on the first run, which is not evidence.** Mutation-tested before being believed:
dropping the sign flip fails 2, an off-by-one on the downward cursor fails 8, and a one-bit error in
the upward mask fails 6. That check is now the habit — a probe has to be made to fail on purpose
before its output means anything.

**173/173.** Removing the fallback also took ~280 bytes off each adapter, since `singleStepOut` left
the production path with it. It stays in the library as an *independent* formula: the walk must
reproduce it to the wei for a swap that crosses nothing, which is the only test that would catch the
two disagreeing about the fee or the rounding.

## 2026-09-08 — D6 review, second round: v4 exercised the walk without testing it

Two more coverage comments, both correct, and the second one is the more interesting.

**"No v4 fork test drives `buyerAssetsBound` through a route pool where the walk actually crosses an
initialized tick."** The premise turned out to be half wrong in a way that made the finding worse
rather than better. v4 *does* cross — the parked pool's first initialized tick sits one tick from
spot, so a residual of any size leaves the active range immediately. What was missing was any
assertion that would notice.

Measured rather than argued: replacing `multiStepOut` with `singleStepOut` — deleting D6 outright —
left **all 38 v4 tests green**, while v3 caught it with four failures. The v4 quotes were all
asserted as ranges (`100e6 < bound < 500e6`) or as relative orderings, and both survive a 14%
change in the number. Coverage that executes a code path without constraining it is not coverage,
and the two are indistinguishable from a passing suite.

Now pinned exactly in both v4 suites: **214.661289** walked against **245.214731** single-stepped.

**The v4 failure is not v3's failure, and saying so precisely matters.** On v3 the single step's
extra size does not settle — it is a bound failing open and the taker eats the revert. On v4 both
numbers settle, because there the bound is budget-limited with capacity far above it. What the
single step buys is 30.55 USDC of quoted size sourced by spending more than the 1bp the maker
signed for. Same mispricing, same cause, different victim: the taker on v3, the maker on v4. I
nearly wrote this up as another fail-open and checked first.

**"No test combines `routeIsParkVenue=true` with a book that actually gets crossed."** Correct, and
it was the one interaction D6 introduced without covering. Every test setting that flag used the
deep default book, so finding A's burn was subtracted from a book the swap never walked — the two
mechanisms were each tested alone and never together.

Two tests now. The first is that they compound, with the active-share cap asserted *not* to bind so
the measurement is self-thinning plus the walk rather than finding B. The second makes the
double-count a number: `multiStepOut` takes liquidity already net of the burn and never adds it
back, so reaching the parked position's own boundary subtracts the burn a second time inside a
`liquidityNet` that still describes the position at full size. The library claimed this was
deliberate and erred downward; that claim now has a test comparing the book as read against the book
a position-aware model would walk, and asserting the difference is real and negative.

**175/175.** Mutation-checked again, since the whole finding was that a green suite proved nothing:
deleting the walk now fails 4 v4 tests and 8 library tests; deleting self-thinning fails 6 and 2.
Both were zero and zero on one side before this round.

## 2026-09-10 — D7: the griefing test, and what it settles about D8

The maker's residual swap is sandwichable, it is worth sandwiching, and the number is large:
**a 5,000 USDC fill costs the maker 3,092.76 USDC — 61.86% of the fill** — of which the attacker
takes 2,995.19 and the route pool's LPs take the remaining 97.57 in fees. The attacker risks a
3,000 USDT round trip and holds the same USDT at the end. `test/SandwichV3.t.sol`, against a real
`take()` on the deployed Midnight, every figure pinned at `FORK_BLOCK`.

### The maker pays in liquidity, not in price

This is the part I had wrong going in. I expected the harm to be "the residual sold cheap and the
maker ate the difference" — a bounded loss, roughly the slippage on one leg. It is not, because
`onBuy` has no discretion: it must deliver `shortfall` or revert. A residual that fetches less USDC
does not settle for less, it **burns more liquidity until the loan is covered**. The maker pays the
attacker out of the LP position, at a size the maker never authorised and cannot see coming.

So the loss is not set by the price move. It is set by `escalationCeiling`. Measured: the honest
fill burns 1,004,421,974,055 and the attacked fill burns 2,008,843,948,110 — **exactly twice, which
is the ceiling, and it will be exactly twice for any attack large enough to trigger escalation at
all.** The D3 ceiling turns out to be doing a second job nobody designed it for: it is the cap on
this attack's payout. Without it, the fallback it replaced would have handed over the whole position.

Worth stating plainly because it inverts the intuition: the escalation path is what makes the take
*settle*, and settling is what makes the attack profitable. A callback that simply reverted when the
first burn came up short would lose the maker nothing here. It would also fail honest fills on any
venue with real impact, which is why D3 added escalation in the first place. The two goals are in
direct tension and D8 is where they get resolved — not by removing escalation, but by giving it a
price it is not allowed to cross.

### The decision this forces: D8 guards realised execution, not spot

The obvious `IPriceRef` design is to compare the route pool's `slot0` against the reference and
refuse to trade when they disagree by more than `MAX_SLIPPAGE_WAD`. **That design does not stop this
attack, and the test says so with a number.**

| | WAD | vs 10bp budget |
|---|---|---|
| Front-run's displacement of route spot | 0.00077014 | **7.70bp — inside** |
| Realised price, honest fill | 0.00081275 | 8.13bp — inside |
| Realised price, attacked fill | 0.61341790 | **61.34% — 613x over** |

The front-run moves spot by less than the maker's entire budget. A spot-versus-reference guard waves
it straight through. The damage is not displacement — it is that the front-run **eats the book the
residual then has to walk**, and the residual is itself twice the size it should have been because
the shortfall forced an escalation. Only the realised price sees all three effects, and it is the
one number that lines up with the loss: 61.34% deviation against 61.86% of the fill destroyed.

So `IPriceRef` gives D8 a reference, but the check is `amountOut >= expectedAt(reference) * (1 -
MAX_SLIPPAGE_WAD)` on the actual swap output — a `minOut` derived on-chain from an oracle the
attacker cannot move, which is exactly the protection the D2 docstring flagged as missing. Checking
`slot0` first is *not* a cheap pre-filter worth adding as well: it costs a read, it catches nothing
this does not, and it would encourage the reading that spot proximity means a safe execution.

### D8 has less than 2bp of slack

The honest fill realises **8.13bp against the 10bp budget**. That is D6's bound working — it quoted
a fill that is genuinely inside the budget — but it leaves under 2bp between an honest fill and a
guard that refuses it. D8 cannot be sloppy about which price it derives `minOut` from or how it
rounds. A guard that is 2bp pessimistic starts reverting fills the bound correctly promised, which
is a bound that over-promises again, by a different mechanism.

This also means the D8 test cannot just assert "attacked take reverts". It has to assert both
directions on the same callback — honest fill still settles, attacked fill reverts — or it will pass
against a guard that refuses everything.

### The exposure is a maker configuration, not a property of the design

The identical attack routed through the deep 0.01% pool the position is parked in **loses the
attacker 0.56 USDC**. Moving a venue ~50x thicker costs more in fee and impact than the take is
worth. So the honest claim is not "Uniswap-parked callbacks can be sandwiched" — it is "a callback
routing through a venue an attacker can afford to move can be sandwiched", and `ROUTE_POOL` is an
immutable the maker picks at deployment.

That is a better result than a blanket vulnerability, because it is actionable: the maker can be
told what depth ratio is safe, and D11's frontier chart is the natural place to say it. It also
retroactively justifies invariant 5. Park is permissionless and route is not, and the reason is
right here — the venue the maker is *forced* to trade in is the one an attacker gets to choose the
price of.

### What D8 does not fix, and the suite says so

An attacker who never takes at all can just move the route venue and make a quote read one block
earlier unfillable. Bisected: 3,000 USDT leaves the 9,838.85 bound fillable, **6,000 kills it, for a
round-trip cost of 5.47 USDC**. The take fails closed — `InsufficientSourced`, no debt, no credit,
the position untouched — so it is censorship of the offer, not theft from it.

No bound computed at block N can promise anything about block N+1, so this is not a bug and D8 will
not close it. It is in the suite as a standing test because the D8 write-up will otherwise read as
"the sandwich problem is solved", and the accurate claim is narrower: a price reference stops the
maker being *robbed* between quote and block, not being *stalled*. Cheap censorship of a fixed-rate
offer is a real property of routing through a venue this thin and belongs in the limitations column,
next to the off-range note from D5.

### Mutation-checked, per the D6 habit

A green griefing suite proves nothing on its own — the attack could be inert and every assertion
still hold. Two mutations, both made to fail on purpose:

- **Escalation disabled** (`if (false && sourced < shortfall …)`): the attacked take reverts with
  `InsufficientSourced` and two tests fail. That is the mechanism claim above, confirmed from the
  other side — with no escalation the maker loses nothing here, because nothing settles.
- **The deep-venue test pointed at the thin pool**: profit flips from -0.56 to +2,995.19, failing
  its assertion, and reproduces the sandwich test's figure to the wei. The venue is the only
  variable between them, which is what makes "it is the maker's route configuration" a measurement
  rather than a story.

## 2026-09-10 — D8: the fix, and three things it turned up on the way

`V3TwapRef` plus a reference-relative cost guard in `onBuy`. **191/191.** The D7 sandwich now
reverts at **44.60% against the maker's 10bp**, and the attacker who used to walk away with
2,995.19 USDC walks away **−2,998.04**. The maker's position, buffer and NFT are untouched: the
take fails closed.

### The security property, measured rather than asserted

The whole guard rests on the reference being expensive to move, so that is pinned as a number
rather than a claim. Pushing 100,000 USDT through the very pool the reference reads drags spot from
tick 7 to **18,819** — a ~7x price move — and the mean tick over 30 minutes stays on **7 exactly**,
because a same-block push contributes zero elapsed seconds to the mean. One Base block later it has
drifted to 27: 20 ticks against 18,812 of displacement, a tenth of a percent. Held for the whole
window it converges on 18,819 exactly, which is the other half of being usable — a reference that
never moved would refuse every fill after a genuine repricing.

Worth recording what that probe also showed, because it is not what "deep pool" suggests: the
0.01% USDC/USDT pool is deep only in a narrow band. 100k USDT exhausts it. Depth on a stable pair is
a statement about a band, not about a pool, and D6 found the same shape on the 0.05% venue.

### The denominator was nearly wrong, and the test that would have caught it did not exist yet

The obvious guard is a `minOut` on the residual sale: value the residual at the reference, subtract
the budget, require at least that much back. I wrote it that way, and it is wrong — not by a little.
`boundBySlippage` measures cost over *sourced*, and a balanced position pays out roughly half its
value as residual, so a guard on the residual leg alone is about twice as strict as the quote. The
callback would have refused fills its own `buyerAssetsBound` had just promised.

It surfaced only when I pointed the fixture at a real reference and honest fills started reverting.
Quote and execution have to enforce one inequality or neither is trustworthy, so `costWad` takes
`sourced` as its denominator and `onBuy` checks it once over both swaps rather than per-swap. A
first swap that came in expensive can still settle honestly if the second is cheap, and a revert
rolls back both burns anyway, so nothing is spent finding out.

### The bound was promising fills the executor would not honour

D5 and D6 built `boundBySlippage` to bisect on `dL` and report what that burn sourced. That answers
"how much can this position source inside the budget", which is **not** the question
`buyerAssetsBound` is documented to answer. `onBuy` does not burn the `dL` the model picked — it
sizes the burn from the *fill*, through `liquidityForTarget`, which adds `IMPACT_MARGIN_BPS`.

On a deep venue the margin is clamped away by available liquidity and the two agree to the wei,
which is why nothing noticed for three days. On the thin route venue it inflates the burn, sells a
larger residual into a nearly-spent book, and costs more than the quote promised: **a fill at
exactly the quoted bound realised 16.93bp against a 10bp budget.** Before D8 that settled and the
maker silently overpaid; after D8 it would have reverted, which is a bound failing open by a
different door.

The bisection now searches over **fill size** and sizes each candidate burn exactly the way the
executor will, escalation included. Consequences, all measured:

- The deep-venue answer is unchanged to the wei — still **19,871.458852**, still exact against a
  real `take()`, because the clamp still applies there.
- The thin v3 venue drops 9,838.854693 → **9,817.764107**, which is the 25bp margin being told the
  truth about. Filling at the new number settles.
- v4 drops 214.661289 → **214.128351**, 0.25%, same cause.
- It is *cheaper*: ~35 iterations over a fill range instead of up to 128 over a `uint128`.

Modelling the escalation in the predicate was not optional. Refusing to quote fills that need it is
safe but halved the bound on the thin v4 venue — a maker's capital idle because the quote would not
admit to behaviour the callback actually has.

### And a rule that fell out of the search ceiling

The search needs a top, and `sourcedFor(maxBurn)` cannot be it — that returns zero exactly when the
route book cannot absorb the whole position's residual, which is the case the search exists for.
The ceiling is the burn's paper value at the reference instead. That has a consequence I did not
design and have chosen to keep: **the bound never promises more than the residual is worth at the
maker's own reference**, even when the route venue would pay better. Quoting the excess would mean
promising to capture a favourable deviation that can vanish between the quote and the block, which
is the same asynchrony the bound exists to be honest about. Pinned in `SourcingMathLib.t.sol`.

### D8 killed the escalation path on these venues, and pretending otherwise would have been fake coverage

`liquidityForTarget` covers the route fee and a flat 25bp of impact, so the sized burn only falls
short once impact exceeds 25bp. On a venue whose book above spot is a handful of ticks, the residual
that costs 25bp and the residual that costs tens of percent are nearly the same trade. Bisected at
`FORK_BLOCK` on the 0.05% route pool: a **2,400** USDT drain still settles in one burn inside 10%,
and **2,500 costs 34.99%**. The constructor caps any budget at 10%, so no callback this factory can
build would settle it — escalation is not merely expensive there, it is unreachable.

The mechanism stays in the contract: a route venue with gradual depth rather than a cliff would
separate the two thresholds. But the D3 test that exercised it through a drained venue can no longer
do so, so it now runs against a deliberately neutralised stub reference, and a paired test states the
finding with the numbers. Rewriting the test to "prove" escalation through a real reference would
have meant inventing a configuration that does not exist.

### Mutation-checked, and one mutation exposed a hole

Three mutations. Deleting the cost guard fails 3 tests. Dropping the route fee from the executor's
sizing fails 4. But **valuing the residual at route spot instead of the reference — undoing the
central change of the day — failed exactly one assertion, by 0.9%**, because on a quiet fork the two
prices agree to within a basis point and nothing in the suite set them apart.

The fork test I reached for first did not close it either: front-running the route venue does collapse
the quote, 9,817.764107 → 3,872.312997, but that is D6's book walk finding the venue spent, not D8's
valuation. Two library tests now set reference and route spot independently on a book deep enough
that the walk never binds, and the mutation fails all three with exact-equality evidence — identical
numbers where there should be a difference, which is the signature of the blind spot itself.

### v4 is deliberately untouched

`UniswapV4BuyCallbackBase` still passes route spot as its reference and still has no cost guard.
That is the v3-first build order, not an oversight, and it is the permissive direction: v4 quotes
what it can source, it just does not yet refuse to source it into a manipulated book. D10 ports both
halves and re-runs the grief suite against them. The one number that moved on v4 is the bisection
change, which is venue-agnostic.

## 2026-09-10 (D9) — The dust bleed, measured: it does not grow with the number of takes

D3 argued from theory that the per-fill economics are linear and therefore a configured minimum
fill size is not load-bearing for safety. D9 is the measurement that argument was owed, and it
holds — more sharply than the argument claimed.

Fixing the grief volume at 2,000 USDC and splitting it every which way, against a fresh 10k+10k
position each time:

| takes | size each | maker's loss |
|---|---|---|
| 1 | 2,000 USDC | 0.131738 USDC |
| 4 | 500 USDC | 0.130993 |
| 20 | 100 USDC | 0.130834 |
| 200 | 10 USDC | 0.131258 |

A **200× increase in the number of takes moves the maker's cost by 0.7%**, and not monotonically.
Splitting is very slightly *cheaper* for the maker over most of that range, because price impact is
convex — two hundred small residual swaps each pay less of it than one large one, which more than
covers the extra wei of rounding each take adds. The 200-take row turning back up is that trade
crossing over.

So the bleed is not a function of how often you are taken. It is 6.55bp of volume, which is the
round-trip cost of the residual swap and nothing else. **There is no dust attack here, only
ordinary execution cost charged per unit of business done.**

That is entirely a property of D3's sized burn, and worth saying because it was not true before.
Under D2's unconditional full unwind the first take of any size cost the maker the whole round trip
on 19.9k and the second cost nothing, because there was nothing left. The superlinearity D1 worried
about was that, and D3 removed it.

## 2026-09-10 (D9) — How to size a buffer: face value, no leverage

D3 left this open — "sizing that policy properly is a question for the D9 grief test". The answer is
that there is no formula, because the buffer defends exactly its own face value and not a wei more.

Funded with the whole 2,000 USDC grief, the position is never touched and the maker's cost is not
small but **exactly zero**: every USDC the buffer pays out comes back as credit of the same size.
Funded with half, take 11 of 20 is the first to reach the position and the bleed is half.

So the maker policy is "hold as much idle loan token as you expect to be taken in dust between
top-ups", and the docs should say it in those words. A buffer buys volume, not leverage.

## 2026-09-10 (D9) — The minimum fill size already exists, and it is the slippage budget

D3 declined to add a configured minimum, on the grounds that the sourcing floor self-calibrates.
Measuring what it calibrates *to* turned out to be the most interesting thing in the day.

| `MAX_SLIPPAGE_WAD` | smallest fill that settles | floor × budget |
|---|---|---|
| 1bp | 9,977 wei USDC | 0.998 wei |
| 10bp | 999 | 0.999 |
| 100bp | 102 | 1.02 |

The floor is inversely proportional to the budget, and the constant of proportionality is **one
wei**. The minimum fill size is the fill at which a single wei of rounding loss is the entire
slippage budget. It needs no constant, no config and no guess, and it moves with the one knob the
maker already sets.

**And the mechanism is D8's cost guard, not D3's rounding check.** One wei below the floor the fill
*does* source enough to cover itself — it reverts `SourcingCostAboveBudget(1.0001bp, 1bp)`. Deleting
the guard drops the floor to **2 wei**. So the dust floor and the sandwich guard are the same
mechanism seen at two scales, which is a better property than having two.

The D3 reasons against configuring one all still stand and are now cheaper to state: a configured
minimum has to be guessed, strands the tail of a partially-filled offer below it, and has no channel
to be advertised on, since `buyerAssetsBound` publishes a maximum and the callback interface has no
minimum.

## 2026-09-10 (D9) — The grief priced from the attacker's side

The bleed tests measure what the maker loses. What settles the question is what the attacker pays.

One unbuffered 10 USDC take destroys **648 wei of USDC** of maker value and costs the attacker
**565,589 gas** — a full unwind, burn and collect and swap, every time. Measured cold, one
transaction per take, because that is how griefing actually works; amortising it across a loop reads
~297k and flatters the attacker.

Breakeven — the gas price at which the grief costs the attacker what it costs the maker — is
**0.00034 gwei** with ETH at $3,400. Base clears one to two orders of magnitude above that, and this
ignores the L1 data cost, which on Base is usually the larger half of the bill. The attacker also
has to post collateral and carry the debt.

The dust grief is uneconomic by a wide margin with no minimum fill size, no rate limit and no
allowlist. The defence is that settlement is expensive to trigger and cheap to serve.

## 2026-09-10 (D9) — D8's cost guard does not subsume D3's escalation ceiling

Found by mutation. Replacing `escalationCeiling(burn, position.liquidity)` with
`position.liquidity` — undoing D3's proportionality fix outright — leaves every D9 bleed test green.
The cost guard catches it: escalating to the whole position for a dust fill now costs far more than
1bp, so it reverts rather than settling, and the maker's position survives.

That is not a reason to drop the ceiling. At a **100bp** budget the same mutation drops the floor to
**1 wei**, which means the D3 kill comes back in full: a one-wei take unwinds the entire position
and passes the guard, because 100bp is enough room to pay for it. The guard covers the 1bp maker and
not the 100bp one.

Two defences that overlap for the configuration you happen to test are not one defence. Recorded
because the mutation looked survivable and was not. The full suite kills it seven ways, including
`test_aDustFillCannotUnwindThePosition`, which is the test D3 wrote for exactly this.

## 2026-09-10 (D9) — Licensing, resolved

Three questions, closed together.

**1. The repo is GPL-2.0-or-later, and now says so.** `LICENSE` at the root, the GPL-2.0 text.
Forced rather than chosen: `UniswapBuyCallbackBase` is forked from Morpho's
`src/periphery/blue-buy-callback/`, which is GPL-2.0-or-later, so the derivative is too. Every
source file already carried the header; the repo did not carry the licence. Open since D4.

**2. The BUSL-1.1 surface is enumerated and enforced.** Both dependencies ship BUSL core beside
permissive periphery in one tree: v4-core's `PoolManager.sol` is BUSL and the libraries around it
are MIT; Midnight's core is BUSL and its periphery is GPL-2.0-or-later.

`script/check-licenses.py` inventories every source in the build and fails when the BUSL set
changes. Four files are in it, all pulled in behind MIT libraries:

| file | reached via |
|---|---|
| `Position.sol` | `StateLibrary` |
| `CurrencyReserves.sol`, `Lock.sol`, `NonzeroDeltaCount.sol` | `TransientStateLibrary` |

That is permitted. BUSL-1.1 grants copying, redistribution and **non-production use** outright;
only production use needs the Additional Use Grant at `v4-core-license-grants.uniswap.eth`, and the
Change Date is 2027-06-15, after which v4-core becomes MIT. Nothing here is a violation — but
anything deployed for real needs that grant read first, which is why the set is pinned rather than
merely counted.

**3. D10's oracle source changes.** Risk #4 was "`UNLICENSED` headers on the oracle sources conflict
with an open-source submission". The premise is gone: Uniswap's truncated-oracle example has been
**deleted from `v4-periphery`**, so there is no canonical source to fork with or without a licence
on it. What survives is a scattering of third-party copies, MIT but unattributed, several edited,
with no upstream to diff against.

So `TruncatedOracleRef` will read **OpenZeppelin's `uniswap-hooks`** (MIT, maintained), not a fork
of a deleted example. MIT into GPL-2.0-or-later is a one-way compatible relicense, so it can sit in
the tree with its own header preserved.

The substitute is better than the thing it replaces, which was not the expectation. Their
`BaseOracleHook` records *two* accumulators per observation — the ordinary `tickCumulative` and a
`tickCumulativeTruncated` capped at `maxAbsTickDelta` per block — and `V3TruncatedOracleAdapter`
exposes the truncated series through a **v3-shaped `observe(secondsAgos)`**. So `TruncatedOracleRef`
is `V3TwapRef` pointed somewhere else, not a second implementation, and the D10 comparison becomes
one where the *only* difference between the two references is the truncation. That is the
apples-to-apples the D8 entry asked for and did not expect to get. It also compiles: `^0.8.19`,
v4-core imports only.

This is a change to the D10 plan, made on D9 as scheduled, and the reason it was scheduled before
D10 rather than during it.

## 2026-09-10 (D9) — Absolute gas is not a pinnable number

The first CI run of D9 failed on one assertion: `gas per dust take: 586,929 !~= 565,589`. Not a
rate limit, not a fork difference — **forge 1.8.1 on the runner against 1.5.1 locally**, disagreeing
by 3.8% about the same call, against the same fork, at the same block.

Gas is a property of the toolchain as much as of the contract. Pinning it turns a runner upgrade
into a red suite for a reason nobody should care about, and the temptation then is to widen the
tolerance until it stops complaining, which quietly retires the assertion.

The assertion is a **floor** instead — the attacker's per-take gas must stay above 500,000. That is
also the only direction the argument needs: the claim is that griefing costs the attacker far more
than it costs the maker, and more gas only strengthens it. Both measured figures stay in the
docstring, attributed to the version that produced them.

The general rule, since this will come up again on D11's gas table: **pin what the contract decides,
bound what the toolchain decides.** Bounds, fills, prices and costs are exact and stay exact. Gas
gets a floor or a ceiling in whichever direction the claim runs.

## 2026-09-10 (D9, corrected same day) — The licence check was one hop deep, and the claim was false

The check shipped in the D9 commit walked the imports written in `src/` and `test/`, resolved each
to a file, and read its SPDX header. It reported "all 29 dependency imports are MIT or
GPL-2.0-or-later; nothing BUSL-1.1 is compiled into this project."

That is wrong, and it was wrong in the way static checks usually are: it measured what I wrote
rather than what the compiler builds. `StateLibrary` and `TransientStateLibrary` are both MIT and
both import BUSL-1.1 files. One hop sees 29 files; the actual build closure is **64**, and four of
them are BUSL:

- `Position.sol`, via `StateLibrary`
- `CurrencyReserves.sol`, `Lock.sol`, `NonzeroDeltaCount.sol`, via `TransientStateLibrary`

**The rewrite reads Foundry's `out/build-info` instead of parsing imports at all.** That is the
compiler's own record of every source in each compilation unit — ground truth rather than a
re-implementation of solc's resolver, which is the same reasoning that put `TickBookLib` on the
pool's own `TickBitmap` rather than a re-derivation. It clears `build-info` before rebuilding,
because Foundry writes one file per unit and never prunes, so a stale unit reports imports nothing
has any more.

**And what it enforces changed, because "no BUSL" was the wrong bar.** BUSL-1.1 grants
redistribution and non-production use outright; the four files are permitted here. The property
worth guarding is not their absence but their *enumeration* — the check now fails when the BUSL set
changes, which is exactly when somebody should look again, and in particular before anything is
deployed for real.

Two things to keep from this. **A licence claim about a build has to be made against the build**,
and a hackathon submission stating one publicly is not a place to approximate. And **the mutation
test I ran was too weak to catch it**: I added a *direct* import of a BUSL file, which the one-hop
check was always going to see. A mutation that only exercises the path you had in mind proves the
code does what you meant, not what you claimed. The replacement is mutated by reaching a BUSL file
that is genuinely off the expected list (`Pool.sol`), which fails, as it must.

## 2026-09-10 (D10) — The v4 fix, and what porting it exposed about references

D8 protected v3 and explicitly left v4 running what D7 attacked, on the grounds that route spot was
the *permissive* direction and one day's exposure in a test suite costs nothing. Ported now: both
v4 adapters read `PRICE_REF`, accumulate what each residual sale was worth against it, and refuse a
settlement whose realised cost exceeds `MAX_SLIPPAGE_WAD`. `SourcingMathLib.Sale` moved out of
`UniswapV3BuyCallback` to hold the totals for all three adapters.

**The attack reproduces on v4 with the same signature it has on v3.** Front-run the route venue,
fire the settlement, and the unguarded twin burns **exactly twice** the honest liquidity —
80,355,823,566 against 160,711,647,132. Not approximately twice: the escalation ceiling, hit
precisely, exactly as D7 found on v3. The maker pays in liquidity rather than in price because
`onBuy` must deliver or revert, and that is a property of the settlement contract, not of the venue.

**The non-custodial adapter needed its own attack.** The two v4 adapters carry the guard separately,
so deleting it from `UniswapV4NftBuyCallback` alone left the whole suite green even after
`SandwichV4` existed. Two implementations of one rule need two tests; one test and an assumption of
symmetry is not coverage.

### The finding: a slippage budget has to cover the *basis*, not just the execution

Porting the guard turned every honest v4 fill red at the fixture's 1bp budget, and the reason was
not impact. Measured at `FORK_BLOCK`:

| | sqrtPriceX96 |
|---|---|
| reference — `V3TwapRef` mean tick on the v3 0.01% pool | 79255895837549753882639819015 |
| v4 route/park venue spot | 79258856290041777283278632807 |

**0.75bp apart, persistently.** Both pools sit at tick 7, which is exactly as close as "the same
tick" gets you — a tick is a basis point wide, and a mean-tick reference is quantised to the tick
boundary while a venue's spot sits somewhere inside it. Add the route fee and an honest fill costs
more than 1bp before any impact at all.

So the budget is not only an impact allowance. It has to cover **the standing basis between the
route venue and the reference venue**, and a mean-tick reference contributes up to a tick of that on
its own. The corollary is sharp and worth stating in the README: *a 1bp maker can only route on the
venue they reference.* The v3 suites pass at 1bp precisely because their route pool **is** their
reference pool, so only TWAP-versus-spot drift shows up — which reads as a validation of the 1bp
number and is really a validation of that coincidence.

The v4 fixtures now carry a 10bp budget and a real `V3TwapRef` in place of a stub pinned at parity.
Both were forced by the port, and the stub was the larger error of the two: it asserted a price the
market does not have, which cost 5.72bp of fictitious basis until it was replaced.

### The v4 bound is conservative by 3%, and that is checked rather than assumed

At the new budget the bound is **3,142.708391** and the largest fill that actually settles is
**3,242.208926** — the bound under-promises by 3.1%. v3 is exact to the wei; v4 is not, and the
difference is not yet explained. It is recorded rather than chased because the direction is the safe
one: the bound never promises a fill settlement would refuse, which is the invariant that matters,
and D11's frontier work is where tightness gets studied.

What that check is really for: re-pinning a moved constant is not evidence. Before touching either
pinned bound I bisected the largest settling fill against the quote, and the first time I ran that
probe — at 1bp, before diagnosing the basis — it showed the bound *over*-promising and only 2 wei
settling. Raising the budget until the suite went green would have buried exactly that.

## 2026-09-10 (D10) — Three mutations, two of which I had already miscounted

The v4 guard shipped green and completely untested: deleting
`require(cost <= MAX_SLIPPAGE_WAD, ...)` from **both** adapters left 197/197 passing. Porting a fix
without porting the attack it answers produces code that looks defended and is not.

Worse, the first test written to close the second hole — that the bound reads `PRICE_REF` rather
than route spot — **passed under the mutation it existed to catch**. It compared two custodial
callbacks over what I thought was one position, but v4 keys a position by `owner: msg.sender`, so
the second callback owned nothing and its bound was zero for reasons having nothing to do with the
reference. Two numbers differed, the assertion held, and it proved nothing. It only surfaced because
the mutation was run rather than assumed. Moved to the NFT adapter, where two callbacks genuinely
share one `tokenId`, and it now fails as it must.

Second time this week a mutation has been too weak to catch its own target — the D9 licence check
was the first. The pattern in both: the test exercised the path I had in mind instead of the claim I
had made. **Check that a probe fails for the reason you intend, not merely that it fails.**
