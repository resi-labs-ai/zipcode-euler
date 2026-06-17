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
A Zodiac Module on a Gnosis Safe, launched inert, with the team set as owner. DeployZipcode later grants the ExitGate the manager(2) shaman. From then on the ExitGate is what drives it: it reads the Loot token and main Safe, and mints/burns szipUSD 1:1 against Loot. Exit runs through the CoW orderbook, and ragequits are managed by the SzipBuyBurnModule through the ExitGate.burnFor function.
[contracts/src/supply/szipUSD/ExitGate.sol]
[contracts/src/supply/szipUSD/SzipBuyBurnModule.sol]
[contracts/script/SummonSubstrate.s.sol]
[contracts/script/DeployZipcode.s.sol]
[wires/8-B1.md]
[wires/ExitGate-szipUSD.md]
[wires/8-B14-SzipBuyBurnModule.md]

- IBaalAndVaultSummoner.sol → the higher-order summoner `0x2eF2fC8a18A914818169eFa183db480d31a90c5D`
Produces the Baal DAO + main Safe + a non-ragequittable sidecar Safe in one transaction (`summonBaalAndVault`).
[contracts/script/SummonSubstrate.s.sol]
[wires/8-B1.md]

- IBaalSummoner.sol → the base summoner factory `0x22e0382194AC1e9929E023bBC2fD2BA6b778E098`
Used only to read the Gnosis Safe singleton for precomputing the main Safe's address during the summon. The actual DAO+Safe summon goes through the vault summoner above, not this one.
[contracts/script/SummonSubstrate.s.sol]
[wires/8-B1.md]

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

Ragequit: How do I redeem my equity?

Zipcode provides lines of credit to HELOC originators, which subjects the USDC in the Credit Warehouse to duration risk.

In order to manage Duration Risk, and prevent a zipUSD depeg, the safe maintains an accounting of the current utilization of the Credit Warehouse, and only permits withdrawals of available USDC. [USDC not currently in use by loans.]

The junior earns through a liquidity-mining engine on the Baal vault: the zipUSD held by the safe is deposited single-sided into a Hydrex/Ichi pool, and the rewards are recycled back into the vault as equity per share. The APR comes from four sources:

1. szALPHA's endemic APR — the native staking yield on the bridged xALPHA itself.
2. Direct equity accretion — szALPHA emissions are market-sold for zipUSD into the pool, and that zipUSD is deposited straight into the vault, increasing the amount of zipUSD each Loot share has a claim to.
3. The Hydrex gauge APR (the auto-compounder) — gauge rewards on the szALPHA/zipUSD pool produce USDC, which is added back into the pool, boosting APR again through direct share donation.
4. veHYDX fees — the Hydrex veHYDX position earns pool fees denominated in zipUSD and szALPHA, which belong to the Baal safe.

None of these come from the active earning potential of the zipUSD that is deployed in credit lines. All fees from active credit lines accrue to the Credit Warehouse, increasing the USDC that backs zipUSD. And because that warehoused USDC is lent to off-chain originators, zipUSD is only fully liquid as lines of credit repay. 

A CoW orderbook is used to allow the safe to post USDC for bid fulfillment, or for others to bid during capital constraint.

Ragequit typically means "Pro-Rata Claim on Liquid Assets held within a Safe" -- however, since a functioning credit warehouse will always have some percentage of USDC in use by loans, a standard ragequit() does not work.

A native ragequit pays a pro-rata slice of the main Safe's *literal* contents — less than a holder is owed — for two reasons:

- Utilized equity sits in the non-ragequittable sidecar Safe, so a ragequit only captures the main Safe; it would be correct only at 0% utilization.
- The junior's LP is staked in the Hydrex gauge, so true per-share value is what the NAV oracle reports, not the Safe's on-chain balance.

Here is how a ragequit is processed on Zipcode:

1. The Zodiac module (SzipBuyBurnModule) rests a USDC bid on CoW — the protocol is the discounted buyer of last resort, bidding for szipUSD at navExit × (1 − d).
2. An exiting holder sells their szipUSD into that bid through CoW.
3. The bought szipUSD lands in the engine Safe.
4. The CRE keeper calls ExitGate.burnFor, which destroys BOTH the transferable szipUSD (held in the Safe) and the equal underlying soulbound Loot (the economic equity) 1:1 — so NAV-per-share ticks up for everyone who stayed.

A full wind-down is the same mechanism scaled up: liquidate the basket to USDC, raise the buyback cap, and keep the bid posted until szipUSD supply reaches zero (an orchestrated CoW drain).
