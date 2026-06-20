// SPDX-License-Identifier: GPL-2.0-or-later
//
// Package zipreport is the single, SDK-free encoder for the §8.0 report envelope and every
// per-(receiver, reportType) payload the Zipcode CRE report-path (R) workflows write.
//
// CRE-01/03/04 import this package instead of re-implementing the §8.0 handshake. It depends ONLY on
// github.com/ethereum/go-ethereum (accounts/abi + common); it has NO cre-sdk dependency, so it builds
// for the host AND for the wasip1 workflow target, and is trivially unit-testable.
//
// EVERY builder below is pinned to the EXACT tuple the FILED contract decodes — the filed contract is the
// source of truth, not spec prose. The decode sites (verified against the contracts):
//
//	Envelope (every receiver): abi.encode(uint8 reportType, bytes payload)
//	  ZipcodeController.sol:193, ZipcodeOracleRegistry.sol:129, SzipNavOracle.sol:301,
//	  SzipReservoirLpOracle.sol:107, DefaultCoordinator.sol:182, SzAlphaRateOracle.sol:81,
//	  WarehouseAdminModule.sol:158 (there the first field is named opType — same (uint8, bytes) shape).
//
//	reportType  receiver constant @ line                 inner payload tuple (the abi.decode site)
//	1 Origination ZipcodeController.RT_ORIGINATION  :47   (bytes32 lienId, bytes32 proofRef, uint256 equityMark,
//	                                                        uint16 borrowLTV, uint16 liqLTV, uint256 drawAmount,
//	                                                        uint256 cap, bytes32 siloId)            :222
//	2 Draw        ZipcodeController.RT_DRAW         :48   (bytes32 lienId, bytes32 proofRef, uint256 equityMark,
//	                                                        uint256 drawAmount)                      :266
//	4 Close       ZipcodeController.RT_CLOSE        :50   (bytes32 lienId)                           :287
//	5 Default /   ZipcodeController.RT_DEFAULT      :51   (bytes32 lienId, uint8 status)            :203
//	6 Liquidation ZipcodeController.RT_LIQUIDATION  :52
//	3 Revaluation ZipcodeOracleRegistry.REVALUATION :29   (address[] liens, uint256[] prices, uint32 ts) :132
//	7 NavLeg      SzipNavOracle.NAV_LEG             :72   (uint8[] legs, uint256[] prices, uint32 ts) :304
//	                                                       legs ∈ {0 LEG_ALPHA_USD, 1 LEG_HYDX_USD}  :66/:68
//	7 LpMark      SzipReservoirLpOracle.LP_MARK     :28   (uint256 mark, uint32 ts)                  :109
//	8 Coordinator DefaultCoordinator.REPORT_TYPE    :49   (uint8 action, bytes data)                 :185
//	                                                       action: Lock=0,Release=1,Default_=2,Recovery=3,
//	                                                       Resolve=4,WriteOff=5                       :52-58
//	8 RATE        SzAlphaRateOracle.RATE            :26   (uint256 rate, uint48 ts)                  :83
//	1/2/3/4 Wh op WarehouseAdminModule.SUPPLY/APPROVE/REDEEM/REPAY :25-31  per-op (below); first field is opType
//
// DefaultCoordinator action `data` tuples (the inner-inner decode):
//
//	Lock(0)     -> (bytes32 lienId, address originator, uint256 amount)        :207
//	Release(1)  -> (bytes32 lienId)                                            :220
//	Default_(2) -> (bytes32 lienId, uint256 atRisk)                            :235
//	Recovery(3) -> (bytes32 lienId, uint256 recoveryProceeds)                  :254
//	Resolve(4)  -> (bytes32 lienId, uint256 capitalSlashAmount)               :277
//	WriteOff(5) -> (bytes32 lienId, uint256 capitalSlashAmount)               :296
//
// WarehouseAdminModule op payloads (envelope (uint8 opType, bytes payload)):
//
//	SUPPLY(1)  -> (uint256 amount)            :164
//	APPROVE(2) -> (uint256 amount)            :168
//	REDEEM(3)  -> (uint256 shares)            :172
//	REPAY(4)   -> (address dest, uint256 amount) :176
//
// go-ethereum v1.17.2 abi.Pack native-type mapping (VERIFIED via cre/buyburn-bid/workflow.go:248):
// uint8->uint8, uint16->uint16, uint32->uint32, uint48/uint256->*big.Int, bytes32->[32]byte,
// address->common.Address, address[]->[]common.Address, uint256[]->[]*big.Int, uint8[]->[]uint8,
// bytes->[]byte. A *big.Int for a uint32 is REJECTED by v1.17.2 — pass native; the ABI bytes are identical.
package zipreport

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// ──────────────────────────────────────────────────────────────────────── reportType / action / op constants
//
// One const block per RECEIVER so the cross-receiver numeral collisions are explicit and a reader cannot
// conflate them: NavLeg==7 and LpMark==7 live in different blocks; CoordinatorReportType==8 and
// RateReportType==8 likewise; the warehouse WhSupply==1..WhRepay==4 reuse 1-4 but are opTypes on their
// own receiver.

