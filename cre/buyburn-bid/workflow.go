// SPDX-License-Identifier: GPL-2.0-or-later
//
// BuyBurnBidWorkflow (CRE-05a) — the buy-burn bid-automation loop for szipUSD exits.
//
// Job: maintain the SINGLE resting buy-burn bid on the post-CTR-01 SzipBuyBurnModule via the §8.0 report path
// (POST_BID=1 / CANCEL_BID=2). It reads the live bid + the chain-derived price ceiling + the free reservoir off
// EulerEarn, sizes one bid (clamped to buybackCap, net of working-capital reserves), and reconciles it: post when
// none rests and the position is fundable/fresh/covered; repost on size drift OR price drift (SEC/L-7 — a resting
// bid must never keep quoting a mark the oracle has since re-priced); cancel when the bid must come down.
//
// It NEVER computes NAV/APR off-chain and NEVER submits a raw tx — the only write is WriteReport. One bid, repost
// on drift (single-resting-bid invariant, driver §4).
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// BUILD BOUNDARY (like szalpha-rate's). PINNED EXACT (the contract handshake — must byte-match
// SzipBuyBurnModule._processReport): the §8.0 envelope abi.encode(uint8 reportType, bytes payload); POST_BID=1 with
// payload abi.encode(uint256 sellAmount, uint256 buyAmount, uint32 validTo); CANCEL_BID=2 with an EMPTY payload.
// CONFIG: the addresses + chain selector + schedule + driftBps + ttlSeconds + the harvestReserve/safetyBuffer
// working-capital split (CRE-06 folded in here as constants — a dynamic, utilization-aware policy is a later
// parameter swap, not a redesign). DEFERRED: the CoW Trade fill log-trigger (phase-2; for MVP a fill is detected as
// a currentSellAmount drop on the next tick); the dynamic reserve policy.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	httpcap "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
)

// Receiver-scoped report types (SzipBuyBurnModule.sol): POST_BID=1, CANCEL_BID=2.
const (
	postBidReportType   uint8 = 1
	cancelBidReportType uint8 = 2
)

const (
	writeGasLimit = uint64(600_000)
	maxBidTTL     = uint64(86_400) // SzipBuyBurnModule.MAX_BID_TTL — the hard ceiling on a resting bid's validTo.
)

// RedemptionSettled is on ZipRedemptionQueue (NOT the buy-burn module): the canonical signature whose keccak256 is
// the LogTrigger topic0 (all four args are non-indexed → topic0 is the only topic).
const redemptionSettledSig = "RedemptionSettled(uint256,uint256,uint256,uint256)"

type Config struct {
	Schedule       string `json:"schedule"`       // heartbeat cron, e.g. "0 */5 * * * *"
	ChainSelector  uint64 `json:"chainSelector"`  // the chain hosting the module + queue + EulerEarn
	BuyBurnModule  string `json:"buyBurnModule"`  // SzipBuyBurnModule (the report receiver)
	NavOracle      string `json:"navOracle"`      // SzipNavOracle
	CoverageGate   string `json:"coverageGate"`   // ICoverageGate (DurationFreezeModule); zero address ⇒ treat covered() = true
	EulerEarn      string `json:"eulerEarn"`      // the EulerEarn senior pool (ERC4626)
	Warehouse      string `json:"warehouse"`      // the warehouse holding the senior position (the §8.2 read subject)
	RedemptionQueue string `json:"redemptionQueue"` // ZipRedemptionQueue (the RedemptionSettled emitter)

	DriftBps       uint64 `json:"driftBps"`       // repost threshold: resize the bid when |Δsize| in bps ≥ this
	PriceDriftBps  uint64 `json:"priceDriftBps"`  // repost threshold: reprice when |posted price − quoteMaxPrice| in bps ≥ this (SEC/L-7); 0 ⇒ falls back to driftBps (drift reconcile is never silently off)
	TTLSeconds     uint64 `json:"ttlSeconds"`     // desired bid lifetime (clamped by the NAV-freshness fence + MAX_BID_TTL)
	HarvestReserve string `json:"harvestReserve"` // 6-dp USDC held back for the harvest engine (CRE-06 constant)
	SafetyBuffer   string `json:"safetyBuffer"`   // 6-dp USDC operational buffer (CRE-06 constant)

	// DEMAND GATE (ratified 2026-07-30): the protocol only fills — it never makes a market. A bid is posted only
	// against sell orders ALREADY resting on the CoW book at an acceptable price (≤ quoteMaxPrice, the current
	// fair ceiling), sized to exactly that demand. Empty OrderbookURL ⇒ gate OFF (build/sim back-compat only —
	// production config MUST set it). SzipUSD/Usdc identify the pair on the book.
	OrderbookURL string `json:"orderbookUrl"` // CoW orderbook API base, e.g. "https://api.cow.fi/base"
	SzipUSD      string `json:"szipUsd"`      // the share token (the book's sellToken side)
	Usdc         string `json:"usdc"`         // the payment token (the book's buyToken side)
}

