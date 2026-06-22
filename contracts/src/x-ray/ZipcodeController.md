# X-Ray — `ZipcodeController.sol` (single-contract, test-connected)

> ZipcodeController | 174 nSLOC | 46fd0c1 (`main`) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo the pre-prod wiring re-freeze + no external audit)*

> **Update 2026-06-20:** the I-11 gap is **CLOSED** — `test_I11_WiringSetters_RejectNonOwner` / `_RejectZeroAddress`
> / `_RepointAndEmit` cover all 5 wiring setters (`onlyOwner` + `ZeroAddress` + re-point/`WiringSet`), and
> `test_I11_Ctor_ZeroGuards` covers the 4 ctor `require` zero-guards. 43/43 green. Verdict lifted to HARDENED.

Per-contract X-Ray for `contracts/src/ZipcodeController.sol` (§4.4), the **portable core's orchestrator**: the CRE
receiver (Forwarder-gated), the per-`reportType` decision logic, and the lien-token mint/burn authority. It is the
on-chain borrower of record but touches **no EVC** — every venue effect goes through the venue-neutral
`IZipcodeVenue` seam; the per-line EVC borrow-on-behalf is the adapter's job. Exercised by `ZipcodeController.t.sol`
— a **~40-test Base-fork suite** (real EVK/EVC/EulerEarn stack via `EulerVenueAdapter`, plus `RecordingVenue` /
`ReentrantVenue` harnesses).

> The contract is a **pure orchestrator**: decode a CRE report → dispatch by `reportType` → drive the venue seam +
> seed the oracle + manage the lien token. The security work is (1) **atomicity** — an origination is `create →
> openLine → seed → setLineLimits → fund → draw → store → incrementLineCount`, and any revert rolls back the whole
> batch incl. the CREATE2 deploys (no orphan lien/market); (2) **fail-closed routing** — draws/closes re-resolve the
> venue from the line's *stored* `siloId` via the `SiloRegistry`, never a global pointer, so a re-pointed/retired
> silo can't strand a line; (3) **report-type allow-list** — anything unknown (incl. reportType 3, which goes direct
> to the registry) reverts. All three are densely fork-tested.

## 1. What it is

A 174-nSLOC `ReceiverTemplate` (CRE receiver; owner = Timelock). Five Timelock-settable wiring slots
(`venue`/`lienFactory`/`oracleRegistry`/`erebor`/`registry`) + a per-lien record map. The single inbound is
`onReport` → `_processReport`, dispatching:

- **`_origination`** (RT=1) — the atomic 9-step batch: resolve venue from `siloId` → dup-guard → precompute+create the lien (assert match) → approve exactly `1e18` → `openLine` → `seedPrice` → `setLineLimits` → `fund` → `draw` (to `erebor`) → store record (last write) → `incrementLineCount` (final).
- **`_draw`** (RT=2) — re-resolve the SAME venue from the stored `siloId` → re-anchor `seedPrice` → `fund` → `draw`.
- **`_close`** (RT=4) — re-resolve venue → `observeDebt==0` guard → `closeLine` (reclaims the lien) → `burn(1e18)` → flip `open=false` → `decrementLineCount`.
- **RT=5/6 (default/liquidation)** — M1 status-marker only (emit `LienStatusUpdated`); **RT=3 and any other** → `UnsupportedReportType`.

No EVC, no custody beyond the transient lien approve. Wiring is build-phase re-pointable; `registry` starts zero and
fails closed (`RegistryUnset`) rather than falling back to the `venue` slot.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `onReport` → `_processReport` | Forwarder-gated (+ workflow identity) | decode + dispatch; unknown type → `UnsupportedReportType` |
| `getLien(lienId)` | public view | struct getter |
| `setVenue`/`setLienFactory`/`setOracleRegistry`/`setErebor`/`setRegistry` | `onlyOwner` (Timelock) | `ZeroAddress`-guarded re-points; emit `WiringSet` |
| `constructor(forwarder, venue_, lienFactory_, oracleRegistry_, erebor_)` | deploy | `require`-zero-guards the 4 non-forwarder args; `registry` wired post-deploy |