// ZipcodeController report types.
const (
	ControllerOrigination uint8 = 1 // RT_ORIGINATION (:47)
	ControllerDraw        uint8 = 2 // RT_DRAW (:48)
	ControllerClose       uint8 = 4 // RT_CLOSE (:50)
	ControllerDefault     uint8 = 5 // RT_DEFAULT (:51)
	ControllerLiquidation uint8 = 6 // RT_LIQUIDATION (:52)
)

// ZipcodeOracleRegistry report type.
const (
	RegistryRevaluation uint8 = 3 // REVALUATION (:29)
)

// SzipNavOracle report type + leg ids.
const (
	NavLeg      uint8 = 7 // NAV_LEG (:72)
	LegAlphaUsd uint8 = 0 // LEG_ALPHA_USD (:66)
	LegHydxUsd  uint8 = 1 // LEG_HYDX_USD (:68)
)

// SzipReservoirLpOracle report type.
const (
	LpMark uint8 = 7 // LP_MARK (:28)
)

// DefaultCoordinator report type + action enum.
const (
	CoordinatorReportType uint8 = 8 // REPORT_TYPE (:49)

	ActionLock     uint8 = 0 // Lock (:52)
	ActionRelease  uint8 = 1 // Release (:53)
	ActionDefault  uint8 = 2 // Default_ (:54)
	ActionRecovery uint8 = 3 // Recovery (:55)
	ActionResolve  uint8 = 4 // Resolve (:56)
	ActionWriteOff uint8 = 5 // WriteOff (:57-58)
)

// SzAlphaRateOracle report type.
const (
	RateReportType uint8 = 8 // RATE (:26)
)

// WarehouseAdminModule op types (these are opTypes on the warehouse receiver, NOT controller report types).
const (
	WhSupply  uint8 = 1 // SUPPLY (:25)
	WhApprove uint8 = 2 // APPROVE (:27)
	WhRedeem  uint8 = 3 // REDEEM (:29)
	WhRepay   uint8 = 4 // REPAY (:31)
)

// ──────────────────────────────────────────────────────────────────────── abi types (built once)

var (
	tUint8    = mustType("uint8")
	tUint16   = mustType("uint16")
	tUint32   = mustType("uint32")
	tUint48   = mustType("uint48")
	tUint256  = mustType("uint256")
	tBytes    = mustType("bytes")
	tBytes32  = mustType("bytes32")
	tAddress  = mustType("address")
	tAddrArr  = mustType("address[]")
	tU256Arr  = mustType("uint256[]")
	tU8Arr    = mustType("uint8[]")
)

func mustType(s string) abi.Type {
	t, err := abi.NewType(s, "", nil)
	if err != nil {
		panic(fmt.Sprintf("zipreport: bad abi type %q: %v", s, err))
	}
	return t
}

func args(ts ...abi.Type) abi.Arguments {
	out := make(abi.Arguments, len(ts))
	for i, t := range ts {
		out[i] = abi.Argument{Type: t}
	}
	return out
}

// ──────────────────────────────────────────────────────────────────────── the §8.0 envelope

// Envelope packs the §8.0 report envelope abi.encode(uint8 reportType, bytes payload). The warehouse
// builders reuse it, passing opType as the first arg (same (uint8, bytes) wire shape).
func Envelope(reportType uint8, payload []byte) ([]byte, error) {
	return args(tUint8, tBytes).Pack(reportType, payload)
}

// wrap encodes a payload tuple, then wraps it in the §8.0 envelope. The single internal seam every
// builder routes through.
func wrap(reportType uint8, payloadArgs abi.Arguments, vals ...interface{}) ([]byte, error) {
	payload, err := payloadArgs.Pack(vals...)
	if err != nil {
		return nil, err
	}
	return Envelope(reportType, payload)
}

