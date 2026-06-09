# 8-B6 report — `LpStrategyModule` (LP build/stake module)

**TL;DR.** Authored + built the **8-B6 LP strategy module** — the third engine Zodiac Module and the simplest one
(no EVC, no oracle, no hook). `LpStrategyModule` owns the LP lifecycle: build the zipUSD/xALPHA ICHI LP, gauge-stake
it to farm oHYDX, and unstake/re-stake slices for the 8-B5 loop. Three `onlyOperator` scalar-only entrypoints —
`addLiquidity(deposit0, deposit1, minShares)` / `stake(lpAmount)` / `unstake(lpAmount)` — driving the wired ICHI
vault + gauge, deposit `to` and both views pinned to the literal `engineSafe`, Call-only, `value==0`, no custody, no
storage written in any mutating path. **29/29 tests** (24 unit + 5 Base-fork), **300/300 total no-regression**.
**Kept on disk, NOT git-committed** (the whole tree is untracked — superintendent commit decision pending, same as
8-B5/8-B14/Exit-Gate).

- Code: `contracts/src/supply/szipUSD/LpStrategyModule.sol` + `contracts/test/LpStrategyModule.t.sol`.
- Run it: `forge test --fork-url $BASE_RPC_URL --match-contract LpStrategyModule` (the 5 fork tests need the RPC; the
  24 unit tests run without it: `forge test --match-contract LpStrategyModuleUnitTest`). I ran the full suite against
  the public endpoint `https://mainnet.base.org` — 300/300.
- Ticket: `tickets/sodo/8-B6-lp-strategy.md`. No `reference/` or kept-contract edits; `BaseAddresses.sol` untouched.

## What the window did (the harness loop)
1. **Drafted** the build-only ticket from `claude-zipcode.md §4.5.1` 8-B6 + `reports/baal-spec.md §10.8`, modeling the kept
   `ReservoirLoopModule` (8-B5) + `SzipBuyBurnModule` (8-B14). Probed live Base first to pin the ICHI deposit path +
   the gauge shape (see Judgment calls).
2. **Fanned out 5 critics** (junior-developer, spec-fidelity, reference-verifier, qa-engineer, security-engineer) in
   parallel. Each read the draft + the cited spec/reference; reference-verifier re-ran `cast` against live Base.
3. **Synthesized + triaged** → 1 spec gap (fixed in `claude-zipcode.md` FIRST) + ~12 ticket-quality fixes folded in.
4. **Built it for real + KEPT it** — materialized the module + tests, `forge build` green, 29/29 + 300/300 fork-green.
   Verified every external signature + address against live Base.

## Design decisions to sanity-check (the judgment calls)
1. **Direct `IICHIVault.deposit`, NOT the DepositGuard — resolved on live Base.** The §4.5.1 8-B6 text mentions both
   the vault `deposit` and the ICHI DepositGuard. I chose **direct `vault.deposit(d0,d1,engineSafe)`** because (a)
   direct deposit is build-verified to work and keeps the module vault-agnostic, and (b) the module is a contract
   that already holds the tokens (the guard is an EOA/UI convenience). **The fork test PROVES direct deposit lands shares against the REAL
   single-sided ICHI vault `0x07e72…` on our factory `0x2b52c416…`** (`test_fork_real_vault_single_sided_deposit`,
   3.97M gas) — so the DepositGuard is not needed. Slippage protection is the operator-supplied `minShares`
   post-check (replacing the guard's `minimumProceeds`). The ticket retains a documented DepositGuard fallback if a
   future production vault is guard-gated, but the canonical vault on our factory is directly depositable.
2. **Single-sided zipUSD, vault-enforced; module vault-agnostic (user-directed, RESOLVED 2026-06-08).** The vault is a
   single-sided **zipUSD** YieldIQ vault — **no balanced add** (the xALPHA leg accrues from pool flow + the emission
   flywheel, never a deposit). Single-sidedness is the **wired vault's** `allowToken*` property, **NOT a module gate**:
   the module forwards `(deposit0, deposit1)` unchanged and the vault rejects the disallowed side fail-closed, so the
   ICHI vault config can be finalized with ICHI later without re-authoring the module. (My initial framing allowed a
   balanced 8-B13 add; the user reversed that — there is no balanced add. The module did NOT change, since it was
   already vault-agnostic; the ticket/spec/tests were reframed to single-sided.) The gauge MUST be a Hydrex
   `ALM_ICHI_UNIV3`-type gauge (the hard external whitelist dependency).
3. **Hard non-zero `minShares` floor (`ZeroMinShares`).** Security flagged `minShares == 0` as a footgun: a direct
   ICHI deposit is sandwich-exposed, and a zero floor no-ops the only protection. I made `addLiquidity` reject
   `minShares == 0`. The CRE robot always sizes a real floor off the `SzipNavOracle` reserve×price math. (No on-chain
   *absolute* floor — the right value is unknowable on-chain without the oracle; per-call non-zero is the right
   granularity.) **Please confirm** this is the desired strictness (vs. permissive-but-documented).
4. **`token0`/`token1` read LIVE off the vault in `setUp`** (the `SzipBuyBurnModule` pattern) — removes two setUp
   args and guarantees the approved tokens match the vault. Address-nonzero guards run BEFORE the live read so an
   `ichiVault == 0` reverts `ZeroAddress` cleanly (not via a staticcall on a code-less address).

## Holes surfaced → resolution
- **DESIGN DECISION (user-directed, §4.5.1):** single-sided zipUSD YieldIQ vault, **no balanced add** (decision 2).
  §4.5.1 8-B6 rewritten to the single-sided/vault-agnostic model; the module is vault-agnostic (no module gate), the
  vault's `allowToken*` enforces single-sided fail-closed; gauge MUST be `ALM_ICHI_UNIV3`. No §17 reopened. (My
  initial balanced-for-8-B13 framing was reversed by the user; module unchanged, docs/tests reframed.)