Report paths route EXCLUSIVELY via the registry (`_venueFor`), never the `venue` slot — fail-closed on
`RegistryUnset`/`SiloUnrouted`.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **atomic origination** — full transcript create→openLine→seed→limits→fund→draw→store→increment; any revert rolls back incl. CREATE2 deploys | Yes | **`test_Origination_L4_FullTranscript`**, `_EmitsExpectedEvents`, `_Atomicity_LateRevert_OverLTV`, `_Atomicity_MidBatchRevert_ZeroMark_RollsBackDeploys`, `_Atomicity_CapOnlyBound` |
| I-2 | **draw re-anchors + re-funds on an open line; fail-closed on unknown/closed** | Yes | **`test_Draw_ExactAccrual`**, `_ReAnchorBelowLTV_RollsBack`, `_UnknownLien_Reverts`, `_OnClosedLine_Reverts` |
| I-3 | **close: zero-debt guard → closeLine → burn(1e18); reclaim-before-burn sequencing; single-use** | Yes | **`test_Close_L7L8_RepayThenRelease`**, `_RepayCannotAddDebt`, `_DebtOutstanding_StateUnchanged`, `_DoubleClose_Reverts`, `_NeverOpened_Reverts`, `_BurnAfterReclaim_Sequencing` |
| I-4 | **report-type allow-list** — RT 0/3/7/255 + truncated payload all revert; default/liquidation are status-only | Yes | **`test_Dispatch_ReportType3_Rejected`**, `_ReportType0_Rejected`, `_ReportType7And255_Rejected`, `_TruncatedPayload_Reverts`, `_Markers_DefaultAndLiquidation_StatusOnly` |
| I-5 | **CTR-03 fail-closed routing** — origination routes to the named venue; draw/close re-resolve from the STORED siloId; closes even after retire; `RegistryUnset`/`SiloUnrouted` revert | Yes | **`test_CTR03_Origination_RoutesToNamedVenue`**, `_DrawClose_ReResolveFromStoredSiloId`, `_OpenLine_ClosesAfterSiloRetired`, `_UnknownSilo_RevertsSiloUnrouted`, `_RegistryUnset_Reverts` |
| I-6 | **slot accounting** — increment on open, decrement on close; `SiloFull` rolls back the whole origination | Yes | **`test_CTR03_LineCount_IncrementsAndDecrements`**, `_SiloFull_RollsBackOrigination`, `_RealRegistry_OriginateAndClose` |
| I-7 | **revolving / coexistence** — borrow→repay→redraw same slot, persistent oracle key, LTV backstop on redraw, survives mark lapse; repo + revolving coexist on one pool | Yes | **`test_Revolving_*`** (4), `_Coexistence_RepoAndRevolving_OnePool` |
| I-8 | **reentrancy structurally impossible** — last-write ordering + trusted no-callback registry | Yes | **`test_Reentrancy_Impossible`** (`ReentrantVenue`) |
| I-9 | **identity gates** — non-Forwarder reverts; dormant-gate; post-renounce parent setters revert | Yes | **`test_Authority_NonForwarder_Reverts`**, `_DormantGate_Demonstration`, `_PostRenounce_SettersRevert` |
| I-10 | **dup origination no double-mint** | Yes | **`test_Dispatch_DuplicateOrigination_NoDoubleMint`** |
| I-11 | **build-phase wiring setters** — the 5 setters are `onlyOwner` + `ZeroAddress`-guarded + emit `WiringSet`; ctor zero-guards the 4 non-forwarder args | Yes | **`test_I11_WiringSetters_RejectNonOwner`** (5× `OwnableUnauthorized`), **`_RejectZeroAddress`** (5× `ZeroAddress`), **`_RepointAndEmit`** (5× re-point + `WiringSet`), **`test_I11_Ctor_ZeroGuards`** (4 ctor `require`s, each arg zeroed) |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `UnsupportedReportType` / truncated decode | `_processReport:206` | `test_Dispatch_*` |
| `LienExists` (dup) | `_origination:229` | `test_Dispatch_DuplicateOrigination_NoDoubleMint` |
| `PrecomputeMismatch` | `_origination:234` | exercised on the real factory in the origination transcript (matches by construction) |
| `UnknownLien` (draw/close) | `:269,290` | `test_Draw_UnknownLien_Reverts`, `_Close_NeverOpened_Reverts` |
| `DebtOutstanding` (close) | `_close:296` | `test_Close_DebtOutstanding_StateUnchanged` |
| `RegistryUnset` / `SiloUnrouted` | `_venueFor:179,181` | `test_CTR03_RegistryUnset_Reverts`, `_UnknownSilo_RevertsSiloUnrouted` |
| Forwarder / identity gate | `ReceiverTemplate` | `test_Authority_NonForwarder_Reverts`, `_DormantGate_Demonstration` |
| 5 wiring setters: `onlyOwner` + `ZeroAddress` + `WiringSet` | `:141-174` | `test_I11_WiringSetters_RejectNonOwner` / `_RejectZeroAddress` / `_RepointAndEmit` |
| ctor `require` zero-guards (×4) | `:128-131` | `test_I11_Ctor_ZeroGuards` |

Every guard, branch, setter, and ctor zero-guard is now exercised — no untested surface.

## 5. Attack surfaces

- **Atomicity is the core safety property — and it's densely proven (I-1).** An origination touches the factory, the
  venue (5 calls), the oracle, and the registry; a failure at any step (over-LTV draw, zero-mark seed, `SiloFull`)
  must leave NO orphan lien/market. The suite drives late reverts, mid-batch reverts (incl. proving the CREATE2
  deploys roll back), and the `SiloFull` rollback — the highest-value tests for an orchestrator.
