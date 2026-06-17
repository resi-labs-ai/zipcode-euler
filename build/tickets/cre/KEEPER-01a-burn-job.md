# KEEPER-01a — the buy-burn fill-detect → `burnFor` job (the first live (K) write job)

> **Track:** (K) — a `Job` on the `cre/keeper/` spine (KEEPER-00). The first slice of KEEPER-01. It is the **burn
> half** of the hybrid buy-burn cycle (`CRE-OPS-ROUTING.md` §"Hybrid buy-burn cycle"): CRE-05a posts the *bid* via
> the (R) report path; the *fill* (szipUSD landing in the engine Safe) is detected off-chain and retired by this
> keeper job via `ExitGate.burnFor` (`onlyWindowController`). The harvest orchestrator (8-B5…8-B10 + rotation) is
> **KEEPER-01b** (separate window); the freeze-`commit`-on-shortfall lever is **KEEPER-01c** (deferred — binds to the
> INCOMPLETE `DurationFreezeModule`, PROGRESS Open obligations). This window builds ONLY the burn job.

---

## Deliverable
Extend the committed `cre/keeper/` module (monorepo, harness §3) with **one `Job`**:
- `internal/job/burn_job.go` — `BurnJob`: each tick, read the engine Safe's szipUSD balance via the Gate's own
  views; if a fill is present (balance ≥ a config floor), return a one-Action `chain.Plan` calling
  `ExitGate.burnFor(balance)`. Read-only `Evaluate`; the spine submits (KEEPER-00 K4). Empty plan = no-op.
- `internal/chain/encode.go` — a small **exported** calldata encoder `PackUintCall(sig string, v *big.Int) []byte`
  (= `selector(sig) ++ abi.encode(uint256 v)`), since the existing `selector` is unexported and the job must build
  write calldata. (Read helpers already exist: `CallAddress`, `CallUintWithAddr` — KEEPER-00 K3.)
- `internal/config/config.go` — add `MinBurnAmount *big.Int` (env `KEEPER_MIN_BURN_AMOUNT`, base-10; default `0` =
  burn any non-zero fill). No new validation rule (any ≥0 is valid).
- `cmd/keeper/main.go` — construct `BurnJob` (ExitGate addr from `cfg.MustAddr("ExitGate")`, the floor from
  `cfg.MinBurnAmount`) and register it in the `Runner`'s job list **after** the `IdentityJob` heartbeat.

## Spec §
- **§7 / 8-B14** — the paired buy-and-burn: retire szipUSD the engine Safe bought below NAV; "pure supply reduction,
  NO asset payout … NAV-per-share ticks up for stayers" (`ExitGate.sol:197-206`).
- **§8.7** — the operator/keeper path (this job runs under the windowController key; one immutable identity).
- **`CRE-OPS-ROUTING.md`** — `ExitGate.burnFor` is **(K) keeper** ("Async after a CoW fill is detected off-chain;
  mechanical 'szipUSD arrived → retire it', nothing to attest"). And the **safety argument** this job relies on:
  the burn is **housekeeping, not a price-affecting step** — `SzipNavOracle._effectiveSupply()` excludes the engine
  Safe's pre-burn szipUSD (`SzipNavOracle.sol:608-613`, and it IS the per-share denominator —
  `spotNavPerShare():474`), so a lagging/missed burn cannot dilute or inflate NAV-per-share. Therefore **no
  coverage/freshness gate** is needed on the burn (unlike the bid).
- **§7 note:** the spec (`claude-zipcode.md` §7) states there is "no separate engine Safe" — `engineSafe` is a
  *label/slot* that on the live deploy may resolve to the **same address as the main/rq Safe**. Harmless here: the
  job reads whatever address `engineSafe()` returns and burns that address's szipUSD; the invariant and mechanic are
  identical whether or not it is a distinct Safe.

