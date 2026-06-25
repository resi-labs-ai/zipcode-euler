# SP-01 — zipUSD utility-dollar lifecycle (the supply-entry seam → S12)

**Intent.** Prove zipUSD is the $1 utility dollar: minted only through the capacity-gated deposit module, which parks
the USDC in the real EE senior pool (warehouse-custodied), is a plain transferable ERC-20, and cannot be minted by an
arbitrary caller. This is the deposit edge that feeds senior backing (S12 / SP-21).

**Proves.** `ZipDepositModule.deposit` seam (USDC→zipUSD→EE pool→warehouse EE-shares); ZipDepositModule **I-1**
net-zero custody; ESynth capacity gating; zipUSD as plain ERC-20. Sources: `docs/supply/ZipDepositModule.md`,
`contracts/src/supply/x-ray/ZipDepositModule.md`, wires `WOOF-06.md`.

**Tier.** Pure on-chain (no CRE push).

**Binds to** (by name from `contract-map.md`): `ZipDepositModule`, zipUSD (ESynth), EulerEarn pool, warehouse Safe,
base USDC market, USDC. Principals: alice = acct[6], bob = acct[8].

**Setup.** `deal` 1,000e6 USDC to alice (USDC slot 9) + gas ETH; alice approves `ZipDepositModule` for 1,000e6.

**Calls (happy).**
1. `ZipDepositModule.deposit(1_000e6)` as alice.
2. `zipUSD.transfer(bob, 100e18)` as alice.

**Calls (fuzzy / negative).**
3. `zipUSD.mint(alice, 1e18)` as alice → expect `E_CapacityReached` (alice is not a capacity-granted minter).

**Assertions** (On-chain=Yes):
- value 1:1 (6→18dp): `zipUSD.balanceOf(alice) == 1_000e18`.
- warehouse custody: `EE.balanceOf(warehouseSafe)` grew; USDC landed in the base USDC market (supplyQueue[0]).
- **I-1 net-zero custody:** `ZipDepositModule` holds 0 USDC and 0 zipUSD after the call.
- capacity gate: step 3 reverts; `zipUSD.totalSupply()` unchanged.
- plain ERC-20: `bob == 100e18`.

**Notes.** `burn` is reachable only by the redemption queue (SP-10). `deposit` (no szipUSD) vs `zap` (mints szipUSD,
SP-06). EVC deferred vault-status check: a bare `eth_estimateGas` OOGs with `ReentrancySentryOOG`; send with a
~20–30% gas buffer (frontend/relayer note, carried from the prior run).

**Result.** **PASS** (real txs on the live fork; reverted to clean baseline first).
- `deposit(1_000e6)` status 1 (gas 413,392): `zipUSD.balanceOf(alice)` 0 → **1,000e18**; `totalSupply` 0 → **1,000e18**.
- `EE.totalAssets()` 0 → **1,000e6**; `EE.balanceOf(warehouseSafe)` 0 → **1,000e6** shares (1:1 genesis); USDC routed
  all the way into the **base USDC market** (0 → **1,000e6**) via supplyQueue[0]; alice USDC → 0.
- **I-1:** `ZipDepositModule` USDC = 0, zipUSD = 0 after — net-zero conduit. ✓
- **(neg)** `zipUSD.mint` by alice **reverted** (capacity gate); `totalSupply` stayed **1,000e18**. ✓
- `transfer(bob, 100e18)` → bob = **100e18**, alice = 900e18. ✓ **No flaws.**
