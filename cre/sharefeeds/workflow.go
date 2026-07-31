// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-03 — the szipUSD share-price feeds producer (§8.6): NAV_LEG, reportType 7.
//
// (The LP_MARK leg was DELETED with its receiver `SzipFarmUtilityLpOracle`: the farm-utility LP collateral is
// priced on-chain by `AlgebraIchiFairLpOracle` (TWAP fair reserves) — a pushed mark composed from spot
// getTotalAmounts was the manipulable surface the TWAP twin exists to price out.)
//
// On the engine epoch (cron) the workflow:
//   (i)   reaches IDENTICAL consensus, in node mode, on the two off-chain leg marks it CANNOT read on Base
//         ({alphaUSD, hydxUsd}, 18-dp; §8.9 mock observe — deterministic config/trigger-supplied LegMarks);
//   (ii)  reads, via DON-mode eth_call, the xALPHA exchangeRate() (the tick gate) and the prior NAV leg
//         cache (legCache(uint8)) for the deviation-band clamp;
//   (iii) emits ONE WriteReport — NAV_LEG → SzipNavOracle — the §8.0 envelope
//         abi.encode(uint8 reportType=7, bytes payload), encoded via the shared cre/zipreport library (CRE-00).
//         This slice does NOT re-implement the handshake.
//
// The producer NEVER pushes xALPHA-USD, oHYDX-USD, the RATE/APR, or per-xALPHA prices — the contract derives
// those on-chain from the two market legs and the trustless exchangeRate(). It pushes only the two market legs
// (alphaUSD per-1.0-ALPHA, HYDX/USD).
//
// Fail-safe no-ops (a liveness-only feed — a no-op tick is the safe outcome): an unset Config receiver skips
// the push; exchangeRate()==0 (unseeded) skips the whole tick; a zero/garbage off-chain mark skips. The NAV
// legs are CLAMPED to the on-chain deviation band so a report never reverts DeviationExceeded.
package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"

	zipreport "cre-zipreport"
)

// defaultWriteGasLimit is the WriteReport GasConfig.GasLimit fallback (used when cfg.WriteGasLimit == 0).
const defaultWriteGasLimit = uint64(600_000)

// defaultMaxDeviationBps is the NAV deviation-band fallback (used when cfg.MaxDeviationBps == 0). It mirrors
// the band the SzipNavOracle enforces per leg; the on-chain value is the source of truth, this is only a
// conservative producer-side default for an unconfigured slot.
const defaultMaxDeviationBps = uint64(500) // 5%

// defaultSchedule pins the engine-epoch heartbeat cadence (used when cfg.Schedule == ""). The cadence is a
// protocol choice, not a per-env detail, so it is pinned here rather than left to the deploy slot — an empty
// slot would otherwise hand cron.Trigger an empty schedule. 6-field cron (sec min hour dom mon dow): every 5
// minutes. With the ±5% per-push band, a large move converges over consecutive epochs well inside the on-chain
// NAV TWAP window, so this cadence needs no material-move companion trigger.
const defaultSchedule = "0 */5 * * * *" // every 5 minutes

var (
	bps10000 = big.NewInt(10_000)
	scale1e18 = func() *big.Int { return new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil) }()
)

// Config is the static workflow config (parsed once at init via cre.ParseJSON[Config]). Every wiring slot
// (§17) is Config-driven and re-pointable — no hardcoded address.
type Config struct {
	ChainSelector   uint64 `json:"chainSelector"`   // the chain hosting the receiver + rate source (Base)
	NavOracle       string `json:"navOracle"`       // SzipNavOracle (the NAV_LEG receiver); unset ⇒ skip the NAV push
	RateSource      string `json:"rateSource"`      // IXAlphaRate.exchangeRate() source (SzAlphaRateOracle or xALPHA stand-in)
	MaxDeviationBps uint64 `json:"maxDeviationBps"` // the NAV per-push band; 0 falls back to 500 (5%)
	Schedule        string `json:"schedule"`        // engine-epoch cron; "" falls back to defaultSchedule ("0 */5 * * * *", every 5 min)
	WriteGasLimit   uint64 `json:"writeGasLimit"`   // WriteReport gas limit; 0 falls back to 600_000

	// MockMarks is the §8.9 mock-feed seam: when non-empty it is the deterministic LegMarks every node
	// observes (identical consensus holds). The real per-node httpcap fetch of alphaUSD (TAO/alpha TWAP ×
	// TAO/USD) + HYDX/USD swaps in here later (the §8.10 source map); the consensus + compose + write
	// machinery is unchanged. JSON-native so it round-trips through ParseJSON[Config].
	MockMarks LegMarks `json:"mockMarks"`
}

