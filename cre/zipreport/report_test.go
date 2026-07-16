// SPDX-License-Identifier: GPL-2.0-or-later
//
// Round-trip test for the §8.0 report encoders. NON-VACUOUS: for every builder we (a) decode the produced
// bytes as (uint8, bytes) and assert the reportType; (b) decode the inner payload as the EXACT filed tuple
// (the abi.decode site cited in report.go's header) and assert every field equals the input. For the
// Coordinator builders we additionally decode the inner-inner (uint8 action, bytes) and the action tuple.
// Length-mismatch error cases for Revaluation/NavLeg are covered.
//
// The filed decode sites (source of truth — see report.go header for the full per-receiver line citations):
//
//	envelope                      abi.encode(uint8 reportType, bytes payload)
//	Origination (1)               (bytes32,bytes32,uint256,uint16,uint16,uint256,uint256,bytes32)  Controller:222
//	Draw (2)                      (bytes32,bytes32,uint256,uint256)                                 Controller:266
//	Close (4)                     (bytes32)                                                         Controller:287
//	Status (5/6)                  (bytes32,uint8)                                                   Controller:203
//	Revaluation (3)               (address[],uint256[],uint32)                                      Registry:132
//	NavLeg (7)                    (uint8[],uint256[],uint32)                                        NavOracle:304
//	LpMark (7)                    (uint256,uint32)                                                  LpOracle:109
//	Coordinator (8)               (uint8 action, bytes data) + per-action tuple                     Coordinator:185
//	Rate (8)                      (uint256,uint48)                                                  RateOracle:83
//	Warehouse (1/2/3/4)           per-op                                                            Warehouse:164-176
package zipreport

