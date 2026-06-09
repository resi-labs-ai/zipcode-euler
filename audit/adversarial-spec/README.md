# Ticket-authoring harness (adversarial-spec methodology on Claude subagents)

This is the validated playbook for authoring one ticket. A fresh Claude follows it end-to-end.

**What it is.** We run the `adversarial-spec` *methodology* — multi-perspective adversarial critique →
synthesize → converge — but on **Claude subagents** (the Agent tool), not the external plugin
(`reference/adversarial-spec/` is the source of the persona/critique method; we don't need its API keys).
Claude is the **active synthesizer**, not just an orchestrator.

**Output = a two-ticket pair per component:**
1. **Build ticket** → the build team (WOOF/CRE/subnet). How to build the thing (contract internals + behavior).
2. **Interface ticket** → Inflow. How it connects (the events/views it exposes + how the Vue frontend wires to
   it), modeling `reference/euler-interfaces` (ABI/interface surface) + `reference/euler-lite` (the Vue wiring).

The interface ticket's job is to **back-pressure the build ticket** — it forces the contract to expose the
events/view methods the frontend needs. (Proven on the zap shakedown: the frontend critic forced a `Zapped`
event + `convertToAssets`/`previewZap` views the build ticket had omitted.)

---

## The per-ticket loop

### 1. Draft both tickets
Each ticket = `README.md` §4 task × the cited `claude-zipcode.md` § × a **verified** `reference/` model. Use
the field format in `sample-ticket.md` (Deliverable · Spec § · Model from · Starting state · Do NOT · Key
requirements · Done when · Depends on). **"Model from" must be verified by inspecting the reference, not
cited** — resolve inherit / replicate / interface-only by looking at the actual code (the zap pass found
`SZIPUSD.stake` doesn't exist — szipUSD models `EulerSavingsRate` ERC-4626 `deposit(assets,receiver)`).

**Discharge inbound obligations.** First check `tickets/PROGRESS.md` → "Open cross-ticket obligations" for any
rows **owed by this item** (e.g. the registry §4.1 owes WOOF-01 a `decimals() == LIEN_DECIMALS` validation).
The ticket MUST satisfy each — make it a Key requirement with a Done-when test. These seams are where
composable integrity is won or lost; mark them `DISCHARGED` in PROGRESS at Conclude.

### 2. Fan out the critic subagents (parallel)
Spawn these in one batch. Each reads the draft(s) + the cited spec § + the cited reference, and returns a
numbered findings list from its lens. Roles (adapt to ticket type):

| Role | Lens | On which ticket |
|---|---|---|
| **junior-developer** | ambiguity / tribal knowledge / "can't tell what to import or do" | both |
| **spec-fidelity** | faithful to the cited §; invents no mechanism; honors locked §17 | both |
| **reference-verifier** | does "Model from" resolve — inherit/replicate/interface; do cited paths/lines exist | both |
| **qa-engineer** | is "Done when" verifiable; missing tests / edge cases / atomicity | build |
| **security-engineer** | attack surface; authority/gating vs §13/§4.3; custody/reentrancy | build |
| **frontend-integration** | required contract surface (back-pressure) + euler-lite modeling specifics | interface |

**Cost tiering:** always run the cheap high-value three (junior-developer, spec-fidelity, reference-verifier).
Add qa/security/frontend on heavier or user-facing tickets. (Six critics ≈ 240k tokens.)
Prompt templates: see "Critic prompts" below.

### 3. Synthesize + TRIAGE (the critical step)
Merge all findings. **Triage each into one of two buckets:**
- **Spec gap** (the spec under-defines the mechanism) → **fix `claude-zipcode.md` FIRST**, then re-derive the
  ticket. (The zap pass found three §4.5 gaps: on-behalf stake, the `stake`/`deposit` naming, the unnamed
  share-custody account. A ticket can't be authored around a spec hole.)
- **Ticket gap** (the spec is fine, the ticket is unclear/incomplete) → fix the ticket.

Apply `--preserve-intent`: don't let critics sand off deliberate choices (event-driven Proof, no on-chain
liquidation, strict junior-first-loss). Claude owns this synthesis and reviews the result.

### 3a. Editing discipline (which authoritative docs you may touch, and when to re-critique)
- **A spec gap edits `claude-zipcode.md`** (the source of truth). When that changes a mechanism the acceptance
  harness references, **also update `audit/2.md` + `audit/3-results.md` to track it** — they are *spec-derived*,
  not a frozen oracle; an un-updated harness would contradict the spec. **But touch `audit/*` ONLY as a
  consequence of a spec change — never to match a ticket that drifted from spec.** Re-verify any *passed*
  `3-results` row you touch still passes under the new spec (re-state its negative test). This is safe because
  authoring retains no code — there is no implementation to bend the oracle toward.
- **Re-fan the critics vs cold-build-only on a revision:** re-fan if the change **adds surface or changes
  semantics**. **Cold-build-only suffices for a strict simplification** that removes *redundant* surface AND is
  covered by a new targeted test proving the removed guard was redundant (e.g. WOOF-01's two-arg `create` + gate
  → one-arg caller-bound, proven by an explicit squat-proof test).

### 4. Build the contract for real — and KEEP it (doctrine flip, 2026-06-06)
A fresh Claude subagent builds the contract + tests **from the ticket alone** (still the zero-guess gate: it must
return **zero load-bearing guesses**, Harness verdict below) — then `forge build` + `forge test` GREEN, and the
code is **committed under `contracts/`, NOT discarded.** Fold any ticket-quality findings back into the ticket.

> **The old "discard the byproduct / reset `contracts/` to `.gitkeep`" rule is RETIRED — it was the root cause of
> the project's worst failure mode.** "Cold-build PASSED 32/32 — byproduct discarded" referred to code that no
> longer existed and could never be re-checked, so the claims rotted as the spec churned. When WOOF-00 was instead
> **kept and re-verified**, that single contract exposed a CRE-selector contradiction, **10 of 25 wrong external
> interface signatures**, and **two "CONFIRMED, repo-authoritative" addresses that were the wrong contract** (an
> ICHI "factory" that was a Gnosis Safe; scrambled Baal summoner labels). None of it was visible at the prose
> layer. **So: the code is the proof, the ticket is the intent; they live together, committed.** For anything
> verifiable — signatures, addresses, does-it-compile — **the code is the source of truth, not the ticket.**
> "Compiles" is NOT verification (a stub always compiles): **every external interface signature and every
> hardcoded address MUST be checked against the live chain** (Basescan / `cast` against `BASE_RPC_URL`).

### 5. File + assign
Build ticket → `tickets/<team>/`; interface ticket → `tickets/inflow/`. A ticket is "done" only when it has
passed steps 2–4 and is filed.

### 6. Conclude the window (so a fresh context can resume with no history)
This process is **one item per context window** — the critics are subagents, so their heavy token use stays
in their own contexts and only short reports return; what must survive the window is **on disk**. Before
stopping, leave the repo in a clean, resumable state:
- Ticket(s) **filed** in `tickets/<team>/`.
- **`tickets/PROGRESS.md` updated** — mark the item DONE, set the next `NEXT`, and log in the session log
  (incl. any spec fix made or spec gap deferred in "Open spec gaps").
- **`tickets/LEDGER.md` updated** — add/extend this component's digest entry (what it does · locked shape ·
  holes surfaced → resolution · cross-ticket obligations). This is the artifact the user reviews at the end;
  PROGRESS tracks process, LEDGER captures design.
- Any **`claude-zipcode.md` spec fixes** saved (a spec-gap triage edits the spec, not just the ticket).
- **The built code COMMITTED** under `contracts/src/...` + its tests, `forge test` green (the byproduct is
  **kept**, not discarded — see step 4). In PROGRESS/LEDGER record **"code at `contracts/src/X.sol`, `forge test`
  green — run it yourself"**, NOT "cold-build YES, discarded".
- **Write `reports/<ITEM-ID>-report.md` to the superintendent** (model `reports/WOOF-01-report.md`): TL;DR ·
  what the window did · design decisions to sanity-check · holes surfaced → resolution · authoritative-doc
  edits (spec/audit) · judgment calls · status + NEXT. This is the review trail the **superintendent** reads
  (`superintendent.md`) — it is what makes the builder/superintendent split work and survive a fresh context.
  Then **STOP** (the builder window is disposable; the superintendent reviews and releases the next).

A window "concludes" when it has produced a durable artifact — a filed ticket *or* a spec fix — and updated
the ledger. If an item needs heavy spec surgery, it's fine to conclude after the spec fix and author the
ticket in the next window. Never carry unfinished state only in conversation context.

---

## Critic prompts (templates — fill `<TICKET PATH>` / cited §)

> **junior-developer.** "You are a junior dev with no tribal knowledge, building from `<TICKET>` alone. List
> every place you'd be confused, blocked, or have to ask — ambiguity, undefined terms, 'where does X come
> from', missing signatures/types, contradictions. Quote the line. Don't build. Return a numbered gap list +
> the single most-blocking item."

> **spec-fidelity.** "Check `<TICKET>` against `claude-zipcode.md` <§§>. Does it faithfully implement the
> cited §, invent no mechanism, honor locked §17? Flag drift / invention / omission / contradiction with the
> § each cites. Also confirm the ticket **discharges any inbound cross-ticket obligations** (`tickets/PROGRESS.md`
> → Open cross-ticket obligations, rows owed by this item) — flag any left unsatisfied."

> **reference-verifier.** "The ticket cites 'Model from' sources. VERIFY each resolves and is usable: do the
> paths/line-numbers exist, what's the real signature, can it be imported via the remap, inherit vs replicate
> vs interface-only? Return per-source: exists+usable / wrong-path / needs-different-approach, with evidence."

> **qa-engineer.** "Is `<TICKET>`'s 'Done when' verifiable? What tests/edge-cases/failure-modes are missing
> (zero-amount, capacity, atomicity/rollback, reentrancy, rounding at share-price≠1, the custody accounting)?
> Return missing tests + unverifiable acceptance + concrete checks to add."

> **security-engineer.** "Attacker mindset on `<TICKET>` + `claude-zipcode.md` <§§>/§13. Attack it: authority,
> custody (who holds shares; can they be siphoned), reentrancy, approvals, atomicity, peg integrity. Return
> numbered findings w/ severity + the requirement or Do-NOT each implies."

> **frontend-integration.** "Read the interface ticket + build ticket; inspect `reference/euler-lite`
> (pages/composables/abis/services/entities) + `reference/euler-interfaces`. (1) What events + view methods
> must the contract expose for the frontend — does the interface ticket DEMAND them from the build ticket?
> (2) Name the ACTUAL euler-lite files to model (real page, composable, abi/address pattern); flag where the
> ticket is vague/wrong. Cite files you found."

---

## Cold-build verdict (step 4 pass criteria)
- Verdict **"yes"** — not "yes-with-guesses." Every load-bearing gap closed in the ticket.
- Every "Model from" resolved by inspection/compile.
- "Done when" self-checkable (a passing unit test) **and** mapped to an `audit/2.md` step / `audit/3-results.md`
  row for the integration layer.
- Byproduct discarded; `contracts/` back to skeleton.

## Prerequisite (one-time, repo-wide)
The `reference/` Euler dep repos' submodules must be initialized (`git submodule update --init` in each) or no
real import compiles. Build config that WOOF-00 pins: `allow_paths = ["../reference"]`, remappings with **no
comment lines**, deduped OZ/forge-std to one copy. See `sample-ticket.md` WOOF-00.
