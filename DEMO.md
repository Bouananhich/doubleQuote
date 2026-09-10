# The demo

Ten dollars of USDC and ten of USDT go into a real Uniswap v3 position, where they earn fees. The
same capital simultaneously quotes a fixed-rate loan on Midnight. A taker fills the loan, and in a
**single transaction** the position unwinds just enough to cover it, the residual is sold, and the
loan settles. What is left keeps earning.

Every step below is a real transaction on Base. **Nothing is mocked.** The loan settles into
Midnight's live cbBTC/USDC market — 86% LLTV, the deployed `0x663BECd1…` oracle, maturing 25 December
2026 — and the offer is authorised by Morpho's own `EcrecoverRatifier`. The market id is asserted
against `0x9593c3a6…` at every step rather than trusted.

## What it costs

| | |
|---|---|
| Deployment | **~$0.36** — measured, 10,295,209 gas at 0.0103 gwei |
| Maker capital | ~$20 — 10 USDC + 10 USDT, returned when the position is closed |
| Taker capital | ~$26 of cbBTC collateral, returned when the loan is repaid |

## What was pre-flighted

`test/DemoPreflight.t.sol` runs **this exact configuration** against a Base fork. It is worth
reading before spending anything, because the rest of the suite parks $10,000 a side and $10 is a
different regime.

| | |
|---|---|
| `buyerAssetsBound` at $10/side | **19.871711 USDC** — and a take of exactly that settles, to the wei |
| A round 10 USDC fill | burns **exactly 50%** of the position |
| A signed offer via `EcrecoverRatifier` | **settles** — 10 USDC, through Morpho's deployed contract |
| Maker taking their own offer | refused, `SelfTake()` — **two funded addresses are required** |
| `ratifier = address(0)` | refused, `RatifierUnauthorized()` |
| An EOA as ratifier | refused — a ratifier must be a contract |

The 50% number is the one to show: half the LP settles the loan, half stays in the pool earning.

## How an offer is actually authorised

`take` has no signature *parameter*, which is misleading at first glance. Offers **are** signed: the
signature travels in `ratifierData` and is checked by the ratifier the offer names. Morpho operates a
canonical one, **`EcrecoverRatifier` at `0xd6e70365C8E8DDa9a4ca662C07bbE663b017755E`** on Base, so
this demo deploys no authorisation contract of its own.

The scheme signs a **Merkle root of offers**, so one signature can authorise a whole book and
`cancelRoot` retires it in a single transaction. A single offer is the degenerate case: empty proof,
`leafIndex` 0, root equal to the offer hash. `test/DemoPreflight.t.sol` proves a signed offer settles
through the deployed ratifier against a Base fork.

**There is a public orderbook.** Morpho indexes offers and the app renders the depth; the REST API at
`https://api.morpho.org/v0/midnight/` serves `/markets` and `/books`. Because the offer this demo
produces is a *standard* signed Midnight offer, it is publishable in principle — whether the Router's
mempool rules index one naming an unknown callback is an open question, and worth probing as part of
the demo since the answer is `FEEDBACK.md` material either way.

Settlement does not depend on any of that. As Morpho's own limit-order POC puts it, "a signed
Midnight offer is an offchain object and can be passed directly to `Midnight.take`; API publication
and discovery are not prerequisites for settlement."

## Setup

```shell
export BASE_RPC_URL=...            # or leave unset for the public endpoint
export DEMO_MAKER=0x...            # holds 10 USDC + 10 USDT + a little ETH
export DEMO_TAKER=0x...            # holds ~0.0003 cbBTC + a little ETH
```

The market is pinned in the script, so there is no maturity to keep in sync.

## Step 1 — the maker deploys

```shell
forge script script/Demo.s.sol --tc Demo --sig "deploy()" \
  --rpc-url "$BASE_RPC_URL" --account maker --broadcast --verify
```

Export the four addresses it prints (`DEMO_OFFER_DIGEST`, `DEMO_PRICE_REF`, `DEMO_FACTORY`,
`DEMO_CALLBACK`). It also authorises `EcrecoverRatifier` to speak for the maker.

