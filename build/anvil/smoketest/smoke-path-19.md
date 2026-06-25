# SP-19 — Donation seam: NAV moves with no deposit (seam S7) [NEW]

**Intent.** Demonstrate the one seam with NO on-chain bound: a direct transfer of a counted asset into a counted Safe
moves NAV with no deposit — and show the only tie-back, the ExitGate's round-down denominator, absorbs it so a new
depositor cannot extract the donated value for free.

**Proves.** Seam **S7** (`grossBasketValue` prices raw `balanceOf` of the counted Safes); NAV X-Ray I-1 / demo X-Ray
I-1/I-2 (the numerator reads raw Safe balance); ExitGate I-4 round-down issuance as the mitigation. Sources:
`contracts/src/supply/x-ray/SzipNavOracle.md` I-1, `contracts/src/hydrex-demo-fork/x-ray/invariants.md` I-1/I-2,
`docs/wires/SYSTEM-SEAM-MAP.md` S7.

**Tier.** Needs-forwarder (NAV seeded so the donated leg is priced).

**Binds to** (by name): `SzipNavOracle`, `ZipDepositModule`, szipUSD, xALPHA mirror, main Safe.

**Setup.** `seed_marks` with `alphaUSD = $1`; `zap(1_000e6)` (supply 1,000e18, gross 1,000e18, NAV 1e18).

**Calls (the seam).** 1. Mint/transfer **500e18 xALPHA directly to the main Safe** (a donation — no deposit, no mint).
2. Re-read `grossBasketValue`, `spotNavPerShare`, `szipUSD.totalSupply`. 3. `previewZap(1_000e6)` at the new navEntry.

**Assertions** (On-chain=Yes for the move; the *bound* is off-chain by design): after the donation,
`grossBasketValue` rose by the donated value with **`szipUSD.totalSupply` unchanged** (NAV moved with no deposit — S7);
the subsequent `previewZap` mints **fewer** shares than face (round-down at the inflated NAV), so the donated value
accrues to existing holders and is not extractable by a new entrant.

**Notes.** This is the seam the map flags as having no on-chain bound — it is **by design** (the Gate's round-down
denominator + first-depositor guard are the mitigation, not an on-chain invariant). In production the counted Safes
hold only deposited/earned value; a donation is a gift to existing holders. Documented, not "fixed".

**Result.** **PASS — seam demonstrated** (2026-06-24, live fork).
- Pre-donation: gross **1,000e18**, spot NAV **1e18**, szipUSD supply **1,000e18** (`valueOf(xAlpha,1e18)`=1e18). 
- After donating **500e18 xALPHA** to the main Safe: gross **1,500e18** (+500e18), spot NAV **1.5e18**, szipUSD supply
  **unchanged at 1,000e18** → **NAV moved with no deposit (S7)**. ✓
- Gate tie-back: navEntry **1.5e18**; `previewZap(1_000e6)` = **666.67e18** shares (< 1,000e18) → the donated value
  accrues to existing holders; a new depositor gets round-down shares and cannot extract it. ✓ The S7 seam behaves
  exactly as the map describes — unbounded on-chain, absorbed by the Gate. **No flaws** (design seam, documented).
