# WOOF-03 — CREGatingHook (wiring map)

> Source of truth = `contracts/src/CREGatingHook.sol` (the kept, final form). Ticket
> `tickets/woof/WOOF-03-cre-gating-hook.md` + report `reports/WOOF-03-report.md` + spec §4.3 are intent.
> Where prose and code disagree, the code wins — every claim below was read off the `.sol`.

## Role
The EVK `IHookTarget` hook (§4.3) that makes the **borrow-driver** (the `EulerVenueAdapter`) — as the EVC
**operator** of each line's fresh per-line borrow account — the **sole** party able to `borrow`/`liquidate` on
the lien markets. It is installed on the per-line USDC borrow vault at `OP_BORROW | OP_LIQUIDATE`; `repay` is
never in `hookedOps`, so it stays permissionless. The gate is **operator-authorization**, not an owner check:
each line borrows on a fresh EVC account with its own owner-prefix (§4.4) that has granted the adapter the
operator bit, so a `haveCommonOwner` check would be false for every line. The hook is **internal to the Euler
venue adapter** (§4.3 venue boundary) — not part of the portable core; another venue enforces the same
"controller is the sole borrower-of-record" invariant behind `IZipcodeVenue` its own way.

## Contracts involved (what each does)
| Contract / file | What it does |
|---|---|
| `CREGatingHook` (`is IHookTarget`) | The hook. `isHookTarget()` returns the magic selector only to a recognized vault; `fallback()` gates every hooked op on `EVC.isAccountOperatorAuthorized(caller, borrowDriver)`; `_msgSender()` extracts the EVK-appended on-behalf account behind an `isProxy` spoof-guard. Op-agnostic. |
| `IGenericFactory` (local iface, in-file) | Minimal view of the EVK `GenericFactory` — only `isProxy(address) returns (bool)`. Used to (a) validate the `isHookTarget` caller is a vault and (b) decide whether to trust the appended caller bytes. |
| `IEVC` (local iface, in-file) | Minimal view of the EVC — only `isAccountOperatorAuthorized(address account, address operator) returns (bool)`, pinning that exact selector. The single predicate the gate evaluates. |
| `IHookTarget` (`evk/interfaces/IHookTarget.sol`, imported) | The interface implemented; pins `isHookTarget()` selector `0x87439e04`. |

## Wiring — internal
**Constructor (the wiring entry point):**
```
constructor(address eVaultFactory_, address evc_, address borrowDriver_)
```
sets `eVaultFactory`, `evc`, `borrowDriver` from the three args, then `owner = msg.sender` and emits
`OwnershipTransferred(address(0), msg.sender)`.

**Wiring fields — Timelock-SETTABLE, not immutable** (build-phase posture, §17 note in the source header at
line 28: "wiring below is Timelock-settable, NOT immutable — build-phase flexibility. Lock pre-prod"):
- `IGenericFactory public eVaultFactory` — the EVK vault factory; re-pointed by `setEVaultFactory(address)`.
- `IEVC public evc` — the Ethereum Vault Connector; re-pointed by `setEvc(address)`.
- `address public borrowDriver` — the EVC operator that drives the borrow; re-pointed by
  `setBorrowDriver(address)`. **NOT the controller** (see cross-component).
- `address public owner` — the build-phase admin (the Timelock). Re-pointed by `transferOwnership(address)`.

All three setters are `onlyOwner`, zero-guard with `if (... == address(0)) revert ZeroAddress()`, and emit
`WiringSet(bytes32 indexed slot, address value)` with the slot label as a `bytes32` string literal
(`"eVaultFactory"` / `"evc"` / `"borrowDriver"`). `transferOwnership` zero-guards and emits
`OwnershipTransferred`.

**Authority / gating:**
- `modifier onlyOwner` checks the **raw `msg.sender`** against `owner` (reverts `NotOwner()`) — deliberately
  NOT the hook's `_msgSender()` decoder (the admin call is never an EVK on-behalf call; see Gotchas).
