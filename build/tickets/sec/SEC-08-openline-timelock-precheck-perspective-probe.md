# SEC-08 — `openLine` EE-timelock precheck + deploy-time perspective probe (M6)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` Group 3 / M6 (FIX, proposed fix REVISED);
audit `findings.md` (M6); `reference/euler-earn/src/EulerEarn.sol`, `.../EulerEarnFactory.sol` · **Status:** DONE 2026-06-15

> **FRAMING CORRECTION (validated by the spec-fidelity critic, 2026-06-15).** The ticket below calls perspective
> rejection of the custom line-vault config "the dominant brick." That premise is FALSE against the *live* EE-factory
> perspective: it is `EVKFactoryPerspective`, which is **provenance-only** (`isVerified(v) = vaultFactory.isProxy(v)`,
> `reference/evk-periphery/src/Perspectives/deployed/EVKFactoryPerspective.sol:27`) — it never inspects IRM, hook,
> governor, oracle, or unit-of-account. A line vault is an EVK-`GenericFactory` proxy, so it passes today purely on
> provenance; the custom config is invisible to the gate. **The probe's real value is therefore guarding a FUTURE
> external `setPerspective` swap** (the EE-factory owner is external; `EulerEarnFactory.sol:81` `setPerspective` is
> owner-settable): a config-inspecting successor (e.g. an ungoverned-only perspective requiring `governorAdmin==0` +
> `hookTarget==0`) would REJECT the governed+hooked line vault and brick origination. The deliverable is unchanged
> (both guards ship); only the justification is corrected. The probe checks the **external** EE factory's gate, NOT a
> protocol-owned perspective — §17 "perspectives dropped entirely" governs the protocol's own design, not external EE
> infra, so no §17 conflict. "Deploy probe passes live" is a PROVENANCE pass, not config-acceptance.

> Scope authored 2026-06-15. The audit's proposed deploy-time `timelock()==0` assert is a one-time snapshot
> (the external EE owner can raise the timelock later) AND misses the dominant brick (perspective rejection of
> the custom line vault). The kill-list fix is TWO guardrails: a runtime timelock precheck + a deploy-time
> perspective probe. NOTE: smoke SP-14 (draw→repay→close) succeeds today, so the live path works — these guard
> against a future EE timelock/perspective change, made to fail LOUDLY and EARLY.

## Deliverable
(1) A legible runtime precheck in `openLine` that reverts if the EE pool's timelock is non-zero; (2) a
deploy-time assert that the EE factory's perspective verifies a probe vault built identically to `openLine`'s
line vault.

