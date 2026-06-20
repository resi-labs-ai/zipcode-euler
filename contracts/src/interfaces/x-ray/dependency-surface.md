# Dependency Surface Map — `contracts/src/interfaces`

> Zipcode external trust surface | 32 interfaces, ~1,054 lines | 10 external vendors + 6 internal seams | `main` | 20/06/26
>
> The external-trust half of the protocol seam picture; the cross-contract joints are catalogued in
> `docs/wires/SYSTEM-SEAM-MAP.md` (seams S1–S13).

This is the interfaces-scoped equivalent of an X-Ray. Interfaces have no bodies/state, so the standard report (entry points, invariants, tests) does not apply. What *does* apply — and what an auditor actually needs from this folder — is the **integration surface**: every external contract Zipcode trusts, what it can do, who calls it, and where the trust is sharpest.

## Headline

- **All 32 are local "minimal mirror" interfaces** — hand-written to expose only the methods Zipcode touches, each carrying **on-chain verification evidence** in NatSpec (live address, selector, decoded `staticcall`, verification date). This is the single biggest de-risker: the #1 interface bug — selector/signature drift from the real contract — is explicitly guarded against per file.
- **Residual risk:** that evidence is a point-in-time snapshot (mostly 2026-06-06/08). Nothing re-checks it against live bytecode at build; an upgraded external contract can silently diverge.
- **4 interfaces are staged** (declared, referenced nowhere in src/script/test yet) — intentional forward scaffolding for the prod ICHI/Algebra LP path + a future range-sell ladder, now labeled `STATUS: STAGED` in-file. Not dead.
- The deepest-trust surfaces are the **Subtensor precompiles** (sole staking backing), **Baal `executeAsBaal`** (arbitrary call as the DAO), **Safe `execTransactionFromModule`**, and **Zodiac Roles** (delegatecall-capable permissioning).

---

## External Dependencies (by vendor)

Trust tier = blast radius if the external contract misbehaves or is mis-wired. **Consumed by** is grep-verified against `src/` (non-interface); deploy/test-only usage is labeled.

### Subtensor precompiles — `bridge/ISubtensorPrecompiles.sol` (IStakingV2 / IAlpha / IAddressMapping)

> **Trust: CRITICAL.** Sole source of staking backing + payout magnitudes for the LST.

- Exposes: `addStake`/`removeStake`/`getStake` (StakingV2), `simSwapTaoForAlpha`/`simSwapAlphaForTao` (Alpha AMM), `addressMapping` (coldkey).
- Consumed by: `bridge/SzAlpha.sol`.
- Composability note: runtime precompiles — behavior can change with a Subtensor chain upgrade; `SzAlpha` trusts return *magnitude* (only direction is guarded). See the bridge X-Ray X-1.

### Baal (Moloch v3 DAO) — `baal/IBaal.sol`, `IBaalToken.sol`, `IBaalSummoner.sol`, `IBaalAndVaultSummoner.sol`

> **Trust: CRITICAL** (`IBaal`). `executeAsBaal(to, value, data)` is a raw arbitrary call *as the DAO avatar*.

- `IBaal` exposes: `ragequit`, `mint/burnLoot`, `mintShares`, `setShamans`, `setAdminConfig`, `executeAsBaal`, proposal lifecycle, plus read getters (`sharesToken`, `avatar`, `totalShares`, lock flags).
- Consumed by: `IBaal` → `supply/szipUSD/ExitGate.sol`. The three summoner/token interfaces are **deploy/test-only** (`script/SummonSubstrate.s.sol`, `test/SummonSubstrate.t.sol`).
- Composability note: `executeAsBaal` is `baalOnly` (avatar) — the whole security model rests on who is the avatar/shaman and whether governance is inert. Worth confirming the ExitGate path can only reach the intended Baal methods.

### Gnosis Safe — `safe/ISafe.sol`, `safe/ISafeProxyFactory.sol`

> **Trust: HIGH.** `execTransactionFromModule` is how enabled modules move Safe funds.

- `ISafe` exposes: `setup`, `enableModule`/`isModuleEnabled`, `execTransactionFromModule`, owner management (`swapOwner`/`add/removeOwner`/`getOwners`/`getThreshold`), `execTransaction`.
- Consumed by: `ISafe` → `supply/szipUSD/DurationFreezeModule.sol`. `ISafeProxyFactory` is **deploy-only** (`script/CreditWarehouseDeployer.sol`, `SummonSubstrate.s.sol`).
- Composability note: the module-exec path is the value seam — every Zodiac module's power is "what the Safe will execute for it." Singleton pinned to SafeL2 1.4.1 @ `0x29fcB4…`.

### Zodiac — `zodiac/IRoles.sol`, `zodiac/IModuleProxyFactory.sol`

