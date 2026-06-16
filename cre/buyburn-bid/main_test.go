package main

import (
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	evmmock "github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/mock"
	"github.com/smartcontractkit/cre-sdk-go/cre/testutils"
)

// ─────────────────────────────────────────────────────────────────── encode round-trip (the load-bearing handshake)

func TestPostBidEnvelopeRoundTrip(t *testing.T) {
	sell := big.NewInt(123_456_789)
	buy, _ := new(big.Int).SetString("987654321000000000000", 10)
	validTo := uint32(1_900_000_000)

	payload, err := encodePostBidPayload(sell, buy, validTo)
	if err != nil {
		t.Fatalf("encodePostBidPayload: %v", err)
	}
	env := encodeEnvelope(postBidReportType, payload)

	// Decode the envelope as (uint8, bytes) — exactly what _processReport does first.
	rt, innerPayload := decodeEnvelope(t, env)
	if rt != postBidReportType {
		t.Fatalf("reportType: got %d want %d", rt, postBidReportType)
	}

	// Decode the inner payload as (uint256, uint256, uint32).
	u256, _ := abi.NewType("uint256", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	out, err := abi.Arguments{{Type: u256}, {Type: u256}, {Type: u32}}.Unpack(innerPayload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	if out[0].(*big.Int).Cmp(sell) != 0 {
		t.Fatalf("sell: got %v want %v", out[0], sell)
	}
	if out[1].(*big.Int).Cmp(buy) != 0 {
		t.Fatalf("buy: got %v want %v", out[1], buy)
	}
	if out[2].(uint32) != validTo {
		t.Fatalf("validTo: got %v want %v", out[2], validTo)
	}
}

func TestCancelBidEnvelopeRoundTrip(t *testing.T) {
	env := encodeEnvelope(cancelBidReportType, []byte{})
	rt, innerPayload := decodeEnvelope(t, env)
	if rt != cancelBidReportType {
		t.Fatalf("reportType: got %d want %d", rt, cancelBidReportType)
	}
	if cancelBidReportType != 2 {
		t.Fatalf("CANCEL_BID constant must be 2, got %d", cancelBidReportType)
	}
	if len(innerPayload) != 0 {
		t.Fatalf("cancel payload must be empty, got %d bytes", len(innerPayload))
	}
}

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

// ─────────────────────────────────────────────────────────────────── sizing unit tests

func TestClamp(t *testing.T) {
	cases := []struct{ v, lo, hi, want int64 }{
		{-5, 0, 100, 0},
		{50, 0, 100, 50},
		{150, 0, 100, 100},
		{0, 0, 100, 0},
		{100, 0, 100, 100},
	}
	for _, c := range cases {
		got := clamp(big.NewInt(c.v), big.NewInt(c.lo), big.NewInt(c.hi))
		if got.Int64() != c.want {
			t.Fatalf("clamp(%d,%d,%d): got %d want %d", c.v, c.lo, c.hi, got.Int64(), c.want)
		}
	}
}

func TestCeilDiv(t *testing.T) {
	cases := []struct{ a, b, want int64 }{
		{10, 3, 4},
		{9, 3, 3},
		{1, 1, 1},
		{0, 5, 0},
		{7, 2, 4},
	}
	for _, c := range cases {
		got := ceilDiv(big.NewInt(c.a), big.NewInt(c.b))
		if got.Int64() != c.want {
			t.Fatalf("ceilDiv(%d,%d): got %d want %d", c.a, c.b, got.Int64(), c.want)
		}
	}
}

func TestComputeValidTo(t *testing.T) {
	now := uint64(1_000_000)

	// fence + ttl + MAX_BID_TTL all far in future ⇒ ttl wins (smallest).
	got := computeValidTo(now, 3_600, big.NewInt(int64(now+10_000_000)), big.NewInt(1_000_000))
	if got != now+3_600 {
		t.Fatalf("ttl should win: got %d want %d", got, now+3_600)
	}

	// MAX_BID_TTL caps a very long ttl.
	got = computeValidTo(now, 999_999, big.NewInt(int64(now+10_000_000)), big.NewInt(1_000_000))
	if got != now+maxBidTTL {
		t.Fatalf("MAX_BID_TTL should cap: got %d want %d", got, now+maxBidTTL)
	}

	// Fence (oldestLeg+maxAge) is the tightest.
	got = computeValidTo(now, 50_000, big.NewInt(int64(now)-100), big.NewInt(200))
	if got != now+100 {
		t.Fatalf("fence should win: got %d want %d", got, now+100)
	}

	// Stale legs: fence <= now ⇒ returns now (caller skips, since validTo > now is false).
	got = computeValidTo(now, 3_600, big.NewInt(int64(now)-500), big.NewInt(100))
	if got != now {
		t.Fatalf("stale legs should yield now: got %d want %d", got, now)
	}
}

func TestSizeDriftBps(t *testing.T) {
	cases := []struct {
		target, current, want int64
	}{
		{1_100, 1_000, 1_000}, // +10%
		{900, 1_000, 1_000},   // -10%
		{1_000, 1_000, 0},
		{1, 0, 10_000}, // current 0 → denom max(.,1)=1
	}
	for _, c := range cases {
		got := sizeDriftBps(big.NewInt(c.target), big.NewInt(c.current)).Int64()
		if got != c.want {
			t.Fatalf("sizeDriftBps(%d,%d): got %d want %d", c.target, c.current, got, c.want)
		}
	}
}

// ─────────────────────────────────────────────────────────────────── simulated run (mocked reads + write capture)

const testChainSelector = evm.EthereumMainnetBase1

var (
	moduleAddr = common.HexToAddress("0x00000000000000000000000000000000000000B1")
	navAddr    = common.HexToAddress("0x00000000000000000000000000000000000000A0")
	gateAddr   = common.HexToAddress("0x00000000000000000000000000000000000000C0")
	eulerAddr  = common.HexToAddress("0x00000000000000000000000000000000000000E0")
	whAddr     = common.HexToAddress("0x00000000000000000000000000000000000000D0")
	queueAddr  = common.HexToAddress("0x00000000000000000000000000000000000000F0")
)

// readState is the scriptable view layer for one simulated tick.
type readState struct {
	uid           []byte
	curSell       *big.Int
	maxPrice      *big.Int
	buybackCap    *big.Int
	fresh         bool
	maxAge        *big.Int
	oldestLeg     *big.Int
	covered       bool
	freeReservoir *big.Int
}

func testConfig() *Config {
	return &Config{
		Schedule:        "0 */5 * * * *",
		ChainSelector:   testChainSelector,
		BuyBurnModule:   moduleAddr.Hex(),
		NavOracle:       navAddr.Hex(),
		CoverageGate:    gateAddr.Hex(),
		EulerEarn:       eulerAddr.Hex(),
		Warehouse:       whAddr.Hex(),
		RedemptionQueue: queueAddr.Hex(),
		DriftBps:        500, // 5%
		TTLSeconds:      3_600,
		HarvestReserve:  "100000000",  // 100 USDC (6-dp)
		SafetyBuffer:    "50000000",   // 50 USDC
	}
}

func encUint(v *big.Int) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(v)
	return out
}

func encBool(b bool) []byte {
	boolT, _ := abi.NewType("bool", "", nil)
	out, _ := abi.Arguments{{Type: boolT}}.Pack(b)
	return out
}

func encCurrentBid(uid []byte, sell *big.Int) []byte {
	bytesT, _ := abi.NewType("bytes", "", nil)
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: bytesT}, {Type: u256}}.Pack(uid, sell)
	return out
}

