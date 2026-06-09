# track-gates.md — the cold-build gate, per track

This extends the harness in `README.md` to non-Solidity work. **The harness loop is unchanged**
(draft → fan critics → triage spec-gap-first → cold-build to zero-guess → file → review). Only two
things are per-track: the **cold-build equivalent** (the zero-guess proof that replaces
`forge build`/`forge test`) and the **reference corpus** the "Model from" block verifies against.
Everything else — one-item-per-window, spec-gap-vs-ticket-gap triage, the obligations table, the
LEDGER digest, "Model from = verified not cited," the superintendent review — transfers 1:1.

Use this when authoring the **non-WOOF tracks** (CRE, subgraph, frontend) — the per-track
cold-build gate that replaces `forge build`/`forge test` for non-Solidity work.

---

## The invariant the gate must preserve

For WOOF, "cold-build to zero-guess" means: a fresh Claude, given the ticket alone, builds the
contract + tests and `forge build`/`forge test` pass with **no load-bearing guess** — every
structural choice, every Model-from resolve, every Done-when assertion is justified by the ticket
text, then the code is **KEPT + committed** (the old discard rule is retired — see README step 4).
The equivalent for each other track must preserve the same three properties:

- **Buildable from the ticket alone** (no tribal knowledge, no "ask the author").
- **Verified against real artifacts** (the reference corpus, and — critically — the *already-filed*
  contract ABIs/interfaces this track binds to), not against prose.
- **Built code KEPT + committed** — the ticket is the intent, the code is the proof; they live together.

A cold-build verdict is **"yes"**, never "yes-with-guesses." If the builder must guess, the gap is
folded back into the ticket and the build re-run.

---

## Per-track gate

### Solidity tracks — Bridge · M2 loss · sdVAULT contracts
**Gate: the existing one, verbatim.** `forge build` + `forge test` against live deps; the built code
is **KEPT + committed** under `contracts/src/...` (not reset to skeleton — retired rule). No other change.
- **Reference corpus:** `reference/subtensor` + `reference/evm-bittensor` (precompiles), `reference/ccip-starter-kit-foundry` + `reference/chainlink-ccip` (CCT pool), `reference/euler-vault-kit` / `reference/euler-earn` (vault + escrow), OZ.
- **Critic tier:** cheap-three (junior-developer + spec-fidelity + reference-verifier) **+ qa + security** — these are authority/custody-bearing (bond slashing, CCT mint/burn, vault strike financing).
- **Note:** the bridge's "Model from" must verify the Subtensor precompile addresses (`0x805` StakingV2, `0x802` Metagraph, `0x800` BalanceTransfer, `0x80c` AddressMapping) against the Rust impl in `reference/subtensor`, exactly as a WOOF ticket verifies an EVK signature.

### CRE workflows (Go → wasip1)
**Cold-build equivalent:** a fresh Claude builds the workflow from the ticket and proves:
1. `go build` compiles to the `wasip1` target (the deploy artifact).
2. **The report struct round-trips the on-chain ABI** — a table-driven test encodes the workflow's
   `ReportRequest` payload and asserts it `abi.decode`s to exactly the §4.4 per-type layout the
   *filed* `ZipcodeController` / `ZipcodeOracleRegistry` expect (`uint8 reportType` + the typed
   payload; types 1/2/4/5/6→controller, 3→registry). This is the seam that discharges the WOOF-05
   report-ABI obligation — it must be proven against the real contract interface, not described.
3. A **simulated run** of the trigger→`RunInNodeMode`→`ConsensusIdenticalAggregation`→
   `GenerateReport` shape executes without guessing SDK signatures.
- **Reference corpus (verify, not cite):** `reference/cre-sdk-go/standard_tests/*/main_wasip1.go`
  (the trigger/node-mode/consensus/report shape), `reference/cre-templates` (project layout),
  `reference/cre-cli` (simulate/deploy mechanics). Every `cre/runtime.go` / capability path cited
  in §8 must resolve to a real symbol at the named line.
- **Critic tier:** cheap-three **+ security** — the load-bearing rule is **no PII in node-mode
  consensus** (`GetSecret` is DON-Runtime-only); the security critic verifies raw PII never enters
  a consensus observation, only proofs/derived bounds do.
- **Built code KEPT + committed:** the Go module is committed alongside the ticket (not reset).