- The op-gate lives in `fallback() external` (non-payable — the EVK invokes with no value):
  ```
  address caller = _msgSender();
  if (!evc.isAccountOperatorAuthorized(caller, borrowDriver)) revert NotAuthorizedOperator();
  ```
  Returns no data on success — the EVK ignores the hook's return on success and only the revert matters.
- `isHookTarget()` returns `this.isHookTarget.selector` (`0x87439e04`) **only when**
  `eVaultFactory.isProxy(msg.sender)`, else `0`.
- `_msgSender()` (internal view): `if (!eVaultFactory.isProxy(msg.sender)) return msg.sender;` then
  `assembly { msgSender := shr(96, calldataload(sub(calldatasize(), 20))) }` — verbatim
  `BaseHookTarget._msgSender()`, replicated inline because evk-periphery is not remapped.

**Key constants / selectors:**
- `IHookTarget.isHookTarget.selector == 0x87439e04` (the magic value).
- `NotAuthorizedOperator() == 0x3d9adf1c` (surfaced by the EVK as `HookReverted`; named so it does not imply
  the controller specifically). Other errors: `ZeroAddress()`, `NotOwner()`.
- `OP_BORROW = 1 << 6`, `OP_LIQUIDATE = 1 << 11`, `OP_REPAY = 1 << 7`. These are **NOT in this contract** —
  the gating scope is set at install time (`setHookConfig(hook, OP_BORROW | OP_LIQUIDATE)`) by the
  deploy/wiring ticket (item 10 / S9). `OP_REPAY ∈ CONTROLLER_NEUTRAL_OPS` and is never hooked. The hook
  code itself is op-agnostic — the same predicate applies regardless of which 4-byte selector prefixes the
  calldata.

**Events:** `WiringSet(bytes32 indexed slot, address value)`, `OwnershipTransferred(address indexed
previousOwner, address indexed newOwner)`.

## Wiring — cross-component (who points at whom)
- **`borrowDriver` → the VENUE adapter (`EulerVenueAdapter`), NOT the controller.** The address the hook gates
  is the `EVC.call(borrowVault, borrowAccount, …)` caller — the address EVC authenticates as the **operator**
  of the per-line account. The controller drives every venue effect **through** `IZipcodeVenue.draw`
  (§4.4/§4.7), so the EVC sees the **adapter** as `msg.sender`. Wiring `borrowDriver` to the controller
  contract (when distinct from the adapter) would make the hook reject **every** borrow (PROGRESS.md item-10
  obligation, line 312; §4.3 lines 304-319). In M1 the adapter may be collapsed into the controller — one
  address, `VENUE == ZIP_CONTROLLER` — still correct, because the borrow-driver *is* that address.
- **The gate predicate → `EVC.isAccountOperatorAuthorized(caller, borrowDriver)`**
  (`ethereum-vault-connector/src/EthereumVaultConnector.sol:286` → internal `:1205-1221`). `caller` is the
  appended EVC `onBehalfOfAccount` = the per-line **borrow account** (the `account` arg); `borrowDriver` is
  the **operator** arg. The internal keys on the account's address-prefix owner, fails closed for an
  unregistered prefix (`:1213`), and checks `operatorLookup[prefix][operator]` (`:1220`) — so the gate clears
  **only** when the line's owner granted the exact `borrowDriver` the operator bit.
