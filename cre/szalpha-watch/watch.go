// SPDX-License-Identifier: GPL-2.0-or-later
//
// szalpha-watch — the Phase C monitor for the SzAlpha wrapper on Subtensor (964).
//
// The contracts halt damage autonomously (BackingVanished stops deposits and the rate; the CRE feed then
// stales and every Base consumer fails closed). What no contract can do is PAGE A HUMAN — Rubicon took
// 10.6 hours to pause and that window was the entire loss. This binary is the paging half: a read-only
// poller implementing the four alarms from bridge/SN46-BRIDGE-MVP-V2.md Phase C.
//
//	1  backing vanished     stake == 0 while supply > 0 — the exact Rubicon state. CRITICAL.
//	2  stake discontinuity  stake drops beyond a threshold with no Redeemed event in the block range —
//	                        emission only adds, so an unexplained drop is a hotkey event. CRITICAL.
//	3  rate revert / jump   exchangeRate() REVERTING is alarm-1-equivalent, never a script error (the
//	                        revert IS the vanished state); a move beyond a threshold between polls pages
//	                        too (catches the same event from the other side). CRITICAL.
//	4  hotkey liveness      the configured hotkey absent from the subnet metagraph, or earning zero
//	                        dividends — degradation before it becomes a loss. Via the metagraph precompile
//	                        (0x802), which reads MECHANISM 0 ONLY; for subnets running more than one
//	                        mechanism the substrate-side check in hotkey_swap_watch.py is the full version.
//
// Plus: the validatorHotkey() pointer changing between polls (expected only from a timelocked
// retarget/migrateTo) raises a WARN, and hotkey_swap_watch.py subscribes to the chain's
// HotkeySwappedOnSubnet event for drift detection that fires BEFORE any user transaction lands.
//
// This binary is READ-ONLY by construction: no signer, no submission path. Alerts go to the log (stderr)
// and, when WATCH_ALERT_WEBHOOK_URL is set, as a JSON POST {"text": ...} to that URL (Slack/Discord-shaped;
// anything that accepts it). The incident runbook the alerts point at is MVP-V2 §C3: pause → locate the
// stake → retarget via the timelock → unpause.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// The Subtensor metagraph precompile (0x802) — a chain constant, not a wiring slot.
const metagraphPrecompile = "0x0000000000000000000000000000000000000802"

// redeemedTopic is the Redeemed event signature topic — SzAlpha.sol:
// event Redeemed(address indexed user, address indexed receiver, uint256 sharesIn, uint256 alphaOutRao, uint256 taoOut)
var redeemedTopic = crypto.Keccak256Hash([]byte("Redeemed(address,address,uint256,uint256,uint256)"))

// Thresholds are the alarm trigger levels (config-driven; defaults per MVP-V2 §C2).
type Thresholds struct {
	StakeDropBps uint64 // alarm 2: a drop beyond this fraction of the previous stake (default 200 = 2%)
	RateMoveBps  uint64 // alarm 3: a rate move beyond this between polls (default 100 = 1%)
	// alarm 5: how far the value on Base may sit from the 964 source before it is a transport fault.
	// Small by design — the job transports the rate UNCHANGED, so the only legitimate gap is one poll of
	// emission accrual (sub-bps per 72-min tempo). Default 50 = 0.5%, which is ~two orders of magnitude of
	// headroom over real drift and still catches any scaling error by many orders.
	TransportDriftBps uint64
}

// Snapshot is one poll's view of the wrapper.
type Snapshot struct {
	Block        uint64
	Stake        *big.Int    // totalStaked() (readable even in the vanished state, by design)
	Supply       *big.Int    // totalSupply()
	Hotkey       common.Hash // validatorHotkey()
	Rate         *big.Int    // exchangeRate(); nil when RateReverted
	RateReverted bool        // the vanished state seen from the rate side
}

// BaseSnapshot is one poll's view of the Base-side receiver, SzAlphaRateOracle. Optional: nil whenever
// WATCH_RATE_ORACLE / WATCH_BASE_RPC_URL are unset, which is the single-chain rehearsal shape.
type BaseSnapshot struct {
	Raw      *big.Int // rawExchangeRate() — the last value the CRE actually pushed, UNSMOOTHED
	Smoothed *big.Int // exchangeRate() — min(spot, twap), what NAV consumes
	Fresh    bool     // fresh() — consumers fail closed when false
}

