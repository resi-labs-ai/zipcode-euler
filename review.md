# review.md — handoff: organize the docs into one build spec

> **For the next Claude.** This session worked the whole design through (oracle, gating, CRE→Go,
> allocator, collateral granularity, supply side, loss side) and the docs are individually coherent and
> current. What's left before building is **organization**: the build spec is currently spread across
> three technical docs (plus two plain-language narratives), with some duplication and a few stale
> fragments. This doc maps what exists, answers the structural questions, and lays out how to consolidate
> into a single concise build spec for a final review. It is a map and a plan — not a re-spec. No emojis.

---

## 1. The current doc set (what each is, and its state)

| Doc | Kind | Owns | State |
|---|---|---|---|
| `vision.md` | narrative | the *why* of the base protocol — problem, the CRE-underwriter insight, the three structures, north star | current |
| `risk-vision.md` | narrative | the *why* of the money — the two dollars, RESI, what happens on default, the dashboard | current |
| `claude-zipcode.md` | **technical spec** | base protocol: oracle, lien token, gating hook, controller, CRE workflows, control-flow, lifecycle, trust, business, demo, repo map, open decisions, glossary | **most complete spec**; but supply side is a *stand-in* (plain shares, §1 banner) and the loss branch (§3.4d) is a stub pointing out |
| `supply-redemption.md` | technical spec | the supply side: zipUSD 1:1 mint, yield routing, szipUSD junior, the epoch redemption queue, NAV/dashboard, "not using"/licensing | current, clean |
| `tokenomics-layer.md` | technical spec | the loss side: continuous markdown, socialized term-lock, RESI slash/bonus, recovery, settle | current (top matter cleaned 2026-05-22 — see §4) |
| `spv-lien-proof.md` | open issue | the one unresolved item: the off-chain SPV + lien-perfection proof | open by design |
| `todo.md` | working plan / index | doc-set status, resolved-pointers, next moves, the post-synthesis build checklist | current; the orchestration/entry doc |

---

## 2. The structural questions, answered

**Why are `vision.md` and `risk-vision.md` two docs?** Historical artifact. The tokenomics started life as a
"separate layer," so it got its own narrative. Now that it's one pathway, the split has no real
justification — they're both plain-language "why" docs telling halves of one story (the credit machine +
the money around it). **Recommendation: merge them into a single narrative.**

**What does `tokenomics-layer.md` do?** It is now the **loss side** — default detection → continuous
mark-to-recovery markdown → socialized pro-rata term-lock → RESI in-kind bonus (priced) → recovery loop →
settle. That's its job. (Its top matter previously still described the old supply-side framing; that was
cleaned 2026-05-22 — header rewritten to the loss side, the duplicate §2 token model replaced with a
pointer to `supply-redemption.md` §1, the superseded §4.1/§4.2/§7 stubs trimmed, and terminology unified
to "socialized term-lock.")

**What does `supply-redemption.md` do?** It is the **supply side** — how a depositor's USDC becomes zipUSD
(1:1 mint), how yield reaches szipUSD (EulerEarn `feeRecipient`), how redemption works (30-day epoch queue
+ secondary AMM), and how NAV/solvency is reported. Clean and self-contained.

**How do these differ from `claude-zipcode.md`?** They don't compete — they're **three fragments of one
build spec.** `claude-zipcode.md` is the base/oracle/gating/CRE spine and is the most complete single doc,
but it deliberately holds the supply side as a stand-in (plain shares) and the loss side as a stub.
`supply-redemption.md` fills the supply fragment; `tokenomics-layer.md` fills the loss fragment. Together
they are the whole spec — split for clean context, not because they're different layers.

---

## 3. The "one spec file" — authoritative source per section

If we collapse the three technical docs into one build spec, here is where the most-updated version of
each section lives today (the synthesis is mostly *assembling*, not rewriting):

| Build-spec section | Pull from | Note |
|---|---|---|
| Overview + component map | `claude-zipcode.md` §1 | replace the supply-side stand-in with the real zipUSD/szipUSD |
| Token model (zipUSD/szipUSD/RESI) | `supply-redemption.md` §1 | authoritative; `tokenomics-layer.md` §2 is a stale duplicate — drop it |
| Reused primitives | `claude-zipcode.md` §2 + `supply-redemption.md` §2 + `tokenomics-layer.md` §3 | merge the three tables; dedupe |
| Net-new contracts | `claude-zipcode.md` §3 (registry, lien token, hook, controller) + `supply-redemption.md` §3 (ZipDepositModule, szipUSD, ZipRedemptionQueue) + `tokenomics-layer.md` §4 (LienRESIEscrow, DefaultCoordinator) | one contracts section |
| Supply / mint / yield routing | `supply-redemption.md` §3–6 | authoritative |
| Redemption (epoch queue + secondary) | `supply-redemption.md` §7, §9 | authoritative |
| Oracle (two pricing inputs) | `claude-zipcode.md` §3.1/§7 (collateral equity mark) + `tokenomics-layer.md` §3 (RESI price feed) | both feeds in one place |
| CRE workflows | `claude-zipcode.md` §4 + `supply-redemption.md` §7.1 (settle trigger) + `tokenomics-layer.md` §6 (default report) | one CRE section |
| Authorization / control-flow trace | `claude-zipcode.md` §6 + supply mint/redeem + loss default flow | |
| Lien lifecycle + credit-line mechanics | `claude-zipcode.md` §8 + `tokenomics-layer.md` §5 (default detail) | |
| Loss / default / recovery machinery | `tokenomics-layer.md` §4–6 | authoritative |
| NAV / dashboard / solvency | `supply-redemption.md` §8 | authoritative |
| Trust & security model | `claude-zipcode.md` §9 + junior/RESI/recovery-timing from `tokenomics-layer.md`/`risk-vision.md` | |
| Business context (3 structures) | `claude-zipcode.md` §10 | |
| Proof-of-operations scope | `claude-zipcode.md` §11 | |
| Reference-repo map | `claude-zipcode.md` §12 + the 7540/Maple/Centrifuge repos from `supply-redemption.md` | |
| Open decisions | `claude-zipcode.md` §13 + `supply-redemption.md` §11 + `tokenomics-layer.md` §9 | consolidate (see §5 here) |
| Glossary | `claude-zipcode.md` §14 + the supply/loss glossaries | merge |
| Explicitly NOT using + licensing | `supply-redemption.md` §10 | authoritative |

