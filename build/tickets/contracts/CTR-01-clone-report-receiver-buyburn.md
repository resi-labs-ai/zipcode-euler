# CTR-01 — Clone-compatible CRE report socket on SzipBuyBurnModule (8-B14)

> Contract-track change (the on-chain stack is being EXPANDED, not just bound to). This resolves the systemic
> **operator-path-has-no-CRE-write seam** (below) for the buy-burn module first, and ships the **reusable
> clone-compatible report-receiver base** that the other ~10 operator/controller modules can later adopt.
> Spec: `claude-zipcode.md` §8.0 (report envelope) / §8.7 (operator path) / §17 (Timelock-settable wiring).
> Driver: `build/CoW.md` (the szipUSD CoW-exit workstream — the CRE bid-loop this unblocks).

## The seam this discharges (verified, not cited blind)
`cre-sdk-go`'s evm `Client` (`reference/cre-sdk-go/capabilities/blockchain/evm/client_sdk_gen.go`) exposes
**reads** (`CallContract`/`FilterLogs`/`BalanceAt`/`EstimateGas`/`GetTransactionByHash`/`GetTransactionReceipt`/
`HeaderByNumber`) and **exactly one write — `WriteReport`** (`:293`), which delivers a DON-signed `Report`
through the immutable Keystone Forwarder to a `ReceiverTemplate.onReport(metadata, report)`. There is **no
raw-transaction / keeper write primitive anywhere in the SDK** (grep-confirmed). But
`SzipBuyBurnModule.postBid(GPv2OrderInput)` / `cancelBid()` are gated `msg.sender == operator` (a hot-key EOA,
asserted `!= owner`) and the module is **not** a report receiver — so a wasip1 CRE workflow **cannot drive it**.
§8.7 hand-waves this ("the operator submits ordinary transactions … using `WriteReport`'s *sibling write
surface*"); that sibling surface does not exist. **Resolution (ratified by the user 2026-06-16): add a CRE
report socket to the module itself, ALONGSIDE the operator key (two doors, one set of guards) — NOT a new
external contract, NOT removing the operator path.**

## Deliverable
1. **`CloneReportReceiver` — a new reusable abstract base** (`contracts/src/supply/szipUSD/CloneReportReceiver.sol`),
   a **clone-compatible** re-implementation of the report-receiver surface (the constructor-based vendored
   `ReceiverTemplate` is unusable on an EIP-1167 clone — see Do NOT). It provides:
   - set-once-in-`setUp` / Timelock-settable storage: `forwarder`, `expectedWorkflowId`, `expectedAuthor`;
   - `onReport(bytes calldata metadata, bytes calldata report) external` implementing `IReceiver`
     (`reference/x402-cre-price-alerts/contracts/interfaces/IReceiver.sol`): gate `msg.sender == forwarder`
     (FAIL CLOSED on zero — see Key req 2), optional workflow-identity check via `_decodeMetadata`, then
     `_processReport(report)`;
   - `abstract function _processReport(bytes calldata report) internal virtual;`
   - owner-gated setters (`setForwarder`/`setExpectedWorkflowId`/`setExpectedAuthor`) reusing the **module's
     existing zodiac `owner`/`onlyOwner`** (NO second `Ownable`);
   - `supportsInterface` (IERC165 + IReceiver).
2. **`SzipBuyBurnModule` expanded** to `is MastercopyInitLock, CloneReportReceiver`:
   - **Refactor** the bodies of `postBid`/`cancelBid` into `internal _postBid(GPv2OrderInput memory)` /
     `internal _cancelBid()` carrying ALL existing validation; the existing `onlyOperator` `postBid`/`cancelBid`
     become thin wrappers that call them (operator path PRESERVED, byte-for-byte same guards).
   - Implement `_processReport`: decode the §8.0 envelope `abi.encode(uint8 reportType, bytes payload)`; route
     `POST_BID` → decode `(uint256 sellAmount, uint256 buyAmount, uint32 validTo)` → `_postBid(...)`;
     `CANCEL_BID` → `_cancelBid()`; any other reportType → revert `UnsupportedReportType`.
   - Declare the two reportType constants (receiver-scoped per §8.0 — values local to THIS receiver; pick + doc).

## Spec §
`claude-zipcode.md` §8.0 (the `abi.encode(uint8 reportType, bytes payload)` envelope; reportType space is
**per-receiver**, so new types here cannot collide with the controller/oracle types), §8.7 (the operator path —
this ticket records the **explicit exception**: 8-B14 becomes ALSO report-drivable), §17 (build-phase wiring is
Timelock-settable; the forwarder + workflow identity are re-pointable, immutability deferred to pre-prod).

## Binds to (verified targets)
- `IReceiver` — `reference/x402-cre-price-alerts/contracts/interfaces/IReceiver.sol`:
  `onReport(bytes calldata metadata, bytes calldata report)` + IERC165. (Inherit the interface; do NOT inherit
  the constructor-based `ReceiverTemplate.sol`.)
- `ReceiverTemplate._decodeMetadata` (same dir) — the canonical metadata layout
  (`abi.encodePacked(workflowId bytes32, workflowName bytes10, workflowOwner address)`) to REPLICATE in the
  clone-safe base (assembly decode at offsets 32/64/74). Copy the logic; cite the source.
- `zodiac-core` `Module`/`Ownable`/`FactoryFriendly`/`Initializable`
  (`reference/zodiac-core/contracts/{core/Module.sol,factory/Ownable.sol,factory/FactoryFriendly.sol}`): the
  module already inherits `owner`/`onlyOwner` + the `initializer`-guarded `setUp` via `MastercopyInitLock`.
- The as-built `SzipBuyBurnModule.sol` (truth) + `build/wires/8-B14-SzipBuyBurnModule.md`. The CoW/NAV/coverage
  surfaces (`IGPv2Settlement`, `INavOracle`, `ICoverageGate`) are UNCHANGED.
- Test patterns: `contracts/test/SzipBuyBurnModule.t.sol` (`_cloneSzipBuyBurnModule` via OZ `Clones.clone`,
  `RecordingSafe`, `MockNavOracle`).

## Starting state
- `SzipBuyBurnModule.sol` as filed (operator-only `postBid`/`cancelBid`; 10-arg `setUp`; 8 Timelock wiring
  setters; `currentBid`/`quoteMaxPrice` views). Fork-tested, SEC-reviewed.
- The CRE workspace has NO buildable module yet (only `cre/szalpha-rate/` reference + a `.gitkeep`); the wasip1
  bid-loop workflow that PRODUCES these reports is a **follow-on** (CRE-05 bid half), not this ticket.

## Do NOT
- **Do NOT** inherit the vendored `ReceiverTemplate` — it (a) extends **OpenZeppelin** `Ownable`, clashing with
  the module's zodiac `Ownable` (two `owner`s), and (b) sets its forwarder in its **constructor**, which an
  EIP-1167 clone never runs ⇒ a cloned `ReceiverTemplate` has a ZERO forwarder = `onReport` open to anyone.
- **Do NOT** modify any file under `reference/` (kept pristine) — replicate, don't edit.
- **Do NOT** remove or weaken the operator path, or any `postBid`/`cancelBid` validation (cap, coverage gate
  `covered()`, NAV-freshness leg-anchored fence, exact price bound, single-resting-bid `BidAlreadyLive`,
  `BadValidTo`, `BadDiscount`). Both doors MUST enforce the identical guards.
- **Do NOT** change the existing 10-arg `setUp` ABI (it ripples into `DeployZipcode` + every test) — wire the
  forwarder/identity via the new Timelock setters post-clone instead.
- **Do NOT** add fill-time coverage re-gating or any CoW hook (`APP_DATA == 0` is pinned — unchanged).
- **Do NOT** build the wasip1 CRE producer here (separate item) and **do NOT** ladder the bid (single-resting-bid
  invariant unchanged — driver §4).

## Key requirements
1. **Two doors, one guard set.** `postBid`/`cancelBid` (operator) and the `POST_BID`/`CANCEL_BID` report path
   MUST both route through the same `_postBid`/`_cancelBid` internals — no duplicated or divergent validation.
   A test asserts a report-driven `POST_BID` produces the EXACT same `currentUid`/`currentSellAmount`/`BidPosted`
   as the equivalent operator `postBid` (same inputs).
2. **Fail CLOSED on an unset forwarder (the clone inversion).** Unlike `ReceiverTemplate` (zero forwarder ⇒
   open), `CloneReportReceiver.onReport` MUST revert when `forwarder == address(0)` OR
   `msg.sender != forwarder`. A clone starts all-zero, so the socket is INERT until the Timelock wires the
   forwarder. Test: `onReport` on a freshly-cloned, un-wired module reverts.
3. **Workflow identity, when set.** When `expectedWorkflowId != 0` (and/or `expectedAuthor != 0`), `onReport`
   decodes metadata and rejects a mismatched id/author (mirror `ReceiverTemplate`'s checks). When unset, the
   forwarder gate alone applies. Test both.
4. **Operator path unchanged.** Every existing `SzipBuyBurnModule.t.sol` test still passes verbatim (the operator
   entrypoints keep their signatures, errors, events, gating).
5. **Timelock-settable wiring (§17).** `setForwarder`/`setExpectedWorkflowId`/`setExpectedAuthor` are
   `onlyOwner` (Timelock), emit a `WiringSet`-style event, zero-guard the forwarder setter is NOT required
   (zero is the inert state) but document it.
6. **Reusable.** `CloneReportReceiver` carries NO buy-burn-specific logic — only the report socket + identity +
   `_processReport` hook — so 8-B5…8-B10/DurationFreeze/OffRamp can adopt it later unchanged (logged as a
   follow-on obligation, NOT built here).
7. **§8.0 table updated.** Add a `SzipBuyBurnModule` row to the §8.0 per-type producer table with the two new
   reportTypes + payload ABIs.

## Done when (the gate — `forge test`, contract track)
- `forge build` green; `forge test --match-path 'contracts/test/SzipBuyBurnModule.t.sol'` green, INCLUDING new
  cases: (a) report-driven POST_BID via a mock Forwarder == operator POST_BID (req 1); (b) un-wired clone
  `onReport` reverts (req 2); (c) wrong-forwarder caller reverts; (d) workflow-id mismatch reverts, match
  passes (req 3); (e) report-driven CANCEL_BID retracts the live bid; (f) `UnsupportedReportType` reverts;
  (g) every pre-existing operator-path test still green (req 4).
- The new tests use the established harness (`_cloneSzipBuyBurnModule`, `RecordingSafe`, `MockNavOracle`) + a
  minimal mock Forwarder/metadata builder.
- No `reference/` file changed; no `setUp` ABI change; no change to CoW/NAV/coverage behavior.
- A cold-build subagent implements from this ticket with ZERO load-bearing guesses.

## Implementation pins (resolved from the critic pass — the cold-builder guesses NONE of these)
1. **Inheritance / MRO (the load-bearing one).** `abstract contract CloneReportReceiver is Ownable` where
   `Ownable` is **zodiac-core's** `reference/zodiac-core/contracts/factory/Ownable.sol` — the SAME base
   `Module` already inherits. Then `SzipBuyBurnModule is MastercopyInitLock, CloneReportReceiver`. Because both
   paths derive from the *same* zodiac `Ownable`, C3 linearization merges it to ONE `owner`/`onlyOwner` (no
   clash, no second Ownable). `CloneReportReceiver` has **no constructor** and declares
   `function _processReport(bytes calldata report) internal virtual;` (abstract).
2. **reportType numerals (receiver-scoped, §8.0).** `uint8 public constant POST_BID = 1;`
   `uint8 public constant CANCEL_BID = 2;` — these are scoped to THIS receiver's address, so they do NOT
   collide with the controller's `1`/`2` or the oracles' `7` (different receiver = different decode); document
   that in the §8.0 row. `_processReport`: `(uint8 t, bytes memory payload) = abi.decode(report,(uint8,bytes));`
   then `if (t==POST_BID) {...} else if (t==CANCEL_BID) {_cancelBid();} else revert UnsupportedReportType(t);`.
3. **Payload ABI.** POST_BID payload = `abi.encode(uint256 sellAmount, uint256 buyAmount, uint32 validTo)`,
   decoded `abi.decode(payload,(uint256,uint256,uint32))` → `_postBid(GPv2OrderInput(sellAmount,buyAmount,validTo))`.
   CANCEL_BID payload = empty (ignored). (cre-binding verified the Go `abi.Pack(uint256,uint256,uint32)` ↔
   Solidity decode round-trips bit-perfectly, incl. the `uint32`.)
4. **`_postBid`/`_cancelBid` signatures.** `function _postBid(GPv2OrderInput memory order) internal { ... }`
   carrying the ENTIRE current `postBid` body **including** the leading `currentUid.length != 0 ⇒ BidAlreadyLive`
   check (so both doors enforce single-resting-bid). `function _cancelBid() internal { ... }` carrying the
   current `cancelBid` body. Operator entrypoints become: `postBid(GPv2OrderInput calldata order) external
   onlyOperator { _postBid(order); }` (calldata→memory copy) and `cancelBid() external { if (msg.sender !=
   operator && msg.sender != owner) revert NotOperator(); _cancelBid(); }`. The report path calls `_postBid`/
   `_cancelBid` directly from `_processReport` (already gated by the forwarder check in `onReport`).
5. **`_decodeMetadata`.** Replicate `ReceiverTemplate._decodeMetadata` VERBATIM — `function _decodeMetadata(bytes
   memory metadata) internal pure returns (bytes32, bytes10, address)` with the assembly offsets 32/64/74.
   `onReport(bytes calldata metadata, ...)` passes the calldata arg to this `bytes memory` param (implicit
   copy); offsets do NOT change. Cite the source file in a comment.
6. **Fail-closed gate (in `onReport`, before identity).** `if (forwarder == address(0) || msg.sender !=
   forwarder) revert InvalidForwarder(msg.sender, forwarder);` — NOT ReceiverTemplate's "zero ⇒ open". Then,
   only if `expectedWorkflowId != 0 || expectedAuthor != 0`, decode metadata + check (revert
   `InvalidWorkflowId`/`InvalidAuthor` on mismatch). Then `_processReport(report)`.
7. **Setters + events.** `setForwarder(address)` / `setExpectedAuthor(address)` emit the EXISTING
   `event WiringSet(bytes32 indexed slot, address value)` with slots `"forwarder"` / `"expectedAuthor"`.
   `setExpectedWorkflowId(bytes32)` emits a new `event ExpectedWorkflowIdSet(bytes32 previousId, bytes32 newId)`.
   All three `onlyOwner`. No zero-guard on the forwarder (zero == inert is intended). `setUp` is UNCHANGED
   (10-arg ABI); the three receiver-wiring slots default zero and are set post-clone by the Timelock.
8. **Imports.** `IReceiver` + `IERC165` from
   `reference/x402-cre-price-alerts/contracts/interfaces/{IReceiver,IERC165}.sol` (the same ones
   `ReceiverTemplate` uses). `supportsInterface` returns true for `type(IReceiver).interfaceId` +
   `type(IERC165).interfaceId` (copy ReceiverTemplate's).
9. **Errors.** `error UnsupportedReportType(uint8 reportType);` `error InvalidForwarder(address sender, address
   expected);` `error InvalidWorkflowId(bytes32 received, bytes32 expected);` `error InvalidAuthor(address
   received, address expected);`.
10. **Test mock Forwarder = a prank.** No mock contract needed: in the test, `module.setForwarder(fwd)` then
    `vm.prank(fwd); module.onReport(meta, report);`. Build `meta = abi.encodePacked(bytes32 workflowId, bytes10
    workflowName, address workflowOwner)` and `report = abi.encode(POST_BID, abi.encode(sellAmount, buyAmount,
    validTo))` via a small test helper. The req-1 equivalence test: drive one clone via `postBid(x)` and a second
    (identically setUp) via the report path with the same `x`, assert equal `currentUid()`/`currentSellAmount()`
    and identical `BidPosted` emissions.

## Depends on / unblocks
- **Unblocks:** the CRE-05 buy-burn bid-loop (now a real wasip1 `WriteReport` workflow), and — via the reusable
  base — CRE-02 (`settleEpoch`/`claim` once the queue/off-ramp adopt the socket) and the rest of CRE-05.
- **New deploy-wiring obligation (log in PROGRESS):** `DeployZipcode` must, post-clone, call `setForwarder` +
  `setExpectedWorkflowId` on the buy-burn module (the socket is inert until then — fail-closed, safe).
