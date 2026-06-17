# INTERFACES — LOSS
[zipcode-euler/contracts/src/interfaces/loss]

Two internal interfaces the loss coordinator uses to drive other in-repo contracts. Base (chain 8453). Solidity 0.8.24.

==================================================================================
Interface → What it is

Note: both are internal — they point at our own contracts (the bond escrow and the NAV oracle), not outside protocols. The coordinator talks to them through narrow interfaces so it doesn't compile against the whole escrow or oracle.

- ILienXAlphaEscrow.sol → the xALPHA bond escrow
The bond lifecycle the loss coordinator drives: lock a bond when a credit line opens, release it on repay, or slash it (to capital, or to the cohort) on a loss. DefaultCoordinator is the only caller, and the bond can only move to the recorded originator or the fixed sinks — never to an arbitrary address.
[contracts/src/loss/DefaultCoordinator.sol]
[wires/DefaultCoordinator.md]

- ISzipNavOracle.sol → the NAV oracle's provision writer
A one-function write seam: push the impairment provision into the NAV oracle, which marks the basket down. DefaultCoordinator pushes it after every provision change. The size limit is enforced in the coordinator, not the oracle.
[contracts/src/loss/DefaultCoordinator.sol]
[wires/DefaultCoordinator.md]

Summaries:
[../wires/interfaces-loss.md]

==================================================================================
References:

- LienXAlphaEscrow — [contracts/src/loss/LienXAlphaEscrow.sol] implements the bond seam.
- SzipNavOracle — [contracts/src/supply/SzipNavOracle.sol] implements `writeProvision` (sole writer = the coordinator; unset coordinator means it reverts for everyone).
