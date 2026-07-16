# LOSS
[zipcode-euler/contracts/src/loss]

The first-loss / insurance side of the protocol. Base (chain 8453). Solidity 0.8.24.

* Each line of credit is backed by a slashable xALPHA first-loss bond.
* On a default, two things happen: NAV is marked down by the recognized loss, and the bond is slashed as partial insurance.
* Chainlink CRE administrates pricing and insurance.

* TODO — Still need to build CRE Workflows.
* TODO — Need to set addresses for where the xALPHA bond is routed on default.

==================================================================================
This is a CRE gated contract group which digests loans which have been marked as defaulted.

- DefaultCoordinator.sol → the loss orchestrator
A CRE-gated contract which marks losses and routes the xALPHA bond on a default. It is the only contract that can write the NAV impairment provision — the explicit loss markdown.
[contracts/src/loss/DefaultCoordinator.sol]
[wires/DefaultCoordinator.md]

- LienXAlphaEscrow.sol → the per-line xALPHA first-loss bond custody
Holds each line's xALPHA bond — locks it at origination, returns it on repayment. On a default it slashes part to the treasury Safe (the recovery custody whose off-chain process bridges and liquidates xALPHA → USDC to cover the realized loss) and routes the remainder as the cohort's Duration-Bond premium. That remainder now goes to the main Junior Tranche Safe (CTR-11), where the yield flywheel subsumes it — it lands as free, liquid value the sell and LP modules fold back into the basket, lifting junior NAV per share. The slash-triggered CRE flow that actually drives it is still M2; CTR-11 only sets the destination. It used to go to the juniorTrancheSidecar Safe, where no module could reach it and it sat inert. The escrow itself only moves the xALPHA — never sells or deposits — and it can only ever send to its three fixed destinations, never an arbitrary address.
[contracts/src/loss/LienXAlphaEscrow.sol]
[wires/8-Bx-LienXAlphaEscrow.md]

Interfaces:
[interfaces/interfaces-loss.md]

==================================================================================
Security X-Ray (audit fidelity)

Both contracts have dedicated, test-connected X-Rays under contracts/src/loss/x-ray/. Both are rated ADEQUATE (a hair from HARDENED) — the strongest-tested scope reviewed: unit + stateless fuzz + Foundry invariants on both (DefaultCoordinator 66u+1f+3i, LienXAlphaEscrow 44u+1f+2i + a 5-test reentrancy battery). The X-Rays are the authoritative security artifact; the wires summaries below are the code-truth wiring maps.

[contracts/src/loss/x-ray/x-ray.md] — scope-level overview + verdict
[contracts/src/loss/x-ray/DefaultCoordinator.md]
[contracts/src/loss/x-ray/LienXAlphaEscrow.md]

The load-bearing properties an auditor should check (full catalog + test connection live in the X-Rays):

* Conservation (I-1 + the sole-writer seam) — totalProvision == Σ per-lien provision == SzipNavOracle.provision(). The coordinator is the ONLY writeProvision caller, and it pushes after every change. This is the load-bearing invariant; it is fuzz + invariant asserted.
* I-2 — a default marks the provision DOWN only by atRisk·(1−recoveryFloor), rounded down (never over-marks); it heals UP only by realized receipts, or fully to 0 on a clean Resolve. recoveryFloor is not retroactive.
* I-4 — the lien status machine (None→Bonded→{None|Defaulted}, Defaulted→{Resolved|WrittenOff}) has no reverse or re-entry; WriteOff deliberately leaves the residual provision in place as the realized loss.
* I-5 — the escrow holds exactly Σ bondAmount and uses RECORDED amounts, never balanceOf, so it is donation-immune.
* Escrow theft-immunity (destination integrity) — NO state-changer takes a recipient parameter; xALPHA can only ever flow to three fixed sinks (recorded bondOriginator / adminSafe / juniorTrancheSafe).
* X-1 (top residual, on-chain=No) — the §13 CRE trust ceiling: the coordinator BOUNDS AND ROUTES, it does not validate that a default is real. The CRE (DON consensus, behind the Forwarder) is trusted for magnitude/timing/split/originator; a compromised CRE can grief (down-mark NAV, slash a healthy bond, reclaim a fresh bond via a hostile originator) but CANNOT steal to an arbitrary address or inflate NAV.
* X-2 (build-phase, on-chain=No) — destination integrity is absolute only after the pre-prod immutable re-freeze: the sinks (adminSafe/juniorTrancheSafe) and the wiring are Timelock-settable during the build phase, so the theft-immunity absolute is conditional until that process step ships. The owner has no sweep, pause, or NAV-inflation power either way.

==================================================================================
How the loss side connects to the rest of the protocol

* It writes NAV. The coordinator is the sole writeProvision caller into SzipNavOracle (8-B4) — a default instantly down-marks junior NAV (unsmoothed, accepted by design). This is the loss→NAV seam; it is CRE-Forwarder-gated (system seam S4), the same Forwarder pattern the bridge rate oracle and the engine modules sit behind.
* The bond IS the bridged xALPHA. The first-loss collateral the escrow custodies is the Base SzAlphaMirror from the bridge subsystem (a plain hookless/feeless BurnMintERC20 — which is exactly why the donation-immune recorded-amount accounting is safe). Re-pointable via setXAlpha.
* The slash feeds the junior flywheel. On default the capital portion routes to the treasury/adminSafe (off-chain bridged + liquidated xALPHA→USDC to cover the realized hole) and the cohort premium routes to the main Junior Tranche Safe (CTR-11), where the sell/LP modules fold it into the basket and lift junior NAV per share. The slash-driving CRE flow is still M2.

[wires/SYSTEM-SEAM-MAP.md] — the cross-contract seam catalog (loss appears as X-1/X-2; the CRE Forwarder is S4)
[wires/8-B4-SzipNavOracle.md] — the NAV oracle that consumes the provision
[bridge.md] — the source of the xALPHA bond (SzAlphaMirror)

==================================================================================
References:

- The coordinator drives the escrow and the NAV oracle through narrow interfaces (`ILienXAlphaEscrow`, `ISzipNavOracle`) — see [interfaces/interfaces-loss.md].
- Custody model — cloned (not imported) from 3Jane - [reference/moneymarket-contracts] `InsuranceFund.sol`: one immutable authorized caller + gated transfers, generalized to a pull-in at lock, per-lien bookkeeping, and three fixed destinations.
