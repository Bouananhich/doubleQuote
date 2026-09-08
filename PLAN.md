# Plan

Two build weeks: **Fri 4 Sep → Fri 18 Sep 2026**. D1 is Fri 4 Sep.

## Where things stand — end of D1

**Done:** public repo; `FRICTION.log` running; fork-Base harness green on a **single compiler
profile** (solc 0.8.34 / evm osaka, Base pinned at block 50,875,000); all Midnight and
Uniswap addresses verified on-chain; both parking venues chosen and pinned; FairFlow cleared for
parking; CI green. Plus, second half of D1:

- `UniswapBuyCallbackBase` (abstract) + `UniswapBuyCallbackFactoryBase` (abstract) +
  `IMidnightBuyCallback` / `IPriceRef` / `IUniswapBuyCallbackFactory`, forked from
  `lib/midnight/src/periphery/blue-buy-callback/` (GPL-2.0, safe to fork — core is BUSL-1.1 and
  must not be vendored). Four deliberate divergences from Blue, all in `JOURNAL.md`.
- Blue's two unit suites forked onto the base and the factory: **36/36 green** in ~0.4s. Base and
  factory tests need no fork, so only `ForkSanity` hits the network.
- The buffer landed early, in the base rather than at D3 — it fixes the signature of
  `_sourceLoanToken` (shortfall, not total), which both adapters implement.

## D2 — done

`UniswapV3BuyCallback` + `UniswapV3BuyCallbackFactory`, green against a real position minted in the
real USDC/USDT 0.01% pool on the Base fork. **52/52** suite-wide.

- **Custody settled, non-custodial.** The maker keeps the NFT and approves the callback for the
  `tokenId`; `ownerOf` is asserted unchanged *after* a full unwind. The D1 leaning is confirmed,
  not reversed.
- **`lib/v4-core` added** for `SqrtPriceMath` / `TickMath` / `FullMath`, all `^0.8.0`, none of them
  reaching the `0.8.26`-pinned `PoolManager`. Still one compiler profile. `SourcingMathLib` seeded
  with the naive bound.
- **Measured:** a 10k+10k position unwinds to 19,871.46 USDC; the residual swap costs 8.5bp, 1bp of
  which is the pool fee. That is the number D8 has to beat.
- Park and route proven independent — a callback routing through cbBTC/USDC rejects a swap callback
  from the pool its position is parked in.

## D3 — done

Sized partial unwind. **77/77.**

- `SourcingMathLib.liquidityForTarget` sizes the burn as a single proportion — amounts are exactly
  linear in liquidity — plus a 25bp impact margin. The library now has fork-free unit tests.
- **The margin is load-bearing.** Without it the spot-and-fee estimate is so nearly exact (0.2bp)
  that every fill came up short, hit the fallback and drained the position anyway, at 479k gas. All
  tests still passed, because the D2 assertions encoded the old full-unwind behaviour. See
  `JOURNAL.md`.
- **Correction to this plan:** partial unwind *costs* ~18k gas (304k → 322k for a 5k fill). What it
  buys is the maker's position surviving the fill. The common-case gas win is the buffer, which
  landed on D1.
- Dust-take defence verified: 20 consecutive dust takes never touch a position with a funded
  buffer. It does require the buffer to be funded — a maker policy, not automatic.

## The Midnight integration suite — done (7 Sep)

`test/MidnightIntegration.t.sol`. The D1 deferral, closed: a real offer taken against the **deployed
Midnight on Base**, sourced out of a real v3 position. **87/87.**

- Park → offer → take → atomic unwind + settle, in one transaction on the taker's gas. The maker
  keeps the NFT, ~75% of the position survives a 25% fill, and the surplus lands in the buffer,
  where a second take of 10 USDC is served without touching Uniswap at all.
- Binding the deployed instance rather than deploying one (as upstream does) immediately surfaced
  constraints a self-configured test would have missed — `tickSpacingSetter` is `address(0)`, so
  markets keep spacing 4 and offer ticks must divide by it. See `JOURNAL.md`.
