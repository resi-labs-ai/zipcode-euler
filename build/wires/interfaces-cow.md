# interfaces-cow — `IGPv2Settlement` shim (wiring map)

> Source of truth = the kept code at `contracts/src/interfaces/cow/IGPv2Settlement.sol`. This doc reads the
> code as the final form and records what it shims, its declared surface, and who consumes it.

## Role
A minimal local interface over the live CoW Protocol `GPv2Settlement` — only the presignature/domain surface
the §7 buy-and-burn bid module (8-B14) touches; interfaced + forked, never compiled from CoW source.

## What it shims
The CoW Protocol `GPv2Settlement` singleton on Base 8453 — `COW_SETTLEMENT 0x9008D19f58AAbD9eD0D60971565AA8510560ab41`
(same address on all chains). Verified live on Base 8453 (2026-06-08, `cast`):
- `domainSeparator()` => `0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b` — EIP-712 domain for CoW orders.
- `vaultRelayer()` => `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` — the GPv2VaultRelayer, the spender sell tokens (USDC) are `approve`d to. Read live (not pinned) in module setUp / `BaseAddresses` book.
- `setPreSignature(bytes,bool)` selector `0xec6cb13f` — stores a presignature keyed by the `owner` packed into `orderUid`; that `owner` MUST == `msg.sender`.
- `preSignature(bytes)` selector `0xd08d33d1` — `0` = unsigned, nonzero = signed.

## Declared surface (exact signatures)
| Signature | Mutability | Returns | Notes |
|---|---|---|---|
| `domainSeparator()` | `view` | `bytes32` | per-chain EIP-712 domain separator |
| `vaultRelayer()` | `view` | `address` | the `approve` spender for sell tokens |
| `setPreSignature(bytes orderUid, bool signed)` | nonpayable | — | `owner` in `orderUid` MUST equal `msg.sender` |
| `preSignature(bytes orderUid)` | `view` | `uint256` | `0` = unsigned, nonzero = signed |

SPDX `GPL-2.0-or-later`, `pragma solidity 0.8.24`.

## Consumed by
- `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` — the §7 / 8-B14 buy-and-burn bid module.
  (Only consumer; the interface file itself is the other grep hit.)

## Gotchas
- **PRESIGN flow, not delegatecall.** The module signs orders via `setPreSignature(orderUid, true)` as
  `msg.sender` — the `owner` packed into `orderUid` MUST be the module's own address. This is the on-chain
  presignature path; it is NOT a `GPv2Settlement.settle` delegatecall and not EIP-1271.
- **`approve` to `vaultRelayer`, not to settlement.** Sell-side USDC must be `approve`d to
  `vaultRelayer()` (`0xC92E…0110`), the relayer that pulls funds — approving the settlement contract itself
  does nothing.
- `vaultRelayer()` is read live rather than hard-pinned; the settlement address is the same on every chain.
