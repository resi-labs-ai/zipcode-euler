#!/bin/bash
# frontend-up.sh — one-shot bring-up of the zipcode frontend's PRODUCTION build.
#
# Clears port 3000, loads the app's .env (the standalone nitro server does NOT
# auto-load it — nuxt dev does), serves .output/, and verifies / + /bridge +
# the anvil fork the app's 8453 proxy points at.
#
# Use this for "just show me the app" (no hot reload). For active frontend work,
# run `npm run dev` in the app dir instead — and never run `nuxt build` while a
# dev server is up (it clobbers the dev cache). If dev hits EMFILE watcher
# errors, the shell's open-file limit is too low: `ulimit -n 65536` (a permanent
# raise lives in ~/.zshrc, added 2026-06-12).
#
# Rebuild the served artifact after frontend changes: `npm run build` in the app
# dir, then re-run this script.

set -u
APP_DIR=/Users/root1/zipcode-euler/frontend/zipcode-finance-euler

pkill -f "nuxt dev" 2>/dev/null
pkill -f ".output/server/index.mjs" 2>/dev/null
sleep 1
pids=$(lsof -ti :3000 2>/dev/null)
if [ -n "$pids" ]; then kill -9 $pids 2>/dev/null; fi
sleep 1

cd "$APP_DIR"
if [ ! -f .output/server/index.mjs ]; then
  echo "no production build found — run 'npm run build' in $APP_DIR first" >&2
  exit 1
fi

# Chains are enabled purely by RPC_URL_<id> env presence (utils/chain-env.ts).
set -a
. ./.env
set +a

nohup node .output/server/index.mjs > /tmp/zipcode-prod-server.log 2>&1 &
sleep 5

root=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost:3000/)
bridge=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost:3000/bridge)
anvil=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' http://127.0.0.1:8545)
echo "RESULT — /: $root   /bridge: $bridge   anvil(8545): $anvil"
echo "log: /tmp/zipcode-prod-server.log"
