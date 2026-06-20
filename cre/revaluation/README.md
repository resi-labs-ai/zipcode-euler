# cre-revaluation — the WOOF-02 gas-bounded revaluation producer (CRE-01a)

A `wasip1` Chainlink CRE workflow that turns an off-chain Proof-of-Value re-appraisal batch into one or more
on-chain price pushes to the [`ZipcodeOracleRegistry`](../../contracts/src/ZipcodeOracleRegistry.sol) as the
§8.0 envelope `abi.encode(uint8 reportType=3, bytes payload)` where
`payload = abi.encode(address[] liens, uint256[] prices, uint32 ts)`.

This is the **revaluation sweep → registry** slice of CRE-01 (the underwriting/controller and
default/recovery slices are CRE-01b / CRE-01c). It implements the §8.1 "Revaluation sharding (the WOOF-02
discharge)" runbook **verbatim**:

1. Reach **identical consensus** on the `(lien, mark)` set (notarized facts → identical, not median; §8.10).
2. **Validate + dedup** across the full sweep and **enforce equal-length** `liens`/`prices` **before** encoding.
3. **Shard** into gas-bounded batches sized to `MAX_LIENS_PER_REPORT`.
4. Emit **one `WriteReport` per shard** — each batch is independently atomic on-chain.

Encoding is delegated to the shared [`cre/zipreport`](../zipreport/README.md) library
(`zipreport.Revaluation`, CRE-00) — this slice does **not** re-implement the §8.0 handshake.

## Trigger + the JSON batch shape

One trigger: **`http.Trigger`** (§8.1 — revaluation is http/event-driven; there is **no cron heartbeat**, the
mark is event-driven Proof). The off-chain pipeline POSTs the batch; `http.Payload.Input` is the JSON body.

The wire shape (`Marks`) — lowercase `liens`/`prices` JSON tags are the feed contract the off-chain pipeline
must match:

```json
{
  "liens":  ["0xabc…", "0xdef…"],
  "prices": ["1500000000000000000000", "980000000000000000000"]
}
```

`liens` are hex lien-**token** addresses (the registry is keyed by token address, never `lienId`); `prices`
are base-10 decimal strings of the 18-dp equity marks.

## Config

```json
{
  "chainSelector": 1234567890,
  "registry": "0x…",
  "maxLiensPerReport": 50,
  "writeGasLimit": 600000,
  "authorizedKeys": []
}
```

- `registry` — the `ZipcodeOracleRegistry` receiver (§17: Config-driven, re-pointable; **never hardcoded**).
- `maxLiensPerReport` — the shard cap `MAX_LIENS_PER_REPORT`. **TUNABLE**, "calibrated on the target chain":
  the on-chain `_processReport` loop is O(n) with a per-entry `decimals()` staticcall + SSTORE, so the default
  **50** keeps a shard's processing well under the report `GasLimit`. `<= 0` falls back to 50.
- `writeGasLimit` — `WriteReport` gas limit; `0` falls back to `600000`.
- `authorizedKeys` — optional, reserved for `http.Config` request-signature validation (empty for the build).

The handler **logs the shard count** + total liens on every sweep.

## The §8.9 mock-feed seam + the §8.10 swap-in note

This slice builds against **mock Proof + mock feeds** (§8.9, DEC-01 RESOLVED). The node-mode `observe`
function `json.Unmarshal`s the **identical** trigger-supplied batch on every node (deterministic → identical
consensus holds). That `json.Unmarshal` is the **only** mocked seam:

> **§8.10 swap-in:** replace `observe`'s `json.Unmarshal` of the trigger batch with a per-node
> `httpcap.Client.SendRequest` to the real Proof-of-Value feed + an on-node hash/cert-chain verify. The
> `RunInNodeMode` + identical-consensus + shard + write machinery is **unchanged** — only the per-node fetch
> source moves from "the trigger body" to "a verified live endpoint."

The consensus carrier is `Marks{ Liens []string; Prices []string }` (parallel `[]string` slices only —
unambiguously Wrap-able + JSON-native); the hex/decimal strings are parsed to `common.Address` / `*big.Int`
**after** consensus, on the DON side.

## Fail-closed rules the producer enforces (before encoding)

- **Length mismatch** `len(liens) != len(prices)` → error, no write (don't rely on the on-chain
  `LengthMismatch`).
- **Malformed lien** (no `0x`, not 40 hex chars, or the zero address) → error. `common.HexToAddress` silently
  zero-pads bad input, so the hex string is validated **first**.
- **Zero / malformed price** → error (the on-chain `price == 0` revert is the backstop).
- **Duplicate lien** → error, **fail-closed** (on-chain a dup is silent last-write-wins; the producer surfaces
  it as the bug it is).

**No-op fail-safe:** empty marks ⇒ no write; unset `registry` ⇒ no write.

### The `StaleReport` same-second edge (known, intentionally not special-cased)

`ts = uint32(runtime.Now().Unix())` is always `<= block.timestamp` (DON time ≈ chain time), so `FutureTimestamp`
never trips, and `runtime.Now()` is monotonic across distinct sweeps, so the registry's strictly-newer
`StaleReport` guard holds in normal operation. **Edge:** a lien seeded/revalued in the *same wall-clock
second* would make a second push that second revert its shard. The long line-term validity window tolerates it
(the lien stays on its prior mark until the next push, §8.1); this is **deliberately not** special-cased (no
per-lien `cache.timestamp` read-back — that is outside the §8.1 runbook).

## Gate

```sh
go build ./... && go vet ./...          # host
GOOS=wasip1 GOARCH=wasm go build ./...  # the wasip1 target — the real gate
go test ./...                           # the host sim (testutils + evmmock)
```

`workflow_test.go` runs the full handler path (`RunInNodeMode` + `ConsensusIdenticalAggregation[Marks]` +
`runtime.Now()` stamp + `zipreport.Revaluation` + `GenerateReport` + `WriteReport`) under `testutils` +
`evmmock`, and asserts the captured envelope(s) `abi.decode` to the exact `(uint8 3, bytes)` →
`(address[], uint256[], uint32)` tuple the registry's `_processReport` expects — plus sharding
(`ceil(N/k)` writes, ordered subsets, identical `ts`, union == input), dedup/length/zero/malformed errors, and
the no-op cases.

## See also

- [§8.1 Revaluation sharding (WOOF-02)] + [§8.0 report envelope] in `build/claude-zipcode.md`.
- [`cre/zipreport`](../zipreport/README.md) — the shared §8.0 encoder (`zipreport.Revaluation`, reportType 3).
- [`cre/scaffold`](../scaffold/README.md) — the clone-me template this module is built from.