// Alert is one page-worthy finding. Severity: CRITICAL pages, WARN notifies, INFO records.
type Alert struct {
	Severity string
	Code     string
	Msg      string
}

// evaluate is the PURE alarm core over two consecutive snapshots (prev nil on the first tick).
// hadRedeem answers "did any Redeemed event land in (fromBlock, toBlock]" — injected so the logic is
// table-testable; an error from it must FAIL TOWARD PAGING (an unverifiable drop is still a page).
func evaluate(prev, cur *Snapshot, th Thresholds, hadRedeem func(fromBlock, toBlock uint64) (bool, error)) []Alert {
	var alerts []Alert

	// Alarm 1 — the exact Rubicon state. The contract has already halted entry + the rate on its own;
	// this page is what turns the built-in halt into a human response (§C3 runbook).
	if cur.Stake.Sign() == 0 && cur.Supply.Sign() > 0 {
		alerts = append(alerts, Alert{"CRITICAL", "backing-vanished",
			"stake reads 0 against non-zero supply — the configured hotkey no longer holds the backing. " +
				"Runbook §C3: pause → locate the stake (operator's new hotkey) → retarget via timelock → unpause."})
	}

	// Alarm 3a — a reverting rate IS the vanished state (BackingVanished), never a script error.
	if cur.RateReverted {
		alerts = append(alerts, Alert{"CRITICAL", "rate-reverted",
			"exchangeRate() reverts (BackingVanished breaker open) — alarm-1-equivalent; the CRE cannot push, " +
				"the Base feed will stale, consumers fail closed. Runbook §C3."})
	}

	if prev == nil {
		return alerts
	}

	// Alarm 2 — emission only adds; a drop that is not a redemption is a hotkey event.
	if prev.Stake.Sign() > 0 && cur.Stake.Cmp(prev.Stake) < 0 {
		drop := new(big.Int).Sub(prev.Stake, cur.Stake)
		beyond := new(big.Int).Mul(drop, big.NewInt(10_000)).Cmp(
			new(big.Int).Mul(prev.Stake, new(big.Int).SetUint64(th.StakeDropBps))) > 0
		if beyond {
			redeemed, err := hadRedeem(prev.Block, cur.Block)
			switch {
			case err != nil:
				alerts = append(alerts, Alert{"CRITICAL", "stake-discontinuity",
					fmt.Sprintf("stake dropped %s (beyond %d bps) and the Redeemed-event check FAILED (%v) — treating as unexplained. Runbook §C3.", drop, th.StakeDropBps, err)})
			case !redeemed:
				alerts = append(alerts, Alert{"CRITICAL", "stake-discontinuity",
					fmt.Sprintf("stake dropped %s (beyond %d bps) with NO Redeemed event in blocks %d..%d — a hotkey event, not an exit. Runbook §C3.", drop, th.StakeDropBps, prev.Block, cur.Block)})
			default:
				alerts = append(alerts, Alert{"INFO", "large-redemption",
					fmt.Sprintf("stake dropped %s (beyond %d bps), explained by Redeemed event(s) in the range.", drop, th.StakeDropBps)})
			}
		}
	}

	// Alarm 3b — a rate jump between polls (either direction) catches the same event from the other
	// side, and catches a bad push upstream of any consumer.
	if !cur.RateReverted && !prev.RateReverted && prev.Rate != nil && prev.Rate.Sign() > 0 && cur.Rate != nil {
		move := new(big.Int).Abs(new(big.Int).Sub(cur.Rate, prev.Rate))
		if new(big.Int).Mul(move, big.NewInt(10_000)).Cmp(
			new(big.Int).Mul(prev.Rate, new(big.Int).SetUint64(th.RateMoveBps))) > 0 {
			alerts = append(alerts, Alert{"CRITICAL", "rate-jump",
				fmt.Sprintf("exchangeRate() moved %s → %s between polls (beyond %d bps).", prev.Rate, cur.Rate, th.RateMoveBps)})
		}
	}

	// Pointer change — legitimate only as a timelocked retarget/migrateTo; anything else is drift.
	if prev.Hotkey != cur.Hotkey {
		alerts = append(alerts, Alert{"WARN", "hotkey-repointed",
			fmt.Sprintf("validatorHotkey changed %s → %s — expected ONLY from a timelocked retarget/migrateTo; verify the timelock executed it.", prev.Hotkey.Hex(), cur.Hotkey.Hex())})
	}

	return alerts
}

