// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host sim test for the CRE-01b controller lifecycle producer (models cre/revaluation/workflow_test.go). It
// exercises, per the Done-when:
//   - the encode handshake (per action): the captured report decodes to (uint8 reportType, bytes payload) and
//     the payload to the EXACT ZipcodeController decode tuple for that action — by decoding the bytes, NOT by
//     trusting zipreport;
//   - the §8.9 Proof gate: all-true ⇒ 1 write; two separate cases each flipping a DIFFERENT single gate ⇒ 0;
//   - siloId routing: origination carries the trailing bytes32; draw's tuple is 4 elements (no siloId);
//   - validation errors ⇒ no write (unknown/empty action, malformed/zero lienId, zero/non-base-10 equityMark);
//   - no-op: unset Controller ⇒ 0 writes;
//   - the FULL handler path through RunInNodeMode + ConsensusIdenticalAggregation[Application] (proving the
//     bool/uintN/nested-struct carrier values.Wraps) + dispatch + gate + zipreport.* + GenerateReport +
//     WriteReport, under testutils + evmmock, asserting the captured envelope.
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

var controllerAddr = common.HexToAddress("0x00000000000000000000000000000000000000C7")

func testConfig() *Config {
	return &Config{
		ChainSelector: testChainSelector,
		Controller:    controllerAddr.Hex(),
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

const zeroHash = "0x0000000000000000000000000000000000000000000000000000000000000000"

// allTrueGates returns Gates with every Proof boolean true (the gate passes).
func allTrueGates() Gates {
	return Gates{LienPerfected: true, Insured: true, IdentityOk: true, CreditOk: true, IncomeOk: true, TitleClean: true}
}

// eventJSON marshals an Application into the wire body the trigger carries.
func eventJSON(t *testing.T, app Application) []byte {
	t.Helper()
	b, err := json.Marshal(app)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	return b
}

// runHandler wires the mocks, runs onApplication with a *httpcap.Payload carrying the event, and returns the
// captured WriteReport envelopes. Modeled on cre/revaluation/workflow_test.go.
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
	evmmock.AddContractMock(controllerAddr, evmMock, map[string]func([]byte) ([]byte, error){}, writeCap)

	_, herr := onApplication(cfg, runtime, &httpcap.Payload{Input: event})
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

func mustType(t *testing.T, s string) abi.Type {
	t.Helper()
	ty, err := abi.NewType(s, "", nil)
	if err != nil {
		t.Fatalf("abi type %q: %v", s, err)
	}
	return ty
}

// ─────────────────────────────────────────────────────────── encode handshake (per action, full handler)

// TestSimOriginationHandshake drives the full handler for an origination event and asserts the captured bytes
// decode to (uint8 1, bytes) → the EXACT _origination tuple
// (bytes32,bytes32,uint256,uint16,uint16,uint256,uint256,bytes32), including the trailing siloId.
func TestSimOriginationHandshake(t *testing.T) {
	app := Application{
		Action:     "origination",
		LienID:     hash32(0x01),
		ProofRef:   hash32(0x02),
		SiloID:     hash32(0x03),
		EquityMark: "1500000000000000000",
		DrawAmount: "1000000000000000000",
		Cap:        "5000000000000000000",
		BorrowLTV:  7500,
		LiqLTV:     8500,
		Gates:      allTrueGates(),
	}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("onApplication: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.ControllerOrigination {
		t.Fatalf("reportType: got %d want zipreport.ControllerOrigination", rt)
	}
	if rt != 1 {
		t.Fatalf("reportType: got %d want literal 1 (ORIGINATION)", rt)
	}
	dec, err := abi.Arguments{
		{Type: mustType(t, "bytes32")}, {Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint256")},
		{Type: mustType(t, "uint16")}, {Type: mustType(t, "uint16")}, {Type: mustType(t, "uint256")},
		{Type: mustType(t, "uint256")}, {Type: mustType(t, "bytes32")},
	}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode origination payload: %v", err)
	}
	if len(dec) != 8 {
		t.Fatalf("origination tuple: got %d fields want 8", len(dec))
	}
	gotLien := dec[0].([32]byte)
	if common.Hash(gotLien) != common.HexToHash(app.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(gotLien).Hex(), app.LienID)
	}
	gotProof := dec[1].([32]byte)
	if common.Hash(gotProof) != common.HexToHash(app.ProofRef) {
		t.Fatalf("proofRef: got %s want %s", common.Hash(gotProof).Hex(), app.ProofRef)
	}
	if dec[2].(*big.Int).String() != app.EquityMark {
		t.Fatalf("equityMark: got %s want %s", dec[2].(*big.Int), app.EquityMark)
	}
	if dec[3].(uint16) != app.BorrowLTV {
		t.Fatalf("borrowLTV: got %d want %d", dec[3].(uint16), app.BorrowLTV)
	}
	if dec[4].(uint16) != app.LiqLTV {
		t.Fatalf("liqLTV: got %d want %d", dec[4].(uint16), app.LiqLTV)
	}
	if dec[5].(*big.Int).String() != app.DrawAmount {
		t.Fatalf("drawAmount: got %s want %s", dec[5].(*big.Int), app.DrawAmount)
	}
	if dec[6].(*big.Int).String() != app.Cap {
		t.Fatalf("cap: got %s want %s", dec[6].(*big.Int), app.Cap)
	}
	// siloId routing (CTR-03): the trailing bytes32 decodes to the input siloId.
	gotSilo := dec[7].([32]byte)
	if common.Hash(gotSilo) != common.HexToHash(app.SiloID) {
		t.Fatalf("siloId: got %s want %s", common.Hash(gotSilo).Hex(), app.SiloID)
	}
}

// TestSimDrawHandshake asserts the draw payload decodes to (bytes32,bytes32,uint256,uint256) rt2 — a 4-element
// tuple with NO siloId.
func TestSimDrawHandshake(t *testing.T) {
	app := Application{
		Action:     "draw",
		LienID:     hash32(0x11),
		ProofRef:   hash32(0x12),
		EquityMark: "2000000000000000000",
		DrawAmount: "750000000000000000",
		SiloID:     hash32(0x99), // present on the wire but MUST NOT be sent (re-resolved on-chain)
		Gates:      allTrueGates(),
	}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("onApplication: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.ControllerDraw {
		t.Fatalf("reportType: got %d want zipreport.ControllerDraw", rt)
	}
	if rt != 2 {
		t.Fatalf("reportType: got %d want literal 2 (DRAW)", rt)
	}
	dec, err := abi.Arguments{
		{Type: mustType(t, "bytes32")}, {Type: mustType(t, "bytes32")},
		{Type: mustType(t, "uint256")}, {Type: mustType(t, "uint256")},
	}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode draw payload: %v", err)
	}
	if len(dec) != 4 {
		t.Fatalf("draw tuple: got %d fields want 4 (NO siloId)", len(dec))
	}
	gotLien := dec[0].([32]byte)
	if common.Hash(gotLien) != common.HexToHash(app.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(gotLien).Hex(), app.LienID)
	}
	if dec[2].(*big.Int).String() != app.EquityMark {
		t.Fatalf("equityMark: got %s want %s", dec[2].(*big.Int), app.EquityMark)
	}
	if dec[3].(*big.Int).String() != app.DrawAmount {
		t.Fatalf("drawAmount: got %s want %s", dec[3].(*big.Int), app.DrawAmount)
	}
}