- **Measured: the naive bound over-promised by 0.63bp** (19,872.71 quoted vs 19,871.46 sourceable).
  *Resolved on D5, and against expectation* — the single-step bound is exact to the wei here, and
  the reading that "the stable venue leaves D5 nothing to win" was wrong. See the D5 section.
- Upstream's other two tests are Blue-specific (bound capped by available liquidity, by Blue's
  balance under a flash loan). The v3 analogue of the first is already in
  `UniswapV3BuyCallback.t.sol`; the second has no counterpart.

## D4 — done, and larger than planned

**Both v4 custody modes shipped.** `UniswapV4BuyCallback` (custodial, direct on `PoolManager`),
`UniswapV4NftBuyCallback` (non-custodial, `PositionManager` NFT), a shared
`UniswapV4BuyCallbackBase`, and a factory each. **121/121.**

v4 forces a choice v3 did not: `modifyLiquidity` keys positions by `msg.sender`, and `unlock`
reverts `AlreadyUnlocked` when nested, so one-unlock netting and non-custodial parking are mutually
exclusive. Building only one would have made the gas table compare custody models and call the
difference "v4". Full reasoning in `JOURNAL.md`.

- **The netting difference is measured, not asserted.** Residual ERC-20 transfers touching the
  callback during one settlement: **0** custodial, **2** through the NFT path. Gas on the same 500
  USDC fill: **296,485** vs **352,065**.
- **v4 USDC/USDT is 724x thinner than v3** at this block — 5.43e11 against 3.93e14, same pair, same
  fee tier, same tick. The v4 fixtures park 2k+2k and fill in the hundreds because that is what the
  venue absorbs. D11's table has to say so or it compares trades rather than plumbing.
- Native currency is refused at deployment and at parking on both adapters. It costs the ETH pools,
  which are v4's deepest. A stated limitation, not an oversight.
- The `PositionManager` interface is hand-written (v4-periphery would drag in a second compiler
  profile) and asserted against the deployment rather than trusted.

**Cost:** this ran past the one day D4 had, as flagged before starting. It comes out of slack; if it
reaches D5, the tick walk is what gives, per risk #2.

**Open, needs a decision:** the repo has no root `LICENSE` file. The forked Morpho periphery is
GPL-2.0-or-later, so the derivative is too; the file headers already say so but the repo does not.

## D5 — done

`SourcingMathLib.boundBySlippage`: simulate the unwind, bisect on how much liquidity to burn, subject
to the slippage budget. Live on all three adapters. **145/145.**

- **The bound is exact where the single step is valid.** Against a real `take()` on the deployed
  Midnight, the quote is 19,871.458852 USDC and the largest settleable fill is 19,871.458852 —
  headroom **zero, to the wei**, pinned in both directions (`bound` fills, `bound + 1` reverts).
  That holds while the residual swap stays inside the route venue's active tick range. Routing the
  same position through the thinner 0.05% pool, where it does not, the bound **over-promises by
  25.33%** — see the review section below.
- **The D4 caveat was the wrong reading.** "The naive bound is already within 0.63bp, so D5 has
  little to win" mistook *near* for *correct*. A 0.63bp optimistic bound hands a taker a reverted
  transaction; the routing layer is asynchronous by construction, which is why the bound exists.
- **v4 is where it bites.** The parked 2k+2k is **59.24% of that pool's active liquidity**, so the
  active-share cap binds *and* the 1bp budget cuts the quote to **245.21 USDC** against ~3,950 of
  paper value. Same pair, same fee tier, opposite answer from v3 — depth relative to the maker is
  the whole variable, and that contrast is the demo.
- Both `bound.py` findings implemented rather than approximated, and both had to be *generalised*:
  park and route are independently chosen here, so a burn thins the route venue only when it is the
  same pool and in range. `bound.py` models one pool and could assume it.

### D5 review — one bug fixed, one limitation measured

