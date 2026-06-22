#!/bin/bash
# Serve Qwen3-Coder-480B-A35B-Instruct-4bit as an OpenAI-compatible endpoint on :8081
# for the adversarial-review panel. Code-specialist local reviewer leg.
#
# ~252GB on disk, ~250GB resident — needs the 512GB box (GPU wired limit raised at boot).
# Loads in ~60-90s. Run in its OWN terminal; Ctrl-C to stop, or: pkill -f mlx_lm.server
#
# Port 8081 deliberately avoids 8080 (the Qwen3.5-397B generalist endpoint), so both
# can serve at once if memory allows — though 252GB + 421GB will NOT co-reside on 512GB.
# Run one local model at a time.
#
# Model-id gotcha: mlx_lm.server identifies the loaded model by its full path and tries
# to HF-download any other name. panel.env passes the full path as the model id.
set -euo pipefail
exec /Users/root1/.venvs/hf/bin/python -m mlx_lm.server \
  --model /Users/root1/night-owl/models/Qwen3-Coder-480B-A35B-Instruct-4bit \
  --host 127.0.0.1 --port 8081
