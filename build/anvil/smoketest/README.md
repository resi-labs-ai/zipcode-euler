# build/anvil/smoketest — the live-fork smoke suite (rebuilt from the X-Ray/seam model)

Each `smoke-path-NN.md` pushes **real smoke through the real machinery** on the running anvil (Base fork @ 47096000):
fire the actual functions at the actual deployed contracts, prove a named **seam** holds (the per-contract X-Ray
invariants), happy path **and** an adversarial/negative ("fuzzy") leg. Rebuilt 2026-06-24 from
`../smoke-path-x-ray-update.md` (the recipe); supersedes the old flat `../smoke-path-NN.md`.

## How to run
- **Bind by NAME, never paste hex.** `source _harness.sh` gives the address book (engine modules are the live
  **CLONES**, re-derived from the main Safe's module list — the mastercopies in `../contract-map.md` are inert),
  `meta_for`/`push_report` (CRE), `seed_marks` (the universal rate+legs preamble), `deal_usdc`, and `revert_baseline`.
- **Isolation:** each SP starts with `revert_baseline` (`evm_revert` to a clean post-deploy snapshot, then re-snapshot)
  so SPs don't contaminate each other.
- **Universal preamble:** nearly every SP first calls `seed_marks` — on a fresh baseline all NAV/engine ops
  fail-close `RateUnseeded`/`StalePrice` until the xALPHA rate + NAV legs are CRE-seeded.
- **Gas:** CRE reports through the controller (origination) need `gas-limit ≥ 8M`.

## Catalog (seam → headline; ✓ = live-executed PASS this cycle)
| # | Seam | Headline | Status |
|---|---|---|---|
| 01 | →S12 | zipUSD deposit lifecycle (net-zero custody, capacity gate) | ✓ PASS |
| 02 | S8-in | NAV genesis read surface (+ RateUnseeded fail-closed) | ✓ PASS |
| 03 | S9 | DurationFreeze commit (main→sidecar) | ✓ PASS |
| 04 | — | farm borrow/repay (real EVK) + borrow guard | ✓ PASS |
| 05 | S10 | buy-burn bid post/cancel (live CoW presign) | ✓ PASS |
| 06 | S8 | junior zap → issuance (two-token invariant) | ✓ PASS |
| 07 | S3 | szipUSD transfer + NAV entry/exit asymmetry | ✓ PASS |
| 08 | lien | revaluation rail (strict-18dp + StaleReport) | ✓ PASS |
| 09 | S11 | warehouse senior ops via Roles scope | ✓ PASS |
| 10 | — | senior par-epoch redemption (queue-only burn) | ✓ PASS |
| 11 | S5/S6 | loss bond → provision → resolve/slash | ✓ PASS |
| 12 | S2/S3 | xALPHA rate push → NAV leg (saturation-safe) | ✓ PASS |
| 13 | S10 | buy-burn full exit (NAV ticks up for stayers) | ✓ PASS |
| 14 | spine | full venue origination (CTR-03 siloId) | ✓ PASS |
| 15 | S9 | utilization ↔ freeze identity | ✓ PASS (identity) |
| 16 | spine | draw + close line (CTR-03) | ✓ PASS |
| 17 | S13 | engine flywheel (LP/harvest/exercise/sell/recycle) | ✓ PASS |
| 18 | demo | vAMM auto-compounder showcase | ✓ PASS |
| 19 | **S7** | donation seam — NAV moves with no deposit | ✓ PASS |
| 20 | **S13** | engine end-to-end value conservation | ✓ PASS |
| 21 | **S12** | senior NAV donation-immunity | ✓ PASS |

Run order: 01→04, then 06/08, 14/16, 09/10/21, 03/15, 05/13, 11/12, 17/20, 19, then 18 (after `DeployShowcaseVAMM`).

## Coverage vs the board (provable completeness)
Every protocol + demo contract in `../contract-map.md` is bound by ≥1 SP (see the spec "Binds to" lines). Runtime-minted
contracts have no fixed address and are exercised at origination:
- **`LineAccount`** — the per-line EVC sub-account (`new LineAccount{salt}`) — created + drawn against in **SP-14/16**.
- **`LienCollateralToken`** — the per-lien CREATE2 token — minted + escrowed + burned in **SP-14/16**.

Deliberate non-SP targets (infra / off-chain / out-of-scope per the X-Rays): `TimelockController` (used as owner
throughout), the pure libraries/mixins (`ConcentratedLiquidity`, `IchiAlgebraFairReserves`, `MastercopyInitLock`,
`CloneReportReceiver`), `ZipcodeDeployAsserts`, the bridge contracts `SzAlpha*` (964/CCIP side — `DeploySzAlphaBridge`),
and `AlgebraIchiFairLpOracle` (prod fair-LP path, not wired on this M1 board). **No SPs** for the off-chain seams
S1 (964 precompile), S2 conservation, S4 correlated-CRE, S11 Roles scope tree (X-Rays mark them `On-chain=No`).

## Notes
- **All 21 SPs are live-executed PASS as of 2026-06-24** (SP-16 close, SP-17's five venue legs, SP-18 vAMM mechanics,
  and SP-20's single-state loop were finished live in the follow-up pass). 0 flaws found.
- The nonce-dependent addresses (engine clones, WarehouseAdminModule, the demo contracts) must be re-derived from the
  broadcast each deploy — see `_harness.sh` (it carries the current board) and the re-derivation note in
  `../contract-map.md`.
- The one venue dependency that can't be forced on a frozen fork is gauge **oHYDX emission accrual** (Merkl/Voter
  onboarding) — SP-17's harvest call-path passes; accrual reads 0. Not a code gap.
