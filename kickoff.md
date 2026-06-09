# kickoff.md — paste this to start each authoring window

You're authoring zipcode-euler build tickets, **one item per context window**. This window: complete exactly
ONE item, conclude it on disk, then STOP for review. Do not mass-produce.

1. **Read `nextsteps.md`** — it orients you and points to the harness playbook
   (`audit/adversarial-spec/README.md`) and the format model (a **filed ticket** — `sample-ticket.md` is
   retired; model `tickets/woof/WOOF-01-lien-collateral-token.md` + the `WOOF-06`/`INFLOW-06` build+interface
   pair). Auto-loaded memory holds the method; the docs are authoritative.
2. **Read `tickets/PROGRESS.md`** — the ledger. The item marked **`NEXT`** is your task. The build is
   **mid-stream** (items 1–7 + 10a have **drafted tickets**; their original cold-builds were **discarded and are
   unverified** — under the new keep-the-build doctrine they each need real materialization + on-chain interface
   verification, exactly as WOOF-00 got; **item 8 — the Baal/Zodiac `szipUSD` vault — is the current design
   chain**, decomposed into `8-Bw` + `8-B1…8-B12`). **Only WOOF-00 is currently materialized + building green on
   disk** (`contracts/`).
3. **Author that item via the harness loop** (`audit/adversarial-spec/README.md`):
   - **Check `tickets/PROGRESS.md` → "Open cross-ticket obligations" for rows owed by this item** — the ticket
     MUST discharge each (the critics verify); mark them `DISCHARGED` at Conclude. (Its source digest is in `LEDGER.md`.)
   - Draft the ticket(s): **build** always; an **interface** ticket only if the item is user-facing (most
     WOOF contracts are build-only — internal plumbing).
   - Fan out the critic subagents in parallel (tiered: junior-developer + spec-fidelity + reference-verifier
     always; add qa-engineer + security-engineer for foundational/intricate contracts; frontend-integration
     for any interface ticket).
   - Synthesize + **TRIAGE**: spec-gap → fix `claude-zipcode.md` FIRST and log it in `PROGRESS.md`;
     ticket-gap → fix the ticket. Preserve intent.
   - **Build it for real and KEEP it (doctrine, 2026-06-06).** Materialize the contract + its tests from the
     ticket, get `forge build` + `forge test` green, and **commit the code under `contracts/`**. The code is the
     **proof**; the ticket is the **intent**. **Do NOT discard the byproduct** — the old "reset `contracts/` to
     its `.gitkeep` skeleton" rule is **RETIRED**: it was the root cause of unverifiable, rotted "cold-build
     PASSED — byproduct discarded" claims (WOOF-00, kept and re-checked, then exposed a selector contradiction,
     10-of-25 wrong interface signatures, and two "CONFIRMED" addresses that were the wrong contract). For
     anything verifiable — **signatures, addresses, does-it-compile — the code is the source of truth, not the
     ticket.** VERIFY every external interface signature and every hardcoded address **against the live chain**
     (Basescan / `cast` against `BASE_RPC_URL`), not merely "it compiles" (a stub always compiles).
4. **Conclude** (so a fresh window resumes with no history): file the ticket(s) in `tickets/<team>/`; **commit the
   built code** (`contracts/src/...` + tests, `forge test` green); update `tickets/PROGRESS.md` (mark the item
   DONE, set the next `NEXT`, log the session line + any spec fix / deferred gap). In PROGRESS/LEDGER, record
   **"code at `contracts/src/X.sol`, `forge test` green — run it yourself"**, NOT "cold-build YES, discarded".
5. **Write `reports/<ITEM-ID>-report.md`** to the superintendent (model `reports/WOOF-01-report.md`): what the
   pass found, the spec/audit edits, design decisions to sanity-check, and any judgment calls. Then **STOP** —
   your window is disposable; the superintendent (`superintendent.md`) reviews it and releases the next window.

**Rules:** one item only. "Model from" must be VERIFIED against the actual `reference/` code, not cited. Do
not reopen locked `claude-zipcode.md` §17 decisions. Spend the tokens needed for quality; an item that comes
back with no findings is a flag to be skeptical, not a win.

**Prerequisite already satisfied in this checkout:** `reference/` submodules are initialized.
