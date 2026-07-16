# Zipcode — documentation index

The auditor's front door. Zipcode is a credit protocol on Base (chain 8453, Solidity 0.8.24): a shared senior dollar (zipUSD) backed by isolated credit lines on a lending venue, with a junior first-loss vault (szipUSD) that auto-compounds options yield and absorbs losses before the senior is ever touched.

This page links every contract to its plain-English summary. Start with the three system-wide maps, then drill by subsystem.

## How the docs are layered

Every contract has three views, and they link to each other:

- ELI20 summary (the files linked below, under `docs/`) — what the contract IS and what it's for, in plain words.
- Wiring map (`docs/wires/`) — the code-truth, file-by-file detail; the source of truth, read off the `.sol`.
- Security X-Ray (`contracts/src/**/x-ray/`) — the per-contract security verdict (invariants, guards, test connection, residuals).

Each summary links down to its wiring map and out to its X-Ray; each wiring map links up to the X-Ray verdict. Verdicts run ADEQUATE → HARDENED; every one is capped below a clean bill only by the absence of an external audit (and, for the stateful contracts, a deferred pre-production immutable re-freeze of build-phase wiring).

## Start here — the system-wide maps

- The cross-contract seams — how the subsystems join, and where trust is off-chain — [wires/SYSTEM-SEAM-MAP.md]
- Coverage manifest — every `.sol` under `contracts/` mapped to its doc (provable completeness) — [wires/COVERAGE.md]
- External trust surface — every outside contract the protocol trusts, ranked by blast radius — [interfaces/dependency-surface.md]

==================================================================================
## The senior side — credit lines + the warehouse

zipUSD is the shared senior dollar. USDC supplied by lenders backs isolated credit lines opened on a lending venue; the warehouse custodies the senior backing.

- ZipcodeController — the orchestrator: opens, draws, and closes credit lines on the protocol's instruction, atomically. [ZipcodeController.md]
- The venue layer — opens and runs the actual lines on Euler (the adapter, the venue-neutral interface, the per-line borrower account). [venue.md]
- CREGatingHook — the per-line borrow gate: only the line's own driver may borrow against its collateral. [CREGatingHook.md]
- LienCollateralToken — the 1/1 fixed-supply token that is each line's identity and collateral. [LienCollateralToken.md]
- LienTokenFactory — the caller-bound deterministic minter for those lien tokens (squat-proof, single-use). [LienTokenFactory.md]
- ZipcodeOracleRegistry — the price source for every line's collateral (appraised value minus debt). [ZipcodeOracleRegistry.md]
- WarehouseAdminModule — the senior backing's vault and its four-operation gatekeeper. [supply/CreditWarehouse/WarehouseAdminModule.md]
- ZipDepositModule — the supply entry (the zap): turns USDC into the protocol's supply positions. [supply/ZipDepositModule.md]
- ZipRedemptionQueue — the senior exit: redeems zipUSD for USDC at par, burning as it fills. [supply/ZipRedemptionQueue.md]

==================================================================================
## The junior side — the szipUSD auto-compounder engine

szipUSD is the first-loss junior share. A fleet of keeper-driven modules runs an options-yield flywheel; the gate mints/burns the share and the freeze keeps enough equity locked to back the senior.

Custody, token, and exit:
- ExitGate — custody + issuance + exit; the sole szipUSD minter/burner. [supply/szipUSD/ExitGate.md]
- SzipUSD — the transferable junior share token. [supply/szipUSD/SzipUSD.md]
- SzipBuyBurnModule — the only exit valve: the discounted buy-and-burn bid on CoW. [supply/szipUSD/SzipBuyBurnModule.md]
- DurationFreezeModule — the solvency freeze: keeps junior equity locked above the coverage floor. [supply/szipUSD/DurationFreezeModule.md]