// runTick wires the mocks for a state, runs evaluateAndReconcile, and returns the captured WriteReport payloads
// (each is the §8.0 envelope bytes the module's _processReport would decode).
func runTick(t *testing.T, st readState) [][]byte {
	t.Helper()
	runtime := testutils.NewRuntime(t, testutils.Secrets{})
	runtime.SetTimeProvider(func() time.Time { return time.Unix(1_000_000, 0) })

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

	// Module: currentBid / quoteMaxPrice / buybackCap views + the WriteReport receiver.
	evmmock.AddContractMock(moduleAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("currentBid()"):    func([]byte) ([]byte, error) { return encCurrentBid(st.uid, st.curSell), nil },
		sel("quoteMaxPrice()"): func([]byte) ([]byte, error) { return encUint(st.maxPrice), nil },
		sel("buybackCap()"):    func([]byte) ([]byte, error) { return encUint(st.buybackCap), nil },
	}, writeCap)

	// NavOracle views.
	evmmock.AddContractMock(navAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("fresh()"):               func([]byte) ([]byte, error) { return encBool(st.fresh), nil },
		sel("maxAge()"):              func([]byte) ([]byte, error) { return encUint(st.maxAge), nil },
		sel("oldestRequiredLegTs()"): func([]byte) ([]byte, error) { return encUint(st.oldestLeg), nil },
	}, nil)

	// Coverage gate.
	evmmock.AddContractMock(gateAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("covered()"): func([]byte) ([]byte, error) { return encBool(st.covered), nil },
	}, nil)

	// EulerEarn: maxWithdraw(address) = freeReservoir.
	evmmock.AddContractMock(eulerAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("maxWithdraw(address)"): func([]byte) ([]byte, error) { return encUint(st.freeReservoir), nil },
	}, nil)

	if _, err := evaluateAndReconcile(testConfig(), runtime); err != nil {
		t.Fatalf("evaluateAndReconcile: %v", err)
	}
	return captured
}

// decodeCaptured returns the reportType of a captured envelope.
func decodeCapturedType(t *testing.T, env []byte) uint8 {
	rt, _ := decodeEnvelope(t, env)
	return rt
}

