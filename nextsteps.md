# nextsteps.md — handoff for a fresh Claude (builder window)

You are picking up **zipcode-euler**, a decentralized home-equity credit protocol. Your job: **author M1 build
tickets — one item per window, in build-priority order — each through the adversarial authoring harness.** The
item marked `NEXT` in `tickets/PROGRESS.md` is your task (NOT "the beginning" — the build is well underway).
Read this, then orient.

> **State (2026-06-07 — supply-side two-token redesign integrated).** Items 1–7 + 10a are authored (original
> cold-builds discarded → unverified under keep-the-build; only WOOF-00 is materialized green). **Item 8 (the Baal
> `szipUSD` vault) is in progress.** This session **rewrote the supply-side model and integrated it into the spec.**
> The four spec artifacts you must understand:
>
> - **`claude-zipcode.md` = THE canonical spec.** Just rewritten to the **two-token / NAV-oracle /
>   provision-that-recovers** model: szipUSD = a **transferable ERC-20 share** the **Exit Gate** mints
>   **NAV-proportionally** vs **soulbound gate-held Loot** (the soulbound is on the Loot, not the user token); exit =
>   windowed ragequit at `min(spot,twap)` NAV (partial-fill) + a **CoW** secondary + 8-B14 buy-and-burn; first-loss =
>   a **conservative provision-that-recovers** marked on `SzipNavOracle`, **NOT** withhold-no-markdown. **Author /
>   build against IT.**
> - **`reports/design/baal-spec.md` = the build-grade companion** for the **8-B** tickets — the contract-cited recipes
>   for the **substrate scaffold (8-B1), `SzipNavOracle`, the Exit Gate, and engine 8-B5…8-B14 + 8-Bw warehouse**, plus
>   the **Base address book** (`BaalAndVaultSummoner 0x2eF2fC8a18A914818169eFa183db480d31a90c5D`, `BaalSummoner`,
>   Loot/Shares singletons). **MOVED to `reports/design/` (2026-06-09) — it is the design trail now, not a root spec:**
>   nearly all of it is consumed (8-B1 / `SzipNavOracle` / Exit Gate / 8-B5…B10 / B14 / 8-Bw all BUILT-VERIFIED), so
>   it is **mostly historical**. Its only remaining live "Model from" duty is **item 9 (`§12 ZipRedemptionQueue`)** +
>   the **loss side (`§9`, M2)**; author those FROM it, then **DELETE it once they consume it** (staging, not permanent).
>   The canonical reflection of everything in it lives in `claude-zipcode.md` (its `[→ §X]` pointers).
> - **`WOOF-06` + `INFLOW-06` are already re-authored** to the two-token shape (Gate seam, transferable szipUSD,
>   NAV-proportional); the stale `contracts/src/supply/ZipDepositModule.sol` stub is deleted; **cold-build them once
>   8-B1 / `SzipNavOracle` / the Exit Gate land** (they mock the Gate seam until then).
> - **`audit/1-results.md` I1–I5 are RETIRED** — they audited the deleted `J×p` / convert-on-stake / withhold szipUSD; the new
>   invariants derive **per-component through the critic fanout at ticket time**, not a standalone pass.
>
> `claude-zipcode.md` is the source of truth; **§17 is locked** but was **updated this session** to the new model.
> Trust `PROGRESS.md` + `LEDGER.md` + `reports/README.md` for current state. `reference/` submodules are initialized.

---

## Orient (read in this order)
1. **`tickets/PROGRESS.md`** — the ledger + **current state**: the `NEXT` item is your task, plus the open
   cross-ticket obligations and open spec gaps. **Start here.** (`tickets/LEDGER.md` = the per-component design
   digest; `reports/README.md` = the index of which reports are current vs superseded.)
2. **`audit/adversarial-spec/README.md`** — **the harness** (the per-ticket loop you run).
3. **Format model = a filed ticket** (`sample-ticket.md` was retired): a clean build-only ticket
   `tickets/woof/WOOF-01-lien-collateral-token.md`, and a build+interface pair
   `tickets/woof/WOOF-06-deposit-module.md` + `tickets/inflow/INFLOW-06-deposit-module.md`. Every ticket follows
   this field format.