Review comment: `routeIsParkVenue=false` was covered in the library's unit tests but never through a
real adapter. Closing that found both of the following. **155/155.**

- **Bug, fixed.** A callback routing through a 5bp venue under a 1bp budget has no honest bound at
  any size — a fee is proportional. It quoted **1 wei**, because at dust `dL` the residual and then
  its spot valuation both round to zero, so the modelled cost vanished and the bisection took the
  one size that looked free. `onBuy(1)` reverted while `onBuy(2)` settled: wrong in both directions
  at once. `sourcedFor` now refuses a residual it cannot price and floors the cost at the venue fee.
- **Limitation, measured and pinned.** Off-range the bound **fails open by 25.33%** (19,854.752510
  quoted, 14,824.408869 settleable) on the 0.05% route pool, because the single step assumes active
  liquidity continues past the ticks the swap actually crosses.

## D6 — done

`SourcingMathLib.multiStepOut` walks the route venue's initialized ticks with
`SwapMath.computeSwapStep`; `TickBookLib` reads the book once, in the direction the residual travels,
and hands it over as a flat array. Live on all three adapters. **175/175.**

- **The fail-open case is closed.** Same position, same 10bp budget, routed through the thin 0.05%
  pool: the single step quoted **19,854.752510** and that reverted; the walk quotes
  **9,838.854693** and it settles.
- **And it cost nothing where the model was already right.** On the 0.01% pool the answer is
  unchanged to the wei — 19,871.458852, still exact against a real `take()` on deployed Midnight.
- **The bound is now a solvency limit as well as a slippage limit.** The remaining gap to
  14,824.408869, the largest fill that technically settles, is not headroom: that pool's whole book
  above spot is eight ticks and its liquidity is spent by the last of them, so those fills go
  through only by selling the residual into an empty pool. Widening the budget from 10bp to 5% does
  not move the quote by a wei — what binds is the book.
- Read once and bisect over it, rather than walking inside the swap: `boundBySlippage` evaluates the
  residual up to 128 times, so this is `O(ticks)` instead of `O(ticks × 128)`, and `SourcingMathLib`
  stays `pure` and venue-agnostic. The two venue-specific reads are passed in as function pointers.
- ~3.0KB of runtime per adapter, all of it in the view. `onBuy` is untouched.

**Review:** the walk had a fallback for an empty book that reopened the fail-open it was written to
close — `readBook` returns an empty array for a venue too sparse to read, and the fallback then
assumed liquidity continued forever, which is the pre-D6 model on exactly the venues D6 exists for.
Removed: unreadable is unquotable. The bitmap search also gained the direct unit tests it should
have had — it is arithmetic copied by hand from a library that cannot be called from outside a
pool, and it was only being checked several layers downstream by a fork test. A second round found
that **deleting the walk outright left all 38 v4 tests green**: v4's quotes were asserted as ranges,
so the crossing they do exercise was never pinned. Now exact — 214.661289 against the single step's
245.214731, a 14.23% gap that on v4 is a budget breach rather than a revert.

**Next:** D7 — the griefing test on v3. Note that D6 changed what it is testing against: the bound
now refuses to quote a fill the route venue cannot absorb, so an attacker who moves the pool is
attacking a quote that already knows how deep the book is. The loss to quantify is what happens
between the quote and the block, which is what `PRICE_REF` exists for at D8.

Build order is **v3 first, v4 second, both shipped**. v3 is load-bearing — its native
`observe()` makes the price-reference work straightforward. If a day goes missing, v4 is cut,
never v3.

---

## Prep (not done — carried into D1)

The prep window (Mon 31 Aug → Thu 3 Sep) was not used. These are prerequisites, not optional:

- [x] **Fork harness spike.** One Foundry profile on 0.8.34 / osaka, forking Base, `setUp()`
      binding deployed Midnight, a v3 pool + `NonfungiblePositionManager`, and v4 `PoolManager`
      + `PositionManager` **through interfaces only**. Should need no second compiler profile.
      *Kill-switch not needed — green on D1, single profile, 8/8 in 3.7s.*
