// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-02b — non-vacuous sizing test for the reserve-gated redemption funding leg (onFundingTick). Against a
// simulated backend with mocked eth_call replies (the P8 selector list), it decodes the CAPTURED report bytes
// (P9 — the §8.0 envelope abi.encode(uint8 opType, bytes payload), then the per-op tuple) and asserts the op +
// the sized scalars for the six "Done when" cases — NOT just the write count. The CRE-04 http-path tests
// (workflow_test.go) are unchanged and still pass; this handler is purely additive.
package main

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	evmmock "github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/mock"
	"github.com/smartcontractkit/cre-sdk-go/cre/testutils"

	zipreport "cre-zipreport"
)

// The simulated wiring slots. The adapter (== cfg.Warehouse, the report receiver) returns the other four
// addresses off its getters; queue == redemptionBox (seam #6).
var (
	fAdapter = warehouseAddr // reuse the CRE-04 test's receiver address as the adapter
	fSafe    = common.HexToAddress("0x00000000000000000000000000000000000000D1")
	fEEPool  = common.HexToAddress("0x00000000000000000000000000000000000000E1")
	fUsdc    = common.HexToAddress("0x00000000000000000000000000000000000000F1")
	fQueue   = common.HexToAddress("0x0000000000000000000000000000000000000A11")
	fGate    = common.HexToAddress("0x0000000000000000000000000000000000000B22")
)

// fundingState scripts the view layer for one simulated tick (all 6-dp USDC unless noted).
type fundingState struct {
	covered      bool
	totalPending *big.Int // 18-dp zipUSD
	scaleUp      *big.Int
	reserved     *big.Int // 6-dp USDC reservedAssets on queue
	usdcBalQueue *big.Int // 6-dp USDC balanceOf(queue)
	safeUsdc     *big.Int // 6-dp USDC balanceOf(safe)
	maxWithdraw  *big.Int // 6-dp USDC maxWithdraw(safe) = free reservoir
	totalShares  *big.Int // 18-dp EE shares balanceOf(safe)
	navAssets    *big.Int // 6-dp USDC convertToAssets(totalShares)
}

func fundingConfig() *Config {
	cfg := testConfig() // CRE-04 base: ChainSelector + Warehouse(=adapter) + WriteGasLimit
	cfg.FundingEnabled = true
	cfg.FundingSchedule = "0 */5 * * * *"
	cfg.CoverageGate = fGate.Hex()
	cfg.HarvestReserve = "100000000"   // 100 USDC (6-dp)
	cfg.SafetyBuffer = "50000000"      // 50 USDC
	cfg.MaxRedeemPerTick = "0"         // uncapped by this knob unless a case overrides
	return cfg
}

func encAddr(a common.Address) []byte {
	addrT, _ := abi.NewType("address", "", nil)
	out, _ := abi.Arguments{{Type: addrT}}.Pack(a)
	return out
}

func encU(v *big.Int) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(v)
	return out
}

func encB(b bool) []byte {
	bt, _ := abi.NewType("bool", "", nil)
	out, _ := abi.Arguments{{Type: bt}}.Pack(b)
	return out
}

