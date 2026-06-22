# INTERFACES — BAAL
[zipcode-euler/contracts/src/interfaces/baal]

Minimal interface shims for Baal (Moloch v3) — the Vault substrate for szipUSD — on Base (chain 8453). Solidity 0.8.24.

==================================================================================
This vault acts as the Junior Tranche, Yield Farm, and Risk Manager for zipUSD.

* Baal is a vault container, built on top of Gnosis Safe, Gnosis Zodiac Modules, and Chainlink CRE.
* Depositors hold szipUSD — a liquid receipt token, backed 1:1 by soulbound Loot ([Baal/contracts/LootERC20.sol]), the underlying economic share of the junior tranche. We deliberately do NOT hand out raw Loot — a native ragequit would pay the wrong amount (see the Ragequit section below). Instead depositors get the receipt token plus a secondary market (CoW), and redemptions are centralized through the ExitGate according to capital availability.
* The safe operates the Hydrex Auto-compounder as a yield source.
* The safe *also* processes USDC withdrawals into the CoW Orderbook, and facilitates the secondary market orderbook.
* The safe *also* restricts USDC withdrawals on deployed lines of credit.

Notes:

ABI was verified against the `reference/Baal/` source.
The summoner factories have fixed Base addresses (in `contracts/script/BaseAddresses.sol`).
The DAO and its tokens are per-deploy clones with no fixed address.
Baal, as a Moloch DAO has no functional governance shares.
Baal's native ragequit() is NOT wired — ragequits are processed via the CoW buy-and-burn flow below (a full unwind is the same mechanism scaled into an orchestrated CoW drain).
Baal is on OpenZeppelin 4.x, which can't coexist with Euler's OpenZeppelin 5.0.2.

- IBaal.sol → a Baal (Moloch v3) DAO instance (template `0xE0F33E95aF46EAd1Fe181d2A74919bff903cD5d4`)
A Zodiac Module on a Gnosis Safe, launched inert, with the team set as owner. DeployZipcode later grants the ExitGate the manager(2) shaman. From then on the ExitGate is what drives it: it reads the Loot token and main Safe, and mints/burns szipUSD 1:1 against Loot. Exit runs through the CoW orderbook: SzipBuyBurnModule rests the buy bid, and once it fills the CRE keeper calls ExitGate.burnFor to retire the bought szipUSD and its backing Loot.
[contracts/src/supply/szipUSD/ExitGate.sol]
[contracts/script/SummonSubstrate.s.sol]
[contracts/script/DeployZipcode.s.sol]
[../wires/8-B1.md]
[../wires/ExitGate-szipUSD.md]

- IBaalAndVaultSummoner.sol → the higher-order summoner `0x2eF2fC8a18A914818169eFa183db480d31a90c5D`
Produces the Baal DAO + main Safe + a non-ragequittable juniorTrancheSidecar Safe in one transaction (`summonBaalAndVault`).
[contracts/script/SummonSubstrate.s.sol]
[../wires/8-B1.md]

- IBaalSummoner.sol → the base summoner factory `0x22e0382194AC1e9929E023bBC2fD2BA6b778E098`
Used only to read the Gnosis Safe singleton for precomputing the main Safe's address during the summon. The actual DAO+Safe summon goes through the vault summoner above, not this one.
[contracts/script/SummonSubstrate.s.sol]
[../wires/8-B1.md]

- IBaalToken.sol → the Loot ERC20 clones
The DAO's Loot token (per-DAO clone, paused at summon, owned by the Baal). Loot **is** minted/burned on every deposit/exit — but through `IBaal.mintLoot`/`burnLoot` (the manager shaman the ExitGate holds), never by calling this token directly. So nothing imports this shim for mint/burn; it's only the read/check surface for summon assertions (paused, owner == Baal, 18 decimals), reached via `IBaal.lootToken()`.

Summaries:
[../wires/interfaces-baal.md]

==================================================================================
References:

Baal (Moloch v3) is HausDAO's DAO framework; these shims declare only the calls we make against it, hand-verified against the vendored source. Live summoner addresses are pinned in BaseAddresses.

- Baal — [reference/Baal] (HausDAO/Baal, pinned in reference/MANIFEST.md). The framework these shims target.
- [contracts/script/BaseAddresses.sol] — the live Base address pins (summoners + DAO template).

==================================================================================
Yield: where the APR comes from

The junior earns through a liquidity-mining engine on the Baal vault. The zipUSD held by the safe is deposited single-sided into a Hydrex/Ichi pool, and the rewards are recycled back into the vault as equity per share. The APR comes from four sources:

1. szALPHA's endemic APR — the native staking yield on the bridged xALPHA itself.
2. Direct equity accretion — szALPHA emissions are market-sold for zipUSD into the pool, and that zipUSD is deposited straight into the vault, raising the zipUSD each Loot share can claim.
3. The Hydrex gauge auto-compounder — gauge rewards on the szALPHA/zipUSD pool produce USDC, which is added back into the pool (a direct share donation that lifts APR again).
4. veHYDX fees — the veHYDX position earns pool fees in zipUSD and szALPHA, which accrue to the Baal safe.

None of this comes from the credit-line USDC. Fees from active credit lines accrue to the Credit Warehouse, raising the USDC that backs zipUSD — they never reach szipUSD holders.

==================================================================================

Ragequit: how do I redeem my equity?

Zipcode lends the warehouse's USDC to HELOC originators, so that USDC carries duration risk — zipUSD is only fully liquid as loans repay. To protect the peg, the safe tracks how much of the warehouse is lent out and only lets you withdraw USDC that isn't currently in a loan.

A standard ragequit (a pro-rata claim on a Safe's liquid assets) does not work here. It would pay a pro-rata slice of the main Safe's *literal* contents, which doesn't reflect the actual value of the safe's equity.

- Utilized equity sits in the non-ragequittable juniorTrancheSidecar Safe, so a ragequit only captures the main Safe; it would be correct only at 0% utilization.
- The junior's LP is staked in the Hydrex gauge, so true per-share value is what the NAV oracle reports, not the Safe's on-chain balance.

So redemption runs through a CoW buy-and-burn:

1. The Zodiac module (SzipBuyBurnModule) rests a USDC bid on CoW — the protocol is the discounted buyer of last resort, bidding for szipUSD at navExit × (1 − d).
2. An exiting holder sells their szipUSD into that bid.
3. The bought szipUSD lands in the engine Safe.
4. The CRE keeper calls ExitGate.burnFor, which destroys both the transferable szipUSD and the equal underlying soulbound Loot 1:1 — so NAV per share ticks up for everyone who stayed.

A full wind-down is the same mechanism scaled up: liquidate the basket to USDC, raise the buyback cap, and keep the bid posted until szipUSD supply reaches zero.
