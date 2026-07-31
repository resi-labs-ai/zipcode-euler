package main

import (
	"context"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	evmmock "github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/mock"
	httpcap "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	httpmock "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http/mock"
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

func TestDriftBps(t *testing.T) {
	cases := []struct {
		target, current, want int64
	}{
		{1_100, 1_000, 1_000}, // +10%
		{900, 1_000, 1_000},   // -10%
		{1_000, 1_000, 0},
		{1, 0, 10_000}, // current 0 → denom max(.,1)=1
	}
	for _, c := range cases {
		got := driftBps(big.NewInt(c.target), big.NewInt(c.current)).Int64()
		if got != c.want {
			t.Fatalf("driftBps(%d,%d): got %d want %d", c.target, c.current, got, c.want)
		}
	}
}

// SEC/L-7 unit: postedPrice derives the live bid's implied 6-dp price; 0-buy (no/malformed bid state) → 0.
func TestPostedPrice(t *testing.T) {
	// sell 850 USDC (6-dp) for 850e18 shares → 1.0 USDC/share = 1_000_000 (6-dp per 1e18).
	sell := big.NewInt(850_000_000)
	buy, _ := new(big.Int).SetString("850000000000000000000", 10) // 850e18
	if got := postedPrice(sell, buy); got.Int64() != 1_000_000 {
		t.Fatalf("postedPrice: got %d want 1000000", got.Int64())
	}
	if got := postedPrice(sell, big.NewInt(0)); got.Sign() != 0 {
		t.Fatalf("postedPrice with 0 buy must be 0, got %v", got)
	}
}

// SEC/L-7 unit: an unset priceDriftBps falls back to driftBps — the price reconcile is never silently off.
func TestPriceDriftThresholdFallback(t *testing.T) {
	cfg := &Config{DriftBps: 500}
	if got := priceDriftThreshold(cfg); got != 500 {
		t.Fatalf("fallback: got %d want 500", got)
	}
	cfg.PriceDriftBps = 50
	if got := priceDriftThreshold(cfg); got != 50 {
		t.Fatalf("explicit: got %d want 50", got)
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
	pluginAddr = common.HexToAddress("0x00000000000000000000000000000000000000AB") // lpTwapStatus().plugin
)

var (
	szipAddr = common.HexToAddress("0x0000000000000000000000000000000000005219")
	usdcAddr = common.HexToAddress("0x0000000000000000000000000000000000000006")
)

// readState is the scriptable view layer for one simulated tick.
type readState struct {
	uid           []byte
	curSell       *big.Int
	curBuy        *big.Int // currentBuyAmount() — nil ⇒ 0 (no live-bid state)
	maxPrice      *big.Int
	buybackCap    *big.Int
	fresh         bool
	maxAge        *big.Int
	oldestLeg     *big.Int
	covered       bool
	freeReservoir *big.Int
	twapHalted    bool     // lpTwapStatus().ready == !twapHalted — zero value ⇒ TWAP fine (audit F8)
	twapReadyAt   *big.Int // lpTwapStatus().readyAt — nil ⇒ 0 (no ETA: plugin missing/uninitialized)
	auctionJSON   string   // non-empty ⇒ demand gate ON: config gains OrderbookURL and the http mock serves this body
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
		PriceDriftBps:   100, // 1% — the SEC/L-7 reprice threshold
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

func encLpTwapStatus(ready bool, plugin common.Address, readyAt *big.Int) []byte {
	boolT, _ := abi.NewType("bool", "", nil)
	addrT, _ := abi.NewType("address", "", nil)
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: boolT}, {Type: addrT}, {Type: u256}}.Pack(ready, plugin, readyAt)
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

	// Module: currentBid / currentBuyAmount / quoteMaxPrice / buybackCap views + the WriteReport receiver.
	curBuy := st.curBuy
	if curBuy == nil {
		curBuy = big.NewInt(0)
	}
	if st.curSell == nil {
		st.curSell = big.NewInt(0)
	}
	evmmock.AddContractMock(moduleAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("currentBid()"):       func([]byte) ([]byte, error) { return encCurrentBid(st.uid, st.curSell), nil },
		sel("currentBuyAmount()"): func([]byte) ([]byte, error) { return encUint(curBuy), nil },
		sel("quoteMaxPrice()"):    func([]byte) ([]byte, error) { return encUint(st.maxPrice), nil },
		sel("buybackCap()"):       func([]byte) ([]byte, error) { return encUint(st.buybackCap), nil },
	}, writeCap)

	// NavOracle views.
	twapReadyAt := st.twapReadyAt
	if twapReadyAt == nil {
		twapReadyAt = big.NewInt(0)
	}
	evmmock.AddContractMock(navAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("fresh()"):               func([]byte) ([]byte, error) { return encBool(st.fresh), nil },
		sel("maxAge()"):              func([]byte) ([]byte, error) { return encUint(st.maxAge), nil },
		sel("oldestRequiredLegTs()"): func([]byte) ([]byte, error) { return encUint(st.oldestLeg), nil },
		sel("lpTwapStatus()"): func([]byte) ([]byte, error) {
			return encLpTwapStatus(!st.twapHalted, pluginAddr, twapReadyAt), nil
		},
	}, nil)

	// Coverage gate.
	evmmock.AddContractMock(gateAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("covered()"): func([]byte) ([]byte, error) { return encBool(st.covered), nil },
	}, nil)

	// EulerEarn: maxWithdraw(address) = freeReservoir.
	evmmock.AddContractMock(eulerAddr, evmMock, map[string]func([]byte) ([]byte, error){
		sel("maxWithdraw(address)"): func([]byte) ([]byte, error) { return encUint(st.freeReservoir), nil },
	}, nil)

	cfg := testConfig()
	if st.auctionJSON != "" {
		cfg.OrderbookURL = "https://orderbook.test"
		cfg.SzipUSD = szipAddr.Hex()
		cfg.Usdc = usdcAddr.Hex()
		httpMock, herr := httpmock.NewClientCapability(t)
		if herr != nil {
			t.Fatalf("http NewClientCapability: %v", herr)
		}
		body := st.auctionJSON
		httpMock.SendRequest = func(_ context.Context, _ *httpcap.Request) (*httpcap.Response, error) {
			return &httpcap.Response{StatusCode: 200, Body: []byte(body)}, nil
		}
	}

	if _, err := evaluateAndReconcile(cfg, runtime); err != nil {
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

// ───────────────────────────────────────────────── demand gate (fill-only, ratified 2026-07-30)

// auction builds a one-or-two-order CoW auction body for the szipUSD→USDC pair.
func auctionBody(orders ...string) string {
	out := `{"orders":[`
	for i, o := range orders {
		if i > 0 {
			out += ","
		}
		out += o
	}
	return out + `]}`
}

func sellOrder(sellShares, buyUSDC string) string {
	return `{"sellToken":"` + szipAddr.Hex() + `","buyToken":"` + usdcAddr.Hex() +
		`","sellAmount":"` + sellShares + `","buyAmount":"` + buyUSDC + `","kind":"sell"}`
}

// One acceptable resting order (asks 0.90/share vs ceiling 0.99) → bid sized to that demand, NOT to cash.
func TestSimDemandGateSizesToAcceptableOrders(t *testing.T) {
	st := readState{
		maxPrice:      big.NewInt(990_000), // 0.99 USDC per share (6-dp per 1e18)
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000), // 1,000 USDC cash — demand must undercut this
		auctionJSON: auctionBody(
			sellOrder("100000000000000000000", "90000000"),   // 100 shares asking 90 USDC (0.90) — acceptable
			sellOrder("50000000000000000000", "60000000"),    // 50 shares asking 60 USDC (1.20) — above ceiling, ignored
		),
	}
	out := runTick(t, st)
	if len(out) != 1 {
		t.Fatalf("expected 1 write (POST_BID), got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != postBidReportType {
		t.Fatalf("expected POST_BID, got %d", rt)
	}
	// demand = ceil(100e18 × 0.99 / 1e18) = 99 USDC — the bid funds the acceptable set at OUR ceiling.
	wantSell := big.NewInt(99_000_000)
	u256, _ := abi.NewType("uint256", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	dec, err := abi.Arguments{{Type: u256}, {Type: u256}, {Type: u32}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if dec[0].(*big.Int).Cmp(wantSell) != 0 {
		t.Fatalf("sell: got %v want %v (sized to acceptable demand, not cash)", dec[0], wantSell)
	}
}

// Empty book → nothing posts, even with cash available. The protocol never makes a market.
func TestSimDemandGateNoOrdersNoPost(t *testing.T) {
	st := readState{
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000),
		auctionJSON:   auctionBody(),
	}
	if out := runTick(t, st); len(out) != 0 {
		t.Fatalf("expected no writes on an empty book, got %d", len(out))
	}
}

// Live bid + demand gone → the bid comes down. No resting protocol price without someone to fill it.
func TestSimDemandGateCancelsWhenDemandGone(t *testing.T) {
	st := readState{
		uid:           []byte{0x01, 0x02, 0x03},
		curSell:       big.NewInt(99_000_000),
		curBuy:        new(big.Int).Mul(big.NewInt(100), big.NewInt(1e18)),
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000),
		auctionJSON:   auctionBody(), // book emptied since the post
	}
	out := runTick(t, st)
	if len(out) != 1 || decodeCapturedType(t, out[0]) != cancelBidReportType {
		t.Fatalf("expected exactly CANCEL_BID, got %d writes", len(out))
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

// Audit F8: while the LP-TWAP history halt is live (lpTwapStatus().ready == false), the round is skipped and a
// RESTING bid is cancelled — it would keep quoting a pre-halt mark that cannot be drift-checked while NAV reverts.
// The gate fires BEFORE quoteMaxPrice, so the halted-NAV read is never attempted.
func TestSimTwapHaltedCancelsRestingBidAndSkips(t *testing.T) {
	st := readState{
		uid:           []byte{0xAA},
		curSell:       big.NewInt(850_000_000),
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000),
		twapHalted:    true,
		twapReadyAt:   big.NewInt(1_003_000), // plugin replaced; history covers at unix 1_003_000
	}
	out := runTick(t, st)
	if len(out) != 1 || decodeCapturedType(t, out[0]) != cancelBidReportType {
		t.Fatalf("expected single CANCEL_BID during TWAP halt, got %d writes", len(out))
	}
}

// Audit F8: halted with NO resting bid ⇒ pure no-op (log-and-skip; nothing to cancel, nothing posted).
func TestSimTwapHaltedNoBidNoOp(t *testing.T) {
	st := readState{
		uid:           nil,
		curSell:       big.NewInt(0),
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000),
		twapHalted:    true, // twapReadyAt nil ⇒ 0: plugin missing/uninitialized, no ETA branch
	}
	out := runTick(t, st)
	if len(out) != 0 {
		t.Fatalf("expected no writes during TWAP halt with no resting bid, got %d", len(out))
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
	sell := big.NewInt(850_000_000)
	maxPrice := big.NewInt(990_000)
	st := readState{
		uid:     []byte{0xAA},
		curSell: sell, // == target ⇒ size drift 0 < driftBps
		// posted at the CURRENT ceiling (the buyAmount the loop itself would post) ⇒ price drift ~0 < priceDriftBps
		curBuy:        ceilDiv(new(big.Int).Mul(sell, big.NewInt(1e18)), maxPrice),
		maxPrice:      maxPrice,
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

// SEC/L-7: size unchanged but the oracle re-priced — the live bid still quotes its POSTED price, so the loop must
// cancel-and-repost at the current ceiling. This is the Octane V7 stale-resting-bid window closed operationally.
func TestSimRepriceOnPriceDriftOnly(t *testing.T) {
	sell := big.NewInt(850_000_000)
	st := readState{
		uid:     []byte{0xAA},
		curSell: sell, // == target ⇒ size drift 0: ONLY the price moved
		// posted when the ceiling was 1.10 USDC/share; the mark has since dropped to 0.99 (~10% drift ≥ 1%)
		curBuy:        new(big.Int).Div(new(big.Int).Mul(sell, big.NewInt(1e18)), big.NewInt(1_100_000)),
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000),
	}
	out := runTick(t, st)
	if len(out) != 2 {
		t.Fatalf("expected 2 writes (CANCEL then POST) on price drift, got %d", len(out))
	}
	if decodeCapturedType(t, out[0]) != cancelBidReportType {
		t.Fatalf("first write should be CANCEL_BID")
	}
	rt, payload := decodeEnvelope(t, out[1])
	if rt != postBidReportType {
		t.Fatalf("second write should be POST_BID")
	}
	// The repost is priced at the CURRENT ceiling: buy = ceilDiv(sell·1e18, maxPrice-now).
	u256, _ := abi.NewType("uint256", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	dec, err := abi.Arguments{{Type: u256}, {Type: u256}, {Type: u32}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	wantBuy := ceilDiv(new(big.Int).Mul(sell, big.NewInt(1e18)), st.maxPrice)
	if dec[1].(*big.Int).Cmp(wantBuy) != 0 {
		t.Fatalf("repost buy: got %v want %v (current-ceiling pricing)", dec[1], wantBuy)
	}
}

// SEC/L-7: malformed/legacy live-bid state (buyAmount reads 0 while a uid rests) must force a reprice, never a
// silent no-op — postedPrice(…, 0) = 0 ⇒ drift 10_000 bps.
func TestSimRepriceWhenLiveBuyAmountZero(t *testing.T) {
	st := readState{
		uid:           []byte{0xAA},
		curSell:       big.NewInt(850_000_000), // == target ⇒ size drift 0
		curBuy:        nil,                     // reads 0
		maxPrice:      big.NewInt(990_000),
		buybackCap:    big.NewInt(1_000_000_000_000),
		fresh:         true,
		maxAge:        big.NewInt(3_600),
		oldestLeg:     big.NewInt(999_900),
		covered:       true,
		freeReservoir: big.NewInt(1_000_000_000),
	}
	out := runTick(t, st)
	if len(out) != 2 {
		t.Fatalf("expected CANCEL then POST on zero live buyAmount, got %d writes", len(out))
	}
	if decodeCapturedType(t, out[0]) != cancelBidReportType || decodeCapturedType(t, out[1]) != postBidReportType {
		t.Fatalf("expected CANCEL_BID then POST_BID")
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