// evaluateTransport is the pure alarm-5 core: does the value that LANDED on Base equal the value the
// source actually reports?
//
// Why this alarm exists. `SzAlphaRateOracle.exchangeRate()` serves `min(spot, twap)` over a 24h window, so a
// wrong pushed value takes a full window to reach NAV. That delay is only worth something if somebody looks
// during it — otherwise it just postpones the same outcome. This is the look.
//
// It is an EQUALITY check, not a threshold, and that is the point. Every other rate alarm here is a
// heuristic guessing whether a move is "too big"; a real slash is large and legitimate, so those thresholds
// can only ever be tuned badly. This one has a correct answer: the raw pushed value on Base must equal
// `SzAlpha.exchangeRate()` on 964, because the job transports the number unchanged with no scaling. Any
// inequality beyond one poll's worth of legitimate drift is a transport fault — a mis-scaled encode, a read
// against the wrong contract or chain, or a stalled job.
//
// It reads the RAW view deliberately. `exchangeRate()` is designed to hide exactly this signal for a window,
// which is protective for consumers and useless for a monitor.
func evaluateTransport(src *Snapshot, base *BaseSnapshot, th Thresholds) []Alert {
	var alerts []Alert
	if base == nil || src == nil {
		return alerts // Base side not configured — the single-chain rehearsal shape
	}

	// Not fresh means every consumer is already failing closed. That is the designed safe state, not a
	// silent one: page it, because it means the job has stopped and nobody is marking xALPHA.
	if !base.Fresh {
		alerts = append(alerts, Alert{"CRITICAL", "rate-feed-stale",
			"SzAlphaRateOracle.fresh() is false — the push job has stopped and every Base consumer is failing " +
				"closed on the xALPHA leg. Issuance is paused; exits still price off the last good mark."})
	}

	// The equality check. Skipped while the source is in the vanished state (it reverts by design, and
	// alarm 1/3a already page that) or before the receiver has ever been seeded.
	if src.RateReverted || src.Rate == nil || base.Raw == nil || base.Raw.Sign() == 0 {
		return alerts
	}
	diff := new(big.Int).Abs(new(big.Int).Sub(base.Raw, src.Rate))
	if diff.Sign() != 0 {
		beyond := new(big.Int).Mul(diff, big.NewInt(10_000)).Cmp(
			new(big.Int).Mul(src.Rate, new(big.Int).SetUint64(th.TransportDriftBps))) > 0
		if beyond {
			alerts = append(alerts, Alert{"CRITICAL", "rate-transport-mismatch",
				fmt.Sprintf("the value on Base does not match the source: 964 exchangeRate()=%s vs Base "+
					"rawExchangeRate()=%s (beyond %d bps). The job transports the number UNCHANGED, so these must "+
					"agree — suspect a mis-scaled encode, a read against the wrong contract/chain, or a stalled "+
					"job. The 24h smoothing is buying time right now; use it.", src.Rate, base.Raw, th.TransportDriftBps)})
		}
	}

	// How much of a bad value is still being withheld from consumers. Not itself a fault: it is the
	// smoothing working, and it tells the responder how long they have left.
	if base.Smoothed != nil && base.Smoothed.Cmp(base.Raw) != 0 {
		alerts = append(alerts, Alert{"INFO", "rate-smoothing-active",
			fmt.Sprintf("consumers are seeing %s while the last push was %s — the TWAP is still absorbing the "+
				"difference.", base.Smoothed, base.Raw)})
	}
	return alerts
}

// evaluateMetagraph is the pure alarm-4 core: the configured hotkey's registration + dividends as read
// from the metagraph precompile (mechanism 0 only — documented limitation; the python watcher is the
// substrate-complete version).
func evaluateMetagraph(found bool, dividends uint64) []Alert {
	if !found {
		return []Alert{{"CRITICAL", "hotkey-unregistered",
			"configured hotkey absent from the subnet metagraph (mechanism 0) — deregistration or drift; verify on substrate and prepare §C3."}}
	}
	if dividends == 0 {
		return []Alert{{"WARN", "hotkey-zero-dividends",
			"configured hotkey earns zero dividends — dead weight, the rate will flatline; consider a voluntary migrateTo."}}
	}
	return nil
}

// ──────────────────────────────────────────────────────────────────────── revert classification

// dataError is go-ethereum's rpc.DataError shape: an error carrying EVM return data — i.e. a REVERT,
// as opposed to a transport/RPC failure.
type dataError interface{ ErrorData() interface{} }

