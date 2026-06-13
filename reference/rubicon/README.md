# reference/rubicon — Project Rubicon (the proven Bittensor↔Base xAlpha bridge)

> Vendored 2026-06-12 as the proven-pattern source of truth for the 8x-01 szALPHA bridge rework.
> Read-only reference — nothing here is compiled by this repo. Consumers:
> `build/wires/8x-01-szALPHA-bridge.md` (§Provenance), `contracts/src/bridge/SzAlpha.sol` (header),
> `contracts/src/interfaces/bridge/ISubtensorPrecompiles.sol` (unit docs).

## What Rubicon is
General TAO Ventures + Chainlink, launched 2025-11: non-custodial liquid staking of Bittensor subnet alpha
on Subtensor EVM (964), bridged to Base over CCIP, with xAlpha/USDC pools on Aerodrome. 18 live tokens.
Audited by Hashlock (final rating "Secure", Oct 2025; scope: Blake2b, LiquidStakedV2/V3,
MetaGraphInterface, BalanceTransfer, Constants, StakingV2Interface):
<https://hashlock.com/wp-content/uploads/2025/10/Rubicon-Smart-Contract-Audit-Report-Final-Report-v6.pdf>
Docs: <https://docs.rubiconbridge.io/> (address book: `/developer/contract-addresses`).

## Files
- `LiquidStakedV3.flattened.sol` — the verified 964 implementation (see provenance header inside).

## The architecture we verified on-chain (2026-06-12)
| Piece | Subtensor EVM 964 | Base 8453 |
|---|---|---|
| Token | `ERC1967Proxy → LiquidStakedV3` (UUPS) | canonical Chainlink `BurnMintERC20` (18-dp, maxSupply 0) |
| Pool | **`LockReleaseTokenPool 1.6.1`** | `BurnMintTokenPool 1.6.1` |

Lock/release on 964 is load-bearing, not incidental: `exchangeRate()` is `stake / local totalSupply`, so
burning bridged-out supply on the home chain would inflate the rate against unchanged stake. Locked supply
keeps counting. (Our `SzAlphaLockReleasePool` mirrors this; our vendored chainlink-ccip pin is 2.0.0 —
same family, with the `ERC20LockBox` custody split that makes pool rotation fund-migration-free.)

## Key mechanics extracted from the verified source (the facts the SzAlpha rework is built on)
1. **Units.** StakingV2 precompile (0x…0805) speaks 9-dp: `addStake` amount = TAO in rao
   (`msg.value / 1e9`, remainder refunded — audit finding H-01 was losing it); `removeStake` amount =
   alpha 9-dp; `getStake` returns alpha 9-dp. Rate = `netStaked(9dp) × 1e27 / supply(18dp)` → 18-dp.
2. **`addStake` is an AMM swap** (TAO→alpha at variable price), called with NO attached value (the
   precompile debits the caller's substrate-mapped balance). Shares are minted against the **measured
   `getStake` delta**, never the input amount; both legs carry slippage params + deadline
   (`stakeWithSlippage(minLsaAmount, deadline)` / `redeemWithSlippage(lsaAmount, minTaoAmount, deadline)`).
3. **Redemption pays the measured native-balance delta** after `removeStake` (alpha→TAO swap).
4. **Quotes via the Alpha precompile (0x…0808, INDEX 2056):** `simSwapTaoForAlpha`/`simSwapAlphaForTao`
   (9-dp in/out, fee-inclusive, size-aware), `getAlphaPrice`/`getMovingAlphaPrice` (18-dp TAO/alpha;
   the EMA is the manipulation-resistant read). Live-verified SN64: price 0.0672e18; 1 TAO → 14.870
   alpha; 1000 TAO → 14,792.8 alpha (~0.5% impact).
5. **Genesis rate** defaults to 1e18 when supply or stake is 0; V3 accrues treasury/yield fees in alpha
   (netted out of the rate), claimed via `FEE_CLAIMER_ROLE`. (We take no fees — our rate is the raw
   stake/supply.)
6. **`transferStake` exists** (used by their `redeemAsAlphaWithSlippage` for alpha-native exits) — proof
   that third parties can attribute stake to an arbitrary coldkey, i.e. the donation vector our SzAlpha
   header documents honestly.

## Live address book (from docs.rubiconbridge.io, fetched 2026-06-12)
Sample (xSN64): 964 token `0x3D44B9c5eBA6DE51f4Da3152341EBe591962e843`, Base mirror
`0xbAdd3F2d84605032C1B2AD8cBebb4700Dcd9D7dE` ("SUBNET 64"), 964 pool
`0xd612d33972698C20cDa6AcA38d16F25ca4077881` (LockRelease 1.6.1), Base pool
`0x51d67a38b185bffed0773c8b8a7326e55c1f537d` (BurnMint 1.6.1).
Full 18-token book (xTAO, xSN4, xSN8, xSN9, xSN17, xSN33, xSN34, xSN35, xSN41, xSN44, xSN46, xSN50,
xSN51, xSN56, xSN62, xSN64, xSN71, xSN120): <https://docs.rubiconbridge.io/developer/contract-addresses>

## What we deliberately do differently
- **CRE rate push to Base** (`SzAlphaRateOracle`, 8x-02): Rubicon ships no on-Base rate primitive
  (Aerodrome prices by market). The token+lane is the proven part; the oracle leg is our extension.
- **No fees in the wrapper** (no treasury/yield skim) — rate is raw stake/supply.
- **2.0.0 pool pin** (LockReleaseTokenPool + ERC20LockBox) vs their live 1.6.1 — newer of the same family.
