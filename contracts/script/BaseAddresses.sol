// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title BaseAddresses
/// @notice Validated Base mainnet (chainId 8453) address constants for the
///         protocols Zipcode interfaces+forks against. Status flags per the
///         superintendent verification pass (WOOF-00). All addresses
///         are EIP-55 checksummed (the all-lowercase form does NOT compile as a
///         Solidity address literal).
library BaseAddresses {
    // -- CRE / Chainlink ----------------------------------------------------
    /// @dev KeystoneForwarder — SAME address on Base mainnet AND Base Sepolia. CONFIRMED on both.
    address internal constant CRE_KEYSTONE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    // -- Euler (CONFIRMED, repo-authoritative: euler-interfaces/EulerChains.json) --
    address internal constant EVC = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address internal constant EVAULT_FACTORY = 0x7F321498A801A191a93C840750ed637149dDf8D0;
    address internal constant EULER_EARN_FACTORY = 0x75F49a2621b6DeC6a5baB22ce961bF3e676EFAE6;
    address internal constant ORACLE_ROUTER_FACTORY = 0xA9287853987B107969f181Cce5e25e0D09c1c116;
    address internal constant EDGE_FACTORY = 0x4B930F0222349c2092b8531A42295262cc4F0e4A;

    // -- Gnosis Safe (CONFIRMED on Basescan) --------------------------------
    address internal constant SAFE_PROXY_FACTORY_1_3_0 = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address internal constant SAFE_L2_SINGLETON_1_4_1 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    // The Safe proxy factory the BaalSummoner (0x22e0…) is ACTUALLY configured with — verified by
    // reading BaalSummoner storage slot 208 on Base mainnet (it is a 1.3.0 GnosisSafeProxyFactory deployment, a
    // DIFFERENT address from 0xa6B7…). Used for the 8-B1 main-Safe CREATE2 precompute; the compute==avatar
    // fail-closed assert in SummonSubstrate guards any drift. The summoner's `gnosisSingleton` (read live) =
    // 0x69f4D1788e39c87893C980c06EdF4b7f686e2938.
    address internal constant BAAL_SAFE_PROXY_FACTORY = 0xC22834581EbC8527d974F8a1c97E1bEA4EF910BC;

    // -- Baal (CORRECTED — the prior labels were SCRAMBLED) ------
    // Source of truth: reference/Baal/deployments/base/*.json (cross-checked on-chain via template()).
    // The base summoner (summonBaal / summonBaalFromReferrer) is 0x22e0..., NOT 0x97Aaa... (that is the
    // AdvToken variant). Confirmed: BaalSummoner(0x22e0).template() => 0xE0F33E95... == Baal.json singleton.
    address internal constant BAAL_SUMMONER = 0x22e0382194AC1e9929E023bBC2fD2BA6b778E098; // BaalSummoner_Proxy
    address internal constant BAAL_AND_VAULT_SUMMONER = 0x2eF2fC8a18A914818169eFa183db480d31a90c5D; // summon DAO+Safe (8-B1)
    address internal constant BAAL_SINGLETON = 0xE0F33E95aF46EAd1Fe181d2A74919bff903cD5d4; // Baal.json DAO master copy / template
    address internal constant BAAL_ADV_TOKEN_SUMMONER = 0x97Aaa5be8B38795245f1c38A883B44cccdfB3E11; // BaalAdvTokenSummoner_Proxy (was mis-labeled BAAL_SUMMONER)
    address internal constant BAAL_ADV_TOKEN_SUMMONER_IMPL = 0xD69e5B8F6FA0E5d94B93848700655A78DF24e387; // its impl (was mis-labeled BAAL_IMPL)

    // -- Zodiac (CONFIRMED on Basescan) -------------------------------------
    address internal constant ZODIAC_ROLES_MASTERCOPY = 0x9646fDAD06d3e24444381f44362a3B0eB343D337;
    address internal constant ZODIAC_MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;

    // -- Hydrex / Algebra / ICHI (source of truth: pending-docs/hydrex.md) --
    address internal constant HYDX = 0x00000e7efa313F4E11Bfff432471eD9423AC6B30;
    address internal constant OHYDX = 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78;
    address internal constant HYDREX_VOTER = 0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b;
    address internal constant VEHYDX = 0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1;
    /// @dev The Voter's voting escrow (veHYDX) — alias of VEHYDX, named per the 8-B7 ticket Deliverable list.
    ///      Read live in the module's `setUp` off `Voter.ve()`; this constant is the address-book + fork-test anchor.
    address internal constant HYDREX_VE = 0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1;
    /// @dev The Hydrex RewardsDistributor = Minter._rewards_distributor() (0x4b1cd5da), read live. The
    ///      per-veNFT anti-dilution rebase (`claim_many`/`claimable`). On-chain-verified this window.
    address internal constant HYDREX_REWARDS_DISTRIBUTOR = 0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42;
    /// @dev The Hydrex Minter — the rebase/epoch driver. NOT imported by any module (the 8-B7 module hard-wires the
    ///      RewardsDistributor; `Minter._rewards_distributor()` = HYDREX_REWARDS_DISTRIBUTOR, verified live).
    ///      The address-book anchor for item-10 deploy (derive the RewardsDistributor via `Minter._rewards_distributor()`
    ///      at deploy). The 8-B7 fork test declares its own test-local copy. Verified live.
    address internal constant HYDREX_MINTER = 0xA7D64625F45548a19B2A19e28E7546bb2839003E;
    address internal constant ALGEBRA_NFPM = 0xC63E9672f8e93234C73cE954a1d1292e4103Ab86;
    // CORRECTED (on-chain verified): the ICHI vault FACTORY is read from the deposit guard's
    // ICHIVaultFactory() getter = 0x2b52c416. The old 0x7d11De61... constant was MIS-LABELED — it is a Gnosis
    // Safe (getOwners() => 7 owners), the ICHI admin/deployer multisig, NOT the factory the interfaces call.
    address internal constant ICHI_VAULT_FACTORY = 0x2b52c416F723F16e883E53f3f16435B51300280a;
    address internal constant ICHI_DEPOSIT_GUARD = 0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8;
    address internal constant ICHI_ADMIN_SAFE = 0x7d11De61c219b70428Bb3199F0DD88bA9E76bfEE; // Gnosis Safe, not the factory
    address internal constant HYDX_USDC_POOL = 0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev The Algebra Integral `SwapRouter` (Hydrex periphery) — the 8-B9 SellModule swap target. On-chain-verified
    ///      this window: `router.factory()` == 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E == the HYDX/USDC pool's
    ///      `factory()` whose `poolByPair(HYDX, USDC)` returns the live pool 0x51f0… ⇒ a base-factory pool, so the
    ///      `exactInputSingle` `deployer` arg is address(0). `exactInputSingle(...)` selector 0x1679c792.
    address internal constant ALGEBRA_SWAP_ROUTER = 0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e;

    // -- CoW Protocol (verified live on Base 8453 via `cast`) ----
    /// @dev GPv2Settlement — SAME address all chains. `domainSeparator()` on Base =
    ///      0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b. The 8-B14 buy-burn module signs
    ///      PRESIGN orders here via `setPreSignature(bytes,bool)` (selector 0xec6cb13f).
    address internal constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    /// @dev GPv2VaultRelayer — the spender USDC is `approve`d to for a live bid. NOTE: read `vaultRelayer()` LIVE in
    ///      `setUp` (do not hard-trust this constant); it is here for the address book + deploy reference only.
    address internal constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    /// @dev CowswapOrderSigner (Gnosis Guild) — the SDK's delegatecall signer. REFERENCE-ONLY: the 8-B14 module does
    ///      NOT delegatecall it (it signs via its own `setPreSignature` Call). Useful as a uid ground-truth.
    address internal constant COW_ORDER_SIGNER = 0x23dA9AdE38E4477b23770DeD512fD37b12381FAB;
}