## Binds to (verified by inspection)
`ExitGate` @ anvil `0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e` (chainId 8453); szipUSD @ `0x33aD3E23ae…` (read via
the Gate, not hard-coded). Verified surfaces:
| Call | Signature | Evidence |
|---|---|---|
| burn write | `burnFor(uint256 amount)` — `onlyWindowController`; reverts `NotWired` if `engineSafe==0`, `ZeroAmount` if `amount==0`; burns `amount` Loot from the Gate + `amount` szipUSD from `engineSafe` | `ExitGate.sol:199-206` |
| share token | `shareToken() returns (address)` (= szipUSD) | `address public shareToken;` `ExitGate.sol:50` |
| engine Safe | `engineSafe() returns (address)` | `address public engineSafe;` `ExitGate.sol:52` |
| controller | `windowController() returns (address)` (the keeper key; already asserted by KEEPER-00's IdentityJob) | `ExitGate.sol:51` |
| fill amount | `IERC20(shareToken).balanceOf(engineSafe) returns (uint256)` | ERC-20 standard (szipUSD is an ERC-20 share) |

Selectors (verified `keccak256(sig)[:4]`): `burnFor(uint256)=0x6f5d0f0b`, `shareToken()=0x6c9fa59e`,
`engineSafe()=0xf24ff18d`, `balanceOf(address)=0x70a08231`.

## Key requirements

### B1 — `BurnJob.Evaluate` (read + compute; never submits)
```go
type BurnJob struct { exitGate common.Address; minBurn *big.Int }
func NewBurnJob(exitGate common.Address, minBurn *big.Int) *BurnJob
func (j *BurnJob) Name() string { return "burn" }
func (j *BurnJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error)
```
`Evaluate` (re-read addresses each tick — §17 re-pointable; do not cache):
1. `shareToken := chain.CallAddress(ctx, r, j.exitGate, "shareToken()")`.
2. `engineSafe := chain.CallAddress(ctx, r, j.exitGate, "engineSafe()")`. If `engineSafe == (common.Address{})`
   return an **empty plan, nil error** (Gate not wired yet — no-op, not an error; `burnFor` would revert `NotWired`).
3. `bal := chain.CallUintWithAddr(ctx, r, shareToken, "balanceOf(address)", engineSafe)`.
4. If `bal.Sign() == 0` **or** `bal.Cmp(j.minBurn) < 0` → empty plan, nil error (no fill / below floor — no-op).
5. Else → `chain.Plan{Actions: []chain.Action{{ Label: "burnFor", To: j.exitGate,
   Data: chain.PackUintCall("burnFor(uint256)", bal) }}}`. `GasLimit: 0` (the spine estimates; `EstimateGas`
   doubles as a dry-run — KEEPER-00 K3).
- **Amount = the full engine-Safe balance** (`bal`), NOT a min with the Gate's Loot. Rationale (record in a code
  comment): `burnFor` also burns `amount` Loot from the Gate, so it requires `Loot.balanceOf(gate) ≥ amount`. By
  construction the Gate is the sole Loot minter/custodian and mints Loot **to itself** 1:1 with each szipUSD share
  (`ExitGate.sol:172-173`); the invariant `szipUSD.totalSupply() == Loot.balanceOf(gate)` holds at all times
  (`ExitGate.sol:30-32`), and the engine Safe's szipUSD is a **subset** of that supply — so
  `Loot(gate) ≥ balanceOf(engineSafe)` always holds and the burn cannot under-flow the Loot side. (A CoW fill only
  *moves* already-minted szipUSD into the engine Safe; the paired Loot was minted to the Gate at the original
  deposit and is soulbound — it never leaves.) If the invariant were ever violated, `EstimateGas` (the spine's
  dry-run, KEEPER-00 K3) catches the revert → no send, no nonce advance → **retry next tick** with a freshly-read
  balance — genuine recovery, never an unsafe partial state.
