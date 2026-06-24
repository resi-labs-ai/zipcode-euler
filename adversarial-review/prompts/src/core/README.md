# Core subsystem group — adversarial review prompts

> **Running a cycle?** Read `adversarial-review/CONDUCTOR.md` first — it's the step-by-step operating
> procedure (spawn missions, verify-before-promote, reconcile, ticket). This file is the map.

Mirrors the **loose top-level contracts of `contracts/src/`** — the protocol's portable core / control plane:
the CRE-driven orchestrator, the multi-pool federation catalog, the multi-asset price registry, the senior
solvency telemetry, the lien-token primitive + its CREATE2 factory, the EVK borrow gate, and the deploy-time
identity assertion. These are the contracts that sit at the top of `contracts/src/` (not under a subsystem
folder); their per-contract X-Rays live in `contracts/src/x-ray/` (the `src/`-root scope). Eight contracts,
~636 nSLOC, all rated **HARDENED** in their X-Rays.

One folder per contract; each holds `_boot.md` (shared context fed to every sub-agent for that contract) +
numbered mission files (`1.md`, `2.md`, …) + `context.files` (the inline file list for non-agentic panelists).
Mission count follows each contract's authored attack surface per its X-Ray — not a fixed number.

## The contracts (mirror `contracts/src/*.sol`; X-Rays in `contracts/src/x-ray/`)

| Contract | nSLOC | Missions | Surfaces (from the X-Ray) |
|---|---:|---:|---|
| `zipcodecontroller/` | 174 | 5 | atomic origination + dup-no-double-mint (I-1/I-10) · draw+close lifecycle (I-2/I-3) · report-type allow-list (I-4) · CTR-03 fail-closed routing + slot accounting + revolving (I-5/I-6/I-7) · identity/reentrancy/wiring (I-8/I-9/I-11) |
| `siloregistry/` | 150 | 4 | 6-clause topology web + admission guards + CTR-10b (I-1/I-2/I-3/I-11) · slot accounting cap/symmetry/onlyController (I-4/I-5/I-6) · lifecycle + UnknownSilo on all by-id (I-7/I-8/I-12/I-13) · owner gates + setController (I-9/I-10) |
| `zipcodeoracleregistry/` | 97 | 3 | two write paths + all-or-nothing batch + value/SEC-01 guards (I-2/I-3/I-4/I-6) · shared-scale + strict-18-dp + read path + no-value-band (I-1/I-5/I-7/I-8) · identity/renounce + the 3 Timelock setters (I-9/I-10/I-11) |
| `seniornavaggregator/` | 85 | 3 | donation immunity + per-silo read math (I-1/I-2/I-4/I-5) · aggregate semantics + breaker-safety `supply==0→max` (I-3/I-6/I-7) · fail-closed reads + CTR-10b venue-agnostic + wiring (I-8/I-9/I-10/I-11) |
| `cregatinghook/` | 64 | 3 | operator-auth gate + op-agnostic + selector KAT (I-1/I-4/I-5) · `isProxy` spoof guard + `isHookTarget` magic — the load-bearing crux (I-2/I-3) · build-phase admin + `setBorrowDriver` re-point (I-6) |
| `zipcodedeployasserts/` | 26 | 1 | the deploy-time fail-closed identity gate it defends with — author+name per receiver + registry controller seeded (I-1..I-6) |
| `lientokenfactory/` | 20 | 2 | caller-bound CREATE2 squat-proof + keying (I-1/I-2/I-3) · single-use-forever + cross-contract constants (I-4/I-5/I-6/I-7) |
| `liencollateraltoken/` | 18 | 2 | the 1/1 supply primitive + decimals pin + vanilla-OZ + venue reliance (I-1/I-2/I-5/I-7/I-8) · controller-only burn + ctor zero-guard (I-3/I-4/I-6) |

**Group total: 23 missions across 8 contracts.**

