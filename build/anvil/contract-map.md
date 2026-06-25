# contract-map.md — the live anvil board (REAL-contract deploy)

The Zipcode protocol, deployed + wired on a **local anvil forking Base mainnet @ block 47096000**
(`script/DeployLocal.s.sol`). This is the address book every smoke-path spec binds to.

> **Scope:** a single-silo local board. The federation catalog (`SiloRegistry`) is deployed + wired by this script
> (the CTR-03 routing fix, below), and the senior-solvency telemetry aggregator (`SeniorNavAggregator`, CTR-05) is now
> deployed too — pointed at the live registry + zipUSD, so it sums the one registered silo (`LOCAL_SILO_ID`). On a
> fresh board `seniorBacking()` reads 0 and `systemCollateralization()` reads `uint256.max` (no senior par supplied,
> no zipUSD minted yet); both move once a CRE SUPPLY report seeds EE shares into the warehouse Safe.
> **Last broadcast 2026-06-24** (fresh re-broadcast from HEAD source on a clean anvil @ 47096000), now including the
> CTR-05 `SeniorNavAggregator` (newly wired into the deployer, deployed LAST in the main sequence so no earlier CREATE
> moved). Every other main-protocol + runtime-created address is byte-for-byte identical to the prior board, and the
> on-chain runtime bytecode equals the HEAD artifacts (verified). The `build/anvil/abi/` ABIs were regenerated from the
> same HEAD source in lockstep. **The two SHOWCASE demo addresses AND the `WarehouseAdminModule` adapter moved** —
> all three are nonce-dependent (the demos trail the `team` nonce; the warehouse adapter is a plain `new` inside
> `CreditWarehouseDeployer`, non-deterministic across deploys — old smoke specs used yet another address). **Re-derive
> these three from `broadcast/DeployLocal.s.sol/8453/runLocal-latest.json` after every deploy**; the rest of the board
> is deterministic. (Prior 2026-06-22 SIZE-01 note: `EulerVenueAdapter` trimmed under EIP-170 to 24054 / +522 margin.)

> **Real contracts, not mocks.** The senior pool is a REAL EulerEarn pool created off the live factory + curator-
> configured; the base USDC market is a REAL EVK vault; the farm utility market is real EVK; Safe/Baal/Zodiac/CoW/ICHI/
> Hydrex/Algebra/oHYDX/USDC are the live Base bytecode on the fork. Local to us: our two own rate models (ZeroIRM
> 0% for the farm-utility vault, LineIrm ~7.5% APR for credit lines — both real contracts, not stand-ins) and the
> xALPHA stand-in (an inherent cross-chain placeholder). See "Simulation boundaries" at the bottom.

## Connection
- RPC: `http://127.0.0.1:8545` · chainId `8453` (Base mainnet fork) · fork block `47096000`

## Principals (anvil deterministic dev accounts)
| Role | Address | Private key |
|---|---|---|
| `team` (broadcaster; Safe owner on both Safes; EE pool owner) | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |
| `godOwner` (warehouse Safe/Roles owner) | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| `creOperator` (engine-module operator; queue settle controller; **windowController**) | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |
| `workflowAuthor` (CRE workflow owner, all receivers) | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | `0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6` |
| `erebor` (draw off-ramp) | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` | `0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a` |
| `capitalSink` (loss-side xALPHA sink) | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` | `0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba` |

CRE identity sealed on every receiver: `workflowId = 0x…01`, author = `workflowAuthor`. CRE Forwarder (only legal
report pusher) = `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` — impersonate via `anvil_impersonateAccount` to push.

## Roots
| Contract | Address |
|---|---|
| TimelockController (owns ~everything) | `0x0395da1BBCD51A0b48EEBf40F4F39E5985d6CA1A` |

