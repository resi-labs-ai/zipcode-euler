# Exit auto-dump module — xALPHA→zipUSD on exit (§6.4 leg 2) — **TODO**

> **Status: TODO (not yet authored/built).** Created 2026-06-08 alongside the Exit Gate
> (`tickets/sodo/8-B-exit-gate-szipusd.md`) at the user's direction: "do pure RQ, and setup another ticket for
> auto-dump." Build it **after** the engine sell machinery (8-B9) and the live zipUSD/xALPHA Hydrex pool exist —
> it reuses that machinery. **Team folder:** `tickets/sodo/`. Build-only.

**Deliverable**
A separate Zodiac module (NOT the Exit Gate) that, after a leaver has ragequit their pro-rata basket slice
(zipUSD + xALPHA) via the Gate's `processWindow`, **market-sells the xALPHA leg → zipUSD on Hydrex** so the leaver
ends holding **only zipUSD** — which they then take through the existing `ZipRedemptionQueue` (zipUSD→USDC, §6.1).

The full junior leave path (the Gate does only step 1):
1. **Gate `processWindow`** → ragequit pro-rata in-kind → leaver receives zipUSD + xALPHA. *(done — Exit Gate)*
2. **This module** → market-dump the xALPHA → zipUSD on Hydrex → leaver holds all zipUSD. *(this ticket)*
3. **`ZipRedemptionQueue`** → zipUSD → USDC via the senior epoch queue. *(item 9 / §12, separate)*

**Open scope questions to resolve when authored**
- **Whose xALPHA does it dump — the leaver's, or the vault's pre-exit?** Two shapes: (a) the Gate ragequits the
  xALPHA leg to the leaver, then this module (with the leaver's approval / an integrated step) sells it; or (b) the
  exit is routed so the leaver only ever sees zipUSD (the module sells the xALPHA slice *during* the window and hands
  the leaver the zipUSD proceeds). Decide which at authoring — (b) is a smoother UX but couples the module into the
  window; (a) keeps the Gate pure (its current shape) and makes the dump a leaver-initiated follow-on.
- **Slippage / size bounds** — the HYDX/USDC-style constraints of the zipUSD/xALPHA pool (reuse 8-B9's soft-bleed
  caps); a large exit shouldn't tank the xALPHA mark.
- **It's "literally a fucking auto-dump" (user) — NOT an oracle concern.** Just a market sell on Hydrex. No NAV/oracle
  in this path.

**Model from (verify at build)**
- The engine **sell module 8-B9** (`baal-spec.md §10.8`) — `SwapRouter.exactInputSingle` on Hydrex; this module is
  the same swap machinery pointed at the exit's xALPHA leg. `SwapRouter 0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`.
- `reference/zodiac-core` `Module` (`is Module`, `onlyOperator`) — the CRE-operator pattern, like the engine modules.
- The live zipUSD/xALPHA ICHI pool (created at deploy; the gauge whitelist is the Hydrex-governance dependency).

**Depends on**
8-B9 (the Hydrex sell machinery), the live zipUSD/xALPHA pool, the Exit Gate (the source of the xALPHA leg). Author
it in its own window once those land.
