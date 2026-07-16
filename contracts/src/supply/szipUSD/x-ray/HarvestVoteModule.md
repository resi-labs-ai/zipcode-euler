# X-Ray — `HarvestVoteModule.sol` (single-contract, test-connected)

> HarvestVoteModule | 142 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/HarvestVoteModule.sol`, the 8-B7 harvest/vote leg
— the most **external-integration-heavy** of the engine fleet (Hydrex gauge / voter / voting-escrow / rewards-
distributor). Connected to `test/HarvestVoteModule.t.sol`: **24 unit + 5 base-fork = 29 tests, all passing** (0 fuzz,
0 invariant — stateless, deterministic single-`exec`s). **Every mutator is exercised** (all 7 setters + the 5
operator actions).

> Fleet-shape note: like `ExerciseModule`, this is operator-scalars → module-built calldata → Safe exec. Unlike the
> value-moving modules, the harvest leg moves **no value out** — it claims rewards *into* the Safe, permalocks *to*
> the Safe, and votes *as* the Safe (account-keyed). No token approvals exist anywhere.

## 1. What it is

The fourth engine Zodiac `Module`, CRE-operator-gated, enabled on the engine Safe (`avatar == target ==
juniorTrancheEngine`). It owns the emissions + governance leg of the auto-compounder, in five operator-only actions:
1. `claimReward` — `gauge.getReward()` claims the gauge's oHYDX to the Safe.
2. `lockVe(amount)` — the FREE vote-floor permalock: `oHYDX.exerciseVe(amount, juniorTrancheEngine)` burns oHYDX and
   mints a fresh account-owned veHYDX NFT to the Safe (grows the Safe's account-aggregate voting power).
3. `vote(pools, weights)` / `resetVote()` — account-keyed re-vote / clear (votes reset weekly).
4. `claimRebase(tokenIds)` — per-veNFT anti-dilution rebase (`claim_many`).

**The §10.1 security boundary:** the operator supplies ONLY scalars/arrays (`amount`, `poolVote`/`weights`,
`tokenIds`). The module builds all calldata to set-once wired targets, the `exerciseVe` recipient is **hard-pinned**
to the literal `juniorTrancheEngine`, every balance/floor read is `juniorTrancheEngine`, `value==0`, no
delegatecall/passthrough. The Voter is **account-keyed** (no tokenId) — the veNFT and votes accrue to the Safe purely
because the Safe is the `exec` msg.sender. **No `tokenId` state, no token approvals** — every call acts on the Safe's
own holdings/account directly.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `claimReward()` | operator-only | 1 exec: `gauge.getReward()` → oHYDX to the Safe |
| `lockVe(amount)` | operator-only | 1 exec: `exerciseVe(amount, juniorTrancheEngine)`; decodes + emits fresh `nftId`; `ZeroAmount` guard |
| `vote(pools, weights)` | operator-only | `EmptyArray`/`LengthMismatch` guards; account-keyed |
| `resetVote()` | operator-only | clears the epoch vote (unwind/emergency) |
| `claimRebase(tokenIds)` | operator-only | `EmptyArray` guard; tolerates an imperfect operator-curated array |
| `pendingReward` / `voteFloor` / `rebaseClaimable` | `view` | all read `juniorTrancheEngine`, not the caller |
| `setUp` + 7 × `setX` | `initializer` / `onlyOwner` | clone init; build-phase wiring re-points (`setJuniorTrancheEngine` syncs `avatar`/`target`) |

No permissionless mutators. No custody, no approvals, no recipient parameter except the pinned `juniorTrancheEngine`.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **`exerciseVe` recipient hard-pinned** — the veHYDX NFT mints only to `juniorTrancheEngine` | Yes | `test_exec_shape_lockVe_decodes_nftId_and_recipient` (decodes recipient arg == Safe), **`test_fork_real_exerciseVe_fresh_nft_account_aggregate`** (`veC.ownerOf(nftId) == juniorTrancheEngine`) |
| I-2 | **one exec per action, `value==0`, Call-only, no passthrough, NO token approvals** | Yes | `test_exec_shape_claimReward`/`_lockVe`/`_vote`/`_resetVote`/`_claimRebase` (each `callCount==1`, exact calldata), fork: "exactly `amount` oHYDX burned (NO approval)" |
| I-3 | **account-keyed + stateless** — no `tokenId` state; veNFT/votes accrue to the Safe as msg.sender; account-aggregate | Yes | **`test_fork_real_exerciseVe_fresh_nft_account_aggregate`** (two locks → two *distinct* fresh NFTs, aggregate votes grow each time) |
| I-4 | **exec false-return hard-reverts with bubbled inner data** (the Safe swallows reverts otherwise) | Yes | `test_exec_bubbles_custom_error` (surfaces `TargetBoom`), `test_exec_bubbles_no_data_ExecFailed`, `test_lockVe_reverts_on_short/empty_return_data` |
| I-5 | **views read `juniorTrancheEngine`**, never the caller/operator | Yes | `test_views_read_juniorTrancheEngine`, **`test_views_pass_oHYDX_and_juniorTrancheEngine`** (`expectCall` pins `earned(oHYDX, engine)` + `getVotes(engine)`) |
| I-6 | **live-read targets** — `oHYDX = gauge.rewardToken()`, `ve = voter.ve()` (can't drift from the real deps) | Yes | `test_setUp_rejects_zero_rewardToken_live`, `test_setUp_rejects_zero_ve_live`, **`test_fork_sig_verify`** (live oHYDX/ve match) |
| I-7 | **`claimRebase` tolerates an imperfect array** — the rebase credits each veNFT's own lock, can't be redirected | Yes | **`test_fork_real_claimRebase`** (asserts both the consumed and the empty-tolerance branch) |
| X-1 | §10.1 residual: operator trusted for `(amount, pools/weights, tokenIds)` — bounded, not theft | **No** | recipient pin + account-keyed + no-approvals cap it on-chain; the `lockVe` over-lock grief (below) is the residual |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr (×6) / owner==operator / live-zero oHYDX & ve | `test_setUp_rejects_zero_in_each_of_six`, `_rejects_owner_equals_operator`, `_rejects_zero_rewardToken_live`, `_rejects_zero_ve_live` |
| `initializer` once + mastercopy lock (SEC-14) | `test_setUp_initializer_once`, `test_SEC14_mastercopy_setUp_reverts`, `test_mastercopy_inert` |
| `setOperator` owner-recheck (SEC-15) | `test_SEC15_setOperator_owner_recheck` |
| `NotOperator` on all 5 mutators | `test_entrypoints_only_operator`, `test_fork_non_operator_reverts` |
| `ZeroAmount` / `EmptyArray` / `LengthMismatch` | `test_guards` |
| operator cannot redirect Safe (`setAvatar`/`setTarget`) | `test_operator_cannot_redirect_safe` |
| 6 wiring setters (`setJuniorTrancheEngine`/`setGauge`/`setVoter`/`setRewardsDistributor`/`setOHYDX`/`setVe`) | `test_wiring_setters_onlyOwner_effect_and_zeroGuard` (onlyOwner + effect + zero-guard, all 6; + `setJuniorTrancheEngine` syncs `avatar`/`target`) |

## 5. Attack surfaces

- **The recipient pin + account-keying are the whole safety story (I-1/I-3) — proven on a live fork** — `exerciseVe`
  mints the veNFT to the literal `juniorTrancheEngine`; votes and the veNFT accrue to the Safe purely as the exec
  msg.sender, with no tokenId state. `test_fork_real_exerciseVe_fresh_nft_account_aggregate` confirms two locks mint
  two distinct Safe-owned NFTs and the account aggregate grows — there is no per-id handle an operator could redirect.
- **`lockVe` is an irreversible permalock (the §13 residual, X-1)** — it burns sellable oHYDX into a *permalocked*
  veHYDX position. A compromised/clumsy operator can **grief** by over-locking (converting liquid emissions into
  illiquid governance weight), but the value accrues to the Safe — never theft, never a third party (recipient
  pinned). Bounded by design; the off-chain 8-B11 robot sizes the vote-floor slice. Worth noting in ops runbooks as a
  one-way action.
- **Heaviest external-integration surface of the fleet** — gauge / voter / voting-escrow / rewards-distributor, each
  account-keyed. The fork suite exercises the *real* Hydrex contracts and even reproduces the live Voter's
  epoch-snapshot + per-account vote-delay sequencing (`test_fork_real_vote_and_reset`) — strong evidence the seam
  matches mainnet behavior, not just a mock.
- **Bubbled reverts prevent silent success (I-4)** — `_exec` re-throws the inner Hydrex revert data so a swallowed
  failed claim/lock/vote can't report success; tested with custom error, empty data, and short/empty `lockVe`
  return decodes.
- **The 6 wiring setters — now covered** — `test_wiring_setters_onlyOwner_effect_and_zeroGuard` exercises
  `setJuniorTrancheEngine`/`setGauge`/`setVoter`/`setRewardsDistributor`/`setOHYDX`/`setVe` for all three: a non-owner
  reverts `OwnableUnauthorizedAccount`, an owner re-point updates the slot, and zero reverts `ZeroAddress`. With
  `setOperator` (SEC-15) that closes every wiring setter; **every mutator on the contract is now exercised**.
- **No fuzz/invariant — correctly omitted** — each action is a single deterministic `exec` with no internal
  arithmetic; the live-fork tests are the higher-value check and they exist.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 24 | setUp/guards, SEC-14/15 clone-safety, all 7 wiring setters (onlyOwner/effect/zero-guard), the fully-pinned exec-shape proof for all 5 mutators, the bubble/atomicity matrix, view-target pinning (`expectCall`) |
| Base-fork | 5 | live Hydrex: sig-verify, real `exerciseVe` (fresh NFT + account-aggregate + no approval), real `vote`/`reset` (with live epoch-snapshot + vote-delay handling), real `claimRebase` (empty-tolerance), non-operator revert |
| Stateless fuzz / invariant | 0 | deterministic single-execs; fork is the higher-value check |

All **29 pass** (`forge test --match-path test/HarvestVoteModule.t.sol`). The decisive properties (recipient pin,
account-keyed statelessness, no approvals, bubbled reverts) are tested unit + live-fork. Coverage % uninstrumentable
(project-wide stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** — a clean fleet module with the heaviest external-integration surface, and the suite rises to it: every
action's exec shape is pinned, the recipient pin and account-keyed statelessness are proven against the **real**
Hydrex gauge/voter/ve/rewards-distributor (including the live Voter's epoch + vote-delay quirks), no token approvals
exist, and bubbled reverts prevent silent success. **Every mutator is now exercised** (all 7 setters + the 5 operator
actions; the 6-setter gap flagged in the first draft was filled). Capped at ADEQUATE by: no fuzz/invariant
(correctly low-value for stateless single-execs), the §13 `lockVe` over-lock grief residual (bounded to the Safe,
never theft), and the build-phase mutable wiring pending the pre-prod re-freeze — none a coverage gap.

**Structural facts:**
1. 142 nSLOC; clone (`MastercopyInitLock` + `initializer`, no immutable); no custody, no approvals, no tokenId state.
2. 5 operator-only actions; `exerciseVe` recipient + all balance reads hard-pinned to `juniorTrancheEngine`; account-keyed Voter (veNFT/votes accrue to the Safe as msg.sender).
3. `oHYDX`/`ve` live-read off `gauge.rewardToken()`/`voter.ve()`; `value==0`, Call-only, no passthrough; `_exec` bubbles inner reverts.
4. Tests: 24 unit + 5 base-fork (0 fuzz/invariant); every mutator exercised; real exerciseVe/vote/reset/claimRebase against live Hydrex.
5. No outstanding coverage gap on the contract surface; residuals are off-chain (the §13 `lockVe` over-lock grief, the pre-prod wiring re-freeze).
