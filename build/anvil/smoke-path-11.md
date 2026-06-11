# SP-11 — Loss bond lifecycle (default provisioning)

**Intent.** Drive the loss side: lock an xALPHA bond at origination, mark a default (which writes a provision that
drops spot NAV), and resolve/slash the bond to the capital sink + sidecar.

**Proves.** `DefaultCoordinator.onReport` reportType 8 action family (Lock/Default/Resolve…); `writeProvision` is
coordinator-only and the sole NAV provision sink; `LienXAlphaEscrow` bond custody + slash routing.

**Tier.** Needs-forwarder (+ identity for the loss workflow).

**Binds to.** `DefaultCoordinator` `0xb6366c0d…`, `LienXAlphaEscrow` `0xfba6a2f0…`, `SzipNavOracle` `0x0C3E7731…`,
xALPHA `0xF6CAAF72…` (mint to escrow), capitalSink `0x99655…`, sidecar `0x39D22961…`. Source:
`contracts/src/loss/DefaultCoordinator.sol` (reportType-8 dispatch, `setEscrow` allowance), `contracts/src/loss/
LienXAlphaEscrow.sol` (`lockXAlpha`/`releaseXAlpha`/`slash…`), `SzipNavOracle.writeProvision` L246-251. Wires
`DefaultCoordinator.md`, `8-Bx-LienXAlphaEscrow.md`.

**Setup.**
- Establish a basket with supply (SP-06) so spot NAV is meaningful.
- `MockERC20(xALPHA).mint(<bond source>, bondAmount)`; ensure the coordinator/escrow can pull it (the coordinator
  force-approves the escrow on `setEscrow`).
- Build reports: `abi.encode(uint8(8), abi.encode(uint8 action, …))` per action; verify field shapes against source.

**Calls (impersonate Forwarder).**
1. LOCK (action 0): bond posted to escrow for a lienId.
2. DEFAULT (action 2): writes a provision into the NAV oracle.
3. Read `SzipNavOracle.spotNavPerShare()` before/after step 2.
4. RESOLVE/SLASH (action 4): bond routed to capitalSink + sidecar.
5. (negative) `SzipNavOracle.writeProvision(x) as non-coordinator` → revert `NotDefaultCoordinator`.

**Assertions.**
- after 1: `xALPHA.balanceOf(escrow) == bondAmount`.
- after 2: `spotNavPerShare()` dropped (provision subtracted from gross); coordinator's per-lien ledger shows the provision.
- after 4: `xALPHA.balanceOf(capitalSink)` and/or sidecar rose; escrow bond cleared.
- step 5 reverts.

**Notes.** First-loss = a pari-passu provision-that-recovers (§11). The provision is the only path that moves NAV
down; this proves the coordinator→oracle wiring is load-bearing.

**Result.** **PASS** (2026-06-10, real txs on anvil). The loss side drives end-to-end: bond lock → default provision (the sole NAV-down path) → resolve with capital/cohort slash routing. Wiring confirmed: DC = `oracle.defaultCoordinator` = `escrow.coordinator`; recoveryFloor = **0.5e18 (50%)**; capitalSink `0x9965507D`, sidecar `0x39D22961`.

Setup: minted 1000e18 xALPHA to the **coordinator** (the bond source; escrow pulls from it via the max allowance granted on `setEscrow`). lienId = `keccak("zipcode-sp11-bond-1")` = `0x8322bc08…`. Reports = `abi.encode(8, abi.encode(uint8 action, data))`.

1. **LOCK (action 0)** `(lienId, originator=erebor, 1000e18)` → `xALPHA.balanceOf(escrow)` 0 → **1000e18**; coordinator → 0; `bondAmount[lienId]` = 1000e18; status = **Bonded(1)**. ✓
2. spot NAV before default = **106.265e18**.
3. **DEFAULT (action 2)** `(lienId, atRisk=10000e18)` → provision = `atRisk·(1−recoveryFloor)` = **5000e18**; `oracle.provision()` 0 → **5000e18**, `DC.totalProvision` = 5000e18, status = **Defaulted(2)**. **spot NAV 106.265e18 → 100.015e18** = (85012−5000)/800 — the provision nets straight off gross. ✓
4. **RESOLVE (action 4)** `(lienId, capitalSlashAmount=600e18)` → provision healed to 0 (`oracle.provision` → 0), status = **Resolved(3)**; bond routed **capital-first** `slashXAlphaToCapital(600e18)` → **capitalSink 0 → 600e18**, then **cohort** `slashXAlphaToCohort(400e18 remaining)` → **sidecar 0 → 400e18**; escrow xALPHA + bondAmount both → **0**. **spot NAV → 106.765e18** = (85012+400)/800 — provision healed AND the 400e18 in-kind premium landed in the sidecar, so NAV rises *above* the pre-default 106.265e18: the §6.4 socialized cohort pro-rata happens automatically via NAV (no snapshot/index). ✓
5. (negative) `SzipNavOracle.writeProvision(1) as alice` → **`NotDefaultCoordinator` (0xdd00f130)**. ✓

No flaws. The coordinator→oracle wiring is load-bearing: `writeProvision` is the only path that moves NAV down (and it's coordinator-only), `totalProvision == oracle.provision()` held at every step, and the bond can flow only to capitalSink (realized hole) / sidecar (cohort premium) — destination integrity intact. First-loss is the pari-passu provision-that-recovers: default down-marks, resolution heals + pays the premium to stayers.

**State note:** capitalSink now holds 600e18 xALPHA; **sidecar holds 400e18 xALPHA** + 79,600e6 USDC (this xALPHA is now a basket/committed leg — later paths reading NAV will see it).
