# 8-B7 — HarvestVoteModule (wiring map)

> **X-Ray (security verdict):** rated **ADEQUATE** — the most external-integration-heavy module, exercised
> against the real Hydrex gauge/voter/voting-escrow/rewards-distributor (24 unit + 5 fork). Vote-lock recipient
> hard-pinned to the vault; account-keyed; no token approvals. Report:
> `contracts/src/supply/szipUSD/x-ray/HarvestVoteModule.md` (scope: `portfolio-map.md`). ELI20:
> `docs/supply/szipUSD/HarvestVoteModule.md`. This doc is the code-truth wiring map.

> Source of truth = the kept code `contracts/src/supply/szipUSD/HarvestVoteModule.sol`. Ticket
> `tickets/sodo/8-B7-harvest-vote.md` + report `reports/8-B7-report.md` are intent — the `.sol` wins.
> Spec context: `claude-zipcode.md §4.5.1`, `reports/baal-spec.md §10.8`.

## Role
The **4th engine Zodiac Module** (after 8-B14 buy-and-burn, 8-B5 farm utility loop, 8-B6 LP strategy) — the
simplest sibling of 8-B6: **no EVC, no oracle, no custody, no approvals, and NO `tokenId` state**. It owns the
emissions + governance leg of the auto-compounder. Enabled ON the szipUSD engine Safe (`avatar == target ==
juniorTrancheEngine`), CRE-operator-gated. Per epoch it (1) CLAIMS the gauge's oHYDX to the Safe, (2) takes the
vote-floor `exerciseVe` slice (the free permalock that grows the Safe's account-aggregate veHYDX), (3) re-VOTES
our gauge (votes reset weekly), and (4) claims the per-veNFT anti-dilution REBASE. The module is **stateless
beyond its set-once wiring** — the veNFT and votes accrue to the Safe purely because the Safe is the `exec`
msg.sender, and the Hydrex Voter is **account-keyed** (no per-NFT id is ever tracked).

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `HarvestVoteModule` (`is Module`) | 5 `onlyOperator` mutators + 3 views; drives the Safe via inherited `execAndReturnData(Operation.Call, value 0)` through `_exec` (bubbles the inner revert). Set-once wiring written in `setUp` (NOT immutable — clone-safe). No tokenId state, no approvals, no generic call passthrough. |
| External: Hydrex `Gauge` | `getReward()` (claim oHYDX to caller/Safe) + `earned(token, account)` (two-arg form) + `rewardToken()` (read live in `setUp`). |
| External: Hydrex `VoterV5` | account-keyed `vote(address[],uint256[])` / `reset()` (NO tokenId) + `ve()` (read live in `setUp`) + `gauges(pool)` (item-10 gate). |
| External: Hydrex `OptionToken` (oHYDX) | `exerciseVe(uint256 amount, address recipient) → nftId` — burns oHYDX, permalocks underlying HYDX into a FRESH account-owned veHYDX minted to `recipient`. |
| External: Hydrex `VotingEscrow` (veHYDX) | `getVotes(account)` — account-aggregate voting power summed across ALL the Safe's veNFTs (the floor read). |
| External: Hydrex `RewardsDistributor` | `claim_many(uint256[])` (rebase, bool return IGNORED) + `claimable(uint256)` (per-id view). |

## Wiring — internal (ctor / setUp / mutators / views)
- **No constructor logic** — `is Module`; all per-clone config is decoded in `setUp` under the zodiac-core
  `initializer` (one-shot; the mastercopy is init-locked in its constructor (see `MastercopyInitLock`, SEC-14)).
  **CLONE FACT** (§18.6): a `ModuleProxyFactory`
  clone shares mastercopy bytecode, so `immutable` cannot carry per-clone config — EVERY wired address is plain
  set-once storage, NOT `immutable`.
- **`setUp(bytes initParams)`** decodes 6 addresses `(owner, juniorTrancheEngine, operator, gauge, voter,
  rewardsDistributor)`. **ORDER is load-bearing:** (1) revert `ZeroAddress` if ANY of the six is zero (so a zero
  `gauge` fails cleanly, not as a confusing staticcall-to-zero), (2) `OwnerIsOperator` if `owner == operator`,
  (3) `avatar = target = juniorTrancheEngine`, (4) store `juniorTrancheEngine`/`operator`/`gauge`/`voter`/`rewardsDistributor`,
  (5) read `oHYDX = gauge.rewardToken()` and `ve = voter.ve()` LIVE (the 8-B6 live-read pattern) + assert both
  nonzero, (6) `_transferOwnership(owner)`. The live reads GUARANTEE the `exerciseVe` target == the gauge's reward
  token and the floor-read escrow == the Voter's escrow.
- **The 5 `onlyOperator` mutators** (operator supplies ONLY scalars/arrays; the module builds ALL calldata to the
  wired targets via `abi.encodeCall`):
  - `claimReward()` → `_exec(gauge, getReward())` — oHYDX lands in the Safe (= the gauge call's msg.sender). Emits `RewardClaimed`.
  - `lockVe(uint256 amount)` → `ZeroAmount` guard → `_exec(oHYDX, exerciseVe(amount, juniorTrancheEngine))`; decodes the
    returned `nftId` and emits `Locked(amount, nftId)`. The recipient is **hard-pinned to `juniorTrancheEngine`** (the
    irreversibility firewall — the fresh veNFT can only mint to the Safe).
  - `vote(address[] poolVote, uint256[] weights)` → `EmptyArray` + `LengthMismatch` guards → `_exec(voter,
    vote(poolVote, weights))`. Account-keyed: votes the Safe's WHOLE veHYDX position, NO tokenId. Emits `Voted`.
  - `resetVote()` → `_exec(voter, reset())` — clears the Safe's current-epoch vote (account-keyed; unwind/emergency). Emits `VoteReset`.
  - `claimRebase(uint256[] tokenIds)` → `EmptyArray` guard → `_exec(rewardsDistributor, claim_many(tokenIds))`;
    the bool return is IGNORED (the rebase credits each veNFT's own lock — cannot be redirected, so an
    imperfect operator-curated array is harmless). Emits `RebaseClaimed`.
- **`_exec(to, data)`** = `execAndReturnData(to, 0, data, Operation.Call)` and HARD-REVERTS if it returns false,
  **bubbling the inner revert data** (assembly `revert(add(ret,0x20), mload(ret))`, or `ExecFailed` if empty).
  Required because the Gnosis Safe `execTransactionFromModuleReturnData` catches inner reverts and returns
  `(false, revertData)` rather than bubbling — an unchecked `exec` would silently swallow a failed
  claim/lock/vote. `value == 0` and `Operation.Call` on EVERY exec; **no delegatecall, no generic passthrough**.
  Only `lockVe` decodes the returned bytes (the fresh nftId).
- **3 views** (the 8-B11/8-B12 back-pressure metrics, all reads pinned to the Safe):
  - `pendingReward()` = `gauge.earned(oHYDX, juniorTrancheEngine)` — the two-arg `earned(token, account)` form (the
    guessed single-arg `earned(address)` is ABSENT from the gauge bytecode).
  - `voteFloor()` = `ve.getVotes(juniorTrancheEngine)` — the account-aggregate veHYDX voting power summed across ALL the
    Safe's veNFTs (NOT `balanceOfNFT(tokenId)` — the Safe holds many).
  - `rebaseClaimable(uint256 tokenId)` = `rewardsDistributor.claimable(tokenId)` — per-id (operator enumerates off-chain).
- **No token approvals anywhere** — `getReward`/`exerciseVe`/`vote`/`reset`/`claim_many` all act on the Safe's own
  holdings/account directly.
- **Owner vs operator separation.** The 5 mutators are `onlyOperator` (the CRE hot key). `setUp`/wiring setters
  are `onlyOwner` (the Timelock). `setAvatar`/`setTarget` are inherited `onlyOwner` (zodiac-core); the operator
  CANNOT reach them — a redirect is a deliberate timelocked governance act, not an attack path. They are NOT
  hard-locked (that would require marking vendored zodiac-core setters `virtual` — reference deps stay pristine).
  `setOperator` re-checks `operator != owner` (`OwnerIsOperator`, SEC-15) so a re-point cannot collapse the two roles
  into one key — preserving the init-time (`setUp`) separation across re-points.
- **`setJuniorTrancheEngine` moves `avatar`/`target` in lockstep** (SUPPLY-ADV-11), not only at `setUp`: it sets
  `avatar = target = juniorTrancheEngine` on every re-point so the engine-Safe invariant cannot be split. Because
  `juniorTrancheEngine` is the `exerciseVe` recipient (and every balance/floor-read subject), it MUST equal the
  exec'ing Safe (`target`) — else a lone re-point would burn the OLD Safe's oHYDX while minting the veNFT to the NEW
  engine. Matches the syncing siblings (Sell/Exercise/LpStrategy/FarmLoop/Recycle, `docs/wires/8-B9-SellModule.md`).

## Wiring — cross-component (who points at whom)
- **`gauge` → resolved via `Voter.gauges(ourPool)` with the hard gate `Voter.gauges(ourPool) != 0`** (item-10).
  Our zipUSD/xALPHA **ALM_ICHI** gauge must be Hydrex-whitelisted — the **SAME external-governance dependency as
  8-B6** (the OTC whitelist; `hydrex.md §9.4`). Fork tests use a stand-in until the gate clears.
- **`rewardsDistributor` → `Minter._rewards_distributor()` read at deploy** (= `HYDREX_REWARDS_DISTRIBUTOR
  0x6FCa…eD42`), passed into `setUp` — NOT the Minter directly (the rebase is claimed on the RewardsDistributor).
- **`oHYDX` / `ve` are NOT passed in** — they are derived live in `setUp` (`gauge.rewardToken()` /
  `voter.ve()`), so they cannot drift from the wired gauge/voter.
- **The fresh-veNFT / account-aggregate model** (the load-bearing cross-component shape, fork-proven): each
  `exerciseVe` mints a FRESH account-owned veHYDX to the Safe; the Voter aggregates voting power by ACCOUNT
  (`getVotes(Safe)` sums all the Safe's veNFTs), so there is no merge, no enumeration, and no `tokenId` the module
  must persist. The veNFT and votes accrue to the Safe solely because the Safe is the exec msg.sender. `claimRebase`
  is the only mutator that takes ids, and they are operator-curated (off-chain `ve.tokenOfOwnerByIndex`
  enumeration), purely as a batch convenience — wrong ids are harmless.

## Item-10 deploy facts (PROGRESS rows 342 / 343 / 344)
- **Deploy:** CREATE2-clone via `ModuleProxyFactory` + `enableModule` on the engine Safe + `setUp`. The mastercopy
  is locked AUTOMATICALLY by its constructor (`MastercopyInitLock`, SEC-14) the instant it is deployed — NO separate
  deploy-time lock step, and `setUp` on the mastercopy reverts `AlreadyInitialized`. `owner = TimelockController !=
  operator` (the `OwnerIsOperator` invariant). (The 8-B5/8-B6/8-B14 atomic clone+setUp factory pattern — never
  two-tx deploy-then-init.)
- **Wiring (row 342):** wire the single CRE operator as `HarvestVoteModule.operator` (sole caller); resolve+wire
  `gauge` via `Voter.gauges(ourPool)` with the hard gate `!= 0`; pass the live `rewardsDistributor`
  (= `Minter._rewards_distributor()` read at deploy).
- **8-B11 sequences the leg:** claim → vote-floor `lockVe` FIRST → `vote` each epoch; sizes the lock-vs-sell split
  by regime; enumerates the Safe's veNFTs (`ve.tokenOfOwnerByIndex`) for `claimRebase`.
- **The over-lock bound + irreversibility (row 343) are CRE/monitoring, NOT contract-enforced.** `lockVe(amount)`
  is **uncapped on-chain by design** (stateless module, no basket-size notion) — 8-B11 MUST bound per-epoch
  `lockVe` to the regime-sized floor slice `s*` (never the full oHYDX balance). `exerciseVe` is **irreversible**
  (permalocked veHYDX is marked ~0 principal, non-redeemable — NOT exit collateral) — 8-B12 MUST tripwire
  `voteFloor()` growth vs `pendingReward()` drain so detection precedes the irreversible lock. The §4.5.1
  failure modes **missed-epoch-vote** + **floor-drift** are CRE/monitoring-layer (not contract-testable).

## Gotchas
- **VoterV5 is account-keyed — NO tokenId.** `vote(address[],uint256[])` (`0x6f816a20`) + `reset()`
  (`0xd826f88f`) carry no tokenId; the guessed `vote(uint256,…)`/`reset(uint256)` are ABSENT on-chain. The floor
  read is `ve.getVotes(account)` (`0x9ab24eb0`), NOT `balanceOfNFT(tokenId)`. State = **none / no tokenId** (5
  §4.5.1 spec mis-citations were reverse-verified from Base 8453 bytecode and FIXED before build).
- **Per-account ~1h vote-delay.** The live Voter enforces a per-account vote-delay (`VoteDelayNotMet()`) — an
  8-B11 scheduling concern; the module is correctly agnostic.
- **Epoch snapshot + Minter.update_period() test-sequencing.** A live `vote` needs an epoch-advanced
  voting-power snapshot + `Minter.update_period()` first, else `InsufficientVotingPower()` / `EpochStale()`. This
  is fork-test sequencing, NOT module logic.
- **`exerciseVe` permalocks** the veHYDX (marked ~0 principal, non-redeemable) — it is NOT exit collateral.
  Combined with the uncapped on-chain `lockVe`, this makes the 8-B11 size-bound + 8-B12 tripwire mandatory.
- **`getEpochDuration()` = 604800** (weekly) — votes reset weekly, so `vote` runs every epoch; the refinery loop
  cadence is the Hydrex weekly epoch.
- **Rebase via the RewardsDistributor, not the Minter** (`Minter._rewards_distributor()` = `0x6FCa…`,
  `claim_many(uint256[])` `0x1f1db043`).
- **Voting bribes/fees are OUT of scope** (deferred extension, PROGRESS row 345): gauge swap fees auto-compound in
  the ICHI vault → captured in NAV; 8-B7 claims only the oHYDX emission + the anti-dilution rebase.
