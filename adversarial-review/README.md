# adversarial-review

Per-contract adversarial security review. Several models attack the same contract
**independently**, each running X-Ray-derived missions grounded in the audited precedent
the contract was modeled on. Claude (Opus 4.8) then reconciles every report against that
contract's internal X-Ray verdict and emits a synthesis + suggested tickets. One contract
at a time.

## The panel — three delivery modes

| Panelist | Model | TYPE | How it gets context | Status |
|----------|-------|------|---------------------|--------|
| Claude (reviewer + **reconciler**) | Opus 4.8 | `session` | Agent-tool subagent; reads repo files itself | ready |
| Codex | gpt-5.x-codex | `agentic-cli` | `codex exec`; reads repo files itself | needs install + ChatGPT auth |
| Fugu Ultra | fugu-ultra | `inline-api` | **inlined** `context.files` (1M ctx, /v1/responses, effort=max) | needs `SAKANA_API_KEY` |

The split that matters: **agentic** panelists (Claude, Codex) are handed `_boot + mission`
and read the source/grounding/tests themselves. **Inline** panelists (Fugu) can't touch the
filesystem, so the orchestrator inlines the contract's `context.files` manifest into one
request. Same missions, two delivery paths.

## Prompt tree (version-controlled audit definitions)
```
prompts/src/<group>/<contract>/
  _boot.md        shared boot context: contract summary, source-of-truth files, tests, rules, output format
  1.md 2.md ...   one mission per X-Ray attack surface (the adversary persona + named invariants to break)
  context.files   inline manifest: source + tests + ranged grounding (fed to inline-api panelists)
```
Mission count follows the contract's authored surface (fat logic → more; thin wrapper → 1).
See `prompts/src/bridge/README.md` for the worked bridge group (5 contracts, 8 missions).

## Report tree (gitignored output — mirrors the prompt tree)
```
reports/src/<group>/<contract>/
  <panelist>-<mission>.md   one report per (model, mission) cell
  synthesis.md              Claude: reconciled findings vs the X-Ray + suggested tickets
```

## Run one contract
```bash
cd ~/zipcode-euler/adversarial-review
source panel.env            # exports API keys (e.g. SAKANA_API_KEY) into the environment
bin/review-contract.sh bridge/szalpha
```
The script runs the **scripted** panelists (Codex, Fugu) for every mission in parallel and
writes their reports. For **session** panelists (Claude) it writes a PENDING stub — the
Claude session then runs those missions via the Agent tool, overwrites the stubs, and writes
`synthesis.md`. Claude is the conductor, not a line the shell can call.

## Reconciliation contract (Claude's step)
For each finding across all reports, classify against `contracts/src/**/x-ray/<Contract>.md`:
- **covered** — already in the X-Ray verdict (invariant/guard/residual): confirm or dismiss.
- **gap** — genuine, not in the verdict → suggested ticket (in `build/tickets/` style).
- **false-positive** — refuted by the code/design → one-line note, no ticket.
The synthesis also scorecards which model caught what — the empirical measure of each leg's value.

## Files
| File | Purpose |
|------|---------|
| `panel.env` | active panelists (NAME\|TYPE\|MODEL\|BASE_URL\|API_KEY_ENV\|EFFORT); source before running |
| `bin/review-contract.sh` | orchestrator: missions × panelists, parallel, type-aware |
| `bin/panelist_inline.py` | inline-api caller (Fugu /v1/responses, or generic chat); assembles + inlines `context.files` |
| `bin/panelist-codex.sh` | agentic-cli wrapper (`codex exec` with `_boot + mission`) |
| `serve-coder480.sh` | (deferred) local Qwen3-Coder-480B endpoint, if a local inline leg is added later |

## Design invariants
- **Differential-first** — every `_boot` names the audited precedent to diff against; the
  strongest finding is a *delta from precedent* (the thing review-in-isolation can't see).
- **Hot pass** — missions attack *named* X-Ray invariants/residuals. A blind cold-pass set
  (to find what the X-Ray missed) is a separate future addition.
- **No re-reporting proven ground** — each mission lists the real test names already covering
  it; confirming one holds goes in the Summary, not as a finding.
- **Soundness is a valid result** — "wired correctly, here's what I diffed" is acceptable,
  especially for thin wrappers; a manufactured finding is noise.
