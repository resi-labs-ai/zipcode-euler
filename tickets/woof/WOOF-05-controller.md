# WOOF-05 — `ZipcodeController` (§4.4)

> **MATERIALIZED + BUILDS GREEN 2026-06-06 (keep-the-build doctrine).** The controller is now real on disk:
> `contracts/src/ZipcodeController.sol` + `contracts/test/ZipcodeController.t.sol`. `forge build` green (solc
> 0.8.24); **26/26 new tests pass on a live Base-mainnet fork** (102/102 total across all suites, no regression;
> independently re-run by the superintendent). The materialized build confirmed this ticket is a true
> **zero-spec-guess keepsake** — every external signature it calls was verified against the real on-disk
> WOOF-01/02/03/04 source (`openLine`/`setLineLimits`/`fund`/`draw`/`observeDebt`/`closeLine`, `create`/
> `computeAddress`, `seedPrice`, `approve`/`burn`, `ReceiverTemplate` non-virtual setters + conditional identity
> gate) — **all match; no contradiction, wrong address, or wrong signature surfaced.** The controller imports ONLY
> `ReceiverTemplate` + `IZipcodeVenue` (+ three inline local interfaces); it touches **NO EVC type** (the central
> subtraction, confirmed). Error selectors verified live via `cast`: `E_AccountLiquidity()` `0x34373fbc`,
> `E_BorrowCapExceeded()` `0x6ef90ef1`, `NotAuthorizedOperator()` `0x3d9adf1c` (the WOOF-03 hook). The re-author
> proof holds: a `reportType 1` origination borrow succeeds with NO controller operator-wiring
> (`isAccountOperatorAuthorized(borrowAccount, adapter)==true` & `(…, controller)==false`). EVK/EVC/EulerRouter
> live; EulerEarn mocked (0.8.26, recording mock that deposits real cash on `reallocate`). See
> `reports/WOOF-05-report.md`. **Code KEPT, not discarded.**

> **RE-AUTHORED 2026-06-05 (borrower-model rework, Step 2c) — supersedes the sub-account / `wireVenueOperator`
> version.** Under the fresh-per-line-borrower model (§4.3/§4.4/§4.7, Step 1; WOOF-03/WOOF-04 already
> re-authored) each line's borrow account is a **fresh per-line EVC account** owned by a per-line `LineAccount`
> (CREATE2-deployed by the venue adapter inside `openLine`), and **the adapter** is wired as that account's EVC
> operator and drives the borrow. **The controller no longer touches EVC at all.** So this re-author is mostly a
> **SUBTRACTION** — the controller gets simpler. It LOSES:
> - **`wireVenueOperator(address evc)` — GONE.** The per-line operator grant is now issued by the adapter's
>   `LineAccount` at origination (`EVC.setAccountOperator(borrowAccount, adapter, true)` inside `openLine`, §4.7),
>   not by the controller. The controller never calls `setOperator`/`setAccountOperator`.
> - **The EVC handle entirely — GONE.** The controller takes **no EVC** (it was only ever a parameter to
>   `wireVenueOperator`, never a ctor immutable). The ctor stays `ZipcodeController(forwarder, venue, lienFactory,
>   oracleRegistry, erebor)` (5 args, **no EVC**).
> - **The blanket-`setOperator` / `~uint256(1)` / sub-account / F-1 / F-2 reasoning — all GONE.**
>
> **Everything else is UNCHANGED** because the controller drives the venue purely through `IZipcodeVenue` (which
> is venue-neutral, UNCHANGED): the `onReport` Forwarder+identity gate (immutable via renounce), `_processReport`
> envelope-decode + dispatch (1 origination / 2 draw / 4 close / 5,6 status markers / 3 rejected / else
> `UnsupportedReportType`), the origination atomic batch `create → openLine → seed → setLineLimits → fund → draw`
> (the adapter now also deploys the `LineAccount` inside `openLine`, transparent to the controller), the close
> branch (`observeDebt==0 → closeLine → burn(1e18)`), the lien custody (`approve(venue, 1e18)`, full-`1e18`
> guard), the seed via `registry.seedPrice` on the openLine-returned `oracleKey`, and the **dormant-identity-gate
> (F-3)** awareness.

**Deliverable**
`contracts/src/ZipcodeController.sol` — `contract ZipcodeController is ReceiverTemplate`. The single trusted
on-chain identity and the **portable core's** orchestrator: the **CRE receiver** (inbound gated on an
**immutable** Forwarder), the **report decode + per-`reportType` decision logic**, and the **lien-token
mint/burn authority**. It is the on-chain **borrower of record** (the abstract authority that drives every
draw — the *mechanical* EVC borrow-on-behalf is performed by the adapter as the line's EVC operator, §4.4/§4.7;
the controller itself never touches EVC). Every on-chain **venue effect** — open a line, set LTV/caps, fund,
draw, observe debt, close — it drives through the **`IZipcodeVenue`** adapter (§4.7), **never** by calling
EVK/EulerEarn/EVC directly.

(Internal plumbing — **build-only, no interface/frontend ticket**. The controller is driven by the CRE DON via
`onReport`, not by users. PROGRESS item 6 = build only.)

**Spec §**
`claude-zipcode.md` §4.4 (the controller + report ABI + branches a–e). Cross:
- §4.1 (the controller seeds `cache[LIEN_i]` via `registry.seedPrice` inside its atomic origination batch;
  revaluation = reportType 3 goes **direct to the registry**, never through the controller).
- §4.2 (`LienTokenFactory.create(lienId)` caller-bound → the controller is the canonical caller; `LIEN_i.burn`
  is controller-only; the controller owns the burn-custody sequencing).
- §4.7 (`IZipcodeVenue` — the controller calls `openLine → setLineLimits → fund → draw` at origination,
  `observeDebt`/`closeLine` at close; `liquidate` is a defensive stub the controller **never** calls; **the
  adapter deploys the per-line `LineAccount` + issues the EVC operator grant inside `openLine`** — transparent
  to the controller, which sees only the venue-neutral seam).
