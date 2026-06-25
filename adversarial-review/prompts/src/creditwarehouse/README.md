# CreditWarehouse group — adversarial review prompts

> **Running a cycle?** Read `adversarial-review/CONDUCTOR.md` first. This file is the map.

Mirrors `contracts/src/supply/CreditWarehouse/`. One contract — a thin senior-side CRE encoder.

| Contract | nSLOC | Missions | Surfaces |
|---|---:|---:|---|
| `warehouseadminmodule/` | 110 | 2 | encoder discipline (hardcode-dangerous/inject-addressable, op allow-list, REPAY double-defense) · cross-contract scope-trust (X-1) + avatar parity (I-4) + build-phase wiring (X-3) |

## The defining feature — the security boundary is OUT of this file (carry into every synthesis)
`WarehouseAdminModule` is a **pure encoder**: it holds no custody and enforces no scope. It decodes the CRE
envelope into one of four warehouse ops and forwards through `roles.execTransactionWithRole(to, 0, data,
Call, roleKey, true)`. The decisive control — param-pinning (SUPPLY/REDEEM `receiver==avatar`, APPROVE
`spender==EqualTo(eePool)`, REPAY `to==EqualTo(redemptionBox)`), Call-only, no delegatecall — lives in the
**Zodiac Roles-modifier-v2 scope config** (off-chain deploy artifact, X-1, On-chain=No), NOT in this
bytecode. The encoder's on-chain contribution is the discipline *hardcode everything dangerous, inject
everything addressable*: `value`/`operation`/`shouldRevert` are literals (never payload-decoded);
receiver/spender/redeem-owner injected from storage; only the REPAY `to` is payload-carried, and it is BOTH
self-checked AND scope-pinned.

## The precedent is the REAL audited engine, not a code parent
There's no audited parent for the encoder, but the modifier it forwards to IS audited and vendored —
`reference/zodiac-modifier-roles/packages/evm/contracts/Roles.sol` + `PermissionBuilder.sol`. Diff the
adapter's `execTransactionWithRole` call shape, the `Operation` enum (0=Call/1=DelegateCall), and the
`ExecutionOptions` enum (0=None…3=Both) against the real modifier; the local mirror
`contracts/src/interfaces/zodiac/IRoles.sol` claims byte-for-byte parity (verified). The
fork-integration test suite (28 units) drives the REAL deployed modifier — its strength is that the decisive
scope rejections are exercised, not mocked.

## Pressure-test severity hard
The X-Ray rates this **HARDENED** (the only residuals are process: the deferred pre-prod immutable re-freeze
of the six build-phase setters, and no external audit). So:
- A finding requiring distrust of the off-chain Roles scope (X-1) is the #1 audit artifact / documented trust
  boundary — INFO unless the *encoder* itself leaks or makes the scope unable to pin something it must.
- A finding requiring distrust of the build-phase Timelock (X-3) is accepted-risk closed by the re-freeze —
  INFO unless a single-contract re-point drains value without a paired off-chain re-scope.
- A mis-scope or a wiring desync that the modifier rejects is **fail-closed** (DoS/grief), not a leak — label
  every finding drain-vs-fail-closed.
- The most productive open angle (per the X-Ray gaps): is I-4 avatar-parity enforcement *complete*, or only
  entry-point-local? `setWarehouseSafe` reverts `AvatarMismatch`, but `setRoles` and an external
  `Roles.setAvatar` can re-desync the pair afterward (fail-closed) — Mission 2 chases whether the X-Ray's "a
  one-sided re-point can no longer be saved" is overstated.

"Sound" is the expected result for a defensively-hardcoded thin encoder; a manufactured finding is noise.

## Run
Per `CONDUCTOR.md`: prompts authored ✅ (this tree); X-Rays exist ✅
(`contracts/src/supply/CreditWarehouse/x-ray/` — per-contract `WarehouseAdminModule.md` authoritative;
`invariants.md`/`entry-points.md` the scope catalog). Each mission's `context.files` inlines the contract +
the `IRoles`/`IEulerEarn` interfaces + the real Zodiac Roles modifier + the base + the fork test suite for
non-agentic (Fugu) panelists.
