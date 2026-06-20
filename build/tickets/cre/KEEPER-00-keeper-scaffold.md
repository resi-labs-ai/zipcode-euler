# KEEPER-00 — the CRE keeper-service scaffold (the (K) read→compute→submit spine)

> **Track:** (K) — the off-chain Go keeper service (go-ethereum), **NOT wasip1**. This is the foundation for every
> (K) item (KEEPER-01 + the CRE-02 operator half). It is the (K) analogue of CRE-00: layout + key mgmt + the
> read→compute→submit spine + shared chain-read helpers + config — and **nothing engine-specific** (the real
> harvest/redemption/burn jobs are KEEPER-01's). The routing that spawned this: `build/tickets/cre/CRE-OPS-ROUTING.md`.

---

## Deliverable
A committed Go module at **`cre/keeper/`** (in THIS monorepo — harness §3: CRE code commits to `cre/...`) that:
1. Loads the **operator hot key** + config, fail-fast if either is missing/invalid (key never logged).
2. Provides a **`chain` client** over go-ethereum's `ethclient`: typed **view-read helpers** (CallContract +
   abi-decode) and a **submit path** (nonce → EIP-1559 gas → sign → send → wait-receipt, with a 1.3× gas buffer).
3. Defines the **`Job` spine** (`Read → Compute → Submit`): a `Job` interface + a `Plan`/`Action` value type + a
   `Runner` loop that schedules jobs, submits their plans, and is **fail-safe** (a job error logs and the loop
   continues; SIGINT/SIGTERM → graceful stop). Jobs supply **only scalar/encoded calldata** they build — never
   raw operator authority beyond the entrypoint (§8.7 bounded-blast-radius).
4. Ships **one reference Job** — an **identity/liveness probe** (`identity_job.go`) — that reads `operator()` /
   `windowController()` off the real modules and asserts they equal the loaded key's address. It is the
   copy-template KEEPER-01 clones; it makes **no state-changing write** (scope discipline).
5. Asserts the **§8.7 invariant at startup**: the loaded key's address == the on-chain `operator()` of the modules
   it is configured to drive (refuse to run with the wrong key); the keeper's address must **not** be the module
   `owner` (`operator != owner`, §8.7).

This window builds the **spine + the read-only identity probe only.** No harvest leg, no `burnFor`, no `settleEpoch`,
no `commit` — those are KEEPER-01 / CRE-02 and MUST NOT be implemented here.

## Spec §
- **§8.7** — "Engine strategy-admin operator … the single immutable CRE operator … submits ordinary transactions …
  the on-chain gate is the operator address, not the Forwarder identity." Honor: `operator != owner`, one immutable
  operator identity; jobs pass **only scalar amounts** (`LpStrategyModule.sol:19` blast-radius note).
- **§13** — the single trusted operator is the locked trust model; (K) is that identity's off-chain embodiment, **no
  new trust assumption**. `setOperator` (Timelock) is the key-rotation/recovery path.
- **§17** — wiring is Timelock-settable, not frozen; the keeper reads addresses from config (re-pointable), not hard-codes.
- **`CRE-OPS-ROUTING.md`** — the (K)/(R) split, the fail-safe/liveness-only failure model, and the per-module table
  this scaffold's eventual jobs drive (KEEPER-01).

## Binds to (verified by inspection — do NOT cite blind)

### A. go-ethereum `v1.17.2` (already in the module cache; the version `cre/buyburn-bid` pins)
All symbols below were confirmed present at `~/go/pkg/mod/github.com/ethereum/go-ethereum@v1.17.2`:
- `github.com/ethereum/go-ethereum/ethclient` — `*Client` with `CallContract(ctx, ethereum.CallMsg, *big.Int)`,
  `PendingNonceAt(ctx, addr)`, `SuggestGasTipCap(ctx)`, `HeaderByNumber(ctx, nil)` (→ `.BaseFee`),
  `EstimateGas(ctx, ethereum.CallMsg)`, `SendTransaction(ctx, *types.Transaction)`, `TransactionReceipt(ctx, hash)`.
  `ethclient.Dial(rpcURL)` to construct.