- **The operator grant → WOOF-04's `LineAccount`.** At origination `EulerVenueAdapter.openLine` CREATE2-deploys
  a minimal per-line `LineAccount` (the fresh borrower account's owner) which calls
  `setAccountOperator(borrowAccount, adapter, true)` — granting the **adapter** (= `borrowDriver`) the operator
  bit over the code-free borrow account (§4.4, spec line 416). This is the state the hook reads through the EVC.
- **`eVaultFactory` → EVK `GenericFactory` (`EVAULT_FACTORY`).** Both the `isHookTarget` proxy check and the
  `_msgSender()` spoof-guard call `isProxy(msg.sender)` on this factory; it is the factory that minted the lien
  vaults.
- **`evc` → the EVC (`BaseAddresses.EVC`).** Queried for the one operator-authorization predicate.
- **Install (not in this contract): the per-line USDC borrow vault → this hook**, via
  `setHookConfig(hook, OP_BORROW | OP_LIQUIDATE)` at deploy/wiring. The `OP_LIQUIDATE` gate is purely
  **defensive** (block an external party from seizing an interest-underwater line; no on-chain economic
  liquidation in M1, §4.4e/§10).

## Item-10 deploy facts (the circular-immutable problem)
- **Ctor arg order:** `(address eVaultFactory_, address evc_, address borrowDriver_)`. `owner` is set to the
  deployer (`msg.sender`), then handed to the Timelock via `transferOwnership`.
- **The circular dependency (S5 before S6).** The hook is deployed at **S5**; the `EulerVenueAdapter` (=
  `borrowDriver` = `VENUE`) is deployed at **S6** — so the hook needs the adapter's address **before** the
  adapter exists. Resolution (deploy/wiring ticket owns this, PROGRESS.md line 312):
  1. **Precompute `VENUE` via CREATE2** and pass the predicted address into the hook ctor's `borrowDriver_`; OR
  2. **Two-pass deploy** — deploy the adapter first, then deploy the hook with the real address, then install.
  Because `borrowDriver` is now a **settable** field (not immutable), a third path exists: deploy the hook
  with a placeholder and `setBorrowDriver(VENUE)` once the adapter is live (build-phase posture).
- **Assert before installing:** the deployed `VENUE` (adapter) address MUST equal the address wired into the
  hook's `borrowDriver` **before** `setHookConfig` installs the hook on the market. A mismatch silently
  rejects every borrow.
- **Ownership posture:** manual `owner`, initialized to the deployer at construction, then
  `transferOwnership(TIMELOCK)`. No renounce (build-phase wiring stays Timelock-re-pointable per §17;
  re-freezing to immutable is deferred to the pre-prod lock-down). Nothing here renounces or self-destructs;
  there is no sweep/rescue/pause path.

## Gotchas
- **Manual owner, NOT OZ `Ownable`.** The hook deliberately does not inherit `Ownable`/`Context`: OZ's
  `Context._msgSender()` would collide with this hook's EVK trailing-data `_msgSender()` decoder. `onlyOwner`
  therefore checks `msg.sender` **directly** (§17 note, spec line 2371; same posture as `FarmUtilityBorrowGuard`).
- **`isProxy` spoof-guard.** `_msgSender()` trusts the appended 20 bytes **only** when
  `eVaultFactory.isProxy(msg.sender)`; otherwise it returns `msg.sender`. So a non-vault EOA that appends a
  fake authorized account is gated against its own (unauthorized) address and reverts — it cannot spoof an
  authorized borrow account (test `test_d_isProxyGuard_spoofRejected`).
- **Revert returns no data.** On success the fallback returns nothing; the EVK ignores hook return data on
  success (`Base.sol:134`) and only surfaces the revert (`NotAuthorizedOperator`) as `HookReverted`.
- **`repay` is never gated by code — only by install.** The contract has no op branch; it is install
  (`OP_BORROW | OP_LIQUIDATE`, never `OP_REPAY`) that keeps repay permissionless. Do not add an op branch.
- **Local minimal interfaces, not full imports.** `IEVC`/`IGenericFactory` are declared in-file to pin exact
  selectors and avoid pulling the full EVC/factory types; only `IHookTarget` is imported (from `evk/`).
- **0.8.24 pin.** `require(cond, CustomError())` is 0.8.26+; all guards here use `if (!cond) revert Err()`.
