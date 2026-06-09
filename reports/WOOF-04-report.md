# WOOF-04 — `IZipcodeVenue` + `EulerVenueAdapter` + `LineAccount` — MATERIALIZED + BUILT-VERIFIED 2026-06-06

**Status: BUILT-VERIFIED (keep-the-build).** The contracts are committed on disk and proven for real — not a
prose audit. Supersedes the prior re-author cold-build report (that byproduct was discarded under the old
doctrine; this is the kept-code verdict).

## TL;DR
Materialized the densest item in the build set from the ticket alone against the live WOOF-00 scaffold, and got
it green for real:
- `contracts/src/venue/IZipcodeVenue.sol` — the venue-neutral seam (7 methods + 5 events; no Euler types cross it).
- `contracts/src/venue/LineAccount.sol` — the constructor-only per-line EVC owner (CREATE2'd; grants the adapter
  the operator bit over its code-free `address(this)^1` borrow account).
- `contracts/src/venue/EulerVenueAdapter.sol` — `is IZipcodeVenue`; the per-line isolated-market factory.
- `contracts/test/EulerVenueAdapter.t.sol` — 20 tests, live Base-mainnet fork.

`forge build` clean (solc 0.8.24). **`forge test --fork-url $BASE_RPC_URL` = 76/76** (8+14+34 prior + 20 new),
independently re-run by the superintendent. EVK/EVC/EulerRouter are LIVE; `EulerEarn` is MOCKED (it pins solc
0.8.26 → cannot `new` under 0.8.24 — the adapter imports only `IEulerEarn`).

## What it did (the on-chain-verified facts)
The ticket flagged the load-bearing details; every one was re-derived from `reference/` and proven live:
- **AmountCap encode = `(mantissa<<6)|exponent`, round UP, raw `cap==0` → `ZeroCap`.** Verified against
  `reference/euler-vault-kit/src/EVault/shared/types/AmountCap.sol:18-28` (decode `10**(raw&63)*(raw>>6)/100`,
  raw-0 = `type(uint256).max` = unlimited). Round-trip test reads the cap back via the real `EVault.caps()` for
  {1, 1023, 100k, 1e18, 250k}; realized cap is always >= requested. **Live-fork.**
- **`collateralAmount != 1e18` → `InvalidCollateralAmount`.** Both `0` and a partial (`0.3e18`) revert; `1e18`
  succeeds (escrow asset == lien). The 1/1-primitive guard the §4.4c reclaim-1e18-before-burn depends on.
  **Live-fork.**
- **`LineAccount` operator grant.** After `openLine`: `isAccountOperatorAuthorized(borrowAccount, address(adapter))
  == true`, `getAccountOwner(borrowAccount) == address(lineAccount)`, `borrowAccount == address(lineAccount)^1`,
  `borrowAccount.code.length == 0`. Verified the EVC owner-self path mechanics: `setAccountOperator:364`,
  prefix-owner registration `:772-774`, code-free guard `:787`, bitMask `1<<(owner^account)` `:387`. **Live-fork.**
- **Two-line distinct-prefix BOTH-draw isolation** (the headline test, replacing the retired per-`subId` test):
  two distinct liens -> distinct `LineAccount`s/`borrowAccount`s/owner-prefixes/routers/escrows/borrow-vaults; each
  router resolves `COLLAT -> its own lien -> registry`; cross-resolve negative; **A draws 100k, B draws 150k via
  real `evc.batch` borrows**, `debtOf(borrowAccount_A)==100k` and `debtOf(borrowAccount_B)==150k` each unaffected
  by the other; re-marking B leaves A's quote + debt byte-for-byte unchanged. **Live-fork.**
- **`draw` batch encoding.** Self-calls (enableController/enableCollateral) carry `target=address(evc)`,
  `onBehalf=0`, `value=0`; the borrow item carries `target=lineRef`, `onBehalf=borrowAccount`,
  `abi.encodeCall(IBorrowing.borrow, (amount, erebor))`. Verified self-call constraints `:888-895` + operator auth
  `:903` + `BatchItem` struct `:12-23`; `receiver != erebor` -> `BadReceiver`. **Live-fork.**
