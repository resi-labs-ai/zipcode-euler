# CTR-06a — ReservoirMarketDeployer: hand the borrow vault governor to the Timelock

> Contract-track fix (one line + post-assert). Split from CTR-06 (index: `CTR-06-silo-deployer.md`). Discharges
> **FE-07 Finding A** (PROGRESS "Open obligations", logged 2026-06-11). Independent — no other CTR dep; a true
> prerequisite of every silo's reservoir market (CTR-06c builds the market per silo via this script).
> Spec: `claude-zipcode.md` §17 (Timelock-settable-not-frozen) / §4.5.1 (the reservoir market).

## Why (the seam)
`ReservoirMarketDeployer.deploy` (`contracts/script/ReservoirMarketDeployer.sol:54-89`) transfers ONLY the **router**
governance to the Timelock (`EulerRouter(router).transferGovernance(p.governor)`, `:88`) and renounces the **escrow**
vault governor to zero (`IEVault(escrowVault).setGovernorAdmin(address(0))`, `:61`, deliberate — a bare holding box).
But the **USDC borrow vault** is created via `factory.createProxy(address(0), ...)` (`:77`), so its `governorAdmin`
defaults to the throwaway `ReservoirMarketDeployer` INSTANCE and is **never re-pointed** — it strands there. The
Timelock therefore cannot tune the reservoir borrow vault's LTV / caps / IRM, directly contradicting the contract's
own header (`:13-14` "the GOVERNOR IS RETAINED on both the router and the borrow vault") and `:75` ("Governor RETAINED
so the Timelock can tune LTV/caps"). §17 requires this wiring be Timelock-governed.

## Deliverable
In `contracts/src/.../script/ReservoirMarketDeployer.sol`, inside `deploy(Params calldata p)`:
1. After the borrow-vault config (the `setLTV` at `:82`) — alongside the router transfer at `:88` — add:
   `IEVault(borrowVault).setGovernorAdmin(p.governor);` so the Timelock governs the borrow vault.
2. Fix the two now-true-after-the-fix comments so they describe the code: `:13-14` and `:75` already CLAIM "governor
   retained on the borrow vault" — after this fix they are correct; leave them, but add a one-line note at the new
   call site that this is the §17 borrow-vault governor handoff (the escrow stays renounced by design, `:61`).
3. No change to the escrow (`setGovernorAdmin(address(0))` at `:61` is intentional — collateral holding box, no
   governance) and no change to the router transfer.

## Spec §
`claude-zipcode.md` §17 (every cross-component pointer Timelock-settable, not frozen at deploy) / §4.5.1 (reservoir).

## Binds to (verified)
- `IEVault.setGovernorAdmin(address)` — `reference/euler-vault-kit/src/EVault/IEVault.sol:481` (real; impl
  `Governance.sol`). `IEVault.governorAdmin() returns (address)` — `:370` (real, view).
- The call site: `ReservoirMarketDeployer.sol:54-89`; the borrow-vault create at `:77`, the existing router transfer
  at `:88`, the intentional escrow renounce at `:61`.
- Param `p.governor` is the Timelock (`DeployZipcode.s.sol:364` passes `address(d.timelock)`; `DeployLocal.s.sol:196`
  same).

## Starting state
- `ReservoirMarketDeployer` is a per-deployment script contract (constructed fresh in `DeployZipcode._phaseP5`,
  `DeployLocal._phaseP5`, and the tests `ReservoirLoopModule.t.sol:231` / `AlgebraIchiFairLpOracle.t.sol`).
- The existing fork deployment (silo #0 on anvil) already has a stranded borrow-vault governor — see "Do NOT".

## Do NOT
- Do NOT touch the escrow vault's `setGovernorAdmin(address(0))` (`:61`) — intentional (a no-governance holding box).
- Do NOT renounce the borrow vault to `address(0)` — it must be the Timelock (§17, the standing-tunable facility).
- Do NOT attempt to retroactively fix the ALREADY-DEPLOYED anvil borrow vault from this script. The fix is for all
  FUTURE deploys; the live fork market's stranded governor is reclaimed only by a redeploy (the FE-07 row already
  says "re-read `governorAdmin()` and update `entities.json` after any redeploy"). Note this in the Conclude.

## Key requirements
1. **One-line governor handoff.** `IEVault(borrowVault).setGovernorAdmin(p.governor)` added; the Timelock governs the
   borrow vault after `deploy`.
2. **Post-assert the effect, not "didn't revert."** A test asserts `IEVault(borrowVault).governorAdmin() == p.governor`
   after `deploy` (the deployer-instance no longer governs it).
3. **No regression.** Every existing test that constructs the reservoir market stays green — especially
   `ReservoirLoopModule.t.sol` (the full 8-B5 loop) and `AlgebraIchiFairLpOracle.t.sol`. The escrow assert
   `governorAdmin() == address(0)` (`ReservoirLoopModule.t.sol:651`) MUST still hold (the escrow is untouched).

## Done when (gate — `forge test`, fork)
- `forge build` green.
- The new borrow-vault assert lives in the existing "deployer wiring (fork)" section of
  `ReservoirLoopModule.t.sol` (~`:638-651`, next to the escrow `governorAdmin()==address(0)` assert): after the
  deployer runs, assert `IEVault(borrowVault).governorAdmin() == <the governor passed in>`. (A focused new
  `ReservoirMarketDeployer.t.sol` is acceptable, but the existing fork section is the lower-friction home.)
- `forge test` green across `ReservoirLoopModule.t.sol` + `AlgebraIchiFairLpOracle.t.sol` (+ any other suite touching
  the deployer); no pre-existing test regressed.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** nothing (independent).
- **Unblocks / discharges:** FE-07 Finding A (mark DISCHARGED in PROGRESS Open obligations); a clean reservoir-market
  governor for every silo CTR-06c stamps.
