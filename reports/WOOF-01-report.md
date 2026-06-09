# WOOF-01 — authoring-window report to the superintendent

> **UPDATE 2026-06-06 — MATERIALIZED + BUILT-VERIFIED (keep-the-build doctrine).** The contracts were built for
> real from the ticket alone against the WOOF-00 scaffold and **kept on disk** (NOT discarded — the original
> "`contracts/` back to skeleton" line below is retired). **Evidence:** `forge build` clean (solc 0.8.24) +
> **`forge test` 14/14 PASS** (independently re-run this session, exit 0; covers token shape, ctor zero-guard,
> precompute-matches-deploy with empty-slot check, keyed-on-(lienId,controller), caller-bound squat-proof,
> dedup/single-use, burn authority + bounds, transferability, `LienCreated`, `LIEN_DECIMALS==18`). The real build
> found **no spec/citation error** — a genuine zero-spec-guess keepsake; the only open points were 3 cosmetic
> build choices, now pinned in the ticket banner. Code at `contracts/src/{LienCollateralToken,LienTokenFactory}.sol`
> + `contracts/test/LienToken.t.sol`. The 2026-06-04 authoring narrative below is preserved for the design rationale.

**From:** the builder Claude (ticket-authoring harness). **To:** the superintendent.
**Item:** 2 — `LienCollateralToken` + `LienTokenFactory` (§4.2 → WOOF-01).
**Date:** 2026-06-04 (authoring); **2026-06-06** (materialized + built). **Branch:** `main`.

## TL;DR
- Authored item 2 end-to-end (5 critics → triage → cold-build).
- Surfaced + fixed **one real spec gap** (§4.2 deploy-order circularity) and **one compile blocker**
  (0.8.26-only `require(cond, CustomError())` on a 0.8.24 pin), plus QA/security cross-ticket obligations.
- User-directed follow-ups, re-verified by cold-build: pinned SPDX `GPL-2.0-or-later`; simplified `create`
  two-arg → one-arg (threaded through spec + `audit/2.md` + `audit/3-results.md` + ticket). Re-cold-build: 14/14.
- Repo clean + resumable: `contracts/` back to skeleton; ledgers updated; **NEXT = item 3 (`ZipcodeOracleRegistry`, §4.1)**.

## Design decisions (superintendent sanity-check)
**A. §4.2 factory authority (spec gap, fixed in spec).** §4.2 implied the factory holds the controller as an
immutable, but the controller's constructor takes `lienFactory` → deploy-order circularity. Fixed
`claude-zipcode.md` first: the token's controller is `create`'s **caller**, immutable at the token's own
construction. Matches audit/3 row 18 + the §9 trace. No §17 reopened.

**B. `create` two-arg → one-arg (user-directed, threaded).** `create(bytes32 lienId)` uses `msg.sender` as the
authority, no gate. Inherently squat-proof: CREATE2 init-code embeds the caller, so an attacker's
`create(lienId)` lands at a *different* address — can't occupy the canonical `LIEN_i`. `computeAddress` stays
two-arg (pure prediction). Re-cold-build proved it incl. a squat-proof test.

## Holes the harness surfaced
| # | Severity | Hole | Resolution |
|---|---|---|---|
| 1 | spec gap | §4.2 deploy-order circularity | rewrote §4.2 → caller-bound create |
| 2 | blocker | `require(cond, CustomError())` is 0.8.26+; pin is 0.8.24 (`Error 9322`) | mandated `if (!cond) revert` |
| 3 | med (x-ticket) | `burn` reverts if `1e18` still in `EVAULT_i` at close | controller-ticket §4.4c obligation (LEDGER) |
| 4 | low (x-ticket) | registry must validate a key's `decimals()` vs `LIEN_DECIMALS` | registry ticket §4.1 (LEDGER) |
| 5 | qa | edge tests missing (zero-guard, burn(0)/burn(>bal), re-create-after-burn, transferability, distinct-controller precompute, event) | added to Done-when |
| 6 | cosmetic | SPDX unpinned | pinned `GPL-2.0-or-later` (WOOF-00 + WOOF-01) |

## Authoritative-doc edits (review)
- `claude-zipcode.md` §4.2 — factory authority paragraph → caller-bound `create(lienId)`.
- `audit/2.md` L4 steps 3–4 — `computeAddress(lienId, ZIP_CONTROLLER)` precompute + `create(lienId)`.
- `audit/3-results.md` row 19 + negative-test row — `onlyController` → caller-bound/squat-proof.
- `audit/adversarial-spec/README.md` §6 — added the LEDGER update bullet.

## Judgment calls (superintendent ruled: all four stand — see §3a discipline added to the harness)
1. Re-ran only cold-build (not 5 critics) on the one-arg revision — strict simplification + new squat-proof test.
2. Edited the acceptance harness (`audit/2.md`, `audit/3-results.md`) downstream of the spec change.
3. Burn-custody routed to the controller ticket, not solved in the token.
4. 5 critics (cheap-three + qa + security) for a foundational authority-bearing contract.

## Status & next
Done + filed: items 1 (WOOF-00), 2 (WOOF-01), 4 (WOOF-03). **NEXT = item 3 (`ZipcodeOracleRegistry`, §4.1).**
