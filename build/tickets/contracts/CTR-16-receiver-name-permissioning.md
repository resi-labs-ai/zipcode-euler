# CTR-16 — CRE receiver permissioning: author + per-receiver workflowName (drop shared workflowId)

> BUILD ticket. Spec: `claude-zipcode.md` §13 (CRE identity / Forwarder boundary), §17 (build-phase-settable
> wiring). Deploy-track (contracts/script). NO receiver-contract code change — `ReceiverTemplate` already exposes
> `setExpectedWorkflowName`. Reviewer-directed (2026-06-20): adopt the CRE-docs-recommended posture + make the
> separate-daemon model actually enforce privilege separation.

## Why (the reviewer's two decisions)
1. **Drop `workflowId`-pinning, adopt author + workflowName.** Pinning a real `workflowId` re-arms a fleet-wide
   re-seal on every workflow redeploy (the id is a build hash; it rotates). `author` + `workflowName` are stable
   across code updates (CRE "Verifying Workflows" guide). No more lockstep re-seal; no silent-outage footgun.
2. **The CRE producers are SEPARATE daemons** (one per strategy/function), each its own deployed workflow. They
   share one deploy wallet ⇒ **`author` alone CANNOT separate them** — any daemon could write to any receiver.
   The gate that enforces "daemon-A writes only to its own receiver(s)" is **`workflowName`, pinned PER-RECEIVER**.

## The latent bug this fixes
The as-built deploy seals the WHOLE receiver fleet to ONE shared `WORKFLOW_ID` (`DeployZipcode.s.sol` P9
`_sealIdentity` + the "S10b same-WORKFLOW_ID loop"; the `Identity` struct comment: "one author/id family";
`JuniorTrancheDeployer`/`SiloDeployer` pass the same `p.workflowId`). That is correct ONLY for a single bundled
workflow. In the separate-daemon model it would mean **only one daemon's reports are ever accepted and the other
five silently rejected** (`InvalidWorkflowId`). It has not bitten because the CRE side is pre-prod / default-OFF.

## Deliverable
Change the deploy seal posture from `setExpectedAuthor(A) + setExpectedWorkflowId(SHARED_ID)` to
`setExpectedAuthor(A) + setExpectedWorkflowName(<this receiver's daemon name>)`, with the `workflowId` pin DROPPED
(left `bytes32(0)` so `onReport` skips it). NO contract code change — only `contracts/script/*` + the deploy
asserts + the deploy tests.

## The per-receiver → daemon mapping (pin; derived from the CRE producer notes)
| Receiver (sealed) | Daemon / workflow that writes to it | Env name var |
|---|---|---|
| `ZipcodeController` | controller daemon (CRE-01b, rt1/2/4/5,6) | `WORKFLOW_NAME_CONTROLLER` |
| `ZipcodeOracleRegistry` | revaluation daemon (CRE-01a, rt3) | `WORKFLOW_NAME_REVALUATION` |
| `DefaultCoordinator` | coordinator daemon (CRE-01c, rt8) | `WORKFLOW_NAME_COORDINATOR` |
| `SzipNavOracle` | sharefeeds daemon (CRE-03, rt7 NAV leg) | `WORKFLOW_NAME_SHAREFEEDS` |
| `SzipFarmUtilityLpOracle` | sharefeeds daemon (CRE-03, rt7 LP mark — SAME producer) | `WORKFLOW_NAME_SHAREFEEDS` |
| `WarehouseAdminModule` (per silo) | warehouse daemon (CRE-04 / 02b / 02c) | `WORKFLOW_NAME_WAREHOUSE` |
| `SzAlphaRateOracle` | szalpha-rate daemon (8x-02) | `WORKFLOW_NAME_RATE` |
| per-silo `SzipNavOracle` (JuniorTrancheDeployer) | sharefeeds daemon | `WORKFLOW_NAME_SHAREFEEDS` |
| per-silo `DefaultCoordinator` (JuniorTrancheDeployer) | coordinator daemon | `WORKFLOW_NAME_COORDINATOR` |

NOTE: the warehouse daemon (CRE-04/02b/02c) is ONE workflow with three handlers — so all per-silo WAMs share the
ONE `WORKFLOW_NAME_WAREHOUSE` (this is the CRE-02c "shared id across WAMs" picture, now expressed as a shared
NAME — and it's correct: one warehouse daemon writes to all silos' WAMs).

## Binds to (CONFIRMED 2026-06-20)
- **`ReceiverTemplate.setExpectedWorkflowName(string)`** (`reference/x402-cre-price-alerts/.../ReceiverTemplate.sol:159`)
  — SHA256-hashes the name and truncates to `bytes10` (`:158,170-178`); empty string clears it. The DON metadata's
  `workflowName` is the SAME SHA256-truncation of the registered name (`:103,107-114`), so passing the daemon's
  registered name string both sides matches byte-for-byte. **No encoding work in the deploy — pass the string.**
