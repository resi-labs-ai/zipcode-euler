# superintendent-auditor.md — the BUILD-VERIFICATION pass (materialize → build → on-chain-verify → fix → KEEP → update docs)

A fresh window runs this to take each **already-drafted** build item and **prove it for real**: materialize the
contract from its ticket, `forge build` + `forge test` it green, **verify every external interface signature and
every hardcoded address against the live chain**, fix what the real build exposes, **KEEP the code committed**,
and then **update every tracking doc** — automatically, as the last step of the procedure, so nobody has to be
told to do it.

> **This SUPERSEDES the old "document-alignment audit" version of this file (retired 2026-06-06).** That version
> audited tickets-vs-reports-vs-spec at the prose layer and "certified the build set coherent." That layer is
> insufficient and was the project's core failure mode: when WOOF-00 was actually materialized + compiled, the
> prose-clean scaffold turned out to have a CRE-selector contradiction, **10 of 25 wrong external interface
> signatures**, and **two "CONFIRMED, repo-authoritative" addresses that were the wrong contract** (an ICHI
> "factory" that was a Gnosis Safe; scrambled Baal summoner labels). None of it was visible without building.
> **So: a document audit is NOT a verdict. The verdict is "the code builds + the interfaces/addresses are
> on-chain-verified."** See the keep-the-build doctrine in `kickoff.md` + `audit/adversarial-spec/README.md`.

## The doctrine this pass enforces (keep-the-build)
- **The code is the proof; the ticket is the intent. They live together, committed.** For anything verifiable —
  signatures, addresses, does-it-compile — **the code is the source of truth, not the ticket.**
- **Never discard the byproduct.** The old "reset `contracts/` to its `.gitkeep` skeleton" rule is RETIRED.
- **"Compiles" is not verification.** A stub always compiles. Every external interface signature and every
  hardcoded address MUST be checked against the live chain (Basescan / `cast`), or against the authoritative
  deployment JSON (`reference/<dep>/deployments/base/*.json`, `euler-interfaces/EulerChains.json`).

## Resume protocol (a fresh window reconstructs full state from disk)
Read, in order:
1. **This file** (the method + the worklist + the current state below).
2. **`tickets/PROGRESS.md`** — process state. The backlog table (status per item), the **Open cross-ticket
   obligations** table, the **Open spec gaps**, and the **Session log** (newest first — the last entry tells you
   exactly where the prior window stopped).
3. **`tickets/LEDGER.md`** — the per-component design digest + cross-ticket seams.
4. **`reports/README.md`** — the report index (which report is current per item).
5. **`kickoff.md`** + **`audit/adversarial-spec/README.md`** — the keep-the-build doctrine + the harness loop.
6. **`claude-zipcode.md` §17** — the locked decisions every item must honor (do not reopen without user ratification).

## CURRENT STATE (snapshot — update this block when you finish an item)
- **Doctrine flipped 2026-06-06:** keep-the-build is live in `kickoff.md`, `audit/adversarial-spec/README.md`
  (steps 4 & 6), `superintendent.md` (review item 4), and this file.
- **RPC:** a working Base-mainnet Alchemy RPC is wired into **gitignored** `contracts/.env` as `BASE_RPC_URL`
  (and `.env`/`*.env` are gitignored — never commit the key). Use it for `cast` probes + fork tests:
  `forge test --fork-url "$BASE_RPC_URL"` or `cast call <addr> "<sig>" --rpc-url "$BASE_RPC_URL"`.
