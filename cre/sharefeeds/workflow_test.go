// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host sim test for the CRE-03 share-price feeds producer (models cre/revaluation/workflow_test.go +
// cre/buyburn-bid/main_test.go). It exercises:
//   - the encode handshake: the captured NAV_LEG report decodes to (uint8 7, bytes) → (uint8[]{0,1},
//     uint256[]{...}, uint32) — by decoding the bytes, NOT by trusting zipreport;
//   - the band clamp pure helper: beyond-band → edge, within-band → passthrough, unset prior → true;
//   - the FULL handler path through RunInNodeMode + ConsensusIdenticalAggregation[LegMarks] + DON-mode mocked
//     eth_call replies (rate/legCache) + runtime.Now() stamp + zipreport encoders + GenerateReport +
//     WriteReport, asserting the recorded report decodes to the expected payload;
//   - fail-safe no-ops: unset receiver, unseeded rate, zero/garbage mark.
//
// (The LP_MARK leg + its vault-read harness were DELETED with the SzipFarmUtilityLpOracle receiver — the
// farm-utility LP collateral is priced on-chain by AlgebraIchiFairLpOracle.)
package main

import (
	"encoding/json"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	evmmock "github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/mock"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre/testutils"

	zipreport "cre-zipreport"
)

const testChainSelector = evm.EthereumMainnetBase1
const testTs = uint32(1_700_000_000)

var (
	navAddr  = common.HexToAddress("0x00000000000000000000000000000000000000A1")
	rateAddr = common.HexToAddress("0x00000000000000000000000000000000000000D4")
)

func e18() *big.Int { return new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil) }

func testConfig() *Config {
	return &Config{
		ChainSelector: testChainSelector,
		NavOracle:     navAddr.Hex(),
		RateSource:    rateAddr.Hex(),
		Schedule:      "0 */5 * * * *",
		WriteGasLimit: 600_000,
	}
}

// ───────────────────────────────────────────────────────────────── decode helpers (decode the bytes)

func decodeEnvelope(t *testing.T, env []byte) (uint8, []byte) {
	t.Helper()
	u8, _ := abi.NewType("uint8", "", nil)
	bts, _ := abi.NewType("bytes", "", nil)
	out, err := abi.Arguments{{Type: u8}, {Type: bts}}.Unpack(env)
	if err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	return out[0].(uint8), out[1].([]byte)
}

// decodeNavPayload decodes the NAV_LEG payload as the exact SzipNavOracle._processReport tuple
// (uint8[] legs, uint256[] prices, uint32 ts).
func decodeNavPayload(t *testing.T, payload []byte) ([]uint8, []*big.Int, uint32) {
	t.Helper()
	u8Arr, _ := abi.NewType("uint8[]", "", nil)
	u256Arr, _ := abi.NewType("uint256[]", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	out, err := abi.Arguments{{Type: u8Arr}, {Type: u256Arr}, {Type: u32}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode nav payload: %v", err)
	}
	return out[0].([]uint8), out[1].([]*big.Int), out[2].(uint32)
}

// ───────────────────────────────────────────────────────────────── eth_call reply encoders

func encUint(v *big.Int) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(v)
	return out
}

// encLegCache encodes the legCache(uint8) return tuple (uint256 price, uint48 ts). A nil price (unset prior)
// encodes as 0 — matching the on-chain getter's zero-value return for an unset leg.
func encLegCache(price *big.Int, ts uint64) []byte {
	if price == nil {
		price = big.NewInt(0)
	}
	u256, _ := abi.NewType("uint256", "", nil)
	u48, _ := abi.NewType("uint48", "", nil)
	out, _ := abi.Arguments{{Type: u256}, {Type: u48}}.Pack(price, new(big.Int).SetUint64(ts))
	return out
}

// ───────────────────────────────────────────────────────────────── sim harness

// chainState scripts the on-chain reads for one simulated tick.
type chainState struct {
	exchangeRate *big.Int
	priorAlpha   *big.Int
	priorAlphaTs uint64
	priorHydx    *big.Int
	priorHydxTs  uint64
}

