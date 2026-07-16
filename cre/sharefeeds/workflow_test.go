// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host sim test for the CRE-03 share-price feeds producer (models cre/revaluation/workflow_test.go +
// cre/buyburn-bid/main_test.go). It exercises:
//   - the encode handshake: the captured NAV_LEG report decodes to (uint8 7, bytes) → (uint8[]{0,1},
//     uint256[]{...}, uint32); the LP_MARK report to (uint8 7, bytes) → (uint256 mark 6-dp, uint32) — by
//     decoding the bytes, NOT by trusting zipreport;
//   - the band clamp pure helper: beyond-band → edge, within-band → passthrough, unset prior → true;
//   - the LP-mark math pure helper: hand-computed tuples for BOTH token orderings; zero supply → 0;
//   - the side-aware reserve resolution (both orderings + a mismatch);
//   - the FULL handler path through RunInNodeMode + ConsensusIdenticalAggregation[LegMarks] + DON-mode mocked
//     eth_call replies (reserves/supply/rate/legCache) + runtime.Now() stamp + zipreport encoders +
//     GenerateReport + WriteReport, asserting the two recorded reports decode to the expected payloads;
//   - fail-safe no-ops: unset receiver, unseeded rate, zero/garbage mark, empty vault, token mismatch.
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
	navAddr   = common.HexToAddress("0x00000000000000000000000000000000000000A1")
	lpAddr    = common.HexToAddress("0x00000000000000000000000000000000000000B2")
	vaultAddr = common.HexToAddress("0x00000000000000000000000000000000000000C3")
	rateAddr  = common.HexToAddress("0x00000000000000000000000000000000000000D4")
	xAlphaTok = common.HexToAddress("0x00000000000000000000000000000000000000E5")
	zipUsdTok = common.HexToAddress("0x00000000000000000000000000000000000000F6")
)

func e18() *big.Int { return new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil) }

func testConfig() *Config {
	return &Config{
		ChainSelector:   testChainSelector,
		NavOracle:       navAddr.Hex(),
		LpOracle:        lpAddr.Hex(),
		IchiVault:       vaultAddr.Hex(),
		RateSource:      rateAddr.Hex(),
		XAlpha:          xAlphaTok.Hex(),
		ZipUSD:          zipUsdTok.Hex(),
		MaxDeviationBps: 500, // 5%
		Schedule:        "0 */5 * * * *",
		WriteGasLimit:   600_000,
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

// decodeLpPayload decodes the LP_MARK payload as the exact SzipFarmUtilityLpOracle._processReport tuple
// (uint256 mark, uint32 ts).
func decodeLpPayload(t *testing.T, payload []byte) (*big.Int, uint32) {
	t.Helper()
	u256, _ := abi.NewType("uint256", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	out, err := abi.Arguments{{Type: u256}, {Type: u32}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode lp payload: %v", err)
	}
	return out[0].(*big.Int), out[1].(uint32)
}

// ───────────────────────────────────────────────────────────────── eth_call reply encoders

func encUint(v *big.Int) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(v)
	return out
}

func encAddr(a common.Address) []byte {
	addrT, _ := abi.NewType("address", "", nil)
	out, _ := abi.Arguments{{Type: addrT}}.Pack(a)
	return out
}

func encTotalAmounts(t0, t1 *big.Int) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}, {Type: u256}}.Pack(t0, t1)
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
	total0       *big.Int
	total1       *big.Int
	totalSupply  *big.Int
	token0       common.Address
	token1       common.Address
}

// runTick wires the mocks for a state + a LegMarks, runs onEpoch, and returns the captured WriteReport
// envelopes keyed nothing — the order is NAV then LP (the handler order).
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

	// LpOracle: WriteReport receiver only.
	evmmock.AddContractMock(lpAddr, evmMock, map[string]func([]byte) ([]byte, error){}, writeCap)

	// RateSource: exchangeRate().
	evmmock.AddContractMock(rateAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("exchangeRate()"): func([]byte) ([]byte, error) { return encUint(st.exchangeRate), nil },
	}, nil)

	// ICHI vault: getTotalAmounts / totalSupply / token0 / token1.
	evmmock.AddContractMock(vaultAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("getTotalAmounts()"): func([]byte) ([]byte, error) { return encTotalAmounts(st.total0, st.total1), nil },
		sel("totalSupply()"):     func([]byte) ([]byte, error) { return encUint(st.totalSupply), nil },
		sel("token0()"):          func([]byte) ([]byte, error) { return encAddr(st.token0), nil },
		sel("token1()"):          func([]byte) ([]byte, error) { return encAddr(st.token1), nil },
	}, nil)

	_, herr := onEpoch(cfg, runtime, &cron.Payload{})
	return captured, herr
}