**Bottom line:** `claude-zipcode.md` is the spine and the most complete single doc; the supply and loss
fragments slot into it at the marked seams (§1 supply stand-in, §3.4d loss stub).

---

## 4. Cleanup items (inconsistencies to fix during/before synthesis)

1. ~~`tokenomics-layer.md` stale top matter.~~ **DONE (2026-05-22)** — header rewritten to "loss side";
   §2 token model replaced with a loss-side pointer; §1 banner + glossary unified to "socialized
   term-lock"; the superseded §4.1/§4.2/§7 stubs trimmed to one-line pointers. In a merged spec they vanish.
2. ~~Token model defined twice.~~ **DONE (2026-05-22)** — `supply-redemption.md` §1 is authoritative;
   `tokenomics-layer.md` §2 now points to it (loss-side view only), no longer a divergent duplicate.
3. **`claude-zipcode.md` §1 supply stand-in** — in the merged spec the plain-shares stand-in is replaced
   by the real zipUSD/szipUSD supply; the §1 banner is then removed.
4. **Three separate "open decisions" lists** (claude-zipcode §13, supply-redemption §11, tokenomics §9)
   — consolidate into one (see §5).
5. **Two narratives** — merge `vision.md` + `risk-vision.md`.

---

## 5. Open decisions to close (consolidated — these gate "done")

Design is settled; these are parameters/policies and one real unknown:
- **Cash-reserve ratio:** fixed-% vs dynamic (scales with the redemption queue). (`supply-redemption.md` §9/§11, claude-zipcode §4.2)
- **Epoch length** (30d assumed) and whether redeem requests can cancel mid-epoch.
- **Term-lock length** (the default lock duration) and the **recovery haircut** value.
- **RESI price source** (DEX vs feed) for the insurance-bonus NAV.
- **Junior accounting unit** (zipUSD held vs EulerEarn shares) + **fee parameter `f`** (yield split) + **subordination cap/floor** values.
- **Surplus-recovery split** when recovery exceeds the loss (originator vs junior).
- **Proof-of-operations demo** — is it the first integration milestone, and what's in it.
- **Registry price path** — does `ZipcodeOracleRegistry` receive prices directly from CRE or only via the controller.
- **Perspective-verification** for the demo.
- **SPV ↔ lien-perfected proof schema** — `spv-lien-proof.md`. The one genuinely-open, off-chain/legal item; collateral is mocked until it exists.

---

## 6. Recommended target doc set

- **`spec.md`** (or keep the name `claude-zipcode.md`) — the single consolidated build spec, assembled per §3.
- **`vision.md`** — one merged narrative (vision + risk-vision).
- **`todo.md`** — the working plan / build checklist / index (unchanged role).
- **`spv-lien-proof.md`** — the open off-chain issue (or fold into the spec's open-decisions section).
- Retire `supply-redemption.md` and `tokenomics-layer.md` once their content is merged in (their seams in
  the spec are §1 supply and §3.4d loss).

---

## 7. Suggested order of operations for New Claude

1. **Close the parameter decisions in §5** with the user (or mark each explicitly as a build-time
   parameter), so the spec has no soft spots.
2. **Clean `tokenomics-layer.md` top matter** (§4 here) so the loss fragment is internally consistent
   before it's merged.
3. **Assemble the single build spec** per the §3 source map — assembling, not rewriting; verify each
   moved claim still cites a real `reference/` line (this session's habit: open the file, confirm the
   symbol, before trusting a citation).
4. **Merge the two narratives** into one `vision.md`.
5. **Update `todo.md`** to point at the consolidated docs and reflect the new doc set.
6. **Final review with the user**, then begin the build (the post-synthesis checklist is already in
   `todo.md`).

The goal is one concise, internally-consistent build spec + one narrative + the working plan + the one
open issue — nothing redundant, every section sourced from its most-updated fragment, ready to build.