// runTick wires the mocks for a state + a LegMarks, runs onEpoch, and returns the captured WriteReport
// envelopes (at most one — the NAV_LEG push).
func runTick(t *testing.T, cfg *Config, marks LegMarks, st chainState) ([][]byte, error) {
	t.Helper()
	cfg.MockMarks = marks

	runtime := testutils.NewRuntime(t, testutils.Secrets{})
	runtime.SetTimeProvider(func() time.Time { return time.Unix(int64(testTs), 0) })

	evmMock, err := evmmock.NewClientCapability(testChainSelector, t)
	if err != nil {
		t.Fatalf("NewClientCapability: %v", err)
	}

	sel := func(sig string) string { return string(selector(sig)) }

	var captured [][]byte
	writeCap := func(payload []byte, _ *evm.GasConfig) (*evm.WriteReportReply, error) {
		cp := make([]byte, len(payload))
		copy(cp, payload)
		captured = append(captured, cp)
		return &evm.WriteReportReply{}, nil
	}

	// NavOracle: legCache(uint8) view + the NAV_LEG WriteReport receiver. legCache dispatches on the uint8 arg.
	evmmock.AddContractMock(navAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("legCache(uint8)"): func(arg []byte) ([]byte, error) {
			// arg is the abi-encoded uint8 leg (32-byte word; the leg id is the last byte).
			leg := uint8(0)
			if len(arg) > 0 {
				leg = arg[len(arg)-1]
			}
			if leg == zipreport.LegHydxUsd {
				return encLegCache(st.priorHydx, st.priorHydxTs), nil
			}
			return encLegCache(st.priorAlpha, st.priorAlphaTs), nil
		},
	}, writeCap)

	// RateSource: exchangeRate().
	evmmock.AddContractMock(rateAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("exchangeRate()"): func([]byte) ([]byte, error) { return encUint(st.exchangeRate), nil },
	}, nil)

	_, herr := onEpoch(cfg, runtime, &cron.Payload{})
	return captured, herr
}

// marksJSON: convenience for the alphaUSD/hydxUsd 18-dp marks as decimal strings.
func marks(alpha, hydx *big.Int) LegMarks {
	return LegMarks{AlphaUSD: alpha.String(), HydxUsd: hydx.String()}
}

// ───────────────────────────────────────────────────────────────── encode handshake (full handler)

// TestSimEncodeHandshake drives the full handler with an unset prior (first push → true values land) and
// asserts the captured report decodes to the exact tuple SzipNavOracle._processReport decodes.
func TestSimEncodeHandshake(t *testing.T) {
	alpha := new(big.Int).Mul(big.NewInt(7), e18()) // alphaUSD = $7, 18-dp
	hydx := new(big.Int).Mul(big.NewInt(3), e18())  // HYDX/USD = $3, 18-dp
	rate := new(big.Int).Mul(big.NewInt(2), e18())  // exchangeRate = 2.0, 18-dp

	st := chainState{
		exchangeRate: rate,
		priorAlphaTs: 0, // unset prior → no band
		priorHydxTs:  0,
	}
	out, err := runTick(t, testConfig(), marks(alpha, hydx), st)
	if err != nil {
		t.Fatalf("onEpoch: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write (NAV_LEG), got %d", len(out))
	}

	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.NavLeg {
		t.Fatalf("NAV reportType: got %d want NavLeg(%d)", rt, zipreport.NavLeg)
	}
	if rt != 7 {
		t.Fatalf("NAV reportType: got %d want literal 7 (NAV_LEG)", rt)
	}
	legs, prices, ts := decodeNavPayload(t, payload)
	if ts != testTs {
		t.Fatalf("nav ts: got %d want %d", ts, testTs)
	}
	if len(legs) != 2 || legs[0] != 0 || legs[1] != 1 {
		t.Fatalf("legs: got %v want [0 1]", legs)
	}
	if prices[0].Cmp(alpha) != 0 {
		t.Fatalf("nav alpha price: got %v want %v", prices[0], alpha)
	}
	if prices[1].Cmp(hydx) != 0 {
		t.Fatalf("nav hydx price: got %v want %v", prices[1], hydx)
	}
}

