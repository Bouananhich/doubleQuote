# The demo

Ten dollars of USDC and ten of USDT go into a real Uniswap v3 position, where they earn fees. The
same capital simultaneously quotes a fixed-rate loan on Midnight. A taker fills the loan, and in a
**single transaction** the position unwinds just enough to cover it, the residual is sold, and the
loan settles. What is left keeps earning.

Every step below is a real transaction on Base. **Nothing is mocked.** The loan settles into
Midnight's live cbBTC/USDC market — 86% LLTV, the deployed `0x663BECd1…` oracle, maturing 25 December
2026 — and the offer is authorised by Morpho's own `EcrecoverRatifier`. Both transaction-sending
steps assert the market id against `0x9593c3a6…` before doing anything else, via an idempotent
`touchMarket` that costs ~12.8k gas against a market that already exists.

## What it costs

| | |
|---|---|
| Deployment | **$0.217** — paid, 7,728,429 gas at 0.0111 gwei (`forge`'s pre-flight estimate of 10,295,824 is padded) |
| Maker capital | ~$20 — 10 USDC + 10 USDT, returned when the position is closed |
| Taker capital | ~$26 of cbBTC collateral, returned when the loan is repaid |

## What is deployed

Live on Base, verified on Sourcify (full match — creation *and* runtime).

| | address | |
|---|---|---|
| `UniswapV3BuyCallback` | [`0x7D98Cad7E081A77b777E20b0e577722C1d647793`](https://basescan.org/address/0x7D98Cad7E081A77b777E20b0e577722C1d647793) | the callback Midnight calls at settlement |
| `UniswapV3BuyCallbackFactory` | [`0x4bf90d31c9521fBbC3b5b3B26Af22d5846D78a80`](https://basescan.org/address/0x4bf90d31c9521fBbC3b5b3B26Af22d5846D78a80) | CREATE2, salt `0` |
| `V3TwapRef` | [`0xE756307f1838f28FCD3B24BD78a923f8965A17e4`](https://basescan.org/address/0xE756307f1838f28FCD3B24BD78a923f8965A17e4) | 1800s `observe()` window on the USDC/USDT pool |
| `OfferDigest` | [`0x48410042BB5403B85628A4415CBe8e2f50D3f8c4`](https://basescan.org/address/0x48410042BB5403B85628A4415CBe8e2f50D3f8c4) | `view` helper, not part of the protocol |

The callback's immutables read back from chain as `OWNER` = the maker, `MIDNIGHT` = `0xAded…`,
`ROUTE_POOL` = the USDC/USDT 0.01% pool, `PRICE_REF` = `0xE756…`, and `MAX_SLIPPAGE_WAD` =
`0x5af3107a4000` = 1e14 = **1bp**. That column is the safety envelope (invariant 3) and it is worth
reading off the deployment rather than trusting the script.

**The deployed bytecode is the `via_ir` build.** `foundry.toml` scopes `via_ir` to
`lib/midnight/src/ratifiers/**`, but `Demo.s.sol` reaches `HashLib` through `OfferDigest`, which
pulls the script's whole compilation unit into the `midnight-ir` profile. The runtime code on Base
is byte-identical to `out/…/UniswapV3BuyCallback.midnight-ir.json` once the immutable slots are
masked, and differs from the default artifact — 14,225 bytes against 15,485. `DemoPreflight.t.sol`
imports the same path and therefore links the same artifacts, so the numbers below were produced by
the bytecode that is now on Base. The rest of the suite runs the default build. See `JOURNAL.md`.

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
export DEMO_EXPIRY=$(( $(date +%s) + 604800 ))      # 7 days
```

**Set `DEMO_EXPIRY` once and keep it for every step.** It is part of the offer, so a different value
is a different offer hash and the signature from step 4 will not verify at step 5. The script refuses
to default it for exactly that reason — an expiry derived from `block.timestamp` drifts between the
call that prints the digest and the transaction that uses it, and the demo would fail at the last
step, live. The market needs no such care: it is pinned in the script.

### Two things that will bite

**Never let `ETH_PASSWORD` reach a read-only step** — not via `.env`, and not via `export`.
Foundry auto-loads `.env` for *every* `forge` and `cast` invocation, and `ETH_PASSWORD` is the env
alias for `--password-file`, so the mere presence of a password path makes a command that signs
nothing refuse to run: *"the following required arguments were not provided: `--keystore`"*. A plain
`cast call` hits it, and so does `--sig "quote()"`, which is an `eth_call` against a `view`.

Pass it inline on the two steps that broadcast, and nowhere else:

```shell
ETH_PASSWORD="$HOME/.foundry/.demo-pass" forge script … --account maker --broadcast
```

`export ETH_PASSWORD=…` looks equivalent and is not — it poisons every later read in that shell.

**Send one transaction at a time, or pass `--nonce`.** Back-to-back `cast send`s against a hosted
endpoint raced its pending-nonce view here and failed with *"replacement transaction underpriced"*
followed by *"nonce too low"* — neither of which reached the chain, which is the confusing part.
`cast nonce "$DEMO_MAKER"` then an explicit `--nonce` is deterministic.

## Step 1 — the maker deploys

```shell
forge script script/Demo.s.sol --tc Demo --sig "deploy()" \
  --rpc-url "$BASE_RPC_URL" --account maker --sender "$DEMO_MAKER" --broadcast
```

**`--sender` is not optional.** `--private-key` sets the script's `msg.sender` to the derived
address; `--account` does not, so without it `setIsAuthorized(…, msg.sender)` runs as forge's
default sender and the step dies with Midnight's `Unauthorized()` — a protocol-shaped error for a
Foundry-shaped problem. See `FRICTION.log`.

Verification is a separate step because Basescan wants an API key and Sourcify does not:

```shell
forge verify-contract <address> <path>:<Name> --chain-id 8453 \
  --verifier sourcify --compilation-profile midnight-ir --constructor-args <args>
```

`--compilation-profile` is required — the build carries two profiles and the deployed artifact is
the `midnight-ir` one.

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
