# item-10 — `DeployZipcode` (deploy/wiring orchestrator map)

> Source of truth = `contracts/script/DeployZipcode.s.sol`. The ticket `tickets/woof/WOOF-10-deploy-wiring.md`
> + report `reports/WOOF-10-report.md` + spec `claude-zipcode.md` §9 are intent — the kept code is final.
> This doc reads the deploy script as the realized form of the item-10 deploy DAG that every other wires doc's
> "Item-10 deploy facts" section feeds into. **Status (load-bearing): `forge build` GREEN, NEVER EXECUTED** —
> see the test-scaffold note below.

## Role
The single Base-side deploy + wiring orchestrator. `contract DeployZipcode is SummonSubstrate` (which `is
Script`) — it INHERITS `_summon`/`computeMainSafe` and the Safe pre-validated-signature `execTransaction`
pattern, and `new`s the `CreditWarehouseDeployer` / `FarmUtilityMarketDeployer` sub-deployers so the intricate
Baal-summon / Roles-scoping / EVK-market logic stays in its tested home. Entrypoint is **`deploy()`** (NOT
`run()` — `run()` is the inherited non-virtual `SummonSubstrate` entrypoint; delta 3). It deploys + wires the
whole protocol in dependency order across phases **P0–P9**, asserts the **8 cross-cutting seams** inline,
seals every `ReceiverTemplate` CRE identity, and `transferOwnership(timelock)` everywhere (NOT renounce).

The broadcaster MUST be `TEAM_MULTISIG` — the Safe `v==1` pre-validated path needs `msg.sender == owner`.

## Phases (the deploy DAG, entrypoint `deploy()`)
Execution order is P0 → P1 → P2 → **P4 → P3** (warehouse before the deposit module, since `ZipDepositModule`'s
`warehouseSafe` is an immutable ctor arg) → P5 → P6 → P7 → P8 → P9.

| Phase | What it stands up |
|---|---|
| **P0 roots** | `TimelockController` (2-day, deployer = sole proposer/executor + retained build-phase admin). `EE_POOL` / `USDC_RESERVOIR` are env inputs (out-of-band, see Gotchas). |
| **P1 venue spine** | registry → lienFactory → hook (borrowDriver placeholder) → adapter (controller placeholder) → controller; close the two ctor cycles via `adapter.setController` / `hook.setBorrowDriver` / `registry.setController`. Asserts `SeamVenue`, `SeamRegistryController`. |
| **P2 bridge** | `SzAlphaRateOracle` (Base side of 8x-02). |
| **P4 warehouse** | `ZipRedemptionQueue` (deployed here with `zipUSD=address(0)` so the warehouse can pin `redemptionBox == queue`; delta 2) → `CreditWarehouseDeployer.deploy`. Asserts `SeamWarehouseCommingled`. |
| **P3 supply substrate** | `_summon` (Baal + main Safe + juniorTrancheSidecar) → `ESynth` zipUSD → `ZipDepositModule` → `SzipNavOracle` → `ExitGate` → `SzipUSD` → `setShareToken` both sides → `queue.setTokens` (re-point to the real zipUSD) → Gate `manager(2)` via `setShamans`. Asserts zero-Shares + `SeamGateShareToken`. |
| **P5 farm utility** | `SzipFarmUtilityLpOracle` + `FarmUtilityMarketDeployer.deploy` (governor = Timelock, juniorTrancheEngine = main Safe). Asserts `SeamSharedLp` (`POL_ICHI_VAULT == escrowVault.asset()`). |
| **P6 engine modules** | all 9 Zodiac modules cloned via `ModuleProxyFactory.deployModule(mastercopy, setUp, salt)` + `_enableModuleOnSafe`; DurationFreeze enabled on BOTH Safes, OffRamp + the rest on the main Safe. Sets `navOracle.setJuniorTrancheEngine` / `gate.setJuniorTrancheEngine`. Asserts `SeamEngineSafe`, `SeamOneBank`, `SeamSharedLp`; `owner=timelock != operator=CRE`. |
| **P7 loss** | `LienXAlphaEscrow` (coordinator placeholder) → `DefaultCoordinator` → close the cycle via `escrow.setCoordinator` / `coord.setEscrow` (the latter `forceApprove(max)`s the escrow) → `navOracle.setDefaultCoordinator`. Asserts `SeamEscrowCoordinator`. |
| **P8 NAV final** | `navOracle.setLpPosition` + `navOracle.setXAlphaRateOracle`. Asserts `SeamNavShareTokenUnset`. |
| **P9 seal** (CTR-16) | `setExpectedAuthor` + **`setExpectedWorkflowName(<per-receiver daemon name>)`** on every `ReceiverTemplate` (controller, registry, warehouse adapter, coord, navOracle, rateOracle, **and the CRE-push `lpOracle` when `lpOracle != address(0)`** — SEC-05/M4). The shared `setExpectedWorkflowId` pin is **DROPPED** (left `bytes32(0)` ⇒ `onReport` skips it): `author`+`workflowName` survive workflow redeploys, and the **per-receiver names** are what separate the SEPARATE daemons that share the one deploy wallet (the shared author cannot). Names are env inputs (`WORKFLOW_NAME_*`); the per-receiver→daemon map: controller→`CONTROLLER`, registry→`REVALUATION`, WAM→`WAREHOUSE`, coord→`COORDINATOR`, navOracle/lpOracle→`SHAREFEEDS`, rateOracle→`RATE`. Then `ZipcodeDeployAsserts.requireIdentityWired(receivers[], registry)` asserts **EACH** receiver (author+name) + the registry controller seed (no representative-id inference), → `transferOwnership(timelock)` everywhere. The lpOracle seal+assert are guarded `!= address(0)` so the fair-LP branch (ownerless `AlgebraIchiFairLpOracle`) neither seals nor asserts. |

