# doubleQuote

Hackathon project (ETHGlobal, Uniswap track). A Midnight maker buy-callback that parks a
lender's capital in a Uniswap LP position instead of a Morpho Blue market, unwinding it
just-in-time when a fixed-rate offer is taken.

Built with [Foundry](https://book.getfoundry.sh/).

## Docs

- [`PLAN.md`](PLAN.md) — day-by-day schedule, submission checklist, ranked risks
- [`JOURNAL.md`](JOURNAL.md) — architectural decisions and the reasoning behind them
- [`FEEDBACK.md`](FEEDBACK.md) — Uniswap developer feedback (draft; edited from `FRICTION.log`)

## Layout

```
src/
  interfaces/   external interfaces (Midnight callback slot, price reference, ...)
  libraries/    shared math (sourcing/bound math, venue-agnostic)
  price-refs/   pluggable price reference implementations
test/
script/
```

## Usage

```shell
forge build
forge test
```
