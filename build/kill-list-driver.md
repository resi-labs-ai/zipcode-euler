# Kill-list driver — paste this to a fresh Claude

> Copy everything below the line into a new Claude Code session in `/Users/root1/zipcode-euler`.
> It is self-contained: the agent reads the kill-list and source docs itself, so this session's
> context does not need to be carried over.

---

You are resuming a smart-contract remediation effort on the Zipcode protocol
(`/Users/root1/zipcode-euler`). A two-pass audit triage is already done and written to
**`build/kill-list.md`** — read it in full first. It is the single source of truth: 16 FIX,
14 DOC, 3 DISMISS, 3 DEFER items, each with a verified disposition, file:line, and the exact
fix (or why a proposed fix was rejected). Every item traces to the docs listed in its
"Source docs" header.

## Your job
Work the FIX and DOC items **one at a time**, as tickets, tracking progress in
`build/tickets/PROGRESS.md`. Do NOT batch-edit across items — one ticket, one focused change,
verify, mark done, next.

## Ticketing convention (match existing tickets)
- New track folder `build/tickets/sec/`, IDs `SEC-01`, `SEC-02`, … (one per kill-list FIX line;
  the grouped items — Group 1 oracle guards, Group 2 coverage double-count, Group 3 venue — are
  **one ticket each**). Roll all DOC items into a single `SEC-DOC` sweep ticket.
- Ticket file `sec/SEC-NN-{slug}.md` follows the format of existing tickets (look at
  `build/tickets/frontend/FE-01-*.md` and `cre/CRE-02-*.md`): Header/Status, Deliverable,
  Binds-to (verified file:line from the kill-list), Do-NOT, Key requirements, Done-when
  (green build + new regression test + the kill-list acceptance), Depends-on.
- Update `PROGRESS.md`: add a `## SEC track` section, list SEC-NN with status, move to "Just
  done" with a one-line finding note as each lands.

## Suggested order (correctness-first)
1. **Group 1** (H1/M1/L3 oracle monotonic guards) — smallest, highest-leverage.
2. **Group 2** (M2/L14 coverage double-count) — scope `pathLockedLpEquity()` to mainSafe-only.
3. **H4** (CCIP admin handoff) — HIGH, deploy-script + interface change.
4. **H5** (`_xAlphaUSD` fail-close), **M4** (seal lpOracle), **H2/L8** (`closeLine` prune+defund).
5. Remaining standalone FIX: M6, M7, L2, L9, L11, L12, L18, I6.
6. **SEC-DOC** sweep last.
7. Leave DISMISS (H3/L5/L10) and DEFER (drawgate/covguard/exitbook) untouched — just keep the
   `loot.paused()` test (H3) and add the deploy invariants the kill-list names.

## Load-bearing caveats (the kill-list explains each — do NOT skip)
- **Oracle guards won't compile** unless you also `declare error StaleReport();` at each site.
  H1's guard goes in **shared `_writePrice`** (covers the `seedPrice` draw-path clobber). Use `<=`.
- **Group 2 fix lands in `coverageValue`/the oracle view, NOT in `committedValue`** (that breaks
  `freeValue` and the Committed/Released events).
- **L18:** `_disableInitializers()` does **not exist** in zodiac-core's `Initializable` (OZ-only).
  Use the `reference/zodiac-core/.../test/TestModule.sol` constructor-`setUp` idiom.
- **M7:** do NOT key a tally by provision value (it's a re-markable scalar) — use
  `lastSeenProvision` + `divertedSinceProvisionChange` with reset.
- **M8 (DOC):** REJECT the `capitalSlashAmount <= recoveryProceeds` assert — unit-incoherent
  (xALPHA bond units vs USD) and no such param. Just reconcile the header docstring.
- **L4 (DOC):** REJECT per-key try/catch — it weakens the intentional fail-closed batch.
- **H3 (DISMISS):** REJECT the audit's `lockAdmin()` fix — `adminLock` does not pin the pause flag.
- **M4 / lpOracle sealing** must be **conditional on `d.lpOracle != address(0)`** (fair-LP branch
  leaves it unset).
- **M5** deploy-time non-zero assert already exists (`DeployZipcode.s.sol:411,439`) — only the
  `setCoverageGate(0)` warning event is owed.

## Verification per ticket (required before marking done)
- `cd contracts && forge build` clean.
- `forge test` green; **add a regression test** that fails before the fix and passes after
  (e.g. stale-ts replay reverts; donated sidecar LP no longer inflates `covered()`; queue prunes
  on `closeLine`). Name it after the SEC ID.
- For deploy-script fixes (H4, M4, M6, M5): re-run the relevant deploy script against a fresh
  anvil fork and assert the new invariant (admin == timelock pending; lpOracle identity sealed; etc.).
- Quote the actual test output in the ticket's done note. If a fix touches `reference/`-mirrored
  behavior, re-open the cited `reference/**` file to confirm before editing.

## Guardrails
- Read each kill-list item's file:line **and the cited source doc** before editing — the
  dispositions encode subtleties (e.g. §7 asymmetry must be preserved: H5 fails closed on
  *unseeded*, it does NOT gate exit on `fresh()`).
- This is auditor-prep: prefer minimal, surgical, well-tested diffs over refactors. The
  CoverageGuard refactor and other DEFER items are explicitly out of scope.
- After the FIX + DOC tickets land: fresh anvil deploy → update `build/wires/` docs → build CRE
  → revisit frontend (that ordering is the project's next phase, noted at the bottom of the kill-list).

Start by reading `build/kill-list.md` end to end, then propose the `SEC-01` ticket (Group 1) and
wait for confirmation before writing code.
