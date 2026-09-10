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
between the quote and the block, which is what `PRICE_REF` exists for at D8. *(Confirmed on D7 —
that framing was right, and the loss is 61.86% of the fill.)*

## D7 — done

`test/SandwichV3.t.sol`, against a real `take()` on the deployed Midnight. **179/179.**

- **The number: a 5,000 USDC fill costs the maker 3,092.76 USDC, 61.86% of the fill.** The attacker
  takes 2,995.19 of it and the route pool's LPs take the remaining 97.57 in fees, for a 3,000 USDT
  round trip that ends holding the same USDT it started with.
- **The maker pays in liquidity, not in price.** `onBuy` must deliver `shortfall` or revert, so a
  residual that fetches less USDC does not settle for less — it burns more liquidity until the loan
  is covered. Honest burn 1,004,421,974,055; attacked burn 2,008,843,948,110, **exactly the
  escalation ceiling**, and it will be exactly the ceiling for any attack big enough to trigger
  escalation at all. D3's ceiling turns out to also be the cap on this attack's payout.
- **A spot-versus-reference guard would not have caught it, and that decides D8's shape.** The
  front-run displaces route spot by **7.70bp — inside the maker's 10bp budget**. The realised
  execution price deviates by **61.34%**, which is the number that matches the loss. D8 derives a
  `minOut` from `PRICE_REF` and checks the swap's actual output; it does not compare `slot0`.
- **D8 has under 2bp of slack.** The honest fill realises 8.13bp against the 10bp budget. The D8
  test has to assert both directions on one callback — honest fill still settles, attacked fill
  reverts — or it passes against a guard that refuses everything.
- **The exposure is a maker configuration, not a property of the design.** The identical attack
  routed through the deep 0.01% pool the position is parked in *loses* the attacker 0.56 USDC.
  The claim is "a callback routing through a venue an attacker can afford to move", and `ROUTE_POOL`
  is an immutable the maker picks. D11's frontier chart is where the safe depth ratio gets stated.
- **One harm D8 will not fix, kept as a standing test.** An attacker who never takes can move the
  route venue and make a quote read one block earlier unfillable: 3,000 USDT leaves the 9,838.85
  bound fillable, **6,000 kills it for a round-trip cost of 5.47 USDC**. It fails closed — no debt,
  no credit, position untouched — so it is censorship of the offer, not theft from it. No bound
  computed at block N can promise anything about block N+1. Limitations column, next to D5's
  off-range note.
- `MidnightMarketBase` split out of `MidnightIntegration.t.sol` so both take-driven suites share one
  market, ratifier and taker; `_routedCallback`/`_approve` moved down to `ParkedPositionBase`.

**Next:** D8 — `V3TwapRef` and the reference-relative bound in `onBuy`, then re-run this suite with
the assertions inverted. *(Done — the sandwich reverts and the attacker loses 2,998.04.)*

## D8 — done

`V3TwapRef` and a reference-relative cost guard in `onBuy`, live on v3. **191/191.**

- **The D7 attack fails closed.** The sandwiched settlement reverts at **44.60% cost against the
  maker's 10bp budget**; the maker's position, buffer and NFT are untouched, and the attacker who
  took 2,995.19 USDC on D7 now ends **−2,998.04**. Asserted in both directions on one callback —
  the honest fill of the same size on the same venue still settles.
- **The reference is expensive to move, and that is the number the guard rests on.** 100,000 USDT
  pushed through the pool `V3TwapRef` reads drags spot from tick 7 to **18,819**; the 30-minute mean
  stays on **7 exactly** in-block, drifts to 27 after one Base block, and converges on 18,819 over a
  full window.
- **The guard is cost over *sourced*, on the loan token actually received.** Not a `minOut` on the
  residual leg — that is twice as strict as the quote and would refuse fills `buyerAssetsBound` had
  just promised. Not `slot0` versus reference either, per D7.
- **The bisection moved from liquidity to fill size, which was a correctness fix.** `onBuy` sizes
  its burn from the fill through `liquidityForTarget`, margin included, so the old bound promised
  fills the executor would not honour: at exactly the quoted bound the thin venue realised 16.93bp
  against 10bp. Deep-venue answer unchanged to the wei (**19,871.458852**); thin v3 venue
  9,838.854693 → **9,817.764107**; v4 214.661289 → **214.128351**. Fewer iterations, not more.
- **Escalation is now unreachable within any legal budget on these venues.** A 2,400 USDT drain
  settles in one burn inside 10%; 2,500 costs 34.99%, and the budget ceiling is 10%. The mechanism
  stays for venue shapes with gradual depth; its test now isolates it behind a neutralised stub
  reference, and a paired test records the finding.
- **New rule, kept deliberately:** the bound never promises more than the residual is worth at the
  maker's own reference, even when the route venue would pay better.
