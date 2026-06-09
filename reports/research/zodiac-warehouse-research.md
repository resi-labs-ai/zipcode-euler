# Zodiac research — the CreditWarehouse admin module (A purpose-built vs B Roles Modifier)

**For:** the 8-Bw build ticket (`CreditWarehouse` = a Gnosis Safe holding the EulerEarn shares, administered by a
CRE bot on a fixed op-set). **Method:** 7 per-repo subagents over the freshly-cloned Gnosis Guild repos
(`reference/zodiac-core|modifier-roles|guard-scope|module-reality|safe-app|wiki`, `permissions-starter-kit`) +
1 web/audit pass. **Date:** 2026-06-06. Citations are file:line in `reference/` or URLs.

## The load-bearing hard truth (reframes the whole decision)
**No external guard can contain an enabled module — the scoping MUST live inside the enabled contract's own
bytecode, for BOTH options A and B.**
- A Safe **Transaction Guard** (`setGuard`) hooks **only** the owner `execTransaction` path. Module-initiated
  txs were **not** guard-covered until Safe **v1.5.0**, which added a *separate* **Module Guard**
  (`setModuleGuard`) — new, and its own audited component. (Safe docs; safefoundation 1.5.0 post.)
- Zodiac's `GuardableModule` is **voluntary self-policing** — the module calls the guard itself inside `exec`
  (`reference/zodiac-core/contracts/core/GuardableModule.sol:24-46`); a module that doesn't extend it simply
  never calls a guard. Not a containment boundary.
- The **Scope Guard** (`zodiac-guard-scope/contracts/ScopeGuard.sol`) only implements the legacy owner-path
  `checkTransaction`, only scopes target+selector (no params), and **cannot restrict a module** — wrong tool.
- => "we'll bolt a guard on to constrain the CRE module" does **not** work pre-1.5.0. Whatever we enable
  (custom module OR Roles) holds full signature-free Safe authority; its own code is the entire boundary.

## Option B — Zodiac Roles Modifier v2 (`zodiac-modifier-roles`)
- A **Modifier** enabled on the Safe; the caller calls `execTransactionWithRole(to,value,data,op,roleKey,
  shouldRevert)` (`Roles.sol:153`), it validates, then forwards via `execTransactionFromModule`.
- **Expresses every constraint we need:** target allow-list, selector scope, **per-parameter conditions**
  (`scopeFunction` + a `ConditionFlat[]` tree, `PermissionBuilder.sol:133`) — e.g. pin `redeem.receiver ==
  fixedSink` (`EqualTo`), `transfer.to == fixedLoanbook`, `deposit.receiver == EqualToAvatar` (the Safe);
  **Call-only** via `ExecutionOptions=None` (rejects delegatecall + value, `PermissionChecker.sol:187-211`);
  optional `WithinAllowance` rate-limits. The CRE caller is just an address `assignRoles`'d as a member — an
  immutable contract is fine.
- **Audited** (G0 + Omniscia) and **production-canonical** for exactly our shape: ENS DAO (EP 5.12), GnosisDAO,
  Balancer, **karpatkey** run scoped keeper/treasury automation on it. The wiki's marquee pattern
  *"Trustless Delegation with Scoped Permissions"* is a near-verbatim description of our setup and names
  karpatkey-on-Roles as the reference implementation.
- **`permissions-starter-kit`** makes the policy ~15 lines of declarative TS (`allow.<chain>.<contract>.<fn>({
    receiver: c.avatar, to: <const> })`), applied as an owner-signed on-chain diff. Call-only is the default.
- **Costs:** (1) safety = **configuration, not code** — the "never arbitrary outbound" invariant lives in a
  mutable owner-gated condition tree, not bytecode (misconfig is the real, recurring failure mode — why ENS
  does policy reviews); (2) a **CRE-boundary adapter** is needed — Roles expects pre-formed Safe calldata, so
  the Forwarder→onReport handler must ABI-encode the 3 calls and call `execTransactionWithRole` (extra layer).

## Option A — purpose-built custom module (`zodiac-core` base `Module`)
- Subclass `Module` (~80-100 lines): immutable `EE_POOL`/`USDC`/`SINK`/`LOANBOOK`, three `onlyForwarder`
  functions each hardcoding `to` + selector + `Operation.Call`, using `execAndReturnData` for the ERC4626
  returns (`Module.sol:43,59`). Model the `setUp`/init from `TestModule.sol:57`; the module IS the CRE receiver
  (cleanest Forwarder composition — `msg.sender==FORWARDER`).
- **Safety = code, not config:** the 3 ops + fixed targets are a **bytecode invariant**, provable by reading
  ~50 lines; no scope tree to misconfigure, no delegatecall/value surface to remember to zero.
- **Cost (the honest one):** it is **bespoke, unaudited code guarding ALL senior backing.** One bug (wrong
  receiver/owner arg, a missed `Operation.Call`, an approval/reentrancy hole) is catastrophic with no prior
  auditor's eyes. A is only "stronger" **if we fund a dedicated audit + fuzz/invariant tests** of the module.
- **Model from `zodiac-core` (v4.0.0)**, NOT the older `reference/zodiac` (v4.2.1, legacy: `Enum.Operation` +
  OZ `OwnableUpgradeable` + legacy guard interface). zodiac-core is the modern, OZ-decoupled core the current
  Roles build sits on, with the `IModuleGuard` model.

## The decision rule (it's a risk/audit-budget call, not a code call)
- **Choose B (Roles v2)** to lean on audited, production-proven scoping (ENS/Gnosis/Balancer/karpatkey) and
  write zero new audited Solidity — accepting policy-config risk + a small CRE-boundary encoding adapter. This
  is the documented-canonical path and the lower-risk default **for all-senior-backing value unless we audit A.**
- **Choose A (custom module)** for the smallest attack surface + "never arbitrary outbound" as a bytecode
  invariant + cleanest CRE composition — **only if we commit to a dedicated module audit.**
- **Either way:** do NOT rely on a Transaction Guard to scope the module. Optional defense-in-depth = Safe
  1.5.0 + a Module Guard, and/or a **Delay Modifier** behind the admin so the owner can cancel a compromised-CRE
  action within a cooldown window.

## Verification flags to close in the 8-Bw ticket (apply to A and B)
1. **EulerEarn `redeem` arg order.** Verify `redeem(shares, receiver, owner)` against `reference/euler-earn`:
   in our op-set is USDC meant to land in the **Safe** (receiver==SAFE, then opType-3 transfers out) or go
   **directly** to the SINK (receiver==SINK)? The spec's `redeem(shares, SINK, SAFE)` assumes receiver=SINK,
   owner=SAFE — confirm that's intended (it bypasses the Safe) and that owner=SAFE (the share holder) is right.
2. **Deposit approval.** `EE_POOL.deposit(amount, SAFE)` pulls USDC from the Safe → the Safe needs a standing
   `USDC.approve(EE_POOL)`. That's a 4th selector to scope (B) / hardcode (A) — currently missing from the 3-op
   set. Decide standing-infinite vs exact-amount approve.
3. **Exact amounts from the CRE report**, never recompute shares off a live (accruing) EulerEarn price.
4. (B only) confirm Roles v2 G0/Omniscia report dates from `packages/evm/docs` before citing.

## Canonical deploy/enable sequence (from zodiac-safe-app, either option)
`deployAndSetUpModule(...)` → `Safe.enableModule(moduleAddr)` (owner tx) → configure (B: apply the role policy
via permissions-starter-kit, owner-signed diff; A: nothing — ops are in bytecode).