## What it does / what's being fixed (plain language)
`openLine` onboards each per-line borrow vault by calling `eulerEarn.submitCap` then `eulerEarn.acceptCap` in
the **same transaction**. Two EE-side conditions can brick that atomically:
- **Timelock:** if the EE pool's `timelock` is non-zero, `submitCap` sets a *pending* cap with `validAt = now +
  timelock` and `acceptCap` reverts (`afterTimelock`) until it elapses — so the same-tx accept fails. The EE
  owner is external and can raise the timelock after deploy.
- **Perspective (the dominant brick):** both `submitCap` and `acceptCap` require
  `IEulerEarnFactory(creator).isStrategyAllowed(id)`, which is `perspective.isVerified(id) || isVault[id]`.
  Line vaults are EVK-`GenericFactory` proxies, NOT EE-factory-created, so `isVault` is false — they MUST pass
  the perspective. The line vault carries a custom IRM + a gating hook + a retained governor; if the live
  perspective rejects that shape, `submitCap` reverts `UnauthorizedMarket` and origination bricks.

Today both pass (SP-14). The fix makes a future regression surface as a clear revert at `openLine` time and as a
loud deploy-time failure, instead of an opaque mid-origination revert.

## Binds to (verified file:line — 2026-06-15)
- **`openLine` onboarding:** `contracts/src/venue/EulerVenueAdapter.sol:225-226` —
  `eulerEarn.submitCap(IOZERC4626(evault), type(uint136).max); eulerEarn.acceptCap(IOZERC4626(evault));`
  (atomic submit+accept). Line-vault construction = `:217-220` (factory proxy `usdc/router/usdc` + custom IRM
  `setInterestRateModel(irm)` + `setHookConfig(gatingHook, OP_BORROW | OP_LIQUIDATE)`; governor retained — only
  the *router* is frozen at `:243`, the evault's `governorAdmin` is not zeroed).
- **EE mechanism (reference, verified):**
  - `EulerEarn.sol:303` `submitCap` → `pendingCap[id].update(cap, timelock)` (validAt = now + timelock);
    `:301` requires `isStrategyAllowed`.
  - `EulerEarn.sol:507` `acceptCap` has `afterTimelock(pendingCap[id].validAt)`; `:508` re-checks `isStrategyAllowed`.
  - `EulerEarnFactory.sol:76-77` `isStrategyAllowed(id) = perspective.isVerified(id) || isVault[id]`.
- **Interface already sufficient (no change):** `IEulerEarn.timelock()` `reference/euler-earn/src/interfaces/IEulerEarn.sol:51`;
  `IEulerEarn.creator()` `:33` (reach the factory → `isStrategyAllowed`).
- **Deploy context:** the EE pool is built off the live factory with `timelock 0` (`DeployLocal.s.sol:113`,
  `DeployMainnet.s.sol:121`); EVK-factory proxies are noted as perspective-verified (`DeployLocal.s.sol:106`,
  `DeployMainnet.s.sol:112`). P5 builds the reservoir market (`DeployZipcode.s.sol:359-373`).

## Key requirements
1. **Runtime precheck (openLine).** At the TOP of `openLine` (right after the `collateralAmount` check `:199`,
   before any proxy/account is created) add `if (eulerEarn.timelock() != 0) revert EulerEarnTimelockNonZero();`
   and declare the error. Placing it first avoids orphaning half-built line state on the brick.
2. **Deploy-time perspective probe.** In the deploy (P5 region, after the line-vault config — `irm`, `gatingHook`,
   `usdc` — is known), build a throwaway probe vault **identically to `openLine` step-3** (EVK factory proxy with
   the `usdc/router/usdc` shape + `setInterestRateModel(i.irm)` + `setHookConfig(gatingHook, OP_BORROW |
   OP_LIQUIDATE)`, governor retained), then assert
   `IEulerEarnFactory(eulerEarn.creator()).isStrategyAllowed(probe) == true` and revert the deploy loudly if not.
   The probe must exercise whatever the live perspective checks (factory provenance, IRM, hook, governor,
   unit-of-account/oracle resolution) — mirror `openLine` closely.
3. Keep the existing `submitCap`/`acceptCap` flow; both additions are guards, not a rewrite.

## Do NOT
- Do NOT rely on a deploy-time `timelock()==0` assert alone for the timelock case — it is a snapshot; the
  RUNTIME precheck is the required guard (the EE owner can raise the timelock post-deploy).
- Do NOT make the line-vault config a constructor/immutable arg or change `openLine`'s vault construction — the
  probe must match whatever `openLine` actually builds, so they stay in lockstep.
- Do NOT swallow a perspective rejection — the deploy probe must revert. **Back-pressure:** if the probe reveals
  the custom line vault CANNOT pass the live EE factory's configured perspective, that is a design-level
  obligation (origination is structurally bricked), not just a missing assert — log it in `PROGRESS.md` rather
  than silently weakening the line-vault config.
- Do NOT widen scope to H2 (SEC-06) / L8 (SEC-07) / other groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC08_*` regression test** that fails before / passes after:
  - **Timelock precheck:** raise the EE pool's `timelock` to `> 0` (as the EE owner in the test), call
    `openLine`, assert it reverts the legible `EulerEarnTimelockNonZero` and creates NO line proxies (pre-fix it
    reverts opaquely inside `acceptCap`'s `afterTimelock`, after building the line state).
  - **Happy path intact:** with `timelock == 0`, `openLine` still succeeds end-to-end.
  - **Deploy probe passes live:** a deploy against the fork EE factory asserts `isStrategyAllowed(probe) == true`.
  - **Deploy probe bites:** with a mock EE factory whose `isStrategyAllowed` returns false, the deploy-time
    assert reverts (proves the guard fires).
- **Deploy-script verification (per harness):** re-run `DeployLocal` against a fresh anvil fork; the probe assert
  passes and a real `openLine` (SP-14) still succeeds. Quote the actual `forge test` output in the done note.

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-08" with the finding note (and any perspective back-pressure if surfaced).

## DONE 2026-06-15
**Both guards shipped; gate green.** `forge build` clean; `forge test` **791 passed / 0 failed / 3 skipped** (+4 over
SEC-07's 787; the 3 skips are the pre-existing `DeployZipcode.t.sol` scaffold).

- **(1) Runtime precheck** (`src/venue/EulerVenueAdapter.sol`): added `error EulerEarnTimelockNonZero();` and, at the
  TOP of `openLine` (right after the `collateralAmount != 1e18` guard, before step 0),
  `if (eulerEarn.timelock() != 0) revert EulerEarnTimelockNonZero();`. Read LIVE per origination (no new import —
  `timelock()` is on the already-imported `IEulerEarn`).
- **(2) Deploy-time probe**: new `script/SzipPerspectiveProbe.sol` — a standalone **CONTRACT** (NOT a library: a
  library inlines into the ephemeral deploy script and `forge script --broadcast` rejects the script's `address(this)`
  being baked into deployed state — discovered when the first library version reverted *"Usage of `address(this)`
  detected in script contract"* mid-deploy; the contract form mirrors `ReservoirMarketDeployer`). `buildLineVaultShape`
  mirrors `openLine` steps 1/2/3/6 (escrow + per-line router + USDC borrow vault with custom IRM + gating hook +
  governor retained, router frozen); `assertLineVaultAllowed` reaches the factory via `eulerEarn.creator()` (low-level
  staticcall) and reverts `LineVaultPerspectiveRejected` if `isStrategyAllowed(probe)` is false. Wired into
  `DeployLocal._configureEulerEarn` (the EE pool + adapter + factory are all live there).
- **3 new regression tests** in `test/EulerVenueAdapter.t.sol`: `test_SEC08_TimelockPrecheck_RevertsEarly_NoOrphan`
  (raise the mock EE timelock → openLine reverts the legible error AND the factory proxy list is unchanged — no
  orphaned proxies), `test_SEC08_TimelockZero_HappyPath`, `test_SEC08_DeployProbe_PassesLive` (full probe path against
  the **live** `EULER_EARN_FACTORY` — provenance pass), `test_SEC08_DeployProbe_Bites` (a `MockRejectingEarnFactory`
  whose `isStrategyAllowed` returns false → probe reverts `LineVaultPerspectiveRejected`). `MockEulerEarn` gained
  `timelock`/`setTimelock`/`creator`/`setCreator` + a faithful `acceptCap` that reverts `TimelockNotElapsed` while
  `timelock != 0` (so pre-fix the brick orphans real proxies — meaningful fail-before). `ZipcodeController.t.sol`'s own
  `MockEulerEarn` gained a `timelock()==0` stub (the precheck runs on every controller-driven `openLine`).
- **Fail-before/pass-after confirmed.** Disabling the precheck → the timelock test reverts opaquely as
  `TimelockNotElapsed` (not `EulerEarnTimelockNonZero`) at **3.25M gas** (proxies built) vs the post-fix **66k** early
  revert. Disabling the probe's `isStrategyAllowed` assert → the bites test no longer reverts.
- **Deploy-script gate (per harness):** ran the real `DeployLocal --broadcast --slow` against a **fresh** anvil Base
  fork @47096000 (port 8546) → **"ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" / "Script ran successfully"** — the probe
  assert in `_configureEulerEarn` passed end-to-end and the full stack deployed.
- **No spec change** (interface-level guard + deploy-only probe; §4.7 intent unchanged). **No back-pressure / no new
  obligation** — the provenance-only perspective accepts the line vault today, so the back-pressure clause did not fire.
