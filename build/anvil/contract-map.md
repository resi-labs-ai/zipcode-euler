# contract-map.md — the live anvil board (REAL-contract deploy)

The full Zipcode protocol, deployed + wired on a **local anvil forking Base mainnet @ block 47096000**
(`script/DeployLocal.s.sol`, real-EE deploy 2026-06-10). This is the address book every smoke-path spec binds to.

> **Real contracts, not mocks.** The senior pool is a REAL EulerEarn pool created off the live factory + curator-
> configured; the base USDC market is a REAL EVK vault; the farm utility market is real EVK; Safe/Baal/Zodiac/CoW/ICHI/
> Hydrex/Algebra/oHYDX/USDC are the live Base bytecode on the fork. Only the IRM (a real 0%-rate contract) and xALPHA
> (an inherent cross-chain stand-in) are local. See "Simulation boundaries" at the bottom.

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
| TimelockController (owns ~everything) | `0x89ae086561ed831C4f5ebF31d825f0364C8c3B27` |

## Venue spine
| Contract | Address |
|---|---|
| ZipcodeController | `0x36025de2F0753789058eAE99003BbE2131b63810` |
| EulerVenueAdapter | `0x87dC8666F0c31Fb4B205240003DD733E327E14F3` |
| ZipcodeOracleRegistry | `0x0395da1BBCD51A0b48EEBf40F4F39E5985d6CA1A` |
| CREGatingHook | `0x16579ac952BBf5cC0844959699A2876eA885808C` |
| LienTokenFactory | `0xbF1801C78593aF0Ef7BcB4415Eaf146993Ec7A01` |

## Supply
| Contract | Address |
|---|---|
| zipUSD (ESynth) | `0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF` |
| szipUSD (junior vault share) | `0x33aD3E23ae6189055925ba2265041AcCA356b4E4` |
| ZipDepositModule | `0x6ecc717266e6FE8d7Ad7608219c30b736eEB728a` |
| ExitGate | `0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e` |
| SzipNavOracle | `0x0C3E77314D97e8e001e0F626A559992479A3C79e` |
| ZipRedemptionQueue | `0x46c89c1a4e86b7F025871c35F08aA7DA95F79D8f` |
| SzipFarmUtilityLpOracle | `0x4505dbe66837804e2bFe068A365B68cA707d0D42` |

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
| Warehouse Safe (EE-share + USDC custodian; EE feeRecipient) | `0xe028616919E7515Ff0Ce4086E9f5Fd4AcfffC68C` |
| WarehouseAdminModule (CRE adapter — SUPPLY/APPROVE/REPAY/REDEEM) | `0xa430221162cf0e20abDab4324CE2F3d5d3391b5c` |

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
| EulerRouter (escrow → LP → lpOracle) | `0x5a451fEB2Ef43B3615f1eaFba352B7b363d0629f` |

## Engine modules (zodiac proxies, all Timelock-owned; operator = `creOperator`)
| Module | Address | Enabled on |
|---|---|---|
| SzipBuyBurnModule | `0x12881a80c4f4eee7430d1c1c53bbbcfc4c92f71b` | main Safe |
| FarmUtilityLoopModule | `0x61cdc9c8839753f520cc9dc4f2a733e132fe10e4` | main Safe |
| LpStrategyModule | `0xc242eaeb8e0647ef49a97ed827059786446f3c5c` | main Safe |
| HarvestVoteModule | `0x38d549cdaf088f68f549d85c0ba390005ff087ec` | main Safe |
| ExerciseModule | `0x8a80b821f6fe43b94e84a1ed245276964e52c9d1` | main Safe |
| SellModule | `0xbc8e1b79f9321d33266e1f8da594e238439a78e2` | main Safe |
| RecycleModule | `0x0c4c63843f2607ce58ac31ebb8a86d28aadbbc4e` | main Safe |
| OffRampModule | `0xc595aa93d9ba00726efd1741255961df72e49998` | main Safe (rq) |
| DurationFreezeModule | `0x66e0e34254727954cc7137ea58b851d99d438485` | main + sidecar |

## Loss side
| Contract | Address |
|---|---|
| DefaultCoordinator | `0xb6366c0db8f31319e6fc6b28c6f6304064657e99` |
| LienXAlphaEscrow | `0xfba6a2f082ca39552725cb9190754c2f4c525468` |

## Bridge
| Contract | Address |
|---|---|
| SzAlphaRateOracle | `0x7251a305fe860099cdc842fcfbde8ab6002afe72` |

## Local stand-ins (only these are non-real, by necessity)
| Stand-in | Address | Why local |
|---|---|---|
| xALPHA mirror (MockERC20, 18dp, mintable) | `0xF6CAAF72A788916915ce1bF111E245e0bEABCd18` | cross-chain asset (subnet 964→Base via CCIP), not yet bridged |
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
| `SzipNavOracleDemoVAMM` | `0xF84eF3BA83BB62C88502241B878983D79708e371` | prices the vAMM HYDX/USDC LP (HYDX via the pushed `LEG_HYDX_USD`, USDC $1 6→18dp); owner = team; CRE identity = the real sealed `0x90F7…`/`0x…01` |
| `LpStrategyModuleDemoVAMM` | `0xB76FfBa3d1973f61b0E2e3b09536B15283e18dFC` | `addLiquidity` = `pair.mint`; stake/unstake unchanged; **enabled on the main Safe**; owner = team, operator = `creOperator` |
| vAMM HYDX/USDC pair (LP token) | `0x605abD1873737CA9a9Ec1CFa52CDfc8ef62c2E1d` | live Solidly `VolatileV1 AMM - HYDX/USDC` (reserves: HYDX 18dp / USDC 6dp) |
| vAMM gauge (vault-keyed; rewards oHYDX) | `0x2dA5744C7205ae9CacBB1AB8a72A2fA3896d39F8` | alive; standard `deposit/withdraw(uint256)`; emissions stream is live on mainnet, dormant on a frozen fork |

## Simulation boundaries (the outside world being absent on a fork — NOT mocks of our machinery)
1. **CRE reports** — impersonate the real Forwarder `0xF834…4482`; receiver decode/validate is 100% real.
2. **xALPHA** — stand-in ERC20 (no real Base asset pre-bridge).
3. **CoW order fill** — settlement + our pre-signature are real; the solver match is simulated by delivering szipUSD.
4. **Proof-of-Value collateral** — mocked per §17.
