# WOOF-03 — `CREGatingHook` (§4.3) — report to the superintendent

> **UPDATE 2026-06-06 — MATERIALIZED + BUILT-VERIFIED (keep-the-build doctrine).** Built for real from the ticket
> alone against the WOOF-00/01/02 scaffold and **kept on disk** (the "`contracts/` at skeleton" line below is
> retired). **Evidence:** `forge build` clean (solc 0.8.24) + **`forge test` 8/8 PASS** (independently re-run, exit
> 0; 56/56 across all suites, no regression). Confirmed with eyes on output: operator-auth gate on `borrowDriver`
> (not an owner check), error `NotAuthorizedOperator()` = `0x3d9adf1c`, and the isProxy **spoof-guard** rejects a
> non-proxy caller appending an authorized account. No wrong citation — zero-spec-guess keepsake. Code at
> `contracts/src/CREGatingHook.sol` + `contracts/test/CREGatingHook.t.sol`. The 2026-06-05 narrative below is
> preserved for the design rationale.

**Item:** 4 — `CREGatingHook`. **Final state, consolidated** (this single report replaces the former separate
rebuild + reconcile reports). **Date:** 2026-06-05 (authoring); **2026-06-06** (materialized + built).

## What WOOF-03 is (final)
The EVK `IHookTarget` hook that makes the **borrow-driver** (the `EulerVenueAdapter`) — as the EVC operator of each
line's fresh per-line borrow account — the **sole** party that can `borrow`/`liquidate` on the lien markets;
`repay` stays permissionless. Installed at `OP_BORROW | OP_LIQUIDATE`. The `OP_LIQUIDATE` gate is purely defensive
(no on-chain economic liquidation in M1).

## The gate (the load-bearing part)
`fallback()` extracts the appended 20-byte on-behalf caller (the per-line borrow account) and reverts unless
**`EVC.isAccountOperatorAuthorized(caller, borrowDriver)`** — an operator-authorization check, NOT an owner check.
`borrowDriver` is the third ctor immutable and is the **adapter** (the `EVC.call(borrowVault, borrowAccount, …)`
caller; == controller only if M1 collapses them). Ctor `(address eVaultFactory, address evc, address borrowDriver)`.

Two corrections got it here (history, compressed — this is why it looks as it does):
1. **Borrower-model re-author (was Step 2a):** gate `haveCommonOwner(caller, controller)` (owner check) →
   `isAccountOperatorAuthorized`. Each line borrows on a fresh per-line account (own prefix), so an owner check is
   **false for every line**; operator-auth is the venue-neutral invariant.
2. **borrowDriver reconcile:** the EVC authenticates the **adapter** (the `EVC.call` caller) as the operator, not
   the controller — so the gated immutable was renamed `controller` → `borrowDriver` and wired to the adapter.
   Naming it `controller` / wiring it to the controller contract would reject **every** borrow (the footgun this fixed).

## Preserved unchanged (from the pre-borrower-model keepsake)
Inline `BaseHookTarget` replication (evk-periphery is not remapped); `isProxy`-guarded `isHookTarget()` →
`0x87439e04`; `isProxy`-guarded `_msgSender()` (`shr(96, calldataload(sub(calldatasize(),20)))`); `OP_REPAY` never
hooked; named custom error surfaced by the EVK as `HookReverted` (returns no data).

## EVC verification (inspected against `reference/`, not cited)
`reference/ethereum-vault-connector/src/EthereumVaultConnector.sol`:
- `isAccountOperatorAuthorized(account, operator)` `:286` → `isAccountOperatorAuthorizedInternal` `:1205-1221`:
  keys on the **account's** prefix-owner (`:1209-1210`), fails closed for an unregistered prefix (`:1213`),
  returns `operatorLookup[addressPrefix][operator] & bitMask != 0` (`:1218-1220`). So the gate clears ONLY when
  `operator` == the exact `EVC.call` caller = the **adapter**.
- Appended caller = the EVC on-behalf account: `reference/euler-vault-kit/src/EVault/shared/Base.sol` —
  `initOperation` → `callHook(…, account)` (`:87`/`:89`); `invokeHookTarget` appends the 20-byte account (`:132`)
  and ignores the hook's return on success (`:134`) → the hook need return nothing.
- `BaseHookTarget` shape `reference/evk-periphery/src/HookTarget/BaseHookTarget.sol:12-42`; `IHookTarget` selector
  `0x87439e04`.
- Ops `reference/euler-vault-kit/src/EVault/shared/Constants.sol`: `OP_BORROW=1<<6`, `OP_REPAY=1<<7`
  (∈ `CONTROLLER_NEUTRAL_OPS` → never gated), `OP_LIQUIDATE=1<<11`; `GenericFactory.isProxy` (`:185`).

## Cold-build (final, from the ticket alone, real forge)
`forge build` clean; `forge test` **6/6 PASS**: `isHookTarget` proxy-only (`0x87439e04` / `0x0`); an authorized
line account passes; a foreign account → named revert **`NotAuthorizedOperator()` = `0x3d9adf1c`**; non-proxy spoof
rejected (the `isProxy`-guard fell back to `msg.sender`, not the spoofed appended bytes); the `borrowDriver()`
getter pins the wired address; the gate is op-agnostic and `repay` is never hooked. **Zero load-bearing guesses.**
Byproduct discarded; `contracts/` back to the bare `.gitkeep` skeleton.

## Authoritative-doc state
- `claude-zipcode.md` §4.3 gates on `isAccountOperatorAuthorized(caller, borrowDriver)` (borrowDriver = the
  adapter; == controller only if M1 collapses them) + the §4.4 cross-ref. No re-author spec edit was needed
  (§4.3/§4.4 already specified operator-auth from the borrower-model Step-1 spec surgery); the reconcile adjusted
  the §4.3 gate expression + the cross-ref naming.
- `audit/2.md` (S5 ctor / L4 post / N1 / N1b) + `audit/3-results.md` (access-control preamble, row 9, Trace-A hop
  9/10, attack table) swept to the operator-auth gate on the **adapter** (`:286`; `LINE_BORROW_ACCOUNT`; `VENUE`
  as the gated operator).
- `tickets/woof/WOOF-03-cre-gating-hook.md` is the keepsake (ctor `(eVaultFactory, evc, borrowDriver)`, Do-NOT
  forbids naming it `controller`, 6-case unit-test spec).

## Cross-ticket
The live operator grant on each line is **WOOF-04**'s `openLine`/`LineAccount`
(`setAccountOperator(borrowAccount, adapter, true)`). **Deploy/wiring (item 10)** must wire the hook's
`borrowDriver` to the **adapter** address — circular with the hook-before-adapter order → precompute (CREATE2) or
two-pass, and assert the deployed adapter == the wired address before installing the hook.

## Status
WOOF-03 DONE (re-authored + reconciled); cold-build 6/6; consistent across spec / audit / ticket. The contract +
its unit test are provable in isolation with a mock `GenericFactory` + mock EVC.