- **`WorkflowNameRequiresAuthorValidation`** (`:30,107-110`): `onReport` reverts if `expectedWorkflowName` is set
  but `expectedAuthor` is NOT. So author MUST remain set whenever name is set (it already is). At SEAL time the
  order is free (the check is at `onReport`); just ensure both end set.
- **`onReport` gate** (`:88-114`): each non-zero slot is enforced (AND). Dropping `workflowId` (→ `bytes32(0)`)
  makes the gate `msg.sender==forwarder` + `author` + `name` — exactly the target posture.
- **`IReceiverIdentitySet`** (`DeployZipcode.s.sol:680`) currently exposes only `setExpectedAuthor` +
  `setExpectedWorkflowId`. **Add `setExpectedWorkflowName(string)`.**
- **Affected deploy code:** `DeployZipcode.s.sol` (`Identity` struct `:103-104`, `_sealIdentity` `:613-614`, the
  P9 seal calls `:534-543`, env parse `:656-657`, the asserts `ZipcodeDeployAsserts.requireIdentityWired` /
  `requireReceiverIdentityWired`), `JuniorTrancheDeployer.s.sol` (`:374-375`, `:323-324`), `SiloDeployer.s.sol`
  (`:299`), `DeployMainnet.s.sol` (`:68`), `DeployShowcaseVAMM.s.sol` (`:43,77-78`).
- **Affected tests:** `ZipcodeDeployIdentityGate.t.sol` + `DeployZipcode.t.sol` (assert the new author+name posture,
  not the id pin).

## Key requirements
- **K1 — drop the `workflowId` pin everywhere** (do NOT call `setExpectedWorkflowId` with a non-zero value; leave
  it `bytes32(0)`). Replace with `setExpectedWorkflowName(name)` per the mapping. `setExpectedAuthor` UNCHANGED.
- **K2 — per-receiver names, NOT a shared name.** `_sealIdentity` takes a `string name` param; each call site
  passes the receiver's daemon name from the mapping. (Exception: all WAMs + all sharefeeds receivers legitimately
  share their daemon's one name — that's per the mapping, not a fleet-wide single name.)
- **K3 — names are deploy ENV inputs, NOT hardcoded** (`vm.envString("WORKFLOW_NAME_*")`). The deploy wires the
  STRUCTURE; the operator supplies the registered daemon names at deploy time (they don't exist in source —
  `project.yaml`s are templates). §17: re-pointable (the setters stay owner-callable post-deploy).
- **K4 — update the fail-closed identity pre-gate** (`ZipcodeDeployAsserts`): assert `getExpectedAuthor != 0 &&
  getExpectedWorkflowName != bytes10(0)` (the new "identity wired" condition), NOT `getExpectedWorkflowId != 0`.
- **K5 — the privilege-separation PROOF (the load-bearing test):** a test must prove that a report bearing
  daemon-A's name is REJECTED (`InvalidWorkflowName`) by a receiver sealed to daemon-B's name, and ACCEPTED by the
  receiver sealed to daemon-A's name. This is the whole point of per-receiver names — without it, the change is
  unverified. (Author identical in both; only the name differs.)
- **K6 — no behavior regression** on the receiver contracts (unchanged) or the rest of the deploy. `forge build`
  + `forge test` green.

## Done when (the gate)
- `cd contracts && forge build && forge test` green (esp. the updated `ZipcodeDeployIdentityGate.t.sol` +
  `DeployZipcode.t.sol`; the new K5 separation test passes).
- Every receiver in the fleet (incl. per-silo) is sealed with author + its daemon's name; NO `workflowId` pin
  remains; the pre-gate asserts the name posture.
- K5 separation proven; DeployMainnet/DeployShowcaseVAMM consistent.

## Doc-sync (at conclude)
NO receiver-contract behavior changed (the `ReceiverTemplate` gate + setters pre-exist) → the change is the
DEPLOY-TIME posture. Update any `wires/` deploy/identity-seam doc that describes the "one shared WORKFLOW_ID"
sealing to the per-receiver-name posture, + `PROGRESS.md` + the §13 spec note. Discharge: the CRE-02c memory note
(the WAM permissioning question) is RESOLVED by this — record it.

## Critic triage (loop ran 2026-06-20 — these OVERRIDE anything above that conflicts)
Four critics ran (junior-dev / spec-fidelity / reference-verifier / deploy-integrity). All bindings resolve;
design is spec-faithful (§9 recipe, §13 boundary, §17 settable). Verified corrections + folded scope:

- **CORRECTED — venue adapter is NOT a receiver (critic misread, verified false).** `EulerVenueAdapter` has no
  `is ReceiverTemplate` / `onReport` / identity setters — it's the IZipcodeVenue routing adapter, not a report
  consumer. It needs NO sealing. The per-silo hole is the **WAM only**.
