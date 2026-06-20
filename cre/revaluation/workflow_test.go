// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host sim test for the CRE-01a revaluation producer (models cre/scaffold/main_test.go). It exercises:
//   - the encode handshake: the captured report decodes to (uint8 reportType=3, bytes payload) and the
//     payload to the exact ZipcodeOracleRegistry._processReport tuple (address[], uint256[], uint32) — by
//     decoding the bytes, NOT by trusting zipreport;
//   - sharding: N liens with MaxLiensPerReport=k ⇒ ceil(N/k) writes, correct ordered subsets, identical ts,
//     union == input;
//   - dedup ⇒ error, no write; length-mismatch / zero-price / malformed-address ⇒ error, no write;
//   - no-op: empty marks ⇒ 0 writes; unset Registry ⇒ 0 writes;
//   - the FULL handler path through RunInNodeMode + ConsensusIdenticalAggregation[Marks] (proving the carrier
//     values.Wraps) + runtime.Now() stamp + zipreport.Revaluation + GenerateReport + WriteReport.
package main

import (
	"encoding/json"
	"fmt"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	evmmock "github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/mock"
	httpcap "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/cre/testutils"

	zipreport "cre-zipreport"
)

const testChainSelector = evm.EthereumMainnetBase1
const testTs = uint32(1_700_000_000)

var registryAddr = common.HexToAddress("0x00000000000000000000000000000000000000A7")

func testConfig() *Config {
	return &Config{
		ChainSelector:     testChainSelector,
		Registry:          registryAddr.Hex(),
		MaxLiensPerReport: 50,
		WriteGasLimit:     600_000,
	}
}

// lienHex builds a deterministic, distinct, valid 20-byte hex address for index i (i+1 in the last byte +
// a fixed high byte so it is never the zero address).
func lienHex(i int) string {
	var a common.Address
	a[18] = 0x10
	a[19] = byte(i + 1)
	return a.Hex()
}

// batchJSON marshals a Marks wire body from parallel hex-lien + decimal-price slices.
func batchJSON(t *testing.T, liens, prices []string) []byte {
	t.Helper()
	b, err := json.Marshal(Marks{Liens: liens, Prices: prices})
	if err != nil {
		t.Fatalf("marshal batch: %v", err)
	}
	return b
}

// nMarks builds n distinct valid liens with prices price_i = (i+1) * 1e18.
func nMarks(t *testing.T, n int) (liens, prices []string) {
	t.Helper()
	base := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	for i := 0; i < n; i++ {
		liens = append(liens, lienHex(i))
		p := new(big.Int).Mul(base, big.NewInt(int64(i+1)))
		prices = append(prices, p.String())
	}
	return liens, prices
}

// decodeEnvelope decodes the §8.0 envelope as (uint8 reportType, bytes payload).
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

