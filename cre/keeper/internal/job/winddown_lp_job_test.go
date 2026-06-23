package job

import (
	"context"
	"errors"
	"math/big"
	"testing"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// ---- fixed addresses ----
var (
	wdLp    = common.HexToAddress("0x0000000000000000000000000000000000000B01")
	wdSafe  = common.HexToAddress("0x0000000000000000000000000000000000005AFE")
	wdVault = common.HexToAddress("0x000000000000000000000000000000000000E333")
	wdGate  = common.HexToAddress("0x000000000000000000000000000000000000C0FE")
)

// ---- scripted chain.Reader ----

// wdReader models the exact reads WindDownLpJob.Evaluate makes off LpStrategyModule:
// juniorTrancheEngine(), ichiVault(), coverageGate(), stakedBalance(), and the gate's
// lpBurnKeepsCovered(uint256). `covered` decides the gate predicate (nil ⇒ gate is
// zero/ungated). `err` short-circuits every call.
type wdReader struct {
	safe    common.Address
	vault   common.Address
	gate    common.Address     // zero ⇒ ungated
	staked  *big.Int           // stakedBalance()
	covered func(s *big.Int) bool // lpBurnKeepsCovered(s); nil when gate is zero
	err     error
}

func wdEncUint(v *big.Int) []byte {
	u, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u}}.Pack(v)
	return out
}
func wdEncAddr(a common.Address) []byte {
	t, _ := abi.NewType("address", "", nil)
	out, _ := abi.Arguments{{Type: t}}.Pack(a)
	return out
}
func wdEncBool(b bool) []byte {
	t, _ := abi.NewType("bool", "", nil)
	out, _ := abi.Arguments{{Type: t}}.Pack(b)
	return out
}

func (s *wdReader) CallContract(ctx context.Context, call ethereum.CallMsg, _ *big.Int) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	var sg [4]byte
	copy(sg[:], call.Data[:4])
	switch sg {
	case sel("juniorTrancheEngine()"):
		return wdEncAddr(s.safe), nil
	case sel("ichiVault()"):
		return wdEncAddr(s.vault), nil
	case sel("coverageGate()"):
		return wdEncAddr(s.gate), nil
	case sel("stakedBalance()"):
		return wdEncUint(s.staked), nil
	case sel("lpBurnKeepsCovered(uint256)"):
		// decode the single uint256 arg.
		u, _ := abi.NewType("uint256", "", nil)
		vals, err := abi.Arguments{{Type: u}}.Unpack(call.Data[4:])
		if err != nil {
			return nil, err
		}
		return wdEncBool(s.covered(vals[0].(*big.Int))), nil
	}
	return nil, errors.New("wdReader: unexpected selector")
}

// ---- fake Quoter for the wind-down (only the two LP methods are exercised) ----

type wdQuoter struct {
	dev  *big.Int // LpSpotTwapDeviationBps
	e0   *big.Int // LpWithdrawExpected amt0 (scaled by shares below)
	e1   *big.Int // LpWithdrawExpected amt1
	// when perShare is true, e0/e1 are per-1-share and LpWithdrawExpected multiplies
	// by shares; otherwise they are returned verbatim.
	perShare bool
	err      error
}

func (q *wdQuoter) HydxToUsdc(ctx context.Context, amountIn *big.Int) (*big.Int, error) {
	return big.NewInt(0), nil
}
func (q *wdQuoter) HydxPriceUsdc(ctx context.Context) (*big.Int, error) { return big.NewInt(0), nil }
func (q *wdQuoter) ZipToShares(ctx context.Context, recycle, vault common.Address, depositZip *big.Int) (*big.Int, bool, error) {
	return big.NewInt(0), false, nil
}
func (q *wdQuoter) LpWithdrawExpected(ctx context.Context, vault common.Address, shares *big.Int) (*big.Int, *big.Int, error) {
	if q.err != nil {
		return nil, nil, q.err
	}
	if q.perShare {
		return new(big.Int).Mul(q.e0, shares), new(big.Int).Mul(q.e1, shares), nil
	}
	return new(big.Int).Set(q.e0), new(big.Int).Set(q.e1), nil
}
func (q *wdQuoter) LpSpotTwapDeviationBps(ctx context.Context, vault common.Address) (*big.Int, error) {
	if q.err != nil {
		return nil, q.err
	}
	return q.dev, nil
}

// ---- helpers ----

const wdCushion = 200 // 2%
const wdMaxDev = 100  // 1%

// floor2pct returns v - v*200/10000 (the applyCushionFloor result for cushionBps=200).
func floor2pct(v *big.Int) *big.Int {
	cut := new(big.Int).Mul(v, big.NewInt(wdCushion))
	cut.Div(cut, big.NewInt(10000))
	return new(big.Int).Sub(v, cut)
}

func newWDJob(q *wdQuoter, maxSlice *big.Int) *WindDownLpJob {
	return NewWindDownLpJob(wdLp, q, wdCushion, wdMaxDev, maxSlice)
}

