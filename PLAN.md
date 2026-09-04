# Plan

Two build weeks: **Fri 4 Sep → Fri 18 Sep 2026**. D1 is Fri 4 Sep.

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
- [ ] **Verify FairFlow's hook permission bits** exclude `beforeRemoveLiquidity`. Five minutes,
      and the venue choice rests on it.
- [ ] **Read:** Midnight whitepaper, `take()` lines 363–500, `BlueBuyCallbackIntegrationTest.sol`
      end to end. *(Partial: `BlueBuyCallback.sol`, `ICallbacks.sol` and the `Market` struct read
      and confirmed against the design notes. Whitepaper and `take()` outstanding.)*
- [x] **Pick the pools.** Both pinned in `test/ForkBase.sol` at block 50,875,000. Stable venue is
      USDC / **native USDT** (`0xfde4…9bb2`) 0.01% — ~50× deeper than the 0.05% pool. Stress venue
      is cbBTC/USDC 0.05%.
- [ ] **Port `bound.py` reasoning into a Solidity sketch.** ⚠️ `bound.py` is not in this repo — it
      needs recovering before D5/D6, since the cross-check depends on it.

---

## Week 1 — Fri 4 → Thu 10 Sep

| Day | Deliverable |
|-----|-------------|
| **D1** (Fri 4) | Public repo ✅, `FRICTION.log` started ✅, fork-Base harness green. Fork the three Blue callback tests into `UniswapBuyCallback*`. `UniswapBuyCallbackBase` skeleton + factory. |
| **D2** (Sat 5) | **v3 happy path.** Park in the NFT position; `onBuy` does `decreaseLiquidity` then `collect`, swaps residual, approves Midnight, returns `CALLBACK_SUCCESS`. One green fork test. |
| **D3** (Sun 6) | Loan-token buffer + partial unwind in the shared base. Only touch the LP when the buffer can't cover the fill. Fixes dust-grief bleed and common-case gas. |
| **D4** (Mon 7) | **v4 happy path.** Whole unwind inside one `PoolManager.unlock()` — `modifyLiquidity`, swap residual, settle one netted delta. Naive `buyerAssetsBound` on both. |
| **D5** (Tue 8) | `SourcingMathLib` single-step version — exact for the stable pool, where a small residual never leaves the active tick range. Include the `max_share` liquidity cap. |
| **D6** (Wed 9) | Multi-tick walk (`TickBitmap` + `computeSwapStep`) for the volatile pool. Bisection on top. Cross-check against `bound.py` outputs. |
| **D7** (Thu 10) | **The griefing test**, on v3. Attacker moves the pool, takes the offer, callback swaps into the manufactured price. Quantify the maker's loss. |

## Week 2 — Fri 11 → Fri 18 Sep

| Day | Deliverable |
|-----|-------------|
| **D8** (Fri 11) | The fix on v3: reference-relative bound in `onBuy` behind `IPriceRef`, first implementation `V3TwapRef`. Same D7 test, now reverting cleanly or filling honestly. |
| **D9** (Sat 12) | Dust-take grief test — N repeated dust takes, bleed without the buffer, flat line with it. **Resolve the oracle licensing question today**, before D10 depends on it. |
| **D10** (Sun 13) | Port grief + fix to v4; add `TruncatedOracleRef` with a seeded oracle pool in-fork. Hook address mining. Run the D7 attack against both references. |
| **D11** (Mon 14) | **The frontier chart** — sweep range width, plot fee APR against `buyerAssetsBound`. Plus gas benchmarks: v3 vs v4 vs `BlueBuyCallback`, buffer-hit and buffer-miss separately. |
| **D12** (Tue 15) | README with script-generated claim → file → line table. `FEEDBACK.md` edited from `FRICTION.log`. |
| **D13** (Wed 16) | Demo: park → yield accruing → taker fills → atomic unwind + settle in one tx, both venues, then the sandwich contrast. **Submit the Uniswap Developer Feedback Form today.** |
| **D14** (Thu 17) | Buffer. It will be needed. |

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
