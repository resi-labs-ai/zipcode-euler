# WOOF-03 — `CREGatingHook` (§4.3)

> **MATERIALIZED + BUILDS GREEN 2026-06-06 (keep-the-build doctrine).** Built from this ticket alone against the
> real WOOF-00/01/02 scaffold: `forge build` clean (solc 0.8.24) + **8/8 unit tests pass** (independently re-run;
> 56/56 across all suites, no regression). Code kept: `contracts/src/CREGatingHook.sol`,
> `contracts/test/CREGatingHook.t.sol`. The real build confirmed: the immutable is **`borrowDriver`** (not
> `controller`); the gate is `EVC.isAccountOperatorAuthorized(caller, borrowDriver)`; the custom error is
> **`NotAuthorizedOperator()` = `0x3d9adf1c`** (verified via `cast sig`); the isProxy-guarded assembly
> `_msgSender()` extraction is verbatim `BaseHookTarget`; and the **spoof-guard test passes** (a non-proxy caller
> appending an authorized account is rejected). Zero-spec-guess keepsake — every cited reference line accurate
> (EVC `:286`, `Base.sol` append, `Constants` OP_*, `GenericFactory.isProxy` `:185`, `IHookTarget` selector).

> **RE-AUTHORED 2026-06-05 (borrower-model rework, Step 2a).** The gate primitive changed:
> `EVC.haveCommonOwner(caller, controller)` (owner check) → **`EVC.isAccountOperatorAuthorized(caller, borrowDriver)`**
> (operator-authorization). Each line now borrows on a **fresh per-line EVC account** with its own owner-prefix
> (§4.4), with the **borrow-driver** wired as that account's **EVC operator** — so the borrow account does **not**
> share any controller prefix and `haveCommonOwner` is false for every line. **Everything else is unchanged**
> (inline `BaseHookTarget` replication, three ctor immutables, install at `OP_BORROW | OP_LIQUIDATE`,
> `isHookTarget()` proxy-guarded, the `isProxy`-guarded `_msgSender()` extraction, `OP_REPAY` never gated).
>
> **RECONCILED 2026-06-05 (borrow-driver fix, WOOF-04 seam).** The third immutable was named `controller` — a
> footgun: the address the hook must gate is the **EVC `call` caller** (the `EulerVenueAdapter`, which makes the
> `EVC.call(borrowVault, borrowAccount, …)` and is therefore the address EVC authenticates as the operator), **not**
> the controller contract. The controller drives origination through `IZipcodeVenue.draw`; the **adapter** is
> `EVC.call`'s `msg.sender`, so the per-line `LineAccount` grants the **adapter** the operator bit and the hook
> must gate the **adapter** (§4.4/§4.7). The immutable is now **`borrowDriver`** = the EVC operator = the
> `EVC.call` caller. In M1, the adapter may be collapsed into the controller (one address) — still correct, since
> the borrow-driver *is* that address. The gate is `EVC.isAccountOperatorAuthorized(caller, borrowDriver)`.

**Deliverable**
`contracts/src/CREGatingHook.sol` — `contract CREGatingHook is IHookTarget`. The EVK hook that makes the
**borrow-driver** (the venue adapter) — as the **EVC operator** of each line's fresh per-line borrow account — the
sole party able to `borrow`/`liquidate` on the lien markets; `repay` stays ungated.

**Spec §**
`claude-zipcode.md` §4.3 (the hook — operator-authorization gate). Cross: §4.4 (the borrower mechanism — a fresh
per-line EVC account, code-free, with the **borrow-driver / adapter** wired as its EVC operator via the per-line
`LineAccount`; the appended on-behalf caller is the borrow account, §4.4 "Caller semantics"), §4.4e/§10 (the
`OP_LIQUIDATE` gate is **defensive** — no on-chain economic liquidation).

**Model from**
`reference/evk-periphery/src/HookTarget/BaseHookTarget.sol` — **replicate its logic inline, do NOT inherit it**
(it lives in `evk-periphery`, which is **not** in WOOF-00's remap set, so an `import`/inheritance won't resolve;
copy its `isProxy`-guarded `_msgSender()` + factory check). · `reference/euler-vault-kit/src/interfaces/IHookTarget.sol`
(the interface to implement; selector `0x87439e04`) · the EVC **operator-authorization** check:
`reference/ethereum-vault-connector/src/EthereumVaultConnector.sol` —
`isAccountOperatorAuthorized(address account, address operator) external view returns (bool)` (`:286`), which
delegates to `isAccountOperatorAuthorizedInternal` (`:1205-1221`): it keys on the **account's** address-prefix
owner and returns `false` for an unregistered prefix (`:1213`), and otherwise checks
`operatorLookup[addressPrefix][operator]` (`:1220`) — so the gate clears **only** when `operator` equals the
exact address EVC authenticated as the `call` caller (the **adapter / borrow-driver**), never the controller (unless
M1 collapses them). For the calldata-append mechanics see
`reference/euler-vault-kit/src/EVault/shared/Base.sol`: `initOperation` sets `account = EVCAuthenticateDeferred(...)`
= the EVC **on-behalf account** (`:87`), passes it to `callHook(..., account)` (`:89`), and `invokeHookTarget`
appends that same 20-byte `account` to the calldata (`abi.encodePacked(msg.data, caller)`, `:132`) and **ignores
the hook's return data** (`:134` only reverts on failure). `OP_BORROW = 1 << 6`, `OP_REPAY = 1 << 7`,
`OP_LIQUIDATE = 1 << 11` (`reference/euler-vault-kit/src/EVault/shared/Constants.sol:38,39,43`); `OP_REPAY` is in
`CONTROLLER_NEUTRAL_OPS` (`:64`) — it is never hooked here. `GenericFactory.isProxy(address) external view returns
(bool)` (`reference/euler-vault-kit/src/GenericFactory/GenericFactory.sol:185`).