// runFunding wires the P8 mock selector list for a state, runs onFundingTick, and returns the captured WriteReport
// envelopes.
func runFunding(t *testing.T, cfg *Config, st fundingState) [][]byte {
	t.Helper()
	runtime := testutils.NewRuntime(t, testutils.Secrets{})

	evmMock, err := evmmock.NewClientCapability(testChainSelector, t)
	if err != nil {
		t.Fatalf("NewClientCapability: %v", err)
	}

	sel := func(sig string) string { return string(selectorF(sig)) }

	var captured [][]byte
	writeCap := func(payload []byte, _ *evm.GasConfig) (*evm.WriteReportReply, error) {
		cp := make([]byte, len(payload))
		copy(cp, payload)
		captured = append(captured, cp)
		return &evm.WriteReportReply{}, nil
	}

	// Warehouse adapter: the four address getters + the WriteReport receiver.
	evmmock.AddContractMock(fAdapter, evmMock, map[string]func([]byte) ([]byte, error){
		sel("warehouseSafe()"): func([]byte) ([]byte, error) { return encAddr(fSafe), nil },
		sel("eePool()"):        func([]byte) ([]byte, error) { return encAddr(fEEPool), nil },
		sel("usdc()"):          func([]byte) ([]byte, error) { return encAddr(fUsdc), nil },
		sel("redemptionBox()"): func([]byte) ([]byte, error) { return encAddr(fQueue), nil },
	}, writeCap)

	// eePool: maxWithdraw(safe), convertToAssets(totalShares), balanceOf(safe). convertToShares NOT mocked.
	evmmock.AddContractMock(fEEPool, evmMock, map[string]func([]byte) ([]byte, error){
		sel("maxWithdraw(address)"):     func([]byte) ([]byte, error) { return encU(st.maxWithdraw), nil },
		sel("convertToAssets(uint256)"): func([]byte) ([]byte, error) { return encU(st.navAssets), nil },
		sel("balanceOf(address)"):       func([]byte) ([]byte, error) { return encU(st.totalShares), nil },
	}, nil)

	// usdc: balanceOf(queue) and balanceOf(safe) hit the SAME selector with different args ⇒ dispatch on the arg.
	evmmock.AddContractMock(fUsdc, evmMock, map[string]func([]byte) ([]byte, error){
		sel("balanceOf(address)"): func(in []byte) ([]byte, error) {
			arg := common.BytesToAddress(in[len(in)-20:])
			if arg == fQueue {
				return encU(st.usdcBalQueue), nil
			}
			return encU(st.safeUsdc), nil
		},
	}, nil)

	// queue: totalPending / scaleUp / reservedAssets.
	evmmock.AddContractMock(fQueue, evmMock, map[string]func([]byte) ([]byte, error){
		sel("totalPending()"):   func([]byte) ([]byte, error) { return encU(st.totalPending), nil },
		sel("scaleUp()"):        func([]byte) ([]byte, error) { return encU(st.scaleUp), nil },
		sel("reservedAssets()"): func([]byte) ([]byte, error) { return encU(st.reserved), nil },
	}, nil)

	// coverageGate: covered().
	evmmock.AddContractMock(fGate, evmMock, map[string]func([]byte) ([]byte, error){
		sel("covered()"): func([]byte) ([]byte, error) { return encB(st.covered), nil },
	}, nil)

	if _, err := onFundingTick(cfg, runtime, nil); err != nil {
		t.Fatalf("onFundingTick: %v", err)
	}
	return captured
}

