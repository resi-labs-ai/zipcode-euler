# CONDUCTOR — how to run one adversarial-review cycle (read this first)

You are the **conductor** of an adversarial-review cycle for one contract. This file is your runbook;
follow it top to bottom. It encodes the procedure and the hard-won discipline from the SzAlpha pilot
(`reports/src/bridge/szalpha/synthesis.md` is the worked example — read it before your first run).

Two companion docs: `README.md` (system + panel modes) and `prompts/src/<group>/README.md` (the group's
contract/mission list). This file is the *operating procedure*; those are the *map*.

## What you're doing
This file covers TWO cycles, invoked separately:
- **Review** (Steps 1–4): several models attack ONE contract independently on X-Ray-derived missions
  grounded in the audited precedent; you run the Claude legs, reconcile every report against the contract's
  X-Ray, and emit a synthesis + any tickets. One contract per cycle, ideally per clean context.
- **Execute** ("Executing a ticket" below): take a filed `build/tickets/audit/<...>.md` from "filed" to
  "shipped on `main`" — build the fix, gate it green, doc-sync, commit + push. One ticket per turn.

The bridge group is the worked example end-to-end: reviewed 5/5 (synthesis under
`reports/src/bridge/*/`), 3 LOW fixes built + SHIPPED to `main` (consolidated bridge
suite 81/81 green), 1 WONTFIX, 2 sound.

## Pre-flight
1. Pick the contract: `<group>/<contract>` (e.g. `bridge/szalpharateoracle`). The group README lists what
   remains and how many missions each has.
2. Confirm `prompts/src/<group>/<contract>/` exists with `_boot.md`, `N.md` missions, and `context.files`.
   If it doesn't, the prompts haven't been authored yet — author them first (see "Authoring new prompts").
3. Confirm the X-Ray exists: `contracts/src/**/x-ray/<Contract>.md`. It is your ground truth for reconciliation.
4. Check `panel.env` for which legs are live (`claude` always; `codex`/`fugu` only if credentialed).
   A single-model (Claude-only) run is valid but is NOT the decorrelated panel — say so in the synthesis.

## Step 1 — run the panelists

**Scripted legs (Codex / Fugu), if live:**
```bash
cd ~/zipcode-euler/adversarial-review
source panel.env
bin/review-contract.sh <group>/<contract>
```
This runs the scripted legs in parallel and writes `reports/src/<group>/<contract>/<panelist>-<n>.md`.
For Claude (`session` type) it only writes a PENDING stub — you fill those.

**Claude legs (you, via the Agent tool):** spawn ONE `general-purpose` subagent per mission, in parallel
(all in one message). Use this prompt template per mission, substituting `<contract>`, `<n>`, and the
exact file paths from that contract's `_boot.md` + `context.files`:

> You are an adversarial smart-contract security reviewer running ONE focused mission, part of a blind
> panel — review independently. Read these in full FIRST (your instructions + output format):
> `prompts/src/<group>/<contract>/_boot.md` and `prompts/src/<group>/<contract>/<n>.md`. Then actually
> READ the files they name — the contract under review, the audited precedent to diff against, and the
> tests — and conduct the review. Do the real work: trace the actual functions, cite real line numbers.
> The highest-value findings are deltas from the precedent. Your final message must BE the report, in the
> EXACT output format `_boot.md` specifies (the `### [SEV]` finding blocks + `## Summary`). No preamble,
> no closing remarks. If a surface is sound, say so explicitly rather than inventing findings.

Write each subagent's report to `reports/src/<group>/<contract>/claude-<n>.md` (overwrite the stub).

## Step 2 — VERIFY before you promote (non-negotiable)
Subagent reports are leads, not truth. Before any finding enters the synthesis, **re-read the actual code
lines it cites and confirm the claim yourself.** Never relay a subagent finding raw. If a "delta from
precedent" is claimed, open the precedent file and confirm the precedent really has the guard and our
code really lacks it. A finding you couldn't verify does not get promoted — note it as unverified.
(In the pilot, all three headline findings were re-checked against source before landing.)

## Step 3 — reconcile against the X-Ray → `synthesis.md`
Classify each verified finding against `contracts/src/**/x-ray/<Contract>.md`:
- **covered** — already in the X-Ray (invariant/guard/residual): confirm or dismiss.
- **gap** — genuine, not in the verdict → candidate ticket.
- **false-positive** — refuted by code/design → one-line note, no ticket.

Then **pressure-test severity** — this is where most of the value is:
- A finding that depends on **distrusting a ratified trust anchor** is accepted-risk/WONTFIX, not a
  vulnerability. In particular: **the Subtensor precompile / Bittensor runtime is the protocol's trusted
  base — precompile-distrust findings are WONTFIX (accepted runtime trust):** a finding that depends on
  distrusting the Subtensor precompile is accepted-risk, not a vuln — a raw MEDIUM pressure-tested to
  WONTFIX through exactly this lens is the standing precedent.
- A finding the X-Ray already flagged as an open residual: the panel's job is to *resolve* it (construct
  the incident, find the precedent delta), then classify — not to restate it.
- "Soundness" is a valid, expected result, especially for thin wrappers. A manufactured finding is noise.