**Starting state**
- WOOF-00 done; `contracts/src/CREGatingHook.sol` is an empty stub (the WOOF-00 two-line header:
  `// SPDX-License-Identifier: GPL-2.0-or-later` + `pragma solidity 0.8.24;`).
- The `evc/` and `evk/` remaps resolve (verified, WOOF-00). No new remapping needed.

**Do NOT**
- **Do NOT use an EVC owner check** — `haveCommonOwner(caller, borrowDriver)` / `getAccountOwner(caller) == borrowDriver`
  / `caller == borrowDriver`. The borrow account is a **fresh per-line EVC account** with its **own** owner-prefix
  (§4.4), not a sub-account of the borrow-driver, so an owner check is **false for every line** — it would reject
  all borrows. The correct gate is **operator-authorization**: `EVC.isAccountOperatorAuthorized(caller, borrowDriver)`.
- **Do NOT name the third immutable `controller` or wire it to the controller contract.** The address the hook
  gates is the **EVC `call` caller** = the venue adapter (`EulerVenueAdapter`), the address EVC authenticates as
  the operator. The controller drives the borrow **through** `IZipcodeVenue.draw`, so the EVC sees the **adapter**
  as `msg.sender`, and the per-line `LineAccount` grants the **adapter** the operator bit (§4.4/§4.7). Wiring this
  immutable to the controller contract (when distinct from the adapter) makes the hook **reject every borrow**.
  Name it **`borrowDriver`** and wire it to the **adapter** address at deploy. (In M1 the adapter may be the
  controller — same address — still correct.)
- **Do NOT gate `OP_REPAY`** — repay is deliberately permissionless (it only reduces the receiver's debt;
  `Borrowing.repay` runs `initOperation(OP_REPAY, CHECKACCOUNT_NONE)`, `OP_REPAY ∈ CONTROLLER_NEUTRAL_OPS`). The
  hook code is op-agnostic; `OP_REPAY` is simply never in the installed `hookedOps`.
- **Do NOT** put this in the portable core — it is **internal to the Euler venue adapter** (§4.3 venue boundary).
- Do not `setHookConfig` here — installing the hook on the market is the deploy/wiring ticket's job (audit/2.md S9).
- **Do NOT inherit `BaseHookTarget`** (not remapped — see Model from) and **do NOT extract the appended caller
  unconditionally** — the extraction must be gated on `isProxy(msg.sender)` or it is spoofable (a non-proxy EOA
  could append a fake authorized account; see Key requirements).

**Key requirements**
- **Three `immutable`s set in the constructor: the EVK `GenericFactory` (vault factory), the EVC, and the
  `borrowDriver`** (the EVC operator / the address that drives the `borrow` via `EVC.call` — the venue adapter).
  The factory is required — both `isHookTarget` and the caller-extraction guard check
  `factory.isProxy(msg.sender)`; listing only EVC+borrowDriver yields an `isHookTarget` that can't validate the
  vault. Suggested ctor: `constructor(address eVaultFactory, address evc, address borrowDriver)`. Type the EVC
  immutable as a minimal local `IEVC`-style interface exposing **only** `isAccountOperatorAuthorized(address
  account, address operator) external view returns (bool)` (avoids importing the full EVC type; `evc/` does
  resolve if the full import is preferred — either is fine, but a local minimal interface is simplest and pins the
  exact selector). The factory may be typed as the local minimal interface exposing `isProxy(address) returns
  (bool)` or imported via `evk/GenericFactory/GenericFactory.sol`. **Wiring note:** `borrowDriver` is the
  **adapter** address; if the adapter address isn't known when the hook is deployed (circular immutables),
  precompute it (CREATE2) or use a two-pass deploy — the deploy/wiring ticket owns this (audit/2.md S5/S6).
- **Implement `IHookTarget`** (replicate the interface inline OR import `evk/interfaces/IHookTarget.sol` — the
  `evk/` remap resolves; importing the canonical interface is cleanest and pins the `0x87439e04` selector).