- **CORRECTED — `SzipBuyBurnModule` is a `CloneReportReceiver`, NOT a `ReceiverTemplate`** (`SzipBuyBurnModule.sol:67`).
  `CloneReportReceiver` has only `expectedWorkflowId` + `expectedAuthor` — **no `setExpectedWorkflowName`** — and is
  permissioned at clone `setUp`, NOT via the deploy's `_sealIdentity` loop. So it is **OUT of CTR-16**: it physically
  cannot take the name posture, and it's a different permissioning path. (Adding a name surface to
  `CloneReportReceiver` is a CONTRACT change = a separate decision/ticket; logged below, not owed here.) The
  spec-fidelity "omission" is thus resolved: not an omission — a different receiver family.
- **FOLDED IN (reviewer-approved) — the real pre-existing hole: per-silo WAM is never sealed.** `SiloDeployer.s.sol`
  builds each silo's `WarehouseAdminModule` (`warehouse.adapter`, step 6) but never calls `_sealIdentity` on it —
  so silos 2+ ship the WAM forwarder-only (silo-0's WAM IS sealed via `DeployZipcode:536`). **Add a per-silo WAM
  seal** (author + `WORKFLOW_NAME_WAREHOUSE`) in `SiloDeployer`/`JuniorTrancheDeployer`. (Venue adapter NOT sealed —
  not a receiver.)
- **CONFIRMED — the pre-gate is representative-only + keyed on workflowId** (`ZipcodeDeployAsserts.sol:42-58`;
  its own comment `:50` admits the "same WORKFLOW_ID on every subclass" assumption). That assumption is INVALID
  under per-receiver names. K7 below reworks it.
- **CONFIRMED build-breaker — `DeployLocal.s.sol:77`** pins `workflowId = bytes32(uint256(1))` "(identity
  pre-gate)" and sets NO name; after the gate rewrite it reverts. K9 fixes it.
- **SOFTENED claim — the DON encoding match is a deploy-time integration property, not repo-proven.** On-chain
  `setExpectedWorkflowName` stores `SHA256(name)→hex→first-10-chars→bytes10` (`ReceiverTemplate.sol:170-178`); the
  K5 test proves the on-chain *comparison* logic, but whether the live DON/Forwarder emits `workflowName` under the
  identical scheme is Chainlink's off-chain contract — not verifiable here. Treat as an integration check at real
  deploy, not a gate item.

## Additional Key requirements (from triage)
- **K7 — rework the fail-closed pre-gate per-receiver.** Add `getExpectedAuthor()` + `getExpectedWorkflowName()`
  to `IReceiverIdentity` (`ZipcodeDeployAsserts.sol`). Rewrite `requireReceiverIdentityWired` to assert
  `getExpectedAuthor() != address(0) && getExpectedWorkflowName() != bytes10(0)` (NOT workflowId). Rewrite
  `requireIdentityWired` to NOT rely on the "same id ⇒ all wired" inference — assert EACH sealed receiver
  (controller, registry, warehouse adapter, coord, navOracle, rateOracle, lpOracle) individually, so a
  missing/empty name on any one fails closed (a missing `vm.envString` or empty name = author-only hole otherwise).
- **K8 — per-silo WAM seal** in `SiloDeployer`/`JuniorTrancheDeployer`: `_sealIdentity(warehouse.adapter, author,
  WORKFLOW_NAME_WAREHOUSE)`. Thread the name through the param structs (`SiloParams`/`JuniorParams`) alongside the
  existing author. Do NOT seal the venue adapter (not a receiver).
- **K9 — `DeployLocal.s.sol`**: set `WORKFLOW_NAME_*` as constants (anvil; e.g. `"zip-controller"` etc. — local
  labels, since there's no real registration) and stop pinning a non-zero `workflowId` (leave `bytes32(0)`), so the
  reworked pre-gate passes on the name posture. This keeps the anvil/FE stack deployable.
- **K10 — drop the `WORKFLOW_ID` env read** where it would otherwise revert (`vm.envBytes32` reverts if unset);
  replace with the `WORKFLOW_NAME_*` reads. `DeployMainnet` parses the name env vars; `DeployShowcaseVAMM` swaps
  its literal id-pin for a name.

## OPEN / not owed
- The actual registered daemon NAME strings (operator-supplied at deploy; this ticket wires the env slots/labels).
- **`CloneReportReceiver` family (`SzipBuyBurnModule` + any clones) — OUT of scope** (no `setExpectedWorkflowName`
  surface; permissioned at `setUp`, not `_sealIdentity`). Unifying it onto author+name would need a CONTRACT change
  (add a name slot + setter to `CloneReportReceiver`) — a separate ticket/decision. For now it stays on its
  existing author(+id) permissioning.
