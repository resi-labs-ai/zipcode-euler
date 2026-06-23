# SUPPLY-ADV-08 — `RecycleModule.setJuniorTrancheEngine` must sync `avatar`/`target` (match the 4 syncing siblings)

> **STATUS: BUILT (2026-06-23) — SHIPPED to `main`.** `setJuniorTrancheEngine` now sets `avatar`/`target`
> alongside `juniorTrancheEngine` (`RecycleModule.sol:188-190`), matching the 4 syncing siblings; setter NatSpec
> updated. `test_wiring_setters_repoint_only_owner` asserts `avatar`/`target` track the re-point and its docstring
> no longer claims "no sync to assert". Scoped suite **42/42 green**, `forge build` clean. Doc-sync done in the
> same commit: X-Ray `RecycleModule.md` §2/§4/§5 + wire `docs/wires/8-B10-RecycleModule.md:129`. All acceptance
> criteria met. No fix divergence. Reviewer flag (HarvestVote/SzipBuyBurn framing) left as a non-blocking note.
>
> Source: adversarial-review on `contracts/src/supply/szipUSD/RecycleModule.sol`
> (`adversarial-review/reports/src/supply/recyclemodule/synthesis.md`, mission 4). A consistency-vs-siblings
> finding promoted from INFO to LOW after a fleet trace: Recycle is the one non-syncing module that also
> consumes `juniorTrancheEngine` as an **executor-proxy** inside a value-conservation guard.

> BUILD item (LOW). Fail-closed, owner-only (Timelock), build-phase, self-recoverable — never a drain, never
> value invention; `recycle` is unaffected. Worth doing because the fix is a two-line sync that the majority
> of siblings already carry, it removes a latent guard/executor mismatch, and the current test + X-Ray
> actively document the omission as intentional ("no sync to assert") when no design reason supports it.

## The gap (verified in code)

`setUp` pins the engine-Safe invariant `avatar == target == juniorTrancheEngine` (`RecycleModule.sol:160-163`;
NatSpec `:36`, `:159` — "the module is enabled ON the engine Safe and only ever mutates it"). The re-point
setter updates **only** the convenience slot, not the inherited Zodiac executor slots:

```solidity
function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {   // :186
    if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
    juniorTrancheEngine = juniorTrancheEngine_;   // :188  <- only this slot
    emit WiringSet("juniorTrancheEngine", juniorTrancheEngine_);
}
```

`_exec` always drives `IAvatar(target)` (`reference/zodiac-core/contracts/core/Module.sol:66`). `divert` reads
the convenience slot as the executor-proxy for its hard-backing guard:

```solidity
address safe = juniorTrancheEngine;                                   // :325
uint256 beforeUsdc = IERC20(usdc).balanceOf(safe);                    // :328
_exec(pool, abi.encodeCall(IEulerEarn.deposit, (usdcAmount, wh)));    // :330 — executes via target
if (beforeUsdc - IERC20(usdc).balanceOf(safe) != usdcAmount) revert BackingShortfall();   // :332
```

After `setJuniorTrancheEngine(newSafe)` **without** a paired `setAvatar`/`setTarget`: the deposit pulls USDC
from the **old** Safe (still `target`), but `divert` snapshots the **new** Safe's balance (unchanged) →
`0 != usdcAmount` → `BackingShortfall` reverts. `divert` bricks until the operator re-syncs via the inherited
`setAvatar`/`setTarget`.

## Why it's LOW, not higher (don't over-fix)

- **Fail-closed, not a drain.** The guard reverts the whole tx; no USDC leaves under a broken check, no value
  is invented, no shares are misrouted. The only way it could *mask* a real shortfall is if the new Safe
  independently lost exactly `usdcAmount` in the same tx — unreachable via this path (the executor is the old
  Safe).
- **Owner-only + self-recoverable.** Only the Timelock can re-point, and the same Timelock un-bricks it with
  `setAvatar`/`setTarget`. Build-phase, closed by the pre-prod immutable re-freeze (X-2).
- **`recycle` is unaffected** — it never reads `juniorTrancheEngine`; it drives `deposit` through `target` and
  `ZipDepositModule.deposit` pulls from `msg.sender == target` (`ZipDepositModule.sol:117`), so it stays
  internally consistent regardless of the convenience slot.

## Delta from posture / precedent (the promote-to-LOW rationale)