// isRevert distinguishes an EVM revert (the breaker state — an ALARM) from a transport error (a skipped
// tick). Fail toward the transport reading only when neither signal is present.
func isRevert(err error) bool {
	var de dataError
	if errors.As(err, &de) {
		return true
	}
	return strings.Contains(strings.ToLower(err.Error()), "execution reverted")
}

// ──────────────────────────────────────────────────────────────────────── the RPC layer

// caller is the minimal read seam (satisfied by ethclient.Client); injected so tests never dial.
type caller interface {
	BlockNumber(ctx context.Context) (uint64, error)
	CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error)
	FilterLogs(ctx context.Context, q ethereum.FilterQuery) ([]types.Log, error)
}

func selector(sig string) []byte { return crypto.Keccak256([]byte(sig))[:4] }

func callView(ctx context.Context, c caller, to common.Address, data []byte) ([]byte, error) {
	return c.CallContract(ctx, ethereum.CallMsg{To: &to, Data: data}, nil)
}

func decodeUint(data []byte) (*big.Int, error) {
	u256, _ := abi.NewType("uint256", "", nil)
	out, err := abi.Arguments{{Type: u256}}.Unpack(data)
	if err != nil {
		return nil, err
	}
	return out[0].(*big.Int), nil
}

func callUint(ctx context.Context, c caller, to common.Address, sig string) (*big.Int, error) {
	data, err := callView(ctx, c, to, selector(sig))
	if err != nil {
		return nil, err
	}
	return decodeUint(data)
}

// callUint16Args calls sig with uint16 args (the metagraph precompile's shape) and decodes one uint.
func callUint16Args(ctx context.Context, c caller, to common.Address, sig string, args ...uint16) (*big.Int, error) {
	u16, _ := abi.NewType("uint16", "", nil)
	abiArgs := make(abi.Arguments, len(args))
	vals := make([]interface{}, len(args))
	for i, a := range args {
		abiArgs[i] = abi.Argument{Type: u16}
		vals[i] = a
	}
	packed, err := abiArgs.Pack(vals...)
	if err != nil {
		return nil, err
	}
	data, err := callView(ctx, c, to, append(selector(sig), packed...))
	if err != nil {
		return nil, err
	}
	return decodeUint(data)
}

// watcher owns the poll state.
type watcher struct {
	client    caller
	szAlpha   common.Address
	metagraph common.Address
	netuid    uint16
	cachedUID int64 // -1 = unknown; the last uid the configured hotkey was found at
}

// baseWatcher reads the Base-side receiver for alarm 5. Separate from `watcher` because it is a different
// chain and a different client, and because a Base outage must never suppress the 964 alarms.
type baseWatcher struct {
	client     caller
	rateOracle common.Address
}

func newBaseWatcher(client caller, rateOracle common.Address) *baseWatcher {
	return &baseWatcher{client: client, rateOracle: rateOracle}
}

// snapshot reads the receiver's raw + smoothed rate and its freshness. `rawExchangeRate()` is the one that
// matters for the transport check: `exchangeRate()` is the smoothed value and is designed to withhold
// exactly the discrepancy this alarm is looking for.
func (b *baseWatcher) snapshot(ctx context.Context) (*BaseSnapshot, error) {
	raw, err := callUint(ctx, b.client, b.rateOracle, "rawExchangeRate()")
	if err != nil {
		return nil, err
	}
	smoothed, err := callUint(ctx, b.client, b.rateOracle, "exchangeRate()")
	if err != nil {
		return nil, err
	}
	freshWord, err := callUint(ctx, b.client, b.rateOracle, "fresh()")
	if err != nil {
		return nil, err
	}
	return &BaseSnapshot{Raw: raw, Smoothed: smoothed, Fresh: freshWord.Sign() != 0}, nil
}

func newWatcher(client caller, szAlpha common.Address, netuid uint16) *watcher {
	return &watcher{
		client:    client,
		szAlpha:   szAlpha,
		metagraph: common.HexToAddress(metagraphPrecompile),
		netuid:    netuid,
		cachedUID: -1,
	}
}