- §4.4 "Borrower-of-record mechanism" (`:384-417`): the borrower of record is a **fresh per-line EVC account**
  owned by a per-line `LineAccount`, with the **adapter** (the `EVC.call` `msg.sender` on the draw path) wired
  as that account's EVC operator. **The controller drives the borrow only through `IZipcodeVenue.draw`** — it
  takes **no EVC handle** and issues **no operator grant** (§4.4 ctor note: "the controller needs no EVC handle
  at all").
- §9 (deploy/wiring order; identity-first-then-renounce; **"No controller-level operator-wiring step is
  needed"** — the per-line grant is the adapter's `LineAccount` job inside `openLine`, §9 `:915-920`) and §13
  (trust: immutable Forwarder via renounce).
- `audit/2.md` **L4** (origination), **L7/L8** (repay → close → `LienReleased`), **N2/N2b** (Forwarder/identity
  reverts), **N6** (over-LTV origination reverts in the borrow step), **N7** (post-renounce setter reverts).
- `audit/3-results.md` rows **18** (`LIEN_i.mint/burn` controller-only), **19** (`create` caller-bound), **20**
  (`onReport` Forwarder-only + identity), **F1** (renounce ordering).
Locked §17: **event-driven Proof valuation** (the controller never reads a heartbeat — it only seeds/re-anchors
the mark from the report's `equityMark`); **no on-chain economic liquidation** (`liquidate` defensive only,
§4.4e); **venue-agnostic** (every venue effect via `IZipcodeVenue`; **no Euler/EVC type touches the core path at
all** — the one EVC-operator wiring entrypoint of the old version is **removed**); **fresh per-line account +
adapter-as-operator → unbounded disposable lines** (the resolved 2026-06-05 borrower-of-record decision; the §17
supply-side yield/xALPHA/szipUSD decisions are LOCKED — do **NOT** touch them).

**Discharges inbound obligations (PROGRESS → rows owed by item 6):**
1. **(WOOF-04 obligation 1a — DISCHARGED-AT-ORIGIN BY WOOF-04, NOT BY THE CONTROLLER)** the per-line EVC operator
   grant is issued **inside `venue.openLine`** by the adapter's `LineAccount`
   (`EVC.setAccountOperator(borrowAccount, adapter, true)`, §4.7) — **not** by the controller. The controller has
   **no `wireVenueOperator`, no blanket `setOperator`, and no EVC handle**. There is nothing for the controller to
   do here; the obligation is satisfied by WOOF-04's `LineAccount` at origination. (This row's old "the controller
   authorizes the adapter as operator" framing is **retired** by the borrower-model rework.) Mark
   `DISCHARGED-AT-ORIGIN (by WOOF-04; controller has no operator step)`.
2. **(WOOF-04 obligation 1b)** seed `registry.seedPrice(oracleKey, equityMark)` using the `oracleKey`
   **returned by** `venue.openLine` (= `LIEN_i`). Realized in the origination branch. Mark `DISCHARGED`.
3. **(WOOF-04 obligation 1c)** own the lien↔escrow custody: hold the `1e18` from `create`, `approve` the adapter
   for the escrow deposit (inside the same `onReport` call before `openLine`), and at close reclaim it (via
   `venue.closeLine`) before `burn`. **Pass `collateralAmount == 1e18` (the FULL lien)** to `openLine` — the
   controller is the **primary guarantor** of the full-lien invariant (the venue asserts `== 1e18` as a
   backstop). Mark `DISCHARGED`.
4. **(WOOF-02 obligation 3)** the origination branch calls `registry.seedPrice(LIEN_i, equityMark)` **inside**
   its atomic batch, ordered `create → openLine → seed → setLineLimits → fund → draw`; **batch-atomicity is this
   ticket's test** (an over-LTV draw rolls the whole branch back — no orphan lien/market). Mark `DISCHARGED`.
5. **(WOOF-01 obligation 1)** at close, reclaim the `1e18` from the escrow **before** `burn` (else
   `ERC20InsufficientBalance`). Realized: `venue.closeLine` redeems the escrow to the controller, then
   `LIEN_i.burn(1e18)`. Mark `DISCHARGED`.

---

## Design (the portable-core orchestrator)

**Shape.** `is ReceiverTemplate` **only** (it is not an oracle — no `BaseAdapter`). It implements the one
`internal virtual` hook `_processReport`; everything else (`onReport` Forwarder+identity gate, `Ownable`,
`setForwarderAddress`/`setExpected*` setters, `getForwarderAddress`/`getExpectedWorkflowId`,
`supportsInterface`) comes concrete from `ReceiverTemplate`. **Do NOT override `onReport` or
`setForwarderAddress`** — both are **non-virtual** (verified, WOOF-02); Forwarder immutability is sealed by the
S11 `renounceOwnership` (§4.4 corrected wording — see Key requirements / spec-fidelity carry).

**Constructor (5 immutables — NO EVC).** `ZipcodeController(address forwarder, address venue, address
lienFactory, address oracleRegistry, address erebor) ReceiverTemplate(forwarder)` — store `venue`,
`lienFactory`, `oracleRegistry`, `erebor` as immutables. `ReceiverTemplate(forwarder)` sets `Ownable` owner =
`msg.sender` (`CONTROLLER_OWNER`) and stores the immutable-by-renounce Forwarder. **`erebor` is the 5th ctor
arg** (the controller must pass Erebor to `venue.draw`, which validates `receiver == venue.erebor` — WOOF-04
security F2). The controller **does NOT take the EVC** — it is venue-specific and (under the per-line borrower
model) the controller never calls EVC, so there is no EVC parameter, no EVC immutable, and **no EVC import in
the contract**. (This is the central subtraction of the re-author: the prior `wireVenueOperator(evc)` entrypoint
and its `IEVC` import are **removed**.)

**Per-lien state.** `mapping(bytes32 => LienRecord) public liens; struct LienRecord { address lien; address
lineRef; bool open; }` — `lien = LIEN_i` (the collateral token / oracle key), `lineRef` = the opaque venue line
handle returned by `openLine`. Set at origination, read at draw/close. (The controller stores **no**
`borrowAccount`/`subId` — the per-line borrow account is the adapter's internal artifact behind the
`IZipcodeVenue` seam; the controller never observes it.)

**Report ABI (shared envelope, §4.4).** `_processReport(bytes calldata report)` decodes the envelope
`(uint8 reportType, bytes payload)` then dispatches:

| `reportType` | Branch | Payload | M1 action |
|---|---|---|---|
| `1` Origination | (a) | `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV, uint256 drawAmount, uint256 cap)` | full: create → openLine → seed → setLineLimits → fund → draw |
| `2` Draw | (a′) | `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)` | re-anchor seed → fund → draw on the open line |
| `3` Revaluation | (b) | — | **NOT handled here** — `reportType 3` is delivered **direct to the registry** (§4.1); the controller **rejects** it (`UnsupportedReportType`) |
| `4` Close | (c) | `(bytes32 lienId)` | observeDebt == 0 → closeLine → burn → `LienReleased` |
| `5` Default | (d) | `(bytes32 lienId, uint8 status)` | **M1: status-marker only** — `emit LienStatusUpdated(lienId, status)`; no markdown/escrow (DefaultCoordinator is M2, §4.6) |
| `6` Liquidation | (e) | `(bytes32 lienId, uint8 status)` | **M1: status-marker only** — `emit LienStatusUpdated(lienId, status)`; **never** calls `venue.liquidate` (§4.4e — no on-chain economic liquidation) |
| else | — | — | `revert UnsupportedReportType(reportType)` (fail closed) |

Branches 5/6 are status-event markers in M1 by design (see Design decision D3): the loss-side machinery
(`DefaultCoordinator`/`LienXAlphaEscrow`, markdown, Duration Bond, xALPHA) is **M2** (§4.6/§11), and §4.4e forbids
the controller from ever calling liquidation. They are present so the dispatcher honors the locked report ABI
and fails closed on anything else; **only 1 and 4 are exercised by `audit/2.md` Phase L** (2/5/6 are
ABI-complete but M1-untested by the acceptance harness — flagged for the superintendent).

### Origination branch (a) — the atomic batch (the heart)
In one `onReport` call (Solidity-atomic — any revert rolls back the whole branch incl. the CREATE2 deploys, so
there is **no orphan lien/market**; **the controller needs NO explicit EVC batch** — the adapter's `draw` wraps
its own borrow in an internal `EVC.batch`, behind the seam):
1. `if (liens[lienId].lien != address(0)) revert LienExists(lienId);` (clean dup guard; the factory also
   reverts `FailedDeployment` on a re-used slot).
2. **Precompute + assert (L4 step 3):** `address predicted = ILienTokenFactory(lienFactory).computeAddress(lienId,
   address(this));` then `address lien = ILienTokenFactory(lienFactory).create(lienId);`
   `if (lien != predicted) revert PrecomputeMismatch();` (`create` is called **by the controller**, so the
   CREATE2 address binds to `address(this)` and equals `computeAddress(lienId, address(this))`, §4.2). After
   this the controller holds `1e18` `LIEN_i` (minted to it at construction). **`PrecomputeMismatch` is a
   DEFENSIVE assert, unreachable on any real input** (both addresses derive from the same `(lienId,
   address(this))` via the same CREATE2 formula → equal by construction; same class as WOOF-04's `WireMismatch`).
   Do **not** claim a normal origination "proves" it; cover it (if at all) via a `vm.mockCall` on
   `computeAddress` returning a wrong address, or label it explicitly unreachable-by-design.
3. **Custody approve (obligation 1c):** `ILienToken(lien).approve(venue, 1e18);` so `openLine` can
   `transferFrom` the full lien into the escrow vault (the adapter deposits it into `COLLAT` for the line's
   `borrowAccount`, §4.7). (Exact `1e18`, not `max` — `openLine` consumes exactly `1e18`, leaving zero standing
   allowance, security F-7.)
4. **Open the line (full lien):** `(address lineRef, address oracleKey) = IZipcodeVenue(venue).openLine(lienId,
   lien, 1e18);` — pass `1e18` (the FULL lien; the venue backstops `!= 1e18 → InvalidCollateralAmount`, but the
   controller is the primary guarantor, obligation 1c). `oracleKey == lien` by construction. **The adapter, inside
   `openLine`, CREATE2-deploys the per-line `LineAccount` and issues the EVC operator grant — transparent to the
   controller** (it sees only `(lineRef, oracleKey)`; it does not know or store the `LineAccount`/`borrowAccount`).
5. **Seed the Proof-of-Value mark (obligation 1b/4 + WOOF-02 obl. 3):** `IZipcodeOracleRegistry(oracleRegistry)
   .seedPrice(oracleKey, equityMark);` — controller-gated; writes `cache[LIEN_i] = (equityMark, block.timestamp)`.
   Ordered **after** `openLine` (the per-line router resolves `escrow → LIEN_i → registry`; the cache write is
   independent of the router) and **before** `draw` (the borrow's account-status check reads the mark via the
   router — an un-seeded key reverts `PriceOracle_NotSupported`).
6. **Set limits:** `IZipcodeVenue(venue).setLineLimits(lineRef, borrowLTV, liqLTV, cap);` (`borrowLTV`/`liqLTV`
   are **1e4 scale** `uint16`, carried in the report; `cap` is raw token units the venue encodes to AmountCap).
7. **Fund + draw:** `IZipcodeVenue(venue).fund(lineRef, drawAmount);` then
   `IZipcodeVenue(venue).draw(lineRef, drawAmount, erebor);`. **The controller does NOT pre-check the LTV
   bound** — `drawAmount` is bounded **on-chain** by `borrowLTV × equityMark` + the line `cap` via the EVK
   account-status check the adapter's borrow triggers (§4.4a / `audit/2.md` N6); a bad report reverts in the
   borrow step (and rolls the whole branch back). **The live borrow works because the adapter is the line's EVC
   operator** (granted by the `LineAccount` at step 4's `openLine`) — there is no controller operator-wiring
   precondition.
8. `liens[lienId] = LienRecord({lien: lien, lineRef: lineRef, open: true});`
   `emit LienOriginated(lienId, lien, lineRef, proofRef, equityMark, drawAmount);`.

### Draw branch (a′) — additional draw on an open line
`(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)`:
- `LienRecord storage r = liens[lienId]; if (!r.open) revert UnknownLien(lienId);`
- **Re-anchor:** `registry.seedPrice(r.lien, equityMark);` (a fresh Proof-of-Value mark — §4.4a′; this also
  refreshes the cache timestamp, so a line that outlived its validity window can draw again, §4.1). The
  delinquency re-check is **off-chain** (the CRE only emits the report if the line is current); on-chain the
  LTV bound is enforced by the borrow as in (a).
- `venue.fund(r.lineRef, drawAmount); venue.draw(r.lineRef, drawAmount, erebor);`
- `emit LienDrawn(lienId, equityMark, drawAmount);`. (No `cap` field in the type-2 payload → a later draw stays
  within the origination `cap`; it does not re-set limits.)

### Close branch (c) — release on zero debt (§4.4c)
`(bytes32 lienId)`:
- `LienRecord storage r = liens[lienId]; if (!r.open) revert UnknownLien(lienId);`
- `if (IZipcodeVenue(venue).observeDebt(r.lineRef) != 0) revert DebtOutstanding();` (repay is permissionless,
  §9/audit L7 — the controller only confirms zero).
- `IZipcodeVenue(venue).closeLine(r.lineRef);` — the adapter redeems the escrow lien back to the **controller**
  via the operator-routed `EVC.call` (WOOF-04 `closeLine`), so the controller now holds `1e18` `LIEN_i`.
- `ILienToken(r.lien).burn(1e18);` (controller mint/burn authority; reclaim-before-burn satisfies WOOF-01
  obligation 1).
- `r.open = false; emit LienReleased(lienId);` (signals off-chain SPV release).

### (No operator-wiring section — REMOVED)
The prior `wireVenueOperator(address evc)` entrypoint and its `IEVC.setOperator(prefix, venue, ~uint256(1))`
blanket grant are **deleted**. The per-line operator grant is now issued by the adapter's per-line `LineAccount`
inside `venue.openLine` (`EVC.setAccountOperator(borrowAccount, adapter, true)`, §4.7), so the controller has no
EVC role, no `onlyOwner` venue-wiring seam, and no EVC import. (The only `onlyOwner` surface the controller
exposes is the inherited `ReceiverTemplate` identity setters — `setForwarderAddress`/`setExpected*` — all frozen
by the S11 renounce.)

---

**Model from (verified against `reference/` + the filed WOOF tickets)**
- **`is ReceiverTemplate`** — `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol`
  (**inherit**, exactly as WOOF-02). Verified: `abstract contract ReceiverTemplate is IReceiver, Ownable`
  (`:12`); ctor `constructor(address _forwarderAddress) Ownable(msg.sender)` reverts on `address(0)` (`:42-50`);
  `onReport` (`:78`, **non-virtual**) gates `msg.sender == s_forwarderAddress` (`:83-85`) + the **conditional**
  workflow-identity check (`:88-117`, active **only when** `setExpectedAuthor`/`setExpectedWorkflowId`/
  `setExpectedWorkflowName` are non-zero) then calls the one `internal virtual` hook `_processReport(report)`
  (`:119`, `:232-234`). `setForwarderAddress` (`:127`) and `onReport` are **NOT `virtual`** → **cannot be
  overridden** (do NOT try, §4.4 corrected). `renounceOwnership` (inherited OZ `Ownable`) is the immutability
  lock. Import alias requires the `x402-cre-price-alerts/` remap (Starting state). **Hard dep:** the
  `@openzeppelin/contracts/` remap must stay on euler-vault-kit's OZ v5 (WOOF-02 verified — v4.9.6 won't compile
  `Ownable(msg.sender)`). **The controller needs NO EVC import** (the EVC-operator entrypoint is removed).
- **`IZipcodeVenue`** — `contracts/src/venue/IZipcodeVenue.sol` (WOOF-04 **re-authored**, the filed keepsake;
  the interface is **UNCHANGED** by the borrower-model rework — no Euler/EVC types cross it). Verified signatures
  the controller calls: `openLine(bytes32 lienId, address lienToken, uint256 collateralAmount) returns (address
  lineRef, address oracleKey)`; `setLineLimits(address lineRef, uint16 borrowLTV, uint16 liqLTV, uint256 cap)`;
  `fund(address lineRef, uint256 amount)`; `draw(address lineRef, uint256 amount, address receiver)`;
  `observeDebt(address lineRef) view returns (uint256)`; `closeLine(address lineRef)`; `liquidate(address
  lineRef)` (defensive stub — never called). `import {IZipcodeVenue} from "./venue/IZipcodeVenue.sol";`. **No
  Euler types cross it** (so the controller's venue calls carry only `bytes32`/`address`/`uint*`). The
  adapter's internal `LineAccount` deploy + operator grant happen **inside** `openLine` behind this seam —
  invisible to the controller.
- **Local interfaces (declare inline in the controller — avoids the OZ-vs-forge-std `IERC20` import choice the
  junior critic flagged; do NOT re-implement the contracts):**
  - `interface ILienTokenFactory { function create(bytes32 lienId) external returns (address); function
    computeAddress(bytes32 lienId, address controller) external view returns (address); }` — verified against
    `contracts/src/LienTokenFactory.sol` (WOOF-01): `create` caller-bound (`controller := msg.sender`),
    `computeAddress` two-arg (the controller passes `address(this)`).
  - `interface ILienToken { function approve(address spender, uint256 amount) external returns (bool); function
    burn(uint256 amount) external; }` — covers BOTH faces the controller needs on the lien token (the WOOF-01
    `LienCollateralToken` is a plain OZ `ERC20` with a controller-only `burn`); declaring one local interface
    sidesteps importing OZ `IERC20`. `burn(1e18)` burns from the controller's own balance (controller-only).
  - `interface IZipcodeOracleRegistry { function seedPrice(address lien, uint256 price) external; }` — verified
    against `contracts/src/ZipcodeOracleRegistry.sol` (WOOF-02): gated `msg.sender == controller`; writes
    `cache[lien] = (price, block.timestamp)` with the price/decimals guards.
- **NO `IEVC` / EVC import.** (The old `wireVenueOperator` Model-from block — `IEVC.setOperator` /
  `getAddressPrefix` / `isAccountOperatorAuthorized` — is **removed** with the entrypoint. The controller never
  references the EVC; the operator grant + its on-chain verification live entirely in WOOF-04's `LineAccount` and
  the WOOF-03 hook.)
- **NOT** `BaseAdapter`/`IPriceOracle` (the controller is not an oracle). **NOT** any direct EVK/EulerEarn/EVC
  call (every venue effect via `IZipcodeVenue`, §4.4/§4.7). **NOT** `require(cond, CustomError())` (solc ≥ 0.8.26;
  WOOF-00 pins 0.8.24) — use `if (!cond) revert CustomError();`.

**Starting state**
- WOOF-00 done; `contracts/src/ZipcodeController.sol` is an empty stub with the WOOF-00-pinned header
  (`// SPDX-License-Identifier: GPL-2.0-or-later` then `pragma solidity 0.8.24;` — keep both exactly).
  `contracts/test/ZipcodeController.t.sol` carries the same header.
- **Remap:** add the `x402-cre-price-alerts/=../reference/x402-cre-price-alerts/contracts/` line if not already
  present (WOOF-02 added it; the cold-build starts from WOOF-00's base remaps + the filed deps' remaps — re-add
  if absent; **no comment lines**). `evk/`, `evc/`, `euler-price-oracle/`, `euler-earn/`,
  `@openzeppelin/contracts/`, `forge-std/`, `@solady/` all resolve via WOOF-00 + WOOF-02's set. (The controller
  itself imports only `ReceiverTemplate` + `IZipcodeVenue` + its local interfaces — no `evc/`.)
- WOOF-01/02/**03 (re-authored)**/**04 (re-authored, incl. `LineAccount`)** are **filed keepsakes**; the
  cold-build rebuilds them from their tickets into `contracts/src/` (factory/token, registry, operator-auth
  gating hook, `IZipcodeVenue` + `EulerVenueAdapter` + `LineAccount`) so the real controller compiles +
  integrates against them. The controller is the **unit under test** (no mock controller).

**Do NOT**
- **Do NOT override `onReport` or `setForwarderAddress`** — both non-virtual (verified); an override fails to
  compile. Forwarder immutability is the S11 `renounceOwnership`, **not** an override (§4.4 corrected wording).
- **Do NOT add `wireVenueOperator`, any `setOperator`/`setAccountOperator` call, or an EVC parameter/immutable/
  import.** The operator grant is the adapter's `LineAccount` job inside `openLine` (§4.7); the controller has no
  EVC role under the per-line borrower model (§4.4/§9). This is the central subtraction of the re-author — do not
  re-add it.
- **Do NOT call EVK/EulerEarn/EVC directly anywhere.** Every venue effect goes through `IZipcodeVenue`
  (§4.4/§4.7). **The controller touches NO Euler/EVC type at all** (the prior single EVC entrypoint is removed).
- **Do NOT handle `reportType == 3` (Revaluation).** It is delivered **direct to the registry** (§4.1/§4.4b);
  the controller rejects it (`UnsupportedReportType`). Do not add a revaluation branch or a heartbeat — the
  mark is event-driven Proof (§17 locked).
- **Do NOT call `venue.liquidate`** anywhere (§4.4e — no on-chain economic liquidation; `liquidate` is the
  hook's defensive surface, never a controller mechanism). Branch (e) emits a status marker only.
- **Do NOT pre-validate the LTV/draw bound on-chain.** `drawAmount` is bounded by the EVK account-status check
  the adapter's borrow triggers (§4.4a / N6); duplicating it in the controller is redundant and risks drift.
- **Do NOT apply markdown / drive loss machinery in branch (d).** Markdown comes from the deviation Proof
  re-mark (revaluation → registry) and is realized by `DefaultCoordinator` (M2, §4.6/§11). The M1 controller
  only emits the status marker.
- **Do NOT add an admin/`Ownable` surface beyond the inherited `ReceiverTemplate`/`Ownable`** (the identity
  setters only, all `onlyOwner`, all frozen by the S11 renounce). **No `wireVenueOperator` seam** (removed). No
  mutable venue/registry/factory pointer (all immutable). No pause/upgrade.
- **Do NOT seed/re-anchor outside the controller-gated `seedPrice`** or write the cache any other way. The
  controller is the **only** `seedPrice` caller (WOOF-02 set-once `controller`).
- **Do NOT pass a `receiver` other than the immutable `erebor` to `venue.draw`** (the venue reverts
  `BadReceiver` otherwise — defense-in-depth, WOOF-04 security F2).
- **Do NOT add a `nonReentrant` guard or assume one is needed — but understand WHY it is safe (security F-10).**
  `_processReport` makes a chain of external calls (`create` deploys a contract; `openLine`/`seedPrice`/
  `setLineLimits`/`fund`/`draw` are external), and the `liens[lienId]` write is **last** in origination. Reentry
  into `onReport` is structurally impossible because `onReport` is **Forwarder-gated** (`msg.sender ==
  s_forwarderAddress`) and none of the callees (lien token, venue, registry, and — behind the venue seam — the
  EVK vaults/EVC/`LineAccount`) is the Forwarder — so a callee cannot re-enter. This safety rests on (i) the
  Forwarder gate and (ii) the lien token being a **plain OZ ERC20 with no transfer/approve hooks** (WOOF-01 —
  `approve`/`transferFrom`/`burn` have no callback). Do not introduce a lien token with hooks, and do not wire
  the venue as the Forwarder.
- **Do NOT clear `r.lien` to `address(0)` on close, and do NOT design for `lienId` reuse (security F-12).** A
  `lienId` is **single-use for its entire lifecycle**: `LienExists` (origination dup guard on `r.lien != 0`) +
  the CREATE2 slot being permanently occupied (WOOF-01) + the venue's per-line `LineAccount` CREATE2 slot being
  permanently occupied (WOOF-04 — a same-`lienId` re-open reverts the `LineAccount` redeploy) + `r.open = false`
  (blocks post-close draw/close) mean a released `lienId` can never be re-originated. A property needing a new
  loan after release uses a **new `lienId`** (an off-chain CRE obligation). Keeping `r.lien` set post-close is
  the clean guard.

**Key requirements**
- `contract ZipcodeController is ReceiverTemplate`. Constructor `ZipcodeController(address forwarder, address
  venue_, address lienFactory_, address oracleRegistry_, address erebor_) ReceiverTemplate(forwarder)` storing
  four immutables: `address public immutable venue; address public immutable lienFactory; address public
  immutable oracleRegistry; address public immutable erebor;` (the Forwarder + `Ownable` owner come from
  `ReceiverTemplate`; **no EVC immutable**). Add `require`/`revert` zero-checks on
  `venue_`/`lienFactory_`/`oracleRegistry_`/`erebor_` (plain `require(x != address(0))` is fine; the Forwarder
  zero-check is in the base ctor).
- `mapping(bytes32 => LienRecord) public liens; struct LienRecord { address lien; address lineRef; bool open; }`.
  Add **`function getLien(bytes32 lienId) external view returns (LienRecord memory)`** — the `public` mapping
  auto-getter returns a **tuple** `(address,address,bool)`, NOT a struct, so `liens(id).lien` does **not**
  compile; tests + the subgraph use `getLien(id).lien` / `.lineRef` / `.open` (or destructure the tuple). Keep
  `liens` public too (cheap).
- **`_processReport(bytes calldata report) internal override`** — decode the envelope `(uint8 reportType, bytes
  memory payload) = abi.decode(report, (uint8, bytes));` then dispatch on `reportType` to the branches above;
  `else revert UnsupportedReportType(reportType);` (also reject `3`). Each branch decodes its own `payload` via
  `abi.decode`.
- **Origination (a):** implement steps 1–8 above exactly (dup guard → precompute+create+assert → approve →
  openLine → seedPrice → setLineLimits → fund → draw → store + event). Ordering is load-bearing: `create →
  openLine → seed → setLineLimits → fund → draw` (WOOF-02 obl. 3; seed before draw). **No EVC batch / no
  operator step** — the adapter's `openLine` provisions the operator grant and `draw` wraps the borrow.
- **Draw (a′):** re-anchor seed → fund → draw → event; `UnknownLien` if not open.
- **Close (c):** `observeDebt == 0` (`DebtOutstanding` else) → `closeLine` → `burn(1e18)` → `open=false` +
  `LienReleased`; `UnknownLien` if not open.
- **Default/Liquidation (d/e):** `emit LienStatusUpdated(lienId, status)` only; **never** `venue.liquidate`.
- **Forwarder immutability (the spec-fidelity carry from the WOOF-02 superintendent review):** rely on
  `renounceOwnership` (§9 S11) — set `setExpectedAuthor`/`setExpectedWorkflowId` first (S10b), then renounce
  (deploy asserts `getExpectedWorkflowId() != 0` before renounce, §4.4/§9, security F1). The controller adds
  **no** override of the base setters; post-renounce every `onlyOwner` setter (`setForwarderAddress`,
  `setExpected*`) reverts `OwnableUnauthorizedAccount`. **Dormant-gate caveat (security F-3):** the
  workflow-identity check is **conditional** — `onReport` only validates it when an expected value is non-zero
  (`ReceiverTemplate:88`); the controller has **NO on-chain defense** against a deploy that renounces before
  setting identity (it would silently degrade `onReport` to Forwarder-sender-only, letting any co-tenant workflow
  on the shared Forwarder drive origination). The ONLY defense is the deploy S11 pre-gate (item 10 / WOOF-10a).
  The controller's unit test MUST demonstrate the dormancy (expectations unset → a wrong `workflowId` is
  **accepted**; after `setExpectedWorkflowId` → it reverts `InvalidWorkflowId`) so the danger is shown, not
  silently delegated.
- **Errors:** `error LienExists(bytes32 lienId); error UnknownLien(bytes32 lienId); error PrecomputeMismatch();
  error DebtOutstanding(); error UnsupportedReportType(uint8 reportType);`. Identity/sender/owner reverts reuse
  the inherited `ReceiverTemplate`/`Ownable` errors (`InvalidSender`, `InvalidWorkflowId`,
  `OwnableUnauthorizedAccount`). (No EVC errors — the controller never calls EVC.)
- **Events:** `event LienOriginated(bytes32 indexed lienId, address indexed lien, address lineRef, bytes32
  proofRef, uint256 equityMark, uint256 drawAmount); event LienDrawn(bytes32 indexed lienId, uint256 equityMark,
  uint256 drawAmount); event LienReleased(bytes32 indexed lienId); event LienStatusUpdated(bytes32 indexed
  lienId, uint8 status);`. (`LienReleased` is the §4.4c/audit-L8 event; `LienCreated`/`RegistryPriceSeed`/
  `LineOpened`/`Borrow` are emitted by the underlying contracts.)

**Done when**
- `forge build` green (solc 0.8.24); new unit test passes (`contracts/test/ZipcodeController.t.sol`).
- **Harness (mirror WOOF-04's stand-up + the real controller on top):** **live EVK `GenericFactory`/EVault,
  EVC, EulerRouter, the real WOOF-01/02/03/04 contracts (incl. the per-line `LineAccount` the adapter deploys)**;
  **EulerEarn mocked** (pragma 0.8.26 → recording `IEulerEarn` mock). `FORWARDER`, `CONTROLLER_OWNER`, `EREBOR`
  are test EOAs; USDC + IRM mocked/standard. **Wire the WOOF-03 hook with `borrowDriver = address(adapter)`** (the
  EVC operator each `LineAccount` grants is the adapter — WOOF-03/04 re-authored; the hook gate is
  `isAccountOperatorAuthorized(borrowAccount, adapter)`). **Mock-funding recipe (concrete — the live borrow needs
  real cash):** the `IEulerEarn` mock is pre-minted USDC in setup; when the adapter's `fund` calls
  `reallocate([{baseUsdcMarket, …}, {EVAULT_i, lineBal+amount}])`, the mock **deposits `amount` USDC into the
  borrow vault** (`USDC.approve(EVAULT_i, amount); IEVault(EVAULT_i).deposit(amount, address(mock))`) so
  `EVAULT_i.cash() >= drawAmount` before the live borrow (exactly what a real EulerEarn does as the market's
  lender). **Precondition assert:** `EVAULT_i.cash() >= drawAmount` immediately before the draw step — else a
  borrow failure is `E_InsufficientCash`, not the LTV check, and N6/atomicity would pass for the wrong reason
  (qa). **Label per assertion:** EVK reads (`debtOf`/`LTVBorrow`/`getQuote`/cash) and the live borrow are
  **live**; the `reallocate` two-item allocation args are **mock-recorded**. (Cold-build notes, test-harness
  only: break the controller↔venue↔hook constructor cycle with `vm.computeCreateAddress(deployer, nonce)` to
  predict the adapter address so the hook's `borrowDriver` is wired to it; a zero-rate `MockIRM` keeps the
  close-path `repay(debt)` exact; pre-seed the base USDC market so the `reallocate` withdraw leg has balance —
  all item-10/§9 deploy concerns, not controller gaps.)
- **The live borrow works with NO controller operator-wiring (THE re-author proof — replaces the old
  before/after-`wireVenueOperator` negative-control, qa #1):** in a single fixture **without any controller EVC
  step** (there is no `wireVenueOperator` to call — the controller has no EVC handle), a `reportType 1`
  `onReport` **succeeds** and produces a live debt. The live borrow is authorized because the adapter's per-line
  `LineAccount` granted **the adapter** the EVC operator bit inside `openLine` (step 4). Assert directly off the
  adapter's line record (read via the venue's `getLine(lineRef)` / `LineOpened` event): the line's `borrowAccount`
  is operator-authorized to the **adapter** and **not** to the controller, via
  `IEVC(EVC).isAccountOperatorAuthorized(borrowAccount, adapter) == true` and `(..., controller) == false`
  (`EthereumVaultConnector.sol:286`). (There is **no** "before-wiring reverts / after-wiring succeeds" pair — the
  controller never wires anything; the grant is born at `openLine`. The old per-`sub_i`/`sub_0`-exclusion
  assertion is **removed** — there is no controller prefix / sub-account involved.)
- **Origination (audit L4) — the full transcript:** `vm.prank(FORWARDER); controller.onReport("",
  abi.encode(uint8(1), abi.encode(lienId, proofRef, equityMark=200_000e6, borrowLTV=0.8e4, liqLTV=0.85e4,
  drawAmount=100_000e6, cap)))` (**`metadata = ""` / empty bytes for the non-identity tests** — `_decodeMetadata`
  is only reached when expectations are set, qa #5). Assert:
  - `LIEN_i = controller.getLien(lienId).lien` equals `LIEN_FACTORY.computeAddress(lienId, controller)`;
    `LIEN_i.totalSupply()==1e18`, `decimals()==18`; the escrow vault holds **exactly** `LIEN_i.balanceOf(COLLAT_i)
    == 1e18` (the full lien — NOT `> 0`, qa (c)2).
  - `getQuote(1e18, LIEN_i, USDC) == equityMark` (the seed landed; exact for `1e18`).
  - `EVAULT_i.LTVBorrow(COLLAT_i)==borrowLTV`, `LTVLiquidation(COLLAT_i)==liqLTV` (1e4 scale).
  - `EVAULT_i.debtOf(borrowAccount) == drawAmount` (read `borrowAccount` off the venue's line record);
    `USDC.balanceOf(EREBOR) == drawAmount`.
  - `ILienToken(LIEN_i).allowance(controller, venue) == 0` (the `approve(1e18)` was fully consumed — no standing
    approval, security F-7).
  - events with `vm.expectEmit` (topics+data, correct emitter): `LienCreated` (factory), `RegistryPriceSeed`
    (registry), `LienOriginated` (controller), plus the venue's `LineOpened`/`Borrow`.
- **Batch-atomicity (WOOF-02 obl. 3 — the controller's signature test; two revert points, qa #2):**
  - **Late revert (audit N6, over-LTV):** an origination with `drawAmount > borrowLTV × equityMark` reverts on
    `onReport` with the EVK account-status error **`E_AccountLiquidity()`** (cold-build-confirmed it is the LTV
    check, NOT `E_InsufficientCash` — the mock pre-funds the vault; assert this exact selector).
  - **Mid-batch revert (stronger — lien already deployed, seed not yet written):** an origination with
    `equityMark = 0` reverts at `seedPrice` (`PriceOracle_InvalidAnswer`, WOOF-02), OR `vm.mockCallRevert` the
    venue's `openLine` — proving the **CREATE2 deploys (lien token AND the per-line `LineAccount`) both roll
    back**.
  - **Cap-only bound (mark-independent ceiling, security F-5):** an origination with `drawAmount` within
    `borrowLTV × equityMark` but **above `cap`** reverts **`E_BorrowCapExceeded()`** (cold-build-confirmed — the
    real AmountCap ceiling, mark-independent).
  - For **each** revert assert the full no-orphan post-state: `LIEN_FACTORY.computeAddress(lienId,
    controller).code.length == 0`, `controller.getLien(lienId).lien == address(0)`, `.open == false`, and
    registry `getQuote(1e18, predictedLien, USDC)` reverts `PriceOracle_NotSupported` (no orphan seed). (The
    per-line `LineAccount` CREATE2 slot is likewise free after a rollback — a re-origination with the same
    `lienId` can still succeed, since the failed attempt's `LineAccount` deploy reverted too.)
- **Draw (a′), exact (qa #8/#9/#10):** after origination, snapshot `d0 = debtOf(borrowAccount)`; a `reportType 2`
  report re-anchors the mark and draws `drawAmount2`; assert `debtOf(borrowAccount) == d0 + drawAmount2` (no time
  warp) and `USDC.balanceOf(EREBOR) == drawAmount + drawAmount2`. **Re-anchor-below-LTV rollback:** a type-2 with
  a lowered `equityMark` and a `drawAmount` exceeding the new headroom **reverts**, and the re-anchor **rolls
  back** — assert `getQuote(1e18, LIEN_i, USDC)` is still the *prior* mark and `debtOf(borrowAccount)` unchanged.
  Draw on an **unknown** `lienId` and on a **closed** line both revert `UnknownLien`.
- **Close (audit L7/L8):** permissionless `repay` (any EOA — assert a non-Forwarder caller can zero the debt and
  cannot *add* debt, security F-8) zeroes the debt; then `vm.prank(FORWARDER); onReport("", abi.encode(uint8(4),
  abi.encode(lienId)))` → `closeLine` reclaims the lien (operator-routed `EVC.call` redeem), `burn(1e18)` drops
  `LIEN_i.totalSupply()` to 0, `emit LienReleased(lienId)` + `Transfer(holder→0,1e18)`, `getLien(lienId).open ==
  false`, and the closed-loop check `LIEN_i.balanceOf(COLLAT_i) == 0` (escrow drained). **Debt>0 close** reverts
  `DebtOutstanding` with **state unchanged** (`LIEN_i.totalSupply()==1e18`, `.open==true` — no partial unwind, qa
  #4). **Double-close** (second type-4 same `lienId`) reverts `UnknownLien` (controller `!open` guard fires before
  the venue's, qa #5). **Close of a never-opened `lienId`** reverts `UnknownLien`. **Burn-after-reclaim
  sequencing (qa #7):** with `closeLine` mocked to no-op (not redeeming the lien), `burn(1e18)` reverts
  `ERC20InsufficientBalance` — pins the reclaim-before-burn dependency.
- **Dispatch + dup (qa #11/#12):** `reportType 3` reverts `UnsupportedReportType(3)`; `reportType 0` and an
  unknown type (`7`/`255`) revert `UnsupportedReportType`; a **type-1 with a truncated/empty `payload`** reverts
  (the inner `abi.decode` bounds-check — fails closed, no zero-filled origination). A second origination with
  the same `lienId` reverts `LienExists` with **no double-mint** (`LIEN_i.totalSupply()==1e18` unchanged, the
  first line's record intact).
- **Default/Liquidation markers (qa #13):** for an **open** line, `reportType 5`/`6` each emit ONLY
  `LienStatusUpdated(lienId, status)` (assert via `vm.recordLogs()` that no `Borrow`/`Liquidate`/`LineDrawn`
  topic appears; optionally `vm.mockCallRevert(venue, IZipcodeVenue.liquidate.selector, …)` so any liquidate
  call would revert) and mutate **no** state (`getLien(lienId).open` unchanged, `debtOf(borrowAccount)`
  unchanged).
- **Authority + dormant-gate (audit N2/N2b/N7 — inherited, security F-3):** `onReport` from a non-Forwarder
  reverts `InvalidSender(caller, FORWARDER)`. **Dormancy demo:** with expectations unset, an `onReport` carrying
  a *wrong* `workflowId` (packed `metadata`) is **accepted** (succeeds); then `setExpectedWorkflowId(WID)` and
  the same wrong-id `onReport` reverts `InvalidWorkflowId`. After `renounceOwnership()`,
  `setForwarderAddress(any)` and `setExpectedAuthor(any)` both revert `OwnableUnauthorizedAccount`. (Identity
  `metadata` is built with **`abi.encodePacked`** — `_decodeMetadata` reads fixed offsets 32/64/74, WOOF-02
  note.) (There is **no `wireVenueOperator(any)` post-renounce revert** to assert — the entrypoint is removed.)
- **Reentrancy is structurally impossible (security F-10):** a malicious `IZipcodeVenue` mock that tries to
  re-enter `controller.onReport(…)` during `openLine` has its reentrant call revert `InvalidSender(venue,
  FORWARDER)` (the callee is not the Forwarder), and the outer batch completes deterministically — proving the
  last-write `liens` ordering is safe by the Forwarder gate (no `nonReentrant` needed).
- **Acceptance (integration harness — the live end-to-end is the `audit/2.md` slice this ticket owns):** **L4**
  (origination transcript above — the live borrow succeeds with NO controller operator step), **L7/L8** (repay →
  close → `LienReleased`), **N2/N2b** (Forwarder/identity), **N6** (over-LTV origination reverts in the borrow
  step), **N7** (post-renounce setters revert). Authority realized: `audit/3-results.md` rows **18**
  (`LIEN_i.burn` controller-only via the close path), **19** (`create` caller-bound — the controller is the
  caller), **20** (`onReport` Forwarder + identity), **F1** (renounce ordering, asserted in the deploy/wiring
  ticket — item 10).

**Spec/audit edits this ticket made (triage — APPLIED in prior windows, NOT re-opened this re-author):**
- The re-author of WOOF-05 is a **pure subtraction** consequent on the already-ratified borrower-model spec edits
  (§4.3/§4.4/§4.7/§9/§17, Step 1; WOOF-03/04 re-authored). The spec (§4.4 ctor note `:380-383`, §9 `:915-920`)
  **already** states the controller takes no EVC handle and that there is no controller-level operator-wiring
  step — so this ticket required **NO new `claude-zipcode.md` edit** (spec-fidelity confirmed). The `erebor`
  5th-immutable, the §4.4a `create → openLine → seed → setLineLimits → fund → draw` ordering, and the report-type
  branches are carried forward **unchanged** from the prior (filed) WOOF-05; only the operator-wiring machinery is
  removed. **No §17 decision reopened** (esp. supply-side yield / xALPHA / szipUSD).

**Depends on**
WOOF-00 (scaffold + `x402-cre-price-alerts/`/base remaps), WOOF-01 (`LienTokenFactory`/`LienCollateralToken` —
the controller is the `create`/`burn` caller + holds the lien custody), WOOF-02 (`ZipcodeOracleRegistry` — the
`seedPrice` caller), WOOF-03 **re-authored** (`CREGatingHook` — operator-auth gate on the adapter, installed on
each borrow vault), WOOF-04 **re-authored** (`IZipcodeVenue`/`EulerVenueAdapter`/`LineAccount` — every venue
effect; the `LineAccount` issues the per-line operator grant inside `openLine`, so `draw` is authorized with no
controller EVC step). Downstream: the **deploy/wiring ticket (item 10, §9)** — deploys with the 5-arg ctor, calls
`ZIP_ORACLE_REG.setController`, sets identity then renounces (S10b→S11 hard pre-gate), grants the venue EE
curator/allocator + onboards `baseUsdcMarket`, and wires the hook's `borrowDriver` = the adapter (**no
`controller.wireVenueOperator` step — removed**); the **CRE track (§8)** — authors the Go workflow that
ABI-encodes the `(reportType, payload)` reports this controller decodes; the **redemption queue (item 9)** — the
controller is its `settleEpoch` privileged caller (§6.1/§8.3, **out of this ticket's scope**).

**Cross-ticket obligations this ticket CREATES (verify discharged by the named ticket):**
1. **Deploy/wiring (item 10, §9):** (a) deploy `ZipcodeController` with the **5-arg** ctor (incl. `EREBOR`,
   **NO EVC**); (b) **NO `controller.wireVenueOperator(EVC)` step — REMOVED** (each line's operator grant is
   issued per line inside `openLine` by the adapter's `LineAccount`, §4.4/§4.7; `draw` no longer depends on any
   deploy-time controller EVC wiring); (c) `ZIP_ORACLE_REG.setController(ZIP_CONTROLLER)` at S6; (d) set identity
   (S10b) then renounce (S11) with the `getExpectedWorkflowId() != 0` pre-gate (security F-3; tested by WOOF-10a);
   (e) wire the hook's `borrowDriver` immutable = the adapter address (precompute/two-pass — WOOF-03/04
   obligation).
2. **CRE track (§8):** the Go workflow MUST ABI-encode reports as `abi.encode(uint8 reportType, bytes payload)`
   with the per-type payloads in the table above (type 1/2/4/5/6 → controller; type 3 → registry direct), and
   only emit an origination/draw report once the off-chain Proof gates + delinquency checks pass (§8.5/§4.4a′).