- **Fail-closed routing is the multi-silo safety net (I-5).** Draws/closes re-resolve the venue from the line's
  *stored* `siloId`, never a mutable global pointer, so a re-pointed or retired silo cannot strand an open line in
  the wrong venue — and a line can always close even after its silo is retired (`venueOf` ignores `active`). The
  unwired-registry path fails closed (`RegistryUnset`) rather than silently falling back to the `venue` slot.
- **Report-type allow-list (I-4).** Everything that isn't origination/draw/close/default/liquidation reverts —
  notably reportType 3 (revaluation), which is delivered direct to the registry and must NOT be processed here.
  Tested across 0/3/7/255 + a truncated payload.
- **Reentrancy is structurally impossible (I-8).** The `liens` write is the last state mutation before the trusted,
  no-callback registry increment; a `ReentrantVenue` harness confirms a malicious venue cannot re-enter to corrupt
  state. (The venue is trusted infra; this is defense-in-depth.)
- **Build-phase wiring setters + ctor guards (I-11) — CLOSED.** The contract has the most central wiring in the
  system (the venue, the factory, the oracle, the off-ramp, the silo registry); all five setters are now swept —
  `test_I11_WiringSetters_RejectNonOwner` (a non-owner reverts `OwnableUnauthorizedAccount` on all 5),
  `_RejectZeroAddress` (5× `ZeroAddress`), `_RepointAndEmit` (5× re-point + `WiringSet`) — and the four ctor `require`
  zero-guards are exercised by `test_I11_Ctor_ZeroGuards` (each non-forwarder arg zeroed in turn). The recurring
  setter-gap class is closed at the system's most central contract.
- **Inherent trust:** the CRE Forwarder (identity-gated), the venue adapter, the lien factory, and the oracle
  registry are all trusted, separately-X-rayed dependencies. Build-phase mutable wiring (frozen pre-prod) is the
  subsystem-wide residual.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Origination + atomicity | 5 | full transcript, late/mid-batch reverts (CREATE2 rollback), cap bound |
| Draw + close | 10 | accrual, re-anchor backstop, unknown/closed, repay-release, sequencing, double/never |
| Dispatch / report-type allow-list | 6 | RT 0/3/7/255 + truncated + status markers + dup |
| CTR-03 routing + slot accounting | 8 | named-venue, stored-siloId re-resolve, retire-then-close, SiloFull rollback, RegistryUnset/SiloUnrouted, real registry |
| Revolving / coexistence | 5 | borrow-repay-redraw, persistent key, LTV backstop, mark lapse, repo+revolving |
| Identity / reentrancy / live-borrow | 5 | non-forwarder, dormant gate, post-renounce, ReentrantVenue, no-operator-wiring |
| Wiring setters (onlyOwner/zero/event) + ctor zero-guards | 4 | `test_I11_*` (added 2026-06-20) |

Coverage % uninstrumentable (project-wide `Stack too deep`); **43 fork tests green**. The suite is fork-integration
against the real EVK/EVC/EulerEarn stack — exactly right for an orchestrator whose correctness is its end-to-end
interaction with the venue. No coverage gap remains.

## X-Ray Verdict

**HARDENED** *(modulo the pre-prod wiring re-freeze + no external audit)* — the portable core's orchestrator, with
its decisive surfaces all fork-proven against the real stack: atomic origination (with CREATE2-rollback on any
mid-batch revert), fail-closed stored-`siloId` routing (a retired/re-pointed silo can't strand or misroute a line),
the report-type allow-list (reportType 3 rejected), structural reentrancy-impossibility, the full draw/close
lifecycle, slot accounting with `SiloFull` rollback, and revolving/coexistence on one pool. The I-11 gap is **closed**:
all five build-phase wiring setters' `onlyOwner`/`ZeroAddress`/`WiringSet` and the four ctor `require` zero-guards are
now tested. No code or coverage gap remains; the only residuals are the deferred pre-prod immutable re-freeze of the
build-phase wiring (`onlyOwner` + zero-guarded) and the absence of an external audit.

**Structural facts:**
1. 174 nSLOC; `ReceiverTemplate` (CRE receiver, Timelock owner); a pure orchestrator — touches NO EVC; 5 Timelock-settable wiring slots.
2. Origination is an atomic 9-step batch (create→openLine→seed→limits→fund→draw→store→increment); any revert rolls back incl. the CREATE2 deploys.
3. Draws/closes re-resolve the venue from the line's STORED `siloId` via the `SiloRegistry`, never a global pointer — fail-closed (`RegistryUnset`/`SiloUnrouted`); a retired silo's lines still close.
4. Report-type allow-list (origination/draw/close + default/liquidation markers); RT 3 and all others revert; last-write ordering + no-callback registry make reentrancy structurally impossible.
5. Tests: 43 Base-fork (origination/atomicity, draw/close, dispatch, CTR-03 routing+slots, revolving, identity, reentrancy, + the 5 wiring setters' onlyOwner/zero/event + the 4 ctor zero-guards). No coverage gap; capped only by the pre-prod re-freeze + no audit.