// ──────────────────────────────────────────────────────────────────────── ZipcodeController builders

// Origination encodes RT_ORIGINATION (1):
// (bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV,
//
//	uint256 drawAmount, uint256 cap, bytes32 siloId) — ZipcodeController.sol:222.
func Origination(lienId, proofRef [32]byte, equityMark *big.Int, borrowLTV, liqLTV uint16, drawAmount, cap *big.Int, siloId [32]byte) ([]byte, error) {
	return wrap(ControllerOrigination,
		args(tBytes32, tBytes32, tUint256, tUint16, tUint16, tUint256, tUint256, tBytes32),
		lienId, proofRef, equityMark, borrowLTV, liqLTV, drawAmount, cap, siloId)
}

// Draw encodes RT_DRAW (2): (bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)
// — ZipcodeController.sol:266.
func Draw(lienId, proofRef [32]byte, equityMark, drawAmount *big.Int) ([]byte, error) {
	return wrap(ControllerDraw,
		args(tBytes32, tBytes32, tUint256, tUint256),
		lienId, proofRef, equityMark, drawAmount)
}

// Close encodes RT_CLOSE (4): (bytes32 lienId) — ZipcodeController.sol:287.
func Close(lienId [32]byte) ([]byte, error) {
	return wrap(ControllerClose, args(tBytes32), lienId)
}

// Status encodes RT_DEFAULT (5) / RT_LIQUIDATION (6): (bytes32 lienId, uint8 status)
// — ZipcodeController.sol:203. reportType MUST be 5 or 6.
func Status(reportType uint8, lienId [32]byte, status uint8) ([]byte, error) {
	if reportType != ControllerDefault && reportType != ControllerLiquidation {
		return nil, fmt.Errorf("zipreport.Status: reportType must be %d (Default) or %d (Liquidation), got %d",
			ControllerDefault, ControllerLiquidation, reportType)
	}
	return wrap(reportType, args(tBytes32, tUint8), lienId, status)
}

// ──────────────────────────────────────────────────────────────────────── ZipcodeOracleRegistry builder

// Revaluation encodes REVALUATION (3): (address[] liens, uint256[] prices, uint32 ts)
// — ZipcodeOracleRegistry.sol:132. Errors if len(liens) != len(prices) (the contract reverts
// LengthMismatch; fail early off-chain).
func Revaluation(liens []common.Address, prices []*big.Int, ts uint32) ([]byte, error) {
	if len(liens) != len(prices) {
		return nil, fmt.Errorf("zipreport.Revaluation: len(liens)=%d != len(prices)=%d (LengthMismatch)", len(liens), len(prices))
	}
	return wrap(RegistryRevaluation, args(tAddrArr, tU256Arr, tUint32), liens, prices, ts)
}

// ──────────────────────────────────────────────────────────────────────── SzipNavOracle builder

// NavLegReport encodes NAV_LEG (7): (uint8[] legs, uint256[] prices, uint32 ts) — SzipNavOracle.sol:304.
// Errors if len(legs) != len(prices) (LengthMismatch). Leg range (LegAlphaUsd/LegHydxUsd) is NOT
// checked here — the contract's InvalidLeg guard owns that.
//
// Named NavLegReport (not NavLeg) because NavLeg is the reportType constant; a name cannot be both in Go.
func NavLegReport(legs []uint8, prices []*big.Int, ts uint32) ([]byte, error) {
	if len(legs) != len(prices) {
		return nil, fmt.Errorf("zipreport.NavLeg: len(legs)=%d != len(prices)=%d (LengthMismatch)", len(legs), len(prices))
	}
	return wrap(NavLeg, args(tU8Arr, tU256Arr, tUint32), legs, prices, ts)
}

// ──────────────────────────────────────────────────────────────────────── SzipReservoirLpOracle builder

// LpMarkReport encodes LP_MARK (7): (uint256 mark, uint32 ts) — SzipReservoirLpOracle.sol:109.
//
// Named LpMarkReport (not LpMark) because LpMark is the reportType constant. Exported for clarity.
func LpMarkReport(mark *big.Int, ts uint32) ([]byte, error) {
	return wrap(LpMark, args(tUint256, tUint32), mark, ts)
}

// ──────────────────────────────────────────────────────────────────────── SzAlphaRateOracle builder

