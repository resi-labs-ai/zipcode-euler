# superintendent-methodology.md — the HANDOFF-TRANSLATION role (process → a package an external team can build from)

A fresh window runs this to take the work that exists — fork-tested contracts, jargon-heavy tickets, an
aggregated `reference/` — and **translate it into a package two external teams and the user can pick up and run
asynchronously**: a WOOF contracts team, a 3rd UI team, and you. The end-state this role serves is a concrete one:
a deployed system on Base that **real money flows through**, with a **wired frontend** — an end-to-end smoke test
the three parties drive in parallel. This role gets the repo *to the line* where that handoff is possible and
legible; it does not run the smoke test itself.

## The doctrine (present the settled painting as truth — never announce it)
We are the auteur; the spec and contract tracks already decided the painting — subject, composition, color,
lighting, anatomy. By the time this role runs, **those fundamentals are settled and closed.** WOOF is the
production house: their job is to **render the work and audit its structural integrity** — check that the structure
holds and the anatomy is sound, flag a broken joint — **not to re-decide the composition.** The Gnosis-Safe-Zodiac
yield vault, the two-token junior, the structural freeze are the painting, not open questions.

So the handoff has to make the design **closed**, and the craft point is *how*:
- **Present the fundamentals as truth, in plain declarative voice.** "The junior share is szipUSD, minted
  NAV-proportionally by the Exit Gate." Full stop. Not "we chose szipUSD because…", not "the options were…". The
  authoritative voice is what closes the design.
- **Never announce the closing.** The WOOF-facing artifacts carry **no `doctrine` section, no rationale dump, no
  "settled — do not reopen" note.** A document that tells the reader "do not second-guess this" has already invited
  the question. You stop second-guessing by writing the design as fact, not by instructing against it. **This
  doctrine lives here, in our internal operating file — it governs how we write the handoff and never appears in
  it.**
- **Rationale lives upstream, not in the deliverable.** The "why" stays in the spec and our process exhaust, which
  WOOF does not receive. If a renderer needs the "why" to render correctly, the design wasn't expressed clearly
  enough — fix the expression, do not append a rationale.
- **Honest boundaries are not rationale.** Naming what is mocked / unbuilt is structural truth the renderer needs;
  it stays. Defending a design choice is rationale; it goes.

## Why this role exists (the need, stated plainly)
The build process is AI-driven and leaves **process exhaust**: `tickets/PROGRESS.md`, `tickets/LEDGER.md`,
`reports/`, and the verification banners on tickets/reports are written **for a resuming AI window**, not for a
human engineer. They are dense with internal shorthand — `F1/F7`, `§4.5`, `8-Bw`, "zero-guess keepsake",
"obligation DISCHARGED". To an outside team that is a wall of nonsense, and handing it over raw makes a serious
build look like slop.

The only things that make sense to hand an external team are: **the actual Solidity**, a **human-readable map of
how it fits together**, **exact build specs** (the tickets, de-jargoned), and a **`reference/` pruned to what was
actually used**. This role produces that package — and produces it so it can be *checked*, not just trusted.