// decodePayload decodes the reportType-3 payload as the exact ZipcodeOracleRegistry._processReport tuple
// (address[] liens, uint256[] prices, uint32 ts).
func decodePayload(t *testing.T, payload []byte) ([]common.Address, []*big.Int, uint32) {
	t.Helper()
	addrArr, _ := abi.NewType("address[]", "", nil)
	u256Arr, _ := abi.NewType("uint256[]", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	out, err := abi.Arguments{{Type: addrArr}, {Type: u256Arr}, {Type: u32}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode payload tuple: %v", err)
	}
	return out[0].([]common.Address), out[1].([]*big.Int), out[2].(uint32)
}

// runHandler wires the mocks, runs onReappraisal with a constructed *httpcap.Payload carrying the batch, and
// returns the captured WriteReport envelopes. Modeled on cre/scaffold/main_test.go:52-78.
func runHandler(t *testing.T, cfg *Config, batch []byte) ([][]byte, error) {
	t.Helper()
	runtime := testutils.NewRuntime(t, testutils.Secrets{})
	runtime.SetTimeProvider(func() time.Time { return time.Unix(int64(testTs), 0) })

	evmMock, err := evmmock.NewClientCapability(testChainSelector, t)
	if err != nil {
		t.Fatalf("NewClientCapability: %v", err)
	}

	var captured [][]byte
	writeCap := func(payload []byte, _ *evm.GasConfig) (*evm.WriteReportReply, error) {
		cp := make([]byte, len(payload))
		copy(cp, payload)
		captured = append(captured, cp)
		return &evm.WriteReportReply{}, nil
	}
	evmmock.AddContractMock(registryAddr, evmMock, map[string]func([]byte) ([]byte, error){}, writeCap)

	_, herr := onReappraisal(cfg, runtime, &httpcap.Payload{Input: batch})
	return captured, herr
}

// ─────────────────────────────────────────────────────────── encode handshake (full handler path)

// TestSimEncodeHandshake drives the full handler (RunInNodeMode + identical consensus + Now() stamp +
// zipreport.Revaluation + GenerateReport + WriteReport) for a single small batch and asserts the captured
// bytes decode to the exact (uint8 3, bytes) → (address[], uint256[], uint32) tuple matching the input.
func TestSimEncodeHandshake(t *testing.T) {
	liens, prices := nMarks(t, 3)
	out, err := runHandler(t, testConfig(), batchJSON(t, liens, prices))
	if err != nil {
		t.Fatalf("onReappraisal: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.RegistryRevaluation {
		t.Fatalf("reportType: got %d want %d (REVALUATION)", rt, zipreport.RegistryRevaluation)
	}
	if rt != 3 {
		t.Fatalf("reportType: got %d want literal 3 (the on-chain REVALUATION value)", rt)
	}
	gotLiens, gotPrices, gotTs := decodePayload(t, payload)
	if gotTs != testTs {
		t.Fatalf("ts: got %d want %d", gotTs, testTs)
	}
	if len(gotLiens) != 3 || len(gotPrices) != 3 {
		t.Fatalf("decoded lengths: liens=%d prices=%d want 3/3", len(gotLiens), len(gotPrices))
	}
	for i := 0; i < 3; i++ {
		if gotLiens[i] != common.HexToAddress(liens[i]) {
			t.Fatalf("lien[%d]: got %s want %s", i, gotLiens[i].Hex(), liens[i])
		}
		want, _ := new(big.Int).SetString(prices[i], 10)
		if gotPrices[i].Cmp(want) != 0 {
			t.Fatalf("price[%d]: got %v want %v", i, gotPrices[i], want)
		}
	}
}

// ─────────────────────────────────────────────────────────── sharding (full handler path)

func TestSimSharding(t *testing.T) {
	const n, k = 7, 3 // ceil(7/3) = 3 shards: 3,3,1
	liens, prices := nMarks(t, n)
	cfg := testConfig()
	cfg.MaxLiensPerReport = k

	out, err := runHandler(t, cfg, batchJSON(t, liens, prices))
	if err != nil {
		t.Fatalf("onReappraisal: %v", err)
	}
	wantShards := (n + k - 1) / k
	if len(out) != wantShards {
		t.Fatalf("shards: got %d writes want %d", len(out), wantShards)
	}

	var unionLiens []common.Address
	var unionPrices []*big.Int
	var firstTs uint32
	expectedSizes := []int{3, 3, 1}
	for s, env := range out {
		rt, payload := decodeEnvelope(t, env)
		if rt != 3 {
			t.Fatalf("shard %d reportType: got %d want 3", s, rt)
		}
		sl, sp, ts := decodePayload(t, payload)
		if len(sl) != expectedSizes[s] {
			t.Fatalf("shard %d size: got %d want %d", s, len(sl), expectedSizes[s])
		}
		if s == 0 {
			firstTs = ts
		} else if ts != firstTs {
			t.Fatalf("shard %d ts: got %d want %d (must be identical across shards)", s, ts, firstTs)
		}
		// ordered-subset check: shard s holds liens [s*k : s*k+len(sl)] of the input, in order.
		for i := range sl {
			gi := s*k + i
			if sl[i] != common.HexToAddress(liens[gi]) {
				t.Fatalf("shard %d lien[%d]: got %s want input[%d]=%s", s, i, sl[i].Hex(), gi, liens[gi])
			}
		}
		unionLiens = append(unionLiens, sl...)
		unionPrices = append(unionPrices, sp...)
	}
	if firstTs != testTs {
		t.Fatalf("ts: got %d want %d", firstTs, testTs)
	}
	// union == input (no drop / no dup), in order.
	if len(unionLiens) != n {
		t.Fatalf("union liens: got %d want %d", len(unionLiens), n)
	}
	for i := 0; i < n; i++ {
		if unionLiens[i] != common.HexToAddress(liens[i]) {
			t.Fatalf("union lien[%d]: got %s want %s", i, unionLiens[i].Hex(), liens[i])
		}
		want, _ := new(big.Int).SetString(prices[i], 10)
		if unionPrices[i].Cmp(want) != 0 {
			t.Fatalf("union price[%d]: got %v want %v", i, unionPrices[i], want)
		}
	}
}

// ─────────────────────────────────────────────────────────── error → no write (full handler path)

func TestSimDedupErrorNoWrite(t *testing.T) {
	liens, prices := nMarks(t, 3)
	liens[2] = liens[0] // duplicate lien
	out, err := runHandler(t, testConfig(), batchJSON(t, liens, prices))
	if err == nil {
		t.Fatalf("expected dedup error, got nil")
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes on dedup error, got %d", len(out))
	}
}

func TestSimLengthMismatchNoWrite(t *testing.T) {
	out, err := runHandler(t, testConfig(), batchJSON(t, []string{lienHex(0), lienHex(1)}, []string{"1000000000000000000"}))
	if err == nil {
		t.Fatalf("expected length-mismatch error, got nil")
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes on length mismatch, got %d", len(out))
	}
}

func TestSimZeroPriceNoWrite(t *testing.T) {
	out, err := runHandler(t, testConfig(), batchJSON(t, []string{lienHex(0)}, []string{"0"}))
	if err == nil {
		t.Fatalf("expected zero-price error, got nil")
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes on zero price, got %d", len(out))
	}
}

func TestSimMalformedAddressNoWrite(t *testing.T) {
	// 0xDEAD is too short — common.HexToAddress would silently zero-pad it; the producer must reject it.
	out, err := runHandler(t, testConfig(), batchJSON(t, []string{"0xDEAD"}, []string{"1000000000000000000"}))
	if err == nil {
		t.Fatalf("expected malformed-address error, got nil")
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes on malformed address, got %d", len(out))
	}
}

// ─────────────────────────────────────────────────────────── no-op fail-safe (full handler path)

func TestSimNoOpEmptyMarks(t *testing.T) {
	out, err := runHandler(t, testConfig(), batchJSON(t, nil, nil))
	if err != nil {
		t.Fatalf("empty marks should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (empty marks), got %d", len(out))
	}
}

func TestSimNoOpRegistryUnset(t *testing.T) {
	cfg := testConfig()
	cfg.Registry = ""
	liens, prices := nMarks(t, 2)
	out, err := runHandler(t, cfg, batchJSON(t, liens, prices))
	if err != nil {
		t.Fatalf("registry unset should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (registry unset), got %d", len(out))
	}
}

// ─────────────────────────────────────────────────────────── pure helper: shardRevaluation

func TestShardRevaluationPure(t *testing.T) {
	liens, prices := nMarks(t, 5)
	shards, err := shardRevaluation(Marks{Liens: liens, Prices: prices}, 2)
	if err != nil {
		t.Fatalf("shardRevaluation: %v", err)
	}
	if len(shards) != 3 { // ceil(5/2)
		t.Fatalf("shards: got %d want 3", len(shards))
	}
	wantSizes := []int{2, 2, 1}
	var count int
	for i, s := range shards {
		if len(s.Liens) != wantSizes[i] || len(s.Prices) != wantSizes[i] {
			t.Fatalf("shard %d size: liens=%d prices=%d want %d", i, len(s.Liens), len(s.Prices), wantSizes[i])
		}
		count += len(s.Liens)
	}
	if count != 5 {
		t.Fatalf("total liens across shards: got %d want 5", count)
	}

	// default fallback (maxPer<=0 in the handler is corrected to 50; the pure fn errors on <=0).
	if _, err := shardRevaluation(Marks{Liens: liens, Prices: prices}, 0); err == nil {
		t.Fatalf("expected error for maxPer<=0")
	}
}

// TestParseLien covers the hex-validation rules directly.
func TestParseLien(t *testing.T) {
	good := lienHex(0)
	if _, err := parseLien(good); err != nil {
		t.Fatalf("good lien %s rejected: %v", good, err)
	}
	bad := []string{
		"",                                            // empty
		"DEADBEEF",                                     // no 0x
		"0xDEAD",                                       // too short
		"0x" + fmt.Sprintf("%040d", 0),                 // zero address (40 zeros)
		"0x" + "g" + "000000000000000000000000000000000000000", // non-hex
		"0x" + "00000000000000000000000000000000000000000",     // too long (41)
	}
	for _, s := range bad {
		if _, err := parseLien(s); err == nil {
			t.Fatalf("expected parseLien(%q) to error", s)
		}
	}
}