- **BUILT-VERIFIED so far: WOOF-00, 01, 02, 03, 04, 05, 10a.** (`contracts/` builds green; full suite **107/107**,
  fork tests via `$BASE_RPC_URL`; WOOF-10a's 5 are no-fork.) **The pure-Euler M1 contract spine is now ALL real on
  disk.**
  - **WOOF-00:** scaffold builds green, 3 self-checks pass, address book on-chain-verified (2 address bugs +
    10/25 interface sigs fixed). The template.
  - **WOOF-01:** lien token/factory — green + **14/14 tests** (kept); zero-spec-guess keepsake.
  - **WOOF-02:** oracle registry (`is ReceiverTemplate, BaseAdapter` + 2 remaps) — green + **34/34 tests** (kept);
    scale identity + strict-decimals confirmed; zero-spec-guess keepsake.
  - **WOOF-03:** gating hook — green + **8/8 tests** (kept); `borrowDriver` immutable + `NotAuthorizedOperator()`
    `0x3d9adf1c` + isProxy spoof-guard confirmed; zero-spec-guess keepsake.
  - **WOOF-04:** venue adapter (`IZipcodeVenue` + `LineAccount` + `EulerVenueAdapter`) — green + **20/20 tests on a
    LIVE Base-mainnet fork** (kept; EVK/EVC/EulerRouter live, EulerEarn mocked at 0.8.26). The DENSEST item, proven:
    two-line distinct-prefix BOTH-draw isolation (real `evc.batch` borrows), operator-grant authorizes-the-adapter,
    AmountCap `(mantissa<<6)|exponent` round-trip read back via `EVault.caps()`, `!=1e18` guard, router freeze,
    close-reclaim. Every external sig + the AmountCap encode re-verified vs `reference/` before keeping;
    zero-spec-guess keepsake (1 mild cap-seed clarification folded into the ticket).
  - **WOOF-05:** controller / CRE receiver (`is ReceiverTemplate`, 5-arg ctor, NO EVC) — green + **26/26 tests on
    a LIVE Base-mainnet fork** (102/102 total; independently re-run + source read). Live-proven: the
    no-controller-operator-wiring origination borrow (`isAccountOperatorAuthorized(borrowAccount, adapter)==true` &
    `(…, controller)==false`), the L4 full transcript (exact `1e18` escrow, `getQuote==equityMark`, both LTVs,
    `debtOf==drawAmount`, `allowance==0`), batch-atomicity (exact `E_AccountLiquidity()` `0x34373fbc` /
    `E_BorrowCapExceeded()` `0x6ef90ef1` + full no-orphan post-state + mid-batch rollback then re-origination),
    `create→openLine→seed→setLineLimits→fund→draw` ordering, reclaim-before-burn close, dispatch/dup, status
    markers 5/6, dormant-gate, reentrancy-impossible. **Zero EVC coupling confirmed** (only `ReceiverTemplate` +
    `IZipcodeVenue` imports); error selectors re-verified via `cast`; EVK/EVC/EulerRouter live, EulerEarn mocked
    (0.8.26). **Zero spec-guesses → no `claude-zipcode.md` edit;** zero-spec-guess keepsake confirmed.
  - **WOOF-10a:** deploy identity pre-gate (`library ZipcodeDeployAsserts`) — green + **5/5 tests** (107/107
    total; **no fork** — pure view over the real WOOF-02/05). The combined fail-closed `getExpectedWorkflowId()==0
    || controller()==0` → `IdentityNotWired` S11 gate proven across all three classes against the REAL receivers:
    NEGATIVE (3, exact selector+args), POSITIVE (renounce → `OwnableUnauthorizedAccount` on the inherited setters +
    `setController`), NEGATIVE-CONTROL (dormancy selector-difference — dormant → `UnsupportedReportType(3)`,
    gate-active → `InvalidWorkflowId`). Zero spec-guesses; no `claude-zipcode.md` edit; zero-spec-guess keepsake
    confirmed. Discharges (gate portion, now build-verified-kept) the item-10 F-3/F7 S11 rows.
- **DOC-ALIGNED ONLY + NOW STALE — DO NOT BUILD YET: WOOF-06, INFLOW-06.** Both are downstream of the item-8 Baal
  junior-vault design, which has a **post-Phase-8-S decision that invalidates the WOOF-06/INFLOW-06 tickets** (Exit
  Gate, locked 2026-06-06; memory `baal-zodiac-foundation`). The current tickets encode
  `depositFor(zipAmount, msg.sender)` → **on-behalf Loot to the user** + `Zapped(…loot)` + a raw-Loot
  `ZeroLoot`/`ResidualBalance` check. The Exit Gate **reverses** that: deposits mint **Loot to the gate**, the
  depositor gets a **soulbound szipUSD claim and never raw Loot**, and the substrate is **two Safes** (main Baal
  Safe + a non-ragequittable sidecar via `BaalAndVaultSummoner`). So the `depositFor` seam's receiver/return/event
  semantics all change. **Building WOOF-06 now would mint a keepsake against a seam the protocol has already
  decided to change** — exactly the rot keep-the-build exists to prevent. **BLOCKED until** 8-B1 (Baal+sidecar
  scaffold via `BaalAndVaultSummoner`) + 8-B2 (mint shaman **+ the Exit Gate**) land AND WOOF-06/INFLOW-06 are
  re-authored to the soulbound-claim shape. (INFLOW-06 is the frontend half — same blocker, verified vs
  `reference/euler-lite`.) The full **item-10 deploy/wiring script** (which absorbs WOOF-10a's gate at S11) is the
  natural next *contract* once the supply-side (item 7/8) lands.
- **Known recurring bug classes to hunt** (found in WOOF-00 — expect them elsewhere): guessed external interface
  signatures that don't match the real ABI; addresses that are the wrong contract; Base-mainnet-vs-Sepolia
  selector/RPC contradictions; euler-earn / other deps that pin a solc ≠ 0.8.24 and must be MOCKED, not imported.

## NEXT WINDOW — handoff (start here)
**The pure-Euler M1 contract spine is now ALL BUILT-VERIFIED + kept on disk: WOOF-00/01/02/03/04/05/10a (107/107,
fork tests via `$BASE_RPC_URL`; WOOF-10a's 5 are no-fork).** There is **no unblocked next build-verify item.** Do
NOT default to WOOF-06.

- **WOOF-06 / INFLOW-06 are BLOCKED + their tickets are STALE — do NOT build them.** They depend on the item-8
  Baal junior-vault design, which has a post-Phase-8-S decision (the **Exit Gate**, locked 2026-06-06; memory
  `baal-zodiac-foundation`) that **invalidates the current tickets**: the tickets mint `depositFor(zipAmount,
  msg.sender)` Loot **to the user**, but the Exit Gate mints Loot **to a gate** and gives the depositor a
  **soulbound szipUSD claim (never raw Loot)**, over a **two-Safe** substrate (main Baal Safe + non-ragequittable
  sidecar via `BaalAndVaultSummoner`). The `depositFor` seam's receiver/return/event/residual semantics all change.
  See the CURRENT STATE "DO NOT BUILD YET" bullet above for the full diff. **Unblock = 8-B1 (Baal+sidecar
  scaffold) + 8-B2 (mint shaman + Exit Gate) land, THEN WOOF-06/INFLOW-06 re-authored to the soulbound-claim
  shape, THEN build-verify.** (The WOOF-06/INFLOW-06 tickets still lack an Exit-Gate staleness banner — the user
  is managing the item-8 redesign thread and will handle the ticket re-author there.)
- **The item-8 Baal substrate (8-B1/8-B2 + the Exit Gate) is the user's redesign thread, NOT a build-verify item
  for this pass.** Phase 8-S's spec foundation (§6.4/§11/§12 + audit/1 / 8-S3) was derived on the now-retired
  withhold model ("per-depositor matched loot+asset moves was WRONG"), so the spec itself may need a re-pass before
  those build tickets are authorable. Do not start it from this seat without the user.
- **The full item-10 deploy/wiring script (§9)** is the natural next *contract* once the supply-side (item 7/8)
  lands; it absorbs `ZipcodeDeployAsserts.requireIdentityWired` at S11 (now build-verified) + the 5-arg ctor /
  `setController`@S6 / curator-timelock-0 / `baseUsdcMarket` wiring (the still-OPEN clauses of the F-3/F7 rows).
  But it depends on the supply-side too, so it is not unblocked yet either.

**Net: the M1 Euler lending spine is build-complete + verified; everything downstream waits on the item-8 Baal
redesign the user is driving.** If a future window IS handed an unblocked, re-authored ticket: follow the proven
build loop below — dispatch a build subagent to materialize from the ticket alone, then independently re-run +
read the source + spot-check, then run the full doc-update checklist.

## The proven build loop (used for WOOF-00/01/02/03 — follow it)
1. Read the ticket + inbound obligations.
2. **Dispatch a build subagent** to materialize the contract + tests **from the ticket alone** against the real
   scaffold, `forge build` + `forge test`, KEEP the files, and report REAL output + any guesses/findings (give it
   hard anti-fabrication rules: paste real output, a failure is a valid result, never claim an unobserved pass).
3. **Independently verify — do NOT trust the subagent:** re-run `forge test` yourself AND **read the contract
   source** to confirm the logic is real (the subagent wrote the tests, so green-tests alone can be circular).
   Spot-check the load-bearing claims (fork reads, selectors, addresses) with your own `cast`.
4. **Run the doc-update checklist** (step G below). 5. Update this file's CURRENT STATE + worklist.

## Per-item procedure (the WOOF-00 method — do this for each item in the worklist)
For item N (a `(ticket, report)` pair):

A. **Read** the ticket + its current report (per `reports/README.md`) + any inbound obligations owed by this item
   (`tickets/PROGRESS.md` → Open cross-ticket obligations).
B. **Materialize the contract + its tests from the ticket alone**, into `contracts/src/...` (+ `test/`). Build on
   the real WOOF-00 scaffold (it's already on disk). Where the ticket under-specifies something you must write,
   note it as a **guess** — that is itself a finding about ticket quality.
C. **`forge build` then `forge test`** (fork tests via `$BASE_RPC_URL`). Paste/observe REAL output. A failure is a
   valid, valuable result — never paper over it; fix and re-run.
D. **On-chain-verify the load-bearing facts (the step the doc layer can't do):**
   - Every external **interface signature** the contract calls → confirm the selector exists on the real deployed
     contract (`cast call`/`cast sig`/bytecode probe) or against vendored/verified source. (WOOF-00: 10 of 25 were
     wrong.) Fix the interface to the real signature.
   - Every hardcoded **address** → confirm it has code AND is the claimed contract (an identity getter:
     `name()`/`VERSION()`/`typeAndVersion()`/a known selector; or the authoritative deployment JSON). (WOOF-00: 2
     were the wrong contract.) Fix at the source-of-truth doc too (`BaseAddresses.sol`, `pending-docs/hydrex.md`).
   - Confirm any inherited base (e.g. `ReceiverTemplate` non-virtual) against `reference/`.
E. **Triage every fix:** (i) **ticket gap** → fix the ticket; (ii) **spec gap / spec is wrong** (a wrong address,
   signature, or contradiction in `claude-zipcode.md`) → **fix `claude-zipcode.md` FIRST**, then the audit harness
   (`audit/2.md`/`audit/3-results.md`) as a consequence, then the ticket. Apply `--preserve-intent`: don't sand
   off locked §17 choices.
F. **KEEP the code** — `contracts/src/...` + tests committed, `forge build` green. Do NOT reset to skeleton.
G. **UPDATE EVERY TRACKING DOC (mandatory — this is part of the procedure, not a separate request).** See the
   checklist below. Then mark the item **BUILT-VERIFIED** in the worklist + the CURRENT STATE block above.

## THE DOC-UPDATE CHECKLIST (run this every time, after the build test — do NOT wait to be told)
After item N builds green + is on-chain-verified, update **all** of these so the repo is self-consistent:
1. **The ticket** (`tickets/woof/WOOF-NN-*.md`): add a "MATERIALIZED + BUILDS GREEN <date>" banner; fold in every
   signature/address correction the real build exposed; fix any internal contradiction the build surfaced.
2. **The report** (`reports/WOOF-NN-report.md`): status → MATERIALIZED; real build evidence (what compiled, what
   tests pass); the corrections found; an honest boundary (what's still mocked / unverifiable).
3. **`reports/README.md`**: update the item's row note ("materialized + builds green; N corrections").
4. **`tickets/LEDGER.md`**: extend the component digest — built + corrections + obligations (discharged/created).
5. **`tickets/PROGRESS.md`**: flip the backlog status row to BUILT-VERIFIED; mark any **discharged obligations**;
   add a **Session-log entry** (newest at the top of the log) describing what the build exposed + fixed.
6. **`README.md`** (root): check any relevant `[ ]` checklist box for this item; note materialized if applicable.
7. **`claude-zipcode.md`**: ONLY if the build exposed a **spec** error (a wrong address/signature/contradiction in
   the spec itself). Spec-gap edits go here FIRST, then the audit harness, then the ticket (§3a editing discipline).
8. **Source-of-truth address docs** (`contracts/script/BaseAddresses.sol`, `pending-docs/hydrex.md`): fix any
   wrong address at its origin, not just at the call site.
9. **This file's CURRENT STATE block + the worklist row** → mark BUILT-VERIFIED.

## Worklist — items to BUILD-VERIFY (status honest as of 2026-06-06)
Build-priority = dependency order. The pure-Euler items (01–05, 10a) can be fully materialized + fork-tested now;
WOOF-06 leans on Baal/warehouse seams that are still unbuilt (8-B), so it can only be built against mocks until
8-Bw/8-B1/8-B2 exist; INFLOW-06 is a frontend interface ticket (verify against `reference/euler-lite`, not `forge`).

| # | Item | Ticket | Status |
|---|---|---|---|
| 0 | Foundry scaffold | `tickets/woof/WOOF-00-scaffold.md` | **BUILT-VERIFIED 2026-06-06** — materialized, `forge build` green, 3 self-checks pass (incl. live fork read), address book on-chain-verified (2 address bugs + 10/25 sigs fixed). The template. |
| 1 | `LienCollateralToken` + factory | `tickets/woof/WOOF-01-lien-collateral-token.md` | **BUILT-VERIFIED 2026-06-06** — materialized, `forge build` green + **14/14 tests pass**, code kept; zero-spec-guess keepsake (no build-exposed errors). |
| 2 | `ZipcodeOracleRegistry` | `tickets/woof/WOOF-02-oracle-registry.md` | **BUILT-VERIFIED 2026-06-06** — materialized (`is ReceiverTemplate, BaseAdapter` + 2 remaps), `forge build` green + **34/34 tests pass**, code kept; scale identity + strict-decimals proven; zero-spec-guess keepsake. |
| 3 | `CREGatingHook` | `tickets/woof/WOOF-03-cre-gating-hook.md` | **BUILT-VERIFIED 2026-06-06** — materialized, `forge build` green + **8/8 tests pass**, code kept; `borrowDriver` immutable + `NotAuthorizedOperator()` `0x3d9adf1c` + isProxy spoof-guard confirmed; zero-spec-guess keepsake. |
| 4 | `EulerVenueAdapter` + `LineAccount` | `tickets/woof/WOOF-04-venue-adapter.md` | **BUILT-VERIFIED 2026-06-06** — materialized + kept; `forge build` green + **20/20 tests on a live Base-mainnet fork** (76/76 total, no regression; independently re-run). The densest item, proven: two-line distinct-prefix BOTH-draw isolation (real `evc.batch` borrows), operator-grant authorizes-the-adapter, AmountCap `(mantissa<<6)\|exponent` round-trip via `EVault.caps()`, `!=1e18` guard, router freeze, close-reclaim; EVK/EVC/EulerRouter live, EulerEarn mocked (0.8.26). Every external sig + AmountCap encode re-verified vs `reference/`; zero-spec-guess keepsake. |
| 5 | `ZipcodeController` | `tickets/woof/WOOF-05-controller.md` | **BUILT-VERIFIED 2026-06-06** — materialized + kept; `forge build` green + **26/26 tests on a live Base-mainnet fork** (102/102 total, no regression; independently re-run + source read). 5-arg ctor / **zero EVC coupling** (only `ReceiverTemplate`+`IZipcodeVenue` imports) / `create→openLine→seed→setLineLimits→fund→draw` ordering / reclaim-before-burn / the no-controller-operator-wiring origination borrow / batch-atomicity (exact `E_AccountLiquidity()`/`E_BorrowCapExceeded()` + no-orphan post-state) / dormant-gate all live-fork-proven; error selectors re-verified via `cast`; EVK/EVC/EulerRouter live, EulerEarn mocked (0.8.26). Zero spec-guesses; no `claude-zipcode.md` edit (zero-spec-guess keepsake confirmed). |
| 6 | `ZipDepositModule` (zap) | `tickets/woof/WOOF-06-deposit-module.md` | **DOC-ALIGNED ONLY — code UNVERIFIED.** Build against mocks for the `depositFor` (8-B2) + `CreditWarehouse` (8-Bw) seams (both unbuilt); verify `ESynth`/`EE_POOL` faces against `reference/`. |
| 6i | `INFLOW-06` (zap interface) | `tickets/inflow/INFLOW-06-deposit-module.md` | **DOC-ALIGNED ONLY.** Frontend ticket — verify against `reference/euler-lite` (events/views the build exposes), not `forge`. Lower priority. |
| 10a | Deploy identity pre-gate | `tickets/woof/WOOF-10a-deploy-identity-gate.md` | **BUILT-VERIFIED 2026-06-06** — materialized + kept; `forge build` green + **5/5 tests** (107/107 total, no regression; no fork — pure view over the real WOOF-02/05). Combined fail-closed `getExpectedWorkflowId()==0 \|\| controller()==0` → `IdentityNotWired` gate proven across NEGATIVE (3) / POSITIVE (renounce → frozen setters) / NEGATIVE-CONTROL (dormancy selector-difference) against the REAL receivers; zero-spec-guess keepsake. Discharges (gate portion, build-verified-kept) the item-10 F-3/F7 S11 rows. |

## Output per item + the certification goal
Per item: a verdict — **BUILT-VERIFIED** (compiles + tests green + interfaces/addresses on-chain-verified, code
kept, all docs updated), **BUILD-FAILED** (what failed — a valid result, report it), or **BLOCKED** (a real
dependency is unbuilt — name it). Plus anything that needs the **user's** decision.

**Certification (the honest bar):** the build set is "coherent and ready" ONLY when every worklist item is
**BUILT-VERIFIED** — committed code that compiles, tests green, with interfaces + addresses checked against the
live chain. A document-aligned-only item is NOT certified. State plainly which items are real and which are still
prose, and never re-issue a prose-only "ready to build" certification.

## Standing concerns (carry across the pass)
- **Verify, don't trust — including your own subagents.** Re-confirm a subagent's "verified" claim with a direct
  `cast`/source check before folding it (a subagent's report is a claim, not proof). WOOF-00's Baal fix was
  re-verified against the deployment JSONs before editing.
- **A green build is not a green light.** "Compiles" only means the stub is well-formed; the interface might still
  not match the real ABI. Selector-probe the live contract.
- **Spec errors edit `claude-zipcode.md` first** (§3a discipline), then the audit harness, then the ticket. Don't
  bend the spec to match a ticket that drifted.
- **Locked §17** is not reopened without user ratification.
- **No emojis; contract-cited technical scope, not narrative** (project memory).
- **Don't fracture live work / don't clobber a concurrently-edited file** — re-read the exact region right before
  editing a shared doc (`PROGRESS.md`/`LEDGER.md`).