// LegMarks is the node-mode consensus carrier (§8.10): base-10 decimal strings of the two 18-dp off-chain
// marks — JSON-native + isIdenticalType-safe + values.Wrap-able. Do NOT put *big.Int here; parse on the DON
// side AFTER consensus (new(big.Int).SetString(s,10); reject ok==false / sign<=0).
type LegMarks struct {
	AlphaUSD string `json:"alphaUSD"` // USD per 1.0 ALPHA, 18-dp (1e18 = $1)
	HydxUsd  string `json:"hydxUsd"`  // HYDX/USD, 18-dp (1e18 = $1)
}

func initFn(c *Config, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[*Config], error) {
	// One trigger: the engine-epoch cron heartbeat (§8.6 cadence). The "AND a material leg move" http.Trigger
	// second handler is intentionally NOT built (not deferred): the ±5% band clamp caps every push regardless of
	// trigger, so large moves converge over consecutive epochs anyway, and the on-chain NAV TWAP lags the
	// protective side regardless of push cadence — a faster push buys no protection the TWAP doesn't provide.
	schedule := c.Schedule
	if schedule == "" {
		schedule = defaultSchedule // pin the cadence; never hand cron.Trigger an empty schedule
	}
	return cre.Workflow[*Config]{
		cre.Handler(cron.Trigger(&cron.Config{Schedule: schedule}), onEpoch),
	}, nil
}

