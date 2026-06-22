# CRE GATING HOOK
[zipcode-euler/contracts/src]

The borrow gate on each credit line's lending market. Base (chain 8453). Solidity 0.8.24.

* It is installed on every per-line borrow vault and allows a borrow or liquidation only when the borrowing account has authorized the line's borrow-driver. Anyone else is rejected.
* The subtle part is anti-spoofing: it trusts the borrower identity the lending vault appends to the call only when the caller is a recognized vault, otherwise it falls back to the raw caller — so a non-vault caller cannot claim to be an authorized account.
* It moves no value and holds no funds. Repayment is never gated (it is not in the hooked operations), so a line can always be repaid.

==================================================================================
What it does

- CREGatingHook.sol → per-line borrow/liquidate authorization gate
A hook the lending market calls before a borrow or liquidation. It allows the operation only if the borrowing account has authorized the wired borrow-driver as its operator; otherwise it reverts. It is operation-agnostic (the same check for borrow and liquidate) and uses a deliberate raw-caller owner check on its admin functions to avoid colliding with the appended-data decoder.
[contracts/src/CREGatingHook.sol]
[wires/WOOF-03.md]

Summaries:
[wires/WOOF-03.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated HARDENED — a small, sharp hook whose decisive control is exhaustively proven (13 unit tests).

[contracts/src/x-ray/CREGatingHook.md]

The load-bearing points an auditor should check (full catalog + test connection in the X-Ray):

* The anti-spoof guard is the crux, proven both ways: the appended borrower identity is trusted only when the caller is a recognized lending-vault proxy, so a non-vault caller appending an authorized account is still rejected, while the real-vault path does read the appended account.
* The check is operator-authorization, not ownership — correct for the per-line topology, where each line's account grants the driver the operator bit — and it is proven across the authorized/unauthorized matrix.
* Re-pointing the borrow-driver is the highest-stakes admin action and is tested: after a re-point the gate authorizes against the new driver and rejects the account tied to the old one.
* Residual (off-chain/inherent): trust in the audited lending-market and connector mechanics; the wiring is owner-re-pointable until the pre-production immutable re-freeze; no external audit.

==================================================================================
References:

- It is installed on each line's borrow vault by the venue adapter — [contracts/src/venue/EulerVenueAdapter.sol] ([venue.md]).
- It authorizes against the per-line borrower account established at line birth — [contracts/src/venue/LineAccount.sol] ([venue.md]).
- It reads the lending market's factory and connector through their minimal interfaces — see [interfaces/interfaces-euler.md].
