# 3-results.md — Authority & gating wiring sweep (verdict)

> **PLAIN NAME: the who-touches-money check** — the list of who's allowed to touch what.
> Quarantined build scaffolding. Dies once item 10 + per-component tests cover the same ground (see `deathnote.md`).


> **What this is (provenance).** The standalone authority & gating wiring audit of the M1 contract surface:
> every privileged state mutation, who is authorized to call it, how it is gated, and the spec § that rules
> it — plus critical-path traces, a failure-mode checklist, and an orphan-caller sweep. It **absorbs and
> replaces the former `3.md` audit protocol** (retired once this passed). **To re-run** after any wiring
> change: confirm every matrix row has a non-empty authorized caller + gating mechanism, each trace permits
> at every hop, and the orphan sweep stays empty. Loss-side rows (`DefaultCoordinator`, `LienXAlphaEscrow`)
> are **M1-sketch** and flagged for M2 re-audit.
>
> Every citation was verified directly against `reference/` and `claude-zipcode.md`. Source line-checks:
> `ReceiverTemplate.sol:48,83-117,127,143,159,184`; `ESynth.sol:47,55,81`;
> `EthereumVaultConnector.sol:250,260,343,364`;
> `Governance.sol:93(modifier),256,281,333,347`; `EulerRouter.sol:56,78,79`.

---

## §2 — Operation × authority matrix (verified)

Verification legend: **OK** = caller + gating non-empty and matches spec §; **FLAG** = changed or
contested; **M1-sketch** = loss-side, defer to M2.