// onEpoch is the single handler. It runs in DON mode: it reaches identical consensus on the off-chain marks
// (node mode), reads the on-chain quantities (DON mode eth_call), composes one coherent computation, and
// emits the two coupled reports.
func onEpoch(c *Config, runtime cre.Runtime, _ *cron.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// (i) Node-mode observation + identical consensus over the LegMarks carrier. The free generic C is the
	// config-supplied mock seam bytes (§8.9): every node observes the IDENTICAL marshaled MockMarks, so
	// identical consensus holds deterministically.
	in, err := json.Marshal(c.MockMarks)
	if err != nil {
		return struct{}{}, fmt.Errorf("onEpoch: marshal mock marks: %w", err)
	}
	marks, err := cre.RunInNodeMode(in, runtime, observe,
		cre.ConsensusIdenticalAggregation[LegMarks]()).Await()
	if err != nil {
		return struct{}{}, err
	}

	// Parse the consensus marks to *big.Int on the DON side. A zero/garbage off-chain mark ⇒ skip the tick
	// (the contract would revert ZeroPrice; pushing an unpriceable leg is pointless).
	alphaUSD, ok := new(big.Int).SetString(marks.AlphaUSD, 10)
	if !ok || alphaUSD.Sign() <= 0 {
		logger.Info("sharefeeds: no-op (alphaUSD mark zero/garbage)")
		return struct{}{}, nil
	}
	hydxUsd, ok := new(big.Int).SetString(marks.HydxUsd, 10)
	if !ok || hydxUsd.Sign() <= 0 {
		logger.Info("sharefeeds: no-op (hydxUsd mark zero/garbage)")
		return struct{}{}, nil
	}

	client := &evm.Client{ChainSelector: c.ChainSelector}

	// (ii) DON-mode reads. The xALPHA exchangeRate() gates the WHOLE tick: unseeded (== 0) ⇒ the NAV contract
	// reverts RateUnseeded on read, so there is nothing to push — no-op (match the contract's fail-closed
	// posture). Read it FIRST.
	exchangeRate, err := readUint(client, runtime, common.HexToAddress(c.RateSource), "exchangeRate()")
	if err != nil {
		return struct{}{}, err
	}
	if exchangeRate.Sign() == 0 {
		logger.Info("sharefeeds: no-op (exchangeRate unseeded)")
		return struct{}{}, nil
	}

	// Prior NAV leg cache (for the band clamp). The band is the NAV receiver's, so read legCache ONLY when a
	// NavOracle is configured; with no NAV oracle there is no prior and no band (the LP mark uses the raw mark).
	// ts == 0 ⇒ unset ⇒ no band (first push lands at the true value).
	maxDev := c.MaxDeviationBps
	if maxDev == 0 {
		maxDev = defaultMaxDeviationBps
	}
	alphaPush := alphaUSD
	hydxPush := hydxUsd
	if c.NavOracle != "" {
		navAddr := common.HexToAddress(c.NavOracle)
		priorAlpha, priorAlphaTs, err := readLegCache(client, runtime, navAddr, zipreport.LegAlphaUsd)
		if err != nil {
			return struct{}{}, err
		}
		priorHydx, priorHydxTs, err := readLegCache(client, runtime, navAddr, zipreport.LegHydxUsd)
		if err != nil {
			return struct{}{}, err
		}
		// (iii) Clamp each leg to the on-chain deviation band (the HYDX leg independently).
		alphaPush = bandClamp(alphaUSD, priorAlpha, priorAlphaTs, maxDev)
		hydxPush = bandClamp(hydxUsd, priorHydx, priorHydxTs, maxDev)
	}

	// DON-side timestamp. uint32(runtime.Now().Unix()) is <= chain time
	// (DON time ≈ chain time → FutureTimestamp never trips) and monotonic across ticks (StaleReport holds).
	ts := uint32(runtime.Now().Unix())

	// NAV_LEG push: legs=[0,1], prices=[alphaPush, hydxPush]. HYDX pushed unconditionally every epoch
	// (FINDING-1: the as-built SzipNavOracle has no on-chain HYDX read and REQUIRES leg 1 fresh for issuance).
	if c.NavOracle != "" {
		legs := []uint8{zipreport.LegAlphaUsd, zipreport.LegHydxUsd}
		prices := []*big.Int{alphaPush, hydxPush}
		envelope, err := zipreport.NavLegReport(legs, prices, ts)
		if err != nil {
			return struct{}{}, fmt.Errorf("nav encode: %w", err)
		}
		if err := writeReport(c, runtime, c.NavOracle, envelope); err != nil {
			return struct{}{}, fmt.Errorf("nav write: %w", err)
		}
		logger.Info("sharefeeds: NAV_LEG pushed", "alphaUSD", alphaPush.String(), "hydxUsd", hydxPush.String())
	} else {
		logger.Info("sharefeeds: NAV push skipped (navOracle unset)")
	}
	return struct{}{}, nil
}

// observe is the node-mode observation function: it returns the LegMarks carrier for identical consensus.
//
// §8.9 MOCK FEED — replace this json.Unmarshal of the config-supplied marks with a per-node
// httpcap.Client.SendRequest to the real alphaUSD (TAO/alpha TWAP × TAO/USD) + HYDX/USD feeds + on-node
// hash/cert-chain verify (§8.10) when the endpoints integrate; the RunInNodeMode + consensus + compose +
// write machinery is unchanged. For the build every node json.Unmarshals the IDENTICAL config-supplied marks
// (deterministic → identical consensus holds).
//
// MUST NOT call runtime.GetSecret: NodeRuntime has no SecretsProvider, and a consensus observation forbids
// secrets. Any DON-only secret read (none needed this slice) stays in the handler.
func observe(in []byte, _ cre.NodeRuntime) (LegMarks, error) {
	var m LegMarks
	if err := json.Unmarshal(in, &m); err != nil {
		return LegMarks{}, fmt.Errorf("observe: unmarshal marks: %w", err)
	}
	return m, nil
}

// ──────────────────────────────────────────────────────────────────────── pure core (table-testable)

