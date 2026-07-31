# Production `observe` — from mock feed to signed appraisal

Every credit-fact / mark workflow in this tree runs the same shape:

```
http trigger ─▶ RunInNodeMode(observe) ─▶ ConsensusIdenticalAggregation[Carrier] ─▶ validate ─▶ gate ─▶ zipreport encode ─▶ WriteReport
```

`observe` is the **node-mode observation** — it runs independently on every DON node and returns a typed
carrier, and the DON then takes **identical consensus** over that carrier (every node must produce a
byte-identical value or consensus fails).

Today every `observe` is a **MOCK FEED**: it `json.Unmarshal`s the trigger body and trusts it. In production
each is replaced by a per-node call to the real off-chain feed, an on-node verify (hash / cert-chain / zk), and a
derivation of the carrier from the *verified artifact*. The `RunInNodeMode + consensus + gate + encode + write`
machinery below `observe` does **not** change — only the body of `observe` does.

This note sketches that production body and states the one invariant that is easy to get wrong.

---

## The invariant: derive from the artifact, never from the node

`ConsensusIdenticalAggregation[Carrier]` requires **byte-identical** carriers across all nodes. Two consequences
bind every production `observe`:

1. **No node-local nondeterminism in the carrier.** No `time.Now()`, no `Math.rand`, no per-node RPC value that
   can differ across nodes. Every field must be a function of the *fetched, verified artifact* only.
2. **Timestamps come from the artifact, not the clock.** Any timestamp that lands in the carrier — and therefore
   on-chain — must be the value **embedded in the signed feed artifact** (its as-of time), not the node's wall
   clock at observe time. This is both a consensus requirement (clocks differ across nodes) *and* a correctness
   requirement (see SEC/L-3 below).

### Why the timestamp source is load-bearing (SEC/L-3)

The `ZipcodeOracleRegistry` orders every mark by **"as-of time of the mark"** and rejects any write that is not
strictly newer (`_writePrice` → `StaleReport`). Two producers feed that one ordering:

| Producer | How it supplies the as-of time | Why that is correct |
|---|---|---|
| `revaluation` (rt-3) | `uint32(runtime.Now().Unix())` at sweep (`revaluation/workflow.go:110`) | a revaluation sweep re-derives marks **fresh**, so as-of ≈ now |
| `controller` (rt-1/2) | `equityMarkTs` carried from the appraisal artifact | a draw/origination mark may be an **older** appraisal — as-of is NOT now |

Before SEC/L-3 the controller stamped `block.timestamp` (delivery time), so a stale out-of-order draw always won
the ordering and could overwrite a fresher revaluation with an older, higher mark. The fix makes the controller
seed carry the appraisal's own as-of time — which means **`observe` must derive `equityMarkTs` from the signed
appraisal**, never stamp it with `now`. Stamping `now` at observe would re-open the exact bug the on-chain fix
closed, and would also break identical consensus.

---

## The sketch (illustrative — NOT compiling; feeds are not wired)

Shown for `controller/observe` (the SEC/L-3 case). The other workflows follow the same skeleton with a different
feed, verify, and carrier — see the matrix below.

