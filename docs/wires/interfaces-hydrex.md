# interfaces-hydrex — Hydrex (Lynex fork, Algebra Integral) shim set (wiring map)

> **X-Ray (trust surface): MEDIUM–HIGH** — the oHYDX yield + vote-emission loop; `IVammPair` is the demo
> vAMM seam only. Trust map: `contracts/src/interfaces/x-ray/dependency-surface.md`; overview:
> `docs/interfaces/dependency-surface.md`.

> Source of truth = the kept code under `contracts/src/interfaces/hydrex/`. This doc reads each `.sol`
> as the final form and records what live Base-mainnet contract each shims, the exact declared surface,
> who consumes it, and the gotchas. All five are **interface + fork** shims (never compiled from source —
> WOOF-00 Strategy A): minimal local interfaces holding only the methods we call, fork-tested against the
> live Base (8453) deployments.

## Role
The local interface set for the Hydrex ve(3,3) emissions stack (VoterV5 / oHYDX option token / veHYDX V2 /
RewardsDistributor / on-demand gauge) that the 8-B5 farm utility loop farms — the supply-side flywheel that
buys the szipUSD emissions subsidy. Every signature is Basescan/`cast`-selector-verified (Foundry fork
auto-ABI is not trusted).

## Live external pins (from `contracts/script/BaseAddresses.sol`)
| Constant | Address | What |
|---|---|---|
| `HYDX` | `0x00000e7efa313F4E11Bfff432471eD9423AC6B30` | The HYDX emission token (oHYDX underlying). |
| `OHYDX` | `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78` | The option token (`IOptionToken`). Non-proxy. |
| `HYDREX_VOTER` | `0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b` | VoterV5Proxy (`IVoter`). impl `0x0379…48aa4`. |
| `VEHYDX` | `0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1` | veHYDX V2 escrow (`IVotingEscrow`). impl `0x0fc6…ff231`. |
| `HYDREX_REWARDS_DISTRIBUTOR` | `0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42` | Per-veNFT rebase (`IRewardsDistributor`) = `Minter._rewards_distributor()`. |
| `HYDREX_MINTER` | `0xA7D64625F45548a19B2A19e28E7546bb2839003E` | The Minter (source of `_rewards_distributor()`, sel `0x4b1cd5da`). |
| `HYDX_USDC_POOL` | `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2` | The HYDX/USDC pool used in fork tests to resolve a live gauge. |
| _the gauge_ | **no fixed constant** | `IGauge` — created on demand via `Voter.createGauge(ourPool, ALM_ICHI_UNIV3)`, resolved at deploy via `Voter.gauges(ourPool)`. Live test stand-in: `0xAC396CabF5832A49483B78225D902C0999829993` (impl `0x22D2…0480d`). |

---

## IGauge.sol — `IGauge`
1. **What it shims.** A Hydrex gauge (BeaconProxy) over our LP pool. The gauge custodies the staked ICHI
   LP share and emits oHYDX (`rewardToken() == OHYDX`). No fixed address — created on demand by the Voter,
   resolved via `Voter.gauges(ourPool)`. Test stand-in `0xAC396Cab…29993`.
2. **Declared surface.**
   - `deposit(uint256 amount)` — stake LP (sel `0xb6b55f25`).
   - `withdraw(uint256 amount)` — unstake LP (sel `0x2e1a7d4d`).
   - `getReward()` — claim accrued oHYDX (sel `0x3d18b912`).
   - `rewardToken() view returns (address)` — the emitted token (== oHYDX).
   - `earned(address token, address account) view returns (uint256)` — **two-arg** form (sel `0x211dc32d`); pass `rewardToken()==oHYDX` as `token`. The guessed single-arg `earned(address)` (`0x008cc262`) is ABSENT.
   - `balanceOf(address account) view returns (uint256)` (sel `0x70a08231`) — staked LP balance.
3. **Consumed by.** `LpStrategyModule.sol` (stake/unstake/balance), `HarvestVoteModule.sol` (getReward),
   `SzipNavOracle.sol` (staked-balance mark), and the demo forks
   `hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol` + `hydrex-demo-fork/SzipNavOracleDemoVAMM.sol` (same gauge surface).
