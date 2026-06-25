# X-Ray — `CloneReportReceiver.sol` (single-contract, test-connected)

> CloneReportReceiver | 57 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/CloneReportReceiver.sol`, the EIP-1167-safe CRE
report-receiver **base** for the szipUSD module fleet (the `portfolio-map.md` is the subsystem triage; this is the
first per-contract drill). An `abstract` mixin with **no dedicated test file** — exercised indirectly through the
**`CTR-01` block of `test/SzipBuyBurnModule.t.sol`** (7 tests, all passing), the one consumer that currently
inherits it.

> ⚠️ **Correction to the portfolio map.** `portfolio-map.md` lists this contract's tests as *"none"*. That is true
> only of a *dedicated* file — the report socket IS covered (fail-closed gate, wrong-caller, workflow-id, report↔
> operator equivalence, ERC165) via `SzipBuyBurnModule.t.sol::test_CTR01_*`. The remaining gap is narrower still: a
> **reusable base proven by only one consumer** has no isolated suite (the `expectedAuthor` branch — flagged in the
> first draft — was filled by `test_CTR01_workflow_author_mismatch_reverts_match_passes`).

## 1. What it is

A clone-compatible re-implementation of the Chainlink CRE Keystone report-receiver surface (`IReceiver.onReport`),
designed to be mixed into a Zodiac `Module` so a DON-signed report delivered through the immutable Keystone
Forwarder can drive the module **alongside** its operator hot-key. It carries **no business logic** — only the
report socket, the optional workflow-identity checks, and the abstract `_processReport` hook the concrete module
implements.

**The load-bearing design — the "clone inversion":** it deliberately does **not** inherit `ReceiverTemplate`, for
two reasons stated in NatSpec (`:14-20`): (a) `ReceiverTemplate` extends *OpenZeppelin* `Ownable`, which would
collide with the module's *zodiac* `Ownable` (two `owner`s); and (b) `ReceiverTemplate` sets its forwarder in its
**constructor** — which an EIP-1167 clone never runs, so a cloned `ReceiverTemplate` has a **zero** forwarder and
its "zero ⇒ open" gate leaves `onReport` callable by **anyone**. This base **inverts** that: **zero forwarder ⇒
FAIL CLOSED** (inert socket until the Timelock wires it). That inversion is the entire reason the contract exists.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `onReport(metadata, report)` | Forwarder-gated | fail-closed if `forwarder == 0` OR `msg.sender != forwarder`; optional workflow-id/author checks; then `_processReport` |
| `setForwarder(forwarder_)` | `onlyOwner` (Timelock) | **no zero-guard by design** — zero is the intended inert state |
| `setExpectedAuthor(author_)` | `onlyOwner` | zero ⇒ check off |
| `setExpectedWorkflowId(id_)` | `onlyOwner` | zero ⇒ check off |
| `_processReport(report)` | `internal virtual` | abstract — the concrete module routes the §8.0 envelope |
| `supportsInterface(id)` | `public pure` | advertises `IReceiver` + `IERC165` |
| `_decodeMetadata(metadata)` | `internal pure` | assembly, replicated verbatim from `ReceiverTemplate` |

No permissionless surface (the report path is forwarder-gated; setters are `onlyOwner`). No custody, no state beyond
three wiring slots.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **fail-closed forwarder gate (the clone inversion)** — a fresh/zero-forwarder clone is inert; only the wired forwarder can call `onReport` | Yes | **`test_CTR01_unwired_clone_onReport_reverts`** (zero forwarder → `InvalidForwarder(caller, 0)`), **`test_CTR01_wrong_forwarder_caller_reverts`** (wrong caller → `InvalidForwarder`) |
| I-2 | **optional workflow-identity gate** — when configured, a mismatched workflow-id/author is rejected; when unset, the forwarder gate alone applies | Yes | **`test_CTR01_workflow_id_mismatch_reverts_match_passes`** (id mismatch reverts, match passes), **`test_CTR01_workflow_author_mismatch_reverts_match_passes`** (author mismatch → `InvalidAuthor`, match passes); the "both unset" path is `test_CTR01_report_postBid_*` (all-zero meta) |
| I-3 | **two doors, one guard set** — the report path dispatches to the SAME `_processReport` internals as the operator path, with identical effect | Yes | **`test_CTR01_report_postBid_equals_operator_postBid`** (report uid/sellAmount == operator uid/sellAmount, exact), **`test_CTR01_report_cancelBid_retracts_live_bid`** |
| I-4 | **clone-safe** — no constructor; all wiring is set-once via Timelock setters; a fresh clone starts all-zero (inert) | Yes (structural) | the unwired-clone test relies on exactly this (`forwarder()==0` on a fresh clone); the base has no constructor |
| I-5 | ERC165 advertises `IReceiver` + `IERC165` and nothing spurious | Yes | **`test_CTR01_supportsInterface`** (both true; `0xffffffff` false) |
| X-1 | C3/MRO merges the zodiac `Ownable` to ONE `owner`/`onlyOwner` (no second Ownable from the receiver) | Yes (structural) | compiles + the module's `onlyOwner` gate works (`test_operator_cannot_redirect_safe` on the shared owner); the receiver reuses that owner |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `InvalidForwarder` (unset forwarder, fail closed) | `test_CTR01_unwired_clone_onReport_reverts` |
| `InvalidForwarder` (wrong caller) | `test_CTR01_wrong_forwarder_caller_reverts` |
| `InvalidWorkflowId` | `test_CTR01_workflow_id_mismatch_reverts_match_passes` |
| `InvalidAuthor` | `test_CTR01_workflow_author_mismatch_reverts_match_passes` |
| `UnsupportedReportType` (dispatched in the module's `_processReport`, base's error type) | `test_CTR01_unsupported_report_type_reverts` |
| `onlyOwner` on `setForwarder`/`setExpectedAuthor`/`setExpectedWorkflowId` | **not directly tested** — the shared zodiac `Ownable` gate is proven on `setAvatar`/`setTarget` (`test_operator_cannot_redirect_safe`); the receiver setters reuse the identical modifier |

## 5. Attack surfaces

- **The clone inversion is the whole point — and it's tested (I-1)** — the contract exists because a cloned
  `ReceiverTemplate` would be world-callable (zero forwarder ⇒ open). This base makes zero ⇒ inert, and
  `test_CTR01_unwired_clone_onReport_reverts` proves a fresh clone rejects `onReport` from anyone until the Timelock
  wires the forwarder. This is the strongest evidence for the contract's reason to exist.
- **`expectedAuthor` / `InvalidAuthor` — now tested (was the one functional gap)** — `onReport:71-73` rejects a
  mismatched workflow *author*; `test_CTR01_workflow_author_mismatch_reverts_match_passes` now configures an author,
  feeds a wrong `workflowOwner` in metadata (→ `InvalidAuthor`), then the matching author (→ posts). The symmetric
  twin of the workflow-id test; both identity branches are covered.
- **No dedicated test file for a REUSABLE base** — NatSpec (`:27-28`) states this base is meant to be adopted by the
  other szipUSD operator/controller modules **unchanged**. Today its only proof is one consumer's (`SzipBuyBurnModule`)
  CTR-01 block. If a second module adopts it, the base's correctness should not depend on re-running buy-burn's suite.
  Worth a small dedicated `CloneReportReceiver.t.sol` against a minimal concrete harness.
- **`_decodeMetadata` is hand-rolled assembly replicated verbatim from `ReceiverTemplate` (`:116-127`)** — only
  reached when an identity check is configured. It reads fixed calldata offsets with **no length validation**; a
  short/malformed metadata blob would read zero/garbage offsets rather than revert cleanly. The workflow-id match
  test (d) exercises the happy path; a malformed-metadata case is uncovered. Low severity (a wrong decode just
  mismatches → revert), but a transcription/offset bug here would silently weaken the identity gate.
- **`setForwarder` has no zero-guard — by design** (`:85-86`) — zero is the deliberate "socket off" state, fail-closed
  by `onReport`. Correct, not a bug; called out so a reader doesn't "fix" it.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Dedicated unit | 0 | **no `CloneReportReceiver.t.sol`** — all coverage is incidental through `SzipBuyBurnModule` |
| Inherited-via-consumer (CTR-01 block) | 8 | fail-closed gate (×2), report↔operator equivalence, report cancel, workflow-id gate, **workflow-author gate**, unsupported-type, supportsInterface |
| Stateless fuzz / invariant | 0 | a deterministic gate/dispatch contract — low fuzz value |

All **8 CTR-01 tests pass** (`forge test --match-test test_CTR01` → 8 passed, 0 failed). The decisive property (the
fail-closed clone inversion) and the report↔operator equivalence are both directly asserted. Coverage %
uninstrumentable (project-wide stack-too-deep). The git churn is low (1 mod) — this base has been stable since it
was split out.

## X-Ray Verdict

**ADEQUATE** — a small (57 nSLOC), well-documented infrastructure base whose **decisive security property (the
fail-closed clone inversion that fixes `ReceiverTemplate`'s world-callable-clone footgun) is directly tested**, and
whose report path is proven byte-identical in effect to the operator path. Both workflow-identity branches (id +
author) are now covered. Held at ADEQUATE (not higher) by two real, narrow gaps: (1) **no dedicated test file** for a
base explicitly designed for reuse across the fleet — proven by one consumer only; (2) the three receiver setters'
`onlyOwner` gating is proven via the shared zodiac `Ownable` on sibling setters (and confirmed present by reading
`:87,93,99`), not by a direct test. Neither is a correctness defect in the read code — they are coverage gaps on a
small, currently-stable contract.

**Structural facts:**
1. 57 nSLOC; `abstract` mixin; no constructor (clone-safe); no custody; three Timelock wiring slots.
2. Inverts `ReceiverTemplate`'s "zero forwarder ⇒ open" to "zero ⇒ fail-closed/inert" — the reason it exists; proven by `test_CTR01_unwired_clone_onReport_reverts`.
3. Optional workflow-id + author identity checks (both now tested); `_processReport` is the abstract dispatch hook.
4. Tests: 0 dedicated; 8 via `SzipBuyBurnModule.t.sol` CTR-01 (the only current consumer); 0 fuzz/invariant.
5. Reusable by design (NatSpec `:27`) but proven by one consumer — the chief remaining follow-up is a dedicated suite, due when a second module adopts the base.