import (
	"bytes"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

// b32 builds a deterministic, distinct [32]byte from a seed byte.
func b32(seed byte) [32]byte {
	var out [32]byte
	for i := range out {
		out[i] = seed + byte(i)
	}
	return out
}

// decodeEnvelope decodes the §8.0 envelope as (uint8 reportType, bytes payload) — the first thing every
// receiver's _processReport does.
func decodeEnvelope(t *testing.T, env []byte) (uint8, []byte) {
	t.Helper()
	out, err := args(tUint8, tBytes).Unpack(env)
	if err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	return out[0].(uint8), out[1].([]byte)
}

func mustEnv(t *testing.T, env []byte, err error, wantRT uint8) []byte {
	t.Helper()
	if err != nil {
		t.Fatalf("builder error: %v", err)
	}
	rt, payload := decodeEnvelope(t, env)
	if rt != wantRT {
		t.Fatalf("reportType: got %d want %d", rt, wantRT)
	}
	return payload
}

func eqBig(t *testing.T, name string, got *big.Int, want *big.Int) {
	t.Helper()
	if got.Cmp(want) != 0 {
		t.Fatalf("%s: got %v want %v", name, got, want)
	}
}

func eqB32(t *testing.T, name string, got [32]byte, want [32]byte) {
	t.Helper()
	if got != want {
		t.Fatalf("%s: got %x want %x", name, got, want)
	}
}

// ──────────────────────────────────────────────────────────────────────── ZipcodeController

func TestOriginationRoundTrip(t *testing.T) {
	lienId := b32(1)
	proofRef := b32(2)
	siloId := b32(3)
	equityMark := big.NewInt(1_000_000)
	drawAmount := big.NewInt(750_000)
	cap, _ := new(big.Int).SetString("123456789012345678901234567890", 10)
	borrowLTV := uint16(7000)
	liqLTV := uint16(8500)

	env, err := Origination(lienId, proofRef, equityMark, borrowLTV, liqLTV, drawAmount, cap, siloId)
	payload := mustEnv(t, env, err, ControllerOrigination)

	out, err := args(tBytes32, tBytes32, tUint256, tUint16, tUint16, tUint256, tUint256, tBytes32).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
	eqB32(t, "proofRef", out[1].([32]byte), proofRef)
	eqBig(t, "equityMark", out[2].(*big.Int), equityMark)
	if out[3].(uint16) != borrowLTV {
		t.Fatalf("borrowLTV: got %d want %d", out[3].(uint16), borrowLTV)
	}
	if out[4].(uint16) != liqLTV {
		t.Fatalf("liqLTV: got %d want %d", out[4].(uint16), liqLTV)
	}
	eqBig(t, "drawAmount", out[5].(*big.Int), drawAmount)
	eqBig(t, "cap", out[6].(*big.Int), cap)
	eqB32(t, "siloId", out[7].([32]byte), siloId)
}

func TestDrawRoundTrip(t *testing.T) {
	lienId := b32(10)
	proofRef := b32(20)
	equityMark := big.NewInt(2_000_000)
	drawAmount := big.NewInt(500_000)

	env, err := Draw(lienId, proofRef, equityMark, drawAmount)
	payload := mustEnv(t, env, err, ControllerDraw)

	out, err := args(tBytes32, tBytes32, tUint256, tUint256).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
	eqB32(t, "proofRef", out[1].([32]byte), proofRef)
	eqBig(t, "equityMark", out[2].(*big.Int), equityMark)
	eqBig(t, "drawAmount", out[3].(*big.Int), drawAmount)
}

func TestCloseRoundTrip(t *testing.T) {
	lienId := b32(42)
	env, err := Close(lienId)
	payload := mustEnv(t, env, err, ControllerClose)

	out, err := args(tBytes32).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
}

func TestStatusRoundTrip(t *testing.T) {
	for _, rt := range []uint8{ControllerDefault, ControllerLiquidation} {
		lienId := b32(rt)
		status := uint8(3)
		env, err := Status(rt, lienId, status)
		payload := mustEnv(t, env, err, rt)

		out, err := args(tBytes32, tUint8).Unpack(payload)
		if err != nil {
			t.Fatalf("decode inner: %v", err)
		}
		eqB32(t, "lienId", out[0].([32]byte), lienId)
		if out[1].(uint8) != status {
			t.Fatalf("status: got %d want %d", out[1].(uint8), status)
		}
	}
}

func TestStatusRejectsBadReportType(t *testing.T) {
	for _, bad := range []uint8{0, 1, 2, 3, 4, 7, 8} {
		if _, err := Status(bad, b32(0), 1); err == nil {
			t.Fatalf("Status(%d) should error (only 5/6 allowed)", bad)
		}
	}
}

// ──────────────────────────────────────────────────────────────────────── ZipcodeOracleRegistry

func TestRevaluationRoundTrip(t *testing.T) {
	liens := []common.Address{
		common.HexToAddress("0x00000000000000000000000000000000000000A1"),
		common.HexToAddress("0x00000000000000000000000000000000000000A2"),
	}
	prices := []*big.Int{big.NewInt(1_010_000), big.NewInt(990_000)}
	ts := uint32(1_900_000_000)

	env, err := Revaluation(liens, prices, ts)
	payload := mustEnv(t, env, err, RegistryRevaluation)

	out, err := args(tAddrArr, tU256Arr, tUint32).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	gotLiens := out[0].([]common.Address)
	if len(gotLiens) != len(liens) {
		t.Fatalf("liens len: got %d want %d", len(gotLiens), len(liens))
	}
	for i := range liens {
		if gotLiens[i] != liens[i] {
			t.Fatalf("liens[%d]: got %s want %s", i, gotLiens[i], liens[i])
		}
	}
	gotPrices := out[1].([]*big.Int)
	for i := range prices {
		eqBig(t, "prices", gotPrices[i], prices[i])
	}
	if out[2].(uint32) != ts {
		t.Fatalf("ts: got %d want %d", out[2].(uint32), ts)
	}
}

func TestRevaluationLengthMismatch(t *testing.T) {
	liens := []common.Address{common.HexToAddress("0x01")}
	prices := []*big.Int{big.NewInt(1), big.NewInt(2)}
	if _, err := Revaluation(liens, prices, 0); err == nil {
		t.Fatal("Revaluation with mismatched lengths should error")
	}
}

// ──────────────────────────────────────────────────────────────────────── SzipNavOracle

func TestNavLegRoundTrip(t *testing.T) {
	legs := []uint8{LegAlphaUsd, LegHydxUsd}
	prices := []*big.Int{big.NewInt(1_234_567), big.NewInt(7_654_321)}
	ts := uint32(1_888_000_000)

	env, err := NavLegReport(legs, prices, ts)
	payload := mustEnv(t, env, err, NavLeg)

	out, err := args(tU8Arr, tU256Arr, tUint32).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	gotLegs := out[0].([]uint8)
	if len(gotLegs) != len(legs) {
		t.Fatalf("legs len: got %d want %d", len(gotLegs), len(legs))
	}
	for i := range legs {
		if gotLegs[i] != legs[i] {
			t.Fatalf("legs[%d]: got %d want %d", i, gotLegs[i], legs[i])
		}
	}
	gotPrices := out[1].([]*big.Int)
	for i := range prices {
		eqBig(t, "prices", gotPrices[i], prices[i])
	}
	if out[2].(uint32) != ts {
		t.Fatalf("ts: got %d want %d", out[2].(uint32), ts)
	}
}

func TestNavLegLengthMismatch(t *testing.T) {
	if _, err := NavLegReport([]uint8{0, 1}, []*big.Int{big.NewInt(1)}, 0); err == nil {
		t.Fatal("NavLeg with mismatched lengths should error")
	}
}

// ──────────────────────────────────────────────────────────────────────── SzipFarmUtilityLpOracle

func TestLpMarkRoundTrip(t *testing.T) {
	mark, _ := new(big.Int).SetString("999999999999999999999", 10)
	ts := uint32(1_777_000_000)

	env, err := LpMarkReport(mark, ts)
	payload := mustEnv(t, env, err, LpMark)

	out, err := args(tUint256, tUint32).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	eqBig(t, "mark", out[0].(*big.Int), mark)
	if out[1].(uint32) != ts {
		t.Fatalf("ts: got %d want %d", out[1].(uint32), ts)
	}
}

// ──────────────────────────────────────────────────────────────────────── SzAlphaRateOracle

func TestRateRoundTrip(t *testing.T) {
	rate := big.NewInt(1_050_000_000_000_000_000) // 1.05e18
	ts := big.NewInt(1_666_000_000)               // uint48

	env, err := Rate(rate, ts)
	payload := mustEnv(t, env, err, RateReportType)

	out, err := args(tUint256, tUint48).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	eqBig(t, "rate", out[0].(*big.Int), rate)
	eqBig(t, "ts", out[1].(*big.Int), ts)
}

// ──────────────────────────────────────────────────────────────────────── DefaultCoordinator
//
// Each: decode envelope (rt==8), decode inner-inner (uint8 action, bytes data), assert action, then
// decode the action's data tuple and assert every field.

// decodeCoord decodes a coordinator envelope down to (action, data).
func decodeCoord(t *testing.T, env []byte) (uint8, []byte) {
	t.Helper()
	payload := mustEnv(t, env, nil, CoordinatorReportType)
	out, err := args(tUint8, tBytes).Unpack(payload)
	if err != nil {
		t.Fatalf("decode (action,data): %v", err)
	}
	return out[0].(uint8), out[1].([]byte)
}

func TestCoordLockRoundTrip(t *testing.T) {
	lienId := b32(50)
	originator := common.HexToAddress("0x00000000000000000000000000000000000000B7")
	amount := big.NewInt(3_141_592)

	env, err := CoordLock(lienId, originator, amount)
	if err != nil {
		t.Fatalf("CoordLock: %v", err)
	}
	action, data := decodeCoord(t, env)
	if action != ActionLock {
		t.Fatalf("action: got %d want %d", action, ActionLock)
	}
	out, err := args(tBytes32, tAddress, tUint256).Unpack(data)
	if err != nil {
		t.Fatalf("decode data: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
	if out[1].(common.Address) != originator {
		t.Fatalf("originator: got %s want %s", out[1].(common.Address), originator)
	}
	eqBig(t, "amount", out[2].(*big.Int), amount)
}

func TestCoordReleaseRoundTrip(t *testing.T) {
	lienId := b32(60)
	env, err := CoordRelease(lienId)
	if err != nil {
		t.Fatalf("CoordRelease: %v", err)
	}
	action, data := decodeCoord(t, env)
	if action != ActionRelease {
		t.Fatalf("action: got %d want %d", action, ActionRelease)
	}
	out, err := args(tBytes32).Unpack(data)
	if err != nil {
		t.Fatalf("decode data: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
}

func TestCoordDefaultRoundTrip(t *testing.T) {
	lienId := b32(70)
	atRisk := big.NewInt(123_456)
	env, err := CoordDefault(lienId, atRisk)
	if err != nil {
		t.Fatalf("CoordDefault: %v", err)
	}
	action, data := decodeCoord(t, env)
	if action != ActionDefault {
		t.Fatalf("action: got %d want %d", action, ActionDefault)
	}
	out, err := args(tBytes32, tUint256).Unpack(data)
	if err != nil {
		t.Fatalf("decode data: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
	eqBig(t, "atRisk", out[1].(*big.Int), atRisk)
}

func TestCoordRecoveryRoundTrip(t *testing.T) {
	lienId := b32(80)
	proceeds := big.NewInt(654_321)
	env, err := CoordRecovery(lienId, proceeds)
	if err != nil {
		t.Fatalf("CoordRecovery: %v", err)
	}
	action, data := decodeCoord(t, env)
	if action != ActionRecovery {
		t.Fatalf("action: got %d want %d", action, ActionRecovery)
	}
	out, err := args(tBytes32, tUint256).Unpack(data)
	if err != nil {
		t.Fatalf("decode data: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
	eqBig(t, "recoveryProceeds", out[1].(*big.Int), proceeds)
}

func TestCoordResolveRoundTrip(t *testing.T) {
	lienId := b32(90)
	slash := big.NewInt(111_222)
	env, err := CoordResolve(lienId, slash)
	if err != nil {
		t.Fatalf("CoordResolve: %v", err)
	}
	action, data := decodeCoord(t, env)
	if action != ActionResolve {
		t.Fatalf("action: got %d want %d", action, ActionResolve)
	}
	out, err := args(tBytes32, tUint256).Unpack(data)
	if err != nil {
		t.Fatalf("decode data: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
	eqBig(t, "capitalSlashAmount", out[1].(*big.Int), slash)
}

func TestCoordWriteOffRoundTrip(t *testing.T) {
	lienId := b32(100)
	slash := big.NewInt(333_444)
	env, err := CoordWriteOff(lienId, slash)
	if err != nil {
		t.Fatalf("CoordWriteOff: %v", err)
	}
	action, data := decodeCoord(t, env)
	if action != ActionWriteOff {
		t.Fatalf("action: got %d want %d", action, ActionWriteOff)
	}
	out, err := args(tBytes32, tUint256).Unpack(data)
	if err != nil {
		t.Fatalf("decode data: %v", err)
	}
	eqB32(t, "lienId", out[0].([32]byte), lienId)
	eqBig(t, "capitalSlashAmount", out[1].(*big.Int), slash)
}

// ──────────────────────────────────────────────────────────────────────── WarehouseAdminModule

func TestWhSupplyRoundTrip(t *testing.T) {
	amount := big.NewInt(1_000_000)
	env, err := WhSupplyReport(amount)
	payload := mustEnv(t, env, err, WhSupply)
	out, err := args(tUint256).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	eqBig(t, "amount", out[0].(*big.Int), amount)
}

func TestWhApproveRoundTrip(t *testing.T) {
	amount := big.NewInt(2_000_000)
	env, err := WhApproveReport(amount)
	payload := mustEnv(t, env, err, WhApprove)
	out, err := args(tUint256).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	eqBig(t, "amount", out[0].(*big.Int), amount)
}

func TestWhRedeemRoundTrip(t *testing.T) {
	shares := big.NewInt(3_000_000)
	env, err := WhRedeemReport(shares)
	payload := mustEnv(t, env, err, WhRedeem)
	out, err := args(tUint256).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	eqBig(t, "shares", out[0].(*big.Int), shares)
}

func TestWhRepayRoundTrip(t *testing.T) {
	dest := common.HexToAddress("0x00000000000000000000000000000000000000DD")
	amount := big.NewInt(4_000_000)
	env, err := WhRepayReport(dest, amount)
	payload := mustEnv(t, env, err, WhRepay)
	out, err := args(tAddress, tUint256).Unpack(payload)
	if err != nil {
		t.Fatalf("decode inner: %v", err)
	}
	if out[0].(common.Address) != dest {
		t.Fatalf("dest: got %s want %s", out[0].(common.Address), dest)
	}
	eqBig(t, "amount", out[1].(*big.Int), amount)
}

// ──────────────────────────────────────────────────────────────────────── envelope sanity

func TestEnvelopeRoundTrip(t *testing.T) {
	payload := []byte{0xde, 0xad, 0xbe, 0xef}
	env, err := Envelope(7, payload)
	if err != nil {
		t.Fatalf("Envelope: %v", err)
	}
	rt, got := decodeEnvelope(t, env)
	if rt != 7 {
		t.Fatalf("reportType: got %d want 7", rt)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("payload: got %x want %x", got, payload)
	}
}
