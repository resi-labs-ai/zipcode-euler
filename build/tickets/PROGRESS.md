# PROGRESS.md — the living tracker (what's NEXT, what's left)

The forward edge of the build. `build/harness.md` reads the **NEXT** item here to know what to work on.

This file does **not** track what was built — the built contract stack is truth-sourced in `build/wires/`
(index: `build/wires/COVERAGE.md`). This tracks only the remaining work (CRE, frontend, subgraph) and the
open seams. One item moves at a time: finish it, set the next `NEXT`, STOP.

---

## NEXT

**CRE-00 — Project + secrets scaffold + shared report-encoding package.**
- **Deliverable:** a `cre/` Go workspace (`cre-templates` layout) that builds to the `wasip1` target, wires the
  DON-only `GetSecret` config path, and ships the shared §8.0 report-encoding package (the
  `abi.encode(uint8 reportType, bytes payload)` envelope + one typed packer per filed reportType) that
  CRE-01…05 reuse.
- **Binds to:** the filed report consumers' ABI — `contracts/src/ZipcodeController.sol` +
  `contracts/src/ZipcodeOracleRegistry.sol` (the `uint8 reportType` + typed-payload layout, §8.0) — and the
  trigger/node-mode/consensus/report shape in `reference/cre-sdk-go/standard_tests/*/main_wasip1.go` +
  `reference/cre-templates`. Model the existing `cre/szalpha-rate/` workflow.
- **Spec §:** §8.11 (CRE build map) / §8.0 (report envelope table).
- **Done when:** `go build` → `wasip1` green; a table-driven test round-trips a sample report payload to the
  §4.4 layout the filed contract expects; a simulated trigger → node-mode → identical-consensus → report run
  executes without guessing SDK signatures.
- **Obligations:** none inbound. Establishes the report-encoding package CRE-01..05 depend on.

---

## Backlog

### CRE (Go → wasip1) — spec §8
Numbering follows the spec's own CRE map (`claude-zipcode.md` §8.11) — the spec rules intent.

| Item | What | Spec § |
|---|---|---|
| CRE-00 | Project + secrets scaffold (`cre-templates` layout, `wasip1` build, DON-only `GetSecret`) + the shared §8.0 report-encoding package the workflows reuse | §8.11 / §8.0 — **NEXT** |
| CRE-01 | Origination / draw / close / status → controller (rt 1/2/4/5,6); revaluation → registry (rt3, gas-bounded sharded); default/recovery → `DefaultCoordinator` (rt8 action family) | §8.1 / §8.4 |
| CRE-02 | Redemption-settle `cron` → `settleEpoch()` + the warehouse **REDEEM** funding call | §8.3 / §8.5 |
| CRE-03 | szipUSD share-price feeds — `NAV_LEG`(7)→`SzipNavOracle` + `LP_MARK`(7)→`SzipReservoirLpOracle` — and the xALPHA-APR feed (the 8x-02 receiver is built; the Go producer remains) | §8.6 / §8.8 |
| CRE-04 | Senior-warehouse **SUPPLY / APPROVE / REPAY** ops via the Roles adapter | §8.5 |
| CRE-05 | Engine strategy-admin **operator** orchestrator (drives 8-B5…8-B10 `onlyOperator` + main↔sidecar rotation; regime/split/cap policy) | §8.7 |

### Frontend (Vue/viem, inside `euler-lite`)
| Item | What | Spec § |
|---|---|---|
| FE-01 | Depositor / zap UX (deposit → zipUSD → szipUSD) — ticket drafted: `build/tickets/frontend/INFLOW-06-deposit-module.md` | §5 |
| FE-02 | Originator onboarding surface | §15 |
| FE-03 | Map surfaces onto `euler-lite` pages (earn / borrow / onboarding) | — |
| FE-04 | Solvency dashboard — NAV, zipUSD supply, peg, szipUSD APR, utilization, insurance coverage | §12 |

### Subgraph — deferred
Gated on item-10 freezing the §9 event ABIs. No subgraph spec exists yet; author one at the head of the
frontend track once the event ABIs are frozen.

---

## Open obligations / seams

- **item-10 deploy/wire FORK-EXECUTED 2026-06-10 (green, anvil Base-fork @ 47096000).** `script/DeployLocal.s.sol`
  (a `DeployZipcode` subclass) provisions the six `(T)` stand-ins (ZeroIRM, xALPHA MockERC20, MockEulerEarn ×2, + the
  live HYDX ICHI vault `0x07e7…`/gauge `0xAC39…` pair) and runs P0..P9 in one team-broadcast. All 8 seams hold; every
  receiver + engine-module proxy + the warehouse adapter is owned by the Timelock; the warehouse Roles/Safe by godOwner.
  **Four latent deploy-blocking bugs in the orchestrator were found + fixed** (the cost of "never executed"):
    1. `CreditWarehouseDeployer` left the adapter (a CRE ReceiverTemplate) owned by the throwaway deployer instance →
       P9's seal+transfer reverted. Fixed: new `receiverAdmin` param hands the adapter to the item-10 broadcaster.
    2. P9 re-`transferOwnership(tl)`'d engine modules already owned by `tl` (setUp `_transferOwnership(owner_=tl)`) →
       revert. Fixed: removed the redundant P9 module loop.
    3. P4 built `ZipRedemptionQueue` with `address(0)` zipUSD (the queue ctor zero-checks + reads `.decimals()`) →
       revert. Fixed: deploy the zipUSD synth at the top of P4 (EVC-only dep) before the queue.
    4. P7 built `LienXAlphaEscrow` with `address(0)` coordinator (ctor zero-checks it) → revert. Fixed: deploy the
       coordinator first (its ctor needs no escrow), then the escrow with the real coordinator.
  Still a fork-only TODO (origination-time, NOT deploy-time): the EulerEarn pool config (`createEulerEarn` +
  `setIsAllocator`/`setCurator`/`setFeeRecipient`/`setFee` + point the supply queue at the reservoir borrow vault) —
  the deploy used a `MockEulerEarn` EE pool. **Still gates a live CRE origination (CRE-01) test.** Also P5 needs an
  initial `LP_MARK` seeded before the reservoir `setLTV` (EVK calls `getQuote`); in prod that is a CRE push — the local
  harness seeds it via the owner→forwarder trick (`DeployLocal._seedLpMark`). `DeployZipcode.t.sol` 3 skips remain.
- **CRE report ABI seam.** Every CRE report payload must `abi.decode` to the §4.4 layout the filed
  `ZipcodeController` / `ZipcodeOracleRegistry` expect (reportTypes 1/2/4/5/6 → controller, 3 → registry).
- **Subgraph blocked** until item-10 freezes the §9 event signatures.

---

## Deletion triggers (when forward artifacts die)

- **8-B11 + 8-B12 land** (CRE-05 strategy robot + monitoring) → `pending-docs/{monitoring,hydrex,auto-compounder}.md`
  die, folded into those builds.
- **Real Proof / SPV / insurance integration lands** (collateral un-mocked) → `pending-docs/spv-lien-proof.md` dies.
- **Built-contract narrative still in `claude-zipcode.md` §6/§7/§11** can be pruned to `wires/` pointers later
  (only §4 has been pruned so far; left in place for now to avoid disturbing the forward narrative around it).

---

## Done

The built, fork-tested on-chain contract stack (32 product contracts + 6 scripts + 30 interfaces) is
truth-sourced and indexed in **`build/wires/COVERAGE.md`** — not re-narrated here.
