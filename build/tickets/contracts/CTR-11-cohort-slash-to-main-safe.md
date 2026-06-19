# CTR-11 — Route the cohort-premium slash to the main Safe (not the sidecar)

> Contract-track change (EXPANSION) — **loss-side, NOT part of the CTR-02..10 scaling/federation workstream.**
> The escrow's cohort-premium slash currently parks xALPHA in the sidecar, where no flywheel module can reach it,
> so the premium sits inert. Retarget it to the engine/main Safe so the existing yield flywheel subsumes it. This
> ticket is the CONTRACT half only; the slash-triggered CRE flow that processes it stays M2 (KEEPER-01b/CRE-01).
> Spec: `claude-zipcode.md` §4.6 (Duration-Bond premium) / §11 (loss machinery) / §17.

## Why (the verified gap)
`LienXAlphaEscrow.slashXAlphaToCohort` sends the remaining bond to `sidecar` (`contracts/src/loss/LienXAlphaEscrow.sol:213`).
But every flywheel module is enabled on the **engine Safe** (`SellModule`: `avatar == target == engineSafe`,
recipient pinned to `engineSafe`, `contracts/src/supply/szipUSD/SellModule.sol:40-114`; same for
`LpStrategyModule`), and `engineSafe == mainSafe` (`DeployLocal.s.sol:201`) — a *different* Safe from the sidecar.
So premium xALPHA in the sidecar is unreachable by the modules that would sell it for zipUSD / fold it into LP — it
just accumulates. Decision (2026-06-18, PROGRESS 422): route it to the main/engine Safe so the existing flywheel
subsumes it the same way emissions are subsumed (`SellModule` already does the `zipUSD↔xALPHA` POL swap).

## Deliverable
Modify `contracts/src/loss/LienXAlphaEscrow.sol`:
1. Replace the `sidecar` destination slot with a **properly-named `cohortSink` slot wired to the engine/main Safe**
   (NOT the sidecar slot repurposed). Update the constructor arg, the `setSidecar` setter → `setCohortSink`
   (`onlyOwner`, Timelock, `WiringSet`), and the `ZeroAddress` guards.
2. `slashXAlphaToCohort` transfers `remaining` to `cohortSink` (the main Safe) instead of `sidecar` (`:213`).
3. Update the natspec: the three fixed destinations are now `{bondOriginator, capitalSink, cohortSink}`; **drop the
   "never market-sold / NAV does the cohort pro-rata in-kind" framing** — the premium is now liquid in the main
   Safe and the flywheel sells it. Keep the destination-integrity thesis (no caller-chosen recipient).

## Spec §
`claude-zipcode.md` §4.6 (the cohort/Duration-Bond premium), §11, §17. Conclude doc-sync: `wires/8-Bx-LienXAlphaEscrow.md`
+ the `docs/loss.md` summary line that describes the in-kind sidecar routing (it currently says the premium goes
in-kind to the sidecar — see `docs/loss.md`).

## Binds to (verified)
- `LienXAlphaEscrow.sol` — the `sidecar` slot + `setSidecar` + `slashXAlphaToCohort` (`:63-65,140-144,206-216`), the
  three-destination security thesis natspec (`:35-42`).
- `SellModule` engine-Safe locality (`contracts/src/supply/szipUSD/SellModule.sol:40-114`); `engineSafe == mainSafe`
  (`DeployLocal.s.sol:201`).
- Test: `contracts/test/LienXAlphaEscrow.t.sol` (the cohort-slash destination assertions).

## Starting state
- `slashXAlphaToCohort` → `sidecar` (built, mock-tested, M2-live). The slash flow as a whole is M2 (the
  `DefaultCoordinator` driver = CRE-01 rt8). The custody half (`lockXAlpha`/`releaseXAlpha`) is M1-live.

## Do NOT
- Do NOT repurpose the `sidecar` slot — add a distinct `cohortSink` (clarity; the sidecar is a freeze concept, this
  is a loss-premium destination).
- Do NOT change `slashXAlphaToCapital` (the capital-hole path → `capitalSink`) — only the cohort path moves.
- Do NOT add a caller-chosen recipient — `cohortSink` is set-once-wired (Timelock), self-enforced, same as today.
- Do NOT build the slash-triggered CRE flow here — that's M2 (KEEPER-01b/CRE-01); this is the destination only.

## Key requirements
1. **Destination = main Safe.** `slashXAlphaToCohort` lands xALPHA in the engine/main Safe; a test asserts the main
   Safe's xALPHA balance rises by `remaining` and the sidecar's does not.
2. **§4.6 pari-passu preserved.** The NAV oracle sums BOTH Safes for the xALPHA leg, so the cohort still accretes
   per-share pari-passu via gross NAV regardless of which Safe holds it — confirm `SzipNavOracle.grossBasketValue`
   counts main-Safe xALPHA (it does; both Safes). The only change is committed→free.
3. **Freeze-floor unaffected.** Premium now lands in FREE value (a movable plain leg), not the committed sidecar
   bucket; gross NAV unchanged, and the freeze can still `commit` it if needed (xALPHA is one of the 5 movable
   legs). Confirm no `requiredCommittedValue`/`coverageValue` regression.
4. **Deploy wiring (note, not built here):** `DeployZipcode`/`SiloDeployer` must wire `cohortSink = engine/main
   Safe`, and the §11 non-commingling asserts shift (the cohort destination is now the main Safe, intentionally).

## Done when (gate — `forge test`)
- `forge build` green; `contracts/test/LienXAlphaEscrow.t.sol` updated + green: cohort slash lands in the main Safe
  (not sidecar); `setCohortSink` gated + evented + zero-guarded; `slashXAlphaToCapital` unchanged; the
  three-destination integrity still holds.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** nothing (self-contained contract change; safe to land before the M2 CRE flow — rerouted xALPHA is
  swept by the normal harvest cadence vs stranded in the sidecar today).
- **Unblocks:** the M2 slash-premium-into-yield flow (KEEPER-01b/CRE-01) — the premium now lands where the flywheel
  can process it.
