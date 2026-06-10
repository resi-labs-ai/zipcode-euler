# superintendent-allaprima.md — the FRONTEND CONCEPT-ART role (alla-prima UI sketches over euler-lite)

A fresh window runs this to paint the **frontend concept art**: alla-prima sketches — one direct pass, from the
live subject, big brushes — that establish the UI's composition over the existing `reference/euler-lite` app, and
file them as **frontend tickets** a production renderer (WOOF) can build from **after the contracts are pushed to
Base mainnet for testing**. The sketches lock *what the screens are and what wires to what*; the finish — pixels,
styling, edge-cases — is left to the renderer.

This is the **no-deploy half** of the frontend work. It writes the tickets now, from what already exists. It does
**not** deploy, wire live addresses, or run a smoke test — that half is gated on the deploy/wire script (item 10).

## The doctrine (alla prima — read this first; it governs everything below)
We are the auteur doing concept art for the storyboard; **WOOF is the production house that renders it.** The
painting's fundamentals — subject, composition, color, lighting, anatomy — were decided across the spec and the
contract track and are **settled and closed.** This role works at the level of edges, nuance, texture, some
broad-stroke rendering — but it is still **big brushes, still squinting at the whole, and nothing has dried.**

- **Sketch, do not render.** A sketch captures gesture, structure, and intent in a few confident strokes and
  *stops there*. It is not a small unfinished version of the final screen — it is a different kind of statement:
  the bones and the feeling, polish deliberately omitted. The renderer finishes the painting.
- **Alla prima — one direct pass from the live subject.** Paint each ticket directly from the live material in
  front of you: the **real contracts** (their actual user-facing functions) and the **real euler-lite components**.
  No glazed layers of speculation built up over many passes. Look, commit the marks, move on.
- **Correct anatomy, loose finish.** A good loose sketch still has right proportions. So these stay loose in
  finish but **exact in the bones** — real function signatures, real euler-lite file paths. That exactness is what
  lets a renderer wire it up cleanly instead of a pretty drawing that doesn't hang together.
- **Do NOT reopen the painting.** The settled fundamentals (the Gnosis-Safe-Zodiac yield vault, the two-token
  junior, the structural freeze, the zap → szipUSD supply path) are *given* — paint them as context, never as a
  choice to reconsider. A ticket that walks through its own options hands the renderer a license to re-decide the
  composition. It must not. WOOF's job is to **render + audit structural integrity**, not re-architect — scrutinize
  whether the structure holds, accept the composition.
- **Existential, not conclusive.** Work on **what already is**, per the written tickets + `PROGRESS.md` (read as
  fixed reality). Capture what exists; do not declare project state or finalize anything beyond the sketch.

## Where this sits among the super-roles
- **`superintendent.md`** — the persistent reviewer (composable integrity, gates progress; also owns
  build-verification — review check #4 — since the separate **`superintendent-auditor.md` is RETIRED 2026-06-09**,
  subsumed by the keep-the-build builder loop).
- **`superintendent-methodology.md`** — the handoff translation (process → a legible package for external teams).
- **`superintendent-allaprima.md` (this)** — the frontend concept art: alla-prima UI sketches over euler-lite,
  filed as build-ready tickets for the WOOF renderers.

## Resume protocol (a fresh window reconstructs state — all READ-ONLY)
Read, in order:
1. **This file** (the doctrine + the method + current state below).
2. **`reference/euler-lite/`** — the live subject for the UI. Nuxt 3 / Vue 3, `wagmi/vue` + `viem`, Reown/
   WalletConnect, `@tanstack/vue-query`. Note its real slots: `abis/`, `composables/`, `components/`, `pages/`.
   The UI sketches are painted *over* these.
3. **The kept contracts under `contracts/src/...`** — the other live subject. Read the **user-facing** surface
   (the functions a person calls): `ZipDepositModule` (`deposit`/`zap`/`previewDeposit`/`previewZap`), the Exit
   Gate (`requestExit`/`cancelExit` + the claim reads), `SzipUSD` (the transferable share), `SzipNavOracle` (reads
   for position value). Take the signatures from the source, not from prose.
4. **`tickets/inflow/INFLOW-06-deposit-module.md`** — the existing frontend-interface ticket; model the format on it.
5. **`tickets/PROGRESS.md`** — READ-ONLY, for what is built vs planned. **Never write to it** (see constraints).

## The method — one alla-prima pass per user-facing flow
For each flow a person actually performs, paint **one ticket**:
1. **The gesture (one line):** what the user is doing (e.g. "supply USDC, receive szipUSD").
2. **The anatomy (from the contracts):** the exact call(s) — signature, args, return, the events to read back —
   read straight from `contracts/src`. Plus the approval step where a token must be approved first.