// decodeRepay unpacks a captured envelope as REPAY (opType 4 → (address dest, uint256 amount)).
func decodeRepay(t *testing.T, env []byte) (common.Address, *big.Int) {
	t.Helper()
	op, payload := decodeEnvelope(t, env)
	if op != zipreport.WhRepay {
		t.Fatalf("expected REPAY opType constant %d, got %d", zipreport.WhRepay, op)
	}
	if op != 4 {
		t.Fatalf("expected REPAY opType literal 4, got %d", op)
	}
	dec, err := abi.Arguments{{Type: mustType(t, "address")}, {Type: mustType(t, "uint256")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode repay payload: %v", err)
	}
	return dec[0].(common.Address), dec[1].(*big.Int)
}

// decodeRedeem unpacks a captured envelope as REDEEM (opType 3 → (uint256 shares)).
func decodeRedeem(t *testing.T, env []byte) *big.Int {
	t.Helper()
	op, payload := decodeEnvelope(t, env)
	if op != zipreport.WhRedeem {
		t.Fatalf("expected REDEEM opType constant %d, got %d", zipreport.WhRedeem, op)
	}
	if op != 3 {
		t.Fatalf("expected REDEEM opType literal 3, got %d", op)
	}
	dec, err := abi.Arguments{{Type: mustType(t, "uint256")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode redeem payload: %v", err)
	}
	return dec[0].(*big.Int)
}

// scaleUp1e12 is the pinned scaleUp (P7): 1e12 = 10^(18−6).
func scaleUp1e12() *big.Int {
	v, _ := new(big.Int).SetString("1000000000000", 10)
	return v
}

// pending18 builds an 18-dp totalPending whose par capacity (pending/scaleUp) equals usdc6 (6-dp USDC).
func pending18(usdc6 int64) *big.Int {
	return new(big.Int).Mul(big.NewInt(usdc6), scaleUp1e12())
}

// ─────────────────────────────────────────────────────────── (1) disabled ⇒ zero reports

func TestFundingDisabledNoReports(t *testing.T) {
	cfg := fundingConfig()
	cfg.FundingEnabled = false
	// A state that WOULD produce writes if enabled — proves the gate, not the inputs.
	st := fundingState{
		covered: true, totalPending: pending18(1_000_000_000), scaleUp: scaleUp1e12(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(0), safeUsdc: big.NewInt(500_000_000),
		maxWithdraw: big.NewInt(2_000_000_000), totalShares: big.NewInt(1_000), navAssets: big.NewInt(1_000_000_000),
	}
	out := runFunding(t, cfg, st)
	if len(out) != 0 {
		t.Fatalf("disabled: expected 0 reports, got %d", len(out))
	}
}

// ─────────────────────────────────────────────────────────── (2) !covered ⇒ no REDEEM (REPAY may still fire)

func TestFundingNotCoveredNoRedeem(t *testing.T) {
	// shortfall = 600 − 0 = 600 USDC; safeUsdc = 200 ⇒ REPAY 200. Reservoir ample but !covered ⇒ floor 0 ⇒ no REDEEM.
	st := fundingState{
		covered:      false,
		totalPending: pending18(600_000_000), scaleUp: scaleUp1e12(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(0),
		safeUsdc:    big.NewInt(200_000_000),
		maxWithdraw: big.NewInt(2_000_000_000),
		totalShares: big.NewInt(1_000_000_000_000_000_000), navAssets: big.NewInt(1_000_000_000),
	}
	out := runFunding(t, fundingConfig(), st)
	if len(out) != 1 {
		t.Fatalf("!covered: expected 1 report (REPAY only), got %d", len(out))
	}
	dest, amt := decodeRepay(t, out[0])
	if dest != fQueue {
		t.Fatalf("REPAY dest: got %s want queue %s", dest.Hex(), fQueue.Hex())
	}
	if amt.Cmp(big.NewInt(200_000_000)) != 0 {
		t.Fatalf("REPAY amount: got %s want 200000000", amt)
	}
}

// starved reservoir (avail ≤ 0) ⇒ floor 0 ⇒ no REDEEM even when covered.
func TestFundingStarvedReservoirNoRedeem(t *testing.T) {
	// maxWithdraw 120 − 100 harvest − 50 safety = −30 ⇒ clamp 0 ⇒ floor 0. shortfall 600, safe 200 ⇒ REPAY 200 only.
	st := fundingState{
		covered:      true,
		totalPending: pending18(600_000_000), scaleUp: scaleUp1e12(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(0),
		safeUsdc:    big.NewInt(200_000_000),
		maxWithdraw: big.NewInt(120_000_000),
		totalShares: big.NewInt(1_000_000_000_000_000_000), navAssets: big.NewInt(1_000_000_000),
	}
	out := runFunding(t, fundingConfig(), st)
	if len(out) != 1 {
		t.Fatalf("starved: expected 1 report (REPAY only), got %d", len(out))
	}
	if _, amt := decodeRepay(t, out[0]); amt.Cmp(big.NewInt(200_000_000)) != 0 {
		t.Fatalf("REPAY amount: got %s want 200000000", amt)
	}
}

// ─────────────────────────────────────────────────────────── (3) shortfall ≤ safeUsdc ⇒ REPAY only

func TestFundingShortfallCoveredBySafe(t *testing.T) {
	// shortfall = 300 − 0 = 300; safeUsdc = 500 ≥ 300 ⇒ REPAY 300, remaining 0 ⇒ no REDEEM (even though covered+ample).
	st := fundingState{
		covered:      true,
		totalPending: pending18(300_000_000), scaleUp: scaleUp1e12(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(0),
		safeUsdc:    big.NewInt(500_000_000),
		maxWithdraw: big.NewInt(2_000_000_000),
		totalShares: big.NewInt(1_000_000_000_000_000_000), navAssets: big.NewInt(1_000_000_000),
	}
	out := runFunding(t, fundingConfig(), st)
	if len(out) != 1 {
		t.Fatalf("safe-covered: expected 1 report (REPAY only), got %d", len(out))
	}
	if _, amt := decodeRepay(t, out[0]); amt.Cmp(big.NewInt(300_000_000)) != 0 {
		t.Fatalf("REPAY amount: got %s want 300000000", amt)
	}
}

// ─────────────────────────────────────────────────────────── (4) shortfall > safeUsdc, covered, ample ⇒ REPAY+REDEEM

func TestFundingRepayThenRedeem(t *testing.T) {
	// shortfall = 1000 − 0 = 1000 USDC; safeUsdc = 200 ⇒ REPAY 200; remaining 800.
	// avail = maxWithdraw 5000 − 100 − 50 = 4850 ⇒ floor 4850; redeemAssets = min(800, 4850) = 800 USDC.
	// NAV: totalShares = 2e18, navAssets = 2000 USDC ⇒ rate 1 share : 1e-6 USDC... redeemShares = 800·2e18/2e9.
	totalShares := new(big.Int).Mul(big.NewInt(2), big.NewInt(1_000_000_000_000_000_000)) // 2e18
	navAssets := big.NewInt(2_000_000_000)                                                  // 2000 USDC (6-dp)
	st := fundingState{
		covered:      true,
		totalPending: pending18(1_000_000_000), scaleUp: scaleUp1e12(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(0),
		safeUsdc:    big.NewInt(200_000_000),
		maxWithdraw: big.NewInt(5_000_000_000),
		totalShares: totalShares, navAssets: navAssets,
	}
	out := runFunding(t, fundingConfig(), st)
	if len(out) != 2 {
		t.Fatalf("expected 2 reports (REPAY then REDEEM), got %d", len(out))
	}
	// Leg order: REPAY first.
	dest, repayAmt := decodeRepay(t, out[0])
	if dest != fQueue || repayAmt.Cmp(big.NewInt(200_000_000)) != 0 {
		t.Fatalf("REPAY: got dest=%s amt=%s want queue/200000000", dest.Hex(), repayAmt)
	}
	// REDEEM second, shares = convertToAssets-ratio sizing for redeemAssets=800 USDC.
	redeemAssets := big.NewInt(800_000_000)
	wantShares := new(big.Int).Div(new(big.Int).Mul(redeemAssets, totalShares), navAssets)
	gotShares := decodeRedeem(t, out[1])
	if gotShares.Cmp(wantShares) != 0 {
		t.Fatalf("REDEEM shares: got %s want %s", gotShares, wantShares)
	}
}

// ─────────────────────────────────────────────────────────── (5) maxRedeemPerTick clamps the REDEEM

func TestFundingMaxRedeemPerTickClamps(t *testing.T) {
	cfg := fundingConfig()
	cfg.MaxRedeemPerTick = "100000000" // 100 USDC cap
	// Same as case 4 (remaining 800, avail 4850) but the cap clamps redeemAssets to 100 USDC.
	totalShares := new(big.Int).Mul(big.NewInt(2), big.NewInt(1_000_000_000_000_000_000))
	navAssets := big.NewInt(2_000_000_000)
	st := fundingState{
		covered:      true,
		totalPending: pending18(1_000_000_000), scaleUp: scaleUp1e12(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(0),
		safeUsdc:    big.NewInt(200_000_000),
		maxWithdraw: big.NewInt(5_000_000_000),
		totalShares: totalShares, navAssets: navAssets,
	}
	out := runFunding(t, cfg, st)
	if len(out) != 2 {
		t.Fatalf("expected 2 reports (REPAY then clamped REDEEM), got %d", len(out))
	}
	if _, amt := decodeRepay(t, out[0]); amt.Cmp(big.NewInt(200_000_000)) != 0 {
		t.Fatalf("REPAY amount: got %s want 200000000", amt)
	}
	redeemAssets := big.NewInt(100_000_000) // clamped to the cap, not 800
	wantShares := new(big.Int).Div(new(big.Int).Mul(redeemAssets, totalShares), navAssets)
	if gotShares := decodeRedeem(t, out[1]); gotShares.Cmp(wantShares) != 0 {
		t.Fatalf("clamped REDEEM shares: got %s want %s", gotShares, wantShares)
	}
}

// ─────────────────────────────────────────────────────────── (6) shortfall == 0 ⇒ no-op

func TestFundingNoShortfallNoOp(t *testing.T) {
	// par capacity = 300; freeUsdc = usdcBalQueue 400 − reserved 0 = 400 ≥ 300 ⇒ shortfall ≤ 0 ⇒ no-op.
	st := fundingState{
		covered:      true,
		totalPending: pending18(300_000_000), scaleUp: scaleUp1e12(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(400_000_000),
		safeUsdc:    big.NewInt(500_000_000),
		maxWithdraw: big.NewInt(2_000_000_000),
		totalShares: big.NewInt(1_000_000_000_000_000_000), navAssets: big.NewInt(1_000_000_000),
	}
	out := runFunding(t, fundingConfig(), st)
	if len(out) != 0 {
		t.Fatalf("no shortfall: expected 0 reports, got %d", len(out))
	}
}

// scaleUp == 0 ⇒ no-op (malformed/unwired queue guard).
func TestFundingScaleUpZeroNoOp(t *testing.T) {
	st := fundingState{
		covered:      true,
		totalPending: pending18(300_000_000), scaleUp: big.NewInt(0),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(0),
		safeUsdc:    big.NewInt(500_000_000),
		maxWithdraw: big.NewInt(2_000_000_000),
		totalShares: big.NewInt(1_000_000_000_000_000_000), navAssets: big.NewInt(1_000_000_000),
	}
	out := runFunding(t, fundingConfig(), st)
	if len(out) != 0 {
		t.Fatalf("scaleUp 0: expected 0 reports, got %d", len(out))
	}
}
