// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host sim test for the CRE-01c loss-action producer (models cre/controller/workflow_test.go). It exercises,
// per the Done-when:
//   - the encode handshake (per action): the captured report decodes to (uint8 reportType, bytes payload) with
//     reportType == 8, then the payload to (uint8 action, bytes data) with the expected action byte, then data
//     to the EXACT DefaultCoordinator decode tuple for that action — by decoding the bytes, NOT by trusting
//     zipreport. All six actions, asserting the decoded scalars equal the input;
//   - validation errors ⇒ no write (unknown/empty action, malformed/zero lienId, lock zero/malformed
//     originator + zero/non-base-10 amount, default zero/non-base-10 atRisk); a 0 recoveryProceeds /
//     capitalSlashAmount on recovery/resolve/writeoff is ACCEPTED ⇒ 1 write;
//   - no-op: unset Coordinator ⇒ 0 writes;
//   - the FULL handler path through RunInNodeMode + ConsensusIdenticalAggregation[LossEvent] (proving the
//     string-only carrier values.Wraps) + dispatch + zipreport.Coord* + GenerateReport + WriteReport, under
//     testutils + evmmock, asserting the captured envelope.
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

var coordinatorAddr = common.HexToAddress("0x00000000000000000000000000000000000000C8")

func testConfig() *Config {
	return &Config{
		ChainSelector: testChainSelector,
		Coordinator:   coordinatorAddr.Hex(),
		WriteGasLimit: 600_000,
	}
}

// hash32 builds a deterministic, non-zero 32-byte hex string for the given low byte.
func hash32(low byte) string {
	var h common.Hash
	h[0] = 0xAB
	h[31] = low
	return h.Hex()
}

// addr20 builds a deterministic, non-zero 20-byte address hex string for the given low byte.
func addr20(low byte) string {
	var a common.Address
	a[0] = 0xAB
	a[19] = low
	return a.Hex()
}

const zeroHash = "0x0000000000000000000000000000000000000000000000000000000000000000"
const zeroAddr = "0x0000000000000000000000000000000000000000"

// eventJSON marshals a LossEvent into the wire body the trigger carries.
func eventJSON(t *testing.T, ev LossEvent) []byte {
	t.Helper()
	b, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	return b
}

// runHandler wires the mocks, runs onLossEvent with a *httpcap.Payload carrying the event, and returns the
// captured WriteReport envelopes. Modeled on cre/controller/workflow_test.go.
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
	evmmock.AddContractMock(coordinatorAddr, evmMock, map[string]func([]byte) ([]byte, error){}, writeCap)

	_, herr := onLossEvent(cfg, runtime, &httpcap.Payload{Input: event})
	return captured, herr
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

