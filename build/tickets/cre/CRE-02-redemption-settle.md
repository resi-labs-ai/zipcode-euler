# CRE-02 — Redemption-settle keeper Job (the (K) operator path)

> Re-scoped 2026-06-20 to the **(K) operator half** per `CRE-OPS-ROUTING.md` (the routing ruling) and
> PROGRESS:1015 ("the CRE-02 operator half"). Spec: `claude-zipcode.md` §6.1 / §8.3 (+ §8.7 operator path).
> Contracts (truth): `OffRampModule.sol`, `ZipRedemptionQueue.sol`. Wires: `docs/wires/OffRampModule.md`,
> `docs/wires/9-ZipRedemptionQueue.md`. Builds on KEEPER-00 (the spine) + KEEPER-01a (the BurnJob model).
> Supersedes the 2026-06-12 scope (which predated the (R)/(K) split and the keeper-track decision; that scope's
> "against the anvil fork" Done-when, the in-ticket REDEEM/REPAY emission, and the 30-day cron are all stale —
> see "Scope boundary" below).

## Deliverable
A new fail-safe keeper **`Job`** on the `cre/keeper/` spine — `internal/job/redemption_job.go` — that drives the
senior par-redemption **operator path**: `ZipRedemptionQueue.settleEpoch()` (as the queue's `controller`) +
`OffRampModule.claim(assets)` / `OffRampModule.requestRedeem(zipAmount)` (as the off-ramp `operator`). Modeled
exactly on `BurnJob` (KEEPER-01a): a PURE-read `Evaluate` that returns an ordered `chain.Plan`; the Runner alone
submits. Idempotent + stateless (no cross-tick state) — each tick reads live queue/off-ramp state and emits
whatever legs are currently due; the synchronous single-threaded spine guarantees a leg fully mines before the
next `Evaluate` re-reads (the BurnJob no-double-act argument, `burn_job.go:92-101`).

Plus: config field for the escrow target, two `IdentityCheck` rows, registration in `cmd/keeper/main.go`, and the
two test files (unit + sim) below.

## Scope boundary (what this Job does NOT do — documented seams, not gaps)
- **It does NOT emit the (R) warehouse REDEEM→REPAY funding.** That is `cre/warehouse` (CRE-04, BUILT) — a wasip1
  workflow on the report path (Forwarder), a DIFFERENT transport the keeper cannot submit (the cre-sdk-go wasip1
  sandbox exposes `WriteReport`; the go-ethereum keeper submits ordinary txs — `CRE-OPS-ROUTING.md` "two
  transports"). This Job is **reactive**: it settles + claims whatever USDC the (R) REPAY already delivered into
  the queue's own balance (§8.3: "settles against the queue's own REPAY-delivered USDC balance"), and optionally
  escrows idle basket zipUSD.
- **The cross-transport orchestration** (when/how an off-chain producer POSTs the REDEEM/REPAY op event to the
  `cre/warehouse` `http.Trigger`, sized off the §8.2 reserve = the CRE-06 `harvestReserve`/`safetyBuffer` config
  that CRE-05a folded in) is the funding glue — **owed to ops / a CRE-02b follow-up**, logged as a PROGRESS seam.
  The keeper does not call the warehouse; per `OffRampModule.md:23` the off-ramp "is NOT wired to the warehouse."
- **Escrow demand-sizing beyond a config target** (buyback-demand-driven escrow) is deferred. `requestRedeem` is
  gated by a single config knob `RedeemTargetPending` that **defaults to 0 = escrow disabled** (the BurnJob
  `minBurn` / CTR-09 fee default-OFF idiom): ship the full operator cycle, default the policy-laden leg to safe.

## Binds to (verified by inspection — real signatures, real gates)
- **`OffRampModule.sol`** (`docs/wires/OffRampModule.md`):
  - `requestRedeem(uint256 zipAmount) external onlyOperator` (`:144`) — escrows rq-Safe basket zipUSD into the
    queue (drives the Safe: `approve(queue,amt)`→`queue.requestRedeem(amt, rqSafe, rqSafe)`→`approve(queue,0)`).
    Reverts `ZeroAmount` on 0, `NotWholeUnit` on `amt % queue.scaleUp() != 0` (`scaleUp()` read LIVE off the queue).
  - `claim(uint256 assets) external onlyOperator` (`:161`) — drives `queue.withdraw(assets, rqSafe, rqSafe)`; USDC
    lands back in the rq Safe. Reverts `ZeroAmount` on 0.
  - views: `juniorTrancheSafe() → address` (`:45`, the rq Safe), `queue() → address` (`:51`),
    `zipUSD() → address` (`:49`), `operator() → address` (`:47`).
- **`ZipRedemptionQueue.sol`** (`docs/wires/9-ZipRedemptionQueue.md`):
  - `settleEpoch() external` — `if (msg.sender != controller) revert NotController()` (`:199-200`). On-demand, NO
    time gate. Reads own free USDC `balanceOf(this) − reservedAssets`, fills `min(available, totalPending/scaleUp)`
    at par, burns the filled zipUSD, banks USDC as `claimableAssets`. `filledShares == 0` ⇒ a no-op success.
  - views: `usdc() → address` (`:53`), `scaleUp() → uint256` (`:56`, mutable, re-derived on `setTokens`),
    `totalPending() → uint256` (`:74`), `reservedAssets() → uint256` (`:76`), `maxWithdraw(address r) → uint256`
    (`:272`, returns `claimableAssets[r]`), `controller() → address` (`:59`).
- **The keeper spine + helpers (reuse — do NOT re-implement):**
  - `chain.CallAddress(ctx, r, to, "sig()")` (`read.go:90`), `chain.CallUint(ctx, r, to, "sig()")` (`read.go:32`),
    `chain.CallUintWithAddr(ctx, r, to, "balanceOf(address)", arg)` (`read.go:42`).
  - `chain.PackCall("settleEpoch()")` (`encode.go:31`, no-arg) and `chain.PackUintCall("sig(uint256)", v)`
    (`encode.go:24`, one-uint256-arg).
  - `chain.Plan` / `chain.Action{Label, To, Data}` (`action.go`); `GasLimit 0 ⇒ estimate` (dry-run, K3).
  - `job.Job` interface (`job.go:17`); `job.IdentityCheck` + `job.NewIdentityJob` (`identity_job.go`).
  - `config.Config` + `config.(*Config).MustAddr(name)` (`config.go:298`).

## The `Evaluate` algorithm (pure read → ordered Plan)
All reads are re-read **each tick** (§17 re-pointable — never cache across ticks). The Job struct holds only
`offramp common.Address` (from `cfg.MustAddr("OffRampModule")`) + `targetPending *big.Int` (config). Order of the
emitted legs is **load-bearing**: reactive legs first (settle, claim — always-safe), escrow last (optional). A
leg's failure under the spine's abort-on-first-error must not strand the always-safe legs, so escrow is last.

**Constructor + helper (pin these exactly):**
- `func NewRedemptionJob(offramp common.Address, targetPending *big.Int) *RedemptionJob` — store both by
  reference, the `BurnJob` idiom (`burn_job.go:30`); `targetPending` is config-guaranteed non-nil (`defaults()`
  seeds `big.NewInt(0)`), but read-only, so no defensive copy is needed.
- `func floorToUnit(x, u *big.Int) *big.Int { return new(big.Int).Mul(new(big.Int).Div(x, u), u) }` — an
  **unexported package-level** func in `redemption_job.go` (so the `_test.go` files in `package job` can call it).
  Does NOT exist yet — write it. (`u` is always `scaleUp > 0` at every call site.)

1. **Re-pointable address reads** off the off-ramp (NEVER hard-code):
   - `rqSafe = CallAddress(offramp, "juniorTrancheSafe()")`
   - `queue = CallAddress(offramp, "queue()")`
   - `zipUSD = CallAddress(offramp, "zipUSD()")`
   If `queue == 0x0` OR `rqSafe == 0x0` ⇒ **empty Plan, nil error** (unwired — no-op, not an error; mirrors
   `burn_job.go:60-62`).
2. **Queue state reads:**
   - `usdcAddr = CallAddress(queue, "usdc()")`
   - `scaleUp = CallUint(queue, "scaleUp()")`. If `scaleUp.Sign() == 0` ⇒ empty Plan, nil error (malformed/unwired
     queue — a 0 scaleUp would divide-by-zero; treat as no-op).
   - `pending = CallUint(queue, "totalPending()")`
   - `reserved = CallUint(queue, "reservedAssets()")`
   - `usdcBalQueue = CallUintWithAddr(usdcAddr, "balanceOf(address)", queue)`
   - `claimable = CallUintWithAddr(queue, "maxWithdraw(address)", rqSafe)` (returns `claimableAssets[rqSafe]`)
   - `idleZip = CallUintWithAddr(zipUSD, "balanceOf(address)", rqSafe)`
   NOTE the two `balanceOf` reads hit **different token addresses** (`usdcAddr` vs `zipUSD`) with different args
   (`queue` vs `rqSafe`) — the unit-test stub MUST key them apart (see the test section).
   Any read error ⇒ propagate `(chain.Plan{}, err)` (the Runner logs + continues; fail-safe).
3. **freeUsdc** `= usdcBalQueue − reserved`, floored at 0 (`reserved` can momentarily exceed balance only by
   bug; guard `if freeUsdc.Sign() < 0 { freeUsdc = 0 }`).
4. **Build the ordered Plan** (`actions []chain.Action`, appended in this order; each leg independently gated on
   the PRE-read state — NO cross-leg effect modeling, matching BurnJob's read-current-truth philosophy):
   - **settleEpoch** — `expectedFill = min(freeUsdc, pending / scaleUp)` (this mirrors the queue's own
     computation exactly, `ZipRedemptionQueue.sol:203-206`, so a Go `expectedFill == 0` correctly predicts an
     on-chain `filledShares == 0` no-op). Emit IFF `expectedFill.Sign() > 0` — equivalently
     `freeUsdc.Sign() > 0 && pending.Cmp(scaleUp) >= 0` (both must hold; do NOT emit on either-or). `Action{
     Label:"settleEpoch", To: queue, Data: chain.PackCall("settleEpoch()")}`. (Gate in Go to avoid a wasted
     no-op tx — a 0-fill `settleEpoch` succeeds but costs gas.)
   - **claim** — emit IFF `claimable.Sign() > 0`. `Action{Label:"claim", To: offramp,
     Data: chain.PackUintCall("claim(uint256)", claimable)}`. Claims the PRE-read banked `claimableAssets[rqSafe]`;
     this-tick settle's freshly-banked fill is claimed next tick (≤2 ticks to fully cycle delivered USDC —
     acceptable; redemption is low-frequency treasury plumbing).
   - **requestRedeem** (escrow; default-OFF) — emit IFF `targetPending.Sign() > 0` (escrow enabled) AND
     `gap = targetPending − pending > 0` AND `escrow = floorToUnit(min(gap, idleZip), scaleUp)` is `>= scaleUp`
     (a sub-unit escrow would revert `NotWholeUnit`/`ZeroAmount`). `Action{Label:"requestRedeem", To: offramp,
     Data: chain.PackUintCall("requestRedeem(uint256)", escrow)}`. `floorToUnit(x, u) = (x / u) * u` (big.Int).
     The single-requester `MultipleRequesters` guard never trips for this caller (the off-ramp always escrows
     `(rqSafe, rqSafe)`, so `pendingRequester ∈ {0, rqSafe}`).
5. Return `chain.Plan{Actions: actions}` (empty ⇒ no-op).

## Config (one new field — env-only `*big.Int`, default 0 = disabled)
In `internal/config/config.go`, mirror the `MinBurnAmount` pattern EXACTLY (`json:"-"`, env-only, base-10
`*big.Int`, replace-only-if-non-empty, NO `Validate` rule because an explicit 0 is valid):
- Field `RedeemTargetPending *big.Int` // KEEPER_REDEEM_TARGET_PENDING, base-10, zipUSD 18dp; 0 = escrow disabled.
- `defaults()`: `RedeemTargetPending: big.NewInt(0)`.
- `overlayEnv`: parse `KEEPER_REDEEM_TARGET_PENDING` like `KEEPER_MIN_BURN_AMOUNT` (`config.go:156-162`) —
  `new(big.Int).SetString(v, 10)`, error on unparseable, set only if non-empty.
- NO `Validate` rule (0 is valid, like `MinBurnAmount`).

## Wiring in `cmd/keeper/main.go`
- Add two `cfg.MustAddr` lookups: `OffRampModule`, `ZipRedemptionQueue` (re-pointable addresses, §17). The Job
  itself only needs `OffRampModule` (it reads the queue off the off-ramp), but BOTH go in the identity-check list.
- Add two `job.IdentityCheck` rows so a wrong key fails fast at startup (§8.7) — the keeper's single signer must be
  BOTH the off-ramp `operator` AND the queue `controller`:
  - `{Name: "OffRampModule", Addr: offramp, AdminSig: "operator()"}`
  - `{Name: "ZipRedemptionQueue", Addr: queue, AdminSig: "controller()"}`
  `IdentityJob.Evaluate` (`identity_job.go:40-60`) asserts, per row, `AdminSig()==signer && owner()!=signer` —
  BOTH contracts expose `owner()` (OffRampModule via the zodiac `Module`/`Ownable`; the queue `is Ownable`), so
  the §8.7 `owner != operator` assertion resolves on both. (The sim test does NOT run IdentityJob, so the probe
  need not implement `owner()`.)
- **Deploy obligation / known seam:** the IdentityCheck validates the **configured** `ZipRedemptionQueue` address
  (`KEEPER_ADDR_ZipRedemptionQueue`), while the Job resolves the LIVE queue off `offramp.queue()` each tick (§17).
  Deploy must keep `KEEPER_ADDR_ZipRedemptionQueue == offramp.queue()` (assert at deploy). Log this in PROGRESS.
- Construct `redemption := job.NewRedemptionJob(offramp, cfg.RedeemTargetPending)` and register it in the Runner
  job slice AFTER `burn` (and after `strikeLoop`, ordering is non-critical — each Job is independent). Update the
  startup-assertion log line to include the two new identities.

## Do NOT
- Do NOT emit any warehouse REDEEM/REPAY (R) report from the keeper, or import `cre/zipreport`/cre-sdk-go (wrong
  transport; that funding is `cre/warehouse`).
- Do NOT call `queue.withdraw`/`queue.requestRedeem` directly — go through `OffRampModule.claim`/`requestRedeem`
  (the operator path; the off-ramp `exec`s through the rq Safe, which is what `redeemController` authorizes).
- Do NOT hard-code `scaleUp` (`1e12`) — read it LIVE off the queue (it is mutable, re-derived on `setTokens`).
- Do NOT cache any address across ticks; do NOT add cross-tick state (no fill history / no in-flight guard — the
  synchronous spine makes it unnecessary, `burn_job.go:92-101`).
- Do NOT model `settleEpoch`'s effect on `claimable` within one Plan (claim the PRE-read value; let the next tick
  pick up the freshly-banked fill) — keep each leg independently gated (robustness over one-tick latency).
- Do NOT introduce a time gate / 30-day cadence (removed 2026-06-12; the queue is on-demand).

## Acceptance gate (the per-track CRE/(K) gate — `go build`/`go test`, NOT a live anvil run)
Run from `cre/keeper/`: `go build ./... && go vet ./... && go test -count=1 ./...` all green. (Keeper-track
reality, per StrikeLoopProbe/BurnJob: simulated backend + a recorder probe, NOT anvil — the old ticket's "against
the anvil fork" is superseded.)

**Unit test — `internal/job/redemption_job_test.go`** (the load-bearing binding proof; model
`burn_job_test.go`). A `redemptionStubReader` returns canned ABI values. It must key the address getters by
selector (`juniorTrancheSafe()`/`queue()`/`zipUSD()`/`usdc()` → addrs; `scaleUp()`/`totalPending()`/
`reservedAssets()` → uints; `maxWithdraw(address)` → claimable) **AND key the two `balanceOf(address)` reads by
`call.To`** — the Job reads `balanceOf` on `usdcAddr` (→ `usdcBalQueue`) and on `zipUSD` (→ `idleZip`), which
are distinct addresses the stub itself returns from `usdc()`/`zipUSD()`; switch on `call.To` to return the two
different values (a single shared `bal` cannot satisfy test groups 1/4/6). Reuse the EXISTING package-`job`
helpers `sel`/`encodeAddr` (`job_test.go`) and `encodeUint` (already defined in `burn_job_test.go:28` — do NOT
redeclare it; a second definition in the same package is a compile error). Assert, by **decoding the emitted
`Action.Data`**
(selector + `abi.Unpack` the uint arg — NOT trusting `PackUintCall`):
  1. **All three legs, ordered** — with `freeUsdc>0 && pending≥scaleUp`, `claimable>0`, escrow-enabled+gap+idle:
     `Actions == [settleEpoch→queue (selector 0x… , no args), claim→offramp(claimable), requestRedeem→offramp(escrow)]`
     in that order; assert each `To` and each decoded scalar (claimable, and `escrow == floorToUnit(min(gap,idle),scaleUp)`).
  2. **settle-only** — `freeUsdc>0 && pending≥scaleUp`, `claimable==0`, target 0 ⇒ one action `settleEpoch`.
  3. **claim-only** — `freeUsdc==0` (or `pending<scaleUp`), `claimable>0`, target 0 ⇒ one action `claim(claimable)`.
  4. **escrow gating** — target>0: (a) `gap>0 && idle≥scaleUp` ⇒ `requestRedeem(floored)`; (b) `idle<scaleUp` ⇒ no
     escrow leg; (c) `pending≥target` (gap≤0) ⇒ no escrow leg; (d) target==0 ⇒ never an escrow leg.
  5. **no-op / fail-safe** — `queue()==0x0` ⇒ empty Plan, nil err; `scaleUp()==0` ⇒ empty Plan, nil err; a Reader
     error ⇒ `(empty Plan, err)`.
  6. **escrow floor** — `min(gap,idle)` not a whole multiple of `scaleUp` ⇒ the emitted `escrow` is floored
     (e.g. scaleUp=1e12, idle=2.5e12, gap large ⇒ escrow==2e12).

**Sim test — `internal/job/redemption_job_sim_test.go`** (proves the Runner submits the ordered Plan over a real
EVM; model `burn_job_sim_test.go`). Use `env := newSimEnv(t, false)` (the self-deploy form — do NOT pass `true`,
which deploys the unrelated OnlyOperatorProbe) then `probe := env.deployProbe(env.sim.Client(),
redemptionProbeBytecode)`. Seed it via `chain.Submit` of `PackUintCall`/a `setRqSafe` call so all three legs fire:
`setScaleUp(1e12)`, `setTotalPending(3e12)`, `setReservedAssets(0)`, `setBal(<big, e.g. 1e18>)`,
`setClaimable(5)`, `setRqSafe(probe)`. Construct `NewRedemptionJob(probe, targetPending=10e12)`; run through the
Runner; `waitFor(t, func() bool { recordCount()==3 })`; then assert the ordered records. The probe's `record(i)`
returns a **2-field tuple `(bytes4 sel, uint256 a0)`** (NOT StrikeLoop's 4-field shape) — write a small local
decoder (`abi.Arguments{{bytes4},{uint256}}.Unpack`), do NOT reuse StrikeLoop's `readRecord`. Assert:
`record(0)` = `sel4("settleEpoch()")`, a0 ignored; `record(1)` = `sel4("claim(uint256)")`, a0 == `5`;
`record(2)` = `sel4("requestRedeem(uint256)")`, a0 == `floorToUnit(10e12−3e12, 1e12)` == `7e12`. (The probe
returns itself for queue/zipUSD/usdc and `setRqSafe(probe)` makes `rqSafe==probe`, so both `balanceOf` reads hit
the probe's single `bal` slot — fine here: `bal` large opens both the settle gate (freeUsdc>0) and supplies
`idleZip ≥ gap`, so escrow floors to the gap `7e12`. The unit test, not the sim, exercises distinct token
balances.)

`RedemptionProbe` creation bytecode — assign to `const redemptionProbeBytecode = "0x…"` in the sim test (forge,
solc 0.8.24 — verbatim; also commit the source as `cre/keeper/RedemptionProbe.sol` like `StrikeLoopProbe.sol`):
```
0x608060405234801561000f575f80fd5b50610b2f8061001d5f395ff3fe608060405234801561000f575f80fd5b50600436106101c2575f3560e01c806387df735d116100f7578063b6b385f711610095578063e10d29ee1161006f578063e10d29ee146104ba578063ede49968146104d8578063f3f18c37146104f6578063f77c479114610514576101c2565b8063b6b385f714610464578063ba014b831461046e578063ce96cb771461048a576101c2565b8063aa2f892d116100d1578063aa2f892d146103f2578063ace6f90c1461040e578063af38d7571461042a578063b3ab15fb14610448576101c2565b806387df735d1461039a5780638be31c50146103b6578063900407bc146103d4576101c2565b80633f37315511610164578063570ca7351161013e578063570ca735146102ff57806370a082311461031d578063754d68061461034d57806384acbb8914610369576101c2565b80633f373155146102a75780633f90916a146102c557806349b12ad8146102e3576101c2565b8063379607f5116101a0578063379607f5146102315780633d302d061461024d5780633d79d1c81461026b5780633e413bee14610289576101c2565b80630ae214b8146101c65780632a0a66e3146101e25780632c16cd8a14610200575b5f80fd5b6101e060048036038101906101db919061096b565b610532565b005b6101ea61053c565b6040516101f791906109d5565b60405180910390f35b61021a6004803603810190610215919061096b565b610543565b604051610228929190610a37565b60405180910390f35b61024b6004803603810190610246919061096b565b610587565b005b61025561061a565b6040516102629190610a5e565b60405180910390f35b610273610620565b6040516102809190610a5e565b60405180910390f35b610291610626565b60405161029e91906109d5565b60405180910390f35b6102af61062d565b6040516102bc91906109d5565b60405180910390f35b6102cd610650565b6040516102da9190610a5e565b60405180910390f35b6102fd60048036038101906102f89190610aa1565b610656565b005b610307610698565b60405161031491906109d5565b60405180910390f35b61033760048036038101906103329190610aa1565b6106c0565b6040516103449190610a5e565b60405180910390f35b6103676004803603810190610362919061096b565b6106cb565b005b610383600480360381019061037e919061096b565b6106d5565b604051610391929190610a37565b60405180910390f35b6103b460048036038101906103af919061096b565b610710565b005b6103be61071a565b6040516103cb9190610a5e565b60405180910390f35b6103dc610720565b6040516103e99190610a5e565b60405180910390f35b61040c6004803603810190610407919061096b565b61072c565b005b6104286004803603810190610423919061096b565b6107bf565b005b6104326107c9565b60405161043f9190610a5e565b60405180910390f35b610462600480360381019061045d9190610aa1565b6107cf565b005b61046c610812565b005b6104886004803603810190610483919061096b565b6108a4565b005b6104a4600480360381019061049f9190610aa1565b6108ae565b6040516104b19190610a5e565b60405180910390f35b6104c26108b9565b6040516104cf91906109d5565b60405180910390f35b6104e06108c0565b6040516104ed91906109d5565b60405180910390f35b6104fe6108e7565b60405161050b91906109d5565b60405180910390f35b61051c61090c565b60405161052991906109d5565b60405180910390f35b8060018190555050565b5f30905090565b5f805f6007848154811061055a57610559610acc565b5b905f5260205f2090600202019050805f015f9054906101000a900460e01b81600101549250925050915091565b6007604051806040016040528063379607f560e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff1916815260200183815250908060018154018082558091505060019003905f5260205f2090600202015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c021790555060208201518160010155505050565b60035481565b60045481565b5f30905090565b5f8054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b60025481565b805f806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff16021790555050565b5f60065f9054906101000a900473ffffffffffffffffffffffffffffffffffffffff16905090565b5f6004549050919050565b8060048190555050565b600781815481106106e4575f80fd5b905f5260205f2090600202015f91509050805f015f9054906101000a900460e01b908060010154905082565b8060028190555050565b60015481565b5f600780549050905090565b6007604051806040016040528063aa2f892d60e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff1916815260200183815250908060018154018082558091505060019003905f5260205f2090600202015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c021790555060208201518160010155505050565b8060058190555050565b60055481565b8060065f6101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff16021790555050565b6007604051806040016040528063b6b385f760e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff191681526020015f815250908060018154018082558091505060019003905f5260205f2090600202015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c0217905550602082015181600101555050565b8060038190555050565b5f6005549050919050565b5f30905090565b5f805f9054906101000a900473ffffffffffffffffffffffffffffffffffffffff16905090565b60065f9054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b5f60065f9054906101000a900473ffffffffffffffffffffffffffffffffffffffff16905090565b5f80fd5b5f819050919050565b61094a81610938565b8114610954575f80fd5b50565b5f8135905061096581610941565b92915050565b5f602082840312156109805761097f610934565b5b5f61098d84828501610957565b91505092915050565b5f73ffffffffffffffffffffffffffffffffffffffff82169050919050565b5f6109bf82610996565b9050919050565b6109cf816109b5565b82525050565b5f6020820190506109e85f8301846109c6565b92915050565b5f7fffffffff0000000000000000000000000000000000000000000000000000000082169050919050565b610a22816109ee565b82525050565b610a3181610938565b82525050565b5f604082019050610a4a5f830185610a19565b610a576020830184610a28565b9392505050565b5f602082019050610a715f830184610a28565b92915050565b610a80816109b5565b8114610a8a575f80fd5b50565b5f81359050610a9b81610a77565b92915050565b5f60208284031215610ab657610ab5610934565b5b5f610ac384828501610a8d565b91505092915050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52603260045260245ffdfea2646970667358221220e1278ef150060cdcbeda1c06c4ba034e3d5ef5be5802b0e172095e1828a3b95764736f6c63430008180033
```

## Done when
- `cre/keeper`: `go build ./... && go vet ./... && go test -count=1 ./...` all green; the two new test files pass
  (unit: all 6 groups above; sim: `recordCount()==3`, ordered selectors + decoded scalars).
- `redemption_job.go` binds ONLY to real OffRampModule/ZipRedemptionQueue signatures + the existing chain helpers
  (a binding to an absent surface fails the gate → back-pressure obligation). Cold-build returns ZERO load-bearing
  guesses.
- Code committed to `cre/keeper` (code only; no `build/`/`docs/`/`contracts/` staged; the probe `.sol` lives in
  `cre/keeper/RedemptionProbe.sol` like `StrikeLoopProbe.sol`).

## Depends on
KEEPER-00 (spine — DONE), KEEPER-01a (BurnJob model — DONE), CRE-04 (`cre/warehouse` for the (R) funding —
DONE, but only as the OUT-OF-SCOPE counterpart; this Job does not import it).
