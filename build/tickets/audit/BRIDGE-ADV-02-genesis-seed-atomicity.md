# BRIDGE-ADV-02 — Make the SzAlpha genesis seed structural, not procedural (subsumes BRIDGE-ADV-03)

> **STATUS: BUILT (2026-06-22)** on branch `audit/bridge-adv-02-seed-slippage`, awaiting review/merge.
> Shipped: `SlippageFloorRequired` + the genesis-exempt deposit floor & unconditional redeem floor
> (`SzAlpha.sol`); `deploy964` seeds in-broadcast + burns to `0xdead` + `totalSupply()>0` assert, standalone
> `seedDeposit` removed (`DeploySzAlphaBridge.s.sol`); 44 test floors swept to non-zero + 3 new floor tests
> (`SzAlphaBridge.t.sol`); bridge suite **58/58 green**, `forge build` clean. Doc-sync done: X-Ray
> `SzAlpha.md` (entry-points + G-8/G-14), wire `8x-01`, `RUNBOOK:146`, the donation NatSpec. All acceptance
> criteria below met.

> BUILD item (LOW). Source: adversarial-review pilot on `contracts/src/bridge/SzAlpha.sol`
> (`adversarial-review/reports/src/bridge/szalpha/synthesis.md`, missions 1+2). A differential-vs-Rubicon
> finding: the first-depositor protection the donation note credits to "a genesis seed deposit" is a
> manual post-deploy step, leaving a permissionless window the fix below removes.
>
> **Subsumes BRIDGE-ADV-03** (mandatory non-zero slippage floor). The two share one code path: the seed
> is the *only* legitimate `minSharesOut == 0` caller (grep-verified — no CRE/keeper/module deposits with
> zero; only the seed + tests), and the condition that makes a zero floor legitimate is exactly
> "genesis, supply 0" — the same condition this ticket is about. Designing them apart risks a later
> blanket `revert` on `min == 0` breaking the now-in-broadcast seed. See "Folds in BRIDGE-ADV-03" below.

## The gap (verified in code)

`SzAlpha.deposit` is `whenNotPaused` (`SzAlpha.sol:176`) and `initialize` leaves the contract **unpaused**
at genesis (`__Pausable_init()` initializes to not-paused, `SzAlpha.sol:144`; `owner()` is the timelock,
`:143`). So `deposit` is permissionless and open from the instant the proxy is created —
`DeploySzAlphaBridge.s.sol:105` (`new ERC1967Proxy(...)`).

The seed that closes the first-depositor griefing window is a **separate, manually-invoked** function:
`seedDeposit(SzAlpha)` (`DeploySzAlphaBridge.s.sol:161-163`), listed as a manual checklist item in
`contracts/script/RUNBOOK-mainnet-deploy.md:146`. `deploy964` (`:91-154`) never calls it.

Result: between the proxy going live (`:105`, deposit open, supply 0) and the operator manually running
`seedDeposit`, the contract is a live, permissionless, zero-supply vault — exactly the first-depositor
state the seed exists to prevent.

## Why it's LOW, not higher (don't over-fix)

The window is self-limiting and already backstopped, per SzAlpha's own donation note (`SzAlpha.sol:38-46`):
- First-depositor inflation here is **value-destroying**: to skew a victim depositing `V`, the attacker
  must donate ≥ `V` via `transferStake`, and all of it accrues to other holders (irrecoverable gift).
- A deposit rounding to zero shares **reverts** (`ZeroSharesOut`, `SzAlpha.sol:197`) rather than
  silently losing funds.
- A careful depositor is shielded by `minSharesOut` (see BRIDGE-ADV-03).

So the realistic blast radius is **griefing / DoS of the genesis announce sequence**, not theft. The fix
is worth doing because it is cheap and removes the window entirely — not because the window is dangerous.

## Delta from precedent

Rubicon's `_exchangeRate()` hard-returns `1e18` whenever `totalSupply()==0` or `totalStaked==0`
(`reference/rubicon/LiquidStakedV3.flattened.sol:3421-3422`) — its genesis rate is pinned 1:1 **by code**
and is immune to a pre-seed donation. SzAlpha replaced that branch with a live OZ 1/1 virtual-offset
`mulDiv` (`SzAlpha.sol:264-266`), which moves with a pre-seed donation, then leans on the out-of-band
seed to restore the protection. The seed must therefore be as reliable as the code branch it replaced.

