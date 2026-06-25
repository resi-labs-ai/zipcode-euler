# SP-11 — Loss bond lifecycle (default provisioning) (seam S5/S6)

**Intent.** Drive the loss side: lock an xALPHA bond, mark a default (writes a provision that drops spot NAV), and
resolve/slash the bond to the capital sink + cohort.

**Proves.** `DefaultCoordinator.onReport` reportType 8 action family (Lock/Default/Resolve); `writeProvision` is
coordinator-only and the **sole NAV-down path** (S5); `LienXAlphaEscrow` bond custody + slash destination integrity
(S6); the LOSS-ADV-01 exact-amount JIT escrow allowance. Sources: `docs/loss.md` E-1/X-1/X-2,
`contracts/src/loss/x-ray/`, `SzipNavOracle.writeProvision`, wires `DefaultCoordinator.md`, `8-Bx-LienXAlphaEscrow.md`.

**Tier.** Needs-forwarder (loss workflow identity).

**Binds to** (by name): `DefaultCoordinator`, `LienXAlphaEscrow`, `SzipNavOracle`, xALPHA mirror, capitalSink, main
(engine) Safe. `recoveryFloor` = 0.5e18.

**Setup.** `seed_marks`; `zap(1_000e6)` (basket supply so NAV is meaningful); `xALPHA.mint(coordinator, 1000e18)`
(bond source — the escrow pulls via the JIT allowance). Reports = `abi.encode(8, abi.encode(uint8 action, data))`:
LOCK(0) `(bytes32 lienId, address originator, uint256 amount)`, DEFAULT(2) `(bytes32, uint256 atRisk)`,
RESOLVE(4) `(bytes32, uint256 capitalSlashAmount)`.

**Calls (happy).** 1. LOCK (lienId, erebor, 1000e18). 2. DEFAULT (lienId, atRisk=200e18). 3. RESOLVE (lienId, capitalSlash=600e18).

**Calls (fuzzy / negative).** 4. `SzipNavOracle.writeProvision(1)` as alice → `NotDefaultCoordinator`.

**Assertions** (On-chain=Yes): after LOCK, escrow xALPHA == 1000e18; after DEFAULT, `provision == atRisk·(1−floor)` and
`spotNavPerShare` drops by it; after RESOLVE, `provision` healed to 0, capital slash → capitalSink, remainder → the
engine Safe (cohort premium), escrow cleared; `DC.totalProvision == oracle.provision()` at every step; the non-coordinator
`writeProvision` reverts.

**Notes.** First-loss = a pari-passu provision-that-recovers (§11): default down-marks, resolution heals + pays the
cohort premium to stayers automatically via NAV (no snapshot/index). Bond destinations are restricted to
capitalSink (realized hole) / engine|treasury (cohort) — destination integrity (S6).

**Result.** **PASS** (2026-06-24, live fork; `recoveryFloor` 0.5e18; lien `0x8322bc08…`).
- **LOCK** → `LienXAlphaEscrow` xALPHA 0 → **1000e18** (coordinator → 0; exact-amount JIT pull). ✓
- **DEFAULT(atRisk=200e18)** → `provision` 0 → **100e18** (= 200·(1−0.5)); `spotNavPerShare` **1e18 → 0.9e18** (provision
  nets straight off gross). ✓
- **RESOLVE(capitalSlash=600e18)** → `provision` healed to **0**; **capitalSink** xALPHA 0 → **600e18** (realized hole);
  **engine Safe** xALPHA 0 → **400e18** (cohort premium remainder — the 2026-06-10 run routed this to the sidecar; the
  current router sends it to the engine Safe, both valid §6.4 cohort destinations); escrow → **0**. ✓
- `DC.totalProvision == oracle.provision()` held (0 after heal). **(neg)** alice `writeProvision(1)` reverted; provision
  stayed **0** (`NotDefaultCoordinator` 0xdd00f130). ✓ **No flaws** — provision is the sole, coordinator-only NAV-down
  path and bond destinations are integrity-bound.