// decodeAction decodes the §8.4 inner envelope as (uint8 action, bytes data).
func decodeAction(t *testing.T, payload []byte) (uint8, []byte) {
	t.Helper()
	u8, _ := abi.NewType("uint8", "", nil)
	bts, _ := abi.NewType("bytes", "", nil)
	out, err := abi.Arguments{{Type: u8}, {Type: bts}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode action envelope: %v", err)
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

// assertEnvelope decodes the captured report to the rt8 envelope + the (action, data) inner envelope, asserting
// the reportType against BOTH zipreport.CoordinatorReportType AND the literal 8, and the action byte against
// both the expected constant and the literal. Returns the innermost actionData bytes for tuple decode.
func assertEnvelope(t *testing.T, env []byte, wantAction uint8, wantActionLiteral uint8) []byte {
	t.Helper()
	rt, payload := decodeEnvelope(t, env)
	if rt != zipreport.CoordinatorReportType {
		t.Fatalf("reportType: got %d want zipreport.CoordinatorReportType", rt)
	}
	if rt != 8 {
		t.Fatalf("reportType: got %d want literal 8 (Coordinator)", rt)
	}
	action, data := decodeAction(t, payload)
	if action != wantAction {
		t.Fatalf("action: got %d want constant %d", action, wantAction)
	}
	if action != wantActionLiteral {
		t.Fatalf("action: got %d want literal %d", action, wantActionLiteral)
	}
	return data
}

// ─────────────────────────────────────────────────────────── encode handshake (per action, full handler)

// TestSimLockHandshake: lock → action 0 → data (bytes32 lienId, address originator, uint256 amount).
func TestSimLockHandshake(t *testing.T) {
	ev := LossEvent{
		Action:     "lock",
		LienID:     hash32(0x01),
		Originator: addr20(0x0A),
		Amount:     "1000000000000000000",
	}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onLossEvent: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	data := assertEnvelope(t, out[0], zipreport.ActionLock, 0)
	dec, err := abi.Arguments{
		{Type: mustType(t, "bytes32")}, {Type: mustType(t, "address")}, {Type: mustType(t, "uint256")},
	}.Unpack(data)
	if err != nil {
		t.Fatalf("decode lock data: %v", err)
	}
	if len(dec) != 3 {
		t.Fatalf("lock tuple: got %d fields want 3", len(dec))
	}
	if common.Hash(dec[0].([32]byte)) != common.HexToHash(ev.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(dec[0].([32]byte)).Hex(), ev.LienID)
	}
	if dec[1].(common.Address) != common.HexToAddress(ev.Originator) {
		t.Fatalf("originator: got %s want %s", dec[1].(common.Address).Hex(), ev.Originator)
	}
	if dec[2].(*big.Int).String() != ev.Amount {
		t.Fatalf("amount: got %s want %s", dec[2].(*big.Int), ev.Amount)
	}
}

// TestSimReleaseHandshake: release → action 1 → data (bytes32 lienId).
func TestSimReleaseHandshake(t *testing.T) {
	ev := LossEvent{Action: "release", LienID: hash32(0x11)}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onLossEvent: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	data := assertEnvelope(t, out[0], zipreport.ActionRelease, 1)
	dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}}.Unpack(data)
	if err != nil {
		t.Fatalf("decode release data: %v", err)
	}
	if len(dec) != 1 {
		t.Fatalf("release tuple: got %d fields want 1", len(dec))
	}
	if common.Hash(dec[0].([32]byte)) != common.HexToHash(ev.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(dec[0].([32]byte)).Hex(), ev.LienID)
	}
}

// TestSimDefaultHandshake: default → action 2 → data (bytes32 lienId, uint256 atRisk).
func TestSimDefaultHandshake(t *testing.T) {
	ev := LossEvent{Action: "default", LienID: hash32(0x21), AtRisk: "5000000000000000000"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onLossEvent: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	data := assertEnvelope(t, out[0], zipreport.ActionDefault, 2)
	dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint256")}}.Unpack(data)
	if err != nil {
		t.Fatalf("decode default data: %v", err)
	}
	if common.Hash(dec[0].([32]byte)) != common.HexToHash(ev.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(dec[0].([32]byte)).Hex(), ev.LienID)
	}
	if dec[1].(*big.Int).String() != ev.AtRisk {
		t.Fatalf("atRisk: got %s want %s", dec[1].(*big.Int), ev.AtRisk)
	}
}

// TestSimRecoveryHandshake: recovery → action 3 → data (bytes32 lienId, uint256 recoveryProceeds).
func TestSimRecoveryHandshake(t *testing.T) {
	ev := LossEvent{Action: "recovery", LienID: hash32(0x31), RecoveryProceeds: "2500000000000000000"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onLossEvent: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	data := assertEnvelope(t, out[0], zipreport.ActionRecovery, 3)
	dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint256")}}.Unpack(data)
	if err != nil {
		t.Fatalf("decode recovery data: %v", err)
	}
	if common.Hash(dec[0].([32]byte)) != common.HexToHash(ev.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(dec[0].([32]byte)).Hex(), ev.LienID)
	}
	if dec[1].(*big.Int).String() != ev.RecoveryProceeds {
		t.Fatalf("recoveryProceeds: got %s want %s", dec[1].(*big.Int), ev.RecoveryProceeds)
	}
}

