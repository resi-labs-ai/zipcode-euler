# Boot context — ExitGate adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md` / `3.md` / `4.md`) before you begin.

## The contract under review
- `contracts/src/supply/szipUSD/ExitGate.sol` (133 nSLOC) — the szipUSD junior vault's custody + issuance + exit
  core: the **sole szipUSD minter/burner** and **sole Baal `Loot` custodian** (holds `manager(2)`, granted
  post-deploy). `Ownable` + `ReentrancyGuard`; no clone. Two value-moving flows only:
  - `depositFor(asset, amount, receiver)` (`:152`) — permissionless + `nonReentrant`: NAV-proportional issuance off
    `navEntry()` (round DOWN, favor the vault); pulls the asset straight into the main Safe (basket), then mints
    Loot to ITSELF + szipUSD to the receiver in **equal, paired** amounts (`:173-174`).
  - `burnFor(amount)` (`:200`) — `windowController`-only + `nonReentrant`: the §7/8-B14 paired buy-and-burn retire
    (pure supply reduction, no asset payout) — `burnLoot` from the Gate + burn the engine Safe's szipUSD
    (`:204-205`). The ONLY exit executor.

**Why it matters:** depositors hold only transferable szipUSD, never raw Loot; the Gate controls *when* exits
happen. The load-bearing property is the **two-token conservation** `szipUSD.totalSupply() == loot.balanceOf(gate)`
(every Loot mint/burn paired with an equal szipUSD mint/burn). The Gate holds Baal `manager(2)` — a dangerous
power — but wires **NO `ragequit` and NO `mintShares`** (so no in-kind drain, `totalShares()` stays 0). A bug is a
conservation break (Loot/szipUSD desync), a reachable ragequit/mintShares, an issuance mispricing, or custody
residue.

## These are ORIGINAL contracts — the precedent is the §6.4/§7 posture + the Baal base, not a code parent
Unlike the bridge/hydrex forks there is no audited parent to diff line-for-line. Your "supposed to be"
baselines:
- **The documented invariants** (contract NatSpec `:29-37`, authoritative): (1) two-token conservation
  `totalSupply == loot.balanceOf(gate)` always — the engine Safe's transient pre-burn szipUSD is the only
  transient asymmetry, resolved on the next `burnFor`; (2) exit is the **CoW book** (a holder rests a SELL, the
  treasury's buy-and-burn bid or an external buyer fills, retired via `burnFor`) — NO in-kind ragequit, NO
  on-chain forfeiting queue (the old `requestExit`/`processWindow` that confiscated `U` of an exiter's equity is
  RETIRED, ratified design); (3) zero-shares forever (only `mintLoot`/`burnLoot`, never `mintShares`).
- **The Baal base** — `contracts/src/interfaces/baal/IBaal.sol` — `mintLoot`/`burnLoot`/`lootToken`/`avatar`. The
  Gate's powers are deliberately a MINIMAL subset; the strongest finding is a path that reaches `ragequit` or
  `mintShares` (it shouldn't — confirm by reading every Baal call).
- **The oracle** — `contracts/src/supply/SzipNavOracle.sol` — `navEntry()` (reverts `StalePrice`/`RateUnseeded`
  when a required leg is stale — issuance fails closed), `valueOf(asset, amount)`, `grossBasketValue()`. Issuance
  is `shares = valueOf(asset, amount) * 1e18 / navEntry()`, round DOWN.
- **The share token** — `contracts/src/supply/szipUSD/SzipUSD.sol` — `onlyGate` mint/burn (the Gate is the sole
  caller; drilled separately as `szipusd`).
- **The X-Ray is your ground truth** — `contracts/src/supply/szipUSD/x-ray/ExitGate.md` (I-1…I-9, the guard
  table). The fleet-wide pattern context is `.../x-ray/portfolio-map.md`.

## Tests
`contracts/test/supply/szipUSD/ExitGate.t.sol` — 17 base-fork unit + 1 stateful invariant = **18 passing**
(fork-grade: real Baal substrate via `_summon` + real oracle). The marquee:
`invariant_twoToken_conservation_and_zeroShares` (multi-actor deposit/transfer/burn handler, ~6,400 calls, 0
reverts, 0 violations). Plus: NAV issuance (par + round-down), `previewDeposit` parity, the manager-grant gate,
TVL cap, stale/unseeded fail-close, the `xALPHA` deposit path, the `burnFor` under-funded rollback. See what is
proven (don't re-report) and where the tests STOP (the `NotWired`/negative-ctor revert paths not directly
exercised; the build-phase re-point window).

## Ground rules
- Cite exact lines in `ExitGate.sol` AND the `IBaal`/`SzipNavOracle`/`SzipUSD` line where the seam crosses.
- The decisive surfaces: (1) any path where `szipUSD.totalSupply()` and `loot.balanceOf(gate)` desync (an unpaired
  mint/burn, a reentrancy between the two mints, an ordering that drifts them); (2) a reachable `ragequit` or
  `mintShares` (would let an in-kind drain or break zero-shares); (3) an issuance mispricing (rounding UP favoring
  the depositor, a stale mark priced, a TVL-cap bypass); (4) custody residue (the deposited asset not fully
  routed to the basket); (5) `burnFor` burning more than the engine holds without atomic rollback.
- **Pressure-test severity.** The exit topology (CoW-only, no ragequit, no on-chain forfeiting queue) is RATIFIED
  design — do NOT report "there's no in-kind exit" or "exit depends on the CoW rail" as a vuln; that's intentional
  (see the `exit-topology-intentional` precedent). The Baal `manager(2)` power is dangerous IN GENERAL but bounded
  by *what the Gate never calls* — a finding must show a REACHABLE dangerous Baal call, not the theoretical power.
- The build-phase mutable wiring (8 setters incl. `setBaal` which re-derives loot/juniorTrancheSafe) is a
  documented residual closed by the pre-prod re-freeze. A re-point restatement is INFO unless it DRAINS or breaks
  conservation.
- "Sound" is a valid result. If conservation holds and no dangerous Baal call is reachable, say so.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/guard you attack (I-1…I-9, G-n)>
- **Location:** <fn / exact line in ExitGate.sol + the IBaal/SzipNavOracle/SzipUSD line where the seam crosses>
- **Delta from posture:** <how it breaks a documented invariant, or "ratified exit topology / Baal-power-not-reachable", or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it DESYNCS the two-token conservation,
  reaches a RAGEQUIT/mintShares, MISPRICES issuance, leaves CUSTODY residue, or breaks `burnFor` atomicity.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness
verdict (and explicitly: does `totalSupply == loot.balanceOf(gate)` hold, and is any ragequit/mintShares reachable?).
