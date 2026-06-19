# CTR-08 — Structure-2: revolving insurance-underwritten credit lines

> **RE-SCOPED 2026-06-19 — ZERO contract change.** The Key-req #5 question ("is ANY new contract needed?") is
> RESOLVED: **no.** The as-built `ZipcodeController` + `EulerVenueAdapter` + `ZipcodeOracleRegistry` +
> `CREGatingHook` + `LienCollateralToken` ALREADY support a revolving, borrower-keyed credit line. Structure-2 is
> an **operating MODE** over the existing surfaces, not new code. So this ticket is a **fork-test + doc** that
> PROVES the mode on the built stack (the harness "the code is the proof") and pins it so a future change can't
> silently break it. It is a contract-track item (forge-test gate) like CTR-04/CTR-07 — it just changes only
> `test/` + `docs/`, no `src/`.
> Spec: `claude-zipcode.md` §4.4 (origination/draw), §4.7 (`IZipcodeVenue` carries both structures as opaque
> `lineRef`s), §17. **Session decision (PROGRESS 2026-06-18): accommodate BOTH structures; repo is the safe
> default, revolving is the option for when an insurance policy exists.**

## Why zero contract change (the resolution, verified against live source this window)
Two as-built facts make revolving free:

1. **Redraw on an open line already works.** `ZipcodeController._draw` (`src/ZipcodeController.sol:264-283`)
   requires only `r.open`, re-anchors the mark (`seedPrice`), then `fund` + `draw` again. EVK `repay` is
   permissionless and un-hooked (`EulerVenueAdapter` never installs `OP_REPAY`; `openLine` hooks only
   `OP_BORROW | OP_LIQUIDATE`, `:285`). The ONLY thing that closes a line is an explicit `RT_CLOSE`
   (`:286-309`), which `closeLine`s + burns the token. So **borrow → repay → redraw on ONE open line works
   today** — you simply do not file `RT_CLOSE` until disqualification/retirement.

2. **One persistent oracle key for the line's life.** Repo (structure 1) mints a NEW `LienCollateralToken` per
   `lienId` (`_origination` `:233`) → the oracle key churns n→∞ across revolves. Revolving opens the line ONCE,
   so the SAME token/key (`controller.getLien(lienId).lien`) persists across every redraw — `_draw` re-seeds the
   SAME `r.lien` (`:276`). Bounded keys, by construction.

**Reuse `LienCollateralToken` verbatim** — it is already a 1e18 fixed-supply, controller-only, `decimals()==18`
token (`src/LienCollateralToken.sol:7-36`) that passes the registry strict-18 guard
(`src/ZipcodeOracleRegistry.sol:146,152-156`). Its symbol ("zLIEN") is cosmetic; functionally it is exactly the
revolving-line key. A distinct token would buy only naming — **not built**.

## The corrected disqualification mechanism (ticket-fix vs the prior draft)
The prior draft claimed: *"on disqualification the CRE revalues the mark down OR lets it lapse, and new borrows
fail closed."* The **lapse half is WRONG** — verified against `_draw`:

`_draw` re-anchors a **fresh** mark via `seedPrice(r.lien, equityMark)` (`:276`), which stamps
`uint48(block.timestamp)` (`ZipcodeOracleRegistry.seedPrice:113-115`), **before** the borrow. So a lapsed
(stale) mark can **never** block a draw — the draw self-refreshes it. The only borrow path is `draw`, which
always re-seeds.

