# Bridge group — adversarial review prompts

> **Running a cycle?** Read `adversarial-review/CONDUCTOR.md` first — it's the step-by-step operating
> procedure (spawn missions, verify-before-promote, reconcile, ticket). This file is just the map.

Mirrors `contracts/src/bridge/`. One folder per contract; each folder holds `_boot.md` (shared context
fed to every sub-agent for that contract) + numbered mission files (`1.md`, `2.md`, …). Mission count
follows the contract's authored attack surface, per its X-Ray — not a fixed number.

| Contract | nSLOC | Missions | Surfaces (from the X-Ray) |
|---|---:|---:|---|
| `szalpha/` | 201 | 3 | precompile measured-delta (X-1/I-2) · share-accounting/rate/donation (I-1) · privilege/upgrade/conservation (UUPS/pause/E-1) |
| `szalpharateoracle/` | 73 | 2 | push-path/freshness/replay (I-1/I-2/I-5/S3) · APR-math/anchor-roll (I-3/I-4/overflow) |
| `szalphalockreleasepool/` | 21 | 1 | base-wiring diff + deploy-topology (G-S8/G-S9/E-1/S2) |
| `szalphatokenpool/` | 16 | 1 | base-wiring diff + mint-authority (G-S8/G-S9/E-1 + MINTER grant) |
| `szalphamirror/` | 5 | 1 | config pins + mint-authority + subtraction thesis |

Total: **8 missions** across the group.

## Per-contract run (the cycle)
For each contract, every model (Claude, Codex, Fugu) runs every mission as an independent sub-agent,
booted with `_boot.md` + the mission file, the contract source, the bridge references named in `_boot`,
and read access to `contracts/test/bridge/`. Then Claude synthesizes.

- SzAlpha: 3 missions × 3 models = **9 reports** + `synthesis.md`
- RateOracle: 2 × 3 = 6 + synthesis
- each thin wrapper: 1 × 3 = 3 + synthesis

## Report tree (gitignored output — mirrors this prompt tree)
```
adversarial-review/reports/src/bridge/<contract>/
  claude-1.md  codex-1.md  fugu-1.md      (mission 1, one per model)
  claude-2.md  ...                         (further missions)
  synthesis.md                             (Claude: reconciled findings vs the X-Ray + suggested tickets)
```

## Design invariants for these prompts
- **Differential-first.** Every `_boot.md` names the audited precedent to diff against (Rubicon for the
  staking math, the Chainlink CCIP bases for the pools, `BurnMintERC20` for the mirror, the x402/CRE base
  for the oracle). The strongest finding is a *delta from precedent* — the thing review-in-isolation can't
  see.
- **Hot pass, not blind.** Prompts are modeled from the X-Ray's threat model: each mission attacks a
  *named* invariant/residual the X-Ray rates safe. (A blind cold-pass set, for discovering what the X-Ray
  missed, is a separate future prompt set.)
- **No re-reporting proven ground.** Each mission ends with an "already proven" list of real test names;
  confirming one of those holds goes in the Summary, not as a finding — so the 9 reports surface new signal.
- **Soundness is a valid result.** For the thin wrappers especially, "wired correctly, here's what I
  diffed" is the expected and acceptable outcome; a manufactured finding is noise.
