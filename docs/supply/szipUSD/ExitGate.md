# SZIPUSD ENGINE — ExitGate
[zipcode-euler/contracts/src/supply/szipUSD]

The custody, issuance, and exit core of the junior vault. Base (chain 8453). Solidity 0.8.24.

* It is the only contract that can mint or burn szipUSD, and the only holder of the vault's underlying Baal governance tokens.
* Deposit: it prices the deposited asset off the entry NAV (rounding down, in the vault's favor), routes the asset straight into the basket, and mints szipUSD to the depositor.
* Exit: there is no in-kind drain. Exiting means selling szipUSD on CoW; the bought tokens are then retired here. The old forfeiting exit queue is gone.
* Deposits are open to anyone; the retire step is keeper-only.

==================================================================================
What it does

- ExitGate.sol → mint/burn gate and basket custody
Mints szipUSD on deposit and burns it on the buy-and-burn retire, pairing each szipUSD mint or burn one-for-one with the matching Baal token so the two supplies always agree. It never issues the ragequit-bearing governance shares and wires no ragequit path, so depositors cannot drain the basket in kind. Issuance fails closed on a stale or unseeded price and is capped by a total-value ceiling.
[contracts/src/supply/szipUSD/ExitGate.sol]
[../../wires/ExitGate-szipUSD.md]

Summaries:
[../../wires/ExitGate-szipUSD.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE (a hair from HARDENED) — the sole minter/burner, tested against the real Baal substrate and the real NAV oracle: 17 fork unit tests plus a stateful invariant.

[contracts/src/supply/szipUSD/x-ray/ExitGate.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The core safety property is two-token conservation: szipUSD total supply always equals the Baal tokens the gate holds, because every mint or burn is paired. It is now under a fuzzed stateful invariant against the real Baal and oracle (~6,400 calls, zero violations).
* No ragequit and no share-minting are reachable — confirmed by reading the code; exit is the CoW buy-and-burn rail by design.
* Issuance is NAV-proportional and rounds down in the vault's favor; the gate keeps zero custody (the deposited asset routes straight to the basket); a stale or unseeded price pauses deposits.
* Residual (off-chain): build-phase wiring awaits the pre-production immutable re-freeze. A few negative revert paths aren't directly exercised, but the read code is sound.

==================================================================================
References:

- It mints/burns the user token — [contracts/src/supply/szipUSD/SzipUSD.sol] ([SzipUSD.md]).
- It prices deposits off the NAV oracle — [contracts/src/supply/SzipNavOracle.sol] ([../../wires/8-B4-SzipNavOracle.md]).
- It holds Baal governance tokens through the Baal interface — [contracts/src/interfaces/baal/IBaal.sol] (see [../../interfaces/interfaces-baal.md]).
- The retire step is fed by the buy-and-burn module — [contracts/src/supply/szipUSD/SzipBuyBurnModule.sol] ([SzipBuyBurnModule.md]).