The **accurate** on-chain gate per revolution is the **LTV × the mark VALUE the CRE supplies in that draw
report**: a too-low mark makes the borrow exceed `borrowLTV × collateralValue` and the EVK account-status check
reverts `E_AccountLiquidity`, rolling the whole draw back (already proven for the non-repaid case by the
existing `test_Draw_ReAnchorBelowLTV_RollsBack`). **Binary** disqualification is **off-chain**: draws are
CRE-gated (§17 — no public draw entry), so the CRE simply **declines to file an `RT_DRAW`** for a disqualified
borrower. An on-chain hard per-account block (the optional `CREGatingHook` flag in the old Deliverable #4) is
**NOT built and NOT needed for M1** — documented as a future hardening option only.

## Deliverable (test + doc only; NO `src/` change)
### A. PRECONDITION FIX — CTR-04 regression in `test/ZipcodeController.t.sol`'s `MockEulerEarn` (forced)
**Finding (this window): the controller suite is RED on `main`.** CTR-04 extended `EulerVenueAdapter.closeLine`
to reclaim the binding withdraw-queue slot — it now calls `eulerEarn.submitCap(.,0)`, `withdrawQueueLength()`,
`withdrawQueue(i)`, `updateWithdrawQueue(indexes)` (`src/venue/EulerVenueAdapter.sol:480-512`). CTR-04 updated
only `test/EulerVenueAdapter.t.sol`'s mock, **not** `test/ZipcodeController.t.sol`'s simpler `MockEulerEarn`
(`test/ZipcodeController.t.sol:47-112`), which lacks those methods. So every `closeLine` reverts here → **6
failing tests** (`test_Close_L7L8_RepayThenRelease`, `test_Close_DoubleClose_Reverts`,
`test_Draw_OnClosedLine_Reverts`, `test_CTR03_LineCount_IncrementsAndDecrements`,
`test_CTR03_OpenLine_ClosesAfterSiloRetired`, `test_CTR03_RealRegistry_OriginateAndClose`). CTR-03's recorded
"34 passed" predates CTR-04. CTR-08's coexistence proof needs a working close path, so this fix is a forced
precondition (and the gate cannot be green without it).

**The fix — extend `test/ZipcodeController.t.sol`'s `MockEulerEarn` (lines 47-112) with the withdraw-queue
surface `closeLine` calls.** Keep it MINIMAL and ADDITIVE (do not perturb the 28 passing tests). Model the
faithful version in `test/EulerVenueAdapter.t.sol:55-62,80,93,104-128,135-137,187-242` (the CTR-04 mock) but
keyed off this mock's live-`balanceOf` accounting (this controller-integration mock has NO donation path, by
design — its comment `:66-74`). Add exactly:
- `mapping(address => uint136) public cfgCap;` (per-market cap; the removal guard reads it).
- `IOZERC4626[] internal _withdrawQueue;`
- errors `InvalidMarketRemovalNonZeroCap(address id)` and `InvalidMarketRemovalNonZeroSupply(address id)`.
- `submitCap(IOZERC4626 id, uint256 cap)` body → `cfgCap[address(id)] = uint136(cap);` (currently empty `:63`).
- `acceptCap(IOZERC4626 id)` body → push `id` onto `_withdrawQueue` on first enable (a contains-guard so a
  re-accept does not double-push); currently empty `:64`.
- `withdrawQueueLength()` / `withdrawQueue(uint256 i)` getters (mirror the supply-queue getters `:83-89`).
- `updateWithdrawQueue(uint256[] calldata indexes)` — KEEP-index semantics (faithful to
  `EulerVenueAdapter.t.sol:212-242`): rebuild from the kept indexes; every current index NOT listed is removed,
  and a removed market must have `cfgCap[id] == 0` (else `InvalidMarketRemovalNonZeroCap`) and be empty
  (`IEVault(id).previewRedeem(IEVault(id).balanceOf(address(this))) == 0`, else
  `InvalidMarketRemovalNonZeroSupply`); clear `cfgCap[id]` on removal.