// TestSimResolveHandshake: resolve → action 4 → data (bytes32 lienId, uint256 capitalSlashAmount).
func TestSimResolveHandshake(t *testing.T) {
	ev := LossEvent{Action: "resolve", LienID: hash32(0x41), CapitalSlashAmount: "750000000000000000"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onLossEvent: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	data := assertEnvelope(t, out[0], zipreport.ActionResolve, 4)
	dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint256")}}.Unpack(data)
	if err != nil {
		t.Fatalf("decode resolve data: %v", err)
	}
	if common.Hash(dec[0].([32]byte)) != common.HexToHash(ev.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(dec[0].([32]byte)).Hex(), ev.LienID)
	}
	if dec[1].(*big.Int).String() != ev.CapitalSlashAmount {
		t.Fatalf("capitalSlashAmount: got %s want %s", dec[1].(*big.Int), ev.CapitalSlashAmount)
	}
}

// TestSimWriteOffHandshake: writeoff → action 5 → data (bytes32 lienId, uint256 capitalSlashAmount).
func TestSimWriteOffHandshake(t *testing.T) {
	ev := LossEvent{Action: "writeoff", LienID: hash32(0x51), CapitalSlashAmount: "999000000000000000"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onLossEvent: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	data := assertEnvelope(t, out[0], zipreport.ActionWriteOff, 5)
	dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint256")}}.Unpack(data)
	if err != nil {
		t.Fatalf("decode writeoff data: %v", err)
	}
	if common.Hash(dec[0].([32]byte)) != common.HexToHash(ev.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(dec[0].([32]byte)).Hex(), ev.LienID)
	}
	if dec[1].(*big.Int).String() != ev.CapitalSlashAmount {
		t.Fatalf("capitalSlashAmount: got %s want %s", dec[1].(*big.Int), ev.CapitalSlashAmount)
	}
}

// TestSimActionNormalization: a mixed-case + whitespace action ("  LoCk  ") still dispatches to lock.
func TestSimActionNormalization(t *testing.T) {
	ev := LossEvent{Action: "  LoCk  ", LienID: hash32(0x01), Originator: addr20(0x0A), Amount: "1"}
	out, err := runHandler(t, testConfig(), eventJSON(t, ev))
	if err != nil {
		t.Fatalf("onLossEvent: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	assertEnvelope(t, out[0], zipreport.ActionLock, 0)
}

// ─────────────────────────────────────────────────────────── zero magnitudes ACCEPTED (1 write)

// TestSimZeroMagnitudesAccepted: a 0 recoveryProceeds / capitalSlashAmount is accepted (the contract tolerates
// them), each producing exactly one write with the 0 magnitude round-tripped.
func TestSimZeroMagnitudesAccepted(t *testing.T) {
	cases := []struct {
		name   string
		ev     LossEvent
		action uint8
		lit    uint8
	}{
		{"recovery zero", LossEvent{Action: "recovery", LienID: hash32(0x31), RecoveryProceeds: "0"}, zipreport.ActionRecovery, 3},
		{"resolve zero", LossEvent{Action: "resolve", LienID: hash32(0x41), CapitalSlashAmount: "0"}, zipreport.ActionResolve, 4},
		{"writeoff zero", LossEvent{Action: "writeoff", LienID: hash32(0x51), CapitalSlashAmount: "0"}, zipreport.ActionWriteOff, 5},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out, err := runHandler(t, testConfig(), eventJSON(t, c.ev))
			if err != nil {
				t.Fatalf("%s: expected accept, got err: %v", c.name, err)
			}
			if len(out) != 1 {
				t.Fatalf("%s: expected 1 write, got %d", c.name, len(out))
			}
			data := assertEnvelope(t, out[0], c.action, c.lit)
			dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint256")}}.Unpack(data)
			if err != nil {
				t.Fatalf("%s: decode data: %v", c.name, err)
			}
			if dec[1].(*big.Int).Sign() != 0 {
				t.Fatalf("%s: magnitude: got %s want 0", c.name, dec[1].(*big.Int))
			}
		})
	}
}

// ─────────────────────────────────────────────────────────── validation errors ⇒ no write (full handler)

