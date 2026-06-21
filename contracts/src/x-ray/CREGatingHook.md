# X-Ray — `CREGatingHook.sol` (single-contract, test-connected)

> CREGatingHook | 64 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo inherent EVK/EVC trust, the pre-prod re-freeze, and no external audit)*

> **Update 2026-06-20:** the I-6 gap (build-phase admin surface untested) is **CLOSED** — 5 tests
> (`test_f_admin_onlyOwner` / `_admin_zeroGuards` / `_setters_effect_and_events` / `_transferOwnership_effect` /
> `_setBorrowDriver_repoint_changes_gate`) cover the `onlyOwner`/`NotOwner` gate, the `ZeroAddress` guards, all three
> setters' re-point + `WiringSet`, the ownership handoff, and — the high-stakes one — the `setBorrowDriver` re-point
> proving the gate now authorizes against the NEW driver (old line account rejected, new one passes). 13/13 green.
> Verdict lifted to HARDENED.

First per-contract X-Ray in `contracts/src/x-ray/` (the top-level `src/` scope — loose contracts like
`ZipcodeController`, `SiloRegistry`, the registries live here). Subject: `CREGatingHook.sol`, the EVK **hook target**
(§4.3) that gates `borrow`/`liquidate` on the per-line lien markets to the line's borrow-driver. Exercised by
`CREGatingHook.t.sol` — **8 unit tests** (mock factory + mock EVC; the decisive `isProxy`/operator-auth matrix). It
is installed on every borrow vault by `EulerVenueAdapter.openLine` at `OP_BORROW | OP_LIQUIDATE`.

> The decisive control is a single line in `fallback`: the EVK-appended on-behalf account must have authorized
> `borrowDriver` as its EVC operator, else revert `NotAuthorizedOperator`. The subtle part is **trusting the appended
> 20 bytes** — `_msgSender()` reads them ONLY when `msg.sender` is a recognized factory proxy (a real vault),
> otherwise it falls back to `msg.sender`; without that `isProxy` guard a non-vault caller could spoof an authorized
> account. That guard, in both directions, is the test that matters and it is present.

## 1. What it is

