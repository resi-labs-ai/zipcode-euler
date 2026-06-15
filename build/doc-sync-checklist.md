# doc-sync-checklist.md — run at Conclude, after the gate is green

The harness Conclude step (`harness.md` §4 Step 5) names the ticket, PROGRESS, spec, and report — but a FIX that
changes built-contract behavior also has **backward-facing truth-sources** to keep in sync. Run this whole list at
Conclude, after `forge build` + `forge test` are green, before (or with) the commit.

## The list

1. **The ticket** (`build/tickets/<track>/<ID>-*.md`) — status → DONE; add a Done-note with quoted `forge test`
   output; fold back any downstream-test breakage or operational consequence you discovered (so the ticket is
   self-sufficient for a cold rebuild).
2. **`build/tickets/PROGRESS.md`** — mark the item DONE, set the next `NEXT`, add a "Just done — <ID>" note, and log
   any **new obligation/seam** the fix created (Open obligations section + the relevant backlog row).
3. **`build/kill-list.md`** (the consolidated tracker) — flip the item's `[ ]` → `[x]` and append
   `**DONE <date> (<ID>).**`.
4. **`build/audit-claude/`** (the origin record) — mark the originating finding RESOLVED in both the summary table
   and its `fix:` line, in `findings.md` and/or `interconnection-findings.md` / `reference-diff-findings.md` /
   `role-based-findings.md` as applicable.
   - ⚠️ **The kill-list ID ↔ audit finding number is NOT 1:1** — map it. (Example: SEC-01's H1 resolved findings
     **#1 AND #3**; its M1/L3 siblings had no separate numbered findings — they were derived during kill-list
     consolidation, so they cross off only in the kill-list.)
5. **`build/wires/` truth-source for every CHANGED contract** ⚠️ *the most-missed step.* Look up the owning wire doc
   in **`build/wires/COVERAGE.md`** (contract → wire doc), then update any **enumerated guard/behavior list** so it
   matches the built contract. A `_writePrice`/`_processReport` guard list that no longer matches the code is a stale
   truth-source. (SEC-01 touched 3 contracts → 3 wire docs: `WOOF-02`, `8-B4-SzipNavOracle`, `8-B5-ReservoirLoop`.)
6. **`build/claude-zipcode.md` (spec)** — only if the *mechanism/intent* changed (rare for a FIX; the spec rules
   intent, the contract rules interface). If unchanged, state "no spec change" explicitly in the report and why.
7. **`build/reports/<ID>-report.md`** — written: what the window did · decisions to sanity-check · holes → resolution
   · doc edits · status + NEXT.
8. **PROGRESS "Deletion triggers" section** — check whether the completed work fires any forward-artifact deletion.

## Before commit
`git status` should show only the contract/test files + the docs above. Commit code + doc-sync together, or as two
focused commits (SEC-01 did: one for code+tests, one for the doc sync). Never stage layer (`frontend/...`) code in the
monorepo.

## Worked example
SEC-01 (2026-06-15) is the reference application of this list — see `build/reports/SEC-01-report.md` "Doc edits" and
the two commits `dcc6417` (code+tests) / `73685f6` (doc sync).
