# Zipcode frontend — built on top of euler-lite

**The Zipcode frontend is built on top of [euler-lite](https://github.com/euler-xyz/euler-lite)** — Euler's
open Nuxt 3 / Vue reference app. We do **not** build a frontend from scratch: euler-lite is the **canvas**, and
the Zipcode supply / zap / position / exit UI is **painted over it**, wired to the deployed Zipcode contracts.

## Get the canvas
`frontend/euler-lite/` is a clone of `euler-xyz/euler-lite` (its own `.git`, so it is **gitignored**; provenance
pinned in `reference/MANIFEST.md`). If it is not already present locally:
```bash
git clone https://github.com/euler-xyz/euler-lite.git frontend/euler-lite
git -C frontend/euler-lite checkout b4971171   # the pinned commit (reference/MANIFEST.md)
cd frontend/euler-lite && npm install && npm run dev   # Node 24+, npm
```

## What euler-lite gives us (the patterns to model, not rebuild)
- `pages/` — routes/screens (lending / borrowing / portfolio). The Zipcode screens slot in here.
- `composables/` — the reactive on-chain data hooks (wallet, positions, markets). Model the Zipcode
  position / NAV / queue hooks on these.
- `abis/` + `services/` + `entities/` — contract ABIs, the on-chain read/write services, and typed entities.
  The Zipcode contracts plug in here.
- wallet (Reown / AppKit), multi-chain config (`nuxt.config.ts`), tailwind.

## What to build (the Zipcode sweep)
The Zipcode-specific screens, painted over the euler-lite shell and bound to the deployed contracts:
- **Supply / zap** — USDC → zipUSD → szipUSD (`ZipDepositModule.zap`). The headline deposit.
- **Position / NAV** — szipUSD balance + NAV (`SzipNavOracle` navEntry/navExit), APR, utilization / freeze.
- **Exit** — the CoW-book exit + the senior par redemption queue (`ZipRedemptionQueue`).
- **(later)** originator / lien views.

## Where the contract surface is
- **`wires/`** (repo root) — the per-component wiring map: each contract's events + view methods + how it is
  wired. This is the binding surface the composables / services read. Start at `wires/README.md`.
- Contract **addresses + ABIs** come from the **item-10 deploy** (`contracts/script/DeployZipcode.s.sol`), so
  the live-data half of the UI is gated on that deploy.

## Status
This is the **deferred post-deploy frontend sweep** (built last, one dedicated pass) — no Zipcode UI is authored
yet. This note + the euler-lite canvas + `wires/` (the contract surface) are the starting point; the zap
interface intent (INFLOW-06) folds into this sweep.