> **Trust: HIGH** (`IRoles`). Roles Modifier v2 with `execTransactionWithRole` and **delegatecall-capable** `ExecutionOptions`.

- `IRoles` exposes: `assignRoles`, `execTransactionWithRole`, `scopeTarget`, `scopeFunction` (param-pinned), `allowFunction` (wildcarded — noted as *not* used by the warehouse policy).
- Consumed by: `IRoles` → `supply/CreditWarehouse/WarehouseAdminModule.sol`. `IModuleProxyFactory` is **deploy/test-only** (4 scripts + `DurationFreezeModule.t.sol`).
- Composability note: the interface deliberately includes `scopeFunction` because `allowFunction` skips all param checks — the warehouse must pin receiver/spender/`to`. The delegatecall option (`ExecutionOptions=2/3`) is the sharp edge; worth confirming policy never grants it.

### CoW Protocol — `cow/IGPv2Settlement.sol`

> **Trust: HIGH.** Buy-and-burn approves the `vaultRelayer` and presigns orders.

- Exposes: `domainSeparator`, `vaultRelayer` (the `approve` spender), `setPreSignature`/`preSignature`.
- Consumed by: `supply/szipUSD/SzipBuyBurnModule.sol`.
- Composability note: `setPreSignature`'s `owner` packed in `orderUid` MUST equal `msg.sender`; the risk is the approval to the relayer + order parameters (price/receiver), not the settlement contract itself. Live @ `0x9008D1…` (same all chains).

### Algebra (Integral DEX) — `algebra/IAlgebraPool.sol`, `IAlgebraOraclePlugin.sol`, `ISwapRouter.sol`, `IAlgebraFactory.sol`, `INonfungiblePositionManager.sol`

> **Trust: HIGH** (pricing inputs). Pool reserves/state + plugin TWAP feed NAV.

- Exposes: `swap`/`globalState`/`token0/1`/`plugin` (pool); `getTimepoints`-style TWAP (plugin); `exactInputSingle` (router).
- Consumed by: `IAlgebraPool` → `supply/AlgebraIchiFairLpOracle.sol`, `supply/SzipNavOracle.sol`, `supply/lib/IchiAlgebraFairReserves.sol`; `IAlgebraOraclePlugin` → `SzipNavOracle.sol` + the fair-reserves lib; `ISwapRouter` → `supply/szipUSD/SellModule.sol`.
- **Staged (not yet wired):** `IAlgebraFactory` (build-time pool-address check) and `INonfungiblePositionManager` (reserved for a future range-sell ladder) — referenced by no src/script/test today; intentional forward scaffolding (see file headers + docs/interfaces).
- Composability note: `globalState` spot is the in-block-manipulable input; the fair-reserves lib + TWAP plugin are the mitigations. Pool pinned to HYDX/USDC @ `0x51f0B9…`.

### ICHI (Automated Liquidity Manager) — `ichi/IICHIVault.sol`, `IICHIVaultFactory.sol`, `IICHIDepositGuard.sol`

> **Trust: HIGH** (LP valuation + mint). The vault is the LP token the strategy builds and the oracle prices.

- `IICHIVault` exposes: `deposit`/`withdraw`, `getTotalAmounts`, base/limit position getters, tick bounds, `pool`, `token0/1`, `totalSupply`/`balanceOf`.
- Consumed by: `IICHIVault` → `supply/AlgebraIchiFairLpOracle.sol`, `supply/SzipNavOracle.sol`, `supply/szipUSD/LpStrategyModule.sol`, the fair-reserves lib.
- **Staged (not yet wired):** `IICHIVaultFactory` (create/lookup for the prod vault) and `IICHIDepositGuard` (alternative forwarder) — referenced by no src today; intentional forward scaffolding for the prod ICHI pool (see file headers + docs/interfaces).
- Composability note: this is the **prod** LP path (the demo fork swaps it for a vAMM pair); `getTotalAmounts` at current tick is the valuation seam.

### Hydrex (Solidly-style emissions) — `hydrex/IGauge.sol`, `IOptionToken.sol`, `IVoter.sol`, `IVotingEscrow.sol`, `IRewardsDistributor.sol`, `IVammPair.sol`

> **Trust: MEDIUM–HIGH.** The oHYDX yield + vote-emission loop and the demo vAMM LP.

- Exposes: gauge `deposit`/`withdraw`/`balanceOf`/`earned` (IGauge); option `exercise`/`discount` (IOptionToken); voter/ve/rewards (the 8-B5 harvest-vote loop); `getReserves`/`mint`/`token0/1` (IVammPair).
- Consumed by: `IGauge` → demo forks + `SzipNavOracle.sol`, `HarvestVoteModule.sol`, `LpStrategyModule.sol`; `IOptionToken` → demo oracle + `SzipNavOracle.sol`, `HarvestVoteModule.sol`, `ExerciseModule.sol`; `IVoter`/`IVotingEscrow`/`IRewardsDistributor` → `HarvestVoteModule.sol`; `IVammPair` → the two `hydrex-demo-fork` contracts **only**.
- Composability note: `IVammPair` is exclusively the demo seam (see the hydrex-demo-fork X-Ray). The option `discount()` feeds oHYDX intrinsic value in NAV.