- `isHookTarget() external view returns (bytes4)` — return `IHookTarget.isHookTarget.selector` (`0x87439e04`)
  **only when `factory.isProxy(msg.sender)`**; otherwise return `0` (model `BaseHookTarget` `:26-29`).
- **Guarded caller extraction (`_msgSender()`):** trust the appended 20 bytes **only if `msg.sender` is a factory
  proxy** — `if (!factory.isProxy(msg.sender)) return msg.sender;` then
  `assembly { msgSender := shr(96, calldataload(sub(calldatasize(), 20))) }` (verbatim `BaseHookTarget` `:35-41`).
- `fallback() external` — the **only** gate: extract `caller = _msgSender()`; **revert unless
  `EVC.isAccountOperatorAuthorized(caller, borrowDriver)`**. The `caller` is the EVC **on-behalf borrow account**
  (the per-line account) and is the `account` arg; the immutable `borrowDriver` is the `operator` arg. Revert with
  a **named custom error** (so the EVK surfaces it as the harness's `HookReverted`, audit/2.md N1) — name it so it
  does **not** imply the controller specifically (e.g. `NotAuthorizedOperator`); return **no data** (the EVK
  ignores the hook's return data on success, `Base.sol:134` — only the revert matters). A bare `fallback() external`
  (no `payable`) is correct: the EVK calls the hook with no value.
- The gate is **op-agnostic** — it authorizes the appended on-behalf account regardless of which hooked op
  (`OP_BORROW` or `OP_LIQUIDATE`) invoked it. Gating scope (`OP_BORROW | OP_LIQUIDATE`) is set at **install** time
  by the deploy/wiring ticket (S9), not in this contract. `OP_REPAY` is never hooked.

**Done when**
- **Unit (Foundry, `contracts/test/CREGatingHook.t.sol`):** deploy with a **mock `GenericFactory`** whose
  `isProxy` returns `true` for the test vault address (required — else `isHookTarget` returns `0x0` and (a)
  fails), and a **mock EVC** whose `isAccountOperatorAuthorized(account, operator)` returns a per-(account,operator)
  bool the test sets (it mirrors the real predicate: an account is authorized iff its per-line owner granted the
  **borrowDriver** the operator bit). Then, **calling as the proxy** (i.e. from the mock-proxy address, with the
  appended 20-byte on-behalf account):
  (a) `isHookTarget()` returns `0x87439e04` when called by the proxy; returns `0x0` when called by a non-proxy.
  (b) `fallback` with an appended account that **has** the borrowDriver authorized as operator (`isAccountOperatorAuthorized
      == true`) **passes** (no revert) — this is a line's fresh borrow account.
  (c) `fallback` with an appended account that does **not** have the borrowDriver as operator (`== false`)
      **reverts** with the named custom error — an external/foreign account (the N1/N1b case).
  (d) **`isProxy`-guard:** a **non-proxy** `msg.sender` calling `fallback` with an appended *authorized* account is
      **rejected** — because `_msgSender()` falls back to `msg.sender` (the non-proxy EOA), which is **not**
      operator-authorized → reverts. This proves the appended-caller cannot be spoofed by a direct (non-vault)
      caller. (Wire the mock EVC so the non-proxy `msg.sender` returns `false` and the spoofed appended account
      returns `true`; the revert confirms the guard used `msg.sender`, not the appended bytes.)
  (e) **Repay stays permissionless (not gated):** assert by construction — the hook is op-agnostic and `OP_REPAY`
      is never in the installed `hookedOps` (the contract has no op branch); document that the deploy installs
      only `OP_BORROW | OP_LIQUIDATE`, so `repay` never reaches this hook. (No on-chain assertion needed beyond
      confirming the contract contains no `OP_REPAY` handling and the gate is uniform across ops.)
- **Acceptance (maps to the existing harness, re-authored gate):** satisfies `audit/2.md` **N1** (external EOA
  `borrow` → `HookReverted`, `isAccountOperatorAuthorized(EOA_X, borrowDriver) == false`) and **N1b** (external
  `liquidate` on an interest-underwater line → `HookReverted`), and lets **L4** succeed (the line's fresh borrow
  account, operator-authorized to the borrowDriver, passes the hook). Authority rows it realizes:
  `audit/3-results.md` **row 9** (borrow, operator-auth check, `:286`) + **row 10** (liquidate, same hook).
- `forge build` green; the new test passes.

**Depends on**
WOOF-00 (scaffold + `evc/`/`evk/` remaps). The live install + end-to-end N1/N1b/L4 also need the deploy/wiring
ticket, a market, and the per-line `LineAccount`/operator grant from WOOF-04 — but the **contract + its unit test
are completable and provable in isolation** with a mock `GenericFactory` + a mock EVC (`isAccountOperatorAuthorized`).