## Venue spine
| Contract | Address |
|---|---|
| ZipcodeController | `0x5bF6a1503F6A0f43Cf16f417FB033A9d3677dF01` |
| EulerVenueAdapter | `0x36025de2F0753789058eAE99003BbE2131b63810` |
| ZipcodeOracleRegistry | `0xbF1801C78593aF0Ef7BcB4415Eaf146993Ec7A01` |
| CREGatingHook | `0x87dC8666F0c31Fb4B205240003DD733E327E14F3` |
| LienTokenFactory | `0x16579ac952BBf5cC0844959699A2876eA885808C` |
| LineIrm (CTR-13 ~7.5% APR rate model; the adapter installs it on each credit line's borrow vault) | `0xF6CAAF72A788916915ce1bF111E245e0bEABCd18` |

## Federation / routing (CTR-02/03)
| Contract | Address | Notes |
|---|---|---|
| SiloRegistry | `0x86C2ba30C5Ce01479eF797897FAA6791402FeDf2` | the controller routes every origination through it (`venueOf(siloId)`); without it `_origination` reverts `RegistryUnset`. This board registers ONE silo: `LOCAL_SILO_ID = keccak256("ZIPCODE_SILO_0") = 0x0309d2cf8d22de7d0626162a4ba1d7bff931531432937d085bcaf163f0febebd`. The origination CRE report (reportType 1) MUST carry this siloId as its 8th payload field. |
| SeniorNavAggregator (CTR-05) | `0x10Fff7de38A99e5f7F86E982d5dF1B0ECE7f5b01` | senior-solvency telemetry: Σ donation-immune senior par-backing (`convertToAssets(balanceOf(warehouseSafe))`) over every registered silo. Reads the `SiloRegistry` above + zipUSD; owner=Timelock. Not a price oracle. `seniorBacking()`/`systemCollateralization()` are live; 0 / `uint256.max` on a fresh board until senior par is supplied. |

## Supply
| Contract | Address |
|---|---|
| zipUSD (ESynth) | `0xabe34eC6072F35F956450159D7238bCB719Fde6a` |
| szipUSD (junior vault share) | `0x783A08cb688a94cb6bCaE9f74eDe6762b44f3ACd` |
| ZipDepositModule | `0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e` |
| ExitGate | `0xB8fB416FbF1cfd793eCacF9135174bEf92a4b97F` |
| SzipNavOracle | `0x33aD3E23ae6189055925ba2265041AcCA356b4E4` |
| ZipRedemptionQueue | `0x7b5C04034b6531C36E0F10890056D95F6f6153F9` |
| SzipFarmUtilityLpOracle | `0xc933fc2f0d97a14e08071778F6F2AA83ECb1309b` |

## Baal substrate (junior vault)
| Piece | Address |
|---|---|
| Baal DAO (Moloch v3) | `0xdc4f3Bb2789786b06748179e913F43AfbdcF65Dd` |
| main Safe (FREE equity / avatar / "rq") | `0x0B9C95c7fc6048Bd4B568b637707D7dC5381B2ac` |
| sidecar Safe (COMMITTED / structural freeze / "non-rq") | `0x39D229610e52A1229cF5728CAb0A862F650AF6f0` |
| Loot (soulbound, gate-held) | `0xE7501dD9Df8c91b2447b6C3C048c814aFf7354fD` |
| Shares (0 forever) | `0xc25dD44A01100d56D58c8AD33a050f56278E4B58` |

## Credit warehouse (senior)
| Piece | Address |
|---|---|
| Warehouse Safe (EE-share + USDC custodian; EE feeRecipient) | `0x7975E1eFB09690E42C5B574B1768cdFA11e8693c` |
| WarehouseAdminModule (CRE adapter — SUPPLY/APPROVE/REPAY/REDEEM; the sole Roles role-member) | `0x24D7910DCaF4cd27F07e877C588F8EEA0e992A3a` |
| Roles modifier (Zodiac Roles-v2 proxy; `avatar==target==`Warehouse Safe, owner=`godOwner`; the WarehouseAdminModule is its sole role member — this scope config is the real param-pinning, per SEAM-MAP S11) | `0x2f1f2e5cCB88E0B543A5d3B6c8e0095c754FE984` |

## Senior pool — REAL EulerEarn (8-Bw)
| Piece | Address | Config |
|---|---|---|
| EulerEarn pool (USDC) | `0x1a7A8A5a6A2B34895201CFBC997C4eC419ba8A3d` | owner=team, **curator=adapter**, timelock 0, fee 0, feeRecipient=warehouse Safe |
| base USDC market (resting; supply-queue head) | `0x3A48aaaa90CF3938290f12F6A1E58C1aeb54699D` | onboarded cap=uint136.max, enabled, supplyQueue[0] |
| farm utility borrow vault also onboarded | (see below) | cap=uint136.max, enabled (for SP-15 reallocate→utilization) |

## Farm utility market (EVK, 8-B5)
| Piece | Address |
|---|---|
| borrow vault (USDC) | `0x1aFc8c641BE6E8a0849f00f3c90a27D44710D267` |
| escrow vault (LP collateral) | `0x8A5FA36779693584E0e52246f05C5b0bF55Df1b1` |
| EulerRouter (escrow → LP → lpOracle) | `0x83cf98139A35830C90aa28f9e9abf198Fcf6A795` |
| FarmUtilityBorrowGuard (OP_BORROW hook on the borrow vault; pins borrowing to the engine Safe) | `0x3b7ca6e87a2536DEB720eBd6eD3B348738F1fAa3` |

## Engine modules (Zodiac module CLONES, all Timelock-owned; operator = `creOperator`)
> **IMPORTANT (2026-06-24 correction):** each engine module is deployed as a **mastercopy** (deployed once, listed in
> the `Mastercopy` column / `abi/index.json`'s old values) and then **EIP-1167-cloned + initialized + `enableModule`'d**
> on the Safe. **The clone is the live, functional module** (operator/avatar/target set, enabled); the mastercopy is
> inert (`operator()==0`, not enabled). **Bind to the `Clone` address.** The ABI is identical (the clone delegates to
> the mastercopy), so `abi/*.json` is unchanged. Clones are nonce/salt-dependent — **re-derive each deploy** from the
> Safe's module list: `getModulesPaginated(0x1, 50)` on the main Safe `0x0B9C…`, then match each clone's EIP-1167
> implementation target to the `Mastercopy` column below.

| Module | Clone (live — call this) | Enabled on | Mastercopy (ABI ref / inert) |
|---|---|---|---|
| SzipBuyBurnModule | `0x8B7B057bB2B9A7F06929BdB89132005C1Fafd294` | main Safe | `0x9a59A47A42fb5D951c599BE0C9Af008D93ebe831` |
| FarmUtilityLoopModule | `0xea9b76bB08d14E40f04409393B1F113E4999Efb2` | main Safe | `0xa61c6B0E0CbA10Dad5ac06325ab95E5246c48DC2` |
| LpStrategyModule | `0x25cf123dB6700650aC387515519c287031c48aD8` | main Safe | `0x897d82285833933A79e2A3daC4759a7C47B0044e` |
| HarvestVoteModule | `0xf1DEbc425Da983d08FC713a06E655D1018556C1e` | main Safe | `0x2246C8b9756b255DBBEb50eb6f13511B93Eb13ee` |
| ExerciseModule | `0xaD54085b62Ef94923f980314444b63c526Aac4e2` | main Safe | `0x10aa41B6A18FD128568D5e92012Fba4C6fE45f0f` |
| SellModule | `0x1fCe5c71C12E5786A9966455375Cdb2843B8BEAa` | main Safe | `0xEbbB5EA0C4e3E719D5125002c8f91bCCD0B8913E` |
| RecycleModule | `0x28b0109B3ac79fA14F2E1914D44872BD6b32B97f` | main Safe | `0x953e739AcD9a07B1Aa8d6e1F04a6B7e7BEAf7b5b` |
| OffRampModule | `0x2e0Ba43db83E0D3bBc2537836955890F3fAA7434` | main Safe (rq) | `0xA444F4653A4DFd06FA6C7128e9A714c68EebF55D` |
| DurationFreezeModule | `0x3Bcd8BD1282B083C10bdba2a5E205Bc9A094f2FE` | main + sidecar | `0x675fdf5507b337cA98E3B40B59462B37A8DC050b` |

## Loss side
| Contract | Address |
|---|---|
| DefaultCoordinator | `0xAC07DBEEf61E773fc4d745EA83b70D7A18263a01` |
| LienXAlphaEscrow | `0x97Fe77c24831ee77D6Fb4923aEd8138D7A79f02E` |

## Bridge
| Contract | Address |
|---|---|
| SzAlphaRateOracle | `0x46C89c1A4E86b7F025871C35f08aa7da95F79d8f` |

## Local stand-ins (only these are non-real, by necessity)
| Stand-in | Address | Why local |
|---|---|---|
| xALPHA mirror (MockERC20, 18dp, mintable) | `0x237C95e376FCA422316a18264936C426BBc686B6` | cross-chain asset (subnet 964→Base via CCIP), not yet bridged |
| ZeroIRM (0%-rate, real contract) | `0xAF5C4Ff1CA534F6e8527Eaf448db7d30bf9d6d5E` | a real IRM; 0% is a valid config |

## Live Base externals it is wired to
| External | Address |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| CRE KeystoneForwarder | `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` |
| EVC | `0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989` |
| EVK GenericFactory | `0x7F321498A801A191a93C840750ed637149dDf8D0` |
| EulerEarn factory | `0x75F49a2621b6DeC6a5baB22ce961bF3e676EFAE6` |
| CoW GPv2Settlement | `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` |
| Algebra SwapRouter (Hydrex) | `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e` |
| POL ICHI vault (WETH/USDC) | `0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad` |
| POL Hydrex ALM gauge (vault-keyed; rewards oHYDX) | `0x4328CE8ADC23F1c4E5A3049F63Ffbdd8e73F99Ce` |
| HYDX / oHYDX | `0x00000e7efa313F4E11Bfff432471eD9423AC6B30` / `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78` |

## Showcase / demo — vAMM auto-compounder (deployed by `script/DeployShowcaseVAMM.s.sol`, run AFTER the main deploy)
> **Outside the audited core.** A mainnet-showcase of the auto-compounder running against an EXISTING live venue (the
> vAMM HYDX/USDC pair + its gauge), so it can run BEFORE the real zipUSD/xALPHA ICHI pool exists. Forks of the verified
> `SzipNavOracle`/`LpStrategyModule` with ONLY the LP-leg seam changed. Enabled on the SAME engine (main) Safe via
> Zodiac `enableModule` (alongside the prod modules); retire by `disableModule` + pulling the LP out. Tickets:
> `build/wires/SHOWCASE-VAMM.md`; tested by **SP-18**.

| Piece | Address | Notes |
|---|---|---|
| `SzipNavOracleDemoVAMM` | `0xD74712fF21f9AB9468F9A2a99D7b4A20A1E05B58` | prices the vAMM HYDX/USDC LP (HYDX via the pushed `LEG_HYDX_USD`, USDC $1 6→18dp); owner = team; CRE identity = the real sealed `0x90F7…`/`0x…01` |
| `LpStrategyModuleDemoVAMM` | `0x17627cbB95CE6f5b535A32432e082D5723818AF6` | `addLiquidity` = `pair.mint`; stake/unstake unchanged; **enabled on the main Safe**; owner = team, operator = `creOperator` |
| vAMM HYDX/USDC pair (LP token) | `0x605abD1873737CA9a9Ec1CFa52CDfc8ef62c2E1d` | live Solidly `VolatileV1 AMM - HYDX/USDC` (reserves: HYDX 18dp / USDC 6dp) |
| vAMM gauge (vault-keyed; rewards oHYDX) | `0x2dA5744C7205ae9CacBB1AB8a72A2fA3896d39F8` | alive; standard `deposit/withdraw(uint256)`; emissions stream is live on mainnet, dormant on a frozen fork |

## Simulation boundaries (the outside world being absent on a fork — NOT mocks of our machinery)
1. **CRE reports** — impersonate the real Forwarder `0xF834…4482`; receiver decode/validate is 100% real.
2. **xALPHA** — stand-in ERC20 (no real Base asset pre-bridge).
3. **CoW order fill** — settlement + our pre-signature are real; the solver match is simulated by delivering szipUSD.
4. **Proof-of-Value collateral** — mocked per §17.
