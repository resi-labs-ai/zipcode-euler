# harness.md — paste this to start a build window

You are picking up **zipcode-euler**, a decentralized home-equity credit protocol on Base. The on-chain
contract stack is **built and fork-tested**. The work that remains is the two layers that bind *to* the
contracts: the **CRE** off-chain reporting (Go → wasip1) and the **frontend** (Vue/viem).

Your job: author and build **exactly ONE item this window**, through the adversarial harness below, then
conclude on disk and **STOP** for review. Do not mass-produce.

The flow, end to end:
1. **Orient** (this file).
2. **Find your task** — read `build/tickets/PROGRESS.md`; the item marked `NEXT` is yours.
3. **Run the loop** — draft → fan critic subagents → triage → cold-build to zero guesses → keep the code.
4. **Conclude** — file the ticket, update `PROGRESS.md`, write a report, STOP.

---

## 1. The inversion — where truth lives (read this first)

When the contracts were authored, the spec was truth and the code was derived from it. **That is now
reversed.** The contracts exist, are fork-tested, and their ABIs are fixed. So for the remaining work:

- **The source of truth is the built contracts and their ABIs — never spec prose.** The spec
  (`build/claude-zipcode.md`) still rules *intent* (what the system is for); the contract rules
  *interface* (what it actually does). When they disagree on anything bindable, the contract wins and the
  disagreement is a finding.
- The remaining tracks **bind to the contracts**: CRE *encodes* reports the contracts will `abi.decode`;
  the frontend *reads* the events and views the contracts emit/expose. Binding to a surface the contract
  does not have is a **load-bearing guess** and fails the gate.
- If a track needs a contract surface that does not exist, that is **back-pressure**: log it as an
  obligation owed back to that contract — do not invent around it.

**Truth sources per track** (verify, never cite blind):

| Track | Binds to | Intent | Reference patterns |
|---|---|---|---|
| **CRE** (Go→wasip1) | the filed `contracts/src/...` report consumers (`ZipcodeController`, `ZipcodeOracleRegistry`, and the other `ReceiverTemplate`s) + `claude-zipcode.md` §8 | `claude-zipcode.md` §8 producer spec | `reference/cre-sdk-go/standard_tests/*/main_wasip1.go`, `reference/cre-templates`, `reference/cre-cli`; existing `cre/szalpha-rate/` |
| **Frontend** (Vue/viem) | the filed contract **ABIs** (`forge build` output) | `claude-zipcode.md` §5/§12 (UX + dashboard metrics) | `reference/euler-lite/` (pages, composables, abi/address wiring); existing `build/tickets/frontend/INFLOW-06-deposit-module.md`* |

\* `INFLOW-06` is the existing frontend ticket template; model its field shape.

---

## 2. Locked decisions — do not reopen (`claude-zipcode.md` §17)

These are settled. Build to them; do not re-litigate.

- **Valuation = Proof of Value, event-driven** (no AVM/HPI/heartbeat). The Proof family gates before mint;
  collateral is **mocked** for the MVP.
- **zipUSD = $1 utility dollar.** **szipUSD = a transferable ERC-20 share** the **Exit Gate** mints
  **NAV-proportionally** vs soulbound gate-held Loot. **NAV (`SzipNavOracle`, §7) is the pricing primitive.**
- **Exit = a CoW-book secondary + 8-B14 buy-and-burn** (full ragequit is for winding the vault down, not a
  normal exit). The senior exit is the par epoch queue (`ZipRedemptionQueue`, §12).
- **First-loss = a pari-passu conservative provision-that-recovers** (`SzipNavOracle`, §11) — NOT
  withhold-no-markdown. The coverage floor is the **structural freeze** (`DurationFreezeModule`), not a knob.
- **No on-chain economic liquidation** — `liquidate` is a defensive gate; resolution is off-chain →
  permissionless repay (§4.4e).
- **Venue-agnostic**; Euler = config one (§4.7). Fabric = **Zipcode subnet, Shape B** for M1.
- **Build-phase wiring is Timelock-settable, not frozen** — every contract carries one Timelock admin and
  every cross-component pointer is re-pointable. Immutability is a **pre-prod** lock-down, deferred.

---

## 3. Find your task

Read **`build/tickets/PROGRESS.md`** — the item marked **`NEXT`** is your task (the build is well underway;
this is not the beginning). Check **"Open cross-ticket obligations"** for any row owed *by* your item — the
ticket MUST discharge each, as a Key requirement with a Done-when test. Mark it `DISCHARGED` at Conclude.

File CRE tickets under `build/tickets/cre/`, frontend tickets under `build/tickets/frontend/` (create the
folder if absent). Each track keeps its own progress section/ledger in `PROGRESS.md`.

---

## 4. The loop (one item)

### Step 1 — Draft the ticket
One ticket = the task × the relevant `claude-zipcode.md` § × a **verified binding target** (the real
contract ABI / reference symbol — confirmed by inspection, not cited blind). Fields: Deliverable · Spec § ·
Binds to (contract + ABI / reference) · Starting state · Do NOT · Key requirements · Done when · Depends on.

### Step 2 — Fan out critic subagents (one batch, parallel)
Each reads the draft + the cited § + the binding target, and returns a numbered findings list. Run the
cheap three always, plus the track-specific fourth:

| Role | Lens | Track |
|---|---|---|
| junior-developer | ambiguity / "can't tell what to import or do" | all |
| spec-fidelity | faithful to the cited §; invents no mechanism; honors §17 | all |
| reference-verifier | does the binding resolve — real signature, real path, importable | all |
| **cre-binding** | does the report struct **encode** to the §4.4 layout the filed contract `abi.decode`s? does it cite real cre-sdk symbols? | CRE |
| **frontend-binding** | does the composable bind to events/views the contract **actually emits/exposes**? what surface is missing (back-pressure)? | frontend |

Prompt templates: §6 below.

### Step 3 — Synthesize + triage
Merge findings. Triage each:
- **Spec gap** (the spec under-defines the mechanism) → fix `build/claude-zipcode.md` **first**, then re-derive.
- **Ticket gap** (spec is fine, ticket unclear) → fix the ticket.
- **Back-pressure** (the contract lacks a needed surface) → log an obligation against that contract in
  `PROGRESS.md`.

Preserve deliberate choices; do not let critics sand off intent.

### Step 4 — Cold-build to zero guesses, and keep it
A fresh subagent builds from the ticket alone and must return **zero load-bearing guesses**, passing the
per-track gate:

- **CRE:** `go build` compiles to the `wasip1` target; a table-driven test **encodes** the workflow's
  report payload and asserts it `abi.decode`s to exactly the §4.4 per-type layout the *filed* contract
  expects (`uint8 reportType` + the typed payload); a simulated run (trigger → node-mode →
  identical-consensus aggregation → report) executes without guessing SDK signatures. The Go module is
  committed.
- **Frontend:** `nuxi typecheck` + the component builds; the composable binds to the **real emitted events
  and method signatures** of the filed contract (a binding to an absent surface fails the gate); any needed
  contract surface that does not exist becomes a back-pressure obligation. The code is committed.

A verdict is **"yes"**, never "yes-with-guesses." If the builder must guess, the gap folds back into the
ticket and the build re-runs. The code is the proof, the ticket is the intent — they live together,
committed. No findings is a flag to be skeptical, not a win.

### Step 5 — Conclude (leave a resumable on-disk state, then STOP)
- Ticket filed under `build/tickets/<track>/`.
- `build/tickets/PROGRESS.md` updated — mark the item done, set the next `NEXT`, log any spec fix.
- Any `build/claude-zipcode.md` spec fix saved.
- The built code committed (`cre/...` or `frontend/...`) with its gate green.
- `build/reports/<ITEM>-report.md` written: what the window did · decisions to sanity-check · holes →
  resolution · doc edits · status + NEXT.
- **STOP.** One item per window; the reviewer releases the next.

---

## 5. Cadence

One item per context window. The critics are subagents, so their token use stays out of this context —
one item per window is feasible. Always end in the resumable on-disk state above so context saturation
never loses work. The harness *will* surface spec gaps — fix them in the spec before writing the ticket
around them. That is the point.

---

## 6. Critic prompts (templates — fill `<TICKET>` / cited §)

> **junior-developer.** "You are a junior dev with no tribal knowledge, building from `<TICKET>` alone.
> List every place you'd be confused, blocked, or have to ask — ambiguity, undefined terms, missing
> signatures/types, contradictions. Quote the line. Don't build. Return a numbered gap list + the single
> most-blocking item."

> **spec-fidelity.** "Check `<TICKET>` against `build/claude-zipcode.md` <§§>. Does it faithfully implement
> the cited §, invent no mechanism, honor the locked §17 decisions? Flag drift / invention / omission /
> contradiction with the § each cites. Confirm it discharges any inbound obligation in
> `build/tickets/PROGRESS.md`."

> **reference-verifier.** "The ticket cites a binding target (a contract ABI / a reference symbol). VERIFY
> each resolves and is usable: real signature, real event, importable, inherit vs replicate vs
> interface-only. Return per-source: exists+usable / wrong / needs-different-approach, with evidence."

> **cre-binding (CRE).** "Read `<TICKET>` + the filed report consumer(s) under `contracts/src/...`
> (`ZipcodeController`/`ZipcodeOracleRegistry`/other `ReceiverTemplate`s). Does the workflow's report
> payload **encode** to the exact §4.4 layout the contract `abi.decode`s, per reportType? Flag any
> field-order, type, or reportType-routing mismatch. Then verify every cited cre-sdk symbol resolves in
> `reference/cre-sdk-go/`. Cite the contract line + the sdk path."

> **frontend-binding (frontend).** "Read `<TICKET>` + the filed contract ABI; inspect
> `reference/euler-lite`. (1) What events + view methods must the contract expose for this UI — does the
> ticket DEMAND them, and does the contract actually have them (back-pressure)? (2) Name the actual
> euler-lite files to model (page, composable, abi/address pattern). Cite files you found; flag where the
> ticket is vague or wrong."

---

## 7. Prerequisite (one-time)
The `reference/` clones must be present (see `reference/MANIFEST.md`) or no real import/model resolves. Run `forge build` in
`contracts/` so the off-chain and UI tracks bind to fresh ABIs.
