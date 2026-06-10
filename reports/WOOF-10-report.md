# WOOF-10 — item-10 deploy/wiring orchestrator: report to the superintendent

**Item:** 10 — Deploy + wiring script (§9, `audit/2.md` S1–S12, extended for the full current contract set).
**Date:** 2026-06-10. **Status:** **DEPLOY SCRIPT AUTHORED + `forge build` GREEN + KEPT.**

## TL;DR
Authored `contracts/script/DeployZipcode.s.sol` (625 lines) **from `wires/`** (the wiring map is the spec).
Filed the ticket `tickets/woof/WOOF-10-deploy-wiring.md` (phase-by-phase P0–P9), then cold-built the script via
a focused subagent that verified every ctor / `setUp` decode / sub-deployer entrypoint against the kept code
(zero load-bearing guesses) and iterated its own single `forge build` to green. The script deploys + wires the
entire **Base-side** protocol in dependency order, asserts all 8 cross-cutting seams inline, seals CRE identity,
and `transferOwnership(timelock)` everywhere (NOT renounce). I independently re-ran `forge build` → exit 0.

## What it does (phases P0–P9, entrypoint `deploy()`)
- **P0 roots:** `TimelockController`; `EE_POOL`/`BASE_USDC_MARKET` taken as env inputs (see delta 4).
- **P1 venue spine:** registry → lienFactory → hook → adapter → controller, with the **adapter↔controller** and
  **hook↔borrowDriver** circulars resolved by the build-phase settable setters (deploy with a placeholder, then
  `setController`/`setBorrowDriver`); `registry.setController`; venue/registry asserts.
- **P2:** `SzAlphaRateOracle` (Base side of 8x-02).
- **P3 supply substrate:** inherited `_summon` (Baal + main Safe + sidecar) → zipUSD `ESynth` → `ZipDepositModule`
  → `SzipNavOracle` → `ExitGate` → `SzipUSD` → `setShareToken` both sides → `setCapacity` → Gate `manager(2)` via
  `setShamans` → zero-Shares + gate-shareToken asserts.
- **P4 warehouse** (before P3 deposit module, since its `warehouse` is an immutable ctor arg): `CreditWarehouseDeployer.deploy`; EE allocator/curator/fee are fork-only TODOs (delta 4); non-commingling assert.
- **P5 reservoir:** `SzipReservoirLpOracle` + `ReservoirMarketDeployer.deploy`; shared-LP assert.
- **P6 engine modules:** all 9 cloned via `ModuleProxyFactory.deployModule(mastercopy, encodeWithSignature("setUp(bytes)",data), salt)` + a `_enableModuleOnSafe` helper (Safe `execTransaction`, `v==1` pre-validated sig, modeled on `SummonSubstrate`); DurationFreeze on BOTH Safes, OffRamp on the main/rq Safe; one-bank + engineSafe + shared-LP asserts; `owner=timelock != operator=CRE`.
- **P7 loss:** `LienXAlphaEscrow` + `DefaultCoordinator`, escrow↔coordinator circular via `setCoordinator`/`setEscrow`; `navOracle.setDefaultCoordinator`; escrow-wired assert.
- **P8:** `navOracle.setLpPosition` + `setXAlphaRateOracle`; shareToken-set assert before any transfer.
- **P9 seal:** `setExpectedAuthor`/`setExpectedWorkflowId` on every ReceiverTemplate → `ZipcodeDeployAsserts.requireIdentityWired` → `transferOwnership(timelock)` everywhere.

## Design decisions to sanity-check
1. **Build-phase posture = `transferOwnership(timelock)`, never renounce** — straight from the repo-wide §17
   doctrine the `wires/` pass confirmed (every wiring slot is Timelock-settable). This is what makes the
   circular ctor deps deployable without CREATE2 precompute games.
2. **Compose, don't reimplement** — the script inherits `SummonSubstrate` and `new`s the warehouse/reservoir
   deployers, so the intricate Baal-summon / Roles-scoping / EVK-market logic stays in its tested home.
3. **EE-pool config is honestly out-of-band** — rather than vendor the 0.8.26 EulerEarn source (forbidden) or
   guess a factory ABI, `EE_POOL`/`BASE_USDC_MARKET` are env inputs and the allocator/curator/fee + supply-queue
   wiring is a fork-runbook TODO. This keeps the build green and the obligation honest (311/333 still owed).
4. **The broadcaster IS `TEAM_MULTISIG`** (MVP) — same assumption `SummonSubstrate` documents; the Safe-driving
   helpers use the `v==1` pre-validated single-owner signature path (`msg.sender == owner`).

## Holes surfaced → resolution (5 build-discovered deltas, folded into the ticket)
| # | Delta | Resolution |
|---|---|---|
| 1 | `ZipDepositModule` has no Ownable (immutable `deployer` + re-settable `setGate`) | dropped its P9 transfer; re-home only by redeploy |
| 2 | `ZipRedemptionQueue` deployed P4 but zipUSD is a P3 artifact | deploy with `zipUSD=address(0)`, then `setTokens` in P3 |
| 3 | `run()` collides with `SummonSubstrate.run()` (non-virtual) | entrypoint named `deploy()` |
| 4 | EE-pool admin ABI not in the local shim | env inputs + fork-runbook TODO (obligations 311/333) |
| 5 | everything else | matched code exactly (13 ctors, 9 setUp tuples, ReceiverTemplate/Ownable v5, deployModule, Safe exec, TimelockController) |

## Status & next
- **`forge build` GREEN** (exit 0, independently re-run; warnings are pre-existing repo-wide lint notes). The
  script is kept at `contracts/script/DeployZipcode.s.sol`. NOT git-committed (consistent with recent windows).
- **NEXT (fork-execution verification — the real acceptance):** `test/DeployZipcode.t.sol` on a Base fork —
  Phase-S post-state asserts, the identity-pre-gate **tested-negative** (transfer with identity unset must
  revert), and an L4 origination end-to-end; the live-pool EE config runbook (createEulerEarn → allocator /
  curator / fee → point supply queue at the reservoir borrow vault); the deferred `audit/2`+`audit/3`
  engine/junior/loss L-row sweeps; the 8x bridge two-chain (964) wire (separate script). `forge build` green is
  the authoring bar; a green fork run is the deploy bar.
- **Judgment call for review:** I delegated the cold-build's compile-iteration to one subagent (the keep-the-build
  pattern) rather than hand-writing 625 lines in the main loop, to isolate the forge-iteration from this context.
  Every signature was verified against code; the result is green and kept.