// marksJSON: convenience for the alphaUSD/hydxUsd 18-dp marks as decimal strings.
func marks(alpha, hydx *big.Int) LegMarks {
	return LegMarks{AlphaUSD: alpha.String(), HydxUsd: hydx.String()}
}

// ───────────────────────────────────────────────────────────────── encode handshake (full handler)

// TestSimEncodeHandshake drives the full handler with an unset prior (first push → true values land), a
// seeded vault, and asserts both captured reports decode to the exact tuples the two _processReports decode.
func TestSimEncodeHandshake(t *testing.T) {
	alpha := new(big.Int).Mul(big.NewInt(7), e18()) // alphaUSD = $7, 18-dp
	hydx := new(big.Int).Mul(big.NewInt(3), e18())  // HYDX/USD = $3, 18-dp
	rate := new(big.Int).Mul(big.NewInt(2), e18())  // exchangeRate = 2.0, 18-dp

	// Vault: token0 = xALPHA, token1 = zipUSD. reserveXAlpha = 100e18, reserveZipUSD = 500e18, supply = 50e18.
	rX := new(big.Int).Mul(big.NewInt(100), e18())
	rZ := new(big.Int).Mul(big.NewInt(500), e18())
	supply := new(big.Int).Mul(big.NewInt(50), e18())

	st := chainState{
		exchangeRate: rate,
		priorAlphaTs: 0, // unset prior → no band
		priorHydxTs:  0,
		total0:       rX,
		total1:       rZ,
		totalSupply:  supply,
		token0:       xAlphaTok,
		token1:       zipUsdTok,
	}
	out, err := runTick(t, testConfig(), marks(alpha, hydx), st)
	if err != nil {
		t.Fatalf("onEpoch: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("expected 2 writes (NAV then LP), got %d", len(out))
	}

	// --- NAV_LEG (first write) ---
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

	// --- LP_MARK (second write) ---
	rt2, payload2 := decodeEnvelope(t, out[1])
	if rt2 != zipreport.LpMark {
		t.Fatalf("LP reportType: got %d want LpMark(%d)", rt2, zipreport.LpMark)
	}
	if rt2 != 7 {
		t.Fatalf("LP reportType: got %d want literal 7 (LP_MARK)", rt2)
	}
	mark, ts2 := decodeLpPayload(t, payload2)
	if ts2 != testTs {
		t.Fatalf("lp ts: got %d want %d", ts2, testTs)
	}
	// hand-compute: priceXAlpha = 2e18*7e18/1e18 = 14e18; numerator = 100e18*14e18 + 500e18*1e18
	//   = 1400e36 + 500e36 = 1900e36; perShare18 = 1900e36/50e18 = 38e18; mark6 = 38e18/1e12 = 38e6.
	wantMark := lpMark6dp(rX, rZ, supply, rate, alpha)
	if mark.Cmp(wantMark) != 0 {
		t.Fatalf("lp mark: got %v want %v", mark, wantMark)
	}
	if mark.Cmp(big.NewInt(38_000_000)) != 0 { // 38 * 1e6
		t.Fatalf("lp mark literal: got %v want 38000000 (= $38/share, 6-dp)", mark)
	}
}

// ───────────────────────────────────────────────────────────────── band clamp (pure)

func TestBandClampPure(t *testing.T) {
	prior := new(big.Int).Mul(big.NewInt(100), e18()) // priorP = 100e18
	const maxDev = 500                                // 5% → step = 5e18
	step := new(big.Int).Mul(big.NewInt(5), e18())

	// unset prior (ts==0) → true value passes unchanged.
	trueP := new(big.Int).Mul(big.NewInt(200), e18())
	if got := bandClamp(trueP, prior, 0, maxDev); got.Cmp(trueP) != 0 {
		t.Fatalf("unset prior: got %v want %v (true value)", got, trueP)
	}

	// within-band move → passthrough (102e18 within [95e18,105e18]).
	within := new(big.Int).Mul(big.NewInt(102), e18())
	if got := bandClamp(within, prior, 1, maxDev); got.Cmp(within) != 0 {
		t.Fatalf("within-band: got %v want %v (passthrough)", got, within)
	}

	// beyond band above → upper edge (priorP + step = 105e18).
	above := new(big.Int).Mul(big.NewInt(300), e18())
	wantHi := new(big.Int).Add(prior, step)
	if got := bandClamp(above, prior, 1, maxDev); got.Cmp(wantHi) != 0 {
		t.Fatalf("beyond above: got %v want %v (upper edge)", got, wantHi)
	}

	// beyond band below → lower edge (priorP − step = 95e18).
	below := new(big.Int).Mul(big.NewInt(1), e18())
	wantLo := new(big.Int).Sub(prior, step)
	if got := bandClamp(below, prior, 1, maxDev); got.Cmp(wantLo) != 0 {
		t.Fatalf("beyond below: got %v want %v (lower edge)", got, wantLo)
	}

	// exactly at the edge passes through (== edge, within the closed interval).
	if got := bandClamp(wantHi, prior, 1, maxDev); got.Cmp(wantHi) != 0 {
		t.Fatalf("at upper edge: got %v want %v", got, wantHi)
	}
}

// TestSimBandClampInHandler proves the clamp drives the pushed NAV price: a huge alpha move beyond the band
// lands at the upper edge of the prior cached mark.
func TestSimBandClampInHandler(t *testing.T) {
	prior := new(big.Int).Mul(big.NewInt(100), e18())
	hugeAlpha := new(big.Int).Mul(big.NewInt(1000), e18()) // way beyond +5%
	hydx := new(big.Int).Mul(big.NewInt(3), e18())
	rate := e18() // 1.0

	st := chainState{
		exchangeRate: rate,
		priorAlpha:   prior,
		priorAlphaTs: 1, // seen before → band applies
		priorHydx:    hydx,
		priorHydxTs:  1,
		total0:       new(big.Int).Mul(big.NewInt(10), e18()),
		total1:       new(big.Int).Mul(big.NewInt(10), e18()),
		totalSupply:  new(big.Int).Mul(big.NewInt(10), e18()),
		token0:       xAlphaTok,
		token1:       zipUsdTok,
	}
	out, err := runTick(t, testConfig(), marks(hugeAlpha, hydx), st)
	if err != nil {
		t.Fatalf("onEpoch: %v", err)
	}
	_, payload := decodeEnvelope(t, out[0])
	_, prices, _ := decodeNavPayload(t, payload)
	wantHi := new(big.Int).Add(prior, new(big.Int).Mul(big.NewInt(5), e18())) // +5% edge
	if prices[0].Cmp(wantHi) != 0 {
		t.Fatalf("clamped alpha: got %v want %v (band edge)", prices[0], wantHi)
	}
}

// ───────────────────────────────────────────────────────────────── LP-mark math (pure, both orderings)

func TestLpMarkMathPure(t *testing.T) {
	rate := new(big.Int).Mul(big.NewInt(2), e18()) // 2.0
	alpha := new(big.Int).Mul(big.NewInt(7), e18()) // $7
	rX := new(big.Int).Mul(big.NewInt(100), e18())
	rZ := new(big.Int).Mul(big.NewInt(500), e18())
	supply := new(big.Int).Mul(big.NewInt(50), e18())
	want := big.NewInt(38_000_000) // $38/share, 6-dp (hand-computed above)

	if got := lpMark6dp(rX, rZ, supply, rate, alpha); got.Cmp(want) != 0 {
		t.Fatalf("lpMark6dp: got %v want %v", got, want)
	}

	// zero supply → 0 (no-op signal).
	if got := lpMark6dp(rX, rZ, big.NewInt(0), rate, alpha); got.Sign() != 0 {
		t.Fatalf("zero supply: got %v want 0", got)
	}
}

// TestResolveReservesBothOrderings proves the side-aware mapping picks the right reserve for each token
// ordering, and fails closed on a mismatch.
func TestResolveReservesBothOrderings(t *testing.T) {
	rX := big.NewInt(111)
	rZ := big.NewInt(222)

	// token0 = xALPHA, token1 = zipUSD → reserveXAlpha = total0, reserveZipUSD = total1.
	gotX, gotZ, ok := resolveReserves(rX, rZ, xAlphaTok, zipUsdTok, xAlphaTok, zipUsdTok)
	if !ok || gotX.Cmp(rX) != 0 || gotZ.Cmp(rZ) != 0 {
		t.Fatalf("ordering0: got X=%v Z=%v ok=%v", gotX, gotZ, ok)
	}

	// token0 = zipUSD, token1 = xALPHA → reserveXAlpha = total1, reserveZipUSD = total0.
	gotX, gotZ, ok = resolveReserves(rX, rZ, zipUsdTok, xAlphaTok, xAlphaTok, zipUsdTok)
	if !ok || gotX.Cmp(rZ) != 0 || gotZ.Cmp(rX) != 0 {
		t.Fatalf("ordering1: got X=%v Z=%v ok=%v", gotX, gotZ, ok)
	}

	// mismatch (neither side is the configured pair) → ok=false.
	other := common.HexToAddress("0x0000000000000000000000000000000000009999")
	if _, _, ok := resolveReserves(rX, rZ, other, zipUsdTok, xAlphaTok, zipUsdTok); ok {
		t.Fatalf("mismatch should fail closed")
	}
}

// TestSimLpMarkToken0IsZipUsd drives the full handler with the REVERSED vault ordering (token0=zipUSD) and
// asserts the same mark.
func TestSimLpMarkToken0IsZipUsd(t *testing.T) {
	alpha := new(big.Int).Mul(big.NewInt(7), e18())
	hydx := new(big.Int).Mul(big.NewInt(3), e18())
	rate := new(big.Int).Mul(big.NewInt(2), e18())
	rX := new(big.Int).Mul(big.NewInt(100), e18())
	rZ := new(big.Int).Mul(big.NewInt(500), e18())
	supply := new(big.Int).Mul(big.NewInt(50), e18())

	// REVERSED: total0 = zipUSD reserve, total1 = xALPHA reserve; token0 = zipUSD, token1 = xALPHA.
	st := chainState{
		exchangeRate: rate,
		total0:       rZ,
		total1:       rX,
		totalSupply:  supply,
		token0:       zipUsdTok,
		token1:       xAlphaTok,
	}
	out, err := runTick(t, testConfig(), marks(alpha, hydx), st)
	if err != nil {
		t.Fatalf("onEpoch: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("expected 2 writes, got %d", len(out))
	}
	mark, _ := decodeLpPayload(t, mustInner(t, out[1]))
	if mark.Cmp(big.NewInt(38_000_000)) != 0 {
		t.Fatalf("reversed-ordering mark: got %v want 38000000", mark)
	}
}

func mustInner(t *testing.T, env []byte) []byte {
	t.Helper()
	_, p := decodeEnvelope(t, env)
	return p
}

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

// TestSimNavOnlyOnEmptyVault: an empty vault (supply 0) → NAV pushes, LP no-ops.
func TestSimNavOnlyOnEmptyVault(t *testing.T) {
	alpha := new(big.Int).Mul(big.NewInt(7), e18())
	st := chainState{
		exchangeRate: e18(),
		total0:       big.NewInt(0),
		total1:       big.NewInt(0),
		totalSupply:  big.NewInt(0), // empty vault
		token0:       xAlphaTok,
		token1:       zipUsdTok,
	}
	out, err := runTick(t, testConfig(), marks(alpha, e18()), st)
	if err != nil {
		t.Fatalf("empty vault: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write (NAV only), got %d", len(out))
	}
	rt, _ := decodeEnvelope(t, out[0])
	if rt != zipreport.NavLeg {
		t.Fatalf("the single write should be NAV_LEG, got reportType %d", rt)
	}
}

// TestSimNavOnlyOnTokenMismatch: a wrong/spoofed vault (neither token matches) → NAV pushes, LP no-ops.
func TestSimNavOnlyOnTokenMismatch(t *testing.T) {
	alpha := new(big.Int).Mul(big.NewInt(7), e18())
	other := common.HexToAddress("0x0000000000000000000000000000000000008888")
	st := chainState{
		exchangeRate: e18(),
		total0:       new(big.Int).Mul(big.NewInt(10), e18()),
		total1:       new(big.Int).Mul(big.NewInt(10), e18()),
		totalSupply:  new(big.Int).Mul(big.NewInt(10), e18()),
		token0:       other, // mismatch
		token1:       zipUsdTok,
	}
	out, err := runTick(t, testConfig(), marks(alpha, e18()), st)
	if err != nil {
		t.Fatalf("token mismatch: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write (NAV only), got %d", len(out))
	}
}

// TestSimLpOnlyOnNavUnset: NavOracle unset → NAV skipped, LP still pushes.
func TestSimLpOnlyOnNavUnset(t *testing.T) {
	cfg := testConfig()
	cfg.NavOracle = ""
	alpha := new(big.Int).Mul(big.NewInt(7), e18())
	st := chainState{
		exchangeRate: new(big.Int).Mul(big.NewInt(2), e18()),
		total0:       new(big.Int).Mul(big.NewInt(100), e18()),
		total1:       new(big.Int).Mul(big.NewInt(500), e18()),
		totalSupply:  new(big.Int).Mul(big.NewInt(50), e18()),
		token0:       xAlphaTok,
		token1:       zipUsdTok,
	}
	out, err := runTick(t, cfg, marks(alpha, e18()), st)
	if err != nil {
		t.Fatalf("nav unset: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write (LP only), got %d", len(out))
	}
	rt, _ := decodeEnvelope(t, out[0])
	if rt != zipreport.LpMark {
		t.Fatalf("the single write should be LP_MARK, got reportType %d", rt)
	}
}

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