- **`reallocate` (`:93-111`): the current body is HARDCODED to act only on `allocs[1]`** (`:103-104` — it reads
  the line vault as index 1 and deposits). But `closeLine`'s defund puts the line at index **0** with
  `target == 0` (`defund[0] = {lineRef, 0}`, `defund[1] = {baseUsdcMarket, ...}`, `EulerVenueAdapter.sol:457-458`),
  so the hardcoded-index-1 body never touches the line and never empties it. **Change `reallocate` to ITERATE
  EVERY allocation** (keep the existing record loop `:96-99` unchanged), and for each `allocs[i]` act on exactly
  two branches, NO-OP otherwise:
  - `target == 0` → REDEEM all of that market's shares
    (`IOZERC4626(id).redeem(IOZERC4626(id).balanceOf(address(this)), address(this), address(this))`) — empties the
    line on defund so the removal guard's `previewRedeem(balanceOf) == 0` passes.
  - `target > current` → deposit the delta (the EXISTING leg, `:106-110`, with `current =
    convertToAssets(balanceOf(this))`).
  - else (`0 < target < current`) → **no-op** (do nothing).

  This is behavior-preserving for the 28 passing tests: in `fund` the line leg is `target > current` → deposit
  (unchanged) and the base leg is `target = baseBalance - amount` with `0 < target < current` → no-op (the old
  body never inspected `allocs[0]` either, so base is untouched in both old and new). The ONLY new behavior is the
  `target == 0` redeem, which is reached ONLY by `closeLine`'s defund (which was already reverting). Do NOT add a
  generic `target < current` withdraw leg — that WOULD perturb `fund`'s base leg.

Do NOT touch `config()`'s return shape (the adapter reads only `.balance`; the mock's own `updateWithdrawQueue`
reads the separate `cfgCap` mapping). Do NOT replace this mock with the faithful `EulerVenueAdapter.t.sol` one
(that would require `seedConfig` threading through this setUp and broadens the change). Do NOT modify
`test/EulerVenueAdapter.t.sol` (its mock + suite are green and out of scope).

### B. Add a structure-2 revolving test section to `test/ZipcodeController.t.sol`
A new section `// (6) Structure-2: revolving credit-approval line`, reusing the existing fixture + helpers
(`_originate`, `_origReportSilo`, `_drawReport`, `_closeReport`, `_repay`, `_repayAndClose`, `_borrowAccountOf`,
constants `SILO_0`/`EQUITY_MARK`/`BORROW_LTV`/`LIQ_LTV`/`DRAW_AMOUNT`/`CAP`, `LIEN_ID`, `LIEN_ID_2`). The
registry's `validityWindow` is **365 days** (`setUp` `:291`). Every `_drawReport` after an earlier same-lien seed
must `vm.warp(block.timestamp + 1)` first (SEC-01 strictly-newer-ts guard, `ZipcodeOracleRegistry:145`) — mirror
the existing draw tests (`:562,:583`).