- **Ticket-quality (folded in pre-build):** (a) the kept 8-B5 `_exec` returns void — 8-B6 needs `returns (bytes
  memory)` to decode the deposit share-return (ref-verifier + junior; the "model :146-154 exactly" wording was
  corrected to "model the bubbling logic, ADD a return"). (b) The mock ICHI vault + mock gauge behavior was
  unspecified yet 4+ Done-when lines depend on faithful `transferFrom`/mint-to-`to`/LP-movement semantics (qa) →
  fully specified in the ticket. (c) The exec-discipline test MUST run a **live** RecordingSafe with a real mock
  vault, because `addLiquidity` `abi.decode`s the deposit return and a non-live mock returns `""` → reverts before
  any assertion (qa B1 — a new failure mode the void-`_exec` 8-B5 pattern doesn't cover). (d) snapshot-guarded
  slippage probe (qa B3). (e) per-entrypoint atomicity fail-indices (deposit is index 1 single / 2 balanced — no
  `enableCollateral` interposer like 8-B5; qa B4). (f) gauge sig-verify limited to VIEW selectors (can't staticcall
  the state-mutating `deposit`/`withdraw`; qa B6). (g) setUp 5-address (not "four") + ordering. (h) views-read-
  `engineSafe` regression test (qa #6). (i) mastercopy-inert asserts all 6 wired fields (security #6).

## Authoritative-doc edits
- **`claude-zipcode.md §4.5.1`** (8-B6 block): single-sided zipUSD YieldIQ vault (DECIDED, vault-agnostic module);
  direct `vault.deposit` is the add path (build-verified, DepositGuard not needed); the gauge MUST be
  `ALM_ICHI_UNIV3` type; failure modes updated. No `audit/*` edit (the 8-B6 audit-sweep is the deferred
  engine-integration pass).
- **`tickets/PROGRESS.md`**: 8-B6 → DONE, 8-B7 → NEXT; banner updated; 4 new cross-ticket obligations (item-10 gauge
  + POL-vault wiring; 8-B11/CRE op surface; 8-B10 backed-zipUSD; engine-integration audit-sweep); the spec-gap log
  entry. **`tickets/LEDGER.md`**: the 8-B6 digest.

## Cross-ticket obligations
- **Inbound:** none — 8-B6 owes nothing in the obligations table (confirmed by spec-fidelity, verified against the
  full table).
- **Created (logged in PROGRESS):** item-10 resolves+wires the gauge via `Voter.gauges(ourPool)` (hard `!= 0`
  whitelist gate — external Hydrex-governance dep) + creates the POL ICHI vault with both sides allowed; 8-B11/CRE is
  the sole caller (sizes `minShares`, sequences unstake→re-stake around the 8-B5 loop); 8-B10 ensures the zipUSD leg
  is backed; the engine-integration **audit-sweep** (the LP-lifecycle L-step + N-steps into `audit/2`/`audit/3`).

## Status + NEXT
- **8-B6 DONE — BUILT-VERIFIED**, kept on disk, NOT git-committed (whole tree untracked).
- **NEXT = 8-B7** (harvest/vote module — claim oHYDX + fees, `exerciseVe` the vote-floor slice first, `Voter.vote`
  each epoch, claim the veNFT rebase; `reports/baal-spec.md §10.8` / `hydrex.md §4/§8/§9.2`). It custodies the veHYDX veNFT
  and needs the `IVoter`/`IVotingEscrow`/`IOptionToken` interfaces (already vendored + on-chain-verified).

## A skeptical note (per kickoff: "no findings is a flag")
This module is genuinely simple (no EVC/oracle/hook), so the small surface is real, not under-scrutiny. The two
load-bearing checks I'd want a second look at: (1) the **fork tests run against the public RPC** I used — re-run them
against the project's pinned Alchemy `BASE_RPC_URL` to confirm (the real ICHI vault state at the fork block drives
the deposit share math + the snapshot-guarded slippage assertion). (2) The **real-vault deposit test uses WETH/USDC**
(the live single-sided vault) as a stand-in for zipUSD/xALPHA — it proves the *mechanism* (direct deposit on our
factory's codebase lands shares), not our specific pool; the production zipUSD/xALPHA vault + ALM gauge don't exist
until the Hydrex whitelist lands (the item-10 obligation), so the behavioral cycle necessarily uses mocks. That is
the blessed §4.5.1 stand-in posture, but worth your eyes.