- `github.com/ethereum/go-ethereum/core/types` — `LatestSignerForChainID(chainID)`, `SignTx(tx, signer, key)`,
  `NewTx(&DynamicFeeTx{...})`, `*Receipt` (`.Status`, `.ContractAddress`).
- `github.com/ethereum/go-ethereum/accounts/abi` — `NewType`, `Arguments{}.Pack/Unpack` (mirror the patterns in
  `cre/buyburn-bid/workflow.go:289-357`: `selector(sig)=keccak256(sig)[:4]`, `decodeUint`, `readBool`, etc.).
- `github.com/ethereum/go-ethereum/crypto` — `HexToECDSA(hex)`, `PubkeyToAddress(key.PublicKey)`, `Keccak256`.
- `github.com/ethereum/go-ethereum/common` — `HexToAddress`, `Address`.
- `github.com/ethereum/go-ethereum` (root pkg, import alias `ethereum`) — `ethereum.CallMsg{From, To, Data, ...}`.
- **Test only:** `github.com/ethereum/go-ethereum/ethclient/simulated` — `simulated.NewBackend(types.GenesisAlloc,
  opts...) *Backend`; `(*Backend).Client() Client` (the `simulated.Client` interface **exposes the same method set**
  the `Backend` interface needs — its concrete impl embeds `*ethclient.Client` — so the SAME `chain` helpers run
  against it unchanged; depend on the method set, not on extracting `*ethclient.Client`); `(*Backend).Commit()
  common.Hash`; `(*Backend).Close()`. **`NewBackend` hardcodes chainID `1337`** — the test signer must use 1337 (K3).

> **NOTE (go-ethereum 1.17.2 abi quirk, already hit in CRE-05a):** `abi.Arguments.Pack` wants a **native** Go
> integer for fixed-width int args (e.g. `uint32`, `uint8`), **not** a `*big.Int` ("cannot use ptr as type uintN").
> Produced bytes are identical. Mirror `cre/buyburn-bid/workflow.go:248-252`.

> **DEP NOTE:** the keeper does **NOT** import `cre-sdk-go` (it is not a wasip1 workflow — no report path). So the
> `replace → reference/cre-sdk-go` DEP SEAM (PROGRESS) does **not** apply here. `go.mod` requires only go-ethereum
> (+ its transitive deps that `go mod tidy` resolves). `go 1.25.3` (match `cre/buyburn-bid/go.mod`).

