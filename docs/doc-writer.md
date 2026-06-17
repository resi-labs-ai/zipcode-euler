# doc-writer — handoff prompt for continuing the docs

Paste the section below to a fresh Claude window to continue this work. It captures the goal, the format, the
hard rules, and the verification discipline we've been using. Read it, then ask the user which contract/folder to do next.

---

## Your job

You are helping build human-readable documentation for the `zipcode-euler` protocol, **one contract or interface
folder at a time**, under `docs/`. The user leads — they name a target, you read it, you produce or validate the
doc, they direct edits. Work in small, verified increments. Do not run ahead.

## The two doc layers

1. **`docs/wires/<TICKET>.md`** — the detailed catalog (the existing, pre-written source-of-truth wiring maps:
   `8-B1.md`, `ExitGate-szipUSD.md`, `interfaces-*.md`, `SHOWCASE-VAMM.md`, etc.). `docs/wires/COVERAGE.md` maps
   every contract → its wire doc.
2. **`docs/<topic>.md`** or **`docs/interfaces/<topic>.md`** — the ELI20 SUMMARY you write/maintain. Summaries
   link DOWN to the wire(s). When a summary and a wire disagree, the summary is usually the freshly-corrected one —
   **sync the wire to match** (and tell the user you did).

Existing summaries to model on (read them first): `docs/bridge.md`, `docs/hydrex-demo-fork.md`,
`docs/interfaces/interfaces-algebra.md`, `docs/interfaces/interfaces-baal.md`.

## Format (match the existing summaries)

- `# TITLE` then a `[repo/path]` line.
- A ONE-LINE "what is this" intro (tighten it — not a bullet dump).
- For deployable systems: a short TODO list. For interface/reference catalogs: NO TODO section.
- A divider line (`====`), then an `Interface → target` (or `Contract → Chain`) block. Each entry:
  `- File.sol → target` then a plain one/two-sentence description, then bracketed links: source paths
  `[contracts/src/...]` and wire docs `[wires/...]`. Order entries by importance.
- `Summaries:` link to the wire catalog. Another `====` divider. `References:` (what it's built on / who consumes it).

## Always cover the secondary market / outside participants

If the thing touches a market, exchange, orderbook, or any tradable token (CoW, an AMM, a transferable share
token, etc.), the doc MUST say how **outside participants — not just the protocol — use it.** Don't describe
only the protocol's own path and make an open market look protocol-only. State plainly that the token trades
freely, that anyone can post their own orders/bids from their wallet without touching a Zipcode contract, and
note where the protocol's role is just one special participant (e.g. the backstop bid). Example: szipUSD is a
plain ERC-20; any buyer can bid on CoW directly — the protocol's module is special only because it signs on-chain
from a Safe. (See `interfaces-cow.md`.)

## Hard style rules (the user is strict on these — he should not have to repeat them)

- **NO markdown tables** — they break on paste. Use plain lists.
- **NO emojis.**
- **NO run-on sentences, ever.** This is the #1 repeat offense. If a description is one long sentence doing
  several jobs, it is wrong. Write short, single-idea sentences. A description is at most ~2-3 short sentences;
  if it needs more, use a lead line + clean sub-bullets (one idea per bullet).
- **Do NOT interrupt readable prose with function signatures / code.** A summary entry says what the thing IS
  and what we USE it for — in plain words. Function names, selectors, `setPreSignature(...)`, struct fields,
  `msg.sender`, etc. belong in the wire doc, NOT in the summary description. If you're tempted to list functions
  in a sentence, you're writing the wrong doc.
- **Plain English. Unpack or omit jargon.** No bare "EIP-712", "selector", "seam", "face", "shim", "presign",
  "domain separator", "msg.sender" in a description. Either say it in plain words ("a chain-specific tag", "the
  interface", "the contract that pulls the funds") or leave it for the wire doc. Call an interface an
  "interface," not a "face" or "tool."
- **Full addresses, NEVER truncated** — not in the doc and not in chat. `0x…0805` is not an address. For more
  than one address, use an aligned monospace block (fenced ```), not inline-in-prose.
- **Communicate ONE coherent, brief idea per entry.** Think about what you're trying to say before you write it.
  Laziness reads as a wall of text the user has to parse. Brevity + clarity beats completeness here.
- **Terse. Don't pad.** If a read-through is clean, say "clean" and stop — do not invent nitpicks.

When the user pastes a chunk back and swears at it, it is almost always one of the above (run-on, jargon,
function-signatures-in-prose, or truncated address). Fix THAT, don't re-explain.

## Verification discipline (this is the important part)

- **Before writing any "used by / consumed by" claim, VERIFY it.** `grep -rl "<Name>" contracts/src contracts/script`
  to find the REAL importers. Do not infer consumers from naming. (This session caught: an NFPM shim claimed
  "used by LPModule" but nothing imports it — it's reserved for an unbuilt feature; a factory shim is build-time
  verification only; a pool/plugin had an unlisted consumer.)
- **Read the actual `.sol` before describing it.** Natspec headers can be stale — trust the code (functions,
  imports), not the comment. (This session: an ExitGate header said "sole ragequit caller" but the code has no
  ragequit function at all.) When you find stale `src/` natspec, fix it too (with the user's ok).
- **Validate claim-for-claim, report drift, then let the user direct edits.** Don't bulk-rewrite.
- **Do NOT fan out subagents to "critique" the docs, and never relay subagent output unscreened.** Open-ended
  "what's wrong?" prompts make agents invent problems. Do the judgment inline.
- **If a read-through is clean, say "clean, nothing to fix" and stop.** Don't manufacture a nitpick to look thorough
  (the tell: flagging something and then arguing it doesn't need fixing).

## Repo orientation

- Contracts: `contracts/src/` (bridge, supply/szipUSD, supply, venue, loss, demo→`hydrex-demo-fork`, interfaces/*).
- Interfaces to catalog: `contracts/src/interfaces/{algebra,baal,bridge,cow,euler,hydrex,ichi,loss,safe,supply,zodiac}`.
- Deploy scripts: `contracts/script/`. Live address book: `contracts/script/BaseAddresses.sol`.
- Local fork ops + smoke paths: `build/anvil/` (Base fork @ 8453; `contract-map.md` is the live address board).
- Reference upstreams (gitignored, pinned): `reference/MANIFEST.md`.

## Progress so far

Done: `README.md` (BRIDGE section), `docs/bridge.md`, `docs/hydrex-demo-fork.md`,
`docs/interfaces/interfaces-algebra.md`, `docs/interfaces/interfaces-baal.md`.

Next candidates: the remaining `docs/interfaces/` summaries (cow, euler, hydrex, ichi, loss, safe, supply, zodiac,
bridge) and the core `src/supply/szipUSD/` module docs. Ask the user which.

## Memory

There are project memories that encode this workflow and the protocol's economics —
`docs-authoring-pattern`, `do-not-delegate-judgment-on-own-docs`, `junior-yield-thesis`, `exit-topology-intentional`,
plus `terse-answers-only` and `read-before-flagging`. They load automatically; honor them.
