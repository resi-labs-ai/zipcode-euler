// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host sim test for the CRE-04 senior-warehouse op producer (models cre/coordinator/workflow_test.go). It
// exercises, per the Done-when:
//   - the encode handshake (per op): the captured report decodes to (uint8 opType, bytes payload) with the
//     expected opType byte, then the payload to the EXACT WarehouseAdminModule decode tuple for that op — by
//     decoding the bytes, NOT by trusting zipreport. All four: supply → (uint256) opType 1; approve →
//     (uint256) opType 2; redeem → (uint256) opType 3; repay → (address,uint256) opType 4. Asserting the
//     decoded scalars equal the input, and the opType against BOTH the constant AND the literal;
//   - validation errors ⇒ no write (unknown/empty op; supply/approve/redeem zero/non-base-10/missing
//     magnitude; repay zero/malformed/missing dest + zero/non-base-10/missing amount);
//   - op normalization: "  SuPPLy  " dispatches to supply;
//   - no-op: unset Warehouse ⇒ 0 writes;
//   - the FULL handler path through RunInNodeMode + ConsensusIdenticalAggregation[WarehouseOp] (proving the
//     string-only carrier values.Wraps) + dispatch + zipreport.Wh*Report + GenerateReport + WriteReport, under
//     testutils + evmmock, asserting the captured envelope;
//   - a parseAddress unit test (good + the bad set).
package main

import (
	"encoding/json"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	evmmock "github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/mock"
	httpcap "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/cre/testutils"

	zipreport "cre-zipreport"
)

const testChainSelector = evm.EthereumMainnetBase1

var warehouseAddr = common.HexToAddress("0x00000000000000000000000000000000000000C8")

func testConfig() *Config {
	return &Config{
		ChainSelector: testChainSelector,
		Warehouse:     warehouseAddr.Hex(),
		WriteGasLimit: 600_000,
	}
}

// addr20 builds a deterministic, non-zero 20-byte address hex string for the given low byte.
func addr20(low byte) string {
	var a common.Address
	a[0] = 0xAB
	a[19] = low
	return a.Hex()
}

const zeroAddr = "0x0000000000000000000000000000000000000000"

// eventJSON marshals a WarehouseOp into the wire body the trigger carries.
func eventJSON(t *testing.T, ev WarehouseOp) []byte {
	t.Helper()
	b, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	return b
}

// runHandler wires the mocks, runs onWarehouseOp with a *httpcap.Payload carrying the event, and returns the
// captured WriteReport envelopes. Modeled on cre/coordinator/workflow_test.go.
func runHandler(t *testing.T, cfg *Config, event []byte) ([][]byte, error) {
	t.Helper()
	runtime := testutils.NewRuntime(t, testutils.Secrets{})

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
	evmmock.AddContractMock(warehouseAddr, evmMock, map[string]func([]byte) ([]byte, error){}, writeCap)

	_, herr := onWarehouseOp(cfg, runtime, &httpcap.Payload{Input: event})
	return captured, herr
}

// decodeEnvelope decodes the §8.5 envelope as (uint8 opType, bytes payload).
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

func mustType(t *testing.T, s string) abi.Type {
	t.Helper()
	ty, err := abi.NewType(s, "", nil)
	if err != nil {
		t.Fatalf("abi type %q: %v", s, err)
	}
	return ty
}

// assertEnvelope decodes the captured report to the §8.5 envelope, asserting the opType against BOTH the
// expected constant AND the literal. Returns the payload bytes for the per-op tuple decode.
func assertEnvelope(t *testing.T, env []byte, wantOp uint8, wantOpLiteral uint8) []byte {
	t.Helper()
	opType, payload := decodeEnvelope(t, env)
	if opType != wantOp {
		t.Fatalf("opType: got %d want constant %d", opType, wantOp)
	}
	if opType != wantOpLiteral {
		t.Fatalf("opType: got %d want literal %d", opType, wantOpLiteral)
	}
	return payload
}

// ─────────────────────────────────────────────────────────── encode handshake (per op, full handler)