// TestSimCloseHandshake asserts the close payload decodes to (bytes32) rt4.
func TestSimCloseHandshake(t *testing.T) {
	app := Application{Action: "close", LienID: hash32(0x21)}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("onApplication: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.ControllerClose {
		t.Fatalf("reportType: got %d want zipreport.ControllerClose", rt)
	}
	if rt != 4 {
		t.Fatalf("reportType: got %d want literal 4 (CLOSE)", rt)
	}
	dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode close payload: %v", err)
	}
	if len(dec) != 1 {
		t.Fatalf("close tuple: got %d fields want 1", len(dec))
	}
	gotLien := dec[0].([32]byte)
	if common.Hash(gotLien) != common.HexToHash(app.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(gotLien).Hex(), app.LienID)
	}
}

// TestSimDefaultHandshake asserts the default payload decodes to (bytes32,uint8) rt5.
func TestSimDefaultHandshake(t *testing.T) {
	app := Application{Action: "default", LienID: hash32(0x31), Status: 7}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("onApplication: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.ControllerDefault {
		t.Fatalf("reportType: got %d want zipreport.ControllerDefault", rt)
	}
	if rt != 5 {
		t.Fatalf("reportType: got %d want literal 5 (DEFAULT)", rt)
	}
	dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint8")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode default payload: %v", err)
	}
	gotLien := dec[0].([32]byte)
	if common.Hash(gotLien) != common.HexToHash(app.LienID) {
		t.Fatalf("lienId: got %s want %s", common.Hash(gotLien).Hex(), app.LienID)
	}
	if dec[1].(uint8) != app.Status {
		t.Fatalf("status: got %d want %d", dec[1].(uint8), app.Status)
	}
}