// snapshot reads one tick's Snapshot. A transport error anywhere returns err (skip the tick); a REVERT
// on exchangeRate() is captured as RateReverted (an alarm input, not an error).
func (w *watcher) snapshot(ctx context.Context) (*Snapshot, error) {
	block, err := w.client.BlockNumber(ctx)
	if err != nil {
		return nil, fmt.Errorf("blockNumber: %w", err)
	}
	stake, err := callUint(ctx, w.client, w.szAlpha, "totalStaked()")
	if err != nil {
		return nil, fmt.Errorf("totalStaked: %w", err)
	}
	supply, err := callUint(ctx, w.client, w.szAlpha, "totalSupply()")
	if err != nil {
		return nil, fmt.Errorf("totalSupply: %w", err)
	}
	hotRaw, err := callView(ctx, w.client, w.szAlpha, selector("validatorHotkey()"))
	if err != nil || len(hotRaw) < 32 {
		return nil, fmt.Errorf("validatorHotkey: %w", err)
	}
	snap := &Snapshot{Block: block, Stake: stake, Supply: supply, Hotkey: common.BytesToHash(hotRaw[:32])}

	rate, err := callUint(ctx, w.client, w.szAlpha, "exchangeRate()")
	switch {
	case err == nil:
		snap.Rate = rate
	case isRevert(err):
		snap.RateReverted = true // the breaker state — an alarm input, never a script error
	default:
		return nil, fmt.Errorf("exchangeRate (transport): %w", err)
	}
	return snap, nil
}

// hadRedeem reports whether any Redeemed event landed on the wrapper in (fromBlock, toBlock].
func (w *watcher) hadRedeem(ctx context.Context, fromBlock, toBlock uint64) (bool, error) {
	logs, err := w.client.FilterLogs(ctx, ethereum.FilterQuery{
		FromBlock: new(big.Int).SetUint64(fromBlock + 1),
		ToBlock:   new(big.Int).SetUint64(toBlock),
		Addresses: []common.Address{w.szAlpha},
		Topics:    [][]common.Hash{{redeemedTopic}},
	})
	if err != nil {
		return false, err
	}
	return len(logs) > 0, nil
}

// checkMetagraph runs the alarm-4 read: locate the configured hotkey's uid (cached across ticks; full
// rescan on a miss) and read its dividends. Mechanism 0 only — see the header.
func (w *watcher) checkMetagraph(ctx context.Context, hotkey common.Hash) ([]Alert, error) {
	verify := func(uid uint16) (bool, error) {
		got, err := callView(ctx, w.client, w.metagraph, append(selector("getHotkey(uint16,uint16)"), mustPackUint16(w.netuid, uid)...))
		if err != nil || len(got) < 32 {
			return false, err
		}
		return common.BytesToHash(got[:32]) == hotkey, nil
	}

	found := false
	if w.cachedUID >= 0 {
		ok, err := verify(uint16(w.cachedUID))
		if err != nil {
			return nil, err
		}
		found = ok
	}
	if !found {
		countBig, err := callUint16Args(ctx, w.client, w.metagraph, "getUidCount(uint16)", w.netuid)
		if err != nil {
			return nil, err
		}
		count := countBig.Uint64()
		w.cachedUID = -1
		for uid := uint64(0); uid < count; uid++ {
			ok, err := verify(uint16(uid))
			if err != nil {
				return nil, err
			}
			if ok {
				w.cachedUID = int64(uid)
				found = true
				break
			}
		}
	}
	if !found {
		return evaluateMetagraph(false, 0), nil
	}
	div, err := callUint16Args(ctx, w.client, w.metagraph, "getDividends(uint16,uint16)", w.netuid, uint16(w.cachedUID))
	if err != nil {
		return nil, err
	}
	return evaluateMetagraph(true, div.Uint64()), nil
}

func mustPackUint16(vals ...uint16) []byte {
	u16, _ := abi.NewType("uint16", "", nil)
	abiArgs := make(abi.Arguments, len(vals))
	ifaces := make([]interface{}, len(vals))
	for i, v := range vals {
		abiArgs[i] = abi.Argument{Type: u16}
		ifaces[i] = v
	}
	out, _ := abiArgs.Pack(ifaces...)
	return out
}

// ──────────────────────────────────────────────────────────────────────── the alert sink

// postWebhook delivers one alert as {"text": "..."} — the Slack/Discord-compatible minimal shape.
// Failures are the caller's to log; alerting must never crash the watcher.
func postWebhook(ctx context.Context, url string, a Alert) error {
	body, err := json.Marshal(map[string]string{"text": fmt.Sprintf("[szalpha-watch] %s %s: %s", a.Severity, a.Code, a.Msg)})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("webhook status %d", resp.StatusCode)
	}
	return nil
}