The X-Ray §5 framing ("`setJuniorTrancheEngine` does NOT sync avatar/target here — **unlike the other engine
modules** — so there was no sync to assert") is imprecise on two counts:

1. **It is a 4-vs-3 split, not Recycle-vs-everyone.** Syncing: `SellModule:146`, `ExerciseModule:113`,
   `LpStrategyModule:130`, `FarmUtilityLoopModule:149` (each does `avatar = target = juniorTrancheEngine_`,
   documented as a feature — see `docs/wires/8-B9-SellModule.md:189`: *"moves three slots ... the three must
   never diverge"*). Non-syncing: `HarvestVoteModule:130`, `SzipBuyBurnModule:250`, `RecycleModule:186`.
2. **Recycle is the only non-syncing module where the omission bites.** The other two consume
   `juniorTrancheEngine` as a *semantic subject* — HarvestVote: `exerciseVe(…, jte)` `:208`,
   `gauge.earned(…, jte)` `:240`, `getVotes(jte)` `:245`; SzipBuyBurn: the CoW order owner
   `abi.encodePacked(…, jte, …)` `:449` — so a desync changes a recipient/subject, not a guard account.
   Recycle alone uses it as an **executor-proxy** (`safe`, `:325`) inside `BackingShortfall`, where it MUST
   equal `target`.

No design reason supports leaving Recycle unsynced; the invariant `avatar == target == juniorTrancheEngine` is
the module's own stated contract. The fix conforms Recycle to the 4 syncing siblings.

## The fix (recommended)

Add the two slot syncs to `setJuniorTrancheEngine` (`RecycleModule.sol:186`), exactly as the 4 syncing
siblings do:

```solidity
function setJuniorTrancheEngine(address juniorTrancheEngine_) external onlyOwner {
    if (juniorTrancheEngine_ == address(0)) revert ZeroAddress();
    juniorTrancheEngine = juniorTrancheEngine_;
    avatar = juniorTrancheEngine_;   // + keep the engine-Safe invariant: avatar == target == juniorTrancheEngine
    target = juniorTrancheEngine_;   // + (divert's BackingShortfall reads juniorTrancheEngine as the executor)
    emit WiringSet("juniorTrancheEngine", juniorTrancheEngine_);
}
```

Update the setter NatSpec (`:185`) to note the lockstep sync, matching `SellModule`.

## Regression test

Extend `test_wiring_setters_repoint_only_owner` (`RecycleModule.t.sol:429`) — after the
`setJuniorTrancheEngine(x)` re-point assert (`:456`), add:

```solidity
assertEq(m.avatar(), x, "avatar synced to juniorTrancheEngine");
assertEq(m.target(), x, "target synced to juniorTrancheEngine");
```

and drop the docstring's "does NOT sync avatar/target here ... so there is no sync to assert" (`:427-428`).
(Folding into the existing wiring test matches `SellModule`/`LpStrategyModule`/`FarmUtilityLoopModule`; a
dedicated `test_setJuniorTrancheEngine_syncs_avatar_and_target` like `ExerciseModule`'s is an equivalent
option.)

## Documentation propagation (same commit — X-Ray is code-truth)

Grep-verified targets carrying the affected claim:

- **`contracts/src/supply/szipUSD/x-ray/RecycleModule.md`** (authoritative):
  - §2 entry-points (`:40`): annotate the `setUp + 7 × setX` row "(`setJuniorTrancheEngine` syncs avatar/target)",
    matching `SellModule.md:36` / `ExerciseModule.md:39`.
  - §4 guards (`:69`): add "+ the `setJuniorTrancheEngine` avatar/target sync" to the
    `test_wiring_setters_repoint_only_owner` row.
  - §5 (`:86-89`): rewrite the parenthetical — `setJuniorTrancheEngine` now syncs `avatar`/`target` in lockstep
    (SUPPLY-ADV-08), matching the syncing siblings; drop the incorrect "unlike the other engine modules / no
    sync to assert" framing.
- **`docs/wires/8-B10-RecycleModule.md`** (`:129`): note that `setJuniorTrancheEngine` moves `avatar`/`target`
  in lockstep (mirroring `docs/wires/8-B9-SellModule.md:189`).

Out of scope (separate `juniorTrancheEngine` wires, not the Zodiac avatar/target): the
`SzipNavOracle`/`ExitGate`/`SzipBuyBurnModule` denominator-exclusion chain (`docs/wires/README.md` pattern 3),
and `FarmUtilityBorrowGuard`'s borrow-allowlist setter.

## Open question for the reviewer (not blocking)

`HarvestVoteModule` / `SzipBuyBurnModule` also don't sync. Leaving them unsynced is acceptable — their reads
are subjects, not executor-proxies — but the X-Ray framing on those two ("no sync to assert") could be
tightened to say *why* (subject-only consumption) rather than implying it's universal. Out of scope for this
ticket; flag only.

## Acceptance criteria

- `setJuniorTrancheEngine` sets `avatar` and `target` alongside `juniorTrancheEngine`.
- `test_wiring_setters_repoint_only_owner` asserts `avatar`/`target` track the re-point; its docstring no
  longer claims "no sync to assert". Scoped suite (`test/supply/szipUSD/RecycleModule.t.sol`) green.
- `forge build` clean.
- X-Ray (`RecycleModule.md` §2/§4/§5) + the wire doc (`8-B10-RecycleModule.md`) reflect the sync; the
  "unlike the other engine modules" claim is removed.