The yield flywheel (keeper-driven modules):
- HarvestVoteModule — claim rewards, permalock vote power, vote, claim rebases. [supply/szipUSD/HarvestVoteModule.md]
- ExerciseModule — pay the strike to turn reward options into liquid HYDX. [supply/szipUSD/ExerciseModule.md]
- SellModule — swap on Algebra (sell HYDX, buy/sell xALPHA), size-capped. [supply/szipUSD/SellModule.md]
- LpStrategyModule — build, stake, and dissolve the zipUSD/xALPHA LP (dissolve is coverage-gated). [supply/szipUSD/LpStrategyModule.md]
- RecycleModule — the free-value ledger: recycle yield into NAV or top up a loss. [supply/szipUSD/RecycleModule.md]
- FarmUtilityLoopModule — the leverage loop that finances the option strikes. [supply/szipUSD/FarmUtilityLoopModule.md]
- OffRampModule — drive the senior redemption queue for the basket's idle zipUSD. [supply/szipUSD/OffRampModule.md]

Engine infrastructure:
- FarmUtilityBorrowGuard — pins the leverage loop's borrow to the engine vault. [supply/szipUSD/FarmUtilityBorrowGuard.md]
- CloneReportReceiver — the clone-safe, fail-closed CRE report intake base. [supply/szipUSD/CloneReportReceiver.md]
- MastercopyInitLock — the mixin that locks each module's master copy. [supply/szipUSD/MastercopyInitLock.md]

==================================================================================
## Pricing & NAV

The oracles both sides read. NAV is a live price the protocol acts on, not a display number.

- SzipNavOracle — the junior vault's NAV-per-share engine (issuance + exit), the economic keystone. [supply/SzipNavOracle.md]
- AlgebraIchiFairLpOracle — the trustless, fully on-chain LP-collateral price. [supply/AlgebraIchiFairLpOracle.md]
- SzipFarmUtilityLpOracle — the keeper-pushed LP-collateral price (deploy default), fail-closed on staleness. [supply/SzipFarmUtilityLpOracle.md]
- IchiAlgebraFairReserves — the manipulation-resistant reserve reconstruction the fair oracle delegates to. [supply/lib/IchiAlgebraFairReserves.md]
- ConcentratedLiquidity — the vendored Uniswap-V3 tick math underneath it all. [libraries/concentrated-liquidity.md]

==================================================================================
## Federation & scaling — running many silos under one senior dollar

- SiloRegistry — the catalog + admission gate: many credit pools under one mutualized senior zipUSD. [SiloRegistry.md]
- SeniorNavAggregator — donation-immune sum of senior backing across silos (solvency telemetry). [SeniorNavAggregator.md]
- ZipcodeDeployAsserts — the deploy-time check that the CRE identity wiring is set before the keys are thrown away. [ZipcodeDeployAsserts.md]

==================================================================================
## The xALPHA bridge

- szALPHA bridge — the cross-chain liquid-staked-ALPHA leg the basket holds and the NAV marks (Bittensor 964 ↔ Base, Chainlink CCT). [bridge.md]

==================================================================================
## Loss handling — the first-loss machinery

- Loss subsystem — recognizes/heals NAV impairment and custodies the per-line xALPHA first-loss bond. [loss.md]

==================================================================================
## External trust — the interface layer

- Dependency surface — the index over every vendor the protocol integrates, ranked by trust. [interfaces/dependency-surface.md]
- Per-vendor summaries: [interfaces/interfaces-bridge.md] (Subtensor + CCT), [interfaces/interfaces-baal.md] (Baal DAO), [interfaces/interfaces-safe.md] (Gnosis Safe), [interfaces/interfaces-zodiac.md] (Zodiac Roles), [interfaces/interfaces-cow.md] (CoW), [interfaces/interfaces-algebra.md] (Algebra DEX), [interfaces/interfaces-ichi.md] (ICHI), [interfaces/interfaces-hydrex.md] (Hydrex), [interfaces/interfaces-euler.md] (Euler), [interfaces/interfaces-loss.md] + [interfaces/interfaces-supply.md] (internal seams).

==================================================================================
## Demo / showcase — outside the audited core

- vAMM auto-compounder demo — surgical forks that show the engine on a live Hydrex vAMM venue before the production pool exists. [hydrex-demo-fork.md]

==================================================================================
## Reference & process docs

- Zodiac Roles + CRE identity wiring (and the order-dependent re-point rule) — [roles.md]
- Safe identities across the system — [safe-identities.md]
- How these docs are written and maintained (authoring handoff) — [doc-writer.md]