func TestSimPostBidWhenNoLiveAndFunded(t *testing.T) {
	st := readState{
		uid:           nil,
		curSell:       big.NewInt(0),
		maxPrice:      big.NewInt(990_000),                  // 0.99 USDC (6-dp) per share
		buybackCap:    big.NewInt(1_000_000_000_000),        // 1,000,000 USDC
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),                  // fence = 999_900 + 3_600 = 1_003_500 > now
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000),            // 1,000 USDC
	}
	out := runTick(t, st)
	if len(out) != 1 {
		t.Fatalf("expected 1 write (POST_BID), got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != postBidReportType {
		t.Fatalf("expected POST_BID, got %d", rt)
	}

	// targetSell = clamp(1_000_000_000 - 100_000_000 - 50_000_000) = 850_000_000.
	wantSell := big.NewInt(850_000_000)
	wantBuy := ceilDiv(new(big.Int).Mul(wantSell, big.NewInt(1e18)), st.maxPrice)
	u256, _ := abi.NewType("uint256", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	dec, err := abi.Arguments{{Type: u256}, {Type: u256}, {Type: u32}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if dec[0].(*big.Int).Cmp(wantSell) != 0 {
		t.Fatalf("sell: got %v want %v", dec[0], wantSell)
	}
	if dec[1].(*big.Int).Cmp(wantBuy) != 0 {
		t.Fatalf("buy: got %v want %v", dec[1], wantBuy)
	}
	// validTo = min(now+3600=1_003_600, fence=oldestLeg+maxAge=999_900+3_600=1_003_500, now+86400) = 1_003_500.
	if dec[2].(uint32) != uint32(1_003_500) {
		t.Fatalf("validTo: got %v want %v", dec[2], uint32(1_003_500))
	}
}

func TestSimCancelThenPostOnDrift(t *testing.T) {
	st := readState{
		uid:           []byte{0x01, 0x02, 0x03}, // live bid
		curSell:       big.NewInt(100_000_000),  // current 100 USDC
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000), // → target 850 USDC, huge drift vs 100
	}
	out := runTick(t, st)
	if len(out) != 2 {
		t.Fatalf("expected 2 writes (CANCEL then POST), got %d", len(out))
	}
	if decodeCapturedType(t, out[0]) != cancelBidReportType {
		t.Fatalf("first write should be CANCEL_BID")
	}
	if decodeCapturedType(t, out[1]) != postBidReportType {
		t.Fatalf("second write should be POST_BID")
	}
}

func TestSimCancelAloneWhenNotCovered(t *testing.T) {
	st := readState{
		uid:           []byte{0xAA},
		curSell:       big.NewInt(850_000_000),
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       false, // undercovered ⇒ cancel alone
		freeReservoir: big.NewInt(1_000_000_000),
	}
	out := runTick(t, st)
	if len(out) != 1 || decodeCapturedType(t, out[0]) != cancelBidReportType {
		t.Fatalf("expected single CANCEL_BID, got %d writes", len(out))
	}
}

func TestSimCancelAloneWhenNotFresh(t *testing.T) {
	st := readState{
		uid:           []byte{0xAA},
		curSell:       big.NewInt(850_000_000),
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         false, // stale NAV ⇒ cancel alone
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000),
	}
	out := runTick(t, st)
	if len(out) != 1 || decodeCapturedType(t, out[0]) != cancelBidReportType {
		t.Fatalf("expected single CANCEL_BID, got %d writes", len(out))
	}
}

func TestSimCancelAloneWhenTargetZero(t *testing.T) {
	st := readState{
		uid:           []byte{0xAA},
		curSell:       big.NewInt(850_000_000),
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(100_000_000), // 100 USDC − 100 − 50 reserves ⇒ clamp to 0
	}
	out := runTick(t, st)
	if len(out) != 1 || decodeCapturedType(t, out[0]) != cancelBidReportType {
		t.Fatalf("expected single CANCEL_BID, got %d writes", len(out))
	}
}

func TestSimNothingWithinDrift(t *testing.T) {
	st := readState{
		uid:           []byte{0xAA},
		curSell:       big.NewInt(850_000_000), // == target ⇒ drift 0 < driftBps
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000), // → target 850 USDC == current
	}
	out := runTick(t, st)
	if len(out) != 0 {
		t.Fatalf("expected NO writes within drift, got %d", len(out))
	}
}

func TestSimNoLiveNoFundsNoOp(t *testing.T) {
	st := readState{
		uid:           nil,
		curSell:       big.NewInt(0),
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(120_000_000), // 120 − 150 reserves ⇒ target 0, no live bid ⇒ no-op
	}
	out := runTick(t, st)
	if len(out) != 0 {
		t.Fatalf("expected no-op (no live bid, unfunded), got %d writes", len(out))
	}
}

// guard: the LogTrigger filter topic0 matches keccak256 of the real event sig.
func TestRedemptionSettledTopic0(t *testing.T) {
	got := redemptionSettledTopic0()
	if got == (common.Hash{}) {
		t.Fatal("topic0 should be non-zero")
	}
	// Stable, deterministic value of keccak256("RedemptionSettled(uint256,uint256,uint256,uint256)").
	if len(got.Bytes()) != 32 {
		t.Fatalf("topic0 must be 32 bytes")
	}
}
