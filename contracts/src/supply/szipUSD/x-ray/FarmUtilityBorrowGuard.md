# X-Ray — `FarmUtilityBorrowGuard.sol` (single-contract, test-connected)

> FarmUtilityBorrowGuard | 53 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/FarmUtilityBorrowGuard.sol`, the EVK hook target
(§4.3, security F8a) installed on the farm utility USDC borrow vault at `OP_BORROW`. **No dedicated test file** — its
two decisive security properties are exercised via its sibling `test/FarmUtilityLoopModule.t.sol` (the anti-spoof
`isHookTarget` + the account-identity borrow gate, the latter against the **real** EVK/EVC market). The
admin/wiring surface — previously the gap — is **now covered too**: 3 guard tests total.

> Why this guard matters: the farm utility borrow vault holds **≈0 at rest** and is **JIT-funded from the
> warehouse's shared resting USDC** (the `usdcReservoir` idle depositor cash) just before a harvest, via
> `EulerVenueAdapter.fundFarmUtility` (re-absorbed by `defundFarmUtility`; the "combined" always-funded topology was
> rejected). So while funded the vault holds depositor-sourced cash. Without this hook, any ICHI-LP holder could post
> the escrow collateral on their *own* EVC account and lever that depositor cash. The guard pins `OP_BORROW` to the
> engine Safe — so the test that a third party is rejected on its own account is the whole point, and it's proven on
> the live market.

## 1. What it is

An `IHookTarget` installed only on `OP_BORROW` of the farm utility USDC vault. A borrow is allowed **only when the
EVK-appended on-behalf account `== juniorTrancheEngine`** (else revert `NotEngineSafe`). The engine Safe borrows on
its own account (no operator, §4.5.1), so this is an **account-identity** gate, not operator-authorization — distinct
from `CREGatingHook` (which gates `isAccountOperatorAuthorized`). It replicates `BaseHookTarget`'s `isProxy`-guarded
`isHookTarget()` + `_msgSender()` calldata extraction inline (evk-periphery isn't remapped).

**A deliberate, security-relevant quirk:** `onlyOwner` checks the **raw `msg.sender`**, NOT the hook `_msgSender()`
decoder — because OZ `Ownable`'s `Context._msgSender()` would collide with the EVK trailing-data decoder. The admin
is never an EVK on-behalf call, so checking `msg.sender` directly is correct (and this is exactly the kind of choice
worth a test — see §5).

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `fallback()` | EVK (OP_BORROW hook) | the gate: `_msgSender() != juniorTrancheEngine` → `NotEngineSafe`; op-agnostic, no return data |
| `isHookTarget()` | view (EVK install check) | returns the magic selector **only** when `msg.sender` is a factory proxy (anti-spoof) |
| `transferOwnership(newOwner)` | `onlyOwner` (raw msg.sender) | build-phase admin → Timelock; zero-guard |
| `setEVaultFactory` / `setJuniorTrancheEngine` | `onlyOwner` (raw msg.sender) | build-phase wiring re-points; zero-guard |

No CRE operator, no value path. The only state is the wired factory + engine Safe + admin owner.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **OP_BORROW pinned to the engine Safe** — a borrow on any other on-behalf account reverts `NotEngineSafe` | Yes | **`test_third_party_borrow_blocked_by_guard`** — on the *real* EVK market: the engine Safe's loop borrow passes; a third party that deposits the same escrow on its OWN account and calls `EVC.call(borrow, …)` is rejected |
| I-2 | **`isHookTarget` anti-spoof** — magic selector only when the caller is a recognized factory proxy (a vault) | Yes | **`test_guard_isHookTarget_only_for_factory_proxy`** (non-proxy caller → `0`; real factory proxy → the selector) |
| I-3 | **`_msgSender` anti-spoof** — trusts the appended 20-byte on-behalf account only when `msg.sender` is a factory proxy; else returns raw `msg.sender` (a non-vault caller can't spoof an authorized account) | Yes | structural (replicated verbatim from `BaseHookTarget`); exercised by I-1 (real-vault path) + I-2 (the proxy branch); a *direct* non-vault `fallback()` call isn't separately tested |
| I-4 | **admin gate uses raw `msg.sender`** (not the EVK decoder) — a non-owner reverts `NotOwner`; the owner can transfer/re-point | Yes | **`test_guard_admin_onlyOwner_transfer_and_wiring`** — non-owner → `NotOwner` on all 3 admin fns; zero-guards; `setJuniorTrancheEngine`/`setEVaultFactory` effects; `transferOwnership` hands off + the old owner then loses the gate |
| X-1 | the guard only protects if **installed on `OP_BORROW`** of the farm utility vault, and `eVaultFactory` is the real factory | **No** | the hook install + factory wiring is deploy/config (out of this scope); `test_third_party_borrow_blocked_by_guard` deploys the market with the guard installed, evidencing the wiring end-to-end |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `NotEngineSafe` (the borrow gate) | `test_third_party_borrow_blocked_by_guard` (real EVK borrow path) |
| `isHookTarget` factory-proxy check | `test_guard_isHookTarget_only_for_factory_proxy` |
| `onlyOwner` / `NotOwner` (raw msg.sender) on `transferOwnership`/`setEVaultFactory`/`setJuniorTrancheEngine` | `test_guard_admin_onlyOwner_transfer_and_wiring` |
| `ZeroAddress` on the 3 admin functions | `test_guard_admin_onlyOwner_transfer_and_wiring` |

## 5. Attack surfaces

- **The account-identity borrow gate is the whole point — and it's proven on the live market (I-1)** — the farm utility
  vault is shared depositor USDC; the guard is the only thing stopping an LP holder from levering it on their own
  account. `test_third_party_borrow_blocked_by_guard` stands up the real EVK market with the guard installed, lets
  the engine Safe borrow (passes), then has a third party post the same escrow on its own account and attempt a
  direct `EVC.call` borrow — rejected. This is the strongest possible evidence for a borrow-allowlist hook.
- **Anti-spoof on both the install and the decode (I-2/I-3)** — `isHookTarget` returns the magic value only to a
  factory proxy, and `_msgSender` trusts the appended account only when the caller is a proxy. The first is directly
  tested; the second is the same `isProxy` branch and is exercised through the real-vault borrow path. A *direct*
  non-vault `fallback()` call (which would fall to `return msg.sender` and then `!= juniorTrancheEngine` →
  `NotEngineSafe`) isn't separately tested — low-risk (it fails closed) but uncovered.
- **The admin surface — now covered (I-4)** — re-pointing `juniorTrancheEngine` literally **changes who may borrow
  the shared USDC**, and the `onlyOwner` here uses a **non-standard raw-`msg.sender`** check (deliberately bypassing
  the EVK `_msgSender()` decoder to avoid a collision). `test_guard_admin_onlyOwner_transfer_and_wiring` now proves: a
  non-owner reverts `NotOwner` on all three admin functions (the raw-`msg.sender` gate), the zero-guards fire, the
  re-points take effect (incl. the borrow allowlist), and `transferOwnership` hands the admin to the Timelock after
  which the old owner loses the gate. Given this is a security guard, that was the gap worth closing.
- **Install/config is off-chain (X-1)** — the guard does nothing unless installed on `OP_BORROW` with the real
  factory wired; that's the deployer's job. The third-party test evidences the end-to-end wiring, but the install
  correctness itself lives in deploy scripts.
- **No fuzz/invariant — N/A** — a stateless identity check; nothing to fuzz.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Dedicated unit | 0 | no `FarmUtilityBorrowGuard.t.sol` — covered via the sibling loop suite |
| Consumer (security gate) | 2 | `test_third_party_borrow_blocked_by_guard` (real-EVK account-identity gate), `test_guard_isHookTarget_only_for_factory_proxy` (anti-spoof) |
| Admin/wiring | 1 | `test_guard_admin_onlyOwner_transfer_and_wiring` (raw-`msg.sender` `onlyOwner` on all 3 fns, zero-guards, effects, ownership handoff) |
| Fuzz / invariant | 0 | stateless identity check — N/A |

All 3 guard tests pass (`forge test` green). Coverage % uninstrumentable (project-wide stack-too-deep). The gate is
proven against the real market and the admin surface (incl. the borrow allowlist + raw-`msg.sender` gate) is now
covered.

## X-Ray Verdict

**ADEQUATE** — the guard's reason for existing (pin `OP_BORROW` to the engine Safe so the shared farm utility USDC
can't be levered by an outsider) is proven on the **real EVK/EVC market**, the `isHookTarget` anti-spoof is tested,
and the admin surface — incl. the borrow-allowlist `setJuniorTrancheEngine` and the deliberate raw-`msg.sender`
`onlyOwner` — is now covered too. Capped at ADEQUATE only by the off-chain install-on-`OP_BORROW` assumption (X-1,
deploy/config) and the untested direct-non-vault `fallback()` edge (fails closed). No fuzz applies (stateless); no
outstanding coverage gap on the contract surface.

**Structural facts:**
1. 53 nSLOC; `IHookTarget`; no CRE operator, no value path, no custody; replicates `BaseHookTarget` inline.
2. The gate: `fallback()` reverts `NotEngineSafe` unless the EVK on-behalf account == `juniorTrancheEngine` (account-identity, not operator-auth); installed only on `OP_BORROW`.
3. Anti-spoof: `isHookTarget`/`_msgSender` trust the caller/appended account only when `msg.sender` is a factory proxy; `onlyOwner` checks raw `msg.sender` (avoids the EVK decoder collision).
4. Tests: 0 dedicated; 3 via the loop suite — 2 security (real-EVK third-party rejection + isHookTarget anti-spoof) + 1 admin (onlyOwner/transfer/wiring).
5. No outstanding coverage gap on the contract surface; residuals are off-chain (install-on-`OP_BORROW`, X-1) + the direct-non-vault `fallback()` edge (fails closed).
