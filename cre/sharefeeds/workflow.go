// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-03 — the szipUSD share-price feeds producer (§8.6): NAV_LEG, reportType 7.
//
// (The LP_MARK leg was DELETED with its receiver `SzipFarmUtilityLpOracle`: the farm-utility LP collateral is
// priced on-chain by `AlgebraIchiFairLpOracle` (TWAP fair reserves) — a pushed mark composed from spot
// getTotalAmounts was the manipulable surface the TWAP twin exists to price out.)
//
// On the engine epoch (cron) the workflow:
//
//	(i)   reaches IDENTICAL consensus, in node mode, on the two off-chain leg marks it CANNOT read on Base
//	      ({alphaUSD, hydxUsd}, 18-dp; §8.9 mock observe — deterministic config/trigger-supplied LegMarks);
//	(ii)  reads, via DON-mode eth_call, the xALPHA exchangeRate (the tick gate) and the prior NAV leg
//	      cache (legCache(uint8)) for the deviation-band clamp;
//	(iii) emits ONE WriteReport — NAV_LEG → SzipNavOracle — the §8.0 envelope
//	      abi.encode(uint8 reportType=7, bytes payload), encoded via the shared cre/zipreport library (CRE-00).
//	      This slice does NOT re-implement the handshake.
//
// The producer NEVER pushes xALPHA-USD, oHYDX-USD, the RATE/APR, or per-xALPHA prices — the contract derives
// those on-chain from the two market legs and the trustless exchangeRate(). It pushes only the two market legs
// (alphaUSD per-1.0-ALPHA, HYDX/USD).
//
// Fail-safe no-ops (a liveness-only feed — a no-op tick is the safe outcome): an unset Config receiver skips
// the push; exchangeRate()==0 (unseeded) skips the whole tick; a zero/garbage off-chain mark skips. The NAV
// legs are pushed at their TRUE value: the on-chain deviation band was REMOVED 2026-07-31 (it forced this
// producer to clamp and publish a knowingly-wrong number). Magnitude is guarded at the SOURCE instead — see
// the TWAP contract in observe.
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

// defaultSchedule pins the engine-epoch heartbeat cadence (used when cfg.Schedule == ""). The cadence is a
// protocol choice, not a per-env detail, so it is pinned here rather than left to the deploy slot — an empty
// slot would otherwise hand cron.Trigger an empty schedule. 6-field cron (sec min hour dom mon dow): every 5
// minutes. NOTE (2026-07-31): this cadence was previously justified by the ±5% band clamp — that justification
// died with the band. Re-derive it from the source TWAP window once observe is real: the push cadence should
// be short relative to the on-chain NAV window W (3600s), not tied to any per-push magnitude limit.
const defaultSchedule = "0 */5 * * * *" // every 5 minutes

var (
	bps10000  = big.NewInt(10_000)
	scale1e18 = func() *big.Int { return new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil) }()
)

// alphaPrecompile is the Subtensor Alpha precompile (0x…0808) — a chain constant on 964, not a wiring slot.
const alphaPrecompile = "0x0000000000000000000000000000000000000808"

// defaultMaxFeedAge bounds the Chainlink TAO/USD round age (used when cfg.MaxFeedAgeSeconds == 0): the
// feed's heartbeat is 86400s (24h, 2% deviation threshold), so 90000s = heartbeat + 1h slack. Older ⇒ skip.
const defaultMaxFeedAge = uint64(90_000)

// defaultCrossCheckBps bounds the spot-vs-EMA dislocation (used when cfg.CrossCheckBps == 0): beyond it the
// tick is SKIPPED (fail closed; the feed goes stale and consumers fail closed on fresh()) — never clamped.
const defaultCrossCheckBps = uint64(2_500) // 25%