4. **Gotchas.** The gauge address is **wired set-once** into the modules (`setGauge`, Timelock), not
   resolved at runtime — the item-10 deploy resolves it via `Voter.gauges(ourPool)` under the hard gate
   `!= address(0)` (our pool's gauge must first be Hydrex-whitelisted; OTC external-governance dep). The
   gauge MUST be the `ALM_ICHI_UNIV3` type. `earned` is the corrected two-arg shape — single-arg reverts.

## IOptionToken.sol — `IOptionToken`
1. **What it shims.** oHYDX `OHYDX 0xA113…cB78` (non-proxy) — the discounted call option on HYDX that the
   gauge pays out as the emission reward.
2. **Declared surface.**
   - `exercise(uint256 amount, uint256 maxPaymentAmount, address recipient, uint256 deadline) returns (uint256 paymentAmount)` — the **4-arg** cash exercise (sel `0xa1d50c3a`); strike paid in `paymentToken()`.
   - `exerciseVe(uint256 amount, address recipient) returns (uint256 nftId)` — **2-arg** exercise-to-veNFT (sel `0x9130325d`). The guessed 4-arg `exerciseVe(uint256,uint256,address,uint256)` (`0x62994c05`) is ABSENT.
   - `paymentToken() view returns (address)` — the strike ERC20 (sel `0x3013ce29`; live == USDC `0x8335…2913`). Read LIVE in a module's `setUp` so the strike-approval target can never drift.
   - `getDiscountedPrice(uint256 amount) view returns (uint256)` — discounted strike for `amount` (sel `0x339ccade`).
   - `getMinPaymentAmount() view returns (uint256)` — **no-arg** flat strike floor (sel `0x2abb945c`; live `10000` = $0.01 6-dp). Charged strike = `max(getDiscountedPrice(amount), getMinPaymentAmount())`.
   - `discount() view returns (uint256)` — whole-percent discount (sel `0x6b6f4a9d`; live `30` == 30%). NAV intrinsic per token = `HYDX × (100 - discount)/100`.
3. **Consumed by.** `ExerciseModule.sol` (exercise path), `HarvestVoteModule.sol` (harvest), `SzipNavOracle.sol`
   (oHYDX intrinsic mark via `discount`/`getDiscountedPrice`), and the demo fork
   `hydrex-demo-fork/SzipNavOracleDemoVAMM.sol` (same intrinsic mark).
4. **Gotchas.** Two distinct exercise overloads with **different arity** — cash exercise is 4-arg, ve-exercise
   is 2-arg; the earlier 4-arg ve guess and per-amount `getMinPaymentAmount` guess were both wrong and
   corrected. `paymentToken()`/`discount()` must be read live at mark/approval time so neither caches a stale
   value.

## IRewardsDistributor.sol — `IRewardsDistributor`
1. **What it shims.** The Hydrex RewardsDistributor `0x6FCa…eD42` — the per-veNFT anti-dilution rebase.
   Discovered via `Minter._rewards_distributor()` (sel `0x4b1cd5da`), read live.
2. **Declared surface.**
   - `claim(uint256 tokenId) returns (uint256)` — singular per-veNFT rebase claim (sel `0x379607f5`). Included for completeness; **unused** by the module.
   - `claim_many(uint256[] tokenIds) returns (bool)` — the batch the module calls (sel `0x1f1db043`). The bool is IGNORED (rebase credits each veNFT's own lock and cannot be redirected, so an imperfect operator array is harmless).
   - `claimable(uint256 tokenId) view returns (uint256)` — per-veNFT claimable view (sel `0xd1d58b25`).
3. **Consumed by.** `HarvestVoteModule.sol` only.
4. **Gotchas.** The module calls only `claim_many` (mutate) + `claimable` (view). The distributor address =
   `Minter._rewards_distributor()` — resolved off the Minter, not hardcoded blindly. The rebase is
   non-redirectable (credits the veNFT's own lock), so the ignored bool / curated array is safe.

## IVoter.sol — `IVoter`
1. **What it shims.** VoterV5Proxy `HYDREX_VOTER 0xc69E…f17b` (impl `0x0379…48aa4`) — the Solidly/ve(3,3)
   gauge voter.
2. **Declared surface.**
   - `vote(address[] poolVote, uint256[] voteProportions)` — **account-keyed** vote, NO tokenId (sel `0x6f816a20`). The guessed `vote(uint256,address[],uint256[])` (`0x7ac09bf7`) is ABSENT — this Voter votes with the caller's veNFT.
   - `reset()` — **account-keyed** reset, NO tokenId (sel `0xd826f88f`). The guessed `reset(uint256)` (`0x310bd74b`) is ABSENT.
   - `ve() view returns (address)` — the Voter's voting escrow (sel `0x1f850716`).
   - `createGauge(address pool, uint256 gaugeType) returns (address gauge, address internalBribe, address externalBribe)` — 3-return (sel `0xdcd9e47a`).
   - `gauges(address pool) view returns (address gauge)` — resolve the gauge for a pool (sel `0xb9a09fd5`).
   - `claimRewards(address[] gauges)` — claim across gauges (sel `0xf9f031df`).
3. **Consumed by.** `HarvestVoteModule.sol` only (runtime); `LpStrategyModule.t.sol` uses `gauges()` to
   resolve the live gauge in fork tests.
4. **Gotchas.** This is the **account-keyed VoterV5** — `vote`/`reset` take no tokenId; the engine Safe votes
   with the veNFTs it holds. The gauge is resolved via `Voter.gauges(ourPool)` under the hard gate
   `!= address(0)` (Hydrex-whitelist OTC dep), and created with `gaugeType == ALM_ICHI_UNIV3`.

## IVotingEscrow.sol — `IVotingEscrow`
1. **What it shims.** veHYDX V2 escrow `VEHYDX 0x25B2…d1e1` (impl `0x0fc6…ff231`) — the ERC721 lock that
   holds HYDX/oHYDX-ve and grants voting power.
2. **Declared surface.**
   - `createLock(uint256 value, uint256 lockDuration, uint8 lockType) returns (uint256 tokenId)` — **V2** lock (sel `0xc7512670`); 3rd arg = the `IVotingEscrowV2_Data.LockType` enum (modeled `uint8`, 0 = default). The classic Solidly `create_lock(uint256,uint256)` (`0x65fc3873`) is ABSENT.
   - `balanceOfNFT(uint256 tokenId) view returns (uint256)` — per-veNFT voting power (sel `0xe7e242d4`).
   - `getVotes(address account) view returns (uint256)` — **account-aggregate** voting power summed across ALL the account's veNFTs (sel `0x9ab24eb0`) — the floor metric, NOT `balanceOfNFT(tokenId)`.
   - `balanceOf(address owner) view returns (uint256)` — count of veNFTs owned (sel `0x70a08231`).
   - `ownerOf(uint256 tokenId) view returns (address)` (sel `0x6352211e`).
   - `tokenOfOwnerByIndex(address owner, uint256 index) view returns (uint256)` — enumerate an account's veNFTs (sel `0x2f745c59`).
3. **Consumed by.** `HarvestVoteModule.sol` only.
4. **Gotchas.** `createLock` is the **V2** 3-arg shape (classic 2-arg `create_lock` reverts). The floor /
   voting-power metric is the **account-aggregate** `getVotes(account)`, summed across all the account's
   veNFTs — do not confuse with per-token `balanceOfNFT`.

## IVammPair.sol — `IVammPair`
1. **What it shims.** A Solidly-style vAMM pair (the pair contract IS its own LP token). Used only by the
   SHOWCASE demo fork to build and price a live vAMM HYDX/USDC LP before the real ICHI pool exists. Not used
   in production (prod LP is the ICHI vault). No fixed address — wired to the live demo pair.
2. **Declared surface.** `mint(to) → liquidity`, `getReserves() → (r0, r1, ts)`, `token0()`/`token1()`,
   `totalSupply()`, `balanceOf(account)`.
3. **Consumed by.** `hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol` (build LP via `mint`) and
   `hydrex-demo-fork/SzipNavOracleDemoVAMM.sol` (price the LP via `getReserves`). See `SHOWCASE-VAMM.md`.
4. **Gotchas.** Demo-only — outside the audited core. The `ichiVault` storage slot on both demo forks holds
   this vAMM pair (the name is kept so the prod ABI/wiring is byte-identical).

## Cross-cutting gotchas
- **Gauge resolution is a hard-gated OTC dependency.** All gauge wiring flows through
  `Voter.gauges(ourPool) != address(0)`; until Hydrex whitelists our zipUSD/xALPHA `ALM_ICHI_UNIV3` gauge
  (external governance / OTC), there is no gauge — fork tests use the HYDX/USDC stand-in. The modules hold
  the gauge as a Timelock-settable wired address (`setGauge`), not a runtime lookup.
- **rewardsDistributor = `Minter._rewards_distributor()`** — discovered off the Minter, not blindly pinned.
- **Account-keyed, not tokenId-keyed.** VoterV5 `vote`/`reset` and veHYDX `getVotes` operate on the caller
  account aggregate (the engine Safe), reflecting the V5/V2 ve(3,3) shape — every earlier tokenId-arg guess
  was verified ABSENT and corrected in-code.