// bandClamp clamps a true leg value to within maxDeviationBps of the on-chain prior cached mark, EXACTLY as
// the SzipNavOracle deviation guard requires (cre-binding-confirmed to land at the edge):
//
//	step = priorP × maxDeviationBps / 10_000  (integer floor-div)
//	clamped = true ∈ [priorP − step, priorP + step] → true; else priorP+step (above) or priorP−step (below).
//
// At the edge `diff × 10_000 / priorP == maxDeviationBps`, which is NOT `> maxDeviationBps`, so the contract's
// strict-`>` floor-div guard passes — an edge-clamped push can never trip it. First push (priorTs == 0 ⇒ no
// prior) returns the true value unchanged (no band applies). Pure.
func bandClamp(trueP, priorP *big.Int, priorTs uint64, maxDeviationBps uint64) *big.Int {
	if priorTs == 0 || priorP == nil || priorP.Sign() == 0 {
		return new(big.Int).Set(trueP) // first push (or no prior) — true value lands
	}
	step := new(big.Int).Div(new(big.Int).Mul(priorP, new(big.Int).SetUint64(maxDeviationBps)), bps10000)
	lo := new(big.Int).Sub(priorP, step)
	hi := new(big.Int).Add(priorP, step)
	if trueP.Cmp(lo) < 0 {
		return new(big.Int).Set(lo)
	}
	if trueP.Cmp(hi) > 0 {
		return new(big.Int).Set(hi)
	}
	return new(big.Int).Set(trueP)
}

// ──────────────────────────────────────────────────────────────────────── DON-mode reads (copy buyburn-bid)

// selector returns the 4-byte function selector for the canonical signature (copy of cre/buyburn-bid).
func selector(sig string) []byte {
	return crypto.Keccak256([]byte(sig))[:4]
}

func call(client *evm.Client, runtime cre.Runtime, addr common.Address, data []byte) ([]byte, error) {
	reply, err := client.CallContract(runtime, &evm.CallContractRequest{
		Call: &evm.CallMsg{To: addr.Bytes(), Data: data}, // From nil for views; BlockNumber nil = latest
	}).Await()
	if err != nil {
		return nil, err
	}
	return reply.Data, nil
}

// readUint reads a no-arg view returning a single uint (uint256/uint48 decode into *big.Int).
func readUint(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string) (*big.Int, error) {
	data, err := call(client, runtime, addr, selector(sig))
	if err != nil {
		return nil, err
	}
	u256, _ := abi.NewType("uint256", "", nil)
	out, err := abi.Arguments{{Type: u256}}.Unpack(data)
	if err != nil {
		return nil, err
	}
	return out[0].(*big.Int), nil
}

// readLegCache reads SzipNavOracle.legCache(uint8) → (uint256 price, uint48 ts) — the public mapping getter.
// One uint8 arg packed onto the selector; the return decodes as (uint256, uint48). ts is returned as uint64.
func readLegCache(client *evm.Client, runtime cre.Runtime, addr common.Address, leg uint8) (*big.Int, uint64, error) {
	u8, _ := abi.NewType("uint8", "", nil)
	packed, err := abi.Arguments{{Type: u8}}.Pack(leg)
	if err != nil {
		return nil, 0, err
	}
	data, err := call(client, runtime, addr, append(selector("legCache(uint8)"), packed...))
	if err != nil {
		return nil, 0, err
	}
	u256, _ := abi.NewType("uint256", "", nil)
	u48, _ := abi.NewType("uint48", "", nil)
	out, err := abi.Arguments{{Type: u256}, {Type: u48}}.Unpack(data)
	if err != nil {
		return nil, 0, err
	}
	price := out[0].(*big.Int)
	ts := out[1].(*big.Int) // uint48 decodes into *big.Int
	return price, ts.Uint64(), nil
}

// ──────────────────────────────────────────────────────────────────────── WriteReport (copy revaluation)

// writeReport generates a §8.0 report from the pre-encoded envelope and writes it to the receiver. Copied
// from cre/revaluation/workflow.go (the proven WriteCreReportRequest idiom), gas + receiver from Config.
func writeReport(c *Config, runtime cre.Runtime, receiver string, envelope []byte) error {
	report, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: envelope,
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		return err
	}
	gasLimit := c.WriteGasLimit
	if gasLimit == 0 {
		gasLimit = defaultWriteGasLimit
	}
	client := &evm.Client{ChainSelector: c.ChainSelector}
	_, err = client.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(receiver).Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: gasLimit},
	}).Await()
	return err
}