### Frontend (Inflow — Nuxt/Vue/viem)
**Cold-build equivalent** (the `INFLOW-06` ticket is the working model):
1. `nuxi typecheck` + the component builds.
2. **ABI-binding check** — the composable binds to the **real emitted events and method
   signatures** of the *already-filed* contract (e.g. `useZipDeposit` reads `previewZap` /
   `previewDeposit` and the `Zapped`/`Deposited` events that WOOF-06 actually emits). A binding to
   a method the contract does not expose is a load-bearing guess and fails the gate. This is the
   frontend analog of "the reference path must exist."
3. Any contract surface the ticket needs but the contract lacks becomes **back-pressure** — a new
   cross-track obligation owed *back* to the WOOF ticket (INFLOW-06 did exactly this).
- **Reference corpus:** `reference/euler-lite` (page/composable patterns, `useEulerTx`,
  `useEulerAddresses`) + the filed WOOF ABIs.
- **Critic tier:** cheap-three **+ frontend-integration**.

### Subgraph (TS / AssemblyScript manifest)
> **DEFERRED — no subgraph spec exists yet.** §9 (events) and §12 (on-chain NAV model) are *raw material*, NOT a
> subgraph recipe (no entities, no manifest, no mapping/derivation formulas). This gate is unrunnable until a
> **subgraph spec pass** (the §8-for-CRE analog) is authored — which happens at the **head of the frontend track,
> after item 10 freezes the §9 event ABIs**. The subgraph LEADS the frontend (the UI queries its GraphQL schema).
> The gate below is the *target* once that spec exists; do not author GRAPH-01/02 against §9/§12 alone.

**Cold-build equivalent (once the subgraph spec exists):**
1. `graph codegen` + `graph build` succeed against a manifest whose event handlers are generated
   from the **real event ABIs** of the filed contracts (§9 event list — `LienCreated`, `Borrow`/
   `Repay`, `Deposited`/`Zapped`, `EpochSettled`, `RegistryPriceSeed`, …). A handler for an event
   signature the contract does not emit fails the gate.
2. A **Matchstick mapping-handler unit** proves each handler writes the entity the §12 dashboard
   metric reads (NAV / peg / APR / utilization / insurance-coverage), so the GRAPH-02 metric
   formulas are checkable, not asserted.
- **Reference corpus:** the §9 event signatures + the filed WOOF event ABIs; the §12 metric
  definitions.
- **Critic tier:** cheap-three **+ qa** (the metric formulas are the testable surface).

### Subnet containers (Bittensor — Python/Rust)
**This track is the least mature → author a DESIGN ticket first.** Its cold-build equivalent is
weaker by necessity (no live DON to run against in-repo):
1. The container scaffold compiles and the validator/miner consensus loop runs against a **mocked
   Proof endpoint** (matching the "collateral mocked for MVP" precedent).
2. The **Proof-fetch interface contract** is pinned — request shape, return format, the zk-verify
   boundary — so SUBNET-02 and CRE's node-mode fetch agree on the wire format. This interface is
   the real deliverable of the first subnet ticket; it is blocked on DEC-01 (Proof capability).
- **Reference corpus:** `reference/subtensor` + `reference/evm-bittensor`, the Bittensor SDK.
- **Critic tier:** cheap-three **+ security** (zk-verify boundary, no-PII).
- **Gate honesty:** because there is no live consensus run in-repo, the subnet cold-build proves
  *buildability + interface agreement*, not end-to-end consensus. `log()`/state that limitation in
  the report — do not mark it as a full WOOF-grade live proof.

---

## What does NOT change

- **Triage still fixes the spec first.** A gap found authoring a CRE/Vue/subgraph ticket that
  traces to an under-defined mechanism edits `claude-zipcode.md` (and, only as a consequence, the
  spec-derived `audit/*`) before the ticket is written — exactly as the zap pass did for §4.5.
- **The obligations table is the seam ledger.** Cross-track obligations (CRE↔controller report ABI,
  Inflow↔contract surface, subgraph↔event signatures) are tracked in `PROGRESS.md`, discharged by the
  receiving ticket, verified by the spec-fidelity critic, confirmed by the superintendent.
- **One item per window; conclude on disk; STOP.** The builder window stays disposable; the
  superintendent stays persistent and runs the same per-cycle review, now including the cross-track
  seam step.
- **An item that returns no findings is a flag to be skeptical, not a win.**