### B. The live anvil deployment (the real (K) write/read surface — `build/anvil/contract-map.md`)
Base fork, **chainId 8453**, RPC `http://127.0.0.1:8545`. The keeper reads/drives these (config-supplied, §17):
| Name (config key) | Address | Read/Write surface used here |
|---|---|---|
| `creOperator` (the key) | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | priv key `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` (anvil acct #3) — **dev only; `.env`-injected, never committed** |
| `FarmUtilityLoopModule` (8-B5) | `0x61cdc9c8839753f520cc9dc4f2a733e132fe10e4` | `operator() returns (address)` — verified `address public operator;` `FarmUtilityLoopModule.sol:41` |
| `ExitGate` | `0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e` | `windowController() returns (address)` — verified `address public windowController;` `ExitGate.sol:51` |
| `ZipRedemptionQueue` | `0x46c89c1a4e86b7F025871c35F08aA7DA95F79D8f` | (config-registered; no call this window) |

Every engine module exposes `address public operator;` (auto-getter `operator()`), verified across
`FarmUtilityLoopModule/LpStrategyModule/HarvestVoteModule/ExerciseModule/SellModule/RecycleModule/OffRampModule/
DurationFreezeModule/SzipBuyBurnModule.sol`. `ExitGate.burnFor(uint256)` is `onlyWindowController` (`ExitGate.sol:199-200`)
— **that is KEEPER-01's write target, not this window's.** This window only **reads** `operator()`/`windowController()`.

## Module layout (author exactly this)
```
cre/keeper/
  go.mod                          # module cre-keeper ; go 1.25.3 ; require go-ethereum v1.17.2
  .gitignore                      # /.env  and any keystore files
  .env.example                    # documents every config var (placeholder key, NOT a real one)
  README.md                       # what it is, how to run, the gate, the live-anvil acceptance
  cmd/keeper/main.go              # entrypoint: load config+key → chain.NewChain → register jobs → job.NewRunner → Run(ctx)
  internal/config/config.go       # Config struct + Load() (env, with optional JSON file overlay) + Validate()
  internal/config/config_test.go
  internal/keymgr/keymgr.go       # Load(hex|keystore) → *Signer {Address(), SignTx(tx,chainID)(*types.Transaction,error)}
  internal/keymgr/keymgr_test.go
  internal/chain/action.go        # Action + Plan value types (HERE, not in job — chain.Submit consumes Action; see C1)
  internal/chain/chain.go         # Chain + NewChain(...) ; Submit(ctx, Action)(*types.Receipt,err) ; ResyncNonce(ctx)
  internal/chain/read.go          # Reader iface + view-read helpers: CallUint/CallBool/CallAddress(+ arg variants)
  internal/chain/chain_test.go    # simulated-backend submit-spine + read-helper round-trips
  internal/job/job.go             # Job interface + Runner + NewRunner(...) (schedule loop, fail-safe, graceful stop)
  internal/job/identity_job.go    # the reference read-only identity/liveness probe
  internal/job/job_test.go        # Runner drives a job end-to-end on the simulated backend
```

> **C1 — package-dependency direction (kill the import cycle; the #1 cold-build blocker).** `chain.Submit` consumes
> an `Action`, and `job.Runner` consumes a `chain.Chain` + a `chain.Reader`. So **`Action`/`Plan` live in
> `internal/chain` (in `action.go`)**, and `internal/job` imports `internal/chain` (for `Chain`, `Reader`, `Action`,
> `Plan`). The dependency is **one-way** `job → chain`; `internal/chain` MUST NOT import `internal/job`. `cmd/keeper`
> imports both. (Do not place `Action`/`Plan` in `job` — that creates the `chain ⇄ job` cycle and `go build` fails.)

## Key requirements

### K1 — config (`internal/config`)
- `Config` fields (all required unless noted): `RPCURL string`, `ChainID uint64`, `PollInterval time.Duration`
  (e.g. `30s`), `GasBufferBps uint64` (default `3000` ⇒ gas-units ×1.30; applies to the **gas limit only**, NOT the
  fee cap — see K3), `FeeCapMultiplier uint64` (default `2`; the base-fee headroom knob, see K3),
  `ConfirmTimeout time.Duration` (e.g. `60s`), and an **address book**
  `Modules map[string]common.Address` keyed by name (`FarmUtilityLoopModule`, `ExitGate`, `ZipRedemptionQueue`, …).
- `Load()`: **apply defaults first**, then read env, then `Validate()` — so an unset `KEEPER_GAS_BUFFER_BPS` becomes
  `3000` (valid) and only an explicit `KEEPER_GAS_BUFFER_BPS=0` is rejected. Env keys: `KEEPER_RPC_URL`,
  `KEEPER_CHAIN_ID`, `KEEPER_POLL_INTERVAL`, `KEEPER_GAS_BUFFER_BPS`, `KEEPER_FEE_CAP_MULTIPLIER`,
  `KEEPER_CONFIRM_TIMEOUT`, and `KEEPER_ADDR_<NAME>=0x…` for each module. **Optional** JSON file via
  `KEEPER_CONFIG_FILE` overlaid first, env wins.
- `Validate()` rejects: empty `RPCURL`; `ChainID==0`; `GasBufferBps==0`; `FeeCapMultiplier==0`;
  `PollInterval<=0`; `ConfirmTimeout<=0`. **Address-book scope:** `Validate()` requires non-zero/valid addresses
  ONLY for the names this window's startup-check + registered jobs actually reference (this window:
  `FarmUtilityLoopModule` and `ExitGate`). Unreferenced book entries (e.g. `ZipRedemptionQueue` — registered for
  KEEPER-01, not called here) MAY be absent/zero. Provide `Config.MustAddr(name) (common.Address, error)` (errors
  loudly — not a panic — if a *referenced* name is missing/zero) so a job declares which names it needs and
  `main.go` fail-fasts cleanly.
- The **operator key is NOT in Config** — it lives only in keymgr's input (`KEEPER_OPERATOR_KEY`), so a Config dump
  can never leak it.
- `config_test.go`: env-load happy path; default-applied-before-validate (bare env ⇒ `GasBufferBps==3000`, valid);
  each validation rejection.

### K2 — key management (`internal/keymgr`)
- `Load() (*Signer, error)`: read `KEEPER_OPERATOR_KEY` (0x-hex, 32-byte). Optionally support a geth **keystore**
  file path via `KEEPER_KEYSTORE_FILE` + `KEEPER_KEYSTORE_PASSWORD` (use `keystore.DecryptKey`) — env-hex is the
  primary path; keystore is a documented secondary. `crypto.HexToECDSA` → `*ecdsa.PrivateKey`;
  `crypto.PubkeyToAddress(key.PublicKey)` → `Address()`.
- `Signer.SignTx(tx *types.Transaction, chainID *big.Int) (*types.Transaction, error)`:
  `return types.SignTx(tx, types.LatestSignerForChainID(chainID), key)`.
- Expose `LoadHex(hexKey) (*Signer, error)` (the env path `Load()` delegates to it after reading
  `KEEPER_OPERATOR_KEY`); tests build a `Signer` from a raw hex string via `LoadHex` without env plumbing.
- **The key is NEVER logged, NEVER put in an error string, NEVER in Config.** Logs show only `Address()`. Loud,
  non-key error on empty/garbage input.
- `keymgr_test.go`: hex-load → known address (use anvil acct #3: key `0x5de4…b365a` ⇒ `0x3C44…93BC`); reject empty;
  reject non-hex.

### K3 — chain client (`internal/chain`)
- **`Backend` interface** — declare a minimal interface listing **exactly** the methods used: `CallContract(ctx,
  ethereum.CallMsg, *big.Int)([]byte,error)`, `PendingNonceAt(ctx, common.Address)(uint64,error)`,
  `SuggestGasTipCap(ctx)(*big.Int,error)`, `HeaderByNumber(ctx, *big.Int)(*types.Header,error)`, `EstimateGas(ctx,
  ethereum.CallMsg)(uint64,error)`, `SendTransaction(ctx, *types.Transaction)error`, `TransactionReceipt(ctx,
  common.Hash)(*types.Receipt,error)`. **Both `*ethclient.Client` and the `simulated.Client` returned by
  `(*simulated.Backend).Client()` satisfy this** — `*ethclient.Client` directly, and `simulated.Client` because its
  interface exposes the same method set (its concrete impl embeds `*ethclient.Client`). This is what lets the spine
  be tested deterministically without anvil. (Do not depend on extracting `*ethclient.Client` out of
  `simulated.Client` — the SDK deliberately prevents it; depend only on your `Backend` method set.)
- **`Reader` interface** — `CallContract(ctx, ethereum.CallMsg, *big.Int)([]byte,error)` only, so jobs read through
  an injectable seam (`Chain` and the raw clients all satisfy it).
- `read.go` view helpers — **re-implement** following the decode patterns in `cre/buyburn-bid/workflow.go:289-357`
  (the read TRANSPORT differs: go-ethereum's `Reader.CallContract(ctx, ethereum.CallMsg{To:&addr, Data:calldata},
  nil)` with the **block arg `nil` = latest**, vs the wasip1 `evm.Client.CallContract`). Helpers:
  `selector(sig string) []byte` (= `crypto.Keccak256([]byte(sig))[:4]`); `CallUint(ctx, r, to, sig) (*big.Int,error)`;
  `CallBool(ctx, r, to, sig) (bool,error)`; `CallAddress(ctx, r, to, sig) (common.Address,error)` (decode via
  `abi.Arguments{{Type: addressT}}.Unpack` → `out[0].(common.Address)`); arg variant
  `CallUintWithAddr(ctx, r, to, sig, arg common.Address) (*big.Int,error)`. `CallMsg.From` left zero for views.
- **`Chain` + `NewChain`** — `NewChain(backend Backend, chainID *big.Int, signer *keymgr.Signer, cfg *config.Config)
  *Chain`. `Chain` stores `chainID` as a **`*big.Int`** (Config's `uint64` → `new(big.Int).SetUint64`), the buffer
  bps + fee-cap multiplier, and a **mutex-guarded `nonce uint64`** (the in-process counter). `cmd/keeper` constructs
  it (no unexported-field access across packages).
- **`Chain.ResyncNonce(ctx) error`** — sets the local counter to `PendingNonceAt(ctx, signer.Address())`. The
  `Runner` calls this **once at the start of each tick** (so the counter tracks externally-landed txs / key rotation).
- **`Chain.Submit(ctx, Action) (*types.Receipt, error)`** (nonce-safe — finding-driven):
  1. `nonce`: read the current **local** counter under the mutex (do NOT call `PendingNonceAt` per Action —
     `ResyncNonce` already seeded it for the tick; per-Action `PendingNonceAt` would return the same nonce for a
     not-yet-mined predecessor and collide).
  2. `tipCap = SuggestGasTipCap`; `baseFee = HeaderByNumber(ctx,nil).BaseFee`;
     `maxFee = baseFee*FeeCapMultiplier + tipCap` (FeeCapMultiplier is the documented base-fee headroom knob — a
     transient base-fee spike past `maxFee` is a *liveness* stall the contracts fail-safe against, not a safety bug).
  3. `gasLimit`: if `Action.GasLimit==0`, `EstimateGas(ctx, CallMsg{From:signer.Address(), To:&action.To, Data})`
     then `gasLimit = est*(10000+GasBufferBps)/10000`; else use the supplied limit. **`EstimateGas` doubles as a
     dry-run:** if it errors (the call would revert), `Submit` returns that error **without sending** and **without
     advancing the nonce** — the Runner then aborts the rest of the plan (K4).
  4. build `types.NewTx(&types.DynamicFeeTx{ChainID, Nonce, GasTipCap, GasFeeCap, Gas, To:&action.To, Data})`,
     `signer.SignTx`, `SendTransaction`. **Advance the local nonce counter ONLY after `SendTransaction` returns
     nil** — a failed send leaves the counter unchanged so the next Action reuses the slot (no gap nonce).
  5. **wait:** poll `TransactionReceipt` until found or `ConfirmTimeout`; require `Status==1`, else return a clear
     `tx reverted` error (include tx hash, NOT the key). Production `Submit` **always** sets `To` (it never deploys).
- `chain_test.go`: on a `simulated.Backend` seeded with the operator account funded (`types.GenesisAlloc{operator:
  {Balance: big}}`):
  - **chainID = 1337.** `simulated.NewBackend` hardcodes chainID **1337** (`params.AllDevChainProtocolChanges`), NOT
    8453. Build `NewChain` with `big.NewInt(1337)` in the test so signing/submission match the backend. (Production
    uses Config's 8453 against anvil.)
  - Deploy the **`OnlyOperatorProbe`** (creation bytecode below) with a **one-off raw deploy tx in the test** (build
    a `DynamicFeeTx` with `To:nil` + the bytecode, sign, send, mine, take `receipt.ContractAddress`) — deploy is
    NOT a `Submit` path (Submit always has `To`).
  - Run `setValue(42)` via `Action{To: probe, Data: append(selector("setValue(uint256)"), <abi uint256 42>...)}`;
    assert `CallUint(probe,"value()")==42`, the gas buffer was applied (final gasLimit > raw estimate), and a
    **2-action plan** lands both txs at consecutive nonces.
  - **Simulated-backend mining:** the backend mines only on `Commit()` (no auto-mine, blockPeriod 0). Spin a
    committer goroutine `for { select { case <-done: return; default: b.Commit(); time.Sleep(5*time.Millisecond) } }`
    so `Submit`'s receipt-poll resolves. **Race-safe teardown (`-race`):** the committer must `defer close(exited)`
    and `stop` must `close(done); <-exited` so the goroutine has fully returned before any `(*Backend).Close()` runs
    (otherwise an in-flight `Commit()` races `Close()`).
  - **Nonce-gap regression:** submit an Action whose `SendTransaction` is forced to fail (or whose `EstimateGas`
    reverts), then a follow-up Action; assert the follow-up uses the **same** nonce the failed one would have (no gap).
  - Read-helper round-trips: `CallAddress(probe,"operator()")` == the operator; `CallUint(probe,"value()")` == 42.

### K4 — the Job spine (`internal/chain` types + `internal/job` Job/Runner)
`Action`/`Plan` are defined in **`internal/chain`** (C1 — kills the import cycle):
```go
// internal/chain/action.go
type Action struct { Label string; To common.Address; Data []byte; GasLimit uint64 } // GasLimit 0 ⇒ estimate
type Plan struct { Actions []Action } // empty ⇒ no-op (skip)
```
```go
// internal/job/job.go
type Job interface {
    Name() string
    Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) // READ + COMPUTE only; never submits
}
```
- `Runner` (unexported fields) built via `NewRunner(c *chain.Chain, jobs []Job, interval time.Duration,
  log *slog.Logger) *Runner`. `Run(ctx)`:
  - ticker loop on `interval`; each tick: **`chain.ResyncNonce(ctx)`** first, then for each job `Evaluate` → submit
    the returned `Plan`.
  - **Plan submission is ordered + abort-on-first-error:** `chain.Submit` each Action **in order**; on the **first**
    Action that errors, **log it and STOP submitting the rest of that plan** (do NOT continue to later Actions —
    a partially-applied ordered sequence, e.g. borrow-without-repay, is the one unsafe outcome the spine must avoid;
    combined with K3's "advance nonce only after a successful send," this guarantees no gap nonce and no
    half-executed sequence). Then move to the next job.
  - **Fail-safe between jobs:** a job's `Evaluate` error or a plan's aborted submission is **logged and the loop
    continues** to the next job / next tick (never panic, never crash) — liveness-only failure, never unsafe
    (CRE-OPS-ROUTING §"Failure mode = LIVENESS-ONLY, and FAIL-SAFE").
  - `ctx.Done()` (SIGINT/SIGTERM via `signal.NotifyContext`) → finish the in-flight Action, return.
- **SUBMIT/COMPUTE separation:** `Job.Evaluate` is pure (read+decide); only the `Runner` submits. This is the seam
  KEEPER-01 plugs harvest/burn/settle jobs into — each a `Job` returning a `chain.Plan`.
- **Poll-only spine (by design).** The Runner is a poll loop; jobs read fresh state each tick. KEEPER-01's
  fill-detect (szipUSD landing in the engine Safe) and CRE-02's `RedemptionSettled` sequencing are **balance/state
  polls inside `Evaluate`**, NOT log subscriptions — there is no on-chain "fill" event to subscribe to (the
  keeper-binding back-pressure note below). If event-driven triggering is ever wanted, it is a KEEPER-01 addition;
  the `Job` interface deliberately carries no log-subscription hook this window.

### K5 — the reference identity probe (`internal/job/identity_job.go`)
The selector to read per module is **explicit** (no magic name-matching). A check carries its own admin getter:
```go
type IdentityCheck struct { Name string; Addr common.Address; AdminSig string } // AdminSig: "operator()" or "windowController()"
type IdentityJob struct { want common.Address; checks []IdentityCheck }
```
- `Evaluate` for each check: read `check.AdminSig` via `chain.CallAddress` and require it == `want`; ALSO read
  **`owner()`** (`chain.CallAddress(addr,"owner()")`) and require it **!=** `want` — enforcing the §8.7
  `operator != owner` invariant the spec demands (verified exposed: zodiac `Ownable.owner()` and OZ `Ownable.owner()`,
  selector `0x8da5cb5b`). Any failure → return an **error** (the Runner logs the mismatch — a misconfigured/wrong key
  is a loud liveness failure, not silent). Returns an **empty `chain.Plan`** always (read-only; never writes).
- `cmd/keeper/main.go` builds the check list from config — `{"FarmUtilityLoopModule", addr, "operator()"}` and
  `{"ExitGate", addr, "windowController()"}` — and runs the assertion **once at startup** (fail-fast: refuse to start
  the Runner if it fails), then also registers `IdentityJob` as a heartbeat job.
- **Test `IdentityJob` with a stub `chain.Reader`** (anvil-free, simulated-free — the cleanest seam): a fake Reader
  returns canned ABI-encoded addresses keyed by the selector in the call data (`operator()`→X, `owner()`→Y). Cover:
  (i) `operator()==want && owner()!=want` ⇒ empty plan, nil error; (ii) `operator()!=want` ⇒ error; (iii)
  `owner()==want` ⇒ error (the `operator != owner` guard fires). Also assert the Runner logs-and-continues on the
  error (fail-safe). The `OnlyOperatorProbe` on the simulated backend is for the **submit-spine** test (K3/the Runner
  end-to-end), not the identity logic. (The `owner()!=creOperator` real-surface case is additionally exercised by the
  live-anvil acceptance, where `owner()`==Timelock `0x89ae…`.)

### K6 — docs
- `README.md`: one-paragraph "what/why (the (K) spine; not wasip1)", the env vars, **the gate commands**, and the
  **live-anvil acceptance** (below). Cross-link `CRE-OPS-ROUTING.md` + §8.7.
- `.env.example`: every `KEEPER_*` var with a **placeholder** operator key (the anvil dev key is fine to name as the
  M1/anvil value, clearly labelled "anvil dev key — replace for any real network"). `.gitignore`: `/.env`, keystores.

## The `OnlyOperatorProbe` test contract (real, forge-compiled — use verbatim)
Solidity (for reference; the bytecode below is what the test deploys — do NOT depend on a solc toolchain in `go test`):
```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
contract OnlyOperatorProbe {
    address public operator;   // selector operator()  = 0x570ca735
    uint256 public value;      // selector value()     = 0x3fa4f245
    error NotOperator();
    constructor() { operator = msg.sender; }
    function setValue(uint256 v) external {   // selector setValue(uint256) = 0x55241077
        if (msg.sender != operator) revert NotOperator();
        value = v;
    }
}
```
Creation bytecode (forge solc 0.8.24, paste as a Go const `probeBytecode` and `common.FromHex` it):
```
0x608060405234801561000f575f80fd5b505f80546001600160a01b0319163317905561015a8061002e5f395ff3fe608060405234801561000f575f80fd5b506004361061003f575f3560e01c80633fa4f24514610043578063552410771461005f578063570ca73514610074575b5f80fd5b61004c60015481565b6040519081526020015b60405180910390f35b61007261006d36600461010d565b6100b8565b005b5f546100939073ffffffffffffffffffffffffffffffffffffffff1681565b60405173ffffffffffffffffffffffffffffffffffffffff9091168152602001610056565b5f5473ffffffffffffffffffffffffffffffffffffffff163314610108576040517f7c214f0400000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b600155565b5f6020828403121561011d575f80fd5b503591905056fea2646970667358221220156c220f7fa39b0e12cc3a92ba44606f4c7f61d45dafc8ee52705be05efcfded64736f6c63430008180033
```
Selectors (verified `keccak256(sig)[:4]`): `setValue(uint256)=0x55241077`, `operator()=0x570ca735`, `value()=0x3fa4f245`.

## Do NOT
- Do **NOT** compile to `wasip1` — this is a native service (`go build ./...`, default GOOS/GOARCH).
- Do **NOT** import `cre-sdk-go` or `runtime.GenerateReport`/`WriteReport` — that is the (R) path; (K) submits raw txs.
- Do **NOT** implement any KEEPER-01 / CRE-02 logic: no harvest legs (8-B5…8-B10), no `burnFor`, no `settleEpoch`/
  `requestRedeem`/`claim`, no `commit`/`release`. The only on-chain interaction this window makes is **reading**
  `operator()`/`windowController()`. The submit path is exercised **only** against the synthetic
  `OnlyOperatorProbe` on the simulated backend.
- Do **NOT** hard-code any module address in Go — all addresses come from `Config` (§17 re-pointable).
- Do **NOT** log, wrap-into-error, or Config-embed the private key.
- Do **NOT** invent a new trust assumption — the keeper IS §13's single trusted operator (`operator != owner`).

## Done when (the per-track gate — keeper variant, replaces the wasip1 gate)
1. **`cd cre/keeper && go vet ./... && go build ./...`** exits 0 for the **native** target (NOT wasip1).
2. **`cd cre/keeper && go test ./...`** is green, including:
   - `chain`: the simulated-backend **submit-spine** test (deploy `OnlyOperatorProbe` → `setValue(42)` →
     `value()==42`; gas buffer applied; 2-action nonce sequencing) + read-helper round-trips.
     `setValue(42)` → `value()==42`; gas buffer applied; 2-action nonce sequencing; **nonce-gap regression** (a
     failed send/estimate does NOT advance the nonce)) + read-helper round-trips.
   - `keymgr`: hex-key → anvil acct #3 address `0x3C44…93BC`; rejects empty/garbage; key never appears in output.
   - `config`: env load + **default-before-validate** (bare env ⇒ `GasBufferBps==3000`, valid) + each validation rejection.
   - `job`: `Runner` drives a job end-to-end on the simulated backend; **abort-on-first-error** stops the rest of a
     plan; `IdentityJob` returns empty-plan/nil on a matching `operator()` and an error on a mismatch (incl. the
     `operator != owner` branch per K5); fail-safe (a job error doesn't crash the Runner).
3. The Go module is **committed to `cre/keeper/`** in this monorepo.
4. **Live-anvil acceptance (documented in README; gated on anvil up — NOT the CI gate):** with anvil up
   (`cast block-number --rpc-url http://127.0.0.1:8545`), `go run ./cmd/keeper` with the anvil env (operator key
   `0x5de4…b365a`, `KEEPER_ADDR_FarmUtilityLoopModule=0x61cd…`, `KEEPER_ADDR_ExitGate=0xd9b8…`) passes the startup
   identity assertion (reads `operator()`==`0x3C44…93BC`, `windowController()`==`0x3C44…93BC`) and the IdentityJob
   logs OK each tick. (No write tx is sent against anvil this window.)

