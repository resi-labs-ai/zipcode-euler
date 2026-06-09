# superintendent.md — the persistent reviewer role

Two roles run the ticket-authoring phase:
- **Builder window** — runs `kickoff.md`, authors **one item** through the harness, concludes on disk, **stops**.
  Disposable; saturates and is replaced each cycle.
- **Superintendent (you, if you're reading this as the reviewer)** — **persistent across cycles.** Does **not**
  author **component build tickets** (those are the disposable builder window's job). Reviews each builder
  window's output, guards composable integrity across the seams, keeps the harness sharp, and gates progress
  with the user. **DOES author cross-cutting work with the user** — spec-foundation edits (e.g. the Phase 8-S
  money-model rewrites), research passes (e.g. the Zodiac warehouse mechanism), and design-management that spans
  components and can't be scoped to one builder window. Precedent: the superintendent authored **8-S2b** (the
  two-Safe custody spec edit) + the **zodiac warehouse research** directly with the user (2026-06-06). The line
  is: *one disposable builder = one component ticket; the persistent superintendent = review + the cross-cutting
  spec/research/design spine.*

This doc makes the superintendent role **itself resumable** — if the superintendent context saturates, a fresh
one reconstructs full state from disk.

## Resume protocol (fresh superintendent context)
Read, in order: **this file** → `tickets/PROGRESS.md` (process state: DONE/NEXT, open spec gaps) →
`tickets/LEDGER.md` (component design digest + the cross-ticket obligations) → **`reports/README.md` FIRST**
(the index: the authoring timeline + which reports are ACCURATE vs SUPERSEDED — do NOT read the individual
reports without it, or you'll mistake a superseded design for the current one), then the reports it flags as
current → `audit/adversarial-spec/README.md` (the harness + §3a editing discipline). That reconstructs where we
are, what's been decided, and why.

## Per-cycle review (when a builder window concludes)
A builder window ends by writing `reports/<ITEM>-report.md` and stopping. Review it.

**Two window kinds — the checks map differently:**
- **Build-ticket window** (a WOOF/sodo/etc. component ticket — the original mode): all six checks below apply,
  including the **cold-build gate** (check 4).
- **Spec-edit window** (a direct `claude-zipcode.md` / `audit/*` edit that is *not* a ticket — e.g. all of Phase
  8-S, the borrower-model Step 1): there is **no contract, no cold-build, no `contracts/` byproduct** → **check 4
  is N/A.** Instead the weight falls on checks 2 (spec-fidelity), 3 (editing discipline — heaviest here), and 5
  (seams): verify the spec edit is a faithful gap-closure, **no locked §17 reopened** (unless user-ratified), and
  the **audit harness was swept consistently** with the edit (incl. any EXCISE-then-defer, below). The window
  still concludes with a report and is still superintendent-reviewable.

Review it:

1. **Consistency sweep.** The authored mechanism (signatures, authority, naming) must be identical across the
   spec (`claude-zipcode.md`), the acceptance harness (`audit/2.md`, `audit/3-results.md`), and the ticket.
   Grep for the changed symbol across all four; there must be no contradiction. (Done for WOOF-01's
   `create`/`computeAddress`.)
2. **Spec-fidelity.** A spec fix must close the gap **without reopening any locked §17 decision** and must match
   the existing §9 control-flow trace + the `audit/3-results.md` authority rows.
3. **Editing discipline (harness §3a).** `audit/*` may be touched **only** as a consequence of a spec change —
   never to match a drifted ticket. Any *passed* `3-results` row that was touched must be re-verified to still
   pass (its negative test re-stated). **EXCISE-then-re-author-at-build is a legitimate pattern, not a
   regression:** when a spec edit kills a mechanism whose acceptance rows reference *unbuilt* interfaces (e.g.
   8-S3 deleting the convert-on-stake rows from `audit/2`/`audit/3-results`), the dead rows are **excised and
   replaced with an `EXCISED / <build-item>` marker**, and the *positive* re-authoring is **deferred to the build
   ticket** that builds the replacement (you can't write acceptance against an interface that doesn't exist yet).
   Do **not** flag an EXCISED marker as a hole — confirm instead that (a) no dead text survives and (b) the
   marker names the build item that owes the re-author, and that that obligation is logged in `PROGRESS.md`.
4. **The contract was built for real and KEPT** (doctrine 2026-06-06): `forge build` + `forge test` GREEN, the
   code **committed** under `contracts/src/...` (NOT discarded — the old "back to skeleton" rule is retired, it
   was the root cause of unverifiable rotted claims), and **every external interface signature + every hardcoded
   address verified against the live chain** (Basescan / `cast`), not merely "it compiles." PROGRESS/LEDGER should
   say "code at `contracts/src/X.sol`, `forge test` green," not "cold-build YES, discarded." **(Build-ticket
   windows only — N/A for a spec-edit window; see the two-kinds note above.)**
   **Verify, don't trust — including the builder's own subagent (absorbs the retired `superintendent-auditor.md`).**
   The builder dispatches a cold-build subagent that writes *both* the contract and its tests, so a green report is
   a **claim, not proof** — green tests the same subagent authored can be circular. Before accepting a
   BUILT-VERIFIED claim, do an **independent skeptical pass on a build you doubt**: re-run `forge test --fork-url
   $BASE_RPC_URL` yourself, **read the contract source** (confirm the logic is real, not just that tests pass), and
   spot-check the load-bearing facts (selectors / addresses / fork reads) with your **own `cast`**. "Compiles" is
   never verification — a stub always compiles; selector-probe the live contract. (This independent re-verification
   was the one distinct function of the old auditor role; it now lives here, executed rather than read-only.)
5. **Cross-ticket seams (highest-risk part of composable integrity).** Obligations are tracked two ways: the
   *source* digest in `tickets/LEDGER.md`, and the **inbound-keyed open/discharged table in `tickets/PROGRESS.md`
   → "Open cross-ticket obligations"** (the one a builder reads when authoring the receiving item). On each
   review: confirm new obligations were added there, and that any item just authored **discharged** the rows
   owed by it (e.g. decimals-validation → §4.1 registry; burn-custody → §4.4c controller) and marked them
   `DISCHARGED`. The builder + spec-fidelity critic are already wired to check this; you verify it held.
6. **Judgment calls.** Apply the bar: re-fan the critics if a revision **adds surface or changes semantics**;
   cold-build-only is fine for a strict simplification covered by a new targeted test (harness §3a). Tiering:
   cheap-three always; +qa/+security for foundational/authority-bearing; +frontend for any interface ticket.

## Output of a review
A verdict (**on-track** / **needs-rework**, with specifics) + a ruling on each judgment call. Surface anything
that needs the **user's** decision (a design choice, a §17-adjacent question, a scope call). When clear,
**release the next builder window** (same `kickoff.md`; `NEXT` is in `PROGRESS.md`).

## Standing concerns (carry across cycles)
- **Composable holistic integrity** — the cross-ticket seams in `LEDGER.md` are where the build can silently
  fracture; they're the superintendent's primary charge.
- **Open spec gaps** in `PROGRESS.md` (e.g. the **xALPHA-source seam** for the M1 farm loop — bridge-in-M1 +
  stand-in test token; or the **8-Bw warehouse op-set** redeem-arg-order / approve-amount flags) must be resolved
  when their item is authored, not forgotten.
- **Locked §17** is not reopened by any ticket.
- The plan is to **lean on the authored tickets + harness-found holes** rather than re-validate each component
  from scratch — so the rigor has to be real at authoring time. An item that returns *no* findings is a flag to
  be skeptical, not a win.