## The differential is the audited bases + the §4.4/§17 posture — these are ORIGINAL contracts
Unlike the bridge (diffed vs Rubicon) and hydrex-demo-fork (diffed vs their prod parents), the core contracts
have **no audited code parent to diff line-for-line**. The "supposed to be" baselines are the posture each X-Ray
encodes + the audited bases the contracts build on:
- **The orchestrator** (`ZipcodeController`) is the keystone — a `ReceiverTemplate` (CRE receiver, Timelock owner)
  that touches NO EVC; every venue effect crosses the venue-neutral `IZipcodeVenue` seam. Its three drill
  questions: is origination atomic (any mid-batch revert rolls back the CREATE2 deploys — no orphan lien/market),
  is routing fail-closed (draws/closes re-resolve from the line's STORED `siloId`, never a global pointer), and
  does the report-type allow-list hold (reportType 3 = revaluation, delivered direct to the registry, must NOT be
  processed here). All densely fork-tested against the real EVK/EVC/EulerEarn stack.
- **The federation catalog** (`SiloRegistry`) — a pure OZ `Ownable` catalog whose admission gate is a 6-clause
  topology web (a curator earns senior backing only by registering a self-consistent silo whose freeze/escrow/
  coordinator/adapter all point at its OWN pool/safe/oracle); `lineCount`/`active` are registry-managed, never
  caller-supplied. Venue-agnostic (CTR-10b) — it dereferences only the venue-neutral `ISeniorVenue.seniorPool()` +
  `ISeniorPool` slots.
- **The price registry** (`ZipcodeOracleRegistry`) — the EVK read-adapter (`BaseAdapter`) + CRE receiver
  (`ReceiverTemplate`) in one; the multi-asset sibling of `SzipFarmUtilityLpOracle`. One shared `scale` makes the
  strict-18-dp key guard load-bearing (a non-18-dp lien is unreachable by design); revaluation is all-or-nothing
  (a poison key reverts the whole batch); SEC-01 strictly-newer ts is the replay defense; no on-chain value band
  (integrity is upstream).
- **The solvency telemetry** (`SeniorNavAggregator`) — a pure-view donation-immune Σ of senior par-backing; reads
  `convertToAssets(balanceOf(warehouseSafe))`, NEVER `balanceOf(eePool)`, with the per-silo math lifted VERBATIM
  from `DurationFreezeModule` so the two never disagree. Telemetry, not pricing.
- **The lien primitive** (`LienCollateralToken` + `LienTokenFactory`) — a 1/1 fixed-supply OZ `ERC20` (1e18
  minted once, immutable controller, no mint path) deployed via a caller-bound CREATE2 factory (the init-code
  embeds `msg.sender`, so the address is squat-proof and single-use-forever). Uniquely in the subsystem these two
  carry NO build-phase mutable-wiring residual.
- **The infra** (`CREGatingHook`, `ZipcodeDeployAsserts`) — the EVK borrow gate (its load-bearing `isProxy`
  spoof guard, replicated verbatim from `BaseHookTarget`) and the deploy-time identity-gate library (the only
  defense against the F1/S11 dormant-identity vuln). Small, consumer-covered; soundness is the expected result.

## Pressure-test severity hard (carry into every synthesis)
- **Build-phase mutable wiring (§17)** — the Timelock-settable slots (`venue`/`registry`/`controller`/`quote`/
  `borrowDriver`/…) are frozen pre-prod. A bare re-point restatement is INFO unless it DRAINS or breaks an
  on-chain invariant. The sharpest one worth working: the `CREGatingHook.setBorrowDriver` re-point changes WHICH
  operator the gate authorizes against (already test-proven to re-target correctly).
- **Trusted, separately-X-rayed dependencies** — the CRE Forwarder (identity-gated), the venue adapter, the EVK
  `GenericFactory.isProxy` / EVC `isAccountOperatorAuthorized`, the EVK `ScaleUtils`/`BaseAdapter` math, the
  `ISeniorPool` 4626 surface, and the upstream Proof-of-Value producer + DON consensus. A finding must show THIS
  contract mis-USING an honest read/dependency, not "the dependency could lie."
- **Ratified design** — no on-chain value band on revaluation (integrity is upstream), CoW-only exit topology,
  retired silos still counted in `seniorBacking` (they back outstanding zipUSD), the controller touching no EVC
  (the per-line borrow is the adapter's job), the all-or-nothing revaluation (a per-key try/catch is deliberately
  omitted): all intentional. Don't re-report as gaps.
- A finding is HIGH/CRITICAL only if it breaks an on-chain guarantee: an orphan lien/market on a mid-batch revert,
  a double-mint, a line stranded/misrouted by a silo re-point, a non-18-dp key reaching the cache, a stale mark
  read as fresh, an account spoofing the borrow gate, a donation moving the solvency aggregate, or a drain.

These are among the **best-tested contracts reviewed** — the controller is fork-proven against the real
EVK/EVC/EulerEarn stack (43 tests); the registry's 6-clause web has each clause individually negated; the oracle's
guard matrix and the hook's spoof guard are exhaustively pinned. "Sound" is the expected result for most surfaces,
especially the thin token/factory/library bases — a manufactured finding is noise.

## Run
Per `CONDUCTOR.md`: prompts authored ✅ (this tree); X-Rays exist ✅ (`contracts/src/x-ray/` — per-contract files
are authoritative). Each mission's `context.files` inlines the contract + its base(s)/precedent + the externals it
drives + the test suite for non-agentic (Fugu) panelists. Reports/synthesis land under
`adversarial-review/reports/src/core/<contract>/` (gitignored scratch).
