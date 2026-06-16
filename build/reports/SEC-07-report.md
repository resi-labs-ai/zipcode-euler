# SEC-07 report — `closeLine` defunds the line's USDC back to base (L8)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-08 (M6).
**Source:** kill-list Group 3 / L8 · audit finding #4 / ref-B6. **Ticket:** `build/tickets/sec/SEC-07-closeline-defund-to-base.md`.

## What the window did
Closed the L8 funding-brick: `closeLine` now returns the EulerEarn pool's `fund`-supplied USDC from a closed line's
borrow vault back to the base USDC market, instead of stranding it.

- **Contract (1 file, `src/venue/EulerVenueAdapter.sol:367-378`):** after the collateral redeem and **before** the
  SEC-06 supply-queue prune, read `lineBalance = convertToAssets(balanceOf(eulerEarn))` on `lineRef`; if non-zero, read
  the same on `baseUsdcMarket` and call
  `eulerEarn.reallocate([{lineRef, assets: 0}, {baseUsdcMarket, assets: baseBalance + lineBalance}])` — the inverse of
  `fund`'s absolute-target reallocate (`assets: 0` redeems the EE's whole line position; base absorbs it; zero-sum).
  No-op guard on `lineBalance == 0` (never-funded line). The collateral redeem, `L.open = false`, and the SEC-06 prune
  are otherwise untouched (additive); SEC-06's prune comment was corrected (the defund — not the redeem — is what now
  empties the removed market).
- **Test (1 file, `test/EulerVenueAdapter.t.sol`):** made `MockEulerEarn.reallocate` **faithful** — it now executes the
  absolute-target reallocation against the real EVK vaults (pass 1 withdraws / redeems-all to the pool's USDC cash, pass 2
  deposits), via a new `MockEulerEarn(usdc)` ctor. 3 new `test_SEC07_*` regressions.

## Decisions to sanity-check
1. **Faithful mock (the one non-obvious move).** The recording-only `MockEulerEarn.reallocate` could not move funds, so
   the strand / underflow were not reproducible — flagged by the junior-dev critic as the single most-blocking gap. I made
   the mock faithful (mirrors what SEC-06 did to `setSupplyQueue`). This is a test-fixture change, not a production-code
   change; the production fix is the 12-line `closeLine` block. Confirm you're comfortable that the regression's fidelity
   rests on the mock's two-pass withdraw/deposit replicating EE's reallocate (reference-verifier confirmed the semantics:
   absolute-target, zero-sum, `assets:0`→redeem-all, `EulerEarn.sol:383-442`).
2. **Sizing read = `convertToAssets(balanceOf(EE))`, NOT `previewRedeem(config[id].balance)`.** Deliberate: SEC-11 (L9)
   has not landed (the `_eeSupplyAssets` helper is absent), so the defund matches `fund`'s current sizing. The base-leg
   read is therefore donation-vulnerable in the *same* way `fund` is today — SEC-11 fixes both together. See hole #1.
3. **Defund sequenced before the prune.** Required so the pruned market is empty. Reference-verifier nuance: the defund
   would *also* work after the prune (EE's reallocate gates on `config[].enabled`, set by `acceptCap`, independent of
   supply-queue membership), but before-prune keeps the close path symmetric with the open path and avoids any reliance
   on post-prune reallocate-eligibility.

## Holes → resolution
- **L9/SEC-11 donation-immunity (open, by design).** Both `fund` and this defund size off `convertToAssets(balanceOf(EE))`;
  a 1-share donation can break `reallocate`'s zero-sum. SEC-11 will switch to `previewRedeem(config[id].balance)`; when it
  lands, the defund's base-leg read adopts the shared helper. Logged in audit B7 / finding #4 and the ticket's Do-NOT.
- **Live EE path unexercised at unit level (pre-existing).** Tests mock EE (it pins solc 0.8.26); the faithful mock now
  moves real USDC between live-fork EVK vaults, but the real `EulerEarn.reallocate` path is still the item-10 deploy/wiring
  concern, not unit-covered. Unchanged by SEC-07.

## Doc edits (doc-sync-checklist run)
- Ticket → DONE + Done-note with quoted `forge test` output and fail-before/pass-after evidence.
- `PROGRESS.md` → SEC-07 row DONE, SEC-08 set NEXT, header line updated, "Just done — SEC-07" section added.
- `kill-list.md` → L8 `[ ]`→`[x]` + `DONE 2026-06-15 (SEC-07)`.
- `audit-claude/` → finding **#4** (`findings.md` table + body) RESOLVED; ref **B6** (`reference-diff-findings.md`)
  RESOLVED; `SUMMARY.md` L-tier prose mention marked ✅(SEC-07). *(L8 has no own H/M SUMMARY row — it maps to numbered
  finding #4 / B6, per the kill-list↔audit non-1:1 note.)*
- `wires/WOOF-04.md` (owns `EulerVenueAdapter.sol` per `COVERAGE.md`) → `closeLine` behavior list now documents the defund
  step + ordering + `config[].enabled` rationale; the EE-mock note records the faithful `reallocate`.
- **No spec change** — interface-level fix; §4.7 intent unchanged (defund is the adapter's allocator role, the symmetric
  un-do of `fund`'s supply, just as SEC-06 un-did `openLine`'s queue append). **No back-pressure / no new obligation.**

## Gate (quoted)
- `forge build` → clean (lints only).
- `forge test` → **`787 passed; 0 failed; 3 skipped (790 total)`** (+3 over SEC-06's 784; 3 skips = pre-existing
  `DeployZipcode.t.sol` scaffold). Adapter suite `26 passed`.
- Fail-before (defund call disabled): `test_SEC07_CloseLine_DefundsUsdcToBase` FAIL `700000000000 !~= 1000000000000`;
  `test_SEC07_NoLaterFundUnderflow` FAIL `panic: arithmetic underflow or overflow (0x11)` (the exact `:290` bug);
  `test_SEC07_NeverFundedLine_NoDefund` PASS (guard test). Restored → all pass.

## Status + NEXT
SEC-07 DONE. Next: **SEC-08** (M6 — `openLine` runtime EE-timelock precheck + deploy-time perspective probe). STOP for review.