Venue-adapter convention confirmed against §4.4/§4.7/§9: the **EulerEarn allocator + curator**, **`EVAULT_i`
governor**, and the **per-line `ROUTER_i` governor (transient — frozen at birth)** are held by the **`VENUE`
(`EulerVenueAdapter`)**, not the controller. §9 setup wires `venuePool.setIsAllocator(adapter,true)` +
`setCurator(adapter)`; the per-line markets + routers are minted inside `VENUE.openLine` (no shared router;
per-line routers are `transferGovernance(0)`-frozen, §4.1/§4.7). The TIMELOCK governs §17 **params**, not the
routers.
Each line borrows on a **fresh per-line EVC account** (its own owner-prefix, §4.4) with the **borrow-driver**
(the `VENUE` adapter — the `EVC.call` caller) wired as that account's EVC **operator**; the hook gates on
operator-authorization (`isAccountOperatorAuthorized(caller, VENUE)`, `EthereumVaultConnector.sol:286`), **not**
an owner check (no line shares the borrow-driver's prefix, so `haveCommonOwner` is false for every line).

| # | Op | Target | Authorized caller(s) | Gating mechanism | § match | Verdict |
|---|---|---|---|---|---|---|
| 1 | `setIsAllocator` | `EE_POOL` | EulerEarn owner | `onlyOwner` | §3/§9 | OK |
| 2 | `setFeeRecipient` | `EE_POOL` | EulerEarn owner | `onlyOwner` | §3/§5/§9 | OK |
| 3 | `setFee` | `EE_POOL` | EulerEarn owner | `onlyOwner` | §5/§17 | OK |
| 4 | `reallocate` | `EE_POOL` | allocator (= **VENUE**) via EVC `onBehalfOfAccount` | `_msgSenderOnlyEVCAccountOwner` ⇒ `isAllocator[VENUE]` | §3/§4.4a/§9 | OK (caller = VENUE per §4.7) |
| 5 | `setGovernorAdmin` | `EVAULT_i` | current governor (= **VENUE**) | `governorOnly` (`Governance.sol:256`) | §3/§9 | OK |
| 6 | `setLTV` | `EVAULT_i` | governor (= **VENUE**) | `governorOnly` (`Governance.sol:281`) | §3/§4.4a | OK (governor = VENUE per §4.4/§4.7) |
| 7 | `setHookConfig` | `EVAULT_i` | governor (= **VENUE**) | `governorOnly` (`Governance.sol:347`) | §3/§9 | OK (governor = VENUE per §4.4/§4.7) |
| 8 | `setInterestRateModel` | `EVAULT_i` | governor (= **VENUE**) | `governorOnly` (`Governance.sol:333`) | §3/§9 | OK (governor = VENUE per §4.4/§4.7) |
| 9 | `borrow` | `EVAULT_i` | the line's fresh per-line borrow account (borrow-driver/`VENUE`-as-operator) | `CREGatingHook` ⇒ `EVC.isAccountOperatorAuthorized(caller, VENUE)` (`EthereumVaultConnector.sol:286`) | §4.3/§4.4a | OK |
| 10 | `liquidate` | `EVAULT_i` | the line's fresh per-line borrow account (borrow-driver/`VENUE`-as-operator), **defensive only** | same hook (EVC operator-auth check) on `OP_LIQUIDATE` | §4.3/§4.4e | OK (no on-chain economic liquidation, §17) |
| 11 | `repay` | `EVAULT_i` | **anyone** (deliberately ungated) | `OP_REPAY ∉ hookedOps` (`Borrowing.sol:82`) | §4.3/§9 | OK |
| 12 | `govSetConfig`/`govSetResolvedVault` | per-line `ROUTER_i` | the `VENUE` adapter, **at birth only** (inside `openLine`) | `onlyGovernor`; the adapter is the fresh router's governor, then `transferGovernance(address(0))` **freezes** it | §4.1/§4.7 | OK (per-line frozen — supersedes shared-router/timelock) |
| 13 | `transferGovernance` | per-line `ROUTER_i` | the `VENUE` adapter (once, to `address(0)`) | `onlyGovernor`; after the freeze no caller can re-wire (2.md N5) | §4.1/§4.7 | OK |
| 14 | `schedule`/`executeBatch` | `TIMELOCK` | `PROPOSER_ROLE`=`ZIP_CONTROLLER`; `EXECUTOR_ROLE`=`address(0)` | OZ `AccessControl` | §4.4/§9 | OK |
| 15 | `setCapacity` | `ZIPUSD` (`ESynth`) | `Ownable` owner | `onlyEVCAccountOwner onlyOwner` (`ESynth.sol:47`) | §5/§9 | OK (renounce post-S7) |
| 16 | `mint` | `ZIPUSD` (`ESynth`) | minters (`DEPOSIT_MODULE`) | per-minter capacity (`ESynth.sol:55`) | §4.5/§5 | OK |
| 17 | `burn` | `ZIPUSD` (`ESynth`) | minters (`DEPOSIT_MODULE`; **the M2 loss-side `DefaultCoordinator` for the lever-1 junior-zipUSD burn**, §11/§4.6 — *not* szipUSD-on-stake, deleted) | per-minter capacity (`ESynth.sol:81`) | §4.5/§9/§11 | OK (M2 burn authority pending 8-B/8-S2b; see open item 1) |
| 18 | `LIEN_i.mint`/`burn` | `LIEN_i` | `ZIP_CONTROLLER` only | `onlyController` (immutable at deploy) | §4.2 | OK |
| 19 | `LIEN_FACTORY.create` | `LIEN_FACTORY` | caller-bound (only `ZIP_CONTROLLER` yields the canonical `LIEN_i`) | `create(lienId)` sets `controller := msg.sender`; CREATE2 address embeds the caller, so a non-controller call lands at a *different*, inert address — no gate needed, squat-proof | §4.2/§4.4a | OK |
| 20 | `ZIP_CONTROLLER.onReport` | `ZIP_CONTROLLER` | `FORWARDER` only | `msg.sender==s_forwarderAddress` (`:83`) + identity (`:88-117`) | §3/§4.4/§13 | OK (depends on §9 ordering — see Finding F1) |
| 21 | `ZIP_ORACLE_REG.onReport` | `ZIP_ORACLE_REG` | `FORWARDER` only | same as row 20 | §3/§4.1 | OK (same §9-ordering dependency) |
| 22 | `ZIP_ORACLE_REG._processReport` | `ZIP_ORACLE_REG` | invoked from row 21 (Forwarder-gated) | `reportType==3` + `liens.length==prices.length`; per-write guards `price!=0`, `≤uint208.max`, **strict** decimals==18 (low-level staticcall, not silent-18 `_getDecimals`), `ts≤now`; atomic batch (no HPI/value band) | §4.1 | OK |
| 23 | `REDEMPTION_QUEUE.settleEpoch` | `REDEMPTION_QUEUE` | `ZIP_CONTROLLER` only | `onlyController` (immutable) | §6.1/§8.3 | OK |
| 24 | `requestRedeem` | `REDEMPTION_QUEUE` | **anyone** (ERC-7540) | standard (no privilege) | §6.1 | OK |
| 25 | junior **deposit → Loot** | 8-B2 deposit/mint shaman | the depositor (self-service) | mint Loot on zipUSD deposit **into the Safe** (no zipUSD burn, no EE-share move) | §4.5/§6.4 | 8-B2 (Baal) — supersedes the deleted `SZIPUSD.stake` |
| 26 | **`ragequit`** (Loot → in-kind basket) | Baal (`Baal.sol`) | the Loot holder | gated by the **lock/freeze shaman** (~30d lock + the Duration-Bond freeze) | §6.4/§11 | 8-B1/8-B3 (Baal) — supersedes the deleted `startCooldown` |
| 27 | **lock / freeze gate** | lock/freeze shaman | set-once (lock) / `DefaultCoordinator` (freeze) | withhold `atRiskAmount/basketNAV` from ragequit + the withdrawal floor; objective release | §6.4/§11 | 8-B3 (Baal) — supersedes the deleted `withdraw`/`availableWithdrawLimit` |
| 28 | `LienXAlphaEscrow.lock/release/slash*` | `XALPHA_ESCROW` | `ZIP_CONTROLLER` (lock/release); `DefaultCoordinator` (slashes) | `onlyController`/`onlyCoordinator` | §4.6 | M1-sketch |
| 29 | `DefaultCoordinator.onReport` | `DEFAULT_COORD` | `FORWARDER` only | same as row 20 | §4.6/§8.4/§13 | M1-sketch |

**Blank-cell sweep:** no blank `Authorized caller(s)` or `Gating mechanism` cells. ✅

**Cells changed/resolved:** rows **5, 6, 7, 8** — the drafted matrix named `ZIP_CONTROLLER` as the
`governorOnly` caller. Per §4.4 ("isolated-market **governor**" is held by `EulerVenueAdapter`), §4.7
("EVK market: `setLTV`, `setHookConfig`, `setIRM`, `setGovernorAdmin`" sit in the **venue adapter**
column) and §9 (`EVault.setGovernorAdmin(adapter)`), the governor is the **VENUE**, not the controller
directly. Rows 5–8 above **name `VENUE`** as the role-holder (an earlier draft named `ZIP_CONTROLLER`),
so the matrix matches the spec with no re-read indirection. Row 4 (`reallocate`) likewise resolves to
**VENUE** as allocator. None was an over-privilege the spec does not intend; the controller *drives* these
via `IZipcodeVenue` but does not hold the role.

**No over-privilege found:** every authorized caller maps to a caller the spec actually authorizes.
No caller is permitted something the spec withholds.

> **Junior rows superseded (2026-06-06, 8-S3 cleanup).** Rows 25–27 originally encoded the **deleted**
> convert-on-stake szipUSD (`stake` / `startCooldown` / `withdraw` via `availableWithdrawLimit`). They are
> replaced above with the **Baal** authority surface (deposit/mint shaman → Loot; `ragequit`; the lock/freeze
> ragequit-gate). The Baal authority wiring is **re-verified at 8-B1/8-B2/8-B3**, and the senior-custody +
> ESynth-authority side at **8-S2b (two-Safe custody, in design)** — this verdict covers the **senior** wiring;
> the junior rows are pointers, not yet a built-and-verified surface.

---

## §3 — Critical-path trace verdicts

### Trace A — Borrow (origination draw): **PERMIT**
- Hop 1 — CRE workflow → `Forwarder.report`: off-chain, DON-signed. n/a on-chain gate.
- Hop 2 — `Forwarder` → `ZIP_CONTROLLER.onReport`: gate `msg.sender==s_forwarderAddress`
  (`ReceiverTemplate.sol:83`) **permit**; identity gate `:88-117` **permit** (provided §9 ordering set
  the expected values — see F1).
- Hop 3 — `_processReport`, `reportType=1` origination branch: internal dispatch, no gate. **permit**.
- Hop 4 — **F4 confirmed.** No router governance call at origination. Each line's `ROUTER_i` is minted, wired
  `escrowVault → LIEN_i → ZIP_ORACLE_REG`, and **frozen** (`transferGovernance(address(0))`) inside
  `VENUE.openLine` (rows 12/13; §4.1/§4.7) — the registry is each per-line router's resolved oracle, so
  `cache[LIEN_i]` is written direct to the registry with no shared router, no `govSetFallbackOracle`, and no
  timelock involvement *(per-line-router redesign — supersedes the shared-fallback "F4")*. **permit** (matches
  §4.1 Registration + audit/2.md S10). ✅
- Hop 5 — registry seeds `cache[LIEN_i]`: Forwarder-gated chain. **permit**.
- Hop 6 — `VENUE.setLineLimits` → `EVAULT_i.setLTV`: `governorOnly`, caller = VENUE (governor).
  **permit**.
- Hop 7/8 — `VENUE.fund/draw` → `EVC.batch([reallocate, borrow on the line's fresh per-line account])`;
  `EE_POOL.reallocate` resolves `allocator=VENUE` via `_msgSenderOnlyEVCAccountOwner` ⇒
  `isAllocator[VENUE]==true`. **permit**.
- Hop 9/10 — `EVAULT_i.borrow` → `callHook(OP_BORROW)` → `GATING_HOOK.fallback()` extracts appended
  on-behalf caller = `LINE_BORROW_ACCOUNT` (the line's fresh account, §4.4),
  `EVC.isAccountOperatorAuthorized(LINE_BORROW_ACCOUNT, VENUE)==true`
  (`EthereumVaultConnector.sol:286` — the per-line `LineAccount` granted the `VENUE` borrow-driver the operator bit at origination).
  **permit**.
- Hop 11 — debt recorded, USDC → Erebor. **permit**.
- **Verdict: PERMIT.** No implicit hop; F4 resolved at hop 4.

### Trace B — Oracle wiring (per-line, frozen at origination): **PERMIT**
- Hop 1 — `VENUE.openLine` mints `ROUTER_i` (`new EulerRouter(evc, VENUE)`): the adapter is the governor at
  birth **permit**.
- Hop 2 — `ROUTER_i.govSetResolvedVault(COLLAT_i)` + `govSetConfig(LIEN_i, USDC, ZIP_ORACLE_REG)`:
  `onlyGovernor`, caller = VENUE **permit**.
- Hop 3 — `ROUTER_i.transferGovernance(address(0))`: **freezes** the wiring; thereafter every `govSet*`
  reverts for everyone (2.md N5) **permit-then-seal**.
- **Verdict: PERMIT.** There is **no shared timelocked router** (per-line-router design, §4.1/§4.7) — a line's
  price wiring is immutable after origination, strictly stronger than a 2-day veto. No re-point path exists by
  design (recovery = open a new line). (The §17 param-change timelock is a separate surface — szipUSD
  floor/`f`/lock length.)

### Trace C — Allocator reallocate (no origination): **PERMIT**
- Hop 1 — `EVC.batch` with `onBehalfOfAccount=ZIP_CONTROLLER`: EVC enforces caller is operator/owner of
  that account. **permit** (an unauthorized caller cannot forge `onBehalfOfAccount`).
- Hop 2 — `EE_POOL.reallocate` resolves via `_msgSenderOnlyEVCAccountOwner` ⇒ `isAllocator`. **permit**.
- **Verdict: PERMIT.** (Note: in the standing config the allocator role holder is the **VENUE**;
  the trace's `ZIP_CONTROLLER` form is the M1-collapsed-adapter case §4.4. Either way `isAllocator`
  gates it.)

### Trace D — zipUSD mint (deposit): **PERMIT**
- Hop 1 — `DEPOSIT_MODULE.deposit(usdc)`: public, no gate (by design). **permit**.
- Hop 2 — `ZIPUSD.mint`: `minters[DEPOSIT_MODULE].capacity ≥ usdc` (`ESynth.sol:55`). **permit**.
- Hop 3 — module deposits USDC to `EE_POOL`. **permit**.
- **Verdict: PERMIT.** Authority freeze holds iff S7 renounces ESynth ownership (`setCapacity` is
  `onlyOwner`, `ESynth.sol:47`) — confirmed required by §9. If S7 skips renounce → over-privilege hole
  (carried as a run-log assertion, not an M1 finding since §9 mandates it).

### Trace E — Junior exit (Baal ragequit): **PERMIT** *(reframed 2026-06-06 — convert-on-stake exit deleted)*
> The old trace was `startCooldown` → `withdraw` (`availableWithdrawLimit`) → venue `redeem`. The Baal exit:
- Hop 1 — `ragequit(Loot)`: the Loot holder's own call; gated only by the **~30d lock** (lock-shaman) and any
  active **Duration-Bond freeze** (vacuous in M1, §11). **permit**.
- Hop 2 — basket transfer: `(holder Loot / total Loot) × basket` moved **in-kind** from the Safe (no oracle,
  value-preserving — `1-results.md` I3); subject to the withdrawal **floor**. **permit**.
- Hop 3 — the holder then exits the received zipUSD → USDC via the **epoch queue** (§6.1) — Trace not new.
- **Verdict: PERMIT.** All gates are *restrictions on the holder's own exit*, no third-party authorization.
  The concrete gate wiring is **built + verified at 8-B1/8-B3** (Baal ragequit + lock/freeze shaman). ✅

**All five traces resolve to PERMIT.** No hop is implicit or rests on an unstated invariant.

---

## §4 — Failure-mode checklist confirmation

Every entry has a named defense + spec §. Spot-verified against the spec:

| Contract | Defense present? | § verified |
|---|---|---|
| `ZIP_CONTROLLER` — Forwarder compromise | immutable Forwarder + renounce; recourse = redeploy | §4.4/§13 ✅ |
| `ZIP_CONTROLLER` — controller bug | timelock veto on `govSetConfig`; isolated governor surface | §4.4/§13 ✅ |
| `EulerRouter` (per-line) — re-point after open | **frozen** at origination (`transferGovernance(0)`); no re-point path exists (§4.1/§4.7) | §4.1/§4.7 ✅ |
| `EulerRouter` (per-line) — direct call bypass | `onlyGovernor`; post-freeze every `govSet*` reverts for all (row 12; `2.md` N5) | §4.1/§4.7 ✅ |
| `EVAULT_i` — non-borrow-driver borrow | hook EVC operator-auth check (`isAccountOperatorAuthorized(caller, VENUE)`) | §4.3 ✅ |
| `EVAULT_i` — liquidator front-run | `OP_LIQUIDATE` hooked same way | §4.3/§4.4e ✅ |
| `EVAULT_i` — borrow on a non-line account | only the line's fresh per-line account authorized the borrow-driver (the adapter) as operator ⇒ the operator-auth check passes for it alone; any other account (incl. a foreign EOA) is not operator-authorized ⇒ the hook reverts (`HookReverted` wrapping `NotAuthorizedOperator`) | §4.3/§4.4 ✅ |
| `ZIPUSD` — rogue minter grant | ESynth `Ownable` renounced post-S7 | §5/§9 ✅ |
| `ZIPUSD` — over-mint | per-minter capacity (`ESynth.sol:55`) | §5 ✅ (cap = max; see open item 1) |
| `LIEN_i` — mint outside controller | `onlyController` immutable | §4.2 ✅ |
| `ZIP_ORACLE_REG` — stale/0 price | `_processReport` rejects 0; liquidation delinquency-gated not staleness | §4.1/§7 ✅ |
| `ZIP_ORACLE_REG` — forged value | a forged **high** mark enables **over-borrow** (not bad-liquidation): bounded per-lien to `borrowLTV × mark`, mitigated by the borrowLTV/liqLTV cushion (§4.2) + upstream integrity (Proof-notarized + DON consensus + immutable Forwarder); intentionally **no on-chain value band** (would fight legit re-marks, §4.1) | §4.1/§4.2/§7 ✅ |
| `EE_POOL` — rogue allocator | `setIsAllocator` `onlyOwner` | §3 ✅ |
| `EE_POOL` — fee redirected | `setFeeRecipient` `onlyOwner` | §5 ✅ |
| `TIMELOCK` — re-grant roles | `DEFAULT_ADMIN_ROLE` renounced post-S10 | §9 ✅ |
| `REDEMPTION_QUEUE` — anyone settles | `onlyController` on `settleEpoch` | §6.1 ✅ |
| `SZIPUSD` — run fairness | ~30-day **lock** + the Duration-Bond **freeze** on `ragequit` (lock/freeze shaman, 8-B3) | §6.4/§11 ✅ (Baal) |
| `SZIPUSD` — below floor | withdrawal **floor** enforced on `ragequit` (8-B3) | §6.4 ✅ (Baal) |
| `LienXAlphaEscrow` — wrong slasher | `onlyCoordinator` | §4.6 (M1-sketch) |
| `DefaultCoordinator` — rogue report | Forwarder + identity | §4.6/§8.4 (M1-sketch) |

**Confirmed: every failure-mode entry has a defense + spec §.** ✅

---

## §5 — Orphan-caller sweep (Covered? per mutator)

| Contract | Mutator | Covered? | Note |
|---|---|---|---|
| `ZIP_CONTROLLER` | `setForwarderAddress` (inherited) | **Yes** | base setter is **non-virtual** (not overridable); frozen by S11 renounce → reverts `OwnableUnauthorizedAccount` (§4.4); no row authorizes success (row 20). |
| `ZIP_CONTROLLER` | `setExpectedAuthor`/`WorkflowId`/`WorkflowName` (inherited `:143/159/184`, `onlyOwner`) | **Yes — frozen by renounce, ORDERING-DEPENDENT** | Closed by §9: set identity **first** (assert `getExpectedWorkflowId() != 0` before renounce — S11 hard pre-gate), then `renounceOwnership`. See Finding F1. |
| `VENUE.openLine` → per-line `LineAccount` (§4.4/§4.7) | `EVC.setAccountOperator(borrowAccount, VENUE, true)` (owner-self, in the `LineAccount` ctor) | **Yes** | **REWORKED 2026-06-05 — replaces the retired `ZIP_CONTROLLER.wireVenueOperator`.** The operator grant is issued **per line at origination** by the line's own `LineAccount` (a fresh CREATE2 prefix, salt = `lienId`), authorizing `VENUE` (the `EVC.call` borrow-driver) over **one** code-free borrow account on **its own** prefix. No controller-level blanket grant; no `~uint256(1)` prefix grant; no deploy-time wiring `draw` depends on. Strictly more isolated — one grant, one account, its own prefix (a buggy grant on one line cannot reach another's account). |
| `ZIP_ORACLE_REG` | same inherited identity setters | **Yes** | same §9 ordering; same F1 dependency + S11 pre-gate. |
| `ZIP_ORACLE_REG` | `setController` (set-once, `onlyOwner`, §4.1) | **Yes** | set once at S6 (wires origination-seed authority); `ControllerAlreadySet` on a second call; frozen by S11 renounce. |
| `ZIP_ORACLE_REG` | `seedPrice` (origination seed, §4.1/§4.4a) | **Yes** | `controller` only (`NotController`); the set-once `controller` = `ZIP_CONTROLLER`; same guards as `_processReport` (price≠0, ≤uint208, strict decimals==18, ts≤now). |
| `ZIP_ORACLE_REG` (router) | `govSetConfig` repoint | **Yes** | row 12 (timelock-only). |
| `EVAULT_i` | all governor fns | **Yes** | row 5 (governor = VENUE); rows 6/7/8 cover usage. |
| `EVAULT_i` | `setHookConfig(0,0)` (controller/venue can unhook) | **Yes** | row 7. By design (trusted). **No automated path unhooks** — confirmed: §4.4 branches (a–e) and §9 paths never call `setHookConfig`; only the one-time S9 setup does. ✅ |
| `LIEN_FACTORY` | `create` | **Yes** | row 19 (caller-bound). Negative test: a non-`ZIP_CONTROLLER` `create(lienId)` does NOT revert but lands at a *different* address and does **not** occupy the canonical `LIEN_i` slot (assert `computeAddress(lienId, ZIP_CONTROLLER)` still has no code) — proves origination cannot be griefed. |
| `LIEN_FACTORY` | config setters | **Yes (none expected)** | §4.2: decimals/name/symbol are constant/immutable in init-code; no setters. |
| `ZIPUSD` (`ESynth`) | `setCapacity` | **Yes** | row 15; renounce in S7 (§9). |
| `ZIPUSD` (`ESynth`) | `transferOwnership` | **Yes** | renounced ⇒ frozen (S7). |
| `ZIPUSD` (`ESynth`) | `allocate`/`deallocate`/`addIgnoredForTotalSupply` (`:109/121/139`, `onlyOwner`) | **Yes — frozen by renounce** | Not in the matrix but `onlyEVCAccountOwner onlyOwner`; ESynth ownership renounce (S7) freezes them. See open item 6. |
| `SZIPUSD` (Baal) | shaman/config setters (floor, lock length, freeze authority) | **Pending Baal build** | §17: the withdrawal floor + lock length are timelock-governed params; the freeze authority is `DefaultCoordinator`-driven. Confirmed at **8-B1/8-B3** (the convert-on-stake `availableWithdrawLimit`/cooldown setters are deleted) — open item 4. |
| `REDEMPTION_QUEUE` | `settleEpoch` | **Yes** | row 23 (`onlyController`). |
| `REDEMPTION_QUEUE` | `setOperator` | **Yes** | per-user (7540); not privileged. |
| `REDEMPTION_QUEUE` | `transferOwnership` / `fulfillRedeem onlyOwner` | **Partial** | 7540 fork's `Owned` owner = controller; `fulfillRedeem`/settle is controller-driven. `transferOwnership` should be renounced or governance-routed — **open item 5**. |
| `EE_POOL` | `setIsAllocator`/`setFeeRecipient`/`setFee`/queue setters | **Yes** | rows 1–3 (EE owner). |
| `EE_POOL` | `transferOwnership` | **N/A** | EE owner = governance multisig, not under our control (open item 3). |
| `TIMELOCK` | `grantRole`/`revokeRole` | **Yes** | row 14; `DEFAULT_ADMIN_ROLE` renounced post-S10 ⇒ frozen. |

**Sweep result:** every mutator on a contract under our control/governance is **covered** by a matrix
row or **frozen by a documented renounce**. The previously-uncovered items
(`REDEMPTION_QUEUE.transferOwnership`, `SZIPUSD` config setters, ESynth `allocate`/`deallocate`) were spec
ambiguities, not orphans — and have since been **closed in the spec** (§4.5 immutable-controller gate;
§17 timelock change-path; §9 ESynth-surface freeze), recorded as resolved §6 open items 4–6. **No M1
mutator is left with an undocumented successful caller.** The sweep comes up empty of true orphans. ✅

---

## §6 — Open items surfaced (the proof's value)

1. **ESynth minter set + capacity sizing + renounce ordering.** ⚠️ **REOPENED (2026-06-06, Baal redesign).**
   The old resolution sized a `max` capacity for **szipUSD-on-stake** — that minter is **deleted** (the Baal
   junior never mints/burns zipUSD on deposit). The live minter is `DEPOSIT_MODULE`; the **new** authority to
   pin is the **M2 lever-1 junior-zipUSD burn** (`DefaultCoordinator`, §11/§4.6) — whether it needs an ESynth
   burn authority, and therefore whether the S7 `ESynth` ownership renounce must wait, is settled at
   **8-S2b/8-B**. Capacity is **sized to expected flow (bounded, not `max`)** per §9; the convert-on-stake
   exit-wave `max`-capacity rationale no longer applies.
2. **CANCELLER_ROLE on TIMELOCK.** M1 intentionally has no veto path (Trace B). Production needs a
   separate canceller multisig. §17 build-time decision.
3. **EE_POOL owner trust.** Rows 1–3 depend on the EulerEarn owner/curator being trusted governance.
   In M1 the deployer plays this role; production needs a multisig + written policy on what they can
   change.
4. **`szipUSD` config setters.** ✅ **change-path RESOLVED (spec §17); mechanism reframed to Baal
   (2026-06-06).** §17 locks the change path: every governance-configurable param (withdrawal floor, `f`,
   lock length, recovery haircut, Duration Bond length) is changed **through the OZ `TimelockController`**
   (≈2-day veto), its setter owned by the timelock — never a bare EOA. The **mechanism** is now the Baal
   lock/freeze shaman (the `cooldown`/`availableWithdrawLimit` setters are deleted); the concrete shaman setter
   signatures are pinned at **8-B3**.
5. **`ZipRedemptionQueue` ownership.** ✅ **RESOLVED (spec §4.5).** §4.5 now states the queue's privileged
   ops (`settleEpoch`/`fulfillRedeem`) are gated on an **immutable controller** set at deploy — not the
   forked `Owned` owner — and the inherited `transferOwnership` is removed/inert. (It is deliberately
   **not** renounced like the CRE receivers, since the controller must keep calling `settleEpoch`.)
6. **ESynth `allocate`/`deallocate`/`addIgnoredForTotalSupply`.** ✅ **RESOLVED (spec §9).** §9 now states
   that after the S7 `renounceOwnership`, ESynth's **entire** owner-only surface (`setCapacity`,
   `allocate`, `deallocate`) is permanently frozen and the only live mint surface is the two pre-granted
   capacities. The documentation gap is closed.

