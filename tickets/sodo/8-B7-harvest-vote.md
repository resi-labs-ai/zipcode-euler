# 8-B7 — Harvest/vote module (claim oHYDX; defend the vote floor; re-vote each epoch)

> **NEXT / build-only.** The fourth harvest-loop engine module to be built (after 8-B14 buy-and-burn, 8-B5
> reservoir-loop, 8-B6 LP-strategy). It owns the **emissions + governance leg** of the auto-compounder: per epoch it
> (1) **claims** the gauge's oHYDX to the Safe, (2) takes the **vote-floor `exerciseVe` slice FIRST** (free permalock
> → grows the Safe's account-aggregate veHYDX), (3) **re-votes** our gauge (votes reset weekly), and (4) **claims the
> anti-dilution rebase** on the veNFTs. Internal engine plumbing → **build-only** (no INFLOW ticket; the frontend
> never wires to it, the 8-B11 CRE strategy robot drives every entrypoint). It is the **simplest sibling of
> `LpStrategyModule` (8-B6)** — same `is Module` + `setUp(bytes)`-under-`initializer` + `onlyOperator` +
> `exec(...,Operation.Call)` + `_exec`-that-bubbles pattern, **no EVC leg, no oracle, no custody, no per-clone
> `immutable`, and — the load-bearing simplification this window — NO `tokenId` state** (the Voter is account-keyed).

