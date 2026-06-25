# SP-07 — szipUSD secondary transfer + NAV entry/exit asymmetry (seam S3)

**Intent.** Show szipUSD is a normal transferable receipt, and that a stale price feed pauses issuance but NOT exit —
the §7 asymmetry that keeps holders able to leave even when fresh marks are unavailable.

**Proves.** szipUSD plain ERC-20 transfer; `SzAlphaRateOracle.fresh()`/leg-staleness → `navEntry` fail-closes
(`StalePrice`/`StaleRate`) while `navExit` prices off the last good marks. SzipNavOracle **I-5/I-6**. Sources:
`docs/supply/SzipNavOracle.md`, `contracts/src/supply/x-ray/SzipNavOracle.md`, wires `8-B4-SzipNavOracle.md`.

**Tier.** Needs-forwarder (seed once to mint supply; then let marks age).

**Binds to** (by name): szipUSD, `SzipNavOracle`, `SzAlphaRateOracle`, `ZipDepositModule`. alice, bob.

**Setup.** `seed_marks`; `zap(1_000e6)` as alice (supply > 0 so the bracket is non-trivial).

**Calls (happy).** 1. `szipUSD.transfer(bob, 100e18)` as alice.

**Calls (fuzzy / negative — the asymmetry).** 2. warp +2 days (no re-seed → marks stale). 3. read `navEntry()` vs
`navExit()`.

**Assertions** (On-chain=Yes): transfer moves shares (bob 100e18 / alice 900e18); while fresh `navEntry==navExit==1e18`;
after staleness `fresh()==false`, **`navEntry()` reverts** `StalePrice` (issuance paused), **`navExit()` still returns**
the last-good value (exit never blocked).

**Notes.** This is the fail-open-on-exit / fail-closed-on-entry posture: a holder can always exit at the last honest
mark; only new issuance waits for a fresh CRE push. Re-seeding restores `navEntry`.

**Result.** **PASS** (live fork; `_harness.sh` seed).
- `zap(1_000e6)` → alice **1,000e18** szipUSD. `transfer(bob,100e18)` → bob **100e18**, alice **900e18** (plain ERC-20). ✓
- Fresh: `navEntry == navExit == 1e18`, `fresh()==true`.
- After **+2 day** warp (marks stale): `fresh()==false`; **`navEntry()` reverted `StalePrice` (0x9bbfef51)**;
  **`navExit()` returned 1e18** (last-good). ✓ The §7 asymmetry holds — issuance fail-closed, exit fail-open. **No flaws.**
