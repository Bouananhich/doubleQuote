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

**Next, in order:**
1. Fork `BlueBuyCallbackIntegrationTest` — deferred from D1 on purpose. It needs a real offer taken
   against real Midnight, which is now finally possible.
2. Then D4 (v4 adapter) as scheduled.

**Open, needs a decision:** the repo has no root `LICENSE` file. The forked Morpho periphery is
GPL-2.0-or-later, so the derivative is too; the file headers already say so but the repo does not.

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
- [ ] **Port `bound.py` reasoning into a Solidity sketch.** *(`bound.py` recovered — present at the
      repo root but untracked, hence D1 reading it as missing. Commit it. The port itself is D5/D6.)*

---

## Week 1 — Fri 4 → Thu 10 Sep

| Day | Deliverable |
|-----|-------------|
| **D1** (Fri 4) | Public repo ✅, `FRICTION.log` started ✅, fork-Base harness green ✅. `UniswapBuyCallbackBase` skeleton + factory ✅. Blue's two unit suites forked ✅; the integration suite waits on the v3 adapter. |
| **D2** (Sat 5) | **v3 happy path** ✅. Park in the NFT position; `onBuy` does `decreaseLiquidity` then `collect`, swaps residual, approves Midnight, returns `CALLBACK_SUCCESS`. 16 green fork tests; custody settled non-custodial. |
| **D3** (Sun 6) | Loan-token buffer ✅ (landed D1) + partial unwind ✅. Only touch the LP when the buffer can't cover the fill, and then only for the fill's share. Fixes dust-grief bleed; costs ~18k gas rather than saving it. |
| **D4** (Mon 7) | **v4 happy path.** Whole unwind inside one `PoolManager.unlock()` — `modifyLiquidity`, swap residual, settle one netted delta. Naive `buyerAssetsBound` on both. |
| **D5** (Tue 8) | `SourcingMathLib` single-step version — exact for the stable pool, where a small residual never leaves the active tick range. Include the `max_share` liquidity cap. |
| **D6** (Wed 9) | Multi-tick walk (`TickBitmap` + `computeSwapStep`) for the volatile pool. Bisection on top. Cross-check against `bound.py` outputs. |
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
2. **The tick-walk implementation overruns D6.** Fallback: ship the single-step version plus a
   slippage guard, and present the multi-tick version as designed-but-unshipped, with `bound.py`
   as evidence it works.
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