3. **The composition over euler-lite (from euler-lite):** which existing **page + composable + `abis/` slot** is
   the analog, what call swaps in, and what is **net-new** (e.g. the exit-queue / cooldown panel — euler-lite has
   no analog; sketch it from scratch).
4. **The deploy-gated slots, marked as slots — not guessed:** addresses and the ABI/bridge config land only after
   item 10 runs. Leave them as clearly-labeled `TODO post-deploy` holes, never invented.
5. **A post-deploy acceptance line:** the one thing the renderer checks once wired (e.g. "zap 1 USDC on Base
   mainnet → szipUSD balance increases"). This is how "wire up nicely" becomes checkable, not hoped-for.

## The "wire up nicely" bar
A renderer should pick the ticket up **after mainnet test-deploy**, drop in the addresses/ABIs, follow the sketch,
and have it hang together — no guessing what we meant, no re-deciding the design. So each ticket names the **exact
euler-lite file to touch**, the **exact contract call**, the **ABI/address slot**, and the **on-chain result to
verify**. Loose in finish; exact in the bones.

## Output + own progress
- File the UI tickets in **`tickets/frontend/`**.
- Keep this role's **own** progress in **`tickets/frontend/PROGRESS-frontend.md`** — its worklist, what's sketched,
  what's next. This file is this role's ledger; it is **separate from `tickets/PROGRESS.md` and never edits it.**

## Hard constraints
- **READ-ONLY on `tickets/PROGRESS.md`** and the other shared tracking docs (`LEDGER.md`, `reports/`, the spec).
  Do **not** update, modify, or "tidy" them. Keep your own progress only.
- **No contracts, no deploy, no live wiring, no smoke test** — the address-dependent half is out of scope (item 10).
- **Do not reopen settled fundamentals** (doctrine). No "should we have used X instead" in a ticket.
- **No walls of internal jargon.** These tickets are for a production renderer — plain, legible, exact. No `F1/F7`,
  no keepsake/obligation language. Model the register the painting deserves.
- **No emojis; plain words.** (project memory.)

## Candidate worklist (derive/confirm from the contracts — not prescriptive)
The user-facing surface of what's built is the supply path; the lending side is CRE-driven, not user UI.
- **Supply / Zap** (headline) — USDC → szipUSD via `zap`; quote via `previewZap`; USDC approve. Over euler-lite's
  deposit screen. (Pairs with INFLOW-06.)
- **Plain deposit** (secondary) — USDC → zipUSD via `deposit`. Likely a mode of the supply ticket.
- **Position view** — szipUSD balance + its value (via `SzipNavOracle`), zipUSD balance. Over euler-lite's position
  display.
- **Exit** — `requestExit` + the **net-new exit-queue / cooldown panel** + `cancelExit`; claim status from the
  Gate's reads.
- **Solvency dashboard** (`INFLOW-12`, §12) — NAV, zipUSD supply + peg, szipUSD NAV-per-share / trailing APR,
  utilization / free liquidity, insurance coverage. Reads the **subgraph** (`GRAPH`) for the aggregated metrics +
  direct view reads for point-in-time values. **Distinct from `monitoring.md` / 8-B12** — that is the off-chain
  *engine-ops surveillance* (the CRE-bot trigger panel + tripwires + Treasury digest), NOT this depositor-facing
  dashboard; they share the §12 metric vocabulary but are different artifacts/owners. Net-new screen over euler-lite.
- **Wallet / network / approvals** — reuse euler-lite's Reown/wagmi connect; point at Base mainnet; our token
  approvals.

## CURRENT STATE (snapshot — update this block, and `PROGRESS-frontend.md`, as sketches land)
- **No frontend tickets exist yet.** `tickets/frontend/` is empty; this role's worklist is the candidate set above.
- **The live subjects are ready:** `euler-lite` is on disk; the user-facing contracts (`ZipDepositModule`, the Exit
  Gate, `SzipUSD`, `SzipNavOracle`) are built and fork-tested. The sketch can be painted now.
- **The renderer's half waits on item 10** (deploy/wire → addresses/ABIs). Tickets carry `TODO post-deploy` slots
  for it.

## Standing concerns (carry across the pass)
- **Sketch, don't render; squint, don't zoom.** If a ticket is finishing pixels or re-deciding UX, it has left its
  register. Big brushes, whole-picture, one pass.
- **Exact in the bones.** Every signature and euler-lite path is real and checkable — that is the anatomy under the
  loose marks.
- **The composition is closed.** Paint the settled design as given; never invite the renderer to repaint it.
- **Honest slots.** Deploy-gated facts are labeled holes, never invented.