**Deliverable**
Two files under the supply/engine tree, plus three minimal interface edits/additions:
- `contracts/src/supply/szipUSD/HarvestVoteModule.sol` — `contract HarvestVoteModule is Module` (zodiac-core base,
  `@gnosis-guild/zodiac-core/core/Module.sol`). A CRE-operator-gated Zodiac Module **enabled on the szipUSD engine
  Safe** (`avatar == target == engineSafe`). **Five operator-only entrypoints**, each mutating the Safe **only** via
  the inherited `execAndReturnData(to, 0, data, Operation.Call)` through a private `_exec`-that-bubbles:
  - **`claimReward()`** — `gauge.getReward()` (the oHYDX emissions land in the Safe).
  - **`lockVe(uint256 amount)`** — `oHYDX.exerciseVe(amount, engineSafe)` (the **free** permalock; mints a fresh
    account-owned veNFT to the Safe; decode + emit the returned `nftId`).
  - **`vote(address[] poolVote, uint256[] weights)`** — `Voter.vote(poolVote, weights)` (account-keyed, no tokenId).
  - **`resetVote()`** — `Voter.reset()` (account-keyed; clears the Safe's current-epoch vote — the unwind/emergency path).
  - **`claimRebase(uint256[] tokenIds)`** — `RewardsDistributor.claim_many(tokenIds)` (per-veNFT anti-dilution rebase;
    the operator enumerates the Safe's veNFTs off-chain).
  The operator supplies **only scalars/arrays** (`amount`, `poolVote`/`weights`, `tokenIds`); the module builds all
  calldata to the **set-once wired targets** (`gauge`, `voter`, `oHYDX`, `rewardsDistributor`), the `exerciseVe`
  recipient is hard-pinned to `engineSafe`, every balance read is `engineSafe`. No generic call passthrough, no
  delegatecall, `value == 0` on every `exec` — the module's whole security boundary (§10.1).
- `contracts/test/HarvestVoteModule.t.sol` — unit (recording-mock Safe — exec-shape / authority / atomicity / guards)
  + fork (live Base: real `exerciseVe` against a real summoned substrate Safe proving the **fresh-veNFT /
  account-aggregate** model, real `vote`/`reset` against the live HYDX/USDC gauge, and a **signature-verification** of
  the whole Hydrex surface).
- **Interface edits (on-chain-verified — see Model from). All selectors confirmed live on Base 8453 this window:**
  - `contracts/src/interfaces/hydrex/IVoter.sol`: ADD `function reset() external;` (`0xd826f88f`) and
    `function ve() external view returns (address);` (`0x1f850716`). (`vote(address[],uint256[])` already present.)
  - `contracts/src/interfaces/hydrex/IVotingEscrow.sol`: ADD **four** views the module + fork test need (the file
    currently has only `createLock` + `balanceOfNFT`): `function getVotes(address account) external view returns
    (uint256);` (`0x9ab24eb0`, the account-aggregate floor read — the module view), plus the three the **fork test**
    uses to prove the model — `function balanceOf(address owner) external view returns (uint256);` (`0x70a08231`),
    `function ownerOf(uint256 tokenId) external view returns (address);` (`0x6352211e`),
    `function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);` (`0x2f745c59`).
    (The first three crit-passes flagged that `balanceOf`/`ownerOf`/`tokenOfOwnerByIndex` were used by the fork plan
    but absent from both the interface and this list — add all four.)
  - NEW `contracts/src/interfaces/hydrex/IRewardsDistributor.sol` — **full signatures** (the module calls only
    `claim_many`; `claim`+`claimable` are the singular form + the view): `function claim(uint256 tokenId) external
    returns (uint256);` (`0x379607f5`), `function claim_many(uint256[] calldata tokenIds) external returns (bool);`
    (`0x1f1db043`), `function claimable(uint256 tokenId) external view returns (uint256);` (`0xd1d58b25`). (The module
    ignores `claim_many`'s return — see KR3; `claim(uint256)` is included for interface completeness, harmless,
    unused by the module.)
  (`IGauge.getReward`/`earned`/`rewardToken`/`balanceOf` and `IOptionToken.exerciseVe` already exist + are verified.)

**Spec §**
- `claude-zipcode.md` **§4.5.1** — the build-grade engine spec, the **8-B7** block (corrected this window to the
  on-chain-verified Hydrex surface): external calls `gauge.getReward()`; **account-keyed**
  `Voter.vote(address[] poolVote, uint256[] weights)` + `Voter.reset()` (**no `tokenId`** — VoterV5 is account-keyed,
  `vote`/`reset` carry no tokenId; the guessed tokenId variants are ABSENT on-chain); `oHYDX.exerciseVe(uint256
  amount, address recipient)` (free permalock → a **fresh** account-owned veNFT each call); read
  `ve.getVotes(address account)` (account-aggregate, NOT `balanceOfNFT(tokenId)`); rebase via the **RewardsDistributor**
  (`Minter._rewards_distributor()`) `claim_many(uint256[] tokenIds)`. CRE op seq: claim → vote-floor `exerciseVe`
  slice FIRST → re-`vote` → pass the remainder to 8-B8. **State: none beyond the set-once wiring** (no `tokenId`).
  Invariants: vote-floor-first; re-vote every epoch; `exerciseVe` is the FLAT/DOWN hedge; the module is the Safe's
  **sole** voter.
- `reports/baal-spec.md` **§10.1** (engine modules: `is Module`, `enableModule`'d, one immutable CRE operator =
  `onlyOperator`, mutate the Safe only via inherited `exec(to,value,data,Operation.Call)`, CREATE2 clones via
  `ModuleProxyFactory`, init in `setUp` under `initializer`, Call-only / no delegatecall) + **§10.8 / 8-B7** (the
  harvest+vote description, corrected to the account-keyed surface) + **§7/§10.6 #3** (the oHYDX + veHYDX-fee
  refinery sources; veHYDX permalocked → marked at ~0 principal, only the realized oHYDX it produces counts).
- `pending-docs/hydrex.md` **§4** (defend a floor, don't seek dominance — minority status is structural; the team
  out-compounds you ~7:1) **/ §8** (default the un-sold surplus to `exerciseVe`; the dutiful auto-locker) **/ §9.2**
  (regime switch: UP/FLAT → sell, DOWN → `exerciseVe`; never dump into weakness) **/ §2.5/§2.6** (the verified
  address book + live params).
- `pending-docs/auto-compounder.md` **§4 (steps 1/3a/6) / §8 inv. 8** (the harvest loop's claim + vote-floor-first
  ordering).
- `claude-zipcode.md` **§17** locked: venue-agnostic; the engine is **CRE-permissioned** (one writer); no on-chain
  economic liquidation. (8-B7 reopens nothing.)

**Model from (VERIFIED against `reference/`, the kept builds, and the live chain this window — not cited blind)**
- **`is Module`** — `reference/zodiac-core/contracts/core/Module.sol`. **Proven by the kept `LpStrategyModule`
  (8-B6), `ReservoirLoopModule` (8-B5), `SzipBuyBurnModule` (8-B14), all build + fork-test green under 0.8.24:**
  `abstract contract Module is FactoryFriendly, Ownable`; `setUp(bytes) public virtual`; `initializer` is
  zodiac-core's own (`factory/Initializable.sol`, one-shot); `exec(to,value,data,Operation) internal`
  (`core/Module.sol:43`) and `execAndReturnData(to,value,data,Operation) internal returns (bool, bytes)` (`:59`) →
  forward to `IAvatar(target).execTransactionFromModule(...)` / `...ReturnData(...)`; `Operation { Call, DelegateCall }`
  (`core/Operation.sol:4`); `Ownable` is zodiac-core's own (`factory/Ownable.sol`: `address public owner`,
  `_transferOwnership` internal/no-guard — use in `setUp`; `setAvatar`/`setTarget` are `public onlyOwner` at
  `Module.sol`). Remap `@gnosis-guild/zodiac-core/=../reference/zodiac-core/contracts/`; zodiac-core imports **zero
  OpenZeppelin** → no OZ-4/5 collision.
