#!/bin/bash
# Codex panelist (agentic-cli). Feeds _boot + mission to `codex exec`; Codex reads the
# repo files (source, grounding, tests) itself. Requires: codex CLI + ChatGPT-sub auth.
#
# Usage: panelist-codex.sh <model> <boot.md> <mission.md>
# Prints the review to stdout.
set -euo pipefail

MODEL="$1"; BOOT="$2"; MISSION="$3"

if ! command -v codex >/dev/null 2>&1; then
  echo "[panelist-codex] codex CLI not found — install it and auth with your ChatGPT sub." >&2
  exit 127
fi

PROMPT="$(cat "$BOOT"; printf '\n\n===================== YOUR MISSION =====================\n\n'; cat "$MISSION")"

# Run read-only from the repo root so Codex can open the named files. Single non-interactive turn.
exec codex exec --model "$MODEL" --skip-git-repo-check "$PROMPT"
