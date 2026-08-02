// SPDX-License-Identifier: GPL-2.0-or-later
//
// Command szalpha-watch runs the Phase C alarm poller (see watch.go header). Read-only: no key, no
// submission path. Configuration is env-only:
//
//	WATCH_RPC_URL           964 RPC (default https://lite.chain.opentensor.ai)
//	WATCH_SZALPHA           the SzAlpha proxy address (REQUIRED)
//	WATCH_NETUID            subnet id for the alarm-4 metagraph check (default 46)
//	WATCH_POLL_SECONDS      poll cadence (default 60)
//	WATCH_STAKE_DROP_BPS    alarm-2 threshold (default 200 = 2%)
//	WATCH_RATE_MOVE_BPS     alarm-3 threshold (default 100 = 1%)
//	WATCH_METAGRAPH_TICKS   run alarm 4 every N ticks; 0 disables it (default 10)
//	WATCH_ALERT_WEBHOOK_URL optional JSON {"text": ...} POST target (Slack/Discord-shaped)
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envUint(key string, fallback uint64, log *slog.Logger) uint64 {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseUint(v, 10, 64)
	if err != nil {
		log.Error("invalid uint env, using fallback", "key", key, "value", v, "fallback", fallback)
		return fallback
	}
	return n
}

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	szRaw := os.Getenv("WATCH_SZALPHA")
	if !common.IsHexAddress(szRaw) {
		log.Error("WATCH_SZALPHA missing or not an address", "value", szRaw)
		os.Exit(1)
	}
	rpcURL := envOr("WATCH_RPC_URL", "https://lite.chain.opentensor.ai")
	netuid := uint16(envUint("WATCH_NETUID", 46, log))
	poll := time.Duration(envUint("WATCH_POLL_SECONDS", 60, log)) * time.Second
	th := Thresholds{
		StakeDropBps: envUint("WATCH_STAKE_DROP_BPS", 200, log),
		RateMoveBps:  envUint("WATCH_RATE_MOVE_BPS", 100, log),
	}
	metagraphTicks := envUint("WATCH_METAGRAPH_TICKS", 10, log)
	webhook := os.Getenv("WATCH_ALERT_WEBHOOK_URL")

	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		log.Error("dial failed", "rpc", rpcURL, "err", err)
		os.Exit(1)
	}
	w := newWatcher(client, common.HexToAddress(szRaw), netuid)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	log.Info("szalpha-watch running", "szAlpha", szRaw, "rpc", rpcURL, "netuid", netuid,
		"poll", poll.String(), "stakeDropBps", th.StakeDropBps, "rateMoveBps", th.RateMoveBps,
		"metagraphTicks", metagraphTicks, "webhook", webhook != "")

	emit := func(alerts []Alert) {
		for _, a := range alerts {
			switch a.Severity {
			case "CRITICAL":
				log.Error("ALARM", "code", a.Code, "msg", a.Msg)
			case "WARN":
				log.Warn("alert", "code", a.Code, "msg", a.Msg)
			default:
				log.Info("notice", "code", a.Code, "msg", a.Msg)
			}
			if webhook != "" {
				if err := postWebhook(ctx, webhook, a); err != nil {
					log.Error("webhook delivery failed (alert already logged)", "err", err)
				}
			}
		}
	}

	var prev *Snapshot
	tick := uint64(0)
	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	for {
		cur, err := w.snapshot(ctx)
		if err != nil {
			// Transport failure: skip the tick (prev unchanged, so the next good read still compares
			// against real history). Persistent failure is itself visible as a repeating error line.
			log.Error("snapshot failed (transport) — tick skipped", "err", err)
		} else {
			emit(evaluate(prev, cur, th, func(from, to uint64) (bool, error) {
				return w.hadRedeem(ctx, from, to)
			}))
			if metagraphTicks > 0 && tick%metagraphTicks == 0 {
				alerts, err := w.checkMetagraph(ctx, cur.Hotkey)
				if err != nil {
					log.Error("metagraph check failed — will retry", "err", err)
				} else {
					emit(alerts)
				}
			}
			prev = cur
		}
		tick++
		select {
		case <-ctx.Done():
			log.Info("szalpha-watch stopping")
			return
		case <-ticker.C:
		}
	}
}