func initFn(cfg *Config, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[*Config], error) {
	filter := &evm.FilterLogTriggerRequest{
		Addresses: [][]byte{common.HexToAddress(cfg.RedemptionQueue).Bytes()},
		Topics: []*evm.TopicValues{
			{Values: [][]byte{redemptionSettledTopic0().Bytes()}},
		},
	}
	return cre.Workflow[*Config]{
		cre.Handler(cron.Trigger(&cron.Config{Schedule: cfg.Schedule}), onCron),
		cre.Handler(evm.LogTrigger(cfg.ChainSelector, filter), onLog),
	}, nil
}

// Two triggers, two callbacks, one body: heartbeat and event paths reconcile identically (C4).
func onCron(cfg *Config, runtime cre.Runtime, _ *cron.Payload) (struct{}, error) {
	return evaluateAndReconcile(cfg, runtime)
}

func onLog(cfg *Config, runtime cre.Runtime, _ *evm.Log) (struct{}, error) {
	return evaluateAndReconcile(cfg, runtime)
}

// evaluateAndReconcile runs the whole control loop: read state → size → price → reconcile the single resting bid.
func evaluateAndReconcile(cfg *Config, runtime cre.Runtime) (struct{}, error) {
	client := &evm.Client{ChainSelector: cfg.ChainSelector}
	moduleAddr := common.HexToAddress(cfg.BuyBurnModule)

	// --- Reads (all view CallContract; decode the return) -----------------------------------------------------
	uid, currentSellAmount, err := readCurrentBid(client, runtime, moduleAddr)
	if err != nil {
		return struct{}{}, err
	}

	// --- LP-TWAP halt gate (audit F8) --------------------------------------------------------------------------
	// A replaced/reset Algebra plugin restarts with EMPTY history; until the 1h window re-accumulates, every NAV
	// read (quoteMaxPrice ← navExit) reverts LpTwapHistoryTooShort. Probe the oracle's NON-REVERTING status view
	// FIRST so a halt surfaces as a legible status + a skipped round, not an opaque errored run. A resting bid is
	// cancelled: it would keep quoting a pre-halt mark that fills cannot be re-checked against while NAV is halted.
	// Self-healing — the first tick at/after readyAt resumes business as usual with nothing to unpause.
	twapReady, twapPlugin, twapReadyAt, err := readLpTwapStatus(client, runtime, common.HexToAddress(cfg.NavOracle))
	if err != nil {
		return struct{}{}, err
	}
	if !twapReady {
		eta := "no ETA -- the pool has no initialized plugin yet"
		if twapReadyAt.Sign() > 0 {
			eta = fmt.Sprintf("resuming at %s (unix %d) once 1h of price history has accumulated",
				time.Unix(twapReadyAt.Int64(), 0).UTC().Format(time.RFC3339), twapReadyAt)
		}
		runtime.Logger().Warn(fmt.Sprintf(
			"Algebra pool plugin %s has been replaced/reset; TWAP NAV oracle is halted. %s. Skipping bid round.",
			twapPlugin.Hex(), eta))
		if len(uid) != 0 {
			return struct{}{}, writeCancel(client, runtime, moduleAddr)
		}
		return struct{}{}, nil
	}

	currentBuyAmount, err := readUint(client, runtime, moduleAddr, "currentBuyAmount()")
	if err != nil {
		return struct{}{}, err
	}
	maxPrice, err := readUint(client, runtime, moduleAddr, "quoteMaxPrice()")
	if err != nil {
		return struct{}{}, err
	}
	buybackCap, err := readUint(client, runtime, moduleAddr, "buybackCap()")
	if err != nil {
		return struct{}{}, err
	}

	fresh, err := readBool(client, runtime, common.HexToAddress(cfg.NavOracle), "fresh()")
	if err != nil {
		return struct{}{}, err
	}
	maxAge, err := readUint(client, runtime, common.HexToAddress(cfg.NavOracle), "maxAge()")
	if err != nil {
		return struct{}{}, err
	}
	oldestLeg, err := readUint(client, runtime, common.HexToAddress(cfg.NavOracle), "oldestRequiredLegTs()")
	if err != nil {
		return struct{}{}, err
	}

	covered := true
	if gate := common.HexToAddress(cfg.CoverageGate); gate != (common.Address{}) {
		covered, err = readBool(client, runtime, gate, "covered()")
		if err != nil {
			return struct{}{}, err
		}
	}

	// Free reservoir off EulerEarn, read the donation-immune way §8.2 mandates (maxWithdraw / convertToAssets —
	// NOT IERC20.balanceOf(eulerEarn)). freeReservoir = maxWithdraw(warehouse).
	warehouse := common.HexToAddress(cfg.Warehouse)
	freeReservoir, err := readUintWithAddr(client, runtime, common.HexToAddress(cfg.EulerEarn), "maxWithdraw(address)", warehouse)
	if err != nil {
		return struct{}{}, err
	}

	// --- Size (CRE-06 split folded in) ------------------------------------------------------------------------
	harvestReserve := mustBig(cfg.HarvestReserve)
	safetyBuffer := mustBig(cfg.SafetyBuffer)
	avail := new(big.Int).Sub(new(big.Int).Sub(freeReservoir, harvestReserve), safetyBuffer)
	targetSell := clamp(avail, big.NewInt(0), buybackCap)

	// --- Demand gate (ratified 2026-07-30: fill-only, never market-make) ---------------------------------------
	// Read the CoW book for resting szipUSD→USDC sell orders asking ≤ the CURRENT fair ceiling (quoteMaxPrice).
	// The bid is sized to min(that demand, cash): no acceptable resting order ⇒ no bid ⇒ no resting protocol
	// price to go stale. Fail-closed: an unreachable book ⇒ demand 0 ⇒ nothing posts (and a live bid cancels).
	if cfg.OrderbookURL != "" && maxPrice.Sign() > 0 {
		demandUSDC, derr := acceptableDemandUSDC(cfg, runtime, maxPrice)
		if derr != nil {
			runtime.Logger().Warn(fmt.Sprintf("orderbook read failed (%v); demand gate fails closed this tick", derr))
			demandUSDC = big.NewInt(0)
		}
		targetSell = clamp(demandUSDC, big.NewInt(0), targetSell)
	}

	// --- Price ------------------------------------------------------------------------------------------------
	// maxPrice == 0 ⇒ no fresh mark; skip posting (targetBuy is undefined). targetBuy = ceilDiv(sell·1e18, maxPrice).
	var targetBuy *big.Int
	if maxPrice.Sign() > 0 {
		targetBuy = ceilDiv(new(big.Int).Mul(targetSell, big.NewInt(1e18)), maxPrice)
	}

	// --- validTo (defensive, fail-closed-by-skipping) ---------------------------------------------------------
	now := uint64(runtime.Now().Unix())
	validTo := computeValidTo(now, cfg.TTLSeconds, oldestLeg, maxAge)

	// --- Reconcile (single resting bid) -----------------------------------------------------------------------
	postable := targetSell.Sign() > 0 && fresh && covered && maxPrice.Sign() > 0 && validTo > now
	hasLiveBid := len(uid) != 0

	switch {
	case !hasLiveBid:
		if postable {
			return struct{}{}, writeBid(client, runtime, moduleAddr, targetSell, targetBuy, uint32(validTo))
		}
		return struct{}{}, nil // no-op

	default: // a bid is live
		if !postable {
			return struct{}{}, writeCancel(client, runtime, moduleAddr)
		}
		// SEC/L-7 price-drift reconcile: a resting bid keeps quoting the price it was POSTED at even after the
		// oracle re-prices navExit — the stale-high side of that is the Octane V7 window. Derive the posted
		// implied price from the module's live-bid state (sell·1e18/buy, 6-dp USDC per 1e18 share — the same unit
		// as quoteMaxPrice) and cancel-and-repost when it has drifted ≥ priceDriftBps from the CURRENT ceiling.
		// Symmetric on purpose: stale-HIGH overpays the treasury side, stale-LOW under-bids the exit lane.
		reprice := driftBps(maxPrice, postedPrice(currentSellAmount, currentBuyAmount)).Uint64() >= priceDriftThreshold(cfg)
		if reprice || driftBps(targetSell, currentSellAmount).Uint64() >= cfg.DriftBps {
			// The module's BidAlreadyLive requires cancel-before-repost; they cannot be atomic → sequential Awaits.
			if err := writeCancel(client, runtime, moduleAddr); err != nil {
				return struct{}{}, err
			}
			return struct{}{}, writeBid(client, runtime, moduleAddr, targetSell, targetBuy, uint32(validTo))
		}
		return struct{}{}, nil // bid still good — no-op
	}
}