## The 8 asserted seams (the cross-cutting invariants, inline custom errors)
`SeamVenue` · `SeamRegistryController` · `SeamSharesNonZero` · `SeamGateShareToken` ·
`SeamWarehouseCommingled` · `SeamOneBank` · `SeamSharedLp` · `SeamEngineSafe` · `SeamEscrowCoordinator` ·
`SeamNavShareTokenUnset`. These realize the `wires/README.md` "Cross-cutting wiring patterns" 1–8 as runtime
reverts — the script connects documented pins, it does not rediscover them.

## Inputs (env / stand-ins)
~30 env keys via `_loadInputs()`: principals (`TEAM_MULTISIG`, `GOD_OWNER`, `CRE_OPERATOR`, `WORKFLOW_AUTHOR`,
the six per-receiver `WORKFLOW_NAME_*` names — CTR-16, replacing the dropped `WORKFLOW_ID`,
`EREBOR`, `ADMIN_SAFE`, `SUMMON_SALT_NONCE`), live-infra stand-ins (`IRM`, `XALPHA_MIRROR`,
`POL_ICHI_VAULT`, `POL_GAUGE`, `EE_POOL`, `USDC_RESERVOIR`), and numeric knobs (NAV window/maxAge/deviation,
TVL cap, recovery floor, borrow cap, LTVs, buy-burn discount/cap, rate staleness/window/cap). Mirrors
`contracts/.env.example`.

## Status — never executed (the one load-bearing caveat)
`DeployZipcode.deploy()` has a GREEN `forge build` (the authoring bar) but **has never run, on a fork or
anywhere.** The fork harness `contracts/test/DeployZipcode.t.sol` is three `vm.skip(true)` placeholders; its
`(T)` stand-ins (`EE_POOL`, ICHI vault, gauge, IRM, xALPHA mirror) are `makeAddr` placeholders, not real/mock
fork contracts. So the 8 seams are asserted in code but **unverified at runtime**, and the deploy DAG is a
build-green plan, not a proven stand-up. Turning the skips green is the open item-10 acceptance (PROGRESS
"Open obligations"). The individual sub-deployers (`SummonSubstrate`, `CreditWarehouseDeployer`,
`FarmUtilityMarketDeployer`) and every component HAVE each run on a Base fork in their own suites — it is the
single end-to-end `deploy()` pass that has not.

## Gotchas (5 build-discovered deltas + the EE hole)
1. **`ZipDepositModule` has no Ownable surface** — immutable `deployer` + re-settable `setGate`. It is the one
   contract P9 does NOT `transferOwnership(timelock)`; re-home only by redeploy.
2. **`ZipRedemptionQueue` deploys in P4 but zipUSD is a P3 artifact** — deployed with `zipUSD=address(0)`, then
   `setTokens(realZipUSD, USDC)` in P3.
3. **`run()` collision** — `DeployZipcode` cannot use `run()` (inherited non-virtual from `SummonSubstrate`);
   the entrypoint is `deploy()`.
4. **The broadcaster IS `TEAM_MULTISIG`** — the Safe-driving helpers (`_enableModuleOnSafe`,
   `_setShamansManager`, `_execAsTeam`) use the `v==1` pre-validated single-owner signature path
   (`msg.sender == owner`).
5. **EE-pool config is out-of-band (the honest hole).** `EE_POOL` / `USDC_RESERVOIR` are env inputs, NOT
   created by the script — the EulerEarn admin ABI (`createEulerEarn`, `setIsAllocator`, `setCurator`,
   `setFeeRecipient`, `setFee`, point the supply queue at the farm utility borrow vault) is intentionally not
   compiled in (we do not vendor EulerEarn 0.8.26). It is a documented fork-runbook pre/post step. This is the
   gap between "deploy script runs" and "system actually works." Tracked as the item-10 EE obligation.

## Cross-component
Every other `wires/*.md` "Item-10 deploy facts" section names the phase + setter this script uses for that
component; this doc is the assembled view. The `ReceiverTemplate` identity-seal family (README pattern 2) is
sealed in P9 against `_sealIdentity` + `requireIdentityWired`; the build-phase Timelock-settable posture
(README pattern 1) is realized as the P9 `transferOwnership(timelock)` sweep (never renounce).
