# Zipcode frontend

The Zipcode frontend is the app in **[`./zipcode-finance-euler/`](./zipcode-finance-euler)** — the team's skinned
borrower/lender UI (`github.com/resi-labs-ai/zipcode-finance-euler`). It is a thin Nuxt **layer on top of**
[euler-lite](https://github.com/euler-xyz/euler-lite) (Euler's open Nuxt 3 / Vue reference app), which it vendors as a
git submodule at `zipcode-finance-euler/euler-lite/`. We do not build a frontend from scratch: euler-lite is the
engine, and the Zipcode screens + branding are layered over it.

This is its own project with its own GitHub home (resi-labs-ai). It lives here next to the contracts for local
development; frontend work is committed and pushed to **that** repo, not the `zipcode-euler` monorepo.

## Run it

```bash
cd zipcode-finance-euler
git submodule update --init --recursive   # pull the euler-lite engine (one-time)
npm install
npm run dev
```

To point it at the **local anvil** protocol (Base fork, chainId 8453, `http://127.0.0.1:8545`) instead of live Base,
see ticket **FE-00** in `../../build/tickets/PROGRESS.md` for the `.env` repoint (`RPC_URL_8453`, on-chain vault
source, local labels). euler-lite's data layer is fully env-driven — nothing is hardwired to mainnet.

## What's where

- `zipcode-finance-euler/euler-lite/` — the engine (submodule, kept pristine; never edit it).
- `zipcode-finance-euler/components/zipcode/`, `pages/{borrower,lender,prototype}/`, `lib/zipcode/` — the Zipcode UI.
  Today these are a clickable mockup fed by `lib/zipcode/store.ts`; the FE-01..07 tickets wire them to the live
  anvil contracts.
- `zipcode-finance-euler/nuxt.config.ts` — the layer wiring (`extends: ['./euler-lite']`, aliases, brand CSS).

## The contract surface it binds to

- **Live anvil address board:** `../../build/anvil/contract-map.md`
- **ABIs:** `../../build/anvil/abi/` (`index.json` resolves address → ABI)
- **Build queue:** the `Frontend ↔ anvil` track (FE-00..07) in `../../build/tickets/PROGRESS.md`