// TestSimLiquidationHandshake asserts the liquidation payload decodes to (bytes32,uint8) rt6.
func TestSimLiquidationHandshake(t *testing.T) {
	app := Application{Action: "liquidation", LienID: hash32(0x41), Status: 3}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("onApplication: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("expected 1 write, got %d", len(out))
	}
	rt, payload := decodeEnvelope(t, out[0])
	if rt != zipreport.ControllerLiquidation {
		t.Fatalf("reportType: got %d want zipreport.ControllerLiquidation", rt)
	}
	if rt != 6 {
		t.Fatalf("reportType: got %d want literal 6 (LIQUIDATION)", rt)
	}
	dec, err := abi.Arguments{{Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint8")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode liquidation payload: %v", err)
	}
	if dec[1].(uint8) != app.Status {
		t.Fatalf("status: got %d want %d", dec[1].(uint8), app.Status)
	}
}

// ─────────────────────────────────────────────────────────── §8.9 Proof gate (full handler)

// TestSimOriginationGatePass: all gates true ⇒ exactly 1 write.
func TestSimOriginationGatePass(t *testing.T) {
	app := Application{
		Action: "origination", LienID: hash32(0x01), ProofRef: hash32(0x02), SiloID: hash32(0x03),
		EquityMark: "1500000000000000000", DrawAmount: "1", Cap: "0", BorrowLTV: 7500, LiqLTV: 8500,
		Gates: allTrueGates(),
	}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("onApplication: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("gate-pass: expected 1 write, got %d", len(out))
	}
}

// TestSimOriginationGateFailLienPerfected: flips lienPerfected=false ⇒ 0 writes, no error.
func TestSimOriginationGateFailLienPerfected(t *testing.T) {
	g := allTrueGates()
	g.LienPerfected = false
	app := Application{
		Action: "origination", LienID: hash32(0x01), ProofRef: hash32(0x02), SiloID: hash32(0x03),
		EquityMark: "1500000000000000000", DrawAmount: "1", Cap: "0", BorrowLTV: 7500, LiqLTV: 8500, Gates: g,
	}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("gate fail should be a no-op (nil err), got: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("gate fail (lienPerfected): expected 0 writes, got %d", len(out))
	}
}

// TestSimDrawGateFailInsured: a DIFFERENT single gate (insured=false) on a DIFFERENT action ⇒ 0 writes. Pairs
// with the lienPerfected case so the all-must-pass logic is exercised on more than one field.
func TestSimDrawGateFailInsured(t *testing.T) {
	g := allTrueGates()
	g.Insured = false
	app := Application{
		Action: "draw", LienID: hash32(0x11), ProofRef: hash32(0x12),
		EquityMark: "2000000000000000000", DrawAmount: "5", Gates: g,
	}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("gate fail should be a no-op (nil err), got: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("gate fail (insured): expected 0 writes, got %d", len(out))
	}
}

// ─────────────────────────────────────────────────────────── validation errors ⇒ no write (full handler)