4. **`README.md`** — §1 index, §2 MVP scope, **§4 the per-team build tasks (what you're ticketing)**, **§7 the
   repo layout (where each deliverable lands)**.
5. **`claude-zipcode.md`** — the spec. Every §4 task cites the § that defines it.
6. **`audit/2.md`** — the M1 tx-by-tx acceptance harness; the **build-priority spine** (Phase S S1→S12 setup,
   then Phase L L1→L12 loop) + the source of each ticket's "Done when". `audit/3-results.md` is the authority
   map. (Note: some item-8 acceptance rows carry `EXCISED / 8-B` markers — the Baal junior acceptance is
   re-authored at the 8-B build tickets, **not** a hole.)
7. **`pending-docs/`** — the *why* + open legs (`vision.md`, `spv-lien-proof.md`), not build spec. *(The post-M1 `treasury.md` economics doc was removed 2026-06-09 — to be re-authored.)*

Project memory (auto-loaded) holds the locked decisions + the authoring method. Trust it; the docs are authoritative.

---

## Your job — author one item per window
**`tickets/PROGRESS.md` is the ledger — the item marked `NEXT` is your task.** It's the persisted "what's
next" so a fresh context resumes with no conversation history. Build-priority spine = `audit/2.md` Phase S → L,
then the **item-8 decomposition** (Phase 8-S spec edits — DONE; Phase 8-B build tickets file in `tickets/sodo/`,
plus the senior `8-Bw` warehouse). Before drafting, check `PROGRESS.md → "Open cross-ticket obligations"` for
any rows **owed by your item** — the ticket MUST discharge each (the critics verify; mark `DISCHARGED` at
Conclude).

**Per item, run the harness** (`audit/adversarial-spec/README.md`):
draft the ticket(s) — build always, **interface only for user-facing items** (most WOOF contracts are
build-only) → fan out the critic subagents → **synthesize + triage** (spec-gap → fix `claude-zipcode.md`
FIRST; ticket-gap → fix the ticket) → **build it for real + KEEP it** (`forge test` green, commit under
`contracts/`; the discard/reset rule is **RETIRED** — keep-the-build doctrine, `kickoff.md`) → file in
`tickets/<team>/` → **conclude** (update `PROGRESS.md`, commit the code, report) → **STOP**.

**Cadence: one item per context window, then conclude and start fresh.** NOT mass-produced. The critics are
subagents (their token use stays out of this context), so one item per window is feasible — but always end in
a resumable on-disk state (the Conclude step) so context saturation never loses work. The harness *will*
surface spec gaps — fix them in the spec before writing the ticket around them (that is the point).

---

## Do not reopen (locked — `claude-zipcode.md` §17)
- Valuation = **Proof of Value**, **event-driven** (no AVM/HPI/heartbeat); **Proof family** gates before mint;
  collateral **mocked** for the MVP.
- **No subordination cap**; zipUSD = **$1 utility**; szipUSD = the main product via the **zap**. szipUSD is a
  **Baal/Moloch-v3 + Zodiac** vault but its **user share is a TRANSFERABLE ERC-20** the **Exit Gate** mints
  **NAV-proportionally** vs **soulbound gate-held Loot**. **NAV (`SzipNavOracle`, §7) is the pricing primitive.**
  Exit = windowed ragequit at `min(spot,twap)` NAV (partial-fill) + a **CoW secondary** + **8-B14 buy-and-burn**.
  **First-loss = a pari-passu conservative provision-that-recovers** (§11), **NOT** withhold-no-markdown. The
  **coverage floor is the freeze** (structural, not a knob). *(2026-06-07 two-token model; supersedes the
  soulbound-claim / ragequit-in-kind / WITHHOLD-no-markdown / ~30d-lock phrasing.)*
- **Duration Bond** (two triggers: default §11-A / duration squeeze §11-B); stack = junior → insurance → xALPHA
  (sold for a realized loss, never peg defense). **No on-chain economic liquidation** — `liquidate` is a
  defensive gate; resolution is off-chain → permissionless repay (§4.4e).
- **Venue-agnostic**, Euler = config one (§4.7). Fabric = **Zipcode subnet**, **Shape B** for M1.

## Done when
Every M1 task in `README.md` §4 has a harness-passed **build ticket** (+ an **interface ticket** where
user-facing), filed in its `tickets/<team>/` folder. Then hand back for the build.
