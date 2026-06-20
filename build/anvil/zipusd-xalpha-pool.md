# zipusd-xalpha-pool.md — the zipUSD/xALPHA Hydrex pool + ICHI vault (the LP collateral token)

Built on the local anvil Base fork in two phases:
- `zipusd-xalpha-pool.sh` — the real Algebra Integral pool + a full-range LP position (the substrate).
- `zipusd-xalpha-ichi-vault.sh` — the **real single-sided-zipUSD ICHI YieldIQ vault** over that pool
  (8-B6, DEC-03), which mints the **fungible ERC20 LP share** — the token usable as **collateral in
  the farm utility EVK market** (the whole point: an NFT position can't be collateral, an ICHI vault
  share can, exactly the pattern the existing farm utility uses with the WETH/USDC ICHI vault behind
  escrow vault `0x8A5F…`).

## What exists on the fork now

| Thing | Value |
|---|---|
| Pool (Algebra Integral) | `0x7878816e26113fBE3B43d51917018cD582a0e27f` |
| token0 | zipUSD `0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF` ($1.00, 18-dp) |
| token1 | xALPHA `0xF6CAAF72A788916915ce1bF111E245e0bEABCd18` ($2.00, 18-dp) |
| LP position (NFPM ERC721) | tokenId **34586**, owner = deployer `0xf39F…2266` |
| Range | full-range, ticks `-887220 … 887220` (tickSpacing 60) |
| Liquidity (L) | `14142135623730950488560` ≈ 14,142 (= √(20000·10000)) |
| Reserves | 20,000 zipUSD + ~10,000 xALPHA |
| TVL | ~$40,000 ($20k zipUSD + $20k xALPHA) |
| Price | tick −6932 ⇒ 0.5 token1/token0 ⇒ 1 xALPHA = 2 zipUSD = $2.00 |

Hydrex / Algebra periphery used (`contracts/script/BaseAddresses.sol`, on-chain verified):
- NFPM `0xC63E9672f8e93234C73cE954a1d1292e4103Ab86`
- Factory `0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E` (poolDeployer `0x1595A5D1…`)
- SwapRouter `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`

## The ICHI vault = the LP collateral token (phase 2)

| Thing | Value |
|---|---|
| ICHI vault / LP share (ERC20, 18-dp) | **`0x4731d24b32e173e82788cF0d1eFf7d3b92fCa5dd`** |
| symbol | `IV-HYDX-301-zipUSD-xALPHA` |
| token0 / token1 | zipUSD / xALPHA |
| single-sided | `allowToken0=true`, `allowToken1=false` (zipUSD-only deposits) |
| pool | `0x7878816e26113fBE3B43d51917018cD582a0e27f` |
| owner | ICHI admin safe `0x7d11De61…` (factory owner; impersonated to create) |
| totalSupply | 4,950,161.74 LP shares (held by deployer; 1,000 moved to mainSafe in an ERC20-transfer test) |
| backing | `getTotalAmounts()` = (10,000 zipUSD, 0 xALPHA) — single-sided zipUSD deposit |

Created via the **real ICHI factory** `createICHIVault(zipUSD, true, xALPHA, false)` (impersonating the
factory owner) and seeded with a 10,000 zipUSD single-sided `deposit(deposit0, 0, to)`. The share is a
genuine, transferable ERC20 — this is the token that gets escrow-wrapped and posted as EVK collateral.

Fork-only wrinkle: the vault's TWAP read defaults to 3600s, but a just-created Algebra pool has no
oracle history, so `deposit` reverted `targetIsTooOld`. Fixed by (a) `setTwapPeriod(60)` on the vault
and (b) one small swap to write an oracle timepoint + a 120s warp so the read resolves. This is a
fork-age artifact (a real Base pool has hours of history), not a design change.

## State deltas from the build

- xALPHA: minted +10,000 to the deployer (MockERC20 open `mint`); totalSupply 1,000 → 11,000.
  The pool holds ~10,000; the NAV-oracle-valued xALPHA (sidecar 400) is untouched.
- zipUSD: **totalSupply unchanged at 500,000** — the 20,000 LP zipUSD came from the deployer's
  existing balance (498,000 → 478,000), nothing minted, so the 1:1 vs senior USDC holds.

## How this maps to the real architecture (and what is deliberately NOT built)

The production design (DEC-03 + the 8-B6 LP vault) is a **single-sided-zipUSD ICHI YieldIQ
vault** sitting ON a zipUSD/xALPHA Hydrex pool; the junior Safe holds the vault's ERC20 shares
(staked in a Hydrex gauge), and `SzipNavOracle` values the staked LP via
`IICHIVault.getTotalAmounts()` pro-rated by held shares.

Built here:
- [x] Real Algebra Integral pool for the pair, initialized at the $2 xALPHA mark.
- [x] Real concentrated-liquidity position (the LP an ICHI vault custodies/rebalances).
- [x] **Real single-sided-zipUSD ICHI YieldIQ vault** over the pool (via the real ICHI factory),
      seeded with a 10,000 zipUSD deposit → a fungible ERC20 LP share with real supply.

Still skipped:
- [ ] A Hydrex **gauge** for the vault share + staking it (earns oHYDX; bare LP earns only fees).
- [ ] Posting the LP share as **EVK collateral**: deploy an escrow collateral vault over
      `0x4731d24b…` and add it to the farm utility borrow market (mirrors the live WETH/USDC ICHI →
      escrow `0x8A5F…` pattern).
- [ ] Wiring into `SzipNavOracle.setLpPosition(ichiVault, gauge)` — the oracle currently points
      `ichiVault` at a real Base WETH/USDC ICHI vault (`0x07e72E46…`) as a valuation stand-in, NOT
      this pair. So the junior NAV does not yet price OUR LP.

Single-sided note: the vault holds the deposited zipUSD and only places it as a two-sided LP on a
YieldIQ rebalance, which is a keeper/off-chain action that does not run on a static fork (same reason
the SP-18 vAMM showcase spoofs harvests). So `getTotalAmounts()` reads (10,000 zipUSD, 0 xALPHA) — the
backing is real and single-sided, just not yet range-placed.

## Remaining steps to "where we need to be"

1. **Collateral**: deploy an escrow collateral EVK vault over the LP share `0x4731d24b…` and add it to
   the farm utility borrow market (so a borrower can post LP shares and draw against them).
2. (optional) Create + stake into a Hydrex gauge to farm oHYDX.
3. `SzipNavOracle.setLpPosition(0x4731d24b…, <gauge>)` so the junior basket prices OUR LP instead of
   the WETH/USDC stand-in.

## Re-run

`bash build/anvil/zipusd-xalpha-pool.sh` — pool creation is idempotent
(`createAndInitializePoolIfNecessary` no-ops if it exists); the xALPHA mint is a top-up; each
run adds one more full-range LP position to the deployer. Resets on anvil restart + redeploy.