// TestSimSupplyHandshake: supply → opType 1 → payload (uint256 amount).
func TestSimSupplyHandshake(t *testing.T) {
	ev := WarehouseOp{Op: "supply", Amount: "1000000"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onWarehouseOp: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	payload := assertEnvelope(t, out[0], zipreport.WhSupply, 1)
	dec, err := abi.Arguments{{Type: mustType(t, "uint256")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode supply payload: %v", err)
	}
	if len(dec) != 1 {
		t.Fatalf("supply tuple: got %d fields want 1", len(dec))
	}
	if dec[0].(*big.Int).String() != ev.Amount {
		t.Fatalf("amount: got %s want %s", dec[0].(*big.Int), ev.Amount)
	}
}

// TestSimApproveHandshake: approve → opType 2 → payload (uint256 amount).
func TestSimApproveHandshake(t *testing.T) {
	ev := WarehouseOp{Op: "approve", Amount: "2500000"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onWarehouseOp: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	payload := assertEnvelope(t, out[0], zipreport.WhApprove, 2)
	dec, err := abi.Arguments{{Type: mustType(t, "uint256")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode approve payload: %v", err)
	}
	if dec[0].(*big.Int).String() != ev.Amount {
		t.Fatalf("amount: got %s want %s", dec[0].(*big.Int), ev.Amount)
	}
}

// TestSimRedeemHandshake: redeem → opType 3 → payload (uint256 shares).
func TestSimRedeemHandshake(t *testing.T) {
	ev := WarehouseOp{Op: "redeem", Shares: "750000000000000000"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onWarehouseOp: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	payload := assertEnvelope(t, out[0], zipreport.WhRedeem, 3)
	dec, err := abi.Arguments{{Type: mustType(t, "uint256")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode redeem payload: %v", err)
	}
	if dec[0].(*big.Int).String() != ev.Shares {
		t.Fatalf("shares: got %s want %s", dec[0].(*big.Int), ev.Shares)
	}
}

// TestSimRepayHandshake: repay → opType 4 → payload (address dest, uint256 amount).
func TestSimRepayHandshake(t *testing.T) {
	ev := WarehouseOp{Op: "repay", Dest: addr20(0x0A), Amount: "3000000"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onWarehouseOp: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	payload := assertEnvelope(t, out[0], zipreport.WhRepay, 4)
	dec, err := abi.Arguments{{Type: mustType(t, "address")}, {Type: mustType(t, "uint256")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode repay payload: %v", err)
	}
	if len(dec) != 2 {
		t.Fatalf("repay tuple: got %d fields want 2", len(dec))
	}
	if dec[0].(common.Address) != common.HexToAddress(ev.Dest) {
		t.Fatalf("dest: got %s want %s", dec[0].(common.Address).Hex(), ev.Dest)
	}
	if dec[1].(*big.Int).String() != ev.Amount {
		t.Fatalf("amount: got %s want %s", dec[1].(*big.Int), ev.Amount)
	}
}

// TestSimOpNormalization: a mixed-case + whitespace op ("  SuPPLy  ") still dispatches to supply.
func TestSimOpNormalization(t *testing.T) {
	ev := WarehouseOp{Op: "  SuPPLy  ", Amount: "1"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onWarehouseOp: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	assertEnvelope(t, out[0], zipreport.WhSupply, 1)
}

// ─────────────────────────────────────────────────────────── validation errors ⇒ no write (full handler)

func TestSimValidationErrorsNoWrite(t *testing.T) {
	cases := []struct {
		name string
		ev   WarehouseOp
	}{
		{"unknown op", WarehouseOp{Op: "bogus", Amount: "1"}},
		{"empty op", WarehouseOp{Op: "", Amount: "1"}},
		// supply: amount guards
		{"supply zero amount", WarehouseOp{Op: "supply", Amount: "0"}},
		{"supply non-base-10 amount", WarehouseOp{Op: "supply", Amount: "not-a-number"}},
		{"supply missing amount", WarehouseOp{Op: "supply", Amount: ""}},
		{"supply negative amount", WarehouseOp{Op: "supply", Amount: "-1"}},
		// approve: amount guards
		{"approve zero amount", WarehouseOp{Op: "approve", Amount: "0"}},
		{"approve non-base-10 amount", WarehouseOp{Op: "approve", Amount: "NaN"}},
		{"approve missing amount", WarehouseOp{Op: "approve", Amount: ""}},
		// redeem: shares guards
		{"redeem zero shares", WarehouseOp{Op: "redeem", Shares: "0"}},
		{"redeem non-base-10 shares", WarehouseOp{Op: "redeem", Shares: "x"}},
		{"redeem missing shares", WarehouseOp{Op: "redeem", Shares: ""}},
		// repay: dest guards
		{"repay zero dest", WarehouseOp{Op: "repay", Dest: zeroAddr, Amount: "1"}},
		{"repay malformed dest (short)", WarehouseOp{Op: "repay", Dest: "0xABCD", Amount: "1"}},
		{"repay missing dest", WarehouseOp{Op: "repay", Dest: "", Amount: "1"}},
		// repay: amount guards
		{"repay zero amount", WarehouseOp{Op: "repay", Dest: addr20(0x0A), Amount: "0"}},
		{"repay non-base-10 amount", WarehouseOp{Op: "repay", Dest: addr20(0x0A), Amount: "y"}},
		{"repay missing amount", WarehouseOp{Op: "repay", Dest: addr20(0x0A), Amount: ""}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out, err := runHandler(t, testConfig(), eventJSON(t, c.ev))
			if err == nil {
				t.Fatalf("%s: expected error, got nil", c.name)
			}
			if len(out) != 0 {
				t.Fatalf("%s: expected 0 writes, got %d", c.name, len(out))
			}
		})
	}
}

// ─────────────────────────────────────────────────────────── no-op fail-safe (full handler)

func TestSimNoOpWarehouseUnset(t *testing.T) {
	cfg := testConfig()
	cfg.Warehouse = ""
	ev := WarehouseOp{Op: "supply", Amount: "1"}
	out, err := runHandler(t, cfg, eventJSON(t, ev))
	if err != nil {
		t.Fatalf("warehouse unset should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (warehouse unset), got %d", len(out))
	}
}

// ─────────────────────────────────────────────────────────── pure helpers

func TestParseAddress(t *testing.T) {
	good := addr20(0x0A)
	if _, err := parseAddress(good); err != nil {
		t.Fatalf("good address %s rejected: %v", good, err)
	}
	bad := []string{
		"",                    // empty
		"ABCD",                // no 0x
		"0xABCD",              // too short
		good[:len(good)-1],    // 39 hex (too short by 1)
		good + "0",            // 41 hex (too long by 1)
		"0x" + "g" + good[3:], // non-hex char
		zeroAddr,              // zero address rejected
	}
	for _, s := range bad {
		if _, err := parseAddress(s); err == nil {
			t.Fatalf("expected parseAddress(%q) to error", s)
		}
	}
}
