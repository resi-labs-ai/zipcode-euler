# SEC-08 report — `openLine` EE-timelock precheck + deploy-time perspective probe (M6)

**Date:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Source:** kill-list M6 (FIX, REVISE); audit finding #10.
**Status:** DONE. Gate green: `forge build` clean; `forge test` **791 passed / 0 failed / 3 skipped**.

## What the window did
Closed the two un-asserted EulerEarn preconditions `openLine`'s atomic same-tx `submitCap`+`acceptCap` depends on:

1. **Runtime timelock precheck** — `EulerVenueAdapter.sol`: added `error EulerEarnTimelockNonZero();` and, at the top
   of `openLine` (right after the `collateralAmount != 1e18` guard, before step 0):
   `if (eulerEarn.timelock() != 0) revert EulerEarnTimelockNonZero();`. Read LIVE per origination — a non-zero EE
   timelock makes `submitCap` set `validAt = now + timelock` and the same-tx `acceptCap` revert (`afterTimelock`)
   AFTER the LineAccount + both EVK proxies + router are built. The precheck fails loud and EARLY, before any state,
   so the brick can't orphan half-built line proxies. The external EE owner can RAISE the timelock post-deploy, so a
   deploy-time `timelock()==0` snapshot is insufficient — hence a per-call runtime read. No new import (`timelock()`
   is on the already-imported `IEulerEarn`).

2. **Deploy-time perspective probe** — new `script/SzipPerspectiveProbe.sol`, wired into
   `DeployLocal._configureEulerEarn`. It builds a throwaway vault with `openLine`'s exact line-vault shape (steps
   1/2/3/6: escrow holding box + per-line router + USDC borrow vault with the custom IRM + gating hook at
   `OP_BORROW|OP_LIQUIDATE` + governor retained + router frozen), reaches the factory via `eulerEarn.creator()`, and
   asserts `IEulerEarnFactory(factory).isStrategyAllowed(probe)` — reverting `LineVaultPerspectiveRejected` otherwise.

## Decisions to sanity-check
- **`SzipPerspectiveProbe` is a CONTRACT, not a library.** The first version was a library; running the real
  `DeployLocal --broadcast` reverted *"Usage of `address(this)` detected in script contract. Script contracts are
  ephemeral…"* — because a library inlines into the ephemeral deploy script, so `new EulerRouter(evc, address(this))`
  baked the script's address into deployed router state, which `forge script` forbids. The contract form (mirroring
  `ReservoirMarketDeployer`) makes `address(this)` the probe instance. Trade-off: the probe vault's governor is the
  probe contract, not the adapter — a fidelity nuance immaterial to the provenance-only live perspective, and the same
  pattern `ReservoirMarketDeployer` already uses.
- **Lockstep without refactoring `openLine`.** The ticket Do-NOT forbids changing `openLine`'s vault construction or
  making its config ctor args. `openLine` stays inline; `SzipPerspectiveProbe.buildLineVaultShape` is the *one* place
  that duplicates the shape (used by both the deploy and the regression test), with a "MUST MIRROR openLine steps
  1/2/3/6" comment on both sides. A future `openLine` change must update the probe — flagged in the wire doc.
- **Probe lien token.** `openLine` takes `lienToken` at runtime; the deploy has none. The probe uses a throwaway token
  (`i.polIchiVault` in the deploy, `LIEN_A` in the test). Because the live perspective is provenance-only it never
  resolves the oracle, so the lien choice does not affect the result.

## Holes → resolution
- **The "dominant brick" premise is false against the live perspective (spec-fidelity critic, validated).** The live
  EE-factory perspective is `EVKFactoryPerspective` — provenance-only (`isVerified(v) = vaultFactory.isProxy(v)`,
  `reference/evk-periphery/src/Perspectives/deployed/EVKFactoryPerspective.sol:27`). It never inspects IRM/hook/
  governor/oracle, so a line vault passes today purely as a factory proxy; the perspective leg of audit #10 cannot
  brick origination under the *current* perspective. **Resolution:** kept both guards (the deliverable is unchanged)
  but corrected the framing everywhere (ticket, kill-list, audit #10, wire WOOF-04): the probe's real value is
  guarding a **future** external `setPerspective` swap (`EulerEarnFactory.sol:81`, owner-settable) to a
  config-inspecting/ungoverned-only perspective (e.g. requiring `governorAdmin==0` + `hookTarget==0`) that would
  reject the governed+hooked line vault. "Deploy probe passes live" is documented as a provenance pass.
- **§17 "perspectives dropped entirely" (spec-fidelity).** No conflict: §17 governs the protocol's OWN design (no
  protocol-owned SnapshotRegistry/perspective). The probe checks the EXTERNAL EE factory's gate. Reconciliation note
  added to the ticket + wire doc.
- **Junior-dev's most-blocking item (probe lien substitute could flip `isStrategyAllowed`).** Dissolved by the
  provenance-only finding — the result is provenance-deterministic regardless of the lien.

## Fail-before / pass-after
- **Timelock precheck:** disabling it → `test_SEC08_TimelockPrecheck_RevertsEarly_NoOrphan` reverts opaquely as
  `TimelockNotElapsed` (not `EulerEarnTimelockNonZero`) at **3.25M gas** (proxies built) vs the post-fix **66k** early
  revert with the factory proxy list unchanged.
- **Perspective probe:** disabling the `isStrategyAllowed` assert → `test_SEC08_DeployProbe_Bites` no longer reverts.

## Deploy-script gate (per harness)
Ran the real `forge script DeployLocal --broadcast --slow` against a **fresh** anvil Base fork @47096000 (port 8546):
**"ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" / "Script ran successfully"** — the probe assert in `_configureEulerEarn`
passed end-to-end and the full stack deployed. (A plain no-broadcast simulation reverts earlier with `GS025`, an
unrelated Gnosis-Safe signature-validation limitation of the Safe-broadcast deploy under simulation.)

## Doc edits
- `build/tickets/sec/SEC-08-*.md` — status DONE, framing-correction banner, Done-note.
- `build/tickets/PROGRESS.md` — SEC-08 DONE, SEC-09 NEXT, "Just done — SEC-08" note.
- `build/kill-list.md` — M6 `[ ]`→`[x]` + DONE note with the framing correction.
- `build/audit-claude/findings.md` — finding #10 RESOLVED (summary row + fix line).
- `build/wires/WOOF-04.md` — `openLine` timelock precheck added to the guard sequence; SEC-08 probe note in the
  deploy-constraint section. `build/wires/COVERAGE.md` — catalogued `script/SzipPerspectiveProbe.sol` → WOOF-04 (8→9).
- **No `build/claude-zipcode.md` change** — interface-level guard + deploy-only probe; §4.7 intent unchanged.

## Status + NEXT
SEC-08 DONE. **NEXT: SEC-09** — `RecycleModule.divert` cumulative hole bound (M7).
**No back-pressure / no new obligation** (the provenance-only perspective accepts the line vault today).