// ───────────────────────────────────────────────────────────────── band clamp (pure)

// TestSimBandClampInHandler proves the clamp drives the pushed NAV price: a huge alpha move beyond the band

// ───────────────────────────────────────────────────────────────── fail-safe no-ops (full handler)

func TestSimNoOpUnseededRate(t *testing.T) {
	st := chainState{exchangeRate: big.NewInt(0)} // unseeded → whole tick no-op
	out, err := runTick(t, testConfig(), marks(e18(), e18()), st)
	if err != nil {
		t.Fatalf("unseeded rate should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (unseeded rate), got %d", len(out))
	}
}

func TestSimNoOpZeroMark(t *testing.T) {
	out, err := runTick(t, testConfig(), LegMarks{AlphaUSD: "0", HydxUsd: "1"}, chainState{exchangeRate: e18()})
	if err != nil {
		t.Fatalf("zero alpha mark should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (zero alpha mark), got %d", len(out))
	}
}

func TestSimNoOpGarbageMark(t *testing.T) {
	out, err := runTick(t, testConfig(), LegMarks{AlphaUSD: "not-a-number", HydxUsd: "1"}, chainState{exchangeRate: e18()})
	if err != nil {
		t.Fatalf("garbage alpha mark should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (garbage alpha mark), got %d", len(out))
	}
}

// TestSimNoOpNavUnset: NavOracle unset → the (only) push is skipped; a no-op tick, not an error.
func TestSimNoOpNavUnset(t *testing.T) {
	cfg := testConfig()
	cfg.NavOracle = ""
	out, err := runTick(t, cfg, marks(new(big.Int).Mul(big.NewInt(7), e18()), e18()), chainState{exchangeRate: e18()})
	if err != nil {
		t.Fatalf("nav unset: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (navOracle unset), got %d", len(out))
	}
}

// ───────────────────────────────────────────────────────────────── the real alpha-USD leg (derived path)

const testSubtensorSelector = uint64(2135107236357186872) // 964's CCIP selector, as deploy config pins it
const testEthereumSelector = evm.EthereumMainnet          // where the TAO/USD feed lives

var (
	alphaPreAddr = common.HexToAddress(alphaPrecompile)
	feedAddr     = common.HexToAddress("0x00000000000000000000000000000000000000F1")
)

// derivedState scripts the 964 + Ethereum reads for the derived alpha-USD path.
type derivedState struct {
	ema           *big.Int // getMovingAlphaPrice (9-dp TAO/alpha)
	spot          *big.Int // getAlphaPrice (9-dp TAO/alpha)
	feedAnswer    *big.Int // Chainlink TAO/USD answer (8-dp, int256)
	feedUpdatedAt int64    // Chainlink round updatedAt
	alphaReadErr  error    // non-nil ⇒ both precompile reads error (a failed read, not a guard)
}

// encRoundData encodes the Chainlink latestRoundData() 5-tuple.
func encRoundData(answer *big.Int, updatedAt int64) []byte {
	u80, _ := abi.NewType("uint80", "", nil)
	i256, _ := abi.NewType("int256", "", nil)
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u80}, {Type: i256}, {Type: u256}, {Type: u256}, {Type: u80}}.Pack(
		big.NewInt(1), answer, big.NewInt(updatedAt), big.NewInt(updatedAt), big.NewInt(1))
	return out
}

// derivedConfig wires the real-source slots; MockMarks.AlphaUSD stays EMPTY so the derivation engages
// (HydxUsd stays mocked — its real source is a separate item).
func derivedConfig() *Config {
	cfg := testConfig()
	cfg.SubtensorChainSelector = testSubtensorSelector
	cfg.Netuid = 46
	cfg.EthereumChainSelector = testEthereumSelector
	cfg.TaoUsdFeed = feedAddr.Hex()
	return cfg
}

