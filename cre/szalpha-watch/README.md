# cre/szalpha-watch — Phase C monitoring for the SzAlpha wrapper (964)

The paging half of the drift posture. The contracts already halt damage autonomously (`BackingVanished`
stops deposits and the rate; the CRE feed stales; Base consumers fail closed) — this is what tells a
human, in minutes instead of hours. Rubicon took 10.6 hours to pause and that window was the entire loss.

## Two processes

**`szalpha-watch` (Go, tested)** — a read-only poller against the 964 RPC implementing the four alarms
from `bridge/SN46-BRIDGE-MVP-V2.md` Phase C:

1. backing-vanished (stake 0 against non-zero supply) — CRITICAL
2. stake-discontinuity (a drop beyond `WATCH_STAKE_DROP_BPS` with no `Redeemed` event in the block
   range; an unverifiable drop still pages) — CRITICAL
3. rate-reverted (a reverting `exchangeRate()` is the breaker state, never a script error) and
   rate-jump (a move beyond `WATCH_RATE_MOVE_BPS` between polls) — CRITICAL
4. hotkey-liveness via the metagraph precompile: unregistered — CRITICAL; zero dividends — WARN.
   Mechanism 0 only; the python watcher is the substrate-complete version.

Plus a WARN when `validatorHotkey()` changes between polls (legitimate only via a timelocked
`retarget`/`migrateTo`).

```bash
cd cre/szalpha-watch && go build -o szalpha-watch .
WATCH_SZALPHA=0x6b1C6b4619C28F8F82349AEb3f6aBf90Ff6a0d1f \
WATCH_ALERT_WEBHOOK_URL=https://hooks.slack.com/... \
./szalpha-watch
```

Alarm 5 (transport, optional) compares the value that LANDED on Base against the 964 source. The push job
moves the rate unchanged, so `SzAlphaRateOracle.rawExchangeRate()` on Base must EQUAL
`SzAlpha.exchangeRate()` on 964. It is an equality check, not a threshold: a real slash is large and
legitimate, so a "too big a move" alarm cannot distinguish one from a scaling error, and this can. It reads
the RAW view because `exchangeRate()` is smoothed and is designed to withhold exactly this signal for a
window. Enable with `WATCH_RATE_ORACLE` + `WATCH_BASE_RPC_URL`; unset means single-chain rehearsal and the
check is skipped. A Base read failure never suppresses the 964 alarms.

Env (all optional except `WATCH_SZALPHA`): `WATCH_RPC_URL` (default `https://lite.chain.opentensor.ai`),
`WATCH_NETUID` (46), `WATCH_POLL_SECONDS` (60), `WATCH_STAKE_DROP_BPS` (200), `WATCH_RATE_MOVE_BPS`
(100), `WATCH_METAGRAPH_TICKS` (10; 0 disables alarm 4), `WATCH_ALERT_WEBHOOK_URL` (JSON
`{"text": ...}` POST; Slack/Discord-shaped).

**`hotkey_swap_watch.py` (python, UNTESTED against the live chain)** — the substrate half: subscribes
to the chain's `HotkeySwappedOnSubnet` event (drift detection that fires before any user transaction
lands) and runs the full-metagraph alarm 4 across all mechanisms. Requires `pip install bittensor`.
Run it in staging before trusting it to page.

## When an alarm fires

The runbook is `bridge/SN46-BRIDGE-MVP-V2.md` §C3: `pause()` → locate where the stake landed (the
operator's new hotkey; your coldkey still owns it) → `retarget(foundHotkey)` through the timelock →
`unpause()`. All three recovery levers are mainnet-proven (the 2026-07-31 drill).

## Status (2026-08-02)

Built and host-tested (alarm core + revert classifier, 6 tests). NOT RUNNING anywhere — starting it
against the production wrapper is an ops act, gated on the go-live decision, and it must be running
before any second depositor. Alert delivery is log + webhook; wiring the webhook to a real paging
channel is part of turning it on.