- **Per-line router wired + frozen.** `govSetResolvedVault(COLLAT,true)` -> `govSetConfig(lien, usdc, registry)` ->
  birth-time `WireMismatch` check via `resolveOracle` -> `transferGovernance(0)`. Post-freeze
  `governor()==address(0)` and `govSetConfig` reverts. **Live-fork.** (`EulerRouter` ctor `:47` / `govSet*`
  `:56,:69` / `resolveOracle` `:123` all confirmed.)
- **Close / reclaim.** `LineNotRepaid` while debt>0; at debt==0 the operator-routed `evc.call(COLLAT,
  borrowAccount, 0, redeem(shares, controller, borrowAccount))` (4-arg `call:553`) returns the full `1e18` lien to
  the controller; `open=false` but `observeDebt` stays readable (==0) post-close. **Live-fork.**
- **Foreign-account hook rejection.** An un-granted account's borrow on a line's vault reverts (the re-authored
  WOOF-03 hook wired `controller = address(adapter)`). **Live-fork.**
- **Authority + F3.** Every mutating method reverts `NotController` from a non-controller; `liquidate` ->
  `NotImplemented`; unknown `lineRef` -> `UnknownLine`; double-`openLine` same `lienId` reverts (CREATE2
  collision); `openLine` `submitCap`s ONLY its own freshly-minted EVAULT (F3 bound) + rebuilds the supply queue
  preserving the head. (`fund`'s two-item ABSOLUTE allocation read via `convertToAssets(balanceOf(EE))` is
  **mock-level** — the recording `IEulerEarn` mock; the live EE path is audit S9/L4.)

## Decisions to sanity-check (none reopen a locked decision)
- **EulerEarn mocked** in the unit test (forced by its 0.8.26 pragma; the ticket mandates this). The two-item
  `fund` allocation + the F3 onboarding bound are therefore mock-level — confirmed by reading the recording mock's
  captured args. The live EE integration is the deploy/wiring ticket (audit S9/L4).
- **`liquidate` is `view`** (always reverts `NotImplemented`). Implementing a non-view interface method as `view`
  is legal (narrower mutability) and compiles; functionally identical.

## Holes the build surfaced -> resolution
- **`submitCap` cap-seed under-spec (mild ticket gap -> fixed in the ticket).** The ticket wrote `submitCap(EVAULT,
  capSeed)` without defining `capSeed`. Materialized as `type(uint136).max` (the EE cap field width); mock-level,
  the real bound is per-line `setCaps`/§9 governance. Clarifying note folded into ticket step 4.
- **Test IRM (not a gap).** The ctor takes `irm_` but the ticket names no concrete test IRM; built a minimal
  `ZeroIRM` (`IIRM` face, zero-rate) — a §9 deploy concern, the ticket already defers the production IRM there.
- **Hook<->adapter deploy cycle (already-tracked obligation, now confirmed).** The adapter ctor needs the hook
  address while the hook's `borrowDriver` must equal the adapter — a deploy circularity resolved in-test via
  `vm.computeCreateAddress`. This is the **existing item-10 / WOOF-03 obligation** ("precompute `VENUE` via CREATE2
  or two-pass deploy, then assert the deployed adapter == the address wired into the hook"); the build empirically
  confirms address-prediction is the forced path (the ticket forbids a settable hook method).

## Doc edits (this window)
Ticket banner + step-4 cap-seed clarification; this report (rewritten to the materialization verdict);
`reports/README.md` row; `tickets/LEDGER.md` WOOF-04 digest; `tickets/PROGRESS.md` (status BUILT-VERIFIED +
discharged obligation + session log); root `README.md` checkbox; `superintendent-auditor.md` CURRENT STATE +
worklist. **No `claude-zipcode.md` edit** — the build exposed no spec error (every cited signature/address was
already correct; the §17 borrower-model + venue decisions hold). **No `BaseAddresses.sol` edit** — no wrong
address surfaced (the live fork stand-up uses the WOOF-00-verified EVC/`EVAULT_FACTORY`, transitively re-proven
by the green fork borrows).

## Status + NEXT
**WOOF-04 = BUILT-VERIFIED.** Discharges the item-5 inbound obligation ("register `LIEN_i` as collateral via
`setLTV`/market wiring", owed to WOOF-01) — `setLineLimits` calls `setLTV(COLLAT, …)`, asserted live.
**NEXT in the build-verification worklist = WOOF-05 (`ZipcodeController`)** — 5-arg ctor, no EVC, `_processReport`
dispatch; materialize + fork-test against the now-real WOOF-04 venue on disk.