- **PRIMARY MODEL = `contracts/src/supply/szipUSD/LpStrategyModule.sol` (8-B6, the closest sibling — same
  no-EVC/no-oracle/operator-driven shape).** Copy the module header (`Module`, `Operation` imports,
  `LpStrategyModule.sol:4-5`), the `_exec`-that-bubbles helper **verbatim** (`LpStrategyModule.sol:116-125` — it
  already `private returns (bytes memory)`: `execAndReturnData(to,0,data,Operation.Call)`, on `!ok` bubble the inner
  revert data via the assembly `revert(add(ret,0x20), mload(ret))` or `revert ExecFailed()` when empty, then
  `return ret`), the `setUp` validate-then-read-live-config pattern (`LpStrategyModule.sol:69-97` — validate the
  decoded addresses nonzero FIRST, set `avatar`/`target`, store, then read the LIVE config off a dependency, then
  `_transferOwnership(owner_)`), the `onlyOperator` modifier + the `setAvatar`/`setTarget` "left as onlyOwner, not
  hard-locked" comment (`LpStrategyModule.sol:100-108`), and the error block (`LpStrategyModule.sol:46-57`).
  **8-B7 has NO token approvals** (it never moves an ERC20 it must approve — `getReward`/`exerciseVe`/`vote`/`reset`/
  `claim_many` all act on the Safe's own holdings/account directly), so it is **strictly simpler** than 8-B6: no
  `approve`/reset-approval dance, no `minShares`/`Slippage`.
- **`exerciseVe` needs NO approval — VERIFIED model.** `oHYDX.exerciseVe(uint256 amount, address recipient)`
  (`IOptionToken.sol`, selector `0x9130325d`, on-chain-verified; returns `nftId`) burns `amount` oHYDX **from
  `msg.sender` (the Safe)** and permalocks the underlying HYDX into a fresh veHYDX NFT minted to `recipient`. The
  Safe is the `exec` msg.sender and holds the oHYDX, so there is no ERC20 `approve` to anyone. **The fork test MUST
  confirm this** (no approval call needed) — keep-the-build: if the live contract requires an approval, the fork test
  reveals it and the ticket gets a one-line approve added; do NOT pre-add an unproven approval.
- **The Voter is ACCOUNT-KEYED, not tokenId-keyed — VERIFIED on live Base 2026-06-08 (the host core is NOT
  open-sourced; reverse-verified from the VoterV5 impl bytecode `0x0379…`):**
  - `vote(address[],uint256[])` selector `0x6f816a20` **FOUND**; the guessed `vote(uint256,address[],uint256[])`
    (`0x7ac09bf7`) is **ABSENT**. The Voter votes with the **caller account's** whole veHYDX position — no tokenId.
  - `reset()` selector `0xd826f88f` **FOUND**; `reset(uint256)` (`0x310bd74b`) is **ABSENT**.
  - `lastVoted(address)` (`0x9a61df89`) and `ve()` (`0x1f850716`) **FOUND** — account-keyed accounting.
  - `getEpochDuration()` (`0x5d3ea8f1`) **FOUND** (= 604800). (The module does NOT call it — epochs are an 8-B11 CRE
    concern; do not add it to the module.)
- **veHYDX is account-aggregate — VERIFIED.** `ve.getVotes(address account)` (`0x9ab24eb0`) **FOUND**, returns the
  account's voting power summed across **all** its veNFTs. Live proof: the team voter account
  `0xd9e966a6Bfa2aE2113a34Bb4dd02ded921DA50aF` holds `ve.balanceOf == 40` veNFTs, and
  `ve.getVotes(account) = 2.798e26` **exceeds** `ve.balanceOfNFT(#1) = 2.787e26` — i.e. each `exerciseVe`/`createLock`
  mints a **fresh** NFT and the account aggregate is the sum. **This is why the module tracks NO `tokenId`** (the
  spec's earlier "the veHYDX tokenId" was wrong) and why the floor read is `getVotes(Safe)`, NOT `balanceOfNFT`.
- **The rebase lives on the RewardsDistributor, NOT the Minter — VERIFIED.** `Minter._rewards_distributor()`
  (`0x4b1cd5da`, read live = `0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42`). On that RewardsDistributor:
  `claim(uint256)` (`0x379607f5`), `claim_many(uint256[])` (`0x1f1db043`), `claimable(uint256)` (`0xd1d58b25`) all
  **FOUND**; `claimable(#1)` staticcalled non-zero. The rebase is **per-veNFT** (claiming credits each veNFT's own
  lock — you cannot redirect it), so `claim_many(tokenIds)` over an operator-curated array is harmless even if the
  array is imperfect. **The module hard-wires the RewardsDistributor address at `setUp` (read it off the Minter at
  deploy and pass it in), so the module needs NO Minter import.**
- **The gauge — VERIFIED (already in `IGauge.sol`).** `gauge.getReward()` (`0x3d18b912`) claims the gauge's reward
  token (oHYDX) to the staker (the Safe = the call's msg.sender). `gauge.earned(address token, address account)`
  (`0x211dc32d`, the **two-arg** form — pass `rewardToken()==oHYDX`, `account==engineSafe`) is the `pendingReward`
  view. `gauge.rewardToken() → oHYDX` (`0xA1136031…`, on-chain-confirmed for the live HYDX/USDC gauge).
- **Read `oHYDX` and `ve` LIVE in `setUp`** off the wired dependencies (the 8-B6 token0/token1-live-read pattern):
  `oHYDX = IGauge(gauge).rewardToken()` and `ve = IVoter(voter).ve()`. This removes two `setUp` args, guarantees the
  `exerciseVe` target == the gauge's reward token and the floor-read escrow == the Voter's escrow, and is fail-closed
  (assert both nonzero). **setUp args (6):** `(address owner, address engineSafe, address operator, address gauge,
  address voter, address rewardsDistributor)`.
- **CRITICAL clone fact (§18.6, proven on 8-B6/8-B5/8-B14).** A `ModuleProxyFactory` clone shares the mastercopy's
  runtime bytecode, so **`immutable` is identical for every clone** — it CANNOT carry per-clone `setUp` config.
  **Every per-clone wired address (`engineSafe`, `operator`, `gauge`, `voter`, `oHYDX`, `ve`, `rewardsDistributor`)
  MUST be plain set-once storage written in `setUp` under `initializer`, NOT `immutable`.** Init-lock the mastercopy
  at deploy.
- **Error declarations:** `error NotOperator(); error ZeroAddress(); error OwnerIsOperator(); error ZeroAmount();
  error EmptyArray(); error LengthMismatch(); error ExecFailed();` (model the block on `LpStrategyModule.sol:46-57`;
  drop `ZeroMinShares`/`Slippage` — no deposit; add `EmptyArray` for `vote`/`claimRebase` and `LengthMismatch` for
  `vote`'s two arrays).
- **Addresses (`contracts/script/BaseAddresses.sol` — ADD the verified ones not yet present):** `HYDREX_VOTER
  0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b` (already present from 8-B6), `OHYDX 0xA1136031…` (present),
  `HYDX_USDC_POOL 0x51f0B932…` (present); **ADD** `HYDREX_VE 0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1` and
  `HYDREX_REWARDS_DISTRIBUTOR 0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42`. (BUILD NOTE: `HYDREX_VE` is an **alias** of
  the existing `VEHYDX` constant — same address `0x25B2…`; add it under the ticket-named symbol.) `HYDREX_MINTER
  0xA7D64625F45548a19B2A19e28E7546bb2839003E` is **NOT imported by the module** (the module hard-wires the
  RewardsDistributor; the Minter is only the deploy-time *derivation* source `Minter._rewards_distributor()`, an
  item-10 concern) **but the fork TEST uses it** (`Minter.update_period()` to force the vote epoch — Done-when fork (c)),
  so add it as a constant. The live gauge
  `0xAC396CabF5832A49483B78225D902C0999829993` is a **test-only constant** (not production — our ALM_ICHI
  zipUSD/xALPHA gauge isn't whitelisted yet, the stand-in posture). **oHYDX source for the fork `deal`:** `deal(OHYDX,
  engineSafe, amount)` is the first attempt (oHYDX is a standard ERC20 — `name()=="Option to buy HYDX w/ USDC"`,
  `isPaused()==false`, standard `balanceOf`/`transfer`, verified). **Fallback (if `deal` doesn't take):** impersonate
  the concrete holder **team Safe A `0xd9e966a6Bfa2aE2113a34Bb4dd02ded921DA50aF`** (holds `2334e18` oHYDX,
  on-chain-verified this window) via `vm.prank` + `transfer` — declare it a test constant `OHYDX_WHALE`.

**Starting state**
`forge build` green on `main` (kept tree incl. WOOF-00…05, `SzipNavOracle`, `ExitGate`+`SzipUSD`, `ZipDepositModule`,
8-B1 substrate, 8-B14 `SzipBuyBurnModule`, 8-B5 `ReservoirLoopModule`+`SzipReservoirLpOracle`+`ReservoirBorrowGuard`+
`ReservoirMarketDeployer`, 8-B6 `LpStrategyModule`). zodiac-core `Module` proven by 8-B6/8-B5/8-B14; the local
Hydrex interfaces exist + are on-chain-verified (`IGauge.sol`, `IVoter.sol`, `IVotingEscrow.sol`, `IOptionToken.sol`).
`contracts/src/supply/szipUSD/` exists. **No engine Safe is summoned in unit tests** — use a **recording mock Safe**
(the `RecordingSafe` in `contracts/test/LpStrategyModule.t.sol` / `ReservoirLoopModule.t.sol`: implements
`execTransactionFromModule` + `execTransactionFromModuleReturnData`, records each `(to, value, data, operation)`,
`setLive`/`getCall`/`callCount`, `setFailOnCallIndex` for atomicity) for validation/authority/exec-shape, and a **real Base fork** with the **real
summoned substrate Safe** (`SummonSubstrate._summon`, model `LpStrategyModule.t.sol`/`ReservoirLoopModule.t.sol
_summonAndEnable`) as the engine Safe for the live `exerciseVe`/`vote`/`reset` cycle.

**Test-harness extensions to author (the kept `RecordingSafe` does NOT cover these — the critics flagged it; build
them in the test file):**
- **`RecordingSafe` return-data (the `lockVe` nftId decode — the most-blocking unit gap).** The kept `RecordingSafe`
  returns `(true, "")` on the non-live path, so `lockVe`'s `abi.decode(ret,(uint256))` would revert. ADD a settable
  global `bytes private _returnData` + `setReturnData(bytes)` and return it from `execTransactionFromModuleReturnData`
  (on the non-live recording path); the `lockVe` unit test sets it to `abi.encode(uint256 expectedNftId)` and asserts
  `emit Locked(amount, expectedNftId)`. ALSO add a **short/empty return-data** case (set `_returnData` to `< 32
  bytes`) and assert `lockVe` **reverts** (the decode must not silently emit garbage).
- **Target mocks (for the live-read-zero + view-pinning unit tests — the model files have no analog):**
  `MockGauge` with a **settable** `rewardToken()` (incl. `address(0)` to prove the `setUp` `ZeroAddress` fail-closed)
  and an `earned(address,address)` that **records** its `(token, account)` args (to prove `pendingReward` reads
  `(oHYDX, engineSafe)`); `MockVoter` with a **settable** `ve()` (incl. `0`), `vote`/`reset` no-ops, and
  `lastVoted(address)`; `MockRewardsDistributor` with `claim_many`/`claimable`. These are the `_exec` *targets* — the
  unit `setUp` wires the module to them; the recording Safe is the *avatar*.
- **A `live`-Safe atomicity case** (not just `setFailOnCallIndex`): a target that returns `(false, customErrorBytes)`
  through a `live` Safe so the `_exec` assembly-bubble (`revert(add(ret,0x20),mload(ret))`) is exercised, plus a
  `(false, "")` case asserting the `ExecFailed` fallback. (The kept harness's `setFailOnCallIndex` reverts a string
  *before* recording — it proves the entrypoint reverts but NOT the production bubble path.)

**Do NOT**
- **Do NOT add any `tokenId` state, `merge`, or on-chain veNFT enumeration.** The Voter is account-keyed; voting +
  floor are account-aggregate; the rebase array is operator-curated. The module is **stateless beyond the set-once
  wiring** — adding tokenId tracking re-introduces the exact mis-model the spec correction removed.
- **Do NOT** call `exerciseVe` with `recipient != engineSafe`, or read any balance/floor for an account other than
  `engineSafe`. The veNFT and the votes must accrue to the Safe (the basket), never to the operator or a third party.
- **Do NOT** mint, sell, borrow, exercise-for-pay (`oHYDX.exercise`), or touch the LP/EVC here — those are
  8-B8/8-B9/8-B5/8-B6. 8-B7 is **claim + free-permalock + vote + rebase** only. The paid `exercise` is explicitly a
  **different** module (8-B8) and a **different** oHYDX function.
- **Do NOT** decide the lock-vs-sell split, the floor target `s*`, or the regime in the contract — those are 8-B11
  CRE policy. The module exposes the levers (`lockVe`/`vote`) and the operator sizes them.
- **Do NOT** use `immutable` for any wired address (clone fact); **do NOT** add a generic `exec`/`call` passthrough,
  delegatecall, or non-zero `value`; **do NOT** hard-lock `setAvatar`/`setTarget` (keep them zodiac-core `onlyOwner`,
  matching 8-B6 — marking the vendored setters `virtual` would dirty the pristine reference dep).
- **Do NOT** claim the veHYDX **voting bribes/fees** in this module (the gauge swap fees auto-compound inside the
  ICHI ALM vault → captured in the LP/NAV mark; the voting bribes are a per-NFT Bribe-contract claim, **deferred** —
  log it as an obligation). 8-B7's only claim is `gauge.getReward()` (oHYDX).

**Key requirements**
1. **`is Module` on the engine Safe, clone-safe.** Inherit zodiac-core `Module`; `setUp(bytes)` under `initializer`
   decodes the 6 addresses `(owner, engineSafe, operator, gauge, voter, rewardsDistributor)`. **ORDER is load-bearing
   (the 8-B6 pattern):** validate all **6** decoded addresses nonzero FIRST + `owner != operator` (so a zero `gauge`
   reverts `ZeroAddress`, not a confusing staticcall-to-zero), set `avatar = target = engineSafe`, store the wiring
   (`rewardsDistributor` gets ONLY the nonzero check — it is stored as-passed, NOT live-validated), THEN read
   `oHYDX = IGauge(gauge).rewardToken()` + `ve = IVoter(voter).ve()` live and assert **both nonzero** (`ZeroAddress`),
   THEN `_transferOwnership(owner)`. All wired addresses are **set-once storage, never `immutable`**. The mastercopy is
   init-locked at deploy (test asserts a second `setUp` reverts).
2. **`onlyOperator` on all five mutators; account/recipient hard-pinned to `engineSafe`.** `claimReward`/`lockVe`/
   `vote`/`resetVote`/`claimRebase` revert `NotOperator` for any non-operator caller. `lockVe` passes
   `recipient = engineSafe`; the views read `engineSafe`. Tests: a non-operator caller reverts on each; a non-owner
   `setAvatar`/`setTarget` reverts; `owner == operator` in `setUp` reverts `OwnerIsOperator`.
3. **Exec discipline — Call-only, value 0, bubble-on-failure, via `_exec`.** Every mutation routes through the
   private `_exec(to, data) returns (bytes)` using `execAndReturnData(to, 0, data, Operation.Call)`; on `!ok` it
   bubbles the inner revert data (or `ExecFailed` when empty). **Only `lockVe` reads the returned `bytes`** (to decode
   the `nftId`); `claimReward`/`vote`/`resetVote`/`claimRebase` call `_exec` and **ignore** the (empty) return. Use
   `abi.encodeCall(IGauge.getReward, ())` / `abi.encodeCall(IOptionToken.exerciseVe, (amount, engineSafe))` /
   `abi.encodeCall(IVoter.vote, (poolVote, weights))` / `abi.encodeCall(IVoter.reset, ())` /
   `abi.encodeCall(IRewardsDistributor.claim_many, (tokenIds))` — **typed `encodeCall`, not `encodeWithSelector`**, so
   an arg-order regression (e.g. a `vote(weights, poolVote)` swap or a `lockVe` recipient slip) fails to compile / is
   caught. Tests assert each entrypoint produces exactly the expected `(to, value == 0, data == the encodeCall,
   Operation.Call)` call(s) on the recording Safe — and for `lockVe`, **decode the recorded calldata's recipient arg
   and assert `== engineSafe`** (the irreversibility firewall, per security #4 — not merely a keccak match). Atomicity:
   a `live` Safe returning `(false, customErrorBytes)` makes the entrypoint **revert bubbling that data**, and
   `(false, "")` reverts `ExecFailed` (the Gnosis Safe swallows inner reverts and returns `(false, data)`; an unchecked
   `exec` would wrongly report success).
4. **Guards.** `lockVe`: `amount == 0` reverts `ZeroAmount`. `vote`: `poolVote.length == 0` reverts `EmptyArray`;
   `poolVote.length != weights.length` reverts `LengthMismatch`. `claimRebase`: `tokenIds.length == 0` reverts
   `EmptyArray`. `claimReward`/`resetVote` take no args.
5. **`lockVe` decodes + emits the fresh `nftId`.** `_exec(oHYDX, exerciseVe(amount, engineSafe))` returns the encoded
   `nftId`; decode `abi.decode(ret,(uint256))` and `emit Locked(amount, nftId)`. (The veNFT is owned by the Safe; the
   module does not store the id.) Other events: `RewardClaimed()`, `Voted(address[] poolVote, uint256[] weights)`,
   `VoteReset()`, `RebaseClaimed(uint256[] tokenIds)`.
6. **Views (8-B11/8-B12 back-pressure):** `pendingReward() → IGauge(gauge).earned(oHYDX, engineSafe)` (claimable
   oHYDX); `voteFloor() → IVotingEscrow(ve).getVotes(engineSafe)` (account-aggregate floor metric);
   `rebaseClaimable(uint256 tokenId) → IRewardsDistributor(rewardsDistributor).claimable(tokenId)`. Plus the public
   set-once getters (`engineSafe`/`operator`/`gauge`/`voter`/`oHYDX`/`ve`/`rewardsDistributor`).
7. **Interface additions are minimal + verified** (Deliverable list): `IVoter.reset()`/`ve()`, `IVotingEscrow.getVotes`,
   new `IRewardsDistributor`. Each carries the on-chain-verified selector in a comment (the house `[EXT]` posture).

**Done when**
- `forge build` green; `forge test --match-contract HarvestVoteModuleTest` green (unit) and
  `forge test --fork-url $BASE_RPC_URL --match-contract HarvestVoteModuleTest` green (unit + fork); **no regression**
  on the full suite (`forge test --fork-url $BASE_RPC_URL`, currently 300/300 after 8-B6).
- **Unit (RecordingSafe + target mocks):** (a) **exec-shape, fully pinned** — each entrypoint produces exactly one
  recorded call whose `data` equals the typed `encodeCall` (KR3): `claimReward` → `(gauge, 0, getReward(), Call)`;
  `lockVe(a)` → `(oHYDX, 0, exerciseVe(a, engineSafe), Call)` **and decodes the mock-set `nftId`** (RecordingSafe
  `setReturnData(abi.encode(id))`; assert `emit Locked(a, id)` via `vm.expectEmit`) **and decodes the recorded
  recipient arg, asserting `== engineSafe`**; `vote(p,w)` → `(voter, 0, vote(p,w), Call)`; `resetVote()` → `(voter, 0,
  reset(), Call)`; `claimRebase(ids)` → `(rewardsDistributor, 0, claim_many(ids), Call)`. (b) **`lockVe` malformed
  return** — `setReturnData` to `< 32` bytes (and empty) → `lockVe` **reverts** (the decode must not emit garbage).
  (c) authority — each of the 5 mutators reverts `NotOperator` for a non-operator (operator + rando); `setAvatar`/
  `setTarget` revert for a non-owner; `owner == operator` setUp reverts `OwnerIsOperator`; the **un-setUp mastercopy**
  is inert (every mutator reverts `NotOperator`, every getter returns 0). (d) guards — `lockVe(0)` → `ZeroAmount`;
  `vote([],[])` → `EmptyArray`; `vote([p],[1,2])` and `vote([p,q],[1])` → `LengthMismatch`; `claimRebase([])` →
  `EmptyArray`. (e) atomicity — the production **bubble** path: a `live` target returning `(false, customErrorBytes)`
  makes each entrypoint revert bubbling that data; `(false, "")` reverts `ExecFailed`. (f) clone/init — a second
  `setUp` reverts (init-locked); a zero in **each** of the 6 addresses reverts `ZeroAddress`; a `MockGauge` whose
  `rewardToken()` returns `0` and a `MockVoter` whose `ve()` returns `0` each revert `ZeroAddress` at setUp. (g) views
  — `pendingReward()` calls `MockGauge.earned(oHYDX, engineSafe)` (assert the recorded `account == engineSafe`, not the
  operator); `voteFloor()` reads `ve.getVotes(engineSafe)`.
- **Fork (live Base, real summoned Safe):** (a) **sig-verify** — staticcall `gauge.earned(oHYDX,Safe)`,
  `ve.getVotes(Safe)`, `Voter.ve()`, `rd.claimable(id)` resolve on the live addresses (the live HYDX/USDC gauge
  `0xAC396…`, ve `0x25B2…`, voter `0xc69E…`, rd `0x6FCa…`). (b) **real `exerciseVe` proves the model** — `deal` oHYDX
  to the Safe (fallback: impersonate `OHYDX_WHALE`), enable the module, operator `lockVe(amount)`: assert
  `ve.balanceOf(Safe)` increased by 1, `ve.getVotes(Safe)` increased, `oHYDX.balanceOf(Safe)` decreased by **exactly
  `amount`** (proves the burn AND that **no approval** was needed — the load-bearing claim), `Locked` emitted a
  nonzero `nftId`, **and `ve.ownerOf(nftId) == Safe`** (the decoded id is the Safe's); a **second** `lockVe` increases
  `ve.balanceOf(Safe)` to 2 and grows `getVotes` further (the fresh-NFT / account-aggregate model, proving NO tokenId
  state is needed). (c) **real `vote`/`reset`** — after holding veHYDX, capture `ts = block.timestamp`, operator
  `vote([HYDX_USDC_POOL],[1])` succeeds and `assertGe(Voter.lastVoted(Safe), ts)`; then `resetVote()` succeeds **and a
  subsequent `vote(...)` in the same epoch also succeeds** (proving `reset` cleared the epoch lock — a real positive
  assertion, not bare "does not revert"). **BUILD-EXPOSED test-sequencing (the live VoterV5 enforces two gates the
  module is correctly agnostic to — both are CRE/8-B11 concerns):** (i) a veNFT minted this block reads **0** voting
  power for the current epoch → `vote` reverts `InsufficientVotingPower()` (`0xcabeb655`); the fork test must **warp to
  the next 1-week epoch boundary** (so the lock predates the snapshot) and call `Minter.update_period()` (else
  `EpochStale()` `0x5208c356`) before voting — uses `HYDREX_MINTER 0xA7D64625…`. (ii) the Voter enforces a per-account
  **~1h vote delay** between consecutive vote/reset actions → `VoteDelayNotMet()` (`0x2add46eb`); warp **+1h** between
  vote→reset and reset→re-vote (still within the same epoch). (d) **real `claimRebase`** — enumerate the Safe's veNFTs via
  `ve.tokenOfOwnerByIndex(Safe, i)`; `claimRebase(ids)` does not revert; if `rd.claimable(id) > 0` for any id (warp ≥1
  epoch + `Minter.update_period()` to force accrual if needed), assert the claim moved it (post-claimable drops or the
  lock grew); otherwise record that the live veNFT had zero accrued rebase and the empty-tolerance path is what's
  proven (do NOT leave it a silent no-op — assert one branch).
- Mapped to the integration layer: the per-epoch harvest/vote belongs in the **deferred engine-integration audit
  sweep** (`audit/2.md` Phase L + `audit/3-results.md` authority rows), authored once the engine is
  integration-testable alongside item-10 — logged as an obligation, NOT in this window (matches the 8-B5/8-B6/Exit-Gate
  sweeps).

**Depends on**
- **8-B1** (the summoned engine Safe substrate — `SummonSubstrate._summon`) and **8-B6** (the `LpStrategyModule`
  primary model + the `RecordingSafe`/`_summonAndEnable` test harness). The on-chain Hydrex interfaces (`IGauge`,
  `IVoter`, `IVotingEscrow`, `IOptionToken`) already exist.
- **Feeds:** 8-B8 (the non-floor oHYDX slice → paid `exercise`), 8-B11 (the CRE robot that sequences claim → lockVe →
  vote → hand-off and sizes the split/floor), 8-B12 (the dashboard reads `pendingReward`/`voteFloor`), item 2 NAV
  (the veHYDX is permalocked → marked ~0 principal; only the realized oHYDX it produces is marked once claimed).

---

**New cross-ticket obligations this ticket CREATES** (record in `PROGRESS.md` at Conclude):
- **Item 10 / engine-integration audit sweep (8-B7):** author the per-epoch harvest/vote into `audit/2.md` Phase L
  (an L-step claim → `lockVe` → `vote`, with `ve.getVotes(Safe)` / `oHYDX` balances moving; N-steps: non-operator /
  zero-amount / empty-array / length-mismatch each revert) + the matching `audit/3-results.md` authority rows
  (operator-only entrypoints; `setAvatar`/`setTarget` owner-locked; `exerciseVe` recipient + reads pinned to the
  engine Safe; no custody). Author once the engine is integration-testable (with 8-B8…B13 + item-10).
- **Item 10 / 8-B11 — gauge + Voter + RewardsDistributor wiring (8-B7):** the single CRE operator is the module's
  `operator` (sole caller); wire `gauge` via `Voter.gauges(ourPool)` with the hard gate `Voter.gauges(ourPool) != 0`
  (our ALM_ICHI zipUSD/xALPHA gauge must be Hydrex-whitelisted — the SAME external-governance dep already logged for
  8-B6); pass the live `rewardsDistributor` (= `Minter._rewards_distributor()` read at deploy). The 8-B11 robot
  sequences claim → vote-floor `lockVe` FIRST → `vote` each epoch, sizes the lock-vs-sell split by regime, and
  enumerates the Safe's veNFTs (`ve.tokenOfOwnerByIndex`) for `claimRebase`.
- **8-B7 — veHYDX voting bribes/fees (deferred extension):** the per-NFT Bribe-contract claim for voting fees is NOT
  in 8-B7's scope (the gauge swap fees auto-compound in the ICHI vault → captured in NAV; 8-B7 claims only the oHYDX
  emission). If/when the voting-bribe leg is worth harvesting, author it as a follow-on (per-NFT, account-curated),
  reconcile with the §10.6 #3 / §7 "veHYDX fees" refinery-source marking.
- **8-B11 / 8-B12 — over-lock guard + monitoring (security #5).** `lockVe(amount)` is **uncapped on-chain by design**
  (the module is stateless, has no notion of basket size, and sizing the lock-vs-sell split is 8-B11 CRE policy). But
  `exerciseVe` is **irreversible** (permalocked veHYDX is marked ~0 principal, non-redeemable — NOT exit collateral),
  so a buggy/over-aggressive CRE could convert sellable oHYDX emissions into dead veHYDX, degrading realizable NAV /
  exit liquidity (it never touches depositor principal / zipUSD / LP, so the structural exit collateral is safe). **8-B11
  MUST bound per-epoch `lockVe(amount)` to the regime-sized floor slice `s*`, never the full oHYDX balance; 8-B12 MUST
  tripwire `voteFloor()` growth vs `pendingReward()` drain.** Because the lock is irreversible, detection must
  precede, not follow.
- **8-B11 / 8-B12 — failure-mode coverage (CRE/monitoring layer, not contract-testable).** The §4.5.1 8-B7 failure
  modes — **missed epoch vote** (votes reset weekly → a skipped epoch starves our gauge) and **floor drift** (the team
  out-compounds us ~7:1, eroding relative vote share) — are NOT contract-layer testable (the module is stateless + has
  no epoch awareness by design). They become 8-B11 scheduling guarantees + the 8-B12 red tripwire (`hydrex.md §4/§12`),
  logged here so they are not silently dropped.