- Mutation-checked, and one mutation exposed a hole worth having found: swapping the reference back
  for route spot — undoing the day's central change — failed one assertion by 0.9%, because the two
  agree on a quiet fork. Two library tests now separate them explicitly.

## D9 — done

The dust grief, measured; and licensing closed. **197/197.**

- **The bleed does not grow with the number of takes.** Fixing the grief volume at 2,000 USDC and
  splitting it 1 / 4 / 20 / 200 ways moves the maker's cost by **0.7%**, and not monotonically:
  0.131738 / 0.130993 / 0.130834 / 0.131258 USDC. It is 6.55bp of *volume* — the round-trip cost of
  the residual swap and nothing else. D3's linearity argument holds; the superlinear bleed D1
  worried about was D2's unconditional full unwind, and it is gone.
- **A funded buffer flattens it to exactly zero**, and defends exactly its own face value: funded
  with half the grief, take 11 of 20 is the first to touch the position. That is the buffer-sizing
  answer D3 deferred to today — hold what you expect to be taken in dust, no leverage, no formula.
- **The minimum fill size already exists and it is the slippage budget.** Smallest settling fill is
  9,977 wei at 1bp, 999 at 10bp, 102 at 100bp — inversely proportional, with one wei of rounding as
  the constant. **No configured minimum**, and the D3 reasoning now has a measurement under it.
- **The grief is uneconomic from the attacker's side.** One 10 USDC unbuffered take destroys 648 wei
  of maker value and costs 565,589 gas (forge 1.5.1; 586,929 on 1.8.1 — the assertion is a floor,
  not a pin, see `JOURNAL.md`). Breakeven is **0.00034 gwei**.
- **Licensing closed.** Root `LICENSE` (GPL-2.0-or-later, forced by the Morpho periphery fork), and
  `script/check-licenses.py` in CI inventorying the **build closure** — 64 dependency sources, of
  which **four are BUSL-1.1**, all reached behind MIT libraries (`StateLibrary`,
  `TransientStateLibrary`). Permitted: BUSL grants redistribution and non-production use outright.
  The check pins that set and fails when it changes. Risk #4 is retired.
  *(The first version of this check was one hop deep and claimed no BUSL reached the build at all —
  corrected same day, see `JOURNAL.md`.)*
- **D10's oracle source changed.** Uniswap's truncated-oracle example has been deleted from
  `v4-periphery`; `TruncatedOracleRef` will read OpenZeppelin's `uniswap-hooks` instead (MIT), whose
  adapter exposes the truncated series through a v3-shaped `observe()` — so it is `V3TwapRef`
  pointed elsewhere rather than a second implementation. See `JOURNAL.md`.
- Mutation-checked three ways, and one mutation is recorded rather than merely killed: deleting
  D3's escalation ceiling leaves every D9 test green, because D8's cost guard catches it *at 1bp*.
  At 100bp it does not, and the one-wei kill returns. The two defences overlap; they are not one.

## D10 — in progress

First half done: **the v4 fix, and the attack that proves it.** 201/201.

- **D8's cost guard ported to both v4 adapters**, bound and settlement. `SourcingMathLib.Sale` moved
  out of the v3 adapter to serve all three.
- **D7's sandwich ported to v4** (`SandwichV4.t.sol`, plus one on the non-custodial path). The
  unguarded twin burns **exactly twice** the honest liquidity — the escalation ceiling hit precisely,
  the same signature D7 measured on v3. Guarded, it fails closed and the position is untouched.
- **The finding: a budget has to cover the basis, not just the execution.** The reference venue and
  the route venue are **0.75bp apart while both sit at tick 7** — a tick is a basis point wide and a
  mean-tick reference is quantised to its boundary. A 1bp maker can only route on the venue they
  reference; v3 passes at 1bp because its route pool *is* its reference pool. v4 fixtures moved to
  10bp and a real `V3TwapRef` in place of a stub pinned at parity.
- **The v4 bound under-promises by 3.1%** (3,142.708391 quoted, 3,242.208926 settleable) — verified
  by bisection rather than re-pinned on faith. Safe direction; v3 stays exact.
- Three mutations, all now killed. Two of them initially survived, including a test that passed
  under the very mutation it was written for — see `JOURNAL.md`.

## Re-scoped 2026-09-10, with 8 days left and 3 days of slack

Reviewed what was built against what the submission actually needs, and moved the remaining effort
towards the demo and the two required artifacts.

**Cut:** `TruncatedOracleRef`, hook address mining, `MedianRef`, and the full frontier sweep. The
plan always said to cut from the right, and D10's first half produced a *better* oracle result than
the truncation comparison was going to — the 0.75bp tick-quantisation basis, which is a finding
about any `observe()`-derived reference rather than about one hook. Recorded as future work.