Write `reports/src/<group>/<contract>/synthesis.md`: headline, a reconciliation matrix (finding → sev →
vs X-Ray → disposition), suggested-tickets section, accepted-residuals (WONTFIX) section, a "confirmed
sound" list, and — if single-model — the caveat that this isn't the full decorrelated panel. Also
scorecard which model caught what (the empirical measure of each leg's value) when >1 leg ran.

## Step 4 — tickets (only for genuine, actionable gaps)
- Location: `build/tickets/audit/<GROUP>-ADV-NN-<slug>.md`. Match house style (dense, line-grounded,
  references to `contracts/src/...` and the `reference/...` precedent; no fluff). Use an existing
  filed bridge ticket as the template.
- **Fold coupled findings** into one ticket when they share a code path (in the bridge cycle, a genesis-
  atomicity finding subsumed a coupled one because the genesis condition is the same line). Splitting
  coupled changes risks one breaking the other.
- Every ticket ends with a **documentation-propagation step**: grep-verify which X-Ray/`docs/` files
  carry the affected claims (filter false positives — most generic hits are unrelated), list only those,
  gate the edits on the code landing (the X-Ray is code-truth), and flag which notes (e.g. an accepted-
  risk WONTFIX note) are landable immediately, independent of code.

## Executing a ticket (the build cycle)
Run when the user points you at a filed `build/tickets/audit/<...>.md` to ship. The discipline mirrors
`build/harness.md` (truth = the built contract/ABI, not prose; cold-build to zero guesses) applied to a
contract change. The shipped bridge fixes are the worked examples.

**Workflow — RATIFIED (trunk, not branch-per-ticket):**
1. **Work on `main` directly**, one ticket per turn. (The bridge fixes were first branched then
   consolidated; that ceremony is dropped — if the change is tested, compiles, valid, and doc-synced, it
   IS the new best version: build on `main`, gate, commit, push, next.)
2. **Verify the real base API BEFORE coding the fix.** The ticket's assumed signature can be wrong — read
   the actual base contract; let the compiler + gate correct you, don't trust the ticket's API guess. Two
   live examples: Chainlink `Ownable2Step` keeps `pendingOwner` PRIVATE (no getter → assert the handoff
   *behaviorally* via `acceptOwnership`); `Math.mulDiv` CANNOT saturate a genuinely-`>uint256` result (the
   `type(uint256).max`-vs-tiny-anchor case needs an early-return guard, not mulDiv).
3. **Baseline the gate, THEN build.** Run the scoped suite green first so the gate is meaningful. Build the
   fix bound to the real code. For a wide MECHANICAL sweep (e.g. a 44-site zero-floor test edit),
   delegate to a cold-build `general-purpose` subagent with explicit instructions + "do NOT run any
   state-changing git command" — but YOU own the commit and YOU re-run the gate (subagents have
   auto-committed against instructions; verify `git log`/`status`).
4. **GATE (green before any commit):** `forge build` clean + the scoped suite green
   (`forge test --match-path 'test/<group>/*.t.sol'`). Run it YOURSELF — never trust a builder's "green."
   Add the regression test the ticket's acceptance criteria name.
5. **Doc-sync (load-bearing — the most-missed step).** Update every truth-source the change touches: the
   per-contract X-Ray (`contracts/src/**/x-ray/<C>.md`, authoritative), the wire doc (`docs/wires/...`),
   the runbook. Grep-verify targets and FILTER false positives. Land the doc edits in the SAME commit.
6. **Mark the ticket BUILT** (a STATUS line noting any divergence from the planned fix), update the
   `PROGRESS.md` audit ledger, then **commit + push `origin main`** (co-author trailer per repo convention).
   If consolidating MULTIPLE fixes at once, run the gate on the MERGED state before the push — three
   individually-green changes can break each other combined.
7. STOP and report; continue to the next ticket only if the user says so ("Repeat").

## Done criteria
**Review cycle:** `reports/src/<group>/<contract>/` has one report per (live-model × mission) +
`synthesis.md`; every promoted finding re-verified against source; tickets (if any) in house style, coupled
findings folded, doc-propagation step included. Reports/synthesis are scratch — not committed.
**Execute cycle:** the fix + its regression test + the doc-sync are committed and pushed to `main` with the
gate green; the ticket is marked BUILT and the `PROGRESS.md` ledger updated.

## Authoring new prompts (if a contract's prompt dir doesn't exist yet)
Read the contract's X-Ray first. Mission count follows its **authored attack surface** (the X-Ray's
"Attack surfaces" list), not a fixed number — fat logic → more missions, thin audited-base wrapper → 1.
Write `_boot.md` (contract summary + the named source-of-truth precedent files + tests + rules + output
format), `N.md` per surface (the adversary persona + the named invariants to break + "already proven —
don't re-report" test list), and `context.files` (source + tests + ranged grounding for inline panelists;
validate every path resolves). The bridge group's files are the worked examples.

## The five hard rules (distilled)
1. **Differential-first** — the strongest finding is a delta from the audited precedent; ground every
   mission in it.
2. **Verify before promote** — re-read the cited code yourself; never relay a subagent finding raw.
3. **Pressure-test severity** — distrusting a ratified trust anchor (esp. the Subtensor precompile) is
   WONTFIX/accepted, not a vuln; deflate plausible-but-trust-dependent findings.
4. **Soundness is a valid result** — don't manufacture findings to look productive.
5. **One model ≠ the panel** — note single-model runs as a baseline, not the full decorrelated review.

Execute-cycle rules (when shipping a ticket):
6. **Verify the base API before fixing** — read the real base contract; the ticket's assumed signature
   may be wrong; let the compiler/gate correct you.
7. **Run the gate yourself** — `forge build` + scoped tests green before any commit; never trust a
   subagent's "green." Doc-sync (X-Ray / wire / runbook) lands in the same commit as the code.
8. **Trunk workflow** — build on `main`, gate, commit + push, next. No branch-per-ticket ceremony.