- A propagated read error (RPC failure) returns `(chain.Plan{}, err)` so the Runner logs it and continues (fail-safe).
- **No-double-burn is a property of the SYNCHRONOUS spine — note it as load-bearing.** `chain.Submit` blocks on the
  receipt (KEEPER-00 K3) and the `Runner` is single-threaded (runs jobs sequentially per tick), so a burn tx fully
  mines (draining the engine Safe's szipUSD, `ExitGate.sol:204`) **before** the next `Evaluate` reads the balance —
  which then sees `0` → empty plan. So there is no in-flight window for a duplicate `burnFor`, and **no in-flight
  guard is needed**. ⚠️ This safety rests on Submit being synchronous + the Runner single-threaded: if a future
  change makes submission async/parallel, the double-burn window reopens and this job needs an explicit
  pending-burn guard. State this in a code comment so the dependency is not silently broken.
- **Re-point race (rare, self-correcting — note, don't gate).** `shareToken()`/`engineSafe()`/`balanceOf` are three
  separate `eth_call`s; a Timelock `setShareToken`/`setEngineSafe` (§17) landing mid-`Evaluate` could read a balance
  on the old token while `burnFor` burns via the live `shareToken` at execution. This is a self-correcting revert
  (the dry-run catches a size mismatch → retry next tick), a rare governance event, never an unsafe burn — acceptable,
  not worth a multicall.

### B2 — `chain.PackUintCall`
- `func PackUintCall(sig string, v *big.Int) []byte` in `internal/chain/encode.go`: `return append(selector(sig),
  <abi.encode uint256 v>...)`. Define a package-level `var uint256T, _ = abi.NewType("uint256", "", nil)` (mirroring
  the existing read.go idiom) and `enc, _ := abi.Arguments{{Type: uint256T}}.Pack(v)`. **The signature returns no
  error by design** — both `abi.NewType("uint256",…)` and `Pack(*big.Int)` cannot fail for a compile-time-constant
  type + a `*big.Int` value, so the errors are dropped with `_` (uint256 takes a `*big.Int`, NOT a native int —
  contrast the `uint32`/`uint8` quirk in `cre/buyburn-bid/workflow.go:248-252`). Reuse the unexported `selector`
  already in `internal/chain/read.go` (same package).

### B3 — config
- Add `MinBurnAmount *big.Int` to `Config` with tag **`json:"-"`** (env-only: a `*big.Int` does not round-trip
  cleanly through the JSON-file overlay — keep it out of it). Seed `big.NewInt(0)` in `defaults()`, then in the env
  step replace it **only if `KEEPER_MIN_BURN_AMOUNT` is non-empty** (guard the empty case so the default survives,
  per KEEPER-00 K1's defaults→json→env ordering). Parse base-10 → `*big.Int`; reject only an unparseable non-empty
  value (a `Load` error, not a `Validate` rule — any parsed value ≥0 is valid). `0` means "burn any non-zero fill."
  `.env.example` documents `KEEPER_MIN_BURN_AMOUNT` on its own line, noting **0 is allowed here** (unlike the
  scalar knobs whose explicit-0 is rejected).

### B4 — wiring (`cmd/keeper/main.go`)
- After building the `IdentityJob`, build `burn := job.NewBurnJob(cfg.MustAddr("ExitGate"), cfg.MinBurnAmount)`
  (handle the `MustAddr` error → fail-fast). Register `[]job.Job{identity, burn}` in `NewRunner`. (`ExitGate` is
  already a referenced/required module via the IdentityJob, so `Validate` requires its address — KEEPER-00 K1.)

### B5 — tests
- **Unit (`burn_job_test.go`, stub `chain.Reader` — anvil-free, the primary proof):** a fake Reader returns canned
  ABI-encoded values keyed by the selector in the call data (`shareToken()`→S, `engineSafe()`→E,
  `balanceOf(address)`→a settable balance). Cover:
  1. balance `100` ≥ `minBurn 0` ⇒ plan has ONE Action; `To == exitGate`; **`Data` byte-equals**
     `0x6f5d0f0b ++ <uint256 100>` (assert the exact calldata — this is the load-bearing binding).
  2. balance `0` ⇒ empty plan, nil error.
  3. balance `5`, `minBurn 10` ⇒ empty plan, nil error (below floor).
  4. `engineSafe == 0x0` ⇒ empty plan, nil error (unwired).
  5. a Reader error ⇒ `(empty plan, err)` (so the Runner logs + continues).
- **Simulated-backend end-to-end (`burn_job_sim_test.go`):** deploy the **`ExitGateBurnProbe`** (bytecode below) on
  the simulated backend; the probe returns itself as `shareToken()`/`engineSafe()` and a settable `balanceOf`.
  `setBal(42)`, then run `BurnJob` through the `Runner`; `waitFor` `probe.lastBurned() == 42` and assert
  `probe.bal() == 0` (the burn drained it).
  - **REUSE the existing package-`job` test harness — do NOT redeclare.** `runner_sim_test.go` already defines (same
    package `job`): `probeBytecode`, `operatorKey`, `simChainID` (=1337), `newSimEnv`, `deployProbe`, `waitFor`; and
    `job_test.go` defines `sel`, `encodeAddr`, `quietLogger`, `stubReader`. Reuse `newSimEnv`/`waitFor`/the
    race-safe Commit-ticker teardown and `simChainID` verbatim. Name the new constant **`burnProbeBytecode`** (NOT
    `probeBytecode`). **Generalize `deployProbe`** to take the bytecode as a parameter (`deployProbe(t, env,
    bytecode)`) and update its one existing caller in `runner_sim_test.go` — editing a TEST helper is in scope (the
    "Do NOT change the spine" rule is about runtime behavior, not test plumbing). The new `burn_job_test.go` stub
    Reader may reuse `sel`/`encodeAddr` from `job_test.go` (same package) — do not redeclare them.
- Existing KEEPER-00 tests must stay green (including after the `deployProbe` signature change — update its caller).

## The `ExitGateBurnProbe` test contract (real, forge-compiled — use verbatim)
```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
contract ExitGateBurnProbe {
    uint256 public bal;           // bal()=0x3d79d1c8
    uint256 public lastBurned;    // lastBurned()=0xae47d43f
    function setBal(uint256 v) external { bal = v; }               // 0x754d6806
    function shareToken() external view returns (address) { return address(this); }  // 0x6c9fa59e
    function engineSafe() external view returns (address) { return address(this); }  // 0xf24ff18d
    function balanceOf(address) external view returns (uint256) { return bal; }       // 0x70a08231
    function burnFor(uint256 amount) external { lastBurned = amount; bal = 0; }       // 0x6f5d0f0b
}
```
Creation bytecode (forge solc 0.8.24 — `common.FromHex` it):
```
0x608060405234801561000f575f80fd5b506101758061001d5f395ff3fe608060405234801561000f575f80fd5b506004361061007a575f3560e01c806370a082311161005857806370a08231146100bf578063754d6806146100d3578063ae47d43f146100e5578063f24ff18d14610099575f80fd5b80633d79d1c81461007e5780636c9fa59e146100995780636f5d0f0b146100a7575b5f80fd5b6100865f5481565b6040519081526020015b60405180910390f35b604051308152602001610090565b6100bd6100b53660046100ee565b6001555f8055565b005b6100866100cd366004610105565b505f5490565b6100bd6100e13660046100ee565b5f55565b61008660015481565b5f602082840312156100fe575f80fd5b5035919050565b5f60208284031215610115575f80fd5b813573ffffffffffffffffffffffffffffffffffffffff81168114610138575f80fd5b939250505056fea2646970667358221220c9a7c02dc3dc048c1d5616b8e178ae26aa22535355520195286671f488d68c6464736f6c63430008180033
```

## Do NOT
- Do NOT add a coverage/freshness gate to the burn (NAV excludes the engine Safe's pre-burn szipUSD — §Spec §;
  `SzipNavOracle.sol:608-611`). The burn is housekeeping; gating it would be wrong, not safer.
- Do NOT implement any harvest leg (8-B5…8-B10), `creditFreeValue`/`recycle`, rotation, or freeze `commit` — those
  are KEEPER-01b/c.
- Do NOT hard-code szipUSD/engineSafe addresses — read them from the Gate each tick (§17 re-pointable).
- Do NOT cache shareToken/engineSafe across ticks (a Timelock re-point must take effect).
- Do NOT change the KEEPER-00 spine's behavior (nonce-safety, abort-on-first-error, fail-safe) — only ADD to it.

## Done when (the keeper gate — same as KEEPER-00)
1. `cd cre/keeper && go vet ./... && go build ./...` exits 0 (native; NOT wasip1).
2. `cd cre/keeper && go test ./...` green, including the B5 unit suite (exact `burnFor` calldata assertion + the
   no-op/floor/unwired/error branches) and the simulated-backend end-to-end (`probe.lastBurned()==42`), AND all
   pre-existing KEEPER-00 tests. Clean under `-race`.
3. Committed to `cre/keeper/` in the monorepo.
4. **Live-anvil acceptance (README; gated on anvil up — NOT the CI gate):** with anvil up and the engine Safe holding
   szipUSD (or after a CoW fill is simulated), `go run ./cmd/keeper` logs the burn job posting `burnFor(<bal>)` to
   `0xd9b8…` and the engine-Safe balance drops to 0. (Optional this window — the unit+sim gate is the bar.)

## Depends on
- **KEEPER-00** (the spine — done; this is a `Job` on it).
- CRE-05a (the bid that produces the fills this job burns) — already shipped; not a build dep.

## Spawns / leaves open
- **KEEPER-01b** — the engine harvest orchestrator (8-B5…8-B10 `onlyOperator` legs + main↔sidecar rotation +
  regime/split/cap policy). The large remaining (K) item.
- **KEEPER-01c** — freeze-`commit`-on-coverage-shortfall (DORMANT, exception-only). **Deferred / back-pressure:**
  binds to `DurationFreezeModule`, flagged INCOMPLETE / premise-under-review (PROGRESS Open obligations) — to be
  locked with the freeze rebuild, not built against an unsettled module.