**The reason for the change:** both required submission artifacts were still D1 stubs. `FEEDBACK.md`
is 131 lines of pre-build speculation whose own header says it should not ship unverified, and one
of its six claims (the truncated-oracle sample being `UNLICENSED`) was disproved on D9 — the sample
has been deleted from `v4-periphery` entirely and the survivors are MIT. Meanwhile 23 real
`FRICTION.log` entries were waiting to replace guesses.

**The demo runs against a Base fork, not mainnet.** Deployment is not the constraint — priced at
live Base gas (0.006 gwei) the whole system costs **~$0.49** to deploy. Capital is: an end-to-end
mainnet demo needs a funded LP position and a taker holding cbBTC collateral, roughly $70 of real
money and a second funded address, for something nobody will interact with. A fork at `FORK_BLOCK`
binds the *real* deployed Midnight and the *real* pools with *real* liquidity, produces the same
numbers, costs nothing, and anyone can re-run it. A mainnet deploy of the factory and `V3TwapRef`
alone (~$0.10, no capital) remains available if the README wants a Basescan link.

**Revised again the same day, on the maker's steer: the demo runs on mainnet after all.** The
visual requirement is better served by real frontends — a Uniswap position page accruing fees, then
a Morpho lending position that did not exist a minute earlier — than by any page we could build. At
$10 a side that costs **$0.39 of gas** (measured, not estimated) and ~$46 of capital that comes back.
A fork script proves the logic; only mainnet proves it is real.

| | Deliverable | State |
|-----|-----|-----|
| **Demo** | `script/Demo.s.sol` + `DEMO.md` — four steps, four screenshots, real transactions | **done, unexecuted** |
| **Pre-flight** | `test/DemoPreflight.t.sol` — the demo's exact configuration on a fork | **done** |
| **`FEEDBACK.md`** | Rewritten from the 23 verified `FRICTION.log` entries | next |
| **README** | Claim → file → line table, so every claim is checkable | next |

### What the pre-flight found, before any money moved

- The bound at $10/side is **19.871711 USDC**, and a take of exactly that settles to the wei.
- **A round 10 USDC fill burns exactly half the position** — the thesis in one screenshot.
- `SelfTake()`: a maker cannot take their own offer, so the demo needs **two funded addresses**.
- A ratifier must be a **contract** — `address(0)` and an EOA are both refused. Hence
  `script/DemoRatifier.sol`, and a `FEEDBACK.md` note: a maker cannot participate in Midnight at all
  without deploying one.
- **`take` carries no signature.** An offer is a struct the taker supplies; the maker's consent is
  `setIsAuthorized` plus the NFT approval. There is no orderbook to publish to, which settles the
  open question about whether an unknown callback would be whitelisted — there is nothing to be
  whitelisted *by*.

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
| **D7** (Thu 10) | **The griefing test**, on v3 ✅. Attacker moves the pool, takes the offer, callback swaps into the manufactured price. Maker's loss: **61.86% of the fill**, paid in burnt liquidity at the escalation ceiling. Settles D8's shape — guard realised execution, not spot. |

## Week 2 — Fri 11 → Fri 18 Sep

| Day | Deliverable |
|-----|-------------|
| **D8** (Fri 11) | The fix on v3 ✅, a day early. `V3TwapRef` + a cost guard measured against it; the D7 sandwich reverts at 44.60% and the attacker ends **−2,998.04**. Also fixed a bound that promised fills the executor would not honour. |
| **D9** (Sat 12) | ✅ **Done, two days early.** Dust-take grief test — N repeated dust takes, bleed without the buffer, flat line with it. Also the decision point for a configured **minimum fill size**: deliberately skipped on D3 because the bleed is linear and the sourcing floor self-calibrates, so revisit only if the measured bleed contradicts that (see `JOURNAL.md`) — measured, and the decision stands. Licensing resolved: root `LICENSE`, a CI compliance check, and a new source of record for D10's oracle. |
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
4. ~~**Licensing.** `UNLICENSED` headers on the oracle sources conflict with an open-source
   submission. Resolve D9.~~ **Retired D9.** The repo carries a GPL-2.0-or-later `LICENSE`, CI
   pins the BUSL-1.1 files that reach the build, and the oracle source in question turned out to have
   been deleted from `v4-periphery` — D10 uses OpenZeppelin's MIT `uniswap-hooks` instead.
5. **Scope creep into writing a hook for the position itself.** Consuming an oracle hook is cheap
   and on-thesis; building one to hold liquidity is a different project. Resist.
6. **Yield accrual can't be shown live** on a weekly incentive cadence. Simulate or show
   historical.
7. **`FEEDBACK.md` and the form left to the last day.** `FRICTION.log` from D1, form submitted D13.