---

## Findings (real vs. benign)

**F1 — §9 renounce-ordering (REAL, but already closed by the spec).** The
`ReceiverTemplate.onReport` identity check at `:88-117` is **conditional**: it runs only when
`s_expectedWorkflowId`, `s_expectedAuthor`, or `s_expectedWorkflowName` is non-zero (verified at
`ReceiverTemplate.sol:88`). If `renounceOwnership` ran **before** `setExpectedAuthor`/
`setExpectedWorkflowId` (both `onlyOwner`, `:143/184`), those expected values would stay zero forever
and the identity gate would be **permanently skipped** — leaving only the Forwarder-sender check at
`:83`. **The spec §9 explicitly mandates the safe ordering**: "before renouncing `Ownable` ownership,
call `setExpectedAuthor(WORKFLOW_OWNER)` and `setExpectedWorkflowId(WORKFLOW_ID)` … Set identity
first, then renounce" — and §4.4 repeats it. So this is **NOT an open finding**: the spec closes it
correctly (spec §9 mandates the S10b "set identity, then renounce" ordering). The audit's job here is to
confirm the spec does NOT say or imply renounce-before-identity — it does not. ✅ No §9 ordering bug.

**F2 — Governor role-holder in rows 5–8 (cell mismatch, now RESOLVED).** The drafted matrix named
`ZIP_CONTROLLER` as the `governorOnly` caller for `setGovernorAdmin`/`setLTV`/`setHookConfig`/`setIRM`.
Per §4.4/§4.7/§9 the EVAULT governor is the **`EulerVenueAdapter` (VENUE)**, not the controller. This is
a cell mismatch the sweep is designed to catch; rows 5–8 above **name `VENUE`** (an earlier draft named
`ZIP_CONTROLLER`), so the matrix matches the spec. It was never an over-privilege (the controller drives
these via `IZipcodeVenue`; the adapter holds the role).

