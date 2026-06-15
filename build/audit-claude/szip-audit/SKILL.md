---
name: szip-audit
description: Run the local-LLM adversarial security audit over the szipcode-euler contracts. Drives the model as a panel of divergent vuln lenses per subsystem, then Claude triages into a verified report. Use when the user wants to audit these contracts, find vulnerabilities, or run the security harness in audit/.
allowed-tools: Bash, Read, Write, Edit
---

# szipcode-euler adversarial audit

You orchestrate a local-LLM security audit of the contracts in this repo. The local model
(`audit/run_audit.py`) does **divergent finding** — surfacing every candidate bug. **You** do the
parts the local model is weak at: building the system map, forming consensus/triage, killing false
positives, and verifying with Foundry PoCs. Do NOT delegate judgment to the local model.

The local model is strong on standard vuln classes and broad coverage, weak on creative economic
exploits and prone to false positives. Your job is to cover both gaps.

## Phase 0 — System map (you build this; do it first, once)
If `audit/system-map.md` is missing or stale, build it before any finding pass:
1. Read the real logic contracts under `src/` (skip `interfaces/`, `demo/`, `test/`, `out/`).
2. Read the design spec at `../build/claude-zipcode.md` if present, plus any natspec invariant claims.
3. Write `audit/system-map.md` covering: every contract + role, money flows, trust boundaries,
   external integrations (Euler/EVC, ICHI, Hydrex, CoW, the SzAlpha bridge, Chainlink CCIP/CRE),
   and a dedicated **"Claimed invariants"** section extracting every defense the natspec asserts
   (e.g. NAV `max(spot,twap)`/`min(spot,twap)` bracket, first-depositor Gate defense, impairment
   bounds, bridge rate freshness). This file is injected into every finder prompt — make it dense
   and accurate; cross-contract bugs are only found if the map captures the seams.

## Phase 1 — Per-section divergent finding (local model)
1. Start the server clean: `bash audit/serve.sh 4 262144` (wait for READY). 256K/slot — the big
   `supply` section is ~63K tokens, so 64K context is too small.
2. Smoke check: `cd audit && python3 run_audit.py --smoke`.
3. For each subsystem (let it run; loop-until-dry — do not interrupt early):
   `python3 run_audit.py --section <name>` for name in: supply, szipUSD, bridge, loss, venue, core.
   (Or `--all` to chain them.) Each writes `reports/<name>.md` + `.json`.
   Rounds are slow (full thinking on whole-subsystem context) — minutes each. That is expected;
   the user has explicitly asked for thoroughness over speed.

## Phase 2 — Cross-section seam pass (local model)
Restart the server for big single-stream context, then run the cross pass:
`bash audit/serve.sh 1 262144` then `cd audit && python3 run_audit.py --cross`.
This hunts bugs that only exist when subsystems combine (deposit→NAV→venue→loss→redemption→bridge).

## Phase 3 — Triage & consensus (YOU, not the model)
Read every `reports/*.json`. Then:
- Deduplicate across sections.
- For each candidate, READ THE ACTUAL CODE and judge: real / false-positive / needs-PoC. Be a harsh
  skeptic — default to false-positive unless the attack path holds against the real source.
- Rank by severity × exploitability.
- Write `reports/AUDIT-SUMMARY.md`: confirmed findings with file:line, the attack path, and your
  confidence; a separate list of rejected candidates with WHY (so the user can sanity-check you).

## Phase 4 — PoC verification (optional, for HIGH/CRITICAL)
For each high-severity confirmed finding, write a Foundry exploit test under `test/audit/`, then run
`forge test --match-path 'test/audit/*' -vvv`. A compiling, passing exploit = confirmed; otherwise
downgrade. Report results in the summary. (Fork tests need `BASE_RPC_URL`; check `.env.example`.
Never read or echo `.env` — it holds real secrets.)

## Operating rules
- Server lifecycle: between phases that change context size, ALWAYS `serve.sh` (it kills stale
  servers first). Never just kill the Python client mid-call — that orphans server work and stalls.
- No consensus among model lenses — divergence is the point. Consensus is YOUR job in Phase 3.
- Report progress to the user between phases. Long runs are fine; surface the per-section finding
  counts as they land.
- Tune `audit/lenses.py` (lenses) and `audit/sections.py` (scope) if the user wants different coverage.