### Euler — `euler/IEulerEarn.sol`

> **Trust: HIGH.** ERC-4626 USDC vault holding senior/warehouse funds; `convertToAssets` is the senior NAV mark.

- Exposes: `deposit`/`redeem`, `convertToAssets`, `balanceOf`, `asset`.
- Consumed by: `supply/ZipDepositModule.sol`, `supply/CreditWarehouse/WarehouseAdminModule.sol`, `venue/EulerVenueAdapter.sol`.
- Composability note: declared locally on purpose (avoids the `euler-earn/` remap's solc-0.8.26 pin / OZ ambiguity). Standard 4626 share-price trust applies.

### Chainlink CCT registry — `bridge/ICctRegistry.sol` (IRegistryModuleOwnerCustom / ITokenAdminRegistry)

> **Trust: MEDIUM** (deploy-time registrar wiring).

- Exposes: token-admin registration surface.
- Consumed by: **deploy-only** (`script/DeploySzAlphaBridge.s.sol`).

---

## Internal Seams (Zipcode's own contracts)

These are intra-protocol interfaces — coupling points, not external trust. Lower attack value, but they define the cross-module contracts an auditor should hold the implementations to.

| Interface | Exposes (gist) | Consumed by (src) |
|-----------|----------------|-------------------|
| `bridge/IXAlphaRate.sol` | `exchangeRate()` | `SzAlpha`, `SzAlphaRateOracle`, `SzipNavOracle`, demo oracle |
| `euler/IZipUSD.sol` | szipUSD mint/burn surface | `supply/ZipRedemptionQueue.sol` |
| `loss/ISzipNavOracle.sol` | NAV read | `loss/DefaultCoordinator.sol` |
| `loss/ILienXAlphaEscrow.sol` | lien/escrow ops | `loss/DefaultCoordinator.sol` |
| `supply/ISzipNavBasket.sol` | basket committed/free value | `supply/szipUSD/DurationFreezeModule.sol` |
| `supply/ISeniorPool.sol` | venue-neutral senior-pool read (`maxWithdraw`/`convertToAssets`/`balanceOf`) with a donation-immunity contract | `SeniorNavAggregator.sol`, `DurationFreezeModule.sol` |

---

## Surface Observations (audit pointers)

- **Verification evidence is the strength, staleness is the risk** — every interface cites a live address + selector + date; none is re-validated at build. An external upgrade (Algebra/ICHI/Euler/Safe/Baal are all live, governed, or upgradeable) can drift from the mirror silently. Worth a periodic `cast`-diff of declared selectors vs live bytecode.
- **Staged interfaces (4):** `IAlgebraFactory`, `INonfungiblePositionManager`, `IICHIVaultFactory`, `IICHIDepositGuard` — declared but referenced by no src/script/test today. These are **intentional forward scaffolding** for the prod ICHI/Algebra LP path + a future range-sell ladder (now labeled `STATUS: STAGED` in each file header and in docs/interfaces). Not dead code — an auditor should treat them as not-yet-live, not as cruft.
- **Sharpest external powers to trace into the consumers:** `IBaal.executeAsBaal` (arbitrary call as DAO → `ExitGate`), `IRoles` delegatecall options (→ `WarehouseAdminModule`), `ISafe.execTransactionFromModule` (→ `DurationFreezeModule` + every module), `IGPv2Settlement` relayer approval (→ `SzipBuyBurnModule`).
- **`ISeniorPool.sol` is a clean pure interface** (3 views + a documented donation-immunity contract) — resolved: an earlier draft flagged a "contract" declaration, but that was a grep artifact from the word "contract" in a NatSpec comment. No logic in the interfaces tree; correctly placed.
- **Local-mirror house style is deliberate and consistent** — the WOOF-00 "[EXT] declare locally, don't import the remap" posture (stated in `IEulerEarn`) avoids solc-version/OZ conflicts. Good hygiene; the cost is manual sync with upstream.

## Takeaway

The interface layer is **well-disciplined, not a weak point** — minimal surfaces, on-chain-verified signatures, clear vendor separation. The real audit work this map points to is in the **implementations** that consume the four sharpest surfaces (Baal, Safe, Roles, CoW) and in keeping the verified selectors current against live external contracts. The 4 staged interfaces are intentional forward scaffolding (now labeled in-file), not cleanup.
