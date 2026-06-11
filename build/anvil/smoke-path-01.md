# SP-01 — zipUSD utility-dollar lifecycle

**Intent.** Prove zipUSD behaves as the $1 utility dollar: it is minted into existence only through the deposit
module (capacity-gated), parks the USDC in the real EE senior pool, is a normal transferable ERC-20, and cannot be
minted by an arbitrary caller or burned outside the redemption queue.

**Proves.** The `ZipDepositModule.deposit` seam (USDC→zipUSD→EE pool→warehouse EE-shares); ESynth capacity gating;
zipUSD as plain ERC-20.

**Tier.** Pure on-chain (no CRE push).

**Binds to.** `ZipDepositModule` `0x6ecc7172…`, zipUSD `0xC5bd67f7…`, EE pool `0x1a7A8A5a…`, warehouse Safe `0xe0286169…`, USDC `0x833589fC…`.
Source: `contracts/src/supply/ZipDepositModule.sol` (`deposit` L115-123), `reference/euler-vault-kit/src/Synths/ESynth.sol` (capacity-gated `mint`), wires `WOOF-06.md`.

**Setup.**
- `deal` 1,000e6 USDC to `alice` (anvil acct[6] or any EOA).
- `alice` approves `ZipDepositModule` for 1,000e6 USDC.

**Calls.**
1. `ZipDepositModule.deposit(1_000e6) as alice`.
2. (negative) `zipUSD.mint(alice, 1e18) as alice` → expect revert / no-op (alice is not a capacity-gated minter; only the deposit module is).
3. `zipUSD.transfer(bob, 100e18) as alice` (plain ERC-20).

**Assertions.**
- `zipUSD.balanceOf(alice) == 1_000e18` after step 1 (1:1 by value, 6→18 dp).
- `USDC.balanceOf(EE_pool)` grew by 1,000e6 **or** the EE pool supplied it into the base USDC market (check `EE.totalAssets()` / base-market balance).
- `EE.balanceOf(warehouseSafe) > 0` (senior shares minted to the warehouse custodian).
- step 2 mints nothing (`zipUSD.totalSupply()` unchanged).
- step 3: `zipUSD.balanceOf(bob) == 100e18`.

**Notes.** `burn` is reachable only by the redemption queue (covered in SP-10). `deposit` (no szipUSD) vs `zap`
(mints szipUSD) — this path is the plain deposit; SP-06 is the zap.

**Result.** **PASS** (2026-06-10, real txs on anvil @ ~block 47096106).

Setup: dealt 1,000e6 USDC to `alice` (acct[6] `0x976EA740…`) via `anvil_setStorageAt` (USDC balance slot 9). bob = acct[8] `0x23618e81…`.

Calls fired & deltas:
1. `approve(module, 1000e6)` then `deposit(1000e6)` as alice. **First broadcast reverted `ReentrancySentryOOG`** — `cast`'s `eth_estimateGas` (~498k) under-priced the EVC *deferred* vault-status check that runs at the outermost EVC frame; the tx OOG'd at the top after all inner work succeeded. Re-fired with `--gas-limit 3_000_000` → **status 1, gasUsed 418,642**. (Simulation via `cast call` always succeeded, returning zipMinted = 1000e18.)
2. (negative) `zipUSD.mint(alice, 1e18)` as alice → **reverted `E_CapacityReached()` (0x1fa8265d)**. alice is not a capacity-granted minter; total supply unchanged. ✓
3. `zipUSD.transfer(bob, 100e18)` as alice → status 1.

Assertions (all ✓):
- `zipUSD.totalSupply` 0 → **1000e18**; `balanceOf(alice)` = **900e18**, `balanceOf(bob)` = **100e18**.
- `EE.totalAssets` 0 → **1000e6**; `EE.balanceOf(warehouseSafe)` 0 → **1000e6 shares** (1:1 at genesis).
- USDC routed all the way into the **base USDC market** `0x3A48aaaa…` (balance 0 → **1000e6**) — EE auto-supplied via supplyQueue[0]; `USDC.balanceOf(alice)` = **0**.
- Negative mint minted nothing (E_CapacityReached); burn is queue-only (SP-10).

**Finding (deploy note, non-blocking):** `ZipDepositModule.deposit` (and any EE-touching tx) needs a gas buffer over `eth_estimateGas` — the EVC deferred-check pattern + 63/64 rule makes the bare estimate OOG with `ReentrancySentryOOG`. Wallets that add the usual 20–30% buffer are fine; a wallet sending the raw estimate would fail. Flagging for the frontend/relayer gas-config.