## The fix (recommended — Option A: seed in-broadcast)

Fold the seed into `deploy964` as its final genesis step, so it runs in the same deploy broadcast,
before the script returns and before any public announcement. `deposit` is permissionless and unpaused,
and the deployer holds 964-native TAO, so no contract change is needed:

1. In `deploy964` (`DeploySzAlphaBridge.s.sol`), after the proxy + wiring + admin handoff, add:
   `uint256 seedShares = token.deposit{value: SEED_TAO}(0, type(uint256).max);`
   then send the seed shares to the burn sink: `token.transfer(address(0xdead), seedShares);`
   (`SEED_TAO ≈ 1 TAO`, matching the current runbook value.)
2. Add an end-of-function assert so a broadcast that didn't seed fails loudly:
   `require(token.totalSupply() > 0, "genesis not seeded");`
3. Delete the standalone `seedDeposit` (`:161-163`) and remove the manual seed line from the runbook
   (`RUNBOOK-mainnet-deploy.md:146`) — or keep `seedDeposit` only as a labeled emergency fallback, not
   the primary path.

This shrinks the window from "until a human remembers, post-announcement" to "the gap between two
consecutive deployer txs in the same pre-announcement broadcast."

## Residual (be honest in the X-Ray)

Option A does **not** mathematically eliminate the window: on a public mempool an attacker could in
principle front-run the seed between the proxy-creation tx and the seed tx within the same block.
Combined with the value-destroying + `ZeroSharesOut` + `minSharesOut` backstops, this residual is
acceptable for a LOW. If **zero window** is required, the only fully-atomic options are more invasive and
likely overkill here:
- a `payable` `initialize` that performs the genesis stake+mint inside the proxy-creation tx (adds
  precompile staking to the initializer — new surface, higher risk), or
- a single-tx deployer helper contract whose constructor creates the proxy and seeds in one tx.

Recommend Option A; record the residual rather than chasing atomicity for a self-limiting LOW.

## Folds in BRIDGE-ADV-03 — mandatory non-zero slippage floor

Rubicon hard-reverts a zero floor on every leg (`InvalidMinAmount`,
`reference/rubicon/LiquidStakedV3.flattened.sol:3331/3531/3615/3711`); SzAlpha allows `0 = unbounded`
(`SzAlpha.sol:198/244`, NatSpec `:168-169`), leaving integrators with no per-call magnitude protection.
ADV-02 does NOT remove the zero-floor caller — the seed still deposits with `0` (no genesis rate to
derive a floor from). But the *only* legitimate zero-floor case is genesis (`totalSupply() == 0`), which
is on-chain checkable, so the floor becomes two small guards — no new function, no new surface:

- **`redeem`** (`SzAlpha.sol:244`): `if (minTaoOut == 0) revert SlippageFloorRequired();` — unconditional.
  Nothing redeems at supply 0 and the seed never redeems, so there is no legitimate zero-redeem caller.
- **`deposit`** (`SzAlpha.sol:198`): `if (minSharesOut == 0 && totalSupply() != 0) revert SlippageFloorRequired();`
  — permits only the genesis (supply-0) deposit (the seed) to skip the floor; every deposit after the
  seed must set a real minimum. (The ADV-02 front-run residual is unchanged: an attacker who front-runs
  the seed is the genesis deposit and may pass 0 — same self-limiting window, no worse.)

**Cost — this is why it's coupled, not separate.** The bridge suite passes `0` floors pervasively
(`contracts/test/bridge/SzAlphaBridge.t.sol` — `deposit{...}(0, MAX_DL)` / `redeem(..., 0, MAX_DL)`
throughout). These tests must be updated to pass a real floor (a `1` lower bound, or a
`previewDeposit/previewRedeem`-minus-tolerance value) — except the genesis-seed test, which legitimately
keeps `0`. Folding ADV-03 here means that test pass happens once, with the seed refactor, instead of
twice. A negative test should assert a non-genesis `deposit(0, ...)` / `redeem(..., 0, ...)` now reverts.

