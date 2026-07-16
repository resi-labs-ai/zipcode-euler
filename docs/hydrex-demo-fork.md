# HYDREX DEMO FORK
[zipcode-euler/contracts/src/hydrex-demo-fork]

* This demo is meant to test out the auto-compounder on an Anvil fork of Base, using an existing Hydrex vAMM HYDX/USDC pool.
* An existing pool means that we can test the oHYDX redemption path inside of the auto-compounder.
* The mainnet version can be deployed after the vAMM szALPHA/zipUSD pool is live, with the Ichi strategy enabled.

Base (chain 8453). Solidity 0.8.24.

* Deploy and Test on Anvil.
* Hook up Zodiac `enableModule` to the existing engine Safe.
* Speak with Hydrex about setting up the szALPHA/zipUSD vAMM pool, and Ichi strategy.

==================================================================================
Contract → Chain

These are meant to price, and deposit, and farm the HYDX/USDC vAMM pool on the Anvil fork of Base.

- SzipNavOracleDemoVAMM.sol → Base 8453
A fork of SzipNavOracle (8-B4). Identical except the LP-leg valuation: it prices a live Solidly vAMM pair via `getReserves()` (+ HYDX/USDC pricing) instead of an ICHI vault.

- LpStrategyModuleDemoVAMM.sol → Base 8453
A fork of LpStrategyModule (8-B6). Identical except `addLiquidity`: it builds vAMM LP by transferring both legs to the pair → `IVammPair.mint` (routerless, no approval) instead of an ICHI deposit. `stake`/`unstake` unchanged.

Interface:
IVammPair.sol → Base 8453
The minimal Solidly pair interface (the pair IS its own LP token). Verified against the live vAMM HYDX/USDC pair.

Deployment:
DeployShowcaseVAMM.s.sol — run AFTER the main deploy (DeployLocal/DeployZipcode), as the team.

Summaries:
[wires/SHOWCASE-VAMM.md]

==================================================================================
Security X-Ray (audit fidelity)

Both forks have dedicated, test-connected X-Rays under contracts/src/hydrex-demo-fork/x-ray/. Both are rated ADEQUATE — but note both self-declare DEMO/SHOWCASE, outside the audited core. Their prod parents' suites were ported with the swapped seam mocked (ICHI → vAMM pair); the demo suites run 21/21 + 24/24 green (LpStrategyModuleDemoVAMM.t.sol + SzipNavOracleDemoVAMM.t.sol). The X-Rays are the authoritative security artifact; the wires summary below is the code-truth wiring map.

[contracts/src/hydrex-demo-fork/x-ray/x-ray.md] — scope-level overview + verdict
[contracts/src/hydrex-demo-fork/x-ray/SzipNavOracleDemoVAMM.md]
[contracts/src/hydrex-demo-fork/x-ray/LpStrategyModuleDemoVAMM.md]

The load-bearing properties an auditor should check (full catalog + test connection live in the X-Rays):

* I-1 — NAV prices the RAW balanceOf of the engine Safes, so a direct transfer into a counted Safe moves NAV with no deposit. The ExitGate's denominator (out of scope) is the only thing tying balances back to issued shares.
* I-2 — the vAMM LP leg is valued at SPOT via IVammPair.getReserves(), manipulable in-block. The only defense is the navEntry = max(spot, twap) / navExit = min(spot, twap) bracket; the LP leg must flow through the TWAP for the bracket to actually fence an in-block reserve push.
* X-1 (top residual, on-chain=No) — writeProvision accepts any value from the DefaultCoordinator; the impairment bound (down ≤ atRisk·(1−floor)) lives off-chain in the coordinator, not at the oracle. The oracle must never be wired before the coordinator exists (fail-closed until then).
* E-1 — the bracket must be non-profitable: you can never mint at a price below what you exit at.
* Blast radius is bounded: the LP module holds NO custody and builds only fixed-shape Safe calls — a compromised CRE operator can grief the LP build ratio (bounded by minShares) but cannot drain. These residuals are inherited from the prod NAV design, not introduced by the forks.

==================================================================================
How the demo connects to the rest of the protocol

This is a showcase layer enabled ON the existing prod system, not a separate one:

* The demo LP module is enableModule'd on the SAME engine (main) Safe as the prod modules; the demo oracle reads the same Safe(s). Retire by disableModule — the prod oracle and modules stay wired and untouched.
* The demo oracle consumes the SAME prod CRE leg feed (reportType 7, sealed author/workflowName per CTR-16) for the HYDX/USD mark that prices the LP's HYDX reserve.
* setXAlphaRateOracle MUST be wired to the Base SzAlphaRateOracle (8x-02) — otherwise grossBasketValue reverts on the sidecar's xALPHA leg (the fallback mock mirror has no exchangeRate()). This is the same cross-chain rate seam the bridge feeds.
* It is INVISIBLE to the prod oracle: the vAMM pair + gauge are different addresses than the prod oracle's wired ICHI vault, so grossBasketValue is unaffected (the SP-06 trap avoided).
* Consumers (ExitGate) read navEntry/navExit/fresh exactly as they do off the prod oracle; provision is written by the DefaultCoordinator.

The full cross-contract seam catalog and the prod parents this forks:
[wires/SYSTEM-SEAM-MAP.md]
[wires/8-B4-SzipNavOracle.md] — the prod NAV oracle this forks
[wires/8-B6-LpStrategyModule.md] — the prod LP-strategy module this forks
[wires/DefaultCoordinator.md] — the provision writer
[wires/ExitGate-szipUSD.md] — the NAV consumer / first-depositor guard

==================================================================================
References:

The two forks are built on the prod contracts they mirror + the existing Hydrex venue.

[contracts/src/supply/SzipNavOracle.sol]
[wires/8-B4-SzipNavOracle.md]
The prod NAV oracle this forks. Everything but the LP-leg valuation is byte-identical.

[contracts/src/supply/szipUSD/LpStrategyModule.sol]
[wires/8-B6-LpStrategyModule.md]
The prod LP-strategy module this forks. Everything but the LP-mint seam is byte-identical.