func TestSimValidationErrorsNoWrite(t *testing.T) {
	cases := []struct {
		name string
		ev   LossEvent
	}{
		{"unknown action", LossEvent{Action: "bogus", LienID: hash32(0x01)}},
		{"empty action", LossEvent{Action: "", LienID: hash32(0x01)}},
		{"release malformed lienId (short)", LossEvent{Action: "release", LienID: "0xDEAD"}},
		{"release zero lienId", LossEvent{Action: "release", LienID: zeroHash}},
		{"release missing lienId", LossEvent{Action: "release", LienID: ""}},
		// lock: originator + amount guards
		{"lock zero originator", LossEvent{Action: "lock", LienID: hash32(0x01), Originator: zeroAddr, Amount: "1"}},
		{"lock malformed originator (short)", LossEvent{Action: "lock", LienID: hash32(0x01), Originator: "0xABCD", Amount: "1"}},
		{"lock missing originator", LossEvent{Action: "lock", LienID: hash32(0x01), Originator: "", Amount: "1"}},
		{"lock zero amount", LossEvent{Action: "lock", LienID: hash32(0x01), Originator: addr20(0x0A), Amount: "0"}},
		{"lock non-base-10 amount", LossEvent{Action: "lock", LienID: hash32(0x01), Originator: addr20(0x0A), Amount: "not-a-number"}},
		{"lock missing amount", LossEvent{Action: "lock", LienID: hash32(0x01), Originator: addr20(0x0A), Amount: ""}},
		// default: atRisk guards
		{"default zero atRisk", LossEvent{Action: "default", LienID: hash32(0x21), AtRisk: "0"}},
		{"default non-base-10 atRisk", LossEvent{Action: "default", LienID: hash32(0x21), AtRisk: "NaN"}},
		{"default missing atRisk", LossEvent{Action: "default", LienID: hash32(0x21), AtRisk: ""}},
		// recovery/resolve/writeoff: missing/malformed magnitude (present requirement)
		{"recovery missing recoveryProceeds", LossEvent{Action: "recovery", LienID: hash32(0x31), RecoveryProceeds: ""}},
		{"recovery non-base-10", LossEvent{Action: "recovery", LienID: hash32(0x31), RecoveryProceeds: "x"}},
		{"resolve missing capitalSlashAmount", LossEvent{Action: "resolve", LienID: hash32(0x41), CapitalSlashAmount: ""}},
		{"writeoff non-base-10", LossEvent{Action: "writeoff", LienID: hash32(0x51), CapitalSlashAmount: "y"}},
		// negative magnitude rejected
		{"recovery negative", LossEvent{Action: "recovery", LienID: hash32(0x31), RecoveryProceeds: "-1"}},
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

func TestSimNoOpCoordinatorUnset(t *testing.T) {
	cfg := testConfig()
	cfg.Coordinator = ""
	ev := LossEvent{Action: "lock", LienID: hash32(0x01), Originator: addr20(0x0A), Amount: "1"}
	out, err := runHandler(t, cfg, eventJSON(t, ev))
	if err != nil {
		t.Fatalf("coordinator unset should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (coordinator unset), got %d", len(out))
	}
}

// ─────────────────────────────────────────────────────────── pure helpers

func TestParseBytes32(t *testing.T) {
	good := hash32(0x01)
	if _, err := parseBytes32(good, false); err != nil {
		t.Fatalf("good bytes32 %s rejected: %v", good, err)
	}
	if _, err := parseBytes32(zeroHash, true); err != nil {
		t.Fatalf("zero with allowZero should pass: %v", err)
	}
	if _, err := parseBytes32(zeroHash, false); err == nil {
		t.Fatalf("zero with !allowZero should fail")
	}
	bad := []string{"", "DEADBEEF", "0xDEAD", good[:len(good)-1], good + "0", "0x" + "g" + good[3:]}
	for _, s := range bad {
		if _, err := parseBytes32(s, true); err == nil {
			t.Fatalf("expected parseBytes32(%q) to error", s)
		}
	}
}

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