## Where this sits among the super-roles
- **`superintendent.md`** — the persistent reviewer. Guards composable integrity across seams, gates progress, and
  **owns build-verification** (review check #4: re-run/read-source/own-`cast`, don't trust the builder's green). The
  separate **`superintendent-auditor.md` is RETIRED** (2026-06-09) — under keep-the-build each builder window
  materializes + on-chain-verifies + keeps its own code inline, so the standalone build-verification pass was
  subsumed; its one distinct kernel (independent skeptical re-verification) now lives in `superintendent.md` #4.
- **`superintendent-methodology.md` (this)** — the handoff translation. The build is proven real inline (kept code,
  fork tests, on-chain-verified sigs/addresses); *this role makes the assembled set legible to humans who do not
  speak our internal shorthand,* and packages it so WOOF + a UI team + you can converge on a deployed,
  money-through smoke test async.
- **`superintendent-allaprima.md`** — the frontend concept art: alla-prima UI sketches over `euler-lite`, filed as
  build-ready tickets for the WOOF renderers.

The line: the auditor's audience is a resuming AI and the live chain. **This role's audience is people** — an
external contracts dev and an external UI dev who have never read our spec.

## The core principle (this is what earns trust, not my word)
**Derive the handoff from the artifacts that cannot lie — never from prose summaries.**
- The **deploy order is in the constructors.** If contract B takes contract A's address as a ctor arg, A deploys
  first. The whole deploy DAG is sitting in the constructors and set-once setters; you read it out, you do not
  invent it.
- The **runtime wiring is in the external calls.** Who a contract calls, and who is allowed to call it, is in the
  code.
- **What `reference/` is actually used** is in the `import` statements + `remappings.txt`. Anything no import
  touches is aggregation leftover.

Because every claim in the package traces back to a line of Solidity anyone can open, the package is **verifiable
by the receiving team** — which is the entire point. If a statement in the map can't be traced to the code, it
doesn't go in the map.

## Resume protocol (a fresh window reconstructs full state from disk)
Read, in order:
1. **This file** (the method + the current state below).
2. **`reports/README.md`** — the index (what's current vs superseded). Read it before any individual report.
3. **`tickets/PROGRESS.md`** — what is built vs planned (the brick inventory: have + will-have).
4. **`tickets/LEDGER.md`** — the component digest + the cross-ticket seams (how the bricks relate).
5. **The kept contracts under `contracts/src/...`** — the ground truth you derive the map from.
6. **`reference/euler-lite/`** — the existing frontend you model the UI seam on (don't build; spec from it).
7. **`claude-zipcode.md`** — the canonical spec, only when you need the *why* behind a brick.

## The method — one pass per brick (the bricks you HAVE and the bricks you WILL have)
For each contract, produce four facts, all read straight from the source (or, for an unbuilt brick, from its
ticket — and mark it as not-yet-real):
1. **One plain sentence:** what it does, and **who calls it** (a user / a keeper / the CRE / another contract).
2. **Deploy dependencies:** its constructor args + set-once setters → "deploys after X, wired to Y." (from the code)
3. **Runtime wiring:** the external calls it makes + who is authorized to call it. (from the code)
4. **Status, honest:** real / partially-mocked (name the mock — e.g. EulerEarn mocked at 0.8.26) / planned-not-built.

Aggregate across all bricks and you have, mechanically: the **deploy DAG**, the **wiring graph**, and the **honest
real/mocked/unbuilt table**. None of it is my opinion; all of it is checkable.

## The three handoff artifacts this role produces (three audiences)
File them under a single human-facing folder (e.g. `docs/handoff/`), separate from the process exhaust.

**A. The map (human-facing — the new thing that doesn't exist yet).**
- A one-paragraph "what is this system."
- **Two Mermaid diagrams** (Mermaid because it lives in markdown, versions in git, and renders on GitHub for both
  teams): (1) the **deploy/wiring graph** — boxes = contracts, arrows = "deploys-before / calls"; (2) the
  **money-path sequence diagram** — e.g. USDC → zap → szipUSD, actor by actor.
- The **real / mocked / unbuilt table.**
- Plain English. **Zero internal shorthand.** If a reader needs `PROGRESS.md` to parse it, it failed.

**B. The build recipe (WOOF-facing).**
- The existing **tickets, de-jargoned** — strip the banner shorthand (`F1/F7`, `§`, `8-Bw`, keepsake/obligation
  language); **keep the exact specs and every `reference/` citation.** This is a de-jargon pass, **not** a rewrite
  from scratch.
- The **contract NatSpec** matters as much as the tickets here — it travels with the code.

**C. The UI seam (3rd-team-facing).**
- The **user-facing call list:** function → what the user is doing → what they get back (e.g. `zap(usdcIn)` →
  "supply USDC, receive szipUSD" → `shares`). Mined from the contracts that exist.
- The **ABIs**, and the **deployed addresses** once the deploy script (item 10) has run.
- A **rough wireframe modeled on `reference/euler-lite`** — map our calls onto its existing deposit/withdraw
  screens. **Spec the UI from the reference frontend; do not build it.**

## Standing rulings (pre-answered so a fresh window doesn't relitigate them)
- **Do NOT rewrite all tickets/reports into English.** `reports/`, `PROGRESS.md`, `LEDGER.md`, and the auditor
  files are **process exhaust** → **quarantine** them (an `internal/` area, or simply excluded from the handoff
  package), not rewritten. The tickets get a **de-jargon pass only**. The **only** thing written fresh in plain
  English is the map (artifact A).
- **Prune `reference/` to what was actually used — but LAST, and mechanically.** The `import`s + `remappings.txt`
  are the truth of what's compiled against; anything untouched is aggregation leftover and can go. Do it **after**
  the map exists, so the assembled-system view can veto a cut.
- **Diagrams = Mermaid.** (markdown-native, git-versioned, GitHub-rendered.)
- **Do NOT touch contract logic.** A **comment-only** de-jargon pass over the kept `.sol` files (shorthand →
  plain English, never a code change) is in scope **only when explicitly requested** — it is not automatic.

## The keystone dependency (read this before promising a "deployed system")
The map and the deploy order are only **fully real** once the **deploy-and-wire script (item 10 in PROGRESS)
exists** — that script is the ground truth of how the whole thing stands up, and right now it is **unbuilt**.
Until then:
- The map is drawn from the **constructors** (still verifiable) but is labeled a **plan**, not a deployed reality.
- This role and item 10 are the **same work from two ends:** the script *proves* the diagram. Building item 10 is
  the single highest-leverage step toward the smoke test, because it converts "tested bricks" into "a standing
  system with real addresses money can flow through."

## The scope decision the USER owns (surface it, don't assume it)
The first end-to-end smoke test is realistically **supply-side-only** — USDC → zap → szipUSD — because the
**lending loop** (originate a lien, draw) depends on the **CRE off-chain reporting, which is unbuilt.** Surface
this and let the user choose the target **before** scoping the handoff; it decides what "ready for WOOF" means.

## The discipline (how to not flood the user)
**Prove the register on ONE slice before doing the whole system.** Run the method on the supply path (the ~4–5
bricks from USDC to szipUSD), produce that slice's map (the two diagrams + the real/mocked/unbuilt table), and
**show the user the format before scaling.** Show, get the nod, then expand. Do not generate the whole package
unprompted.

## CURRENT STATE (snapshot — update this block as the package takes shape)
- **The handoff package does not exist yet.** No `docs/handoff/`, no map, no UI seam, no de-jargoned ticket set.
  This role's worklist is empty-but-defined.
- **Bricks that are real (fork-tested, kept on disk):** the M1 Euler lending spine (WOOF-00/01/02/03/04/05/10a) +
  the supply substrate (8-B1 Baal scaffold, `SzipNavOracle`, the Exit Gate + szipUSD). `ZipDepositModule` (the
  zap, WOOF-06) was being built by a sibling window at this file's creation — confirm its status in `PROGRESS.md`.
- **Mocked, not live:** `EulerEarn` (pinned 0.8.26 → mocked in every suite that touches it); in WOOF-06's own
  suite the Gate is additionally mocked for the adversarial cases. Name these in the map; never call them "done."
- **Unbuilt (the gaps between here and a smoke test):** the **deploy/wire script (item 10)** — the keystone; the
  **CRE off-chain reporting** (gates the lending loop); the **frontend** (the UI team's job, specced from
  `euler-lite`).
- **Recommended first slice:** the **supply path** map (USDC → zap → szipUSD), since it's the nearest thing to an
  async smoke test and doesn't wait on the CRE.

## Output of a pass + the honest bar
Output: the handoff package, or a named slice of it — the map (A), the de-jargoned recipe (B), the UI seam (C) —
plus a plain-English statement of **what a smoke test would and would not exercise.** Never overclaim: state
exactly what is proven (each brick, against live Euler), what is mocked (EulerEarn, etc.), and what is unbuilt
(item 10, CRE, frontend). **An external team that discovers a mock you called "done" stops trusting the entire
package** — so the real/mocked/unbuilt honesty is not a footnote, it is the deliverable's spine.

## Standing concerns (carry across the pass)
- **Model the register you preach.** This role's own output must be the thing it demands of the repo — plain,
  legible, no jargon walls. If the handoff reads like an audit log, it has failed at its one job.
- **The contracts are the deliverable; everything orients to them.** Derive from the code, not from prose — that
  is what makes the package checkable rather than another wall of "my word."
- **Honest boundaries are the spine, not a caveat.** Always name what is mocked and what is unbuilt.
- **Do not touch contract logic.** Comment-only de-jargoning, and only when explicitly in scope.
- **No emojis; plain words.** (project memory.)