// ──────────────────────────────────────────────────────────────────────────── the demand gate (fill-only)

// cowOrder is the slice of a CoW orderbook auction order this gate reads. Amounts are decimal strings.
type cowOrder struct {
	SellToken  string `json:"sellToken"`
	BuyToken   string `json:"buyToken"`
	SellAmount string `json:"sellAmount"`
	BuyAmount  string `json:"buyAmount"`
	Kind       string `json:"kind"`
}

type cowAuction struct {
	Orders []cowOrder `json:"orders"`
}

// demandQuery is the node-mode observation carrier: everything a node needs to fetch + filter the book.
type demandQuery struct {
	URL      string // {OrderbookURL}/api/v1/auction
	SzipUSD  string // lowercased hex
	Usdc     string // lowercased hex
	MaxPrice string // quoteMaxPrice() at read time, 6-dp USDC per 1e18 share, decimal string
}

// acceptableDemandUSDC reads the CoW book per node and returns (median-aggregated) the USDC needed to fill every
// resting szipUSD→USDC SELL order whose asking price is at or below the current fair ceiling (maxPrice). An order
// asking sellAmount shares for buyAmount USDC has price buyAmount·1e18/sellAmount; acceptable ⇔ price ≤ maxPrice.
// USDC needed for the acceptable set = ceil(Σshares · maxPrice / 1e18) — we fund at OUR ceiling, the module's
// exact price bound enforces the rest. Median (not identical) consensus: nodes may see the book seconds apart.
func acceptableDemandUSDC(cfg *Config, runtime cre.Runtime, maxPrice *big.Int) (*big.Int, error) {
	q := demandQuery{
		URL:      strings.TrimRight(cfg.OrderbookURL, "/") + "/api/v1/auction",
		SzipUSD:  strings.ToLower(cfg.SzipUSD),
		Usdc:     strings.ToLower(cfg.Usdc),
		MaxPrice: maxPrice.String(),
	}
	return cre.RunInNodeMode(q, runtime, observeDemand, cre.ConsensusMedianAggregation[*big.Int]()).Await()
}