- [x] **Confirm Base supports the Osaka opcodes** Midnight relies on (`clz`) at the fork block.
      Midnight is deployed and live on Base compiled at osaka, and `clz` is exercised directly in
      the fork by `ClzProbe` in `test/ForkSanity.t.sol`.
- [x] **Verify FairFlow's hook permission bits** exclude `beforeRemoveLiquidity`. Confirmed from
      the address bits (`0x00C4` = `beforeSwap`, `afterSwap`, `afterSwapReturnsDelta` only), the
      `Uniswap/hooklist` entry, and Kyber's own description. Parking is ungated; routing through it
      is impossible (signed `quoteSigner` quotes). Park/route/reference stay separate.
- [ ] **Read:** Midnight whitepaper, `take()` lines 363–500, `BlueBuyCallbackIntegrationTest.sol`
      end to end. *(Partial: `BlueBuyCallback.sol`, `ICallbacks.sol` and the `Market` struct read
      and confirmed against the design notes. Whitepaper and `take()` outstanding.)*
- [x] **Pick the pools.** Both pinned in `test/ForkBase.sol` at block 50,875,000. Stable venue is
      USDC / **native USDT** (`0xfde4…9bb2`) 0.01% — ~50× deeper than the 0.05% pool. Stress venue
      is cbBTC/USDC 0.05%.
- [x] **Port `bound.py` reasoning into a Solidity sketch.** Done on D5 for the single-step half:
      `boundBySlippage`, both findings, and the bisection. The tick walk is D6.

---

## Week 1 — Fri 4 → Thu 10 Sep

| Day | Deliverable |
|-----|-------------|
| **D1** (Fri 4) | Public repo ✅, `FRICTION.log` started ✅, fork-Base harness green ✅. `UniswapBuyCallbackBase` skeleton + factory ✅. Blue's two unit suites forked ✅; the integration suite landed 7 Sep ✅. |
| **D2** (Sat 5) | **v3 happy path** ✅. Park in the NFT position; `onBuy` does `decreaseLiquidity` then `collect`, swaps residual, approves Midnight, returns `CALLBACK_SUCCESS`. 16 green fork tests; custody settled non-custodial. |
| **D3** (Sun 6) | Loan-token buffer ✅ (landed D1) + partial unwind ✅. Only touch the LP when the buffer can't cover the fill, and then only for the fill's share. Fixes dust-grief bleed; costs ~18k gas rather than saving it. |
| **D4** (Mon 7) | **v4 happy path.** Whole unwind inside one `PoolManager.unlock()` — `modifyLiquidity`, swap residual, settle one netted delta. Naive `buyerAssetsBound` on both. |
| **D5** (Tue 8) | `SourcingMathLib` single-step version ✅ — exact to the wei on the stable pool against a real `take()`. `max_share` cap included, and it binds on v4. |
| **D6** (Wed 9) | Multi-tick walk ✅ — `TickBookLib` + `computeSwapStep`, bisection on top. The +25.33% fail-open on a thin route venue is gone; the deep venue is unchanged to the wei. |
| **D7** (Thu 10) | **The griefing test**, on v3. Attacker moves the pool, takes the offer, callback swaps into the manufactured price. Quantify the maker's loss. |

## Week 2 — Fri 11 → Fri 18 Sep

