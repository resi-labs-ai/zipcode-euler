# supply/ review — starting prompt (next window)

> Paste-ready opening brief for a fresh session. Written 2026-06-12 at the close of the 8x-01
> bridge-rework session, which is the direct upstream of everything below.

## Mission

Audit `contracts/src/supply/` — the money-moving spine of the protocol — with the same method that
worked for the bridge: **read each contract, audit it against its wires doc, and pressure-test the
unit/oracle/rounding assumptions against external ground truth.** The bridge session proved that
"reviewed, documented, and tested" components can still hide structural bugs (the rao-units brick;
the burn/mint rate-corruption topology); supply/ is where the same bug *classes* would cost real
money, because NAV prices issuance and exit.

## What changed upstream (context you must carry in)

The 8x-01 rework (commit `c510759`) re-founded the inputs supply/ consumes:

- `SzAlpha.exchangeRate()` (964) is 18-dp alpha-per-szALPHA, **semantics unchanged**, now actually
  correct: rao-unit normalization internal, measured-delta minting, and a **lock/release** CCIP lane
  so bridged-out supply stays in `totalSupply()` (burn/mint would have inflated the rate and drained
  Base holders — `test_lane_roundTrip_rateInvariant` pins this).
- `SzAlphaRateOracle` (Base) re-exposes that rate. **It returns 0 before the first CRE push (never
  reverts)** — every consumer must gate on `fresh()`. Knobs are immutables, now aligned everywhere
  to the 8x-02 fixtures: 6h staleness / 30d APR window / 500% cap.
- Verified live runtime facts now pinned in `ISubtensorPrecompiles.sol` + `reference/rubicon/README.md`:
  precompiles speak 9-dp; AMM conversions are never 1:1; `getMovingAlphaPrice` (18-dp EMA) is the
  only manipulation-resistant price read; spot/`simSwap*` are in-block manipulable.

**Recorded follow-up that lands in supply/:** source `SzipNavOracle`'s `LEG_ALPHA_USD` from
`getMovingAlphaPrice` × TAO/USD (CRE transports the primitive) instead of off-chain price APIs.
Evaluate this while reviewing the leg-cache design.

## Scope (17 files) — suggested order

**Phase 1 — the NAV + issuance/exit spine (highest stakes, do first):**
1. `src/supply/SzipNavOracle.sol` — entry/exit marks, leg cache, xALPHA leg, `fresh()` gating, §7
   issuance/exit asymmetry. Wires: `build/wires/8-B4-SzipNavOracle.md`.
2. `src/supply/ZipDepositModule.sol` — deposit/zap, previews, USDC 6-dp ↔ 18-dp `scaleUp`. Wires: FE-02 reports.
3. `src/supply/szipUSD/SzipUSD.sol` + `src/supply/szipUSD/ExitGate.sol` — share token + exit path.
   Wires: `build/wires/ExitGate-szipUSD.md`.
4. `src/supply/ZipRedemptionQueue.sol` — wires: `build/wires/9-ZipRedemptionQueue.md`.

**Phase 2 — the engine loop:**
5. `szipUSD/LpStrategyModule.sol` (8-B6), `HarvestVoteModule.sol` (8-B7), `ExerciseModule.sol` (8-B8),
   `SellModule.sol` (8-B9), `RecycleModule.sol` (8-B10), `SzipBuyBurnModule.sol` (8-B14).
6. `szipUSD/ReservoirLoopModule.sol` + `ReservoirBorrowGuard.sol` (8-B5) + `src/supply/SzipReservoirLpOracle.sol`.

**Phase 3 — periphery:**
7. `szipUSD/OffRampModule.sol`, `szipUSD/DurationFreezeModule.sol`, `CreditWarehouse/WarehouseAdminModule.sol`.

Tests live in `contracts/test/` (one suite per module: `SzipNavOracle.t.sol`, `ExitGate.t.sol`,
`ZipDepositModule.t.sol`, …). `forge test` baseline at session start: **724 passed / 0 failed / 3
skipped** (skips = Base-fork tests without `BASE_RPC_URL`).

## Pressure-test angles (the bug classes today's session caught — hunt their analogs)

- **Units & decimals:** USDC 6-dp vs shares/NAV 18-dp (`scaleUp = 1e12`); LP-share marks 6-dp USD
  per 1e18 share (`LP_SEED_MARK`); any place a "preview" assumes a 1:1 conversion that is actually
  a market trade (the previewDeposit bug class).
- **Oracle trust:** every `exchangeRate()` read paired with `fresh()`? Every leg-cache read gated on
  staleness + deviation circuits? What does NAV serve between genesis and first push (the
  returns-0-not-reverts trap)? Spot vs EMA: anything fund-moving reading an in-block-manipulable price?
- **Supply locality (the burn/mint bug class):** any value computed as `X / totalSupply()` where
  supply can change out-of-band of backing (burns, bridged supply, queued redemptions, buy-burn)?
- **Rounding direction:** every floor/ceil in mint/redeem/queue math — protocol-favoring, and is
  dust accounted (the redeemer-dust convention from the bridge)?
- **Donation/first-depositor analogs:** can a third party skew any share-price genesis (vault seeds,
  LP marks, EE pool shares)?
- **Asymmetry honesty:** issuance fails closed on stale data, exit prices off the last rate — verify
  every module respects the §7 split and none re-opens it.

## Working agreements (carried from the bridge session)

- The `.sol` is authoritative; tickets/wires are intent. Update wires docs + `COVERAGE.md` whenever
  code changes (COVERAGE counts must stay true — it's a completeness manifest).
- Money math is bigint/fixed-point; comments state constraints, not narration.
- Verify with `cd contracts && forge build && forge test` (and targeted `--match-contract` runs);
  `forge inspect <C> storage-layout` for any upgradeable-contract change.
- Knob/fixture changes must update doc + scripts + test + `.env.example` together (the 8x-02 rule).
- Frontend viewing: `bash build/frontend-up.sh` (production build; never `nuxt build` while a dev
  server runs). Frontend repo is separate (`resi-labs-ai/zipcode-finance-euler`, branch
  `merge-flow-and-function` carries the bridge UI).
- Monorepo pushes to `https://github.com/resi-labs-ai/zipcode-euler.git` `main`.

## Suggested opening prompt for the new window

"Read `build/supply.md` and start the supply/ review. Begin with Phase 1: read
`contracts/src/supply/SzipNavOracle.sol`, audit it against `build/wires/8-B4-SzipNavOracle.md`,
and pressure-test it against the angles in the brief. One component at a time; findings before fixes."