// Rate encodes RATE (8): (uint256 rate, uint48 ts) — SzAlphaRateOracle.sol:83. ts is uint48 → *big.Int.
func Rate(rate, ts *big.Int) ([]byte, error) {
	return wrap(RateReportType, args(tUint256, tUint48), rate, ts)
}

// ──────────────────────────────────────────────────────────────────────── DefaultCoordinator builders
//
// All produce REPORT_TYPE (8) with inner (uint8 action, bytes data) — DefaultCoordinator.sol:185 — where
// data is the action-specific tuple (the inner-inner decode).

// coordEnvelope packs (uint8 action, bytes data) then wraps it in the §8.0 envelope as reportType 8.
func coordEnvelope(action uint8, data []byte) ([]byte, error) {
	return wrap(CoordinatorReportType, args(tUint8, tBytes), action, data)
}

// CoordLock encodes action Lock(0): data = (bytes32 lienId, address originator, uint256 amount) — :207.
func CoordLock(lienId [32]byte, originator common.Address, amount *big.Int) ([]byte, error) {
	data, err := args(tBytes32, tAddress, tUint256).Pack(lienId, originator, amount)
	if err != nil {
		return nil, err
	}
	return coordEnvelope(ActionLock, data)
}

// CoordRelease encodes action Release(1): data = (bytes32 lienId) — :220.
func CoordRelease(lienId [32]byte) ([]byte, error) {
	data, err := args(tBytes32).Pack(lienId)
	if err != nil {
		return nil, err
	}
	return coordEnvelope(ActionRelease, data)
}

// CoordDefault encodes action Default_(2): data = (bytes32 lienId, uint256 atRisk) — :235.
func CoordDefault(lienId [32]byte, atRisk *big.Int) ([]byte, error) {
	data, err := args(tBytes32, tUint256).Pack(lienId, atRisk)
	if err != nil {
		return nil, err
	}
	return coordEnvelope(ActionDefault, data)
}

// CoordRecovery encodes action Recovery(3): data = (bytes32 lienId, uint256 recoveryProceeds) — :254.
func CoordRecovery(lienId [32]byte, recoveryProceeds *big.Int) ([]byte, error) {
	data, err := args(tBytes32, tUint256).Pack(lienId, recoveryProceeds)
	if err != nil {
		return nil, err
	}
	return coordEnvelope(ActionRecovery, data)
}

// CoordResolve encodes action Resolve(4): data = (bytes32 lienId, uint256 capitalSlashAmount) — :277.
func CoordResolve(lienId [32]byte, capitalSlashAmount *big.Int) ([]byte, error) {
	data, err := args(tBytes32, tUint256).Pack(lienId, capitalSlashAmount)
	if err != nil {
		return nil, err
	}
	return coordEnvelope(ActionResolve, data)
}

// CoordWriteOff encodes action WriteOff(5): data = (bytes32 lienId, uint256 capitalSlashAmount) — :296.
func CoordWriteOff(lienId [32]byte, capitalSlashAmount *big.Int) ([]byte, error) {
	data, err := args(tBytes32, tUint256).Pack(lienId, capitalSlashAmount)
	if err != nil {
		return nil, err
	}
	return coordEnvelope(ActionWriteOff, data)
}

// ──────────────────────────────────────────────────────────────────────── WarehouseAdminModule builders
//
// The envelope first field is opType (same (uint8, bytes) shape — Envelope is reused).

// WhSupplyReport encodes SUPPLY (opType 1): (uint256 amount) — WarehouseAdminModule.sol:164.
func WhSupplyReport(amount *big.Int) ([]byte, error) {
	return wrap(WhSupply, args(tUint256), amount)
}

// WhApproveReport encodes APPROVE (opType 2): (uint256 amount) — WarehouseAdminModule.sol:168.
func WhApproveReport(amount *big.Int) ([]byte, error) {
	return wrap(WhApprove, args(tUint256), amount)
}

// WhRedeemReport encodes REDEEM (opType 3): (uint256 shares) — WarehouseAdminModule.sol:172.
func WhRedeemReport(shares *big.Int) ([]byte, error) {
	return wrap(WhRedeem, args(tUint256), shares)
}

// WhRepayReport encodes REPAY (opType 4): (address dest, uint256 amount) — WarehouseAdminModule.sol:176.
func WhRepayReport(dest common.Address, amount *big.Int) ([]byte, error) {
	return wrap(WhRepay, args(tAddress, tUint256), dest, amount)
}
