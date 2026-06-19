# CTR-12 — Rename `capitalSink` → `treasurySafe` (loss-side recovery destination)

> **DONE 2026-06-19.** Pure rename, zero behavior change. **Surface was STALER than the draft enumerated:** the
> draft listed `LienXAlphaEscrow`/`DefaultCoordinator`/3 deploy scripts/2 tests, but CTR-06b/06c (built earlier
> THIS session) added `capitalSink` to `script/SiloDeployer.s.sol` + `script/JuniorTrancheDeployer.s.sol` (Params
> struct field + ctor pass-through) and `test/{SiloDeployer,JuniorTrancheDeployer,DefaultCoordinator}.t.sol` — all
> swept in to satisfy Key-req #2 (zero `capitalSink` left). Triage = **ticket gap** (re-grepped the live tree, did
> not cite the draft's stale set blind). Renamed across 3 case variants: slot/var/field/getter `capitalSink`→
> `treasurySafe`, setter `setCapitalSink`→`setTreasurySafe`, env `CAPITAL_SINK`→`TREASURY_SAFE`, `WiringSet` slot
> label `"capitalSink"`→`"treasurySafe"`, test name `test_ctor_zero_capitalSink_reverts`→`..._treasurySafe_reverts`.
> Natspec/comments polished to name it "the protocol treasury Safe — the recovery custody (§11)". `slashXAlphaToCapital`
> / `SlashedToCapital` / RecycleModule "capital hole" prose UNTOUCHED (Do-NOT honored). **Gate green (full-suite,
> not just touched paths — per the CTR-08 process lesson, since the public getter `capitalSink()→treasurySafe()` is
> an ABI change):** `forge build` exit 0 + `forge test` = **920 passed / 0 failed / 3 skipped (56 suites)** —
> byte-identical to the CTR-10b baseline, proving the rename is behavior-neutral. `grep -rni capitalsink|capital_sink`
> over `src`/`script`/`test`/`docs` = NONE. Cold-build N/A (mechanical rename; no zero-guess builder needed — the
> risk was surface completeness, discharged by grepping the live tree). **Doc-sync:** backward wires
> `docs/wires/8-Bx-LienXAlphaEscrow.md` (slot/setter/WiringSet-label/4-arg-ctor/destination prose), `DefaultCoordinator.md`,
> `DeployZipcode.md` (`TREASURY_SAFE` env), `8-B10-RecycleModule.md` (the `treasurySafe` USDC-output reference);
> `docs/loss.md` was already on "treasury Safe". No `COVERAGE.md` change (no new file). No `claude-zipcode.md` edit
> (§11/§17 unchanged — the slot was never spec-named; the rename invents nothing). PROGRESS-433 "designate the real
> safe" closed at the NAMING level; the actual Safe creation + bridge process stays an M2 ops deliverable.

> Contract-track change (EXPANSION) — **loss-side, NOT part of the CTR-02..10 scaling workstream.** A naming +
> designation change: the slashed-bond capital-hole destination becomes the protocol **treasury Safe**, not an
> abstract "capital sink." This also resolves the PROGRESS-433 operational item (the destination was only a deploy
> placeholder) by naming it what it is — a designated treasury Safe. Mechanical rename across the loss contracts +
> deploy wiring + tests; no behavior change.
> Spec: `claude-zipcode.md` §11 (loss/recovery) / §17.

## Why
`slashXAlphaToCapital` routes the bond to `LienXAlphaEscrow.capitalSink` — the on-chain custody whose off-chain
process bridges xALPHA → TAO → USDC on Bittensor to cover a realized capital hole (`LienXAlphaEscrow.sol:24,61`).
Today that's a bare deploy-config placeholder (`i.capitalSink`/`CAPITAL_SINK`). Naming it **`treasurySafe`** makes
it explicit that it is the protocol's designated treasury Safe (a real Gnosis Safe), the recovery custody — and
designates the operational owner of the bridge/liquidation process.