func observeDemand(q demandQuery, nr cre.NodeRuntime) (*big.Int, error) {
	client := &httpcap.Client{}
	resp, err := client.SendRequest(nr, &httpcap.Request{Url: q.URL, Method: "GET"}).Await()
	if err != nil {
		return nil, fmt.Errorf("orderbook fetch: %w", err)
	}
	var auction cowAuction
	if err := json.Unmarshal(resp.Body, &auction); err != nil {
		return nil, fmt.Errorf("orderbook decode: %w", err)
	}
	maxPrice, ok := new(big.Int).SetString(q.MaxPrice, 10)
	if !ok || maxPrice.Sign() <= 0 {
		return nil, fmt.Errorf("bad maxPrice carrier %q", q.MaxPrice)
	}
	oneE18 := big.NewInt(1e18)
	shares := big.NewInt(0)
	for _, o := range auction.Orders {
		if o.Kind != "sell" || strings.ToLower(o.SellToken) != q.SzipUSD || strings.ToLower(o.BuyToken) != q.Usdc {
			continue
		}
		sell, okS := new(big.Int).SetString(o.SellAmount, 10)
		buy, okB := new(big.Int).SetString(o.BuyAmount, 10)
		if !okS || !okB || sell.Sign() <= 0 || buy.Sign() < 0 {
			continue
		}
		// asking price ≤ ceiling ⇔ buy·1e18 ≤ maxPrice·sell (exact integer form, no division)
		ask := new(big.Int).Mul(buy, oneE18)
		ceil := new(big.Int).Mul(maxPrice, sell)
		if ask.Cmp(ceil) <= 0 {
			shares.Add(shares, sell)
		}
	}
	return ceilDiv(new(big.Int).Mul(shares, maxPrice), oneE18), nil
}

