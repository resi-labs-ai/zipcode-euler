# SPDX-License-Identifier: GPL-2.0-or-later
#
# hotkey_swap_watch.py — the substrate half of Phase C (see watch.go for the EVM half).
#
# Two things only substrate can see:
#   1. The `HotkeySwappedOnSubnet { coldkey, old_hotkey, new_hotkey, netuid }` event — drift detection
#      that fires the moment the operator rotates, BEFORE any user transaction lands (the Go watcher
#      only sees the consequences at the next poll).
#   2. The full metagraph across ALL mechanisms — the EVM metagraph precompile reads mechanism 0 only,
#      so on a multi-mechanism subnet the Go watcher's alarm 4 is best-effort and this is the truth.
#
# UNTESTED AGAINST THE LIVE CHAIN (written 2026-08-02; run it in staging before trusting it to page).
# Requires: pip install bittensor  (which brings substrate-interface).
#
# Usage:
#   WATCH_HOTKEY_SS58=5CDnZ6oe... WATCH_NETUID=46 [WATCH_ALERT_WEBHOOK_URL=...] python3 hotkey_swap_watch.py

import json
import os
import sys
import time
import urllib.request

NETUID = int(os.environ.get("WATCH_NETUID", "46"))
HOTKEY = os.environ.get("WATCH_HOTKEY_SS58", "")
NETWORK = os.environ.get("WATCH_SUBSTRATE_NETWORK", "finney")
WEBHOOK = os.environ.get("WATCH_ALERT_WEBHOOK_URL", "")
METAGRAPH_EVERY_S = int(os.environ.get("WATCH_METAGRAPH_SECONDS", "600"))

if not HOTKEY:
    print("WATCH_HOTKEY_SS58 is required (the configured validator hotkey, ss58)", file=sys.stderr)
    sys.exit(1)


def alert(severity: str, code: str, msg: str) -> None:
    line = f"[szalpha-watch/substrate] {severity} {code}: {msg}"
    print(line, file=sys.stderr, flush=True)
    if WEBHOOK:
        try:
            req = urllib.request.Request(
                WEBHOOK,
                data=json.dumps({"text": line}).encode(),
                headers={"Content-Type": "application/json"},
            )
            urllib.request.urlopen(req, timeout=10)
        except Exception as e:  # alerting must never kill the watcher
            print(f"webhook delivery failed (alert already logged): {e}", file=sys.stderr)


def check_metagraph(sub) -> None:
    """Alarm 4, substrate-complete: registration + dividends across the whole metagraph."""
    mg = sub.metagraph(netuid=NETUID)
    if HOTKEY not in mg.hotkeys:
        alert("CRITICAL", "hotkey-unregistered",
              f"configured hotkey not registered on subnet {NETUID} — dereg or drift; prepare the C3 runbook")
        return
    i = mg.hotkeys.index(HOTKEY)
    if float(mg.dividends[i]) == 0:
        alert("WARN", "hotkey-zero-dividends",
              f"configured hotkey earns zero dividends on subnet {NETUID} — the rate will flatline")


def watch_events(sub) -> None:
    """Subscribe to System.Events and page on HotkeySwappedOnSubnet touching our netuid or hotkey."""
    substrate = sub.substrate

    def handler(events, update_nr, subscription_id):
        for rec in events:
            ev = rec["event"]
            if ev.value.get("event_id") != "HotkeySwappedOnSubnet":
                continue
            attrs = ev.value.get("attributes", {})
            # attribute shapes vary across runtime versions; stringify defensively
            text = json.dumps(attrs, default=str)
            if str(NETUID) in text or HOTKEY in text:
                alert("CRITICAL", "hotkey-swapped",
                      f"HotkeySwappedOnSubnet touching our subnet/hotkey: {text} — the pointer may now be "
                      f"dead; the contract will halt on its own, run the C3 runbook NOW")
            else:
                print(f"HotkeySwappedOnSubnet elsewhere: {text}", file=sys.stderr, flush=True)

    substrate.query("System", "Events", subscription_handler=handler)


def main() -> None:
    import bittensor as bt  # deferred so --help style failures read cleanly

    sub = bt.Subtensor(network=NETWORK)
    alert("INFO", "started", f"substrate watcher up: netuid={NETUID} hotkey={HOTKEY[:8]}… network={NETWORK}")

    last_mg = 0.0
    while True:
        try:
            now = time.time()
            if now - last_mg >= METAGRAPH_EVERY_S:
                check_metagraph(sub)
                last_mg = now
            watch_events(sub)  # blocks inside the subscription; exceptions fall through to retry
        except KeyboardInterrupt:
            return
        except Exception as e:
            print(f"substrate watcher error, reconnecting in 30s: {e}", file=sys.stderr, flush=True)
            time.sleep(30)
            try:
                sub = bt.Subtensor(network=NETWORK)
            except Exception as e2:
                print(f"reconnect failed, retrying: {e2}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
