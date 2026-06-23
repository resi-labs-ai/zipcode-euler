# SUPPLY-ADV-11 — `HarvestVoteModule.setJuniorTrancheEngine` must sync `avatar`/`target` (conform to the 5 syncing siblings)

> **STATUS: BUILT (2026-06-23) — SHIPPED to `main`.** `setJuniorTrancheEngine` now sets `avatar`/`target` alongside
> `juniorTrancheEngine` (`HarvestVoteModule.sol:130-138`), matching the 5 syncing siblings; setter NatSpec updated.
> `test_wiring_setters_onlyOwner_effect_and_zeroGuard` asserts `avatar()`/`target()` track the re-point. Scoped suite
> **29/29 green**, `forge build` clean. Doc-sync in the same commit: X-Ray `HarvestVoteModule.md` §2/§4 + wire
> `docs/wires/8-B7-HarvestVoteModule.md`. All acceptance criteria met. No fix divergence.

> BUILD item (LOW). Owner-only (Timelock), build-phase, honest-path-recoverable. Worth doing because the fix is the
> same two-line sync already shipped for RecycleModule (`SUPPLY-ADV-08`), HarvestVote is now the lone remaining engine
> outlier whose desync can MOVE VALUE (it redirects the veNFT recipient rather than failing closed), and the module's
> own stated invariant is `avatar == target == juniorTrancheEngine`.
>
> Source: adversarial-review on `contracts/src/supply/szipUSD/HarvestVoteModule.sol`
> (`adversarial-review/reports/src/supply/harvestvotemodule/synthesis.md`, mission 4). Single-model (Claude-only)
> baseline run — not the full decorrelated panel.

## The gap (verified in code)

`setUp` pins the engine-Safe invariant `avatar == target == juniorTrancheEngine` (`HarvestVoteModule.sol:93-97`;
NatSpec `:75` — "set `avatar = target = juniorTrancheEngine`"). The re-point setter updates **only** the convenience
slot, not the inherited Zodiac executor slots:

```solidity
function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {   // :130
    if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
    juniorTrancheEngine = juniorTrancheEngine_;   // :132  <- only this slot
    emit WiringSet("juniorTrancheEngine", juniorTrancheEngine_);
}
```

`_exec` always drives `IAvatar(target)` (`reference/zodiac-core/contracts/core/Module.sol:66`). But
`juniorTrancheEngine` is the `exerciseVe` **recipient** and the subject of every read:

```solidity
_exec(oHYDX, abi.encodeCall(IOptionToken.exerciseVe, (amount, juniorTrancheEngine)));   // :208 — recipient
IGauge(gauge).earned(oHYDX, juniorTrancheEngine);                                       // :240 — pendingReward
IVotingEscrow(ve).getVotes(juniorTrancheEngine);                                        // :245 — voteFloor
```

After `setJuniorTrancheEngine(NEW)` **without** a paired `setAvatar`/`setTarget`: `target`/`avatar` still point at
the OLD Safe, so `lockVe` makes the **OLD** Safe (the exec msg.sender) execute `oHYDX.exerciseVe(amount, NEW)` — it
burns the OLD Safe's oHYDX but mints the fresh veHYDX NFT to **NEW**. `claimReward` credits OLD; `pendingReward`/
`voteFloor` report NEW; `vote`/`resetVote`/`claimRebase` stay account-keyed on OLD (no `juniorTrancheEngine` arg).
The desync is partial, confusing, and — uniquely — value-moving.

## Why it's LOW, not higher (don't over-fix)

- **Owner-only + honest-path-recoverable.** Only the Timelock can re-point, and the intended deploy/re-freeze flow
  re-points `setAvatar`/`setTarget` alongside; the same Timelock un-splits it. Build-phase, closed by the pre-prod
  immutable re-freeze (X-2 accepted residual).
- **No new capability for a malicious owner.** A compromised Timelock already controls `setAvatar`/`setTarget`/
  `setOperator` directly — this path adds nothing it couldn't already do.
- **The operator can't reach it.** `onlyOwner`; the CRE hot key has only the 5 actions.

## Why it's still worth fixing — sharper than the Recycle precedent

`SUPPLY-ADV-08` patched RecycleModule's identical setter and explicitly judged HarvestVote's omission "acceptable —
its `juniorTrancheEngine` is a *subject* (recipient), not an executor-proxy" (that ticket's "Open question"). That
reasoning is **backwards for value-safety**:

- **Recycle's desync FAILS CLOSED.** `juniorTrancheEngine` is read as an executor-proxy inside `BackingShortfall`;
  a desync makes the guard revert (`0 != usdcAmount`). Nothing moves; it bricks loudly.
- **HarvestVote's desync MOVES VALUE.** `juniorTrancheEngine` is the `exerciseVe` recipient; a desync makes `lockVe`
  **succeed** and silently mint the veNFT (and sink the burned oHYDX value) to NEW while the cost is borne by OLD.
  It does not revert.

So precisely because it is a subject/recipient, HarvestVote is the one non-syncing engine module where the desync
redirects rather than reverts — the case the §10.1 "exec'ing Safe == pinned recipient" coupling exists to prevent.

It is also a fleet asymmetry: **5 of 6** engine modules now sync (`avatar = target = juniorTrancheEngine_`) —
`RecycleModule:193-194` (SUPPLY-ADV-08), `SellModule:149-150`, `ExerciseModule:116-117`, `LpStrategyModule:137-138`,
`FarmUtilityLoopModule`. HarvestVote is the lone holdout (`SzipBuyBurnModule` is not an engine-Safe Zodiac module of
this family). No design reason supports leaving it unsynced; the invariant `avatar == target == juniorTrancheEngine`
is the module's own stated contract (NatSpec `:75`, X-Ray `:17`, wire `:42`).

## The fix (recommended)

Add the two slot syncs to `setJuniorTrancheEngine` (`HarvestVoteModule.sol:130`), exactly as the 5 syncing siblings:

```solidity
function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {
    if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
    juniorTrancheEngine = juniorTrancheEngine_;
    avatar = juniorTrancheEngine_;   // + keep the engine-Safe invariant: avatar == target == juniorTrancheEngine
    target = juniorTrancheEngine_;   // + (juniorTrancheEngine is the exerciseVe recipient — must equal the exec'ing Safe)
    emit WiringSet("juniorTrancheEngine", juniorTrancheEngine_);
}
```

Update the setter NatSpec (`:129`) to note the lockstep sync, matching `SellModule`.

## Regression test

Extend `test_wiring_setters_onlyOwner_effect_and_zeroGuard` (`HarvestVoteModule.t.sol`) — after the
`setJuniorTrancheEngine(x)` re-point assert (`:317-318`), add:

```solidity
assertEq(m.avatar(), x, "avatar synced to juniorTrancheEngine");
assertEq(m.target(), x, "target synced to juniorTrancheEngine");
```

(Folding into the existing wiring test matches the syncing siblings; a dedicated
`test_setJuniorTrancheEngine_syncs_avatar_and_target` like `ExerciseModule`'s is an equivalent option.)

## Documentation propagation (same commit — X-Ray is code-truth)

Grep-verified targets carrying the affected claim:

- **`contracts/src/supply/szipUSD/x-ray/HarvestVoteModule.md`** (authoritative):
  - §2 entry-points (`:42`): annotate the `setUp + 7 × setX` row "(`setJuniorTrancheEngine` syncs avatar/target)",
    matching `SellModule.md` / `ExerciseModule.md` / the patched `RecycleModule.md`.
  - §4 guards (`:69`): add "+ the `setJuniorTrancheEngine` avatar/target sync" to the
    `test_wiring_setters_onlyOwner_effect_and_zeroGuard` row.
- **`docs/wires/8-B7-HarvestVoteModule.md`** (`:42`): note that `setJuniorTrancheEngine` moves `avatar`/`target` in
  lockstep at re-point (not only at `setUp`), mirroring `docs/wires/8-B9-SellModule.md`.

Out of scope (separate `juniorTrancheEngine` wires, not the Zodiac avatar/target): the SzipNav/ExitGate denominator
chain and any borrow-allowlist setters.

## Acceptance criteria

- `setJuniorTrancheEngine` sets `avatar` and `target` alongside `juniorTrancheEngine`.
- `test_wiring_setters_onlyOwner_effect_and_zeroGuard` asserts `avatar`/`target` track the re-point. Scoped suite
  (`test/supply/szipUSD/HarvestVoteModule.t.sol`) green (29 → 29, assertions added).
- `forge build` clean.
- X-Ray (`HarvestVoteModule.md` §2/§4) + the wire doc (`8-B7-HarvestVoteModule.md`) reflect the lockstep sync.