// postedPrice derives the live bid's implied price (6-dp USDC per 1e18 share) from the module's exposed
// (currentSellAmount, currentBuyAmount) pair: floor(sell·1e18/buy). Returns 0 when no bid state (buy == 0) —
// driftBps against 0 then reads 10_000 bps, which correctly forces a reprice of any malformed live state.
func postedPrice(sell, buy *big.Int) *big.Int {
	if buy == nil || buy.Sign() <= 0 {
		return big.NewInt(0)
	}
	return new(big.Int).Div(new(big.Int).Mul(sell, big.NewInt(1e18)), buy)
}

// priceDriftThreshold: the SEC/L-7 reprice threshold. An unset priceDriftBps (0) falls back to driftBps so the
// price reconcile can never be silently configured off.
func priceDriftThreshold(cfg *Config) uint64 {
	if cfg.PriceDriftBps != 0 {
		return cfg.PriceDriftBps
	}
	return cfg.DriftBps
}

// computeValidTo: fence = oldestRequiredLegTs + maxAge; validTo = min(now+ttl, fence, now+MAX_BID_TTL). The fence and
// the absolute ceiling are computed in big.Int to avoid uint64 overflow, then clamped down to now+ttl. A validTo <=
// now (legs too stale) is left as-is and the caller skips posting (fail-closed).
func computeValidTo(now, ttlSeconds uint64, oldestLeg, maxAge *big.Int) uint64 {
	nowBig := new(big.Int).SetUint64(now)
	candidates := []*big.Int{
		new(big.Int).SetUint64(now + ttlSeconds),
		new(big.Int).Add(oldestLeg, maxAge),         // the NAV-freshness fence
		new(big.Int).SetUint64(now + maxBidTTL),      // MAX_BID_TTL
	}
	min := candidates[0]
	for _, c := range candidates[1:] {
		if c.Cmp(min) < 0 {
			min = c
		}
	}
	if min.Cmp(nowBig) <= 0 {
		return now // validTo <= now ⇒ stale-legs skip (postable becomes false: validTo > now fails)
	}
	return min.Uint64()
}

