// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host sim test for the szalpha-rate pull (models cre/sharefeeds/workflow_test.go). It exercises:
//   - the encode handshake: the captured RATE report decodes to (uint8 8, bytes) → (uint256 rate, uint48 ts)
//     — by decoding the bytes, NOT by trusting zipreport — with ts == the DON clock, never a chain read;
//   - S14 (the load-bearing one): a REVERTING exchangeRate() read produces NO PUSH and a loud error —
//     never a zero/fallback push. This is the vanished-backing breaker's cross-chain half;
//   - fail-safe no-ops: zero rate (unseeded stand-in), unset wiring;
//   - the schedule pin (empty config slot falls back, never an empty cron).
package main

import (
	"errors"
	"math/big"
	"strings"
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

// Two chains, like production: the read leg on 964 (the CCIP directory's Bittensor selector — the SDK
// snapshot has no named constant for it, so the raw value is pinned here exactly as deploy config will pin
// it) and the write leg on Base.
const testSubtensorSelector = uint64(2135107236357186872)
const testBaseSelector = evm.EthereumMainnetBase1

const testTs = int64(1_700_000_000)

var (
	szAlphaAddr  = common.HexToAddress("0x00000000000000000000000000000000000000B1")
	receiverAddr = common.HexToAddress("0x00000000000000000000000000000000000000B2")
)

func e18() *big.Int { return new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil) }

