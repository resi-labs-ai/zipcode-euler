# Structure-2 — revolving insurance-underwritten credit lines (behavior note)

> Source of truth = the kept code under `contracts/src/` (UNCHANGED by this ticket) plus the proving tests in
> `contracts/test/ZipcodeController.t.sol` section `(6) Structure-2: revolving credit-approval line`.
> Ticket `build/tickets/contracts/CTR-08-revolving-credit-approval-line.md` is intent. Spec
> `claude-zipcode.md` §4.4 (origination/draw), §4.7 (`IZipcodeVenue` carries both structures as opaque
> `lineRef`s), §17. This is a BEHAVIOR note (no contract changed), not a wiring map of new code.

## What it is
A revolving credit-approval line is an OPERATING MODE over the as-built stack, not new code. The same
`ZipcodeController` + `EulerVenueAdapter` + `ZipcodeOracleRegistry` + `CREGatingHook` + `LienCollateralToken`
that serve a repo line (structure 1) already serve a revolving line. The only difference is how the CRE drives
the reports: the line is opened ONCE and then borrow -> permissionless repay -> redraw cycles on the SAME open
line, the SAME oracle key, and the SAME EulerEarn slot. The CRE simply never files an `RT_CLOSE` until the
borrower is disqualified or retired.

Repo is the safe default; revolving is the option for when an insurance policy exists (PROGRESS session
decision to accommodate BOTH structures). This note pins the mode so a future change cannot silently break it.

## Why zero contract change
Two as-built facts make revolving free:

- Redraw on an open line already works. `ZipcodeController._draw` (`src/ZipcodeController.sol:264-283`) requires
  only `r.open`, re-anchors the mark via `seedPrice`, then funds and draws again. EVK `repay` is permissionless
  and un-hooked — `EulerVenueAdapter.openLine` hooks only `OP_BORROW | OP_LIQUIDATE` (`:285`), never `OP_REPAY`.
  The only thing that closes a line is an explicit `RT_CLOSE`, which `closeLine`s and burns the token. So
  borrow -> repay -> redraw on ONE open line works today by not filing `RT_CLOSE`.
- One persistent oracle key per line. A repo open mints a NEW `LienCollateralToken` per `lienId`, so its oracle
  key churns n->inf across revolves. A revolving line opens ONCE, so the SAME token/key
  (`controller.getLien(lienId).lien`) persists across every redraw and `_draw` re-seeds that same key. Bounded
  keys by construction. `LienCollateralToken` is reused verbatim (1e18 fixed supply, controller-only,
  `decimals()==18`); a distinct token would buy only naming.

## The corrected disqualification mechanism
The accurate per-revolution on-chain gate is LTV x the mark VALUE the CRE supplies in that draw report. A
too-low mark makes the borrow exceed `borrowLTV x collateralValue`, the EVK account-status check reverts
`E_AccountLiquidity`, and the whole draw rolls back (proven by `test_Revolving_LtvBackstopOnRedraw`, and for the
pre-repay case by the pre-existing `test_Draw_ReAnchorBelowLTV_RollsBack`).

A stale (lapsed) mark does NOT block a draw. `_draw` re-anchors a FRESH mark via `seedPrice` (stamping
`block.timestamp`) BEFORE the borrow, so the draw self-refreshes the mark. Permissionless repay is un-hooked and
never quotes, so it also survives a lapse. Both halves are proven by
`test_Revolving_RepayAndRedrawSurviveMarkLapse`: after warping past the 365-day validity window an external
`getQuote` reverts `PriceOracle_TooStale`, yet repay still zeroes the debt and a subsequent `RT_DRAW` succeeds
and refreshes the mark.

Binary disqualification is OFF-CHAIN: draws are CRE-gated (§17, no public draw entry), so the CRE declines to
file an `RT_DRAW` for a disqualified borrower. An on-chain hard per-account block (an optional `CREGatingHook`
flag) is NOT built and NOT needed for M1 — documented as a future hardening option only.

## Coexistence
A repo line and a revolving line live in ONE EulerEarn pool. The repo line closes and burns its token and frees
its binding withdraw-queue slot (CTR-04 reclaim); the revolving line persists and can still redraw afterward.
Proven by `test_Coexistence_RepoAndRevolving_OnePool`.

## Proving tests (`contracts/test/ZipcodeController.t.sol`)
- `test_Revolving_BorrowRepayRedraw_SameSlot` — borrow -> repay -> redraw >=2x on ONE open line / key / slot;
  no new market or withdraw-queue slot minted; debt equals the redraw amount each cycle.
- `test_Revolving_PersistentOracleKey` — ONE persistent key across N revolutions (registry resolves it to the
  latest mark); a repo open mints a DISTINCT key (n->inf vs 1).
- `test_Revolving_LtvBackstopOnRedraw` — the per-revolution LTV x mark gate in the post-repay context; a too-low
  mark reverts `E_AccountLiquidity` and rolls back (line stays open, mark + debt unchanged).
- `test_Revolving_RepayAndRedrawSurviveMarkLapse` — the lapse correction: repay and a re-seeding redraw both
  survive a stale mark.
- `test_Coexistence_RepoAndRevolving_OnePool` — both structures, one pool; repo closes+frees-slot, revolving
  persists.

## Precondition fix shipped with this ticket
`test/ZipcodeController.t.sol`'s `MockEulerEarn` was extended with the withdraw-queue surface that CTR-04's
`closeLine` now calls (`cfgCap`, `_withdrawQueue`, `submitCap`/`acceptCap` bodies, `withdrawQueueLength` /
`withdrawQueue` getters, `updateWithdrawQueue` with KEEP-index removal guards, and a `reallocate` that iterates
all allocations handling the `target == 0` full-redeem defund leg). This resolved the 6 close-path tests that
were RED on `main` after CTR-04 updated only the faithful mock in `test/EulerVenueAdapter.t.sol`. No `src/`
change.