// driftBps = |target − current| · 10_000 / max(current, 1). Shared by the size reconcile (targetSell vs
// currentSellAmount) and the SEC/L-7 price reconcile (quoteMaxPrice vs the posted implied price).
func driftBps(target, current *big.Int) *big.Int {
	diff := new(big.Int).Abs(new(big.Int).Sub(target, current))
	denom := new(big.Int).Set(current)
	if denom.Sign() <= 0 {
		denom = big.NewInt(1)
	}
	return new(big.Int).Div(new(big.Int).Mul(diff, big.NewInt(10_000)), denom)
}

// clamp(v, lo, hi) = min(max(v, lo), hi).
func clamp(v, lo, hi *big.Int) *big.Int {
	out := new(big.Int).Set(v)
	if out.Cmp(lo) < 0 {
		out.Set(lo)
	}
	if out.Cmp(hi) > 0 {
		out.Set(hi)
	}
	return out
}

// ceilDiv(a, b) = (a + b − 1) / b (ceil so the implied price ≤ maxPrice; the on-chain BidAboveDiscount bound passes).
func ceilDiv(a, b *big.Int) *big.Int {
	num := new(big.Int).Sub(new(big.Int).Add(a, b), big.NewInt(1))
	return new(big.Int).Div(num, b)
}

// --------------------------------------------------------------------- the §8.0 handshake (pinned EXACT)

// encodeEnvelope packs the §8.0 envelope abi.encode(uint8 reportType, bytes payload).
func encodeEnvelope(reportType uint8, payload []byte) []byte {
	u8, _ := abi.NewType("uint8", "", nil)
	bts, _ := abi.NewType("bytes", "", nil)
	out, _ := abi.Arguments{{Type: u8}, {Type: bts}}.Pack(reportType, payload)
	return out
}

// encodePostBidPayload packs abi.encode(uint256 sellAmount, uint256 buyAmount, uint32 validTo) — the EXACT tuple
// SzipBuyBurnModule._processReport decodes for POST_BID.
//
// NOTE (deviation from C6's literal form): go-ethereum v1.17.2's abi.Pack requires a NATIVE uint32 for a uint32 arg
// and rejects a *big.Int ("cannot use ptr as type uint32"). C6 pinned `new(big.Int).SetUint64(uint64(validTo))`
// against an older abi; the produced ABI bytes are identical either way, so we pass the native uint32 the current
// go-ethereum accepts. The (uint256,uint256,uint32) layout — the load-bearing handshake — is unchanged.
func encodePostBidPayload(sell, buy *big.Int, validTo uint32) ([]byte, error) {
	u256, _ := abi.NewType("uint256", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	return abi.Arguments{{Type: u256}, {Type: u256}, {Type: u32}}.Pack(sell, buy, validTo)
}

// writeBid generates + writes a POST_BID report to the buy-burn module.
func writeBid(client *evm.Client, runtime cre.Runtime, module common.Address, sell, buy *big.Int, validTo uint32) error {
	payload, err := encodePostBidPayload(sell, buy, validTo)
	if err != nil {
		return err
	}
	return write(client, runtime, module, postBidReportType, payload)
}

// writeCancel generates + writes a CANCEL_BID report (EMPTY payload — the contract ignores it).
func writeCancel(client *evm.Client, runtime cre.Runtime, module common.Address) error {
	return write(client, runtime, module, cancelBidReportType, []byte{})
}

func write(client *evm.Client, runtime cre.Runtime, module common.Address, reportType uint8, payload []byte) error {
	report, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: encodeEnvelope(reportType, payload),
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		return err
	}
	_, err = client.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  module.Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: writeGasLimit},
	}).Await()
	return err
}

// --------------------------------------------------------------------- reads (C3)

// selector returns the 4-byte function selector for the canonical signature, e.g. "currentBid()".
func selector(sig string) []byte {
	return crypto.Keccak256([]byte(sig))[:4]
}

// redemptionSettledTopic0 = keccak256(canonical RedemptionSettled signature) (C5).
func redemptionSettledTopic0() common.Hash {
	return crypto.Keccak256Hash([]byte(redemptionSettledSig))
}