```go
// PRODUCTION observe (sketch): per-node fetch → verify → derive the carrier from the ARTIFACT.
// Replaces the mock json.Unmarshal at controller/workflow.go:166. Does not compile as-is: the feed client,
// endpoint config, artifact schema, and verify routine are placeholders for the real §8.10 integration.
func observe(in []byte, nrt cre.NodeRuntime) (Application, error) {
	// 0. The trigger still carries the ROUTING facts the DON cannot itself invent: which action, which lien,
	//    which silo, and a proofRef that pins WHICH appraisal artifact to fetch. Parse those first.
	var req TriggerRef // {action, lienId, siloId, proofRef, drawAmount, borrowLtv, liqLtv, cap}
	if err := json.Unmarshal(in, &req); err != nil {
		return Application{}, fmt.Errorf("observe: trigger ref: %w", err)
	}

	// 1. Per-node fetch of the signed appraisal + the §8.10 proof feeds (Plaid / Credit-Karma / Pippin / DART /
	//    Block-Analitica). httpcap.Client over NodeRuntime — NOT runtime.GetSecret (NodeRuntime has no
	//    SecretsProvider; a consensus observation forbids secrets).
	client := httpcap.NewClient() // placeholder ctor
	appraisal, err := fetchSignedAppraisal(client, nrt, req.ProofRef) // returns the signed artifact bytes
	if err != nil {
		return Application{}, fmt.Errorf("observe: appraisal fetch: %w", err)
	}

	// 2. On-node verify: signature / cert-chain / hash-commitment (and zk where applicable). A failed verify is a
	//    hard error → no carrier → the event does not mint (fail-closed).
	if err := verifyAppraisal(appraisal, req.ProofRef); err != nil {
		return Application{}, fmt.Errorf("observe: appraisal verify: %w", err)
	}

	// 3. Derive the carrier from the VERIFIED artifact. Every derived field is a pure function of `appraisal` —
	//    identical on every node.
	gates := deriveGates(appraisal) // §8.9/§8.10 booleans from the verified proof feeds

	// 3a. THE SEC/L-3 FIELDS: equityMark AND its as-of time both come from the artifact. `AsOfUnix` is the
	//     appraisal's OWN timestamp (when the valuation was struck) — do NOT substitute nrt/now here.
	return Application{
		Action:       req.Action,
		LienID:       req.LienID,
		ProofRef:     req.ProofRef,
		SiloID:       req.SiloID,
		EquityMark:   appraisal.EquityMarkBase10, // 18-dp mark, from the artifact
		EquityMarkTs: strconv.FormatUint(appraisal.AsOfUnix, 10), // ← artifact as-of, NOT now (SEC/L-3)
		DrawAmount:   req.DrawAmount,
		Cap:          req.Cap,
		BorrowLTV:    req.BorrowLTV,
		LiqLTV:       req.LiqLTV,
		Gates:        gates,
	}, nil
}
```

The handler below `observe` is unchanged: it validates the carrier (`parseUint48Ts(app.EquityMarkTs)` already
rejects a missing / zero / non-numeric / `>uint48` timestamp fail-closed), enforces the Proof gate, and encodes
via `zipreport.Origination` / `.Draw` — both of which now carry the trailing `sourceTs`.

> Note on `revaluation`: its `runtime.Now()` stamp lives in the **handler** (`workflow.go:110`), not `observe`,
> and is correct precisely because a reval sweep re-derives marks fresh (as-of ≈ now). Do **not** copy that
> pattern into `controller` — a controller mark is a *carried* appraisal, so its as-of must come from the artifact.

---

## Which workflows require the production `observe` rewrite

All five below share the mock-feed shape and must be rewritten when the real §8.10 endpoints integrate. Only the
**controller** carries the SEC/L-3 appraisal-timestamp requirement; the rest still owe the "derive from the
verified artifact, no node-local nondeterminism" discipline.

| Workflow | `observe` returns | Real feeds to wire (§8.10) | Derives | Timestamp source |
|---|---|---|---|---|
| **`controller`** (rt-1/2/4/5/6) | `Application` | Proof / Plaid / Credit-Karma / Pippin / DART / Block-Analitica | Gates + `EquityMark` + **`EquityMarkTs`** | **appraisal artifact as-of (SEC/L-3)** — never `now` |
| **`revaluation`** (rt-3) | `Marks` | Proof-of-Value feed | per-lien marks | handler stamps `runtime.Now()` (fresh sweep — ok) |
| **`sharefeeds`** (rt-7 NAV legs) | `LegMarks` | alphaUSD (TAO/alpha TWAP × TAO/USD) + HYDX/USD | leg prices | leg feed as-of (per NAV push) |
| **`coordinator`** (rt-8 loss) | `LossEvent` | recovery / foreclosure / insurance feeds | loss action + amounts | event feed as-of |
| **`warehouse`** (rt-1..4 ops) | `WarehouseOp` | §8.5 on-chain NAV sizing (shortfall / recovery draw) | amount / shares | on-chain read (no carried ts) |

`scaffold` is the reference template for the pattern (not a live producer). `zipreport`, `keeper`, and
`szalpha-rate` do not use this trigger-driven `observe` shape.

### SEC/L-3 scope, precisely

The on-chain fix (registry `seedPrice(…, ts)` + controller payloads gaining `sourceTs`) is complete and tested.
The **only** remaining producer obligation for SEC/L-3 is in **`controller/observe`**: source `EquityMarkTs` from
the signed appraisal's as-of time. Until the real feed is wired, the mock path satisfies this by requiring the
caller to put `equityMarkTs` (base-10 unix seconds, string) in the trigger JSON — see `controller/README.md`.
