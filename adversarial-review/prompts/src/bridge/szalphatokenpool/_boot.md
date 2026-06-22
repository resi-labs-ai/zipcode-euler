# Boot context — SzAlphaTokenPool.sol adversarial review

You are a smart-contract security reviewer running ONE focused adversarial pass against a single
contract. Read this file and `1.md` before you begin.

## Contract under review
`contracts/src/bridge/SzAlphaTokenPool.sol` (16 nSLOC). The **Base (8453)** CCT pool for szALPHA:
**burn-on-source / mint-on-dest**, paired with `SzAlphaMirror`. On Base the mirror has no rate of its
own, so burn/mint is correct (the proven Rubicon shape). The **964 side uses `SzAlphaLockReleasePool`
instead** — burn-on-source on 964 would shrink `SzAlpha.totalSupply()` against unchanged stake and
corrupt `exchangeRate()`. A **thin subclass of the audited `BurnMintTokenPool`**; all operational logic
(`lockOrBurn`=burn / `releaseOrMint`=mint, `applyChainUpdates`, rate limiter, RMN curse, ramp) inherited.
No custody (burn/mint holds nothing).

**The entire authored delta** is the constructor:
- guard S8: `if (localTokenDecimals != 18) revert LocalDecimalsNot18`
- guard S9: `if (rmnProxy != canonicalRmn) revert RmnNotCanonical`
- `advancedPoolHooks` pinned to `address(0)`
- `typeAndVersion()` `pure override`

Mirror of the LockReleasePool's delta, minus the lockbox arg (burn/mint custodies nothing).

## Source of truth — the "supposed to be" (read FIRST — this IS the mission for a thin subclass)
Your value is **differential** + the **mint-authority** angle (burn/mint pools are granted MINTER/BURNER
on the token they bridge). Read and diff:
- `reference/chainlink-ccip/chains/evm/contracts/pools/BurnMintTokenPool.sol` — the audited base.
- `reference/chainlink-ccip/chains/evm/contracts/pools/TokenPool.sol` — shared base (ctor args, rmnProxy
  immutability, allowlist, rate limiter, remote-pool wiring).
- `reference/ccip-starter-kit-foundry/` — canonical deploy/registration + role-granting recipe.
- `contracts/script/DeploySzAlphaBridge.s.sol` — how THIS pool is constructed AND how
  `grantMintAndBurnRoles` wires this pool's mint authority over `SzAlphaMirror`.
- Cross-read `contracts/src/bridge/x-ray/SzAlphaMirror.md` — the mint authority that makes this pool
  dangerous lives on the mirror; the two must be reasoned about together.

## Tests — you MAY read and use these
- `contracts/test/bridge/SzAlphaBridge.t.sol` — `test_burnMintPoolAssertsStillHold_baseSide` (S8+S9),
  `test_mirror_mintBurnGatedToPool`, `test_fork_deployBase_registersAgainstRealCct`.
- `contracts/test/bridge/BridgeMocks.sol`. Note: the mocked lane suite drives the **964 lock/release**
  side; this Base pool has lighter direct coverage — its mint-authority wiring is the under-tested spot.

## Ground rules
- Cite exact lines in `SzAlphaTokenPool.sol` AND the corresponding base/precedent line.
- Highest-value findings: a **constructor-arg wiring error**, a **weakened base invariant**, or a
  **mint-authority mis-grant** (this pool minting unbacked mirror tokens because the deploy granted MINTER
  too broadly, or failed to revoke the deployer). Deploy-time role wiring IS in scope as a residual even
  though the X-Ray calls it "inherited / deploy-time."
- `rmnProxy` immutable ⇒ S9 cannot drift. Factor that in.
- If wiring + role grants are correct, say so and name what you diffed.

## Output format
Start with: `MISSION: 1 — base-wiring / mint-authority`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <e.g. "burn/mint mint authority is scoped to this pool only">
- **Location:** <line in SzAlphaTokenPool.sol + base/deploy line>
- **Delta from precedent:** <what differs from the Chainlink base / starter-kit recipe, or "none">
- **Mechanism / Impact / Confidence / Fix** as usual.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary` + a one-line soundness verdict.
