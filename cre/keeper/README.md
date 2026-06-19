# cre/keeper — the (K) read→compute→submit spine

**What/why.** This is the off-chain Go keeper service: the single immutable CRE
operator's embodiment (spec **§8.7** / **§13** — `operator != owner`, one immutable
operator identity, no new trust assumption). It is a **native go-ethereum service
that submits ordinary transactions** — **NOT a wasip1 workflow** (it imports no
`cre-sdk-go`, has no report path). It provides the foundation every (K) item builds
on: config + operator key management + the `Read → Compute → Submit` job spine +
shared chain-read helpers. The only on-chain interaction this window makes is
**reading** `operator()` / `windowController()`; the engine-specific jobs
(harvest / `burnFor` / `settleEpoch`) are **KEEPER-01**, not here. See
[`../../build/tickets/cre/CRE-OPS-ROUTING.md`](../../build/tickets/cre/CRE-OPS-ROUTING.md)
for the (K)/(R) split and the fail-safe / liveness-only failure model.

## Layout
- `cmd/keeper` — entrypoint: load config + key → dial → `chain.NewChain` → startup
  identity assertion → register jobs → `job.NewRunner` → `Run(ctx)`.
- `internal/config` — `Config` + `Load()` (env, optional JSON overlay) + `Validate()`.
- `internal/keymgr` — operator key load (hex or geth keystore) + `SignTx`. Key never logged.
- `internal/chain` — `Backend`/`Reader` interfaces, view-read helpers, the nonce-safe
  `Submit` spine, and the `Action`/`Plan` value types (here, not in `job`, to break the
  import cycle — `job → chain` is one-way).
- `internal/job` — the `Job` interface + fail-safe `Runner` + the reference
  read-only `IdentityJob` (the template KEEPER-01 clones).

## Env vars
See [`.env.example`](.env.example). Summary:

| Var | Meaning | Default |
|---|---|---|
| `KEEPER_OPERATOR_KEY` | operator hot key, 0x-hex (primary) | — (required unless keystore) |
| `KEEPER_KEYSTORE_FILE` / `KEEPER_KEYSTORE_PASSWORD` | geth keystore path + password (secondary) | — |
| `KEEPER_RPC_URL` | JSON-RPC endpoint | — (required) |
| `KEEPER_CHAIN_ID` | chain id (anvil/Base = 8453) | — (required) |
| `KEEPER_POLL_INTERVAL` | job tick interval | `30s` |
| `KEEPER_GAS_BUFFER_BPS` | gas-LIMIT buffer in bps (3000 ⇒ ×1.30) | `3000` |
| `KEEPER_FEE_CAP_MULTIPLIER` | base-fee headroom (`maxFee = baseFee*MULT + tip`) | `2` |
| `KEEPER_CONFIRM_TIMEOUT` | receipt-wait timeout | `60s` |
| `KEEPER_MIN_BURN_AMOUNT` | BurnJob floor (base-10; 0 = any fill) | `0` |
| `KEEPER_CUSHION_BPS` | StrikeLoop slippage/min-floor cushion, bps | `200` |
| `KEEPER_AMBER_FRACTION_BPS` | StrikeLoop amber-band taper fraction, bps | `5000` |
| `KEEPER_RECYCLE_FRACTION_BPS` | StrikeLoop fraction of floor surplus to recycle, bps | `10000` |
| `KEEPER_HALT_PRICE_USDC` | StrikeLoop halt-below HYDX price (USDC 6dp) | `15000` |
| `KEEPER_AMBER_PRICE_USDC` | StrikeLoop taper-below HYDX price (USDC 6dp) | `18000` |
| `KEEPER_DEADLINE_BUFFER` | StrikeLoop exercise/sell deadline buffer | `300s` |
| `KEEPER_TWAP_PERIOD` | ICHI TWAP window for `ZipToShares` | `3600s` |
| `KEEPER_MAX_BORROW_PER_CYCLE` | StrikeLoop per-cycle borrow ceiling (USDC 6dp) | — (**required** for StrikeLoop) |
| `KEEPER_ADDR_<NAME>` | address book entry (re-pointable, §17) | — |
| `KEEPER_CONFIG_FILE` | optional JSON overlay (env wins) | — |

The **StrikeLoopJob** (KEEPER-01b) is the auto-compounder harvest loop: one
ordered `chain.Plan` (claim → borrow → exercise → sell → repay → credit →
[recycle → addLiquidity → stake]) driving the six engine modules
(`HarvestVoteModule`, `ReservoirLoopModule`, `ExerciseModule`, `SellModule`,
`RecycleModule`, `LpStrategyModule`) with scalar amounts only. It is a pure
stateless poll (no EMA/state store); the price/share floors come from an
injectable `Quoter` seam (`internal/quote`) that binds to the Algebra HYDX/USDC
pool `globalState()` and the ICHI vault deposit math. `KEEPER_ADDR_*` for the six
modules + `KEEPER_ADDR_HydxUsdcPool` are required; the LP pool is read off the
vault.

The **private key is never** in `Config`, never logged, never in an error string —
logs show only the derived address.

## The gate (CI; no anvil needed)
```sh
cd cre/keeper && go vet ./... && go build ./...   # native target, NOT wasip1
cd cre/keeper && go test ./...
```
The submit spine is tested deterministically against go-ethereum's
`ethclient/simulated` backend (chainID **1337**) with the `OnlyOperatorProbe`
synthetic contract — no anvil required.

## Live-anvil acceptance (documented; gated on anvil up — NOT the CI gate)
With anvil up (`cast block-number --rpc-url http://127.0.0.1:8545`):
```sh
cd cre/keeper
export KEEPER_OPERATOR_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
export KEEPER_RPC_URL=http://127.0.0.1:8545
export KEEPER_CHAIN_ID=8453
export KEEPER_ADDR_ReservoirLoopModule=0x61cdc9c8839753f520cc9dc4f2a733e132fe10e4
export KEEPER_ADDR_ExitGate=0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e
go run ./cmd/keeper
```
Expected: the startup identity assertion passes — `operator()` on
ReservoirLoopModule == `0x3C44…93BC`, `windowController()` on ExitGate ==
`0x3C44…93BC`, and `owner()` != the operator (the live `owner()` is the Timelock
`0x89ae…`). The `IdentityJob` heartbeat then logs OK each tick. **No write tx is
sent against anvil this window.**