`OfferDigest` is a `view` helper that returns what a maker has to sign. It exists because the
ratifier computes that digest internally and offers no way to ask it — see `FRICTION.log`.

## Step 2 — the maker parks

```shell
forge script script/Demo.s.sol --tc Demo --sig "park()" \
  --rpc-url "$BASE_RPC_URL" --account maker --broadcast
```

Mints the position, approves the callback for the NFT, and creates the market. Export
`DEMO_TOKEN_ID`.

> **📸 Screenshot 1 — the capital is working.**
> Open the position on Uniswap: `https://app.uniswap.org/positions/v3/base/$DEMO_TOKEN_ID`.
> Twenty dollars of liquidity, in range, fees accruing. Leave it a while and the fees tick up.
> DeBank on `$DEMO_MAKER` shows the same thing as a portfolio line.

## Step 3 — what the same capital is quoting

```shell
forge script script/Demo.s.sol --tc Demo --sig "quote()" --rpc-url "$BASE_RPC_URL"
```

Free — `buyerAssetsBound` is a `view`, so this is an `eth_call`. **This is the project**: the number
it prints is the largest loan this LP position can settle within the maker's slippage budget, and
the position is earning Uniswap fees the entire time it is being quoted.

> **📸 Screenshot 2 — two order books, one pile of capital.**
> The Uniswap position page and this number, side by side.

## Step 4 — the maker signs the offer

```shell
forge script script/Demo.s.sol --tc Demo --sig "digest()" --rpc-url "$BASE_RPC_URL"
cast wallet sign --account maker --no-hash <the digest it printed>
export DEMO_SIGNATURE=<the 65-byte signature>
```

The private key never enters a script process — the script prints a digest, `cast` signs it.

What is being signed is a **Merkle root of offers**, so one signature can authorise a whole book and
`cancelRoot` retires all of it in one transaction. A single offer is the degenerate tree.

> At this point the offer is a complete, standard, signed Midnight offer. Everything after this is
> somebody choosing to fill it.

## Step 5 — the taker fills it

```shell
forge script script/Demo.s.sol --tc Demo --sig "take()" \
  --rpc-url "$BASE_RPC_URL" --account taker --broadcast
```

> **📸 Screenshot 3 — the atomic unwind.**
> Open the transaction on Basescan. In **one** transaction: liquidity burnt, fees collected, the
> USDT leg swapped for USDC, and the loan settled on Midnight. The taker walks away with USDC and
> a fixed-rate debt; the maker's LP shrank by exactly what it took to pay for it.

> **📸 Screenshot 4 — the position is now two things.**
> Uniswap shows the position at roughly **half** its liquidity, still in range, still earning.
> `https://app.morpho.org/base/address/$DEMO_MAKER` shows the fixed-rate lending position that did
> not exist a minute ago.

## Optional — publish it to the orderbook

Morpho indexes offers and the app renders the depth (`https://api.morpho.org/v0/midnight/books`).
Because step 4 produces a standard signed offer, it is publishable in principle — and whether the
Router's mempool rules will index one naming an **unknown callback** is genuinely unknown.

Try it *after* the demo has been shown to work, never before: the self-take path above always
settles, and this one depends on somebody else's validation rules. Either outcome is worth having.
If it indexes, the demo gains a screenshot of our offer sitting in Morpho's own depth chart. If it
is refused, that is a sharper finding for `FEEDBACK.md` — a callback-backed offer being invisible to
the public orderbook is exactly the kind of thing the Uniswap track's feedback form is asking about.

> ⚠️ A published offer is publicly takeable by anyone, at the terms signed. That is the point, but
> it means step 4's offer should be sized as something you are happy for a stranger to fill.

## Optional — the attack, on the same deployment

`test/SandwichV3.t.sol` runs against a fork rather than mainnet, for the obvious reason that the
attack costs the attacker 2,998 USDC to attempt. It is worth showing on screen next to the demo:
the same fill, sandwiched, is refused at **44.60%** against the maker's budget, and the maker's
position is untouched to the wei.

## Cleaning up

The maker closes the Uniswap position; the taker repays and withdraws the collateral. Both sides get
their capital back, less the fees the position earned, which the maker keeps.