A verdict is **"yes," never "yes-with-guesses."** If the cold-builder must guess a signature, path, or layout, the
gap folds back into this ticket.

## Depends on
- `CRE-OPS-ROUTING.md` (the (K) routing decision — done).
- The live anvil deployment for the acceptance (harness §7); the unit gate (1–3) needs **no** anvil.

## Notes forward to KEEPER-01 (recorded now; NOT owed this window)
- **Back-pressure (no on-chain fill event).** `burnFor` fires when szipUSD lands in the engine Safe; `ExitGate`
  emits only `Burned`, not a "fill" event. So KEEPER-01's fill-detect is a **balance poll**
  (`IERC20(shareToken).balanceOf(engineSafe)`; `shareToken`/`engineSafe` are exposed on `ExitGate.sol:50,52`) or a
  CoW-side read — not a log subscription. CRE-02's `RedemptionSettled` sequencing is likewise a state poll inside
  `Evaluate`. The poll-only spine (K4) is sufficient; no new contract surface is owed.
- **Harvest legs are discrete txs (no on-chain multicall).** `FarmUtilityLoopModule` exposes four separate
  `onlyOperator` entrypoints (post-collateral / borrow / repay / withdraw-collateral) + `outstandingDebt()` /
  `postedCollateral()` views. KEEPER-01's harvest job returns these as an **ordered `chain.Plan`** and relies on the
  spine's abort-on-first-error (K4) + nonce-safety (K3) so a dropped leg cannot leave a borrow-without-repay.
- **`abi.Pack` native-int quirk** (K3 note / `cre/buyburn-bid/workflow.go:248-252`): KEEPER-01's scalar args
  (`uint32`/`uint8`/`uint16`) must be passed as native Go ints to `abi.Arguments.Pack`, not `*big.Int`.

## Discharges / spawns
- Discharges nothing inbound (no Open-obligation row is owed *by* KEEPER-00).
- **Spawns/unblocks KEEPER-01** (= rest of CRE-05: harvest loop + `burnFor` + freeze-on-shortfall) and the **(K)
  half of CRE-02** (`OffRampModule.requestRedeem/claim`, `ZipRedemptionQueue.settleEpoch/claim`). Those plug `Job`
  implementations into this spine.
