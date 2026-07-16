# SZIPUSD ENGINE — FarmUtilityBorrowGuard
[zipcode-euler/contracts/src/supply/szipUSD]

The borrow gate that protects the shared farm-utility cash. Base (chain 8453). Solidity 0.8.24.

* The farm-utility lending vault holds depositor-sourced USDC while it is funded. Without a gate, any LP holder could post the same collateral on their own account and borrow that cash.
* This guard is installed on the vault's borrow operation and allows a borrow only when the borrower is the engine vault. Anyone else is rejected.
* It moves no value and holds no funds — it is a pure permission check installed on the lending market.

==================================================================================
What it does

- FarmUtilityBorrowGuard.sol → pin borrowing to the engine vault
A hook installed on the lending vault's borrow operation: it reverts unless the borrowing account is the wired engine vault. It checks account identity, not authorization, because the vault borrows on its own account. It also guards against spoofing — it trusts the appended borrower identity only when the caller is a recognized lending-vault proxy — and its admin functions deliberately check the raw caller to avoid a decoder collision.
[contracts/src/supply/szipUSD/FarmUtilityBorrowGuard.sol]
[../../wires/8-B5-FarmUtilityLoop.md]

Summaries:
[../../wires/8-B5-FarmUtilityLoop.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE — its decisive gate is proven on the real Euler market; 3 guard tests via the loop suite (no dedicated file).

[contracts/src/supply/szipUSD/x-ray/FarmUtilityBorrowGuard.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The account-identity gate is the whole point and is proven on the live market: the engine vault borrows, a third party posting the same collateral on its own account is rejected.
* The anti-spoof check (trust the appended account only from a real lending-vault proxy) and the admin surface (re-pointing which account may borrow, behind an owner check on the raw caller) are both tested.
* Residual (off-chain): the guard only protects if it is actually installed on the borrow operation with the real factory wired — a deploy/config step. A direct non-vault call fails closed but isn't separately tested.

==================================================================================
References:

- It is the borrow pin the leverage loop relies on — [contracts/src/supply/szipUSD/FarmUtilityLoopModule.sol] ([FarmUtilityLoopModule.md]).
- It is installed on an isolated Euler lending vault (the resting-USDC market) — see [../../interfaces/interfaces-euler.md].
