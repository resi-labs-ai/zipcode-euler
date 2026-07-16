# X-Ray — `LineAccount.sol` (single-contract, test-connected)

> LineAccount | 8 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(a hair from HARDENED — constructor-only; every effect proven)*

Per-contract X-Ray for `contracts/src/venue/LineAccount.sol`, the **per-line EVC borrower-of-record** (§4.4) —
an 8-nSLOC, **constructor-only** contract CREATE2-deployed by `EulerVenueAdapter.openLine` (salt = `lienId`). It does
exactly one thing, once, at birth: establish a fresh EVC owner-prefix and grant the adapter the EVC operator bit over
its own code-free borrow account, then go inert (the §4.4/§17 "graveyard"). No state, no admin, no teardown. Fully
exercised through `EulerVenueAdapter.t.sol` (Base fork) — every `openLine` mints a real one.

> The whole contract is a single constructor with a single external call (`EVC.setAccountOperator`). The interesting
> property is an **EVC mechanic, not arithmetic**: the borrow account is sub-account 1 of this contract's own prefix
> (`address(this) ^ 1`), chosen because it shares the 19-byte prefix (so the owner-self path can grant the operator)
> AND is **code-free** (a plain account address, not this coded contract's), so the EVC's
> non-owner-must-be-code-free guard (`EthereumVaultConnector.sol:787`) does not trip. Get that XOR wrong and either
> the grant reverts or the borrow path is unauthorized — so the test that pins all three facts is the load-bearing one.

## 1. What it is

A constructor-only contract. `constructor(evc_, operator_)`:
1. computes `borrowAccount = address(uint160(address(this)) ^ 1)` — sub-account 1 of its own prefix;
2. calls `IEVC(evc_).setAccountOperator(borrowAccount, operator_, true)` on the owner-self path — which registers this contract as the prefix owner and sets the operator bit for `operator_` (the adapter) over sub-account 1.

After construction it holds no code-reachable state and is never called again. The adapter passes
`operator_ = address(this)` (the adapter) so the adapter becomes the `EVC.call`/`EVC.batch` `msg.sender` authorized
to drive the borrow account at `draw`/`closeLine`.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `constructor(evc_, operator_)` | deploy (CREATE2, by `openLine`) | registers the prefix + grants the operator bit; the only code path |

No functions, no events, no storage, no admin, no fallback. There is nothing to call post-construction.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **LineAccount is the EVC prefix owner** of its borrow account | Yes | **`test_LineAccount_Mechanics`** (`evc.getAccountOwner(borrowAccount) == lineAccount`) |
| I-2 | **borrowAccount == lineAccount ^ 1** (sub-account 1, shared prefix) | Yes | **`test_LineAccount_Mechanics`** |
| I-3 | **borrowAccount is code-free** (so the EVC `:787` non-owner-code-free guard does not trip) | Yes | **`test_LineAccount_Mechanics`** (`borrowAccount.code.length == 0`) |
| I-4 | **the adapter is the granted operator** (before any draw) | Yes | **`test_LineAccount_Mechanics`** (`isAccountOperatorAuthorized(borrowAccount, adapter)`); the operator grant is what lets `draw`/`closeLine` act via `EVC.call`/`batch` |
| I-5 | **a foreign account did NOT grant the adapter** (isolation) | Yes | **`test_LineAccount_Mechanics`** + **`test_ForeignAccount_HookRejects`** |
| I-6 | **deterministic, distinct prefix per line** (CREATE2 salt = `lienId`) — two lines get distinct prefixes and both draw independently | Yes | **`test_TwoLine_DistinctPrefix_BothDraw_Isolation`** |
| I-7 | **salt collision reverts** — reusing a `lienId` reverts the CREATE2 deploy (one cluster per lien) | Yes | **`test_DoubleOpenLine_SameLienId_Reverts`** |

## 4. Guards — coverage

No explicit guards (no `require`/`revert` in the contract). The implicit guards are EVC-side and all exercised:
- the owner-self authorization path inside `setAccountOperator` (I-1/I-4),
- the EVC non-owner-must-be-code-free guard avoided by the `^ 1` code-free sub-account (I-3),
- CREATE2 salt-uniqueness (I-7, enforced by the EVM, surfaced by `openLine`).

## 5. Attack surfaces

- **None post-construction.** The contract is inert after birth — no functions, no state, no admin, no upgrade, no
  teardown. It cannot be re-entered, re-pointed, or drained; it holds nothing.
- **The single risk is constructor correctness, and it is fully pinned (I-1…I-4).** The `^ 1` sub-account choice is
  the load-bearing line: it must be both prefix-sharing (so the owner-self grant works) and code-free (so the EVC
  guard passes). `test_LineAccount_Mechanics` asserts the owner, the `^ 1` identity, the code-freeness, and the
  operator grant together — if any were wrong, either deploy would revert or the borrow path would be unauthorized.
- **Isolation is structural and tested (I-5/I-6).** Distinct CREATE2 prefixes per `lienId` mean one line's adapter
  grant cannot touch another line's account; the two-line both-draw test proves independence, and the foreign-account
  hook-rejection test proves a non-line account is rejected.
- **Inherent trust:** the EVC's `setAccountOperator` owner-self semantics + the `:787` code-free guard are upstream
  Euler mechanics (audited; relied on, not re-proven). The CREATE2 graveyard model (abandon the cluster at close) is
  intentional (§4.4/§17) — the inert account is never reclaimed, by design.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Mechanics (owner / `^1` / code-free / operator / foreign) | 1 | `test_LineAccount_Mechanics` — pins all four ctor facts + isolation |
| Distinct-prefix isolation + both-draw | 1 | `test_TwoLine_DistinctPrefix_BothDraw_Isolation` |
| CREATE2 salt collision | 1 | `test_DoubleOpenLine_SameLienId_Reverts` |
| Implicit (every `openLine` mints one) | many | the whole `EulerVenueAdapter.t.sol` fork suite deploys + drives real LineAccounts |

Coverage % uninstrumentable (project-wide `Stack too deep`); the contract's single constructor is exercised by every
fork test that opens a line, with its four birth-time facts directly asserted. No coverage gap — a constructor-only
contract has nothing else to test.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — a deliberately minimal, constructor-only EVC borrower-of-record whose every
birth-time effect is directly proven against the real EVC on a Base fork: it is the prefix owner, its borrow account
is the code-free `^ 1` sub-account, the adapter is the granted operator, foreign accounts are not, prefixes are
distinct per `lienId`, and a salt collision reverts. It has **no post-construction surface** — no state, admin,
upgrade, or value path — so there is nothing to harden beyond the constructor, and no coverage gap. Held below
HARDENED only by the inherent trust in the upstream EVC operator/code-free mechanics and the project-wide absence of
an external audit.

**Structural facts:**
1. 8 nSLOC; constructor-only; no functions, events, storage, admin, or teardown — inert after deploy.
2. CREATE2-deployed by `openLine` (salt = `lienId`); registers a fresh EVC prefix and grants the adapter the operator bit over the code-free `^ 1` borrow account.
3. The `^ 1` sub-account is both prefix-sharing (owner-self grant works) and code-free (avoids the EVC `:787` guard) — the single load-bearing design line.
4. All four birth-time facts + distinct-prefix isolation + salt-collision are directly asserted (`test_LineAccount_Mechanics`, `_TwoLine_DistinctPrefix_BothDraw_Isolation`, `_DoubleOpenLine_SameLienId_Reverts`).
5. Abandoned at close (the §4.4/§17 graveyard) — never reclaimed, by design; runtime safety of the borrow path lives in [EulerVenueAdapter.md](EulerVenueAdapter.md).