// runDerivedTick extends runTick's wiring with the 964 precompile mock + the Ethereum feed mock.
func runDerivedTick(t *testing.T, cfg *Config, st chainState, ds derivedState) ([][]byte, error) {
	t.Helper()

	subMock, err := evmmock.NewClientCapability(testSubtensorSelector, t)
	if err != nil {
		t.Fatalf("NewClientCapability(964): %v", err)
	}
	ethMock, err := evmmock.NewClientCapability(testEthereumSelector, t)
	if err != nil {
		t.Fatalf("NewClientCapability(ethereum): %v", err)
	}

	sel := func(sig string) string { return string(selector(sig)) }
	alphaRead := func(v *big.Int) func([]byte) ([]byte, error) {
		return func([]byte) ([]byte, error) {
			if ds.alphaReadErr != nil {
				return nil, ds.alphaReadErr
			}
			return encUint(v), nil
		}
	}
	evmmock.AddContractMock(alphaPreAddr, subMock, map[string]func([]byte) ([]byte, error){
		sel("getMovingAlphaPrice(uint16)"): alphaRead(ds.ema),
		sel("getAlphaPrice(uint16)"):       alphaRead(ds.spot),
	}, nil)
	evmmock.AddContractMock(feedAddr, ethMock, map[string]func([]byte) ([]byte, error){
		sel("latestRoundData()"): func([]byte) ([]byte, error) { return encRoundData(ds.feedAnswer, ds.feedUpdatedAt), nil },
	}, nil)

	return runTick(t, cfg, LegMarks{AlphaUSD: "", HydxUsd: e18().String()}, st)
}