// Config is the static workflow config (parsed once at init via cre.ParseJSON[Config]). Every wiring slot
// (§17) is Config-driven and re-pointable — no hardcoded address.
type Config struct {
	ChainSelector uint64 `json:"chainSelector"` // the chain hosting the receiver + rate source (Base)
	NavOracle     string `json:"navOracle"`     // SzipNavOracle (the NAV_LEG receiver); unset ⇒ skip the NAV push
	RateSource    string `json:"rateSource"`    // IXAlphaRate.exchangeRate() source (SzAlphaRateOracle or xALPHA stand-in)
	Schedule      string `json:"schedule"`      // engine-epoch cron; "" falls back to defaultSchedule ("0 */5 * * * *", every 5 min)
	WriteGasLimit uint64 `json:"writeGasLimit"` // WriteReport gas limit; 0 falls back to 600_000

	// The REAL alpha-USD source (design ratified 2026-07-31; rationale in the deriveAlphaUSD header —
	// the standalone doc was retired 2026-08-02): the subnet EMA on 964 × the Chainlink TAO/USD
	// feed on Ethereum. Engaged only when MockMarks.AlphaUSD is EMPTY and TaoUsdFeed is set — the §8.9 mock
	// seam takes precedence, so rehearsal/sim configs are unchanged.
	SubtensorChainSelector uint64 `json:"subtensorChainSelector"` // 964 (CCIP selector 2135107236357186872)
	Netuid                 uint16 `json:"netuid"`                 // the subnet whose alpha this vault stakes (46)
	EthereumChainSelector  uint64 `json:"ethereumChainSelector"`  // where the TAO/USD feed lives (Ethereum mainnet; no Base feed exists, verified 2026-08-02)
	TaoUsdFeed             string `json:"taoUsdFeed"`             // Chainlink TAO/USD proxy (mainnet 0x1c88503c9A52aE6aaE1f9bb99b3b7e9b8Ab35459, 8-dp)
	MaxFeedAgeSeconds      uint64 `json:"maxFeedAgeSeconds"`      // TAO/USD round-age bound; 0 ⇒ 90000 (heartbeat 86400 + slack)
	CrossCheckBps          uint64 `json:"crossCheckBps"`          // spot-vs-EMA dislocation tolerance; 0 ⇒ 2500 (25%)

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
	// second handler is NOT built. Its old justification (the band clamps every push regardless of trigger) is
	// void since the band's removal; the surviving argument is that the on-chain NAV TWAP lags the protective
	// side regardless of push cadence, so a faster push buys no protection the TWAP doesn't already provide.
	// Revisit alongside the source-TWAP work.
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

	// alphaUSD: the REAL derivation (EMA × TAO/USD) when the mock mark is empty and a feed is wired; the
	// §8.9 mock seam otherwise. A zero/garbage NON-EMPTY mark ⇒ skip the tick (the contract would revert
	// ZeroPrice(); pushing an unpriceable leg is pointless), preserving the pre-derivation behavior.
	var alphaUSD *big.Int
	if marks.AlphaUSD == "" && c.TaoUsdFeed != "" {
		derived, skip, err := deriveAlphaUSD(c, runtime)
		if err != nil {
			return struct{}{}, err // a failed read is LOUD (errored run) and pushes nothing — the S14 posture
		}
		if skip {
			return struct{}{}, nil // guard skip (dislocation / stale feed / zero read) — logged in the helper
		}
		alphaUSD = derived
	} else {
		parsed, ok := new(big.Int).SetString(marks.AlphaUSD, 10)
		if !ok || parsed.Sign() <= 0 {
			logger.Info("sharefeeds: no-op (alphaUSD mark zero/garbage)")
			return struct{}{}, nil
		}
		alphaUSD = parsed
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
	// Legs are pushed at their TRUE value. No clamp, and no legCache pre-read: the on-chain deviation band is
	// gone, so there is nothing to clamp against and the two DON-mode eth_calls it required are saved.
	alphaPush := alphaUSD
	hydxPush := hydxUsd

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
// §8.9 MOCK FEED — still a mock. Every node json.Unmarshals the IDENTICAL config-supplied marks
// (deterministic → identical consensus holds). The RunInNodeMode + consensus + compose + write machinery
// around it is real and unchanged; only the data source is stubbed.
//
// ─── THE TWAP CONTRACT (BUILT 2026-08-02 — see deriveAlphaUSD) ──────────────────────────────────────────
// The magnitude guard the removed on-chain band pretended to give is now produced at the source, in
// deriveAlphaUSD: alphaUSD = getMovingAlphaPrice (the source EMA, never spot) × Chainlink TAO/USD
// (Ethereum mainnet — Base has no TAO feed, verified 2026-08-02), with the spot-vs-EMA dislocation
// cross-check SKIPPING the tick rather than clamping. The mock seam here remains for alphaUSD rehearsal
// (a set MockMarks.AlphaUSD takes precedence over the derivation) and is still the ONLY source for
// HYDX/USD, whose real source is a separate item. What remains true and open:
//
//  1. WINDOW SIZING (open). The EMA's effective window is chain-determined; a source-averaged mark's
//     EFFECTIVE age is older than its push `ts`, and `oldestRequiredLegTs` (the SEC-13 buy-burn `validTo`
//     fence) does NOT model that. Reason about it against `maxAge` (86400s) and `W` (3600s) before lending.
//  2. WHAT THIS DOES NOT SOLVE. A source TWAP hardens against a manipulated or bad READ. It does nothing
//     against a dishonest publisher, which is out of scope by ruling (2026-08-02). It also does not touch
//     the RATE factor: _xAlphaUSD is rate x alphaUSD, and this work bounds alphaUSD only. Do not record it
//     as closing anything on the rate leg, which carries its own guard.
//
// Full rationale: the deriveAlphaUSD header below.
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

// ──────────────────────────────────────────────────────────────────────── the real alpha-USD leg

// deriveAlphaUSD composes the real alpha-USD mark. This header is the price-leg design's home (the
// standalone doc, bridge/xalpha-price-leg.md, was retired 2026-08-02 once the build made it redundant;
// the rate-factor severity argument it carried moved to todo-bridge.md item 6):
//
//	alphaUSD (18-dp) = getMovingAlphaPrice(netuid) (964, 9-dp TAO/alpha EMA) × TAO/USD (Chainlink, 8-dp) × 10
//
// (Scaling verified against the precompile source: get_moving_alpha_price is multiplied by 1e9 before
// return — reference/subtensor/precompiles/src/alpha.rs:54. 9dp × 8dp × 10¹ = 18dp.)
//
// Guards, all fail-closed SKIPS (silence is honest; a clamped number is not — the band-removal rule):
//  1. AVERAGE AT THE SOURCE. The EMA precompile is the priced value, never getAlphaPrice spot — spot on a
//     subnet AMM is one-trade pushable, which is the whole reason a naive feed needed a band.
//  2. CROSS-CHECK, DON'T CLAMP. Spot vs EMA beyond CrossCheckBps means the pool is dislocated from its own
//     average (a manipulation in progress, or a violent real move the EMA has not yet absorbed — the two are
//     indistinguishable in one read, and in both cases the honest move is silence): skip the tick, the feed
//     ages, consumers fail closed on fresh(). Spot participates in the GUARD only; it is never the value.
//  3. A Chainlink round older than MaxFeedAgeSeconds, or a non-positive answer, skips the same way.
//
// Returns (value, skip, err): err is a failed READ (loud errored run, no push — the S14 posture; never a
// fallback value); skip is a guard outcome (logged, quiet no-op tick).
func deriveAlphaUSD(c *Config, runtime cre.Runtime) (*big.Int, bool, error) {
	logger := runtime.Logger()
	sub := &evm.Client{ChainSelector: c.SubtensorChainSelector}

	ema, err := readAlphaPrice(sub, runtime, "getMovingAlphaPrice(uint16)", c.Netuid)
	if err != nil {
		return nil, false, err
	}
	spot, err := readAlphaPrice(sub, runtime, "getAlphaPrice(uint16)", c.Netuid)
	if err != nil {
		return nil, false, err
	}
	if ema.Sign() <= 0 || spot.Sign() <= 0 {
		logger.Info("sharefeeds: no-op (zero alpha price read)", "ema", ema.String(), "spot", spot.String())
		return nil, true, nil
	}

	tol := c.CrossCheckBps
	if tol == 0 {
		tol = defaultCrossCheckBps
	}
	diff := new(big.Int).Abs(new(big.Int).Sub(spot, ema))
	diffBps := new(big.Int).Div(new(big.Int).Mul(diff, bps10000), ema)
	if diffBps.Cmp(new(big.Int).SetUint64(tol)) > 0 {
		logger.Error("sharefeeds: SKIP — spot/EMA dislocation beyond tolerance (manipulation or violent move; "+
			"the feed will stale and consumers fail closed)",
			"spotVsEmaBps", diffBps.String(), "toleranceBps", tol)
		return nil, true, nil
	}

	eth := &evm.Client{ChainSelector: c.EthereumChainSelector}
	answer, updatedAt, err := readLatestRoundData(eth, runtime, c.TaoUsdFeed)
	if err != nil {
		return nil, false, err
	}
	if answer.Sign() <= 0 {
		logger.Error("sharefeeds: SKIP — TAO/USD feed answered non-positive", "answer", answer.String())
		return nil, true, nil
	}
	maxAge := c.MaxFeedAgeSeconds
	if maxAge == 0 {
		maxAge = defaultMaxFeedAge
	}
	oldestAcceptable := big.NewInt(runtime.Now().Unix() - int64(maxAge))
	if updatedAt.Cmp(oldestAcceptable) < 0 {
		logger.Error("sharefeeds: SKIP — TAO/USD round stale", "updatedAt", updatedAt.String(), "maxAgeSeconds", maxAge)
		return nil, true, nil
	}

	alphaUSD := new(big.Int).Mul(new(big.Int).Mul(ema, answer), big.NewInt(10)) // 9dp × 8dp × 10 = 18dp
	return alphaUSD, false, nil
}

// readAlphaPrice reads the Alpha precompile's uint16-netuid → uint256 price views on 964.
func readAlphaPrice(client *evm.Client, runtime cre.Runtime, sig string, netuid uint16) (*big.Int, error) {
	u16, _ := abi.NewType("uint16", "", nil)
	arg, err := abi.Arguments{{Type: u16}}.Pack(netuid)
	if err != nil {
		return nil, err
	}
	data, err := call(client, runtime, common.HexToAddress(alphaPrecompile), append(selector(sig), arg...))
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

// readLatestRoundData reads a Chainlink aggregator proxy's latestRoundData() and returns (answer, updatedAt).
func readLatestRoundData(client *evm.Client, runtime cre.Runtime, feed string) (*big.Int, *big.Int, error) {
	data, err := call(client, runtime, common.HexToAddress(feed), selector("latestRoundData()"))
	if err != nil {
		return nil, nil, err
	}
	u80, _ := abi.NewType("uint80", "", nil)
	i256, _ := abi.NewType("int256", "", nil)
	u256, _ := abi.NewType("uint256", "", nil)
	out, err := abi.Arguments{{Type: u80}, {Type: i256}, {Type: u256}, {Type: u256}, {Type: u80}}.Unpack(data)
	if err != nil {
		return nil, nil, err
	}
	return out[1].(*big.Int), out[3].(*big.Int), nil
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
