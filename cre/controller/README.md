# cre-controller — the §8.1 controller lifecycle producer (CRE-01b)

A `wasip1` CRE (Chainlink Runtime Environment) workflow that produces the four `ZipcodeController` credit-fact
report types from off-chain underwriting / lifecycle events. It is the second of three CRE-01 slices
(CRE-01a = revaluation → registry; CRE-01c = default/recovery → `DefaultCoordinator`).

## What it is

An off-chain application / lifecycle event arrives via an **`http.Trigger`** (§8.1 — origination/lifecycle are
http/event-driven; **no cron heartbeat**). The workflow:

1. reaches **identical consensus** on the event record (the typed fields + the §8.9/§8.10 Proof boolean gates)
   via `RunInNodeMode` + `ConsensusIdenticalAggregation[Application]`;
2. dispatches on the **action discriminant**;
3. validates the per-action required fields and **enforces the §8.9 Proof gate** (fail-closed — a credit-fact
   report is emitted ONLY if every gate passes);
4. encodes the matching payload via the shared **`cre/zipreport`** library (CRE-00 — this slice does NOT
   re-implement the §8.0 handshake);
5. emits **one `WriteReport`** to the `ZipcodeController` as the §8.0 envelope
   `abi.encode(uint8 reportType, bytes payload)`.

## The action discriminant

| action (JSON `action`)    | reportType                    | encoder                | Proof-gate? | carries siloId?       |
|---------------------------|-------------------------------|------------------------|-------------|-----------------------|
| `origination`             | 1 `RT_ORIGINATION`            | `zipreport.Origination`| **yes**     | **yes** (CTR-03)      |
| `draw`                    | 2 `RT_DRAW`                   | `zipreport.Draw`       | **yes**     | no (re-resolved on-chain) |
| `close`                   | 4 `RT_CLOSE`                  | `zipreport.Close`      | no          | no                    |
| `default` / `liquidation` | 5 `RT_DEFAULT` / 6 `RT_LIQUIDATION` | `zipreport.Status` | no       | no                    |

The action is normalized with `strings.ToLower(strings.TrimSpace(...))`, so `"Origination"` / `" origination "`
all match. An unknown or empty action is an error (no write).

### siloId on origination only (CTR-03 / §8.0 534-538)

`RT_ORIGINATION` carries a trailing `bytes32 siloId` (the current fill-target silo). `RT_DRAW` / `RT_CLOSE` do
**not** — those branches re-resolve the venue from the controller's stored `r.siloId`, so the producer never
re-sends it.

## The §8.9 Proof gate (all-must-pass, fail-closed)

Each credit-fact report (`origination`, `draw`) carries six §8.10 boolean gates: `lienPerfected`, `insured`,
`identityOk`, `creditOk`, `incomeOk`, `titleClean`. **All six must be true** for the report to be emitted; if
**any** is false the workflow logs and returns with **no write** (fail-closed no-op). `close` and
`default`/`liquidation` have no Proof gate (the on-chain zero-debt check / status-marker semantics own that).

### The §8.10 mock-feed seam

For the build (the spec-sanctioned "CRE-01 builds against mock Proof + mock feeds" posture), the Proof gates +
the equity mark arrive **pre-computed on the trigger payload**, and every node `json.Unmarshal`s the identical
event (deterministic → identical consensus holds). The swap-in: replace the `json.Unmarshal` in `observe` with
per-node `httpcap.Client.SendRequest` to the real Proof / Plaid / Credit-Karma / Pippin / DART /
Block-Analitica feeds + on-node zk/hash/cert-chain verify, deriving `Gates` + `EquityMark` per node. The
`RunInNodeMode` + consensus + gate + encode + write machinery is unchanged. `observe` must never read a secret
(NodeRuntime has no `SecretsProvider`; §8.1); a future DON-only feed token is read in the handler.

## Config (§17 — Config-driven, no hardcoded address)

`cre.ParseJSON[Config]`:

- `chainSelector` (uint64) — the chain hosting the `ZipcodeController`
- `controller` (string) — the `ZipcodeController` receiver address; unset ⇒ no-op
- `writeGasLimit` (uint64) — `WriteReport` gas limit; `0` falls back to `600000`
- `authorizedKeys` ([]string) — optional, reserved for `http.Config`

## Per-action JSON event shapes (one example each)

```jsonc
// origination (rt1) — Proof-gated, carries siloId
{
  "action": "origination",
  "lienId": "0xab...01", "proofRef": "0xab...02", "siloId": "0xab...03",
  "equityMark": "1500000000000000000",  // 18-dp mark, > 0
  "drawAmount": "1000000000000000000", "cap": "5000000000000000000",  // may be 0
  "borrowLtv": 7500, "liqLtv": 8500,    // 1e4-scale uint16
  "gates": { "lienPerfected": true, "insured": true, "identityOk": true,
             "creditOk": true, "incomeOk": true, "titleClean": true }
}
```
```jsonc
// draw (rt2) — Proof-gated, NO siloId
{ "action": "draw", "lienId": "0xab...11", "proofRef": "0xab...12",
  "equityMark": "2000000000000000000", "drawAmount": "750000000000000000",
  "gates": { "lienPerfected": true, "insured": true, "identityOk": true,
             "creditOk": true, "incomeOk": true, "titleClean": true } }
```
```jsonc
// close (rt4) — no Proof gate; only lienId is read
{ "action": "close", "lienId": "0xab...21" }
```
```jsonc
// default (rt5) / liquidation (rt6) — status marker, no Proof gate
{ "action": "default", "lienId": "0xab...31", "status": 2 }
```

`lienId` / `siloId` must be a `0x`-prefixed 64-hex-char **non-zero** bytes32; `proofRef` is a bytes32 that
**may be zero** (an off-chain commitment). A missing/malformed required field is an error (no write).

## The gate

```sh
cd cre/controller
go build ./... && go vet ./...                 # host
GOOS=wasip1 GOARCH=wasm go build ./...          # the wasip1 target (the real gate)
go test ./...                                   # full-handler sims + decode handshakes + gate cases
```

## Cross-links

§8.1 (the producer), §8.9 / §8.10 (the Proof gate + off-chain feed layer), §8.0 (the envelope + decode tuples),
`cre/zipreport` (CRE-00, the shared encoder), `cre/revaluation` (CRE-01a, the sibling registry producer).
