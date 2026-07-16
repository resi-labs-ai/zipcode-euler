// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host sim test for the scaffold (models cre/buyburn-bid/main_test.go). It runs the full handler path —
// DON-only secret read -> RunInNodeMode + identical consensus -> runtime.Now() stamp -> zipreport encode
// -> GenerateReport -> WriteReport — under the testutils + evmmock harness, and asserts the captured report
// decodes to the LpMark envelope (reportType 7, inner (uint256 mark, uint32 ts)).
//
// The exemplar calls its loop fn directly rather than firing the cron trigger; we do the same (call onCron
// with a nil *cron.Payload). The secret read is fail-safe, so the happy path needs no seeded secret.
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

	zipreport "cre-zipreport"
)

const testChainSelector = evm.EthereumMainnetBase1

var receiverAddr = common.HexToAddress("0x00000000000000000000000000000000000000A7")

func testConfig() *Config {
	return &Config{
		Schedule:      "0 */5 * * * *",
		ChainSelector: testChainSelector,
		Receiver:      receiverAddr.Hex(),
		SecretId:      "DEMO_SECRET",
	}
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

// runHandler wires the mocks, runs onCron, and returns the captured WriteReport envelopes. The secrets map
// is passed through so callers can exercise the seeded-secret path (or the empty fail-safe path).
func runHandler(t *testing.T, cfg *Config, secrets testutils.Secrets) [][]byte {
	t.Helper()
	runtime := testutils.NewRuntime(t, secrets)
	runtime.SetTimeProvider(func() time.Time { return time.Unix(1_700_000_000, 0) })

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
	// The receiver address mock: no view calls, only the WriteReport capture.
	evmmock.AddContractMock(receiverAddr, evmMock, map[string]func([]byte) ([]byte, error){}, writeCap)

	if _, err := onCron(cfg, runtime, nil); err != nil {
		t.Fatalf("onCron: %v", err)
	}
	return captured
}

// TestSimWritesLpMark drives the whole handler (incl. RunInNodeMode + identical consensus) and asserts the
// captured report is the LpMark envelope with the consensus mark + the DON-stamped ts.
func TestSimWritesLpMark(t *testing.T) {
	out := runHandler(t, testConfig(), testutils.Secrets{})
	if len(out) != 1 {
		t.Fatalf("expected 1 write (LpMark), got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.LpMark {
		t.Fatalf("reportType: got %d want %d (LpMark)", rt, zipreport.LpMark)
	}
	u256, _ := abi.NewType("uint256", "", nil)
	u32, _ := abi.NewType("uint32", "", nil)
	dec, err := abi.Arguments{{Type: u256}, {Type: u32}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	if dec[0].(*big.Int).Cmp(new(big.Int).SetUint64(templateMark)) != 0 {
		t.Fatalf("mark: got %v want %v", dec[0], templateMark)
	}
	if dec[1].(uint32) != uint32(1_700_000_000) {
		t.Fatalf("ts: got %v want %v", dec[1], uint32(1_700_000_000))
	}
}

// TestSimSeededSecretStillWrites confirms the seeded-secret happy path also writes (secret keyed by the
// testutils Namespace->ID->value scheme with an EMPTY namespace, matching how GetSecret(&SecretRequest{Id})
// is looked up: Namespace defaults to "").
func TestSimSeededSecretStillWrites(t *testing.T) {
	secrets := testutils.Secrets{"": {"DEMO_SECRET": "demo-value"}}
	out := runHandler(t, testConfig(), secrets)
	if len(out) != 1 {
		t.Fatalf("expected 1 write with seeded secret, got %d", len(out))
	}
	if rt, _ := decodeEnvelope(t, out[0]); rt != zipreport.LpMark {
		t.Fatalf("reportType: got %d want %d (LpMark)", rt, zipreport.LpMark)
	}
}

// TestSimNoOpWhenReceiverUnset asserts the fail-safe skip: no receiver ⇒ no write.
func TestSimNoOpWhenReceiverUnset(t *testing.T) {
	cfg := testConfig()
	cfg.Receiver = ""
	out := runHandler(t, cfg, testutils.Secrets{})
	if len(out) != 0 {
		t.Fatalf("expected no-op (receiver unset), got %d writes", len(out))
	}
}
