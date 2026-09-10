# The demo

Ten dollars of USDC and ten of USDT go into a real Uniswap v3 position, where they earn fees. The
same capital simultaneously quotes a fixed-rate loan on Midnight. A taker fills the loan, and in a
**single transaction** the position unwinds just enough to cover it, the residual is sold, and the
loan settles. What is left keeps earning.

Every step below is a real transaction on Base against the deployed Midnight and the real
USDC/USDT pool. Nothing is mocked except the collateral oracle, which is a fixed price and says so.

## What it costs

| | |
|---|---|
| Deployment | **~$0.39** — measured, 11,086,289 gas at 0.0103 gwei |
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
| Maker taking their own offer | refused, `SelfTake()` — **two funded addresses are required** |
| `ratifier = address(0)` | refused, `RatifierUnauthorized()` |
| An EOA as ratifier | refused — a ratifier must be a contract, hence `script/DemoRatifier.sol` |

The 50% number is the one to show: half the LP settles the loan, half stays in the pool earning.

## Two things worth understanding first

**`take` carries no signature.** An offer is a plain struct the taker supplies. The maker's consent
is `setIsAuthorized(ratifier, true, maker)` plus the NFT approval — nothing is signed and nothing is
posted. "Publishing an offer" means letting someone see the struct, which is why Midnight's own docs
say offers "circulate through external channels".

**So the offer will not appear in anyone's UI.** There is no orderbook to submit to. The taker step
below is a CLI call because that is what taking an offer *is*, not because we are working around
something.

## Setup

```shell
export BASE_RPC_URL=...            # or leave unset for the public endpoint
export DEMO_MAKER=0x...            # holds 10 USDC + 10 USDT + a little ETH
export DEMO_TAKER=0x...            # holds ~$26 of cbBTC + a little ETH
export DEMO_MATURITY=$(( $(date +%s) + 2592000 ))   # 30 days
```

Keep `DEMO_MATURITY` **exactly the same for every step** — it is part of the market identity, and a
different value is a different market.

## Step 1 — the maker deploys

```shell
forge script script/Demo.s.sol --tc Demo --sig "deploy()" \
  --rpc-url "$BASE_RPC_URL" --account maker --broadcast --verify
```

Export the five addresses it prints (`DEMO_ORACLE`, `DEMO_RATIFIER`, `DEMO_PRICE_REF`,
`DEMO_FACTORY`, `DEMO_CALLBACK`).

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

## Step 4 — the taker fills it

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

## Optional — the attack, on the same deployment

`test/SandwichV3.t.sol` runs against a fork rather than mainnet, for the obvious reason that the
attack costs the attacker 2,998 USDC to attempt. It is worth showing on screen next to the demo:
the same fill, sandwiched, is refused at **44.60%** against the maker's budget, and the maker's
position is untouched to the wei.

## Cleaning up

The maker closes the Uniswap position; the taker repays and withdraws the collateral. Both sides get
their capital back, less the fees the position earned, which the maker keeps.
