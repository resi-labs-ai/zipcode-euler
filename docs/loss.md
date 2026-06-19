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
Holds each line's xALPHA bond — locks it at origination, returns it on repayment. On a default it slashes part to the treasury Safe (the recovery custody whose off-chain process bridges and liquidates xALPHA → USDC to cover the realized loss) and routes the remainder as the cohort's Duration-Bond premium. Today that remainder goes in-kind to the sidecar Safe; the M2 plan reroutes it to the main Junior Tranche Safe, where the flywheel modules + a CRE flow sell it for zipUSD and fold it back in (see PROGRESS). The escrow itself only moves the xALPHA — never sells or deposits — and it can only ever send to its three fixed destinations, never an arbitrary address.
[contracts/src/loss/LienXAlphaEscrow.sol]
[wires/8-Bx-LienXAlphaEscrow.md]

Interfaces:
[interfaces/interfaces-loss.md]

==================================================================================
References:

- The coordinator drives the escrow and the NAV oracle through narrow interfaces (`ILienXAlphaEscrow`, `ISzipNavOracle`) — see [interfaces/interfaces-loss.md].
- Custody model — cloned (not imported) from 3Jane - [reference/moneymarket-contracts] `InsuranceFund.sol`: one immutable authorized caller + gated transfers, generalized to a pull-in at lock, per-lien bookkeeping, and three fixed destinations.
