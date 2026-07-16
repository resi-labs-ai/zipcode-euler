# cre-coordinator — the §8.4 loss-action producer (reportType 8 → `DefaultCoordinator`)

A wasip1 CRE report-path (R) workflow. It is the loss-side / default-recovery producer: an off-chain loss
event arrives via the `http.Trigger`, the workflow reaches **identical consensus** on the event record,
normalizes + **dispatches on the action discriminant**, validates the per-action required fields, encodes the
matching payload via the shared `cre/zipreport` library, and emits **one `WriteReport`** to the
`DefaultCoordinator` as the §8.0 envelope `abi.encode(uint8 reportType, bytes payload)` — where the payload is
itself the §8.4 inner `abi.encode(uint8 action, bytes actionData)`.

This is **CRE-01c**, the third and last slice of the CRE-01 controller/loss family (CRE-01a revaluation →
registry rt3; CRE-01b origination/draw/close/status → controller rt1/2/4/5,6; CRE-01c loss actions →
coordinator rt8).

## The trigger + the event

One trigger only: `http.Trigger` (§8.4 — default/recovery are off-chain-event-driven; **no cron heartbeat**).
The off-chain loss pipeline POSTs one JSON loss event; `http.Payload.Input` is the JSON body. The consensus
carrier (`LossEvent`) is **string fields only** — every magnitude/address/hash is carried as a string and
parsed on the DON side **after** consensus.

```json
{ "action": "lock", "lienId": "0x…64hex", "originator": "0x…40hex", "amount": "1000000000000000000" }
```

## The 6-action discriminant (all reportType 8)

The action string is normalized (`strings.ToLower(strings.TrimSpace(...))`), so `"Lock"` / `" lock "` all
match. An unknown or empty action ⇒ error, no write.

| action | byte | encoder | actionData tuple | units | required fields |
|---|---|---|---|---|---|
| `lock` | 0 `Lock` | `zipreport.CoordLock` | `(bytes32 lienId, address originator, uint256 amount)` | amount = xALPHA 18-dp | lienId (non-zero), originator (non-zero address), amount (> 0) |
| `release` | 1 `Release` | `zipreport.CoordRelease` | `(bytes32 lienId)` | — | lienId (non-zero) |
| `default` | 2 `Default_` | `zipreport.CoordDefault` | `(bytes32 lienId, uint256 atRisk)` | atRisk = 18-dp USD | lienId (non-zero), atRisk (> 0) |
| `recovery` | 3 `Recovery` | `zipreport.CoordRecovery` | `(bytes32 lienId, uint256 recoveryProceeds)` | recoveryProceeds = 18-dp USD | lienId (non-zero), recoveryProceeds (present, **may be 0**) |
| `resolve` | 4 `Resolve` | `zipreport.CoordResolve` | `(bytes32 lienId, uint256 capitalSlashAmount)` | capitalSlashAmount = xALPHA 18-dp | lienId (non-zero), capitalSlashAmount (present, **may be 0**) |
| `writeoff` | 5 `WriteOff` | `zipreport.CoordWriteOff` | `(bytes32 lienId, uint256 capitalSlashAmount)` | capitalSlashAmount = xALPHA 18-dp | lienId (non-zero), capitalSlashAmount (present, **may be 0**) |

The required-vs-optional rules are derived from the contract's revert guards: `default` reverts `ZeroAtRisk`
and the escrow reverts `ZeroOriginator` / `ZeroAmount` on `lock`, so those are validated `> 0` / non-zero;
`recoveryProceeds` / `capitalSlashAmount` **may be 0** because the contract tolerates a 0 heal (no-op recovery)
and a 0 capital slash (route all to cohort). A missing/unparseable required field ⇒ error, no write — a
malformed event is a producer-side bug to surface. A 0-magnitude `recovery`/`resolve`/`writeoff` ⇒ exactly one
write.

### Example events