func wdBaseReader() *wdReader {
	return &wdReader{
		safe:    wdSafe,
		vault:   wdVault,
		gate:    common.Address{}, // ungated by default
		staked:  bigStr("100000000000000000000"), // 100e18 staked
		covered: nil,
	}
}

// ============================ nothing staked → empty ============================

func TestWindDown_NothingStaked_Empty(t *testing.T) {
	r := wdBaseReader()
	r.staked = big.NewInt(0)
	q := &wdQuoter{dev: big.NewInt(0), e0: big.NewInt(1), e1: big.NewInt(1)}
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan, got %v", labels(plan))
	}
}

// ============================ unwired → empty ============================

func TestWindDown_Unwired_Empty(t *testing.T) {
	r := wdBaseReader()
	r.safe = common.Address{}
	q := &wdQuoter{dev: big.NewInt(0), e0: big.NewInt(1), e1: big.NewInt(1)}
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan (unwired), got %v", labels(plan))
	}
}

// ============================ gate binary search picks smaller s ============================

// TestWindDown_GateBinarySearch: full slice (100e18) is undercovered, but the gate
// blesses any s ≤ 40e18. The binary search must pick exactly 40e18.
func TestWindDown_GateBinarySearch(t *testing.T) {
	threshold := bigStr("40000000000000000000") // 40e18
	r := wdBaseReader()
	r.gate = wdGate
	r.covered = func(s *big.Int) bool { return s.Cmp(threshold) <= 0 }
	// e0/e1 per-share = 2 and 3 → expected scale with the chosen shares.
	q := &wdQuoter{dev: big.NewInt(0), e0: big.NewInt(2), e1: big.NewInt(3), perShare: true}

	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	want := []string{"unstake", "removeLiquidity"}
	if !eqLabels(labels(plan), want) {
		t.Fatalf("labels = %v, want %v", labels(plan), want)
	}
	// shares must equal the threshold (largest covered s).
	a, _ := actionByLabel(plan, "unstake")
	if got := decodeUint256Args(t, a.Data, 1)[0]; got.Cmp(threshold) != 0 {
		t.Fatalf("unstake shares = %s, want %s (largest covered)", got, threshold)
	}
	// removeLiquidity(shares, min0, min1): min_i = floor2pct(e_i*shares).
	a, _ = actionByLabel(plan, "removeLiquidity")
	got := decodeUint256Args(t, a.Data, 3)
	if got[0].Cmp(threshold) != 0 {
		t.Errorf("removeLiquidity shares = %s, want %s", got[0], threshold)
	}
	wantMin0 := floor2pct(new(big.Int).Mul(big.NewInt(2), threshold))
	wantMin1 := floor2pct(new(big.Int).Mul(big.NewInt(3), threshold))
	if got[1].Cmp(wantMin0) != 0 || got[2].Cmp(wantMin1) != 0 {
		t.Errorf("min = [%s %s], want [%s %s]", got[1], got[2], wantMin0, wantMin1)
	}
}

// ============================ gate covers nothing → empty ============================

// TestWindDown_GateCoversNothing_Empty: lpBurnKeepsCovered is false for every s ≥ 1
// (including s=1) ⇒ no excess to dissolve ⇒ empty plan.
func TestWindDown_GateCoversNothing_Empty(t *testing.T) {
	r := wdBaseReader()
	r.gate = wdGate
	r.covered = func(s *big.Int) bool { return false }
	q := &wdQuoter{dev: big.NewInt(0), e0: big.NewInt(1), e1: big.NewInt(1)}
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan (nothing covered), got %v", labels(plan))
	}
}

// ============================ deviation over ceiling → empty ============================

func TestWindDown_DeviationOverCeiling_Empty(t *testing.T) {
	r := wdBaseReader()
	q := &wdQuoter{dev: big.NewInt(101), e0: big.NewInt(1000), e1: big.NewInt(1000)} // 101 > 100 ceiling
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan (pool too volatile), got %v", labels(plan))
	}
}

// TestWindDown_DeviationAtCeiling_OK: dev == ceiling is allowed (strict > skips).
func TestWindDown_DeviationAtCeiling_OK(t *testing.T) {
	r := wdBaseReader()
	q := &wdQuoter{dev: big.NewInt(100), e0: big.NewInt(1000), e1: big.NewInt(1000)} // == 100 ceiling
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	want := []string{"unstake", "removeLiquidity"}
	if !eqLabels(labels(plan), want) {
		t.Fatalf("labels = %v, want %v (dev==ceiling is allowed)", labels(plan), want)
	}
}

// ============================ both floors round to 0 → empty ============================

func TestWindDown_BothFloorsZero_Empty(t *testing.T) {
	r := wdBaseReader()
	// expected = 0 both sides ⇒ floors are 0 ⇒ ZeroMinAmount guard skips.
	q := &wdQuoter{dev: big.NewInt(0), e0: big.NewInt(0), e1: big.NewInt(0)}
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan (both floors 0), got %v", labels(plan))
	}
}

// ============================ happy path (ungated): exact plan + Private ============================