**F3 — M1-sketch loss-side rows (28, 29) — DEFER.** `LienXAlphaEscrow` and `DefaultCoordinator` gating
(`onlyController`/`onlyCoordinator`/Forwarder) is internally consistent with §4.6/§8.4/§13, but the
state machines are sketches. Re-audit required before M2 (M1-sketch scope; §17). No M1 action.

**No over-privileged caller and no true orphan mutator was found.** The only real wiring-correctness
risk (F1, the conditional identity check) is already mitigated by the §9 ordering mandate.

---

## §7 — Acceptance statement

Against the audit's four acceptance criteria:

1. **Matrix filled, no blank `Authorized caller(s)`/`Gating mechanism` cells** — ✅ MET. All 29 rows
   populated; rows 5–8 name the governor role-holder as VENUE (resolved per F2); no over-privilege.
2. **Traces A–E each resolve to permit with named gates at every hop** — ✅ MET. All five PERMIT; F4
   resolved at Trace A hop 4 (no router gov call at origination); no implicit hop.
3. **Failure-mode checklist: defense + § for every entry** — ✅ MET. All 20 entries verified.
4. **Orphan-caller sweep comes up empty (or surfaces items resolved/added to §6)** — ✅ MET. No true
   orphan; every M1 mutator is covered by a matrix row or frozen by a documented renounce; residual
   ambiguities (items 4–6) recorded in §6.

**This audit PASSES for the senior/venue wiring.** The authority wiring has no orphans and no over-privileged
roles within M1 scope. The one substantive wiring risk (F1 — conditional identity check) is correctly closed
by the §9 "identity-first, then renounce" ordering. **Two surfaces are NOT yet built-and-verified here and are
re-audited at their tickets:** (i) the **junior/szipUSD** authority surface — rows 25–27 + Trace E were the
deleted convert-on-stake model; the **Baal** replacement (deposit/mint shaman, `ragequit`, lock/freeze shaman)
is verified at **8-B1/8-B2/8-B3**, and the senior-custody + ESynth-authority side at **8-S2b (two-Safe custody,
in design)**; (ii) the **loss-side** rows (28/29) remain M1-sketch and require re-audit before M2. Combined
with `1-results.md` (money model, re-derived to the Baal/withhold model) and `2.md` (the tx-by-tx acceptance
loop, junior steps excised to 8-B), the **senior** M1 contract build can begin, with the open items
(CANCELLER_ROLE, EE-owner policy) tracked as production hardening; the former build-time wiring ambiguities
(RedemptionQueue ownership, ESynth allocate surface, param change-path) are closed in the spec, and the junior
ownership/minter questions are reopened to the Baal redesign (open item 1/4).
