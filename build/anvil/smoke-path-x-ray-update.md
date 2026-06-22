# smoke-path-x-ray-update — rebuild the anvil smoke suite from the docs/x-ray model

**For a fresh window.** The protocol now has a full documentation set: an ELI20 summary per contract
(`docs/**`, index `docs/README.md`), a code-truth wiring map per contract (`docs/wires/**`), a per-contract
security X-Ray with named invariants (`contracts/src/**/x-ray/**`), and the cross-contract seam ledger
(`docs/wires/SYSTEM-SEAM-MAP.md`, seams S1–S13). This file tells you how to bring every smoke path in
`build/anvil/` (SP-01…SP-18) up to that model, so the suite re-runs on the anvil fork with correct, current
context. Go through the work queue at the bottom one SP at a time.

## The model (what changed)

A smoke path is the LIVE-FORK proof that a cross-contract **seam** holds (unit tests prove single nodes; smoke
paths prove the joints). Three sources do the work for you — do not invent any of it:

1. **`docs/wires/SYSTEM-SEAM-MAP.md` is the skeleton.** Its S1–S13 are the joints; each maps to one or more SPs.
2. **The ELI20 doc + the X-Ray of the contract(s) the SP touches give you the assertions.** Every ELI20 has a
   "load-bearing properties an auditor should check" list; every X-Ray has named invariants (`I-n`, `X-n`, `E-n`)
   with an **On-chain=Yes/No** flag. Lift the `On-chain=Yes` ones into the SP's Assertions, by ID.
3. **`build/anvil/contract-map.md` is the only address source.** Bind by role/name, not pasted hex (see Preconditions).

## Preconditions (do these first)

- **SIZE-01 must be resolved.** `EulerVenueAdapter` is 38 bytes over EIP-170 and blocks `--broadcast`
  (`build/tickets/contracts/trim-eulervenueadapter.md`). Until it is trimmed and the board re-broadcasts, the suite
  cannot run and addresses cannot be refreshed. Resolve it, redeploy, regenerate `contract-map.md` — THEN run SPs.
- **Re-bind every address.** The redeploy (SIZE fix + the new `SiloRegistry`) shifts addresses. Resolve them from
  the broadcast `broadcast/DeployLocal.s.sol/8453/run-latest.json` (or the regenerated `contract-map.md`) by
  contract NAME, and stop pasting truncated hex into SPs — that is why the current SPs rot on every redeploy.

## Coverage table — seam → what to assert → current SP → status

