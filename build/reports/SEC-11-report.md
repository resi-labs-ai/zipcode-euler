# SEC-11 report — `fund`/defund sized off the EE-tracked position (L9, donation-immune)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Kill-list:** L9 · **Audit:** ref-B7 / finding #4 follow-on
**Ticket:** `build/tickets/sec/SEC-11-fund-previewredeem-sizing.md` · **Status:** DONE

## What the window did
Closed the L9 donation-grief DoS in `EulerVenueAdapter`. `fund` (and SEC-07's `closeLine` defund) sized their
ABSOLUTE-target `eulerEarn.reallocate` legs from `convertToAssets(balanceOf(eulerEarn))` — the EE pool's *live*
EVK-share balance. But `reallocate` internally measures each market's current assets as
`previewRedeem(config[id].balance)` — the EE's *tracked* share balance, which deliberately ignores direct share
transfers (`IEulerEarn.sol:69,73`). So anyone could donate even one EVK share into the pool to make `balanceOf`
exceed `config.balance`; the computed targets then disagreed with EE's own accounting, the withdraw/supply deltas
no longer netted to zero, and funding/defunding bricked (grief — operator-trusted, no theft).

**Fix (1 contract file, `EulerVenueAdapter.sol`):** added a shared internal view
`_eeSupplyAssets(market) = IEVault(market).previewRedeem(eulerEarn.config(IOZERC4626(market)).balance)`. `fund`
now sizes both legs off it; `closeLine`'s defund sizes both its base leg and its `lineBalance != 0` guard off it
too (the line leg stays `assets:0` — a full redeem already sweeps any donated shares per `EulerEarn.sol:397-402`).
The two-item absolute-target structure, `amount`/EVC/draw paths, and the no-sweep/no-block stance are unchanged.

## Decisions to sanity-check
1. **SEC-07 coordination discharged inside this window.** The ticket's Depends said "when both land, point SEC-07's
   defund at `_eeSupplyAssets`." SEC-07 had already landed, so SEC-11 repointed the defund now (base leg + guard).
   This is explicitly the allowed "share the helper" scope, not H2/L8 scope creep. If a reviewer prefers SEC-07 and
   SEC-11 to stay textually separate, the defund change is the only cross-ticket edit and is trivially isolable.
2. **The concrete pre-fix revert is NOT literally `InconsistentReallocation` in the test.** The EE pool holds no
   idle USDC, so on a donation the under-withdrawal leaves the supply leg short and the *deposit* reverts
   (`ERC20: transfer amount exceeds balance`) before the terminal `InconsistentReallocation` check is reached. With
   idle cash present it would be `InconsistentReallocation` proper. Both brick funding — the kill-list/audit naming
   it `InconsistentReallocation` is the with-idle-cash case. The regression therefore uses a bare `vm.expectRevert()`
   (robust to which internal revert fires); the fail-before/pass-after pairing is unaffected.
3. **Test-mock rework was the bulk of the work.** Two `MockEulerEarn`s (one per adapter-wiring test file) had to grow
   a `config()` getter. The `EulerVenueAdapter.t.sol` one was made fully faithful to `EulerEarn.reallocate`
   (`previewRedeem(config.balance)` sizing + `InconsistentReallocation` invariant + tracked `cfgBalance`) so the
   grief is reproducible; the `ZipcodeController.t.sol` integration mock got a minimal `config()` returning live
   `balanceOf` (no donation path there → tracked == live → production sizing byte-identical to pre-fix). Both are
   documented in-file. This is mock-faithfulness work, not a behavior change to production sizing on the no-donation
   path.

## Holes → resolution
- **Mock faithfulness divergence risk.** The faithful mock now mirrors `EulerEarn.reallocate:383-442` closely (it
  omits only the `type(uint256).max` supply branch and the `SupplyCapExceeded` check, which `fund`/`closeLine` never
  exercise — caps are `type(uint136).max`). Resolution: documented the omissions in the mock's NatSpec; the live EE
  path remains the item-10 integration concern (per WOOF-04).
- **Junior-dev most-blocking item (the mock could not reproduce the bug).** Resolved by the rework above before the
  cold build — folded into the ticket's DONE-note Test-fixture section so a cold rebuild is self-sufficient.

## Doc edits (doc-sync-checklist run)
- **Ticket** — status DONE + full DONE-note with quoted `forge test` output (line refs also corrected from the
  stale `:285-287`/`:289-292` the critic flagged → `:295-297`/`:299-302`).
- **PROGRESS.md** — SEC-11 row DONE, SEC-12 set NEXT, "Just done — SEC-11" note added, SEC-07's pending
  L9/SEC-11-interaction note marked DISCHARGED.
- **kill-list.md** — L9 `[ ]`→`[x]` + DONE note + corrected line ref.
- **audit-claude/** — `reference-diff-findings.md` B7 marked ✅ RESOLVED; `findings.md` #4 follow-on note marked
  RESOLVED; `SUMMARY.md` L9 line marked ✅(SEC-11).
- **wires/WOOF-04.md** (the owning truth-source per `COVERAGE.md`) — `fund` and `closeLine` defund sizing lines
  rewritten to `_eeSupplyAssets`/`previewRedeem(config.balance)`; the mock-hardening note extended for SEC-11.
- **No `claude-zipcode.md` spec change** — interface-level sizing-precision fix; §4.7 intent (the adapter's
  allocator role over `reallocate`) is unchanged; this fences a donation-grief gap the spec implicitly assumed away.
- **No back-pressure / no new obligation** — uses EE's existing `config`/`previewRedeem` surfaces.

## Status + NEXT
- **Gate:** `forge build` clean; `forge test` **803 passed / 0 failed / 3 skipped** (+3 over SEC-10's 800; 3 skips
  are the pre-existing `DeployZipcode.t.sol` scaffold). 3 new `test_SEC11_*`. Fail-before/pass-after confirmed.
- **NEXT:** SEC-12 — `ZipRedemptionQueue.redeem()` emits canonical shares (L11, event-only).