func TestSimValidationErrorsNoWrite(t *testing.T) {
	good := func() Application {
		return Application{
			Action: "origination", LienID: hash32(0x01), ProofRef: hash32(0x02), SiloID: hash32(0x03),
			EquityMark: "1500000000000000000", DrawAmount: "1", Cap: "0", BorrowLTV: 7500, LiqLTV: 8500,
			Gates: allTrueGates(),
		}
	}
	cases := []struct {
		name string
		mut  func(a *Application)
	}{
		{"unknown action", func(a *Application) { a.Action = "bogus" }},
		{"empty action", func(a *Application) { a.Action = "" }},
		{"malformed lienId (short)", func(a *Application) { a.LienID = "0xDEAD" }},
		{"zero lienId", func(a *Application) { a.LienID = zeroHash }},
		{"non-base-10 equityMark", func(a *Application) { a.EquityMark = "not-a-number" }},
		{"zero equityMark", func(a *Application) { a.EquityMark = "0" }},
		{"missing equityMark", func(a *Application) { a.EquityMark = "" }},
		{"zero siloId", func(a *Application) { a.SiloID = zeroHash }},
		{"missing drawAmount", func(a *Application) { a.DrawAmount = "" }},
		{"draw zero equityMark", func(a *Application) { a.Action = "draw"; a.EquityMark = "0" }},
		{"draw malformed lienId", func(a *Application) { a.Action = "draw"; a.LienID = "0xZZ" }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			app := good()
			c.mut(&app)
			out, err := runHandler(t, testConfig(), eventJSON(t, app))
			if err == nil {
				t.Fatalf("%s: expected error, got nil", c.name)
			}
			if len(out) != 0 {
				t.Fatalf("%s: expected 0 writes, got %d", c.name, len(out))
			}
		})
	}
}

// TestSimZeroProofRefAccepted: a zero proofRef on origination is ACCEPTED (off-chain commitment, may be zero).
func TestSimZeroProofRefAccepted(t *testing.T) {
	app := Application{
		Action: "origination", LienID: hash32(0x01), ProofRef: zeroHash, SiloID: hash32(0x03),
		EquityMark: "1500000000000000000", DrawAmount: "1", Cap: "0", BorrowLTV: 7500, LiqLTV: 8500,
		Gates: allTrueGates(),
	}
	out, err := runHandler(t, testConfig(), eventJSON(t, app))
	if err != nil {
		t.Fatalf("zero proofRef should be accepted, got err: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("zero proofRef: expected 1 write, got %d", len(out))
	}
	_, payload := decodeEnvelope(t, out[0])
	dec, err := abi.Arguments{
		{Type: mustType(t, "bytes32")}, {Type: mustType(t, "bytes32")}, {Type: mustType(t, "uint256")},
		{Type: mustType(t, "uint16")}, {Type: mustType(t, "uint16")}, {Type: mustType(t, "uint256")},
		{Type: mustType(t, "uint256")}, {Type: mustType(t, "bytes32")},
	}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if (dec[1].([32]byte)) != ([32]byte{}) {
		t.Fatalf("proofRef: expected zero, got %x", dec[1].([32]byte))
	}
}

// ─────────────────────────────────────────────────────────── no-op fail-safe (full handler)

func TestSimNoOpControllerUnset(t *testing.T) {
	cfg := testConfig()
	cfg.Controller = ""
	app := Application{
		Action: "origination", LienID: hash32(0x01), ProofRef: hash32(0x02), SiloID: hash32(0x03),
		EquityMark: "1500000000000000000", DrawAmount: "1", Cap: "0", BorrowLTV: 7500, LiqLTV: 8500,
		Gates: allTrueGates(),
	}
	out, err := runHandler(t, cfg, eventJSON(t, app))
	if err != nil {
		t.Fatalf("controller unset should be a no-op, got err: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("expected 0 writes (controller unset), got %d", len(out))
	}
}

// ─────────────────────────────────────────────────────────── pure helper: parseBytes32

func TestParseBytes32(t *testing.T) {
	good := hash32(0x01)
	if _, err := parseBytes32(good, false); err != nil {
		t.Fatalf("good bytes32 %s rejected: %v", good, err)
	}
	// zero accepted iff allowZero.
	if _, err := parseBytes32(zeroHash, true); err != nil {
		t.Fatalf("zero with allowZero should pass: %v", err)
	}
	if _, err := parseBytes32(zeroHash, false); err == nil {
		t.Fatalf("zero with !allowZero should fail")
	}
	bad := []string{
		"",                 // empty
		"DEADBEEF",         // no 0x
		"0xDEAD",           // too short
		good[:len(good)-1], // 63 hex chars (too short by 1)
		good + "0",         // 65 hex chars (too long by 1)
		"0x" + "g" + good[3:], // non-hex char
	}
	for _, s := range bad {
		if _, err := parseBytes32(s, true); err == nil {
			t.Fatalf("expected parseBytes32(%q) to error", s)
		}
	}
}