// TestWindDown_HappyPath_Ungated: gate==zero ⇒ shares = full staked; verify the two
// ordered Private actions with the right selectors/args and min_i == e_i*(1-cushion).
func TestWindDown_HappyPath_Ungated(t *testing.T) {
	r := wdBaseReader() // gate zero, staked 100e18
	e0 := bigStr("500000000000000000000")  // 500e18
	e1 := bigStr("1200000000")             // 1200e6
	q := &wdQuoter{dev: big.NewInt(10), e0: e0, e1: e1}

	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	want := []string{"unstake", "removeLiquidity"}
	if !eqLabels(labels(plan), want) {
		t.Fatalf("labels = %v, want %v", labels(plan), want)
	}
	shares := bigStr("100000000000000000000") // full staked

	// unstake(shares), Private, To == lp, selector unstake(uint256).
	a := plan.Actions[0]
	if a.To != wdLp {
		t.Errorf("unstake To = %s, want lp %s", a.To.Hex(), wdLp.Hex())
	}
	if !a.Private {
		t.Errorf("unstake must be Private")
	}
	wantUnstakeSel := sel("unstake(uint256)")
	var gotSel [4]byte
	copy(gotSel[:], a.Data[:4])
	if gotSel != wantUnstakeSel {
		t.Errorf("unstake selector = %x, want %x", gotSel, wantUnstakeSel)
	}
	if got := decodeUint256Args(t, a.Data, 1)[0]; got.Cmp(shares) != 0 {
		t.Errorf("unstake shares = %s, want %s", got, shares)
	}

	// removeLiquidity(shares, min0, min1), Private, selector matches.
	a = plan.Actions[1]
	if a.To != wdLp {
		t.Errorf("removeLiquidity To = %s, want lp", a.To.Hex())
	}
	if !a.Private {
		t.Errorf("removeLiquidity must be Private")
	}
	wantRmSel := sel("removeLiquidity(uint256,uint256,uint256)")
	copy(gotSel[:], a.Data[:4])
	if gotSel != wantRmSel {
		t.Errorf("removeLiquidity selector = %x, want %x", gotSel, wantRmSel)
	}
	got := decodeUint256Args(t, a.Data, 3)
	wantMin0 := floor2pct(e0)
	wantMin1 := floor2pct(e1)
	if got[0].Cmp(shares) != 0 {
		t.Errorf("removeLiquidity shares = %s, want %s", got[0], shares)
	}
	if got[1].Cmp(wantMin0) != 0 {
		t.Errorf("min0 = %s, want %s (e0*(1-2%%))", got[1], wantMin0)
	}
	if got[2].Cmp(wantMin1) != 0 {
		t.Errorf("min1 = %s, want %s (e1*(1-2%%))", got[2], wantMin1)
	}
}

// ============================ maxSlice cap clamps shares ============================

// TestWindDown_MaxSliceCap: staked 100e18 but maxSlice 30e18 ⇒ shares clamp to 30e18.
func TestWindDown_MaxSliceCap(t *testing.T) {
	r := wdBaseReader() // ungated, staked 100e18
	cap := bigStr("30000000000000000000")
	q := &wdQuoter{dev: big.NewInt(0), e0: big.NewInt(1), e1: big.NewInt(1), perShare: true}
	plan, err := newWDJob(q, cap).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	a, _ := actionByLabel(plan, "unstake")
	if got := decodeUint256Args(t, a.Data, 1)[0]; got.Cmp(cap) != 0 {
		t.Fatalf("unstake shares = %s, want %s (maxSlice cap)", got, cap)
	}
}

// ============================ gate full slice covered → no search ============================

// TestWindDown_GateFullCovered: the gate blesses the full slice ⇒ shares = staked.
func TestWindDown_GateFullCovered(t *testing.T) {
	r := wdBaseReader()
	r.gate = wdGate
	r.covered = func(s *big.Int) bool { return true } // everything covered
	q := &wdQuoter{dev: big.NewInt(0), e0: big.NewInt(1), e1: big.NewInt(1), perShare: true}
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	a, _ := actionByLabel(plan, "unstake")
	if got := decodeUint256Args(t, a.Data, 1)[0]; got.Cmp(r.staked) != 0 {
		t.Fatalf("unstake shares = %s, want full staked %s", got, r.staked)
	}
}

// ============================ deviation quote error aborts ============================

// TestWindDown_QuoterError_Propagates: an unready-TWAP/NoPlugin Quoter error aborts
// the Job (never falls back to spot).
func TestWindDown_QuoterError_Propagates(t *testing.T) {
	r := wdBaseReader()
	q := &wdQuoter{err: errors.New("PluginNotReady")}
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err == nil {
		t.Fatal("expected propagated quoter error")
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan on error, got %v", labels(plan))
	}
}

// ============================ reader error propagates ============================

func TestWindDown_ReaderError_Propagates(t *testing.T) {
	r := wdBaseReader()
	r.err = errors.New("rpc down")
	q := &wdQuoter{dev: big.NewInt(0), e0: big.NewInt(1), e1: big.NewInt(1)}
	plan, err := newWDJob(q, nil).Evaluate(context.Background(), r)
	if err == nil {
		t.Fatal("expected propagated read error")
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan on error, got %v", labels(plan))
	}
}
