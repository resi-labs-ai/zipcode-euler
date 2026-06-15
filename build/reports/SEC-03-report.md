# SEC-03 report — CCIP `TokenAdminRegistry` admin handoff (kill-list H4)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-04 (H5 `_xAlphaUSD()` fail-close)

## What the window did
Closed kill-list **H4** (escalated DECIDE→FIX HIGH; audit ref-B2 / subsystem finding #11): the szALPHA CCT deploy
script left the `TokenAdminRegistry` **registry administrator** pinned to the ephemeral Forge `Script` on both
chains, so post-deploy nobody could ever re-point or delist the bridge pool (RMN/CCIP upgrade, incident response).
`token.setCCIPAdmin(...)` only mutated the token's `getCCIPAdmin()` view — which the registry consumed once at
registration and never re-reads — so the registry `s_tokenConfig[token].administrator` slot stayed the script.
The `:131` `getCCIPAdmin()==ccipAdmin` assert checked that wrong slot → false confidence.

**Fix (3 files), exactly as ticketed:**
- `src/interfaces/bridge/ICctRegistry.sol` — extended `ITokenAdminRegistry` with
  `transferAdminRole(address,address)`, `struct TokenConfig{administrator,pendingAdministrator,tokenPool}`, and
  `getTokenConfig(address) returns (TokenConfig memory)` (reference field names + order). Existing selectors kept;
  header note updated.
- `script/DeploySzAlphaBridge.s.sol` —
  - `deploy964`: after `setPool`, `transferAdminRole(token, ccipAdmin)`; kept `setCCIPAdmin(ccipAdmin)`;
    **replaced** the `:131` `getCCIPAdmin()==ccipAdmin` require with `getTokenConfig(token).pendingAdministrator
    == ccipAdmin`; runbook in NatDoc.
  - `deployBase`: after `setPool`, `transferAdminRole(token, timelock)`; kept `setCCIPAdmin(timelock)`; **added**
    the `getTokenConfig(token).pendingAdministrator == timelock` assert; runbook in NatDoc.
- `test/bridge/{BridgeMocks.sol, SzAlphaBridge.t.sol}` — new mock CCT stack + `SzAlphaAdminHandoffTest` (below).

## Decisions to sanity-check (reviewer)
1. **Per-chain durable target.** The kill-list H4 prose literally says `transferAdminRole(token, timelock)` on
   *both* chains and `pendingAdministrator==timelock`. That "timelock" is shorthand — the actual durable target is
   per-chain: **964 → `ccipAdmin`**, **Base → `timelock`**, i.e. the SAME authority each chain's existing
   `setCCIPAdmin` already hands to (`deploy964` ends `setCCIPAdmin(ccipAdmin)`; `deployBase` `setCCIPAdmin(timelock)`).
   Both critics (spec-fidelity, reference-verifier) ran and PASS on this reading; flagged only as a kill-list
   wording nit, not drift. **If the reviewer wants the registry admin to be `timelock` on 964 too**, that's a
   one-word change + the §17 "one Timelock admin per contract" lens — but it diverges from the script's own
   `ccipAdmin` handoff intent, so I kept it aligned.
2. **`setCCIPAdmin` kept (Do-NOT honored).** Not removed — `getCCIPAdmin()` is read by
   `registerAdminViaGetCCIPAdmin` for any future re-registration, so it stays aligned to the durable admin.
3. **Assert is `pendingAdministrator`, not `administrator`.** Pre-accept the registry `administrator` is still the
   script (2-step semantics), so the deploy-time assert checks `pendingAdministrator`. Asserting `administrator`
   would always fail at deploy time.

## Holes → resolution
- **No live CCT infra on the anvil Base fork** (router/RMN/registry/module/factory). Resolution: the driver's
  "re-run deploy against a fresh fork" is satisfied (per the ticket's explicit deploy-script note) by a
  mock-registry forge test — `vm.etch` unit-faithful mocks at the script's **hard-coded** CCT addresses (both
  chains) and drive `deploy964`/`deployBase` end-to-end. Mocks' identity strings are `constant` and the module's
  registry pointer is `immutable` so they survive `vm.etch` (which copies code, not storage).
- **The existing `SzAlphaBaseForkTest`** (live Base fork, runs only when `BASE_RPC_URL` is set) is untouched and
  still exercises the real registry `deployBase` path; it does not assert the new pending-admin slot (fork test),
  but the unit test does.

## Gate (quoted)
```
cd contracts && forge build            → BUILD CLEAN

forge test --match-contract SzAlphaAdminHandoffTest
  Ran 2 tests for test/bridge/SzAlphaBridge.t.sol:SzAlphaAdminHandoffTest
  [PASS] test_SEC03_deploy964_handsRegistryAdminToCcipAdmin() (gas: 9304020)
  [PASS] test_SEC03_deployBase_handsRegistryAdminToTimelock() (gas: 6854618)
  Suite result: ok. 2 passed; 0 failed; 0 skipped

fail-before (remove the two transferAdminRole calls):
  [FAIL: registry admin handoff failed] test_SEC03_deploy964_handsRegistryAdminToCcipAdmin()
  [FAIL: registry admin handoff failed] test_SEC03_deployBase_handsRegistryAdminToTimelock()

full suite:  769 passed / 0 failed / 3 skipped   (the 3 = pre-existing DeployZipcode.t.sol skips; +2 over SEC-02)
```

## Doc edits (doc-sync-checklist run)
1. Ticket `sec/SEC-03-ccip-admin-handoff.md` → status DONE + DONE-note with quoted output.
2. `PROGRESS.md` → SEC-03 DONE in the SEC table; NEXT = SEC-04; "Just done — SEC-03" note; new standing
   **RUNBOOK** obligation in Open obligations.
3. `kill-list.md` → H4 `[ ]`→`[x]` + DONE note.
4. `audit-claude/` → `reference-diff-findings.md` B2, `findings.md` #11 (+ summary-table row), `SUMMARY.md` H4 all
   marked ✅ RESOLVED.
5. `wires/` (2 changed contracts via `COVERAGE.md`): `8x-01-szALPHA-bridge.md` (deploy-flow enumeration for
   `deploy964`/`deployBase` + interface row + new Item-10 deploy step 4b) and `interfaces-bridge.md` (declared
   surface + Consumed-by + Gotchas).
6. **No `claude-zipcode.md` spec change** — this is an interface-level deploy fix; intent (admin→durable authority)
   is unchanged, the script just now actually achieves it. No back-pressure / no new contract surface owed.
7. Deletion triggers: none fired.

## Standing obligation created
**Durable admin MUST `acceptAdminRole(token)` post-deploy** (964 `ccipAdmin`, Base `timelock`) to finalize the
2-step registry-admin handoff. Until then the deploy Script remains a live registry admin (the one residual
window). Logged in `PROGRESS.md` Open obligations + the deploy runbook (`wires/8x-01-szALPHA-bridge.md` step 4b).

## Status + NEXT
SEC-03 DONE, gate green, doc-sync complete. **NEXT: SEC-04** (`_xAlphaUSD()` fail-close on unseeded rate, H5 —
keep the §7 asymmetry). Reviewer releases it.