(Alternative considered: a dedicated `seedGenesis()` that blanket-reverts `deposit` on `0`. Rejected —
adds a privileged genesis-mint surface where a one-line `totalSupply() == 0` exception suffices.)

## Doc tightening (do alongside the code)

`SzAlpha.sol:45` currently reads "the deploy script makes a small SEED DEPOSIT at genesis, closing even
the griefing window" — true only once Option A lands. Until then (and in the X-Ray), describe it as the
procedural step it is. After Option A, the wording is accurate. Update `seedDeposit`'s NatSpec / runbook
accordingly.

## Next step — documentation propagation (after the code + tests land)

The X-Ray and wire docs are code-truth; update them only once the contract/deploy change is merged, so
they describe the shipped state — not the plan. Targets below are grep-verified to carry the affected
claims (seed / redeem-pausability / slippage floor); re-grep before each edit per house discipline, and
keep docs house style (no tables/emojis in `docs/`). Record the *outcome*, not the journey.

**Primary — `contracts/src/bridge/x-ray/SzAlpha.md`** (per-contract authority):
- Entry-points table (`§2`): `deposit`/`redeem` now require a non-zero floor (genesis-exempt) — drop any
  "0 = unbounded" implication.
- Guards (`§4`) / invariants: note the mandatory slippage floor (ties to G-8/G-14); the genesis seed is
  now structural (in-broadcast), not procedural.
- Attack surfaces (`§5`): the pause-asymmetry residual gets a one-line **accepted-runtime-trust** note
  (ADV-01, WONTFIX) — the precompile-compromise incident was examined and consciously accepted (X-1
  dependency). *This ADV-01 note is the one edit landable now, independent of the code change.*

**Other bridge X-Ray files** (`contracts/src/bridge/x-ray/`):
- `invariants.md` — G-8 (deposit slippage) / G-14 (redeem slippage): record the non-zero requirement;
  donation/first-depositor note: seed is now enforced in-deploy.
- `entry-points.md` — `deposit`/`redeem` detail + the seed reference.
- `x-ray.md` (scope overview) — adversary-ranking #6 (donation/first-depositor) and the redeem-pause line.

**docs/:**
- `docs/wires/8x-01-szALPHA-bridge.md` — carries all three topics (seed, redeem-pausability, slippage);
  update the wiring narrative to the shipped behavior.
- `docs/bridge.md` — the only relevant line is "`redeem()` is never pausable by design" (`:20`): keep it
  (still true), and add the ADV-01 acceptance note (precompile-compromise incident examined + accepted).

(If the team prefers regeneration over hand-edits, re-running the x-ray skill on the bridge scope is an
option — but these per-contract verdicts are hand-curated post-split, so targeted edits are cleaner.)

## Acceptance criteria

- `deploy964` seeds within the same broadcast; `seedDeposit` is gone (or demoted to fallback).
- A new deploy test asserts `token.totalSupply() > 0` at the end of `deploy964` and that the seed shares
  landed at `0xdead` (no live genesis position).
- **(ADV-03)** `redeem` reverts on `minTaoOut == 0`; `deposit` reverts on `minSharesOut == 0` unless
  `totalSupply() == 0`. The genesis seed (supply-0 deposit) still passes; every later deposit/redeem
  needs a real floor.
- **(ADV-03)** Bridge tests updated to pass non-zero floors (except the genesis-seed test); a negative
  test asserts a non-genesis `deposit(0,...)` / `redeem(...,0,...)` reverts. Full bridge suite green.
- SzAlpha donation note (`:45`), `seedDeposit` NatSpec, the `minSharesOut/minTaoOut` NatSpec (`:168-169`,
  drop "0 = unbounded"), and `RUNBOOK-mainnet-deploy.md:146` reflect the new behavior.
- X-Ray (`contracts/src/bridge/x-ray/SzAlpha.md`) updated: first-depositor mitigation is now structural;
  the slippage floor is mandatory (genesis-exempt); residual same-block front-run noted as accepted (LOW).
- Documentation propagation complete per "Next step" above: the bridge X-Ray set (`SzAlpha.md`,
  `invariants.md`, `entry-points.md`, `x-ray.md`) and docs (`docs/wires/8x-01-szALPHA-bridge.md`,
  `docs/bridge.md`) reflect the shipped behavior, and the ADV-01 accepted-runtime-trust note is recorded.
