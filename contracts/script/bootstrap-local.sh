#!/usr/bin/env bash
# bootstrap-local.sh — one-command local dev chain.
#
# Usage:  BASE_RPC_URL=<your Base mainnet RPC> ./script/bootstrap-local.sh
#
# What it does, in order:
#   1. Restores the gitignored reference/ dependency repos the contracts build
#      needs (pinned commits from reference/MANIFEST.md; skipped if present).
#   2. forge build
#   3. Starts an anvil fork of Base on http://127.0.0.1:8545 and leaves it running.
#   4. Broadcasts DeployLocal:runLocal() against it (per RUNBOOK-mainnet-deploy.md §4).
#   5. Writes deployments/local/: addresses.json + one ABI file per deployed
#      contract under abi/.
#
# Requires: git, foundry (forge/anvil/cast), python3, and BASE_RPC_URL in the env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$CONTRACTS_DIR")"
REFERENCE_DIR="${REFERENCE_DIR:-$REPO_ROOT/reference}"
OUT_DIR="$CONTRACTS_DIR/deployments/local"
ANVIL_PORT="${ANVIL_PORT:-8545}"
RPC_LOCAL="http://127.0.0.1:$ANVIL_PORT"
# anvil's well-known account #0 — local-only, holds no real funds anywhere.
ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

for tool in git forge anvil cast python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found in PATH" >&2; exit 1; }
done
[ -n "${BASE_RPC_URL:-}" ] || { echo "ERROR: set BASE_RPC_URL to a Base mainnet RPC url" >&2; exit 1; }

# --- 1. reference/ repos the build needs (name url pinned-commit, per MANIFEST.md) ---
REPOS=(
  "ethereum-vault-connector https://github.com/euler-xyz/ethereum-vault-connector.git b9d557a"
  "euler-vault-kit https://github.com/euler-xyz/euler-vault-kit.git 5b98b42"
  "euler-price-oracle https://github.com/euler-xyz/euler-price-oracle.git abfbfc9"
  "euler-earn https://github.com/euler-xyz/euler-earn.git b2fd6e6"
  "evk-periphery https://github.com/euler-xyz/evk-periphery.git 23ea8c3c"
  "zodiac-core https://github.com/gnosisguild/zodiac-core.git 6bf0d41"
  "x402-cre-price-alerts https://github.com/smartcontractkit/x402-cre-price-alerts.git d582019"
  "chainlink-ccip https://github.com/smartcontractkit/chainlink-ccip.git 349cdba"
  "chainlink-evm https://github.com/smartcontractkit/chainlink-evm.git fdf8945351"
  "chainlink-local https://github.com/smartcontractkit/chainlink-local.git f8c0efe"
)

mkdir -p "$REFERENCE_DIR"
for entry in "${REPOS[@]}"; do
  read -r name url commit <<<"$entry"
  dest="$REFERENCE_DIR/$name"
  if [ -d "$dest" ]; then
    echo "reference/$name already present — skipping clone"
    continue
  fi
  echo "cloning reference/$name @ $commit"
  git clone "$url" "$dest"
  git -C "$dest" checkout --quiet "$commit"
  git -C "$dest" submodule update --init --recursive
done

# --- 2. build ---
cd "$CONTRACTS_DIR"
forge build

# --- 3. anvil fork of Base ---
if lsof -i :"$ANVIL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: port $ANVIL_PORT is already in use. Stop that process first (a stale" >&2
  echo "anvil keeps old contract state; this script wants a fresh chain)." >&2
  exit 1
fi
# Pin a slightly old block so load-balanced RPCs whose nodes lag can all serve it.
LATEST=$(cast block-number --rpc-url "$BASE_RPC_URL")
FORK_BLOCK=$((LATEST - 200))
mkdir -p "$OUT_DIR"
echo "starting anvil fork of Base @ block $FORK_BLOCK on port $ANVIL_PORT"
nohup anvil --fork-url "$BASE_RPC_URL" --fork-block-number "$FORK_BLOCK" \
  --port "$ANVIL_PORT" > "$OUT_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
disown "$ANVIL_PID"
for _ in $(seq 1 60); do
  if cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1; then break; fi
  kill -0 "$ANVIL_PID" 2>/dev/null || { echo "ERROR: anvil died, see $OUT_DIR/anvil.log" >&2; exit 1; }
  sleep 1
done
cast block-number --rpc-url "$RPC_LOCAL" >/dev/null || { echo "ERROR: anvil not responding" >&2; exit 1; }

# --- 4. deploy ---
# --slow and the gas multiplier are load-bearing: see RUNBOOK-mainnet-deploy.md §5.
forge script script/DeployLocal.s.sol:DeployLocal --sig "runLocal()" \
  --rpc-url "$RPC_LOCAL" --broadcast --slow --gas-estimate-multiplier 300 \
  --private-key "$ANVIL_KEY"

# --- 5. collect addresses + ABIs into deployments/local/ ---
BROADCAST_JSON="$CONTRACTS_DIR/broadcast/DeployLocal.s.sol/8453/runLocal-latest.json"
RPC_LOCAL="$RPC_LOCAL" OUT_DIR="$OUT_DIR" BROADCAST_JSON="$BROADCAST_JSON" \
  CONTRACTS_DIR="$CONTRACTS_DIR" python3 - <<'PY'
import json, os, pathlib

out_dir = pathlib.Path(os.environ["OUT_DIR"])
abi_dir = out_dir / "abi"
abi_dir.mkdir(parents=True, exist_ok=True)
broadcast = json.load(open(os.environ["BROADCAST_JSON"]))
artifacts = pathlib.Path(os.environ["CONTRACTS_DIR"]) / "out"

contracts = {}
for tx in broadcast["transactions"]:
    if tx.get("transactionType") != "CREATE":
        continue
    name, addr = tx.get("contractName"), tx.get("contractAddress")
    if not name or not addr:
        continue
    key = name
    n = 2
    while key in contracts:            # e.g. several MockERC20 deploys
        key = f"{name}-{n}"; n += 1
    contracts[key] = addr
    # A contract's artifact sits under its DEFINING source file, which is not
    # always <Name>.sol (e.g. ZeroIRM lives in another file) — so glob by name.
    matches = sorted(artifacts.glob(f"*.sol/{name}.json"))
    if matches:
        abi = json.load(open(matches[0]))["abi"]
        json.dump(abi, open(abi_dir / f"{name}.json", "w"), indent=2)
    else:
        print(f"WARNING: no artifact for {name}, ABI not written")

json.dump(
    {"chainId": 8453, "rpc": os.environ["RPC_LOCAL"], "contracts": contracts},
    open(out_dir / "addresses.json", "w"), indent=2,
)
print(f"wrote {out_dir}/addresses.json ({len(contracts)} contracts) + abi/")
PY

echo ""
echo "DONE. anvil is running (pid $ANVIL_PID, log $OUT_DIR/anvil.log)."
echo "  rpc:       $RPC_LOCAL  (chainId 8453)"
echo "  addresses: $OUT_DIR/addresses.json"
echo "  abis:      $OUT_DIR/abi/"