| Day | Deliverable |
|-----|-------------|
| **D8** (Fri 11) | The fix on v3: reference-relative bound in `onBuy` behind `IPriceRef`, first implementation `V3TwapRef`. Same D7 test, now reverting cleanly or filling honestly. |
| **D9** (Sat 12) | Dust-take grief test — N repeated dust takes, bleed without the buffer, flat line with it. Also the decision point for a configured **minimum fill size**: deliberately skipped on D3 because the bleed is linear and the sourcing floor self-calibrates, so revisit only if the measured bleed contradicts that (see `JOURNAL.md`). **Resolve the oracle licensing question today**, before D10 depends on it. |
| **D10** (Sun 13) | Port grief + fix to v4; add `TruncatedOracleRef` with a seeded oracle pool in-fork. Hook address mining. Run the D7 attack against both references. |
| **D11** (Mon 14) | **The frontier chart** — sweep range width, plot fee APR against `buyerAssetsBound`. Plus gas benchmarks: v3 vs v4 vs `BlueBuyCallback`, buffer-hit and buffer-miss separately. |
| **D12** (Tue 15) | README with script-generated claim → file → line table. `FEEDBACK.md` edited from `FRICTION.log`. |
| **D13** (Wed 16) | Demo: park → yield accruing → taker fills → atomic unwind + settle in one tx, both venues, then the sandwich contrast. **Submit the Uniswap Developer Feedback Form today.** |
| **D14** (Thu 17) | Buffer. It will be needed. |

---

## Open decisions

### The Graph as a routing layer — undecided, costs a day

Full reasoning in `JOURNAL.md` (2026-09-04, "The Graph: routing layer, not `IPriceRef`").
Settled part: **it cannot back `IPriceRef`** and that is not reopenable — a subgraph is
unreachable from an `external view`, and bridging it via Chainlink would add exactly the
push-oracle trust assumption the sandwich demo exists to attack. `V3TwapRef` stays the production
reference.

Open part: whether to build a subgraph as the **taker-side routing layer**. It is on-thesis —
Morpho's own `buyerAssetsBound` docstring says takers get their amount from a routing layer that is
"asynchronous/offchain, and might not be up to date", and the bound exists to cap against it. The
project currently has no routing layer, so the demo only shows the settlement half. It is also
the natural home for the D11 frontier chart and for the historical yield accrual that risk #6 says
cannot be shown live. Qualifies for a second hackathon track.

Cost is roughly one day (subgraph + thin query layer). **If taken, it comes out of either the v4
adapter or the `TruncatedOracleRef` comparison — decide which before starting, not during.**
Ranked preference if forced to choose: cut `TruncatedOracleRef` first (risk #3 already says to
timebox the oracle work and cut from the right), keep v4, since the v3-vs-v4 gas table is the
artifact aimed squarely at a Uniswap judge.

---

## Submission checklist

- [ ] Public GitHub repo, open source — **done D1, not D13**
- [ ] `FEEDBACK.md`, linked from the Uniswap Developer Feedback Form at
      `developers.uniswap.org/hackathon-feedback`
- [ ] README pointing to specific contracts and line ranges so the integration is verifiable
      (script-generated on D12 so the line numbers are correct)

---

## Risks, ranked

1. **Two venues doubles the surface.** Mitigated by the abstract base + shared math lib. If the
   adapters share less than ~two-thirds of their logic, the abstraction is wrong and v4 should be
   dropped rather than forced.
2. ~~**The tick-walk implementation overruns D6.**~~ **Retired — shipped on D6.** Recorded for the
   post-mortem: the risk was ranked second because the walk looked like the expensive, optional
   half. It was neither. It came in inside the day, and it was not optional — the single step
   failed *open* by 25.33% on a thin route venue, which is the one direction a bound may not err
   in. The fallback this entry proposed, "ship the single step plus a slippage guard", was the
   wrong fallback: the slippage guard was already there and it was what got fooled.
3. **The oracle work becomes a rabbit hole.** Timebox hard. `V3TwapRef` must exist;
   `TruncatedOracleRef` makes the comparison interesting; `MedianRef` is decoration. Cut from the
   right. Budget half a day for hook address mining.
4. **Licensing.** `UNLICENSED` headers on the oracle sources conflict with an open-source
   submission. Resolve D9.
5. **Scope creep into writing a hook for the position itself.** Consuming an oracle hook is cheap
   and on-thesis; building one to hold liquidity is a different project. Resist.
6. **Yield accrual can't be shown live** on a weekly incentive cadence. Simulate or show
   historical.
7. **`FEEDBACK.md` and the form left to the last day.** `FRICTION.log` from D1, form submitted D13.