// TestSimDerivedAlphaUSD: the real composition lands in the NAV push — EMA (9-dp) × TAO/USD (8-dp) × 10 =
// 18-dp — and the EMA is the priced value (spot only guards).
func TestSimDerivedAlphaUSD(t *testing.T) {
	ds := derivedState{
		ema:           big.NewInt(500_000_000),    // 0.5 TAO/alpha, 9-dp
		spot:          big.NewInt(520_000_000),    // 4% off the EMA — within tolerance, ignored as value
		feedAnswer:    big.NewInt(42_000_000_000), // $420.00, 8-dp
		feedUpdatedAt: int64(testTs) - 3600,       // an hour-old round: fresh
	}
	// expected: 5e8 × 4.2e10 × 10 = 2.1e20 ($210, 18-dp)
	want := new(big.Int).Mul(big.NewInt(210), e18())

	out, err := runDerivedTick(t, derivedConfig(), chainState{exchangeRate: e18()}, ds)
	if err != nil {
		t.Fatalf("onEpoch: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write (NAV_LEG), got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.NavLeg {
		t.Fatalf("reportType: got %d want NavLeg(%d)", rt, zipreport.NavLeg)
	}
	_, prices, _ := decodeNavPayload(t, payload)
	if prices[0].Cmp(want) != 0 {
		t.Fatalf("derived alphaUSD: got %v want %v (EMA × TAO/USD × 10)", prices[0], want)
	}
}

// TestSimDerivedSkipDislocation: spot beyond CrossCheckBps of the EMA ⇒ the tick is SKIPPED, never clamped
// (manipulation and a violent real move are indistinguishable in one read; silence is the honest output).
func TestSimDerivedSkipDislocation(t *testing.T) {
	ds := derivedState{
		ema:           big.NewInt(500_000_000),
		spot:          big.NewInt(1_000_000_000), // 100% off — far beyond the 25% default
		feedAnswer:    big.NewInt(42_000_000_000),
		feedUpdatedAt: int64(testTs) - 3600,
	}
	out, err := runDerivedTick(t, derivedConfig(), chainState{exchangeRate: e18()}, ds)
	if err != nil {
		t.Fatalf("dislocation must be a skip, not an error: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (spot/EMA dislocation), got %d", len(out))
	}
}

// TestSimDerivedSkipStaleFeed: a TAO/USD round older than MaxFeedAgeSeconds ⇒ skip.
func TestSimDerivedSkipStaleFeed(t *testing.T) {
	ds := derivedState{
		ema:           big.NewInt(500_000_000),
		spot:          big.NewInt(500_000_000),
		feedAnswer:    big.NewInt(42_000_000_000),
		feedUpdatedAt: int64(testTs) - 90_001, // one second past the default 90000s bound
	}
	out, err := runDerivedTick(t, derivedConfig(), chainState{exchangeRate: e18()}, ds)
	if err != nil {
		t.Fatalf("stale feed must be a skip, not an error: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (stale TAO/USD round), got %d", len(out))
	}
}

// TestSimDerivedSkipNonPositiveAnswer: a non-positive Chainlink answer ⇒ skip.
func TestSimDerivedSkipNonPositiveAnswer(t *testing.T) {
	ds := derivedState{
		ema:           big.NewInt(500_000_000),
		spot:          big.NewInt(500_000_000),
		feedAnswer:    big.NewInt(-1),
		feedUpdatedAt: int64(testTs) - 3600,
	}
	out, err := runDerivedTick(t, derivedConfig(), chainState{exchangeRate: e18()}, ds)
	if err != nil {
		t.Fatalf("non-positive answer must be a skip, not an error: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (non-positive TAO/USD answer), got %d", len(out))
	}
}

// TestSimDerivedReadErrorLoud: a FAILED 964 read (revert/transport) is not a guard — it errors loudly and
// pushes nothing (the S14 posture, same as the rate feed).
func TestSimDerivedReadErrorLoud(t *testing.T) {
	ds := derivedState{
		alphaReadErr:  errAlphaRead,
		feedAnswer:    big.NewInt(42_000_000_000),
		feedUpdatedAt: int64(testTs) - 3600,
	}
	out, err := runDerivedTick(t, derivedConfig(), chainState{exchangeRate: e18()}, ds)
	if err == nil {
		t.Fatal("a failed precompile read must surface as a loud error")
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (failed read), got %d", len(out))
	}
}

var errAlphaRead = errAlphaReadT{}

type errAlphaReadT struct{}

func (errAlphaReadT) Error() string { return "execution reverted (precompile unavailable)" }

// guard: the consensus carrier round-trips through json (proves the §8.9 mock seam is JSON-native).
func TestLegMarksJSONRoundTrip(t *testing.T) {
	m := LegMarks{AlphaUSD: "7000000000000000000", HydxUsd: "3000000000000000000"}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got LegMarks
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got != m {
		t.Fatalf("round-trip: got %+v want %+v", got, m)
	}
}

// guard: initFn pins the heartbeat cadence. An empty Schedule slot must NOT brick the workflow — the
// defaultSchedule fallback applies so cron.Trigger never receives an empty schedule, while an explicit
// Schedule is honored. Both build one handler with no error.
func TestInitFnPinsSchedule(t *testing.T) {
	if defaultSchedule == "" {
		t.Fatal("defaultSchedule must be non-empty (it is the pin)")
	}

	// empty slot → fallback applied, workflow builds.
	cEmpty := testConfig()
	cEmpty.Schedule = ""
	wf, err := initFn(cEmpty, nil, nil)
	if err != nil {
		t.Fatalf("empty schedule: initFn err = %v", err)
	}
	if len(wf) != 1 {
		t.Fatalf("empty schedule: got %d handlers want 1", len(wf))
	}

	// explicit slot → honored, workflow builds.
	cSet := testConfig() // Schedule = "0 */5 * * * *"
	wf2, err := initFn(cSet, nil, nil)
	if err != nil {
		t.Fatalf("explicit schedule: initFn err = %v", err)
	}
	if len(wf2) != 1 {
		t.Fatalf("explicit schedule: got %d handlers want 1", len(wf2))
	}
}