func testConfig() *Config {
	return &Config{
		SubtensorChainSelector: testSubtensorSelector,
		SzAlpha:                szAlphaAddr.Hex(),
		BaseChainSelector:      testBaseSelector,
		SzAlphaRateOracle:      receiverAddr.Hex(),
		Schedule:               "0 0 * * * *",
		WriteGasLimit:          250_000,
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

// decodeRatePayload decodes the RATE payload as the exact SzAlphaRateOracle._processReport tuple
// (uint256 rate, uint48 ts).
func decodeRatePayload(t *testing.T, payload []byte) (*big.Int, *big.Int) {
	t.Helper()
	u256, _ := abi.NewType("uint256", "", nil)
	u48, _ := abi.NewType("uint48", "", nil)
	out, err := abi.Arguments{{Type: u256}, {Type: u48}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode rate payload: %v", err)
	}
	return out[0].(*big.Int), out[1].(*big.Int)
}

func encUint(v *big.Int) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(v)
	return out
}

// ───────────────────────────────────────────────────────────────── sim harness

// chainState scripts the 964-side exchangeRate() read for one simulated tick. readErr non-nil simulates a
// REVERTING read (the mock surfaces a handler error exactly as the capability surfaces a revert).
type chainState struct {
	rate    *big.Int
	readErr error
}

// runTick wires both chain mocks for a state, runs onCron, and returns the envelopes captured on the BASE
// receiver (at most one — the RATE push).
func runTick(t *testing.T, cfg *Config, st chainState) ([][]byte, error) {
	t.Helper()

	runtime := testutils.NewRuntime(t, testutils.Secrets{})
	runtime.SetTimeProvider(func() time.Time { return time.Unix(testTs, 0) })

	subtensorMock, err := evmmock.NewClientCapability(testSubtensorSelector, t)
	if err != nil {
		t.Fatalf("NewClientCapability(964): %v", err)
	}
	baseMock, err := evmmock.NewClientCapability(testBaseSelector, t)
	if err != nil {
		t.Fatalf("NewClientCapability(base): %v", err)
	}

	sel := func(sig string) string { return string(selector(sig)) }

	// 964: SzAlpha.exchangeRate() — value or revert per the scripted state.
	evmmock.AddContractMock(szAlphaAddr, subtensorMock, map[string]func([]byte) ([]byte, error){
		sel("exchangeRate()"): func([]byte) ([]byte, error) {
			if st.readErr != nil {
				return nil, st.readErr
			}
			return encUint(st.rate), nil
		},
	}, nil)

	// Base: the SzAlphaRateOracle receiver — capture WriteReport payloads.
	var captured [][]byte
	evmmock.AddContractMock(receiverAddr, baseMock, nil, func(payload []byte, _ *evm.GasConfig) (*evm.WriteReportReply, error) {
		cp := make([]byte, len(payload))
		copy(cp, payload)
		captured = append(captured, cp)
		return &evm.WriteReportReply{}, nil
	})

	_, herr := onCron(cfg, runtime, &cron.Payload{})
	return captured, herr
}

// ───────────────────────────────────────────────────────────────── encode handshake (full handler)

// TestSimEncodeHandshake drives the full handler and asserts the captured report decodes to the exact tuple
// SzAlphaRateOracle._processReport decodes, with the DON clock as the stamp.
func TestSimEncodeHandshake(t *testing.T) {
	rate := new(big.Int).Mul(big.NewInt(2), e18()) // exchangeRate = 2.0, 18-dp

	out, err := runTick(t, testConfig(), chainState{rate: rate})
	if err != nil {
		t.Fatalf("onCron: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write (RATE), got %d", len(out))
	}

	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.RateReportType {
		t.Fatalf("reportType: got %d want RateReportType(%d)", rt, zipreport.RateReportType)
	}
	if rt != 8 {
		t.Fatalf("reportType: got %d want literal 8 (RATE)", rt)
	}
	gotRate, gotTs := decodeRatePayload(t, payload)
	if gotRate.Cmp(rate) != 0 {
		t.Fatalf("rate: got %v want %v", gotRate, rate)
	}
	if gotTs.Int64() != testTs {
		t.Fatalf("ts: got %v want %d (the DON clock, never a chain read)", gotTs, testTs)
	}
}

// ───────────────────────────────────────────────────────────────── S14: reverting read ⇒ NO PUSH

// TestSimRevertingReadNoPush pins seam S14: when exchangeRate() REVERTS (the BackingVanished breaker — the
// exact Rubicon drift state), the handler must push NOTHING and fail loudly. A "push 0" here would defeat
// the stale-feed breaker: the receiver rejects zero, but a fallback/last-known push would keep Base fresh
// while the backing is gone. Silence is the design.
func TestSimRevertingReadNoPush(t *testing.T) {
	revert := errors.New("execution reverted: BackingVanished()")

	out, err := runTick(t, testConfig(), chainState{readErr: revert})
	if err == nil {
		t.Fatal("reverting read must surface as a loud error (the repeating errored run is the alarm)")
	}
	if !strings.Contains(err.Error(), "BackingVanished") {
		t.Fatalf("error should carry the revert reason, got: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("S14 VIOLATED: expected 0 writes on a reverting read, got %d", len(out))
	}
}

// ───────────────────────────────────────────────────────────────── fail-safe no-ops (full handler)

// TestSimNoOpZeroRate: a zero RETURN (genesis-unseeded stand-in) is a quiet skip — the receiver would revert
// ZeroRate, so there is nothing to push; distinct from the reverting case, which errors.
func TestSimNoOpZeroRate(t *testing.T) {
	out, err := runTick(t, testConfig(), chainState{rate: big.NewInt(0)})
	if err != nil {
		t.Fatalf("zero rate should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (zero rate), got %d", len(out))
	}
}

// TestSimNoOpUnsetSource / TestSimNoOpUnsetReceiver: unset wiring is a config state, not a fault — no-op,
// no error. (Two tests, not one: the mock registry is per-test, so each runTick needs its own *testing.T.)
func TestSimNoOpUnsetSource(t *testing.T) {
	cfg := testConfig()
	cfg.SzAlpha = ""
	out, err := runTick(t, cfg, chainState{rate: e18()})
	if err != nil {
		t.Fatalf("szAlpha unset: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (szAlpha unset), got %d", len(out))
	}
}

func TestSimNoOpUnsetReceiver(t *testing.T) {
	cfg := testConfig()
	cfg.SzAlphaRateOracle = ""
	out, err := runTick(t, cfg, chainState{rate: e18()})
	if err != nil {
		t.Fatalf("receiver unset: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (receiver unset), got %d", len(out))
	}
}

// ───────────────────────────────────────────────────────────────── schedule pin

// TestInitFnPinsSchedule: an empty Schedule slot must NOT brick the workflow — the defaultSchedule fallback
// applies so cron.Trigger never receives an empty schedule, while an explicit Schedule is honored.
func TestInitFnPinsSchedule(t *testing.T) {
	if defaultSchedule == "" {
		t.Fatal("defaultSchedule must be non-empty (it is the pin)")
	}

	cEmpty := testConfig()
	cEmpty.Schedule = ""
	wf, err := initFn(cEmpty, nil, nil)
	if err != nil {
		t.Fatalf("empty schedule: initFn err = %v", err)
	}
	if len(wf) != 1 {
		t.Fatalf("empty schedule: got %d handlers want 1", len(wf))
	}

	cSet := testConfig()
	wf2, err := initFn(cSet, nil, nil)
	if err != nil {
		t.Fatalf("explicit schedule: initFn err = %v", err)
	}
	if len(wf2) != 1 {
		t.Fatalf("explicit schedule: got %d handlers want 1", len(wf2))
	}
}