```json
{ "action": "release",  "lienId": "0x…" }
{ "action": "default",  "lienId": "0x…", "atRisk": "5000000000000000000" }
{ "action": "recovery", "lienId": "0x…", "recoveryProceeds": "2500000000000000000" }
{ "action": "resolve",  "lienId": "0x…", "capitalSlashAmount": "0" }
{ "action": "writeoff", "lienId": "0x…", "capitalSlashAmount": "999000000000000000" }
```

## M1-live vs M2 — an OPERATIONAL split, not a code gate

The encode handshake is identical machinery for all six actions; this producer builds + tests all six. Which
actions the off-chain pipeline actually fires when is an operational distinction, **not branched in code**:

- **M1-live:** `lock` (post launch bond), `release` (clean repay).
- **M2 demo:** `default`, `recovery`, `resolve`, `writeoff` (the economic default/slash family).

## Two receivers for one real-world default

A real-world default produces **two** independent reports to **two** receivers (§8.4 line 651):

- The bare reportType-**5** default-**status** report → the **`ZipcodeController`** (status marker + legal-action
  event). That is **CRE-01b's rt5**, already built — this producer does **NOT** emit it.
- The reportType-**8** DEFAULT economic action (`atRisk` → provision + `SzipNavOracle`) → the
  **`DefaultCoordinator`**. That is **this producer**.

The split is on the **receiver**, not on "default vs not". This producer's only receiver is the
`DefaultCoordinator`.

## No Proof gate (§8.9 / DEC-01, RESOLVED)

There is **no on-chain boolean Proof gate** on the loss family. The `DefaultCoordinator`'s six decode tuples
carry no booleans; the **identical consensus over the loss facts IS the attestation**, and the §13 Forwarder +
Timelock-pinned workflow identity is the entry guard. Every well-formed action emits exactly one report —
exactly the posture CRE-01a (revaluation, also a §8.9 line-847 "credit fact") built. There is **no `Gates`
struct and no "emit only if gates pass" branch** here.

## The §8.4/§8.9 mock-feed seam

For the build, `observe` `json.Unmarshal`s the identical trigger-supplied loss event on every node
(deterministic → identical consensus holds). The **real-feed swap** replaces that `json.Unmarshal` with
per-node `httpcap.Client.SendRequest` to the real recovery/foreclosure/insurance feeds + on-node
hash/cert-chain verify, deriving the loss magnitudes (`atRisk` / `recoveryProceeds` / `capitalSlashAmount`) +
the capital-vs-premium split per node. The `RunInNodeMode` + consensus + dispatch + encode + write machinery is
unchanged. `observe` MUST NOT read secrets (NodeRuntime has no SecretsProvider); any future DON-only feed token
is read in the **handler**, never `observe`.

## Anticipated on-chain reverts (surfaced, not pre-checked)

The producer sends a well-formed report; it does **NOT** replicate the coordinator's status machine or the
escrow bond size. These on-chain backstops surface as the returned write error: `lock` can revert `BadStatus`
(lien not `None`), `SelfOriginator`, `BondExists`, or hit an unwired escrow; `release`/`default` need `Bonded`;
`recovery`/`resolve`/`writeoff` need `Defaulted`; `resolve`/`writeoff` revert `ExceedsBond` if
`capitalSlashAmount > bond`.

## The gate

```sh
cd cre/coordinator
go build ./... && go vet ./...
GOOS=wasip1 GOARCH=wasm go build ./...   # the wasip1 target — the real gate
go test ./... -count=1 -v
```

## Cross-references

- Spec §8.4 (default/recovery), §8.9 (no boolean gate on the loss family), §8.0 (the shared envelope), §17
  (Config-driven wiring), §13 (the trust boundary).
- `cre/zipreport` (CRE-00) — the shared §8.0 + §8.4 encoder (`CoordLock`/`CoordRelease`/`CoordDefault`/
  `CoordRecovery`/`CoordResolve`/`CoordWriteOff`). This slice imports it; it does NOT re-encode.
- `contracts/src/loss/DefaultCoordinator.sol` — the filed receiver (the decode sites + the status machine).
- `cre/controller/` (CRE-01b) — the http + zipreport sibling this module was cloned from.