Status: **covered** (an SP proves it), **partial** (touched but the seam's real property isn't asserted),
**gap** (no SP), **off-chain** (the seam map says it's not fork-provable — do NOT write an SP).

| Seam (SYSTEM-SEAM-MAP) | Live-fork property to assert | Current SP | Status | Lift assertions from |
|---|---|---|---|---|
| S1 precompile→SzAlpha (magnitude trust) | — | — | off-chain (964, not on the Base fork) | `docs/bridge.md` (note only) |
| S2 rate truthful (lock/release+18dp) | rate flows 964→Base→NAV | SP-12 | partial (conservation is 964/topology, not fork-provable) | `docs/bridge.md`, `8x-02` |
| S3 fresh()→navEntry asymmetry | stale rate reverts issuance, NOT exit | SP-07, SP-12 | covered | `docs/supply/SzipNavOracle.md` I-5/I-6; `8-B4` |
| S4 CRE Forwarder→receivers | each report path is Forwarder-gated | (all needs-forwarder SPs) | partial (per-path yes; correlated-compromise no) | each receiver's X-Ray; `dependency-surface.md` |
| S5 DC→NAV provision bound | default marks NAV down by `atRisk·(1−floor)`; DC-only writer | SP-11 | covered | `docs/loss.md` E-1; NAV provision gate |
| S6 DC↔escrow destination integrity | bond flows only to originator/treasury/engine | SP-11 | covered | `docs/loss.md` X-1/X-2 |
| S7 donation into a counted Safe moves NAV | a direct transfer shifts NAV with no deposit; Gate denominator is the only tie-back | — | **gap** (the one seam with no on-chain bound) | NAV X-Ray I-1; demo X-Ray I-1/I-2 |
| S8 NAV→ExitGate issuance | `navEntry=max`, round-down mint, first-depositor guard | SP-02, SP-06 | covered | `docs/supply/szipUSD/ExitGate.md` I-1/I-4 |
| S9 NAV→DurationFreeze floor | `release` can't drop coverage below `committed+pathLockedLp` | SP-03, SP-15 | covered | `docs/supply/szipUSD/DurationFreezeModule.md` I-1/I-2 |
| S10 NAV→BuyBurn bid | bid priced at `navExit`, fenced to `oldestRequiredLegTs` | SP-05, SP-13 | covered | `docs/supply/szipUSD/SzipBuyBurnModule.md` I-2/I-3 |
| S11 Warehouse→Roles→Safe→EE | the 4 ops route only through the Roles scope; avatar parity | SP-09 | covered (scope tree audited off-chain) | `docs/supply/CreditWarehouse/WarehouseAdminModule.md` |
| S12 EE shares→senior NAV donation-immune | aggregate reads `convertToAssets(balanceOf(safe))`, never `balanceOf(pool)` | — | **gap** (SeniorNavAggregator not on this board yet) | `docs/SeniorNavAggregator.md` I-1 |
| S13 engine module set on shared Safes | module set IS the access control; cross-module value conservation | SP-17 | partial (flywheel runs; end-to-end conservation not asserted) | `portfolio-map.md`; each module ELI20 |
| credit spine (not an S#): CTR-03 routing | origination resolves venue via `SiloRegistry.venueOf(siloId)`; line count bumps | SP-14, SP-16 | **drifted** (now needs `siloId`; see below) | `docs/ZipcodeController.md`, `docs/SiloRegistry.md` |
| lien pricing (not an S#): revaluation | reportType-3 batch reprices liens; staleness window; strict-18dp | SP-08 | covered | `docs/ZipcodeOracleRegistry.md` |

## Drift to fix across ALL SPs (catch these while you go)

1. **CTR-03 origination routing (SP-14, SP-16 — and any SP that opens a line).** `ZipcodeController._origination`
   now decodes an **8-field** payload with `siloId` LAST, and routes via the `SiloRegistry`. The report MUST carry
   `LOCAL_SILO_ID = keccak256("ZIPCODE_SILO_0") = 0x0309d2cf8d22de7d0626162a4ba1d7bff931531432937d085bcaf163f0febebd`
   or origination reverts `SiloUnrouted`/`RegistryUnset`. The current SPs predate this and will fail.
2. **Address rebind (every SP).** See Preconditions — bind by name from the regenerated `contract-map.md`.
3. **New contracts on the board.** `SiloRegistry`, `FarmUtilityBorrowGuard`, `LineIrm` now appear — SPs that
   reference routing, the farm-utility borrow gate, or line interest must point at them.

## Per-SP refresh recipe (apply to each)

1. Read the SP. Identify the seam(s) + contract(s) it exercises (use the coverage table).
2. Open those contracts' ELI20 (`docs/**`) + X-Ray (`contracts/src/**/x-ray/**`). Note the relevant invariant IDs
   and the **On-chain=Yes** properties.
3. **Intent / Proves:** rewrite to name the seam + invariant(s) it proves (e.g. "proves S8 + ExitGate I-1 on a
   live fork"). Keep it one or two sentences.
4. **Binds to:** list the contracts by NAME (resolve addresses from `contract-map.md`/`run-latest.json` at run
   time) + the ELI20 + the X-Ray + the wires doc. Drop pasted hex.
5. **Calls:** re-derive from the CURRENT ABI via the wires doc — this is where you catch drift (the `siloId`
   field, renamed funcs, new args). Do not trust the old call list.
6. **Assertions:** lift the `On-chain=Yes` invariants by ID; assert them as observed on-chain deltas. Drop any
   claim the X-Ray marks `On-chain=No` (those are off-chain — note them as out-of-scope, don't test them).
7. Leave the **Result** section empty (it gets filled when the SP is actually run post-SIZE-fix).

## Worked example — SP-01 in the new form

```
# SP-01 — zipUSD utility-dollar lifecycle (the supply-entry seam)

**Seam / invariants.** The deposit edge (USDC→zipUSD→EE pool→warehouse shares) feeding S12 (senior backing).
Proves: ZipDepositModule is a net-zero-custody conduit (WOOF-06 / ZipDepositModule X-Ray I-1), zipUSD mint is
capacity-gated to the module only, and the deposited USDC lands as EE shares on the warehouse Safe.

**Binds to** (resolve addresses by name from contract-map.md): ZipDepositModule, zipUSD (ESynth), the EE pool,
the warehouse Safe, USDC.
Docs: docs/supply/ZipDepositModule.md · X-Ray: contracts/src/supply/x-ray/ZipDepositModule.md · wires: WOOF-06.

**Setup.** deal 1,000e6 USDC to alice; approve ZipDepositModule.

**Calls.** (re-derived from WOOF-06's current ABI)
1. ZipDepositModule.deposit(1_000e6) as alice
2. (neg) zipUSD.mint(alice, 1e18) as alice → expect E_CapacityReached
3. zipUSD.transfer(bob, 100e18) as alice

**Assertions** (lift the On-chain=Yes invariants):
- I-1 net-zero custody: ZipDepositModule holds 0 of every token after the call.
- value-1:1: zipUSD.balanceOf(alice) == 1_000e18 (6→18 dp).
- warehouse custody: EE.balanceOf(warehouseSafe) grew; USDC landed in the base USDC market (supplyQueue[0]).
- capacity gate: step 2 mints nothing (totalSupply unchanged).
- plain ERC-20: bob == 100e18.
- (out of scope, On-chain=No: none here.)

**Result.** (fill on run)
```

## Work queue (one at a time; the fresh window walks this)

- **SP-01..13, 15, 17, 18 — refresh in place** with the recipe (re-bind addresses, name the seam+invariants,
  re-derive calls, lift assertions). Most are structurally fine.
- **SP-14, SP-16 — refresh AND fix the CTR-03 drift** (the `siloId` 8th field + SiloRegistry routing). These are
  currently broken, not just stale.
- **Add SP-19 — donation seam (S7).** Direct-transfer zipUSD/xALPHA into a counted Safe; assert NAV moves with no
  deposit and the Gate's round-down denominator absorbs it. The seam map flags S7 as the one with no on-chain
  bound — it deserves an explicit path. (Assertions from the NAV/demo X-Ray I-1/I-2.)
- **Add SP-20 — engine flywheel end-to-end value conservation (S13).** deposit → LP → harvest → exercise → sell →
  recycle, asserting basket value is conserved across the full loop. The szipUSD portfolio-map + SYSTEM-SEAM-MAP §7
  both call this out as proven node-by-node but never end-to-end.
- **Defer SP-21 — senior NAV donation-immunity (S12)** until `SeniorNavAggregator` is on the board (it deploys
  with the multi-silo hub, not this single-silo `DeployLocal`).
- **Do NOT write SPs for:** S1 (964 precompile magnitude), S2 conservation (deploy-topology/964), the S4
  correlated-CRE-compromise (model it, don't fork-test), the S11 Roles scope tree (audit the deployed tree
  directly). The X-Rays mark these `On-chain=No`/off-chain.

## Update the README catalog when done

`build/anvil/README.md` has the SP catalog table (headline question per SP). After the pass, align it: add the
seam ID each SP proves, and add the new SP-19/20 (and SP-21 when it lands).