A 64-nSLOC `IHookTarget` replicating `BaseHookTarget` inline (evk-periphery is un-remapped). Three Timelock-settable
wiring slots (`eVaultFactory`, `evc`, `borrowDriver`) + a build-phase `owner` (a bespoke `onlyOwner` checking the RAW
`msg.sender`, NOT OZ `Ownable` — whose `Context._msgSender()` would collide with this hook's trailing-data decoder).

- **`isHookTarget()`** — returns the magic selector only when `msg.sender` is a factory proxy (vault), else `0`.
- **`fallback()`** — the gate: `evc.isAccountOperatorAuthorized(_msgSender(), borrowDriver)` or revert; op-agnostic (no per-op branch), reverts with no return data.
- **`_msgSender()`** — extracts the appended on-behalf account, but trusts the 20 bytes only when `msg.sender` is a proxy (else returns `msg.sender`).
- **admin** — `transferOwnership` + `setEVaultFactory`/`setEvc`/`setBorrowDriver` (all `onlyOwner`, zero-guarded).

`repay` is never in `hookedOps` (the adapter installs only `OP_BORROW | OP_LIQUIDATE`), so it stays permissionless —
the hook itself is op-agnostic, and repay simply never reaches it.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `isHookTarget()` | public view | magic selector iff caller is a factory proxy; else `0` |
| `fallback()` | EVK-invoked | the operator-auth gate; `NotAuthorizedOperator` on failure |
| `transferOwnership(newOwner)` | `onlyOwner` | build-phase admin handoff; zero-guarded |
| `setEVaultFactory` / `setEvc` / `setBorrowDriver` | `onlyOwner` | `ZeroAddress`-guarded re-points; emit `WiringSet` |
| `constructor(eVaultFactory_, evc_, borrowDriver_)` | deploy | seeds wiring + `owner = msg.sender` |

No permissionless mutator. The gate is reached only via the EVK hook invocation.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **operator-auth gate** — the appended on-behalf account must have authorized `borrowDriver`; else revert `NotAuthorizedOperator` | Yes | **`test_b_fallback_authorizedAccount_passes`**, **`test_c_fallback_unauthorizedAccount_reverts`** |
| I-2 | **`isProxy` spoof guard (the load-bearing one)** — appended bytes are trusted ONLY from a factory proxy; a non-proxy caller appending an *authorized* account is still rejected (the guard uses `msg.sender`, not the bytes) | Yes | **`test_d_isProxyGuard_spoofRejected`** (spoof blocked) + **`test_d_nonProxy_authorizedSelf_passes`** (converse — proves `msg.sender` is used) |
| I-3 | **`isHookTarget` proxy-gated magic** — magic selector `0x87439e04` from a proxy, `0` from a non-proxy | Yes | **`test_a_isHookTarget_proxy_returnsMagic`**, **`test_a_isHookTarget_nonProxy_returnsZero`** |
| I-4 | **op-agnostic uniform gate** — same authorization predicate regardless of the leading selector (borrow vs liquidate); repay stays permissionless by construction | Yes | **`test_e_opAgnostic_uniformGate`** |
| I-5 | **`NotAuthorizedOperator` selector KAT** — `0x3d9adf1c` | Yes | **`test_errorSelector`** |
| I-6 | **build-phase admin** — `onlyOwner` gates the setters + `transferOwnership` (raw `msg.sender`); `ZeroAddress`-guarded; `setBorrowDriver` re-point changes who the gate authorizes against | Yes | **`test_f_admin_onlyOwner`** (4× `NotOwner`), **`_admin_zeroGuards`** (4× `ZeroAddress`), **`_setters_effect_and_events`** (3 setters re-point + `WiringSet`), **`_transferOwnership_effect`** (handoff + old owner loses power), **`_setBorrowDriver_repoint_changes_gate`** (new driver passes the gate, old line account rejected) |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `NotAuthorizedOperator` (the gate) | `fallback:112` | `test_c_fallback_unauthorizedAccount_reverts`, `_d_isProxyGuard_spoofRejected` |
| `isProxy` trust on appended bytes | `_msgSender:119` | `test_d_isProxyGuard_spoofRejected` / `_d_nonProxy_authorizedSelf_passes` |
| `isProxy` magic gate | `isHookTarget:103` | `test_a_isHookTarget_*` |
| `onlyOwner` / `NotOwner` | `:55` | `test_f_admin_onlyOwner` |
| `ZeroAddress` (transferOwnership + 3 setters) | `:73,:81,:88,:95` | `test_f_admin_zeroGuards` |

The decisive runtime gate (I-1…I-4) and the build-phase admin surface (I-6) are now both fully covered — no
outstanding gap.

## 5. Attack surfaces

- **The spoof guard is the crux — and it's proven both ways (I-2).** A hook that trusted EVK's appended on-behalf
  bytes unconditionally would let any caller claim to be an authorized account. `_msgSender` defers to the appended
  bytes only when `msg.sender` is a factory proxy; `test_d_isProxyGuard_spoofRejected` proves a non-proxy caller
  appending an *authorized* target is still rejected (the guard used `msg.sender`), and the converse test proves the
  proxy path actually reads the bytes. This is the single most important behavior and it is pinned.
- **The gate is operator-authorization, not ownership (by design).** The per-line borrow account has its own
  owner-prefix and shares none with `borrowDriver`, so the check is `isAccountOperatorAuthorized`, not a
  `haveCommonOwner`. Correct for the per-line topology (each `LineAccount` grants the adapter the operator bit — see
  [LineAccount.md](../venue/x-ray/LineAccount.md)) and proven via the authorized/unauthorized matrix.
- **`borrowDriver` re-point (I-6) — the highest-stakes admin action, now proven.** `setBorrowDriver` changes *which
  operator the gate authorizes against*; `test_f_setBorrowDriver_repoint_changes_gate` re-points the driver and proves
  the gate now authorizes against the NEW driver (an account authorized to it passes the fallback) while the old line
  account — authorized only to the prior driver — is rejected `NotAuthorizedOperator`. `transferOwnership` (handoff +
  old-owner-loses-power) and `setEVaultFactory`/`setEvc` (re-point + `WiringSet`) are likewise covered.
- **The bespoke `onlyOwner` (raw `msg.sender`) is a deliberate, documented choice** — OZ `Ownable`'s
  `Context._msgSender()` would collide with the hook's trailing-data decoder. Sound, and the `NotOwner` revert is now
  tested across all four admin functions (`test_f_admin_onlyOwner`).
- **Inherent trust:** the EVK `GenericFactory.isProxy` and EVC `isAccountOperatorAuthorized` are upstream Euler
  mechanics (audited; relied on). Build-phase mutable wiring (frozen pre-prod) is the subsystem-wide residual.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Gate (authorized / unauthorized / op-agnostic) | 3 | `test_b`, `test_c`, `test_e` |
| `isProxy` spoof guard (both directions) | 2 | `test_d_isProxyGuard_spoofRejected`, `_d_nonProxy_authorizedSelf_passes` |
| `isHookTarget` magic (proxy / non-proxy) | 2 | `test_a_*` |
| Error-selector KAT | 1 | `test_errorSelector` |
| Admin (owner / setters / zero-guards / re-point gate) | 5 | `test_f_*` (added 2026-06-20) |

Coverage % uninstrumentable (project-wide `Stack too deep`); **13 unit tests green**. The decisive control (the
operator-auth gate + the `isProxy` spoof guard) and the build-phase admin surface are both fully covered against mock
factory/EVC; no outstanding gap.

## X-Ray Verdict

**HARDENED** *(modulo inherent EVK/EVC trust, the pre-prod re-freeze, and no external audit)* — a small, sharp EVK
hook whose decisive control is exhaustively proven: the operator-authorization gate (authorized passes, unauthorized
reverts `NotAuthorizedOperator`), the op-agnostic uniform behavior, the proxy-gated `isHookTarget` magic, and — the
load-bearing one — the `isProxy` spoof guard in both directions (a non-proxy caller cannot spoof an appended
authorized account). The I-6 gap is **closed**: the full build-phase admin surface (`onlyOwner`/`NotOwner`,
`ZeroAddress` guards, the three setters' re-point + `WiringSet`, the ownership handoff, and the `setBorrowDriver`
re-point proving the gate re-targets to the new driver) is now covered. No code or coverage gap remains; the
residuals are inherent — trust in the audited EVK `GenericFactory.isProxy` / EVC `isAccountOperatorAuthorized`, the
deferred pre-prod immutable re-freeze of build-phase wiring, and the absence of an external audit.

**Structural facts:**
1. 64 nSLOC; `IHookTarget` (inline `BaseHookTarget` replica); bespoke `onlyOwner` (raw `msg.sender`, not OZ `Ownable`, to avoid the trailing-data `_msgSender` collision).
2. The gate: the EVK-appended on-behalf account must have authorized `borrowDriver` as its EVC operator; op-agnostic; reverts `NotAuthorizedOperator` with no data.
3. The `isProxy` guard trusts the appended 20 bytes ONLY from a factory proxy — the anti-spoof crux, proven both directions.
4. `repay` is never hooked (adapter installs `OP_BORROW | OP_LIQUIDATE`), so it stays permissionless by construction.
5. Tests: 13 unit (gate matrix + spoof guard + magic + selector KAT + the full admin sweep incl. the `setBorrowDriver` re-point gate proof). No coverage gap; residuals are inherent (EVK/EVC trust, pre-prod re-freeze, no audit).
