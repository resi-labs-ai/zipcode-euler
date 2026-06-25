# SP-21 — Senior NAV donation-immunity (the S12 senior-backing seam)

**Intent.** Prove the CTR-05 `SeniorNavAggregator` reports zipUSD's senior par-backing as a donation-immune Σ over
every registered silo, reading warehouse-owned EE shares via `convertToAssets`, never the pool's raw `balanceOf` —
so an outsider cannot inflate (or deflate) the senior-solvency telemetry by dropping assets on the pool.

**Proves.** Seam **S12** (`EulerEarn` shares → senior NAV via `ISeniorPool`, donation-immune) + `SeniorNavAggregator`
invariants **I-1** (donation immunity: `convertToAssets(balanceOf(warehouseSafe))`, never `balanceOf(eePool)`),
**I-2** (Σ across silos = single-silo identity here), **I-6** (collateralization; zero zipUSD supply → `uint256.max`,
breaker-safe), **I-7** (`systemCollateralization` reads the wired `zipUsd`). Sources: `docs/SeniorNavAggregator.md`,
`contracts/src/x-ray/SeniorNavAggregator.md`, `docs/wires/SYSTEM-SEAM-MAP.md` S12.

**Tier.** Needs-forwarder (senior par is seeded via a CRE SUPPLY report through `WarehouseAdminModule`).

**Binds to** (resolve by name from `contract-map.md`; the warehouse adapter is nonce-dependent — re-derive from
`runLocal-latest.json`): `SeniorNavAggregator`, `SiloRegistry`, EulerEarn pool, warehouse Safe,
`WarehouseAdminModule`, USDC, zipUSD (ESynth), CRE Forwarder. `LOCAL_SILO_ID =
0x0309d2cf8d22de7d0626162a4ba1d7bff931531432937d085bcaf163f0febebd`.

**Setup.** From the clean baseline: `deal` 100,000e6 USDC to the warehouse Safe (USDC slot 9). Build the warehouse
CRE identity metadata = `abi.encodePacked(wfId(32)=0, wfName(10)=getExpectedWorkflowName(), author(20)=0x90F7…)`.
Impersonate the Forwarder and push two reports `abi.encode(uint8 opType, abi.encode(uint256 amount))`:
APPROVE (opType 2, 50,000e6) then SUPPLY (opType 1, 50,000e6) → `eePool.deposit(50,000e6, warehouseSafe)`.

**Calls (happy).**
1. `SeniorNavAggregator.seniorBacking()` and `seniorBackingOf(LOCAL_SILO_ID)`.
2. `systemCollateralization()` (zipUSD supply still 0 here).

**Calls (fuzzy / negative — the donation seam).**
3. Donate 1,000,000e6 raw USDC directly to the **EE pool address** (USDC slot 9 on the pool).
4. Re-read `seniorBacking()`.

**Assertions** (lift the On-chain=Yes invariants):
- I-1/I-2: `seniorBacking() == convertToAssets(EE.balanceOf(warehouseSafe)) · 1e12`; `seniorBackingOf(LOCAL)` equals it.
- I-6: zipUSD `totalSupply()==0` ⇒ `systemCollateralization() == type(uint256).max` (a breaker reading `< threshold`
  must NOT trip on an empty system).
- **I-1 donation immunity:** after step 3, `seniorBacking()` is **unchanged** — the read never touches
  `balanceOf(eePool)`, and EulerEarn prices shares off internal accounting (`lastTotalAssets`), not raw balance.
- (out of scope, On-chain=No: none — the whole surface is on-chain views.)

**Notes.** `SeniorNavAggregator` holds no funds and prices nothing — it is solvency telemetry / the circuit-breaker
input; zipUSD still mints by value and redeems at par. The warehouse adapter address moves every deploy (plain `new`
in `CreditWarehouseDeployer`); bind by name. Retired silos still count toward `seniorBacking` (I-3) — not exercised
on this single-silo board.

**Result.** **PASS** (real txs on the live fork; aggregator at `0x10Fff7de…5b01`).
- SUPPLY seeded the warehouse Safe with **50,000e6 EE shares** (USDC 100,000e6 → 50,000e6; `convertToAssets`=50,000e6, 1:1).
- **Happy (I-1/I-2):** `seniorBacking()` = `seniorBackingOf(LOCAL)` = **50,000·1e18·1e... = 50000000000000000000000**
  (5e22, 18-dp) == `convertToAssets(50,000e6)·1e12`. ✓
- **I-6/I-7:** zipUSD `totalSupply()=0` ⇒ `systemCollateralization()` = **`2^256-1`** (uint256.max). ✓
- **Fuzzy (I-1 donation immunity):** donated **1,000,000e6** raw USDC to the EE pool address; `convertToAssets(shares)`
  stayed **50,000e6** and `seniorBacking()` stayed **5e22** — completely unmoved. ✓ EulerEarn's internal accounting
  defeats the inflation/donation vector; the aggregate is donation-immune as S12 requires. **No flaws.**