Pinned fixture choices (so the build is zero-guess): use `LIEN_ID_2` as the revolving line id; seed `EQUITY_MARK`
($200k) on every revolution unless a test needs a low mark; use `DRAW_AMOUNT` ($100k, well under `0.8 × $200k`)
for each draw/redraw. For Test 4's staleness assert, the file imports only `EVKErrors` (`:25`) — ADD
`import {Errors as PriceErrors} from "euler-price-oracle/lib/Errors.sol";` and assert the FULL error (this repo's
forge-std does a full-returndata compare for `expectRevert(bytes4)`, so a bare selector does NOT match a 2-arg
error): `vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_TooStale.selector, 365 days + 1,
registry.validityWindow()))`. The two args are DETERMINISTIC, not fragile: staleness == the exact warp delta from
the originate-time seed (`365 days + 1`, no intervening warp), window == the registry's live `validityWindow()`.
`getQuote` is the public `BaseAdapter` view already used at `:470`. The base USDC market is NOT in the withdraw queue here
(it is seeded directly in setUp, never `acceptCap`'d), so only `acceptCap`'d line markets occupy withdraw-queue
slots — the coexistence test asserts RELATIVE deltas + line-ref presence/absence, not an absolute length tied to
base. Five tests:

1. **`test_Revolving_BorrowRepayRedraw_SameSlot`** — the core revolving proof. Originate `LIEN_ID_2`; capture
   `lineRef`, `oracleKey (= r.lien)`, `borrowAccount`, supply-queue length, withdraw-queue length. Full
   permissionless `_repay(LIEN_ID_2)` to zero debt; do NOT close. `vm.warp(+1)`; `RT_DRAW` again on `LIEN_ID_2`
   → succeeds. Assert: `r.open` still true; same `lineRef` / same `oracleKey` / same `borrowAccount`; supply-queue
   AND withdraw-queue lengths UNCHANGED (no new market/slot minted); `debtOf(borrowAccount) == the redraw amount`;
   `getLien(LIEN_ID_2).lien` unchanged. Run the borrow→repay→redraw cycle ≥2× to show it revolves on one slot.
2. **`test_Revolving_PersistentOracleKey`** — bounded-key contrast. Across N revolutions of `LIEN_ID_2`,
   `getLien(LIEN_ID_2).lien` is CONSTANT and the registry holds ONE cache entry for it
   (`registry.getQuote(1e18, key, usdc)` resolves to the latest seeded mark throughout). Contrast: originate a
   SEPARATE repo line under `LIEN_ID` → assert its `lien` address `!=` the revolving key (a repo open mints a
   distinct token = a distinct key; n→∞ vs 1). Documents Key-req #4.
3. **`test_Revolving_LtvBackstopOnRedraw`** — the per-revolution on-chain gate (proves the corrected mechanism).
   Originate `LIEN_ID_2` (debt outstanding). Repay fully; do NOT close. `vm.warp(+1)`. A redraw whose
   `equityMark` is too low for the requested amount (e.g. `lowMark` such that `0.8 × lowMark < draw`) reverts
   `EVKErrors.E_AccountLiquidity` and rolls back (line stays open; prior mark + debt unchanged). This is the LTV
   × mark backstop in the revolving (post-repay) context, distinct from the existing pre-repay
   `test_Draw_ReAnchorBelowLTV_RollsBack`.
4. **`test_Revolving_RepayAndRedrawSurviveMarkLapse`** — the lapse correction (load-bearing). Originate
   `LIEN_ID_2` (debt outstanding). `vm.warp(block.timestamp + 365 days + 1)` so the mark is stale for external
   readers — assert `registry.getQuote(1e18, key, usdc)` reverts (`Errors.PriceOracle_TooStale`). (a)
   permissionless `_repay` STILL zeroes the debt (repay is un-hooked, never quotes). (b) An `RT_DRAW` AFTER the
   lapse STILL succeeds (the draw re-seeds a fresh mark, then borrows) → proving lapse does NOT block a draw
   (the corrected mechanism). Assert the post-redraw `getQuote` resolves again (mark refreshed) and debt rose by
   the redraw amount.
5. **`test_Coexistence_RepoAndRevolving_OnePool`** — both structures, one EE pool (Key-req #3). Originate a repo
   line (`LIEN_ID`) and a revolving line (`LIEN_ID_2`) into `SILO_0`. Revolving: draw→repay→redraw, persists
   `open`. Repo: draw→`_repay`→`RT_CLOSE` → token burned, `r.open == false`, AND its market is removed from the
   withdraw queue (slot freed, CTR-04: `ee.withdrawQueueLength()` drops by 1, the repo line's `lineRef` no longer
   present). The revolving line stays open and can still redraw afterward. Assert both held one slot each while
   concurrent.

### C. Doc
A short doc/wire note recording structure-2: the operating-mode definition, the bounded-key contrast, the
**corrected disqualification mechanism** (LTV × mark + off-chain non-filing; lapse does not block a re-seeding
draw; the hook flag is unbuilt/optional), and the "zero contract change" resolution. Home: a new
`docs/wires/CTR-08-structure-2-revolving.md` (a behavior note, since no contract changed) + a `COVERAGE.md`
mention; plus a forward note in `PROGRESS.md`. No `claude-zipcode.md` edit (the federation/structure-2 §-sync is
forward-deferred per the federation-section §-sync note; this invents no mechanism).

## Spec §
`claude-zipcode.md` §4.4 / §4.7 / §17. (No structure-2 section exists in the spec — it is a PROGRESS session
decision; the §-sync is forward-deferred, NOT a precondition.)

## Binds to (verified against live source this window)
- Redraw path: `ZipcodeController._draw` (`src/ZipcodeController.sol:264-283`); re-seed `:276`; `RT_DRAW` routing
  `:197-198`. `_origination` `:212-261`; `_close` `:286-309`.
- Mark gate: `ZipcodeOracleRegistry.seedPrice` `:113-117`, `_writePrice` (strictly-newer `:145`, strict-18
  `:146`), `_getQuote` (`TooStale` `:175-177`), `validityWindow` ctor `:79-84`.
- Permissionless repay + un-hooked: `EulerVenueAdapter.openLine` `:285` (`OP_BORROW | OP_LIQUIDATE` only);
  `closeLine` withdraw-queue reclaim `:480-512`.
- Token shape: `LienCollateralToken.sol:7-36` (1e18, controller-only burn, `decimals()==18`).
- `IZipcodeVenue` (`src/venue/IZipcodeVenue.sol`) — unchanged.
- Test fixture: `test/ZipcodeController.t.sol` (real Base-fork EVK; `MockEulerEarn:47-112`; setUp `:283-373`;
  helpers `:375-424`, `:610-627`). CTR-04 faithful mock to model: `test/EulerVenueAdapter.t.sol:55-248`.

## Starting state
- Structure 1 built + fork-tested. `_draw` redraw-on-open + mark-driven LTV gating exist. CTR-02/03/04/05/06a-c/07
  DONE. **The controller suite is RED on main** (the CTR-04 mock regression above) — fixing it is part of this
  ticket.

## Do NOT
- Do NOT add ANY `src/` contract or modify any contract — structure-2 is achievable on the as-built stack
  (resolved). If the cold-build finds a genuinely missing surface, STOP and log it as back-pressure (do not
  invent around it).
- Do NOT add a new token / rewrite `CREGatingHook` / change `ZipcodeOracleRegistry` / change `IZipcodeVenue`.
- Do NOT build the optional on-chain per-account qualification flag (off-chain non-filing + the LTV×mark backstop
  is the M1 gate).
- Do NOT `RT_CLOSE`/burn on repayment in the revolving tests (that makes it one-shot) — close only the repo line.
- Do NOT replace or modify `test/EulerVenueAdapter.t.sol` (green, out of scope).
- Do NOT build the CRE qualification/marking workflow (a CRE-track item; this proves the on-chain surface).
- Do NOT remove/weaken structure 1 — both coexist.

## Key requirements
1. **Zero contract change** — only `test/ZipcodeController.t.sol` + `docs/` change. `git diff --stat src/` is empty.
2. **Revolving reuses one slot/key** — Test 1: borrow→repay→redraw on the SAME open line / oracle key / EE slot,
   no new market.
3. **Per-revolution on-chain gate is LTV × mark** (not lapse) — Test 3.
4. **Repay + re-seeding redraw survive a mark lapse** — Test 4 (the corrected mechanism).
5. **Coexistence** — Test 5: a repo line (closes+burns, frees its CTR-04 slot) and a revolving line (persists)
   in one pool.
6. **Bounded keys** — Test 2: ONE persistent oracle key per revolving borrower vs n→∞ for repo.
7. **The CTR-04 regression is fixed** — the full `test/ZipcodeController.t.sol` suite is GREEN (the 6 prior
   failures resolved + the 5 new tests pass).

## Done when (gate — `forge test`, Base fork)
- `forge build` exit 0; `forge test --match-path test/ZipcodeController.t.sol` is **fully green** — the 28
  currently-passing + the 6 currently-failing (now fixed) + the 5 new revolving tests (= 39 total).
- `git diff --stat -- contracts/src` is empty (zero contract change).
- Cold-build returns ZERO load-bearing guesses (incl. the resolved "new token: NO" decision and the corrected
  disqualification mechanism).

## Depends on / unblocks
- **Depends on:** CTR-02/03 (routing), CTR-04 (the withdraw-queue reclaim the regression-fix mirrors). Composes
  with CTR-09 (per-revolution fee — revolving maximizes volume; still unbuilt).
- **Unblocks:** insurance-backed offerings once a policy exists; the volume-dependent revenue model (CTR-09).