// readLpTwapStatus reads SzipNavOracle.lpTwapStatus() → (bool ready, address plugin, uint256 readyAt) — the
// non-reverting probe of the LP-TWAP history halt (audit F8). ready=false ⇒ every NAV read currently reverts
// LpTwapHistoryTooShort(plugin, readyAt); readyAt==0 ⇒ no initialized plugin at all (no ETA).
func readLpTwapStatus(client *evm.Client, runtime cre.Runtime, addr common.Address) (bool, common.Address, *big.Int, error) {
	data, err := call(client, runtime, addr, selector("lpTwapStatus()"))
	if err != nil {
		return false, common.Address{}, nil, err
	}
	boolT, _ := abi.NewType("bool", "", nil)
	addrT, _ := abi.NewType("address", "", nil)
	u256, _ := abi.NewType("uint256", "", nil)
	out, err := abi.Arguments{{Type: boolT}, {Type: addrT}, {Type: u256}}.Unpack(data)
	if err != nil {
		return false, common.Address{}, nil, err
	}
	return out[0].(bool), out[1].(common.Address), out[2].(*big.Int), nil
}

// readCurrentBid reads SzipBuyBurnModule.currentBid() → (bytes uid, uint256 sellAmount).
func readCurrentBid(client *evm.Client, runtime cre.Runtime, addr common.Address) ([]byte, *big.Int, error) {
	data, err := call(client, runtime, addr, selector("currentBid()"))
	if err != nil {
		return nil, nil, err
	}
	bytesT, _ := abi.NewType("bytes", "", nil)
	u256, _ := abi.NewType("uint256", "", nil)
	out, err := abi.Arguments{{Type: bytesT}, {Type: u256}}.Unpack(data)
	if err != nil {
		return nil, nil, err
	}
	return out[0].([]byte), out[1].(*big.Int), nil
}

// readUint reads a no-arg view returning a single uint (uint256/uint48/uint16 all decode into *big.Int).
func readUint(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string) (*big.Int, error) {
	data, err := call(client, runtime, addr, selector(sig))
	if err != nil {
		return nil, err
	}
	return decodeUint(data)
}

// readUintWithAddr reads a single-address-arg view returning a uint (e.g. maxWithdraw(address)).
func readUintWithAddr(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string, arg common.Address) (*big.Int, error) {
	addrT, _ := abi.NewType("address", "", nil)
	packed, err := abi.Arguments{{Type: addrT}}.Pack(arg)
	if err != nil {
		return nil, err
	}
	data, err := call(client, runtime, addr, append(selector(sig), packed...))
	if err != nil {
		return nil, err
	}
	return decodeUint(data)
}

func decodeUint(data []byte) (*big.Int, error) {
	u256, _ := abi.NewType("uint256", "", nil)
	out, err := abi.Arguments{{Type: u256}}.Unpack(data)
	if err != nil {
		return nil, err
	}
	return out[0].(*big.Int), nil
}

// readBool reads a no-arg view returning a single bool.
func readBool(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string) (bool, error) {
	data, err := call(client, runtime, addr, selector(sig))
	if err != nil {
		return false, err
	}
	boolT, _ := abi.NewType("bool", "", nil)
	out, err := abi.Arguments{{Type: boolT}}.Unpack(data)
	if err != nil {
		return false, err
	}
	return out[0].(bool), nil
}

func call(client *evm.Client, runtime cre.Runtime, addr common.Address, data []byte) ([]byte, error) {
	reply, err := client.CallContract(runtime, &evm.CallContractRequest{
		Call: &evm.CallMsg{To: addr.Bytes(), Data: data}, // From left nil for views (C3)
	}).Await()
	if err != nil {
		return nil, err
	}
	return reply.Data, nil
}

// mustBig parses a base-10 config string into a *big.Int (0 if empty/unparseable — the conservative direction).
func mustBig(s string) *big.Int {
	if s == "" {
		return big.NewInt(0)
	}
	v, ok := new(big.Int).SetString(s, 10)
	if !ok {
		return big.NewInt(0)
	}
	return v
}