## Deliverable
1. **`LienXAlphaEscrow.sol`** — rename the slot `capitalSink` → `treasurySafe`; the setter `setCapitalSink` →
   `setTreasurySafe`; the constructor arg `capitalSink_` → `treasurySafe_`; the `WiringSet("capitalSink", …)` slot
   label → `"treasurySafe"`; update all natspec (the destination is "the protocol treasury Safe — the recovery
   custody that bridges xALPHA → TAO → USDC to cover a realized capital hole, §11"). Keep the three-destination
   integrity thesis intact (`{bondOriginator, treasurySafe, cohortSink}` — note `sidecar`→`cohortSink` is CTR-11).
2. **`DefaultCoordinator.sol`** — update the natspec reference (`:33` "immutable `capitalSink`") to `treasurySafe`.
3. **Deploy wiring** — `DeployZipcode.s.sol`/`DeployLocal.s.sol`/`DeployMainnet.s.sol`: `i.capitalSink` →
   `i.treasurySafe`; the env var `CAPITAL_SINK` → `TREASURY_SAFE`; `contracts/script/RUNBOOK-mainnet-deploy.md`
   checklist row.
4. **Tests** — `contracts/test/LienXAlphaEscrow.t.sol` + `contracts/test/DeployZipcode.t.sol`: rename the local
   vars/asserts.

## Spec §
`claude-zipcode.md` §11 / §17. Conclude doc-sync: `wires/8-Bx-LienXAlphaEscrow.md` + `docs/loss.md` (the summary
already updated to "treasury Safe" alongside this ticket).

## Binds to (verified)
- `LienXAlphaEscrow.sol` — `capitalSink` slot/`setCapitalSink`/ctor/`SlashedToCapital`/natspec (the grep set;
  primary surface). `DefaultCoordinator.sol:33` natspec mention. Deploy: `DeployZipcode.s.sol`/`DeployLocal.s.sol`/
  `DeployMainnet.s.sol` (`i.capitalSink`, `CAPITAL_SINK`). Tests: `LienXAlphaEscrow.t.sol`, `DeployZipcode.t.sol`.
- No interface (`ILienXAlphaEscrow`) exposes `capitalSink` (grep-confirmed) — so no interface change.

## Starting state
- `capitalSink` is the wired slot + `setCapitalSink` setter (Timelock-settable) routing `slashXAlphaToCapital`.
  Built, mock-tested, M2-live. CTR-11 (cohort → main Safe) is a sibling loss-side rename/retarget.

## Do NOT
- Do NOT change `slashXAlphaToCapital`'s behavior or the `SlashedToCapital` event semantics — only the destination
  *name*. (Keep `slashXAlphaToCapital`/`SlashedToCapital` as-is — they describe covering the capital hole, still
  accurate; renaming the function/event is out of scope.)
- Do NOT touch `RecycleModule`'s "capital hole" prose (`:45,278`) — that's the concept, not the slot.
- Do NOT merge with CTR-11 — separate concerns (CTR-11 is the cohort/sidecar destination; this is the capital one),
  but both land cleanly together if sequenced.

## Key requirements
1. **Pure rename, no behavior change** — every test passes with the renamed symbols; the slash still routes to the
   same address, now called `treasurySafe`.
2. **Complete** — no `capitalSink`/`CAPITAL_SINK` left in `src`/`script`/`test` (except `RecycleModule`'s unrelated
   "capital hole" concept prose).
3. **Timelock-settable preserved** — `setTreasurySafe` is `onlyOwner`, zero-guarded, evented.

## Done when (gate — `forge test`)
- `forge build` green; `forge test` green (the renamed escrow + deploy tests). `grep -rn capitalSink contracts/`
  returns only the `RecycleModule` concept prose. Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** nothing (mechanical, self-contained). Sequences cleanly with CTR-11.
- **Unblocks:** clarity that the recovery destination is the designated treasury Safe (closes the PROGRESS-433
  "designate the real safe" operational item at the naming level; the actual Safe creation + bridge process stays
  an M2 ops deliverable).
