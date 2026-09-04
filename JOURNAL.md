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
