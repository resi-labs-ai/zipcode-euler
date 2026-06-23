package job

import (
	"context"
	"errors"
	"math/big"
	"testing"
	"time"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
)

// ---- fixed addresses for the engine modules + tokens ----
var (
	slHarvest   = common.HexToAddress("0x0000000000000000000000000000000000000A01")
	slFarmUtility = common.HexToAddress("0x0000000000000000000000000000000000000A02")
	slExercise  = common.HexToAddress("0x0000000000000000000000000000000000000A03")
	slSell      = common.HexToAddress("0x0000000000000000000000000000000000000A04")
	slRecycle   = common.HexToAddress("0x0000000000000000000000000000000000000A05")
	slLp        = common.HexToAddress("0x0000000000000000000000000000000000000A06")

	slSafe  = common.HexToAddress("0x0000000000000000000000000000000000005AFE")
	slOHydx = common.HexToAddress("0x000000000000000000000000000000000000d111")
	slHydx  = common.HexToAddress("0x000000000000000000000000000000000000d222")
	slVault = common.HexToAddress("0x000000000000000000000000000000000000d333")
)

// ---- scripted chain.Reader ----

// slReader returns canned values keyed by (to, selector). It models the exact set
// of reads StrikeLoopJob.Evaluate makes.
type slReader struct {
	safe     common.Address
	oHydx    common.Address
	hydx     common.Address
	vault    common.Address
	oHydxBal *big.Int // oHYDX.balanceOf(safe)
	hydxBal  *big.Int // hydx.balanceOf(safe)
	pending  *big.Int // harvest.pendingReward()
	maxSell  *big.Int // sell.maxSellHydx()
	strike   *big.Int // exercise.quoteStrike(_)
	err      error
}

func slEncUint(v *big.Int) []byte {
	u, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u}}.Pack(v)
	return out
}

func slEncAddr(a common.Address) []byte {
	t, _ := abi.NewType("address", "", nil)
	out, _ := abi.Arguments{{Type: t}}.Pack(a)
	return out
}

func (s *slReader) CallContract(ctx context.Context, call ethereum.CallMsg, _ *big.Int) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	var sg [4]byte
	copy(sg[:], call.Data[:4])
	to := *call.To
	switch sg {
	case sel("juniorTrancheEngine()"):
		return slEncAddr(s.safe), nil
	case sel("oHYDX()"):
		return slEncAddr(s.oHydx), nil
	case sel("hydx()"):
		return slEncAddr(s.hydx), nil
	case sel("ichiVault()"):
		return slEncAddr(s.vault), nil
	case sel("pendingReward()"):
		return slEncUint(s.pending), nil
	case sel("maxSellHydx()"):
		return slEncUint(s.maxSell), nil
	case sel("quoteStrike(uint256)"):
		return slEncUint(s.strike), nil
	case sel("balanceOf(address)"):
		if to == s.oHydx {
			return slEncUint(s.oHydxBal), nil
		}
		if to == s.hydx {
			return slEncUint(s.hydxBal), nil
		}
		return nil, errors.New("slReader: balanceOf on unexpected token")
	}
	return nil, errors.New("slReader: unexpected selector")
}

// ---- fake Quoter ----

type fakeQuoter struct {
	priceUsdc   *big.Int // HydxPriceUsdc
	usdcPerHydx *big.Int // HydxToUsdc returns amountIn * usdcPerHydx / 1e18
	shares      *big.Int // ZipToShares returns this verbatim
	zipIsToken0 bool     // ZipToShares returns this verbatim (deposit-side flag)
	err         error
}

var qE18 = func() *big.Int { v, _ := new(big.Int).SetString("1000000000000000000", 10); return v }()

func (f *fakeQuoter) HydxToUsdc(ctx context.Context, amountIn *big.Int) (*big.Int, error) {
	if f.err != nil {
		return nil, f.err
	}
	out := new(big.Int).Mul(amountIn, f.usdcPerHydx)
	return out.Div(out, qE18), nil
}
func (f *fakeQuoter) HydxPriceUsdc(ctx context.Context) (*big.Int, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.priceUsdc, nil
}
func (f *fakeQuoter) ZipToShares(ctx context.Context, recycle, vault common.Address, depositZip *big.Int) (*big.Int, bool, error) {
	if f.err != nil {
		return nil, false, f.err
	}
	return f.shares, f.zipIsToken0, nil
}

// LpWithdrawExpected / LpSpotTwapDeviationBps: scripted stubs so fakeQuoter keeps
// satisfying the (extended) quote.Quoter interface. The StrikeLoopJob never calls
// these; the WindDownLpJob tests use their own fake.
func (f *fakeQuoter) LpWithdrawExpected(ctx context.Context, vault common.Address, shares *big.Int) (*big.Int, *big.Int, error) {
	if f.err != nil {
		return nil, nil, f.err
	}
	return big.NewInt(0), big.NewInt(0), nil
}
func (f *fakeQuoter) LpSpotTwapDeviationBps(ctx context.Context, vault common.Address) (*big.Int, error) {
	if f.err != nil {
		return nil, f.err
	}
	return big.NewInt(0), nil
}

// ---- helpers ----

// fixedClock returns a deterministic clock for the deadline.
func fixedClock(unix int64) func() time.Time {
	return func() time.Time { return time.Unix(unix, 0) }
}

func newSLJob(q *fakeQuoter) *StrikeLoopJob {
	j := NewStrikeLoopJob(StrikeLoopConfig{
		Harvest:            slHarvest,
		FarmUtility:          slFarmUtility,
		Exercise:           slExercise,
		Sell:               slSell,
		Recycle:            slRecycle,
		Lp:                 slLp,
		Quoter:             q,
		CushionBps:         200,
		AmberFractionBps:   5000,
		RecycleFractionBps: 10000,
		HaltPriceUsdc:      15000,
		AmberPriceUsdc:     18000,
		DeadlineBuffer:     300 * time.Second,
		MaxBorrowPerCycle:  bigStr("1000000000000"), // 1e12 (1,000,000 USDC) — generous
	})
	j.clock = fixedClock(1_000_000)
	return j
}

func bigStr(s string) *big.Int { v, _ := new(big.Int).SetString(s, 10); return v }

func baseReader() *slReader {
	return &slReader{
		safe:     slSafe,
		oHydx:    slOHydx,
		hydx:     slHydx,
		vault:    slVault,
		oHydxBal: big.NewInt(0),
		hydxBal:  big.NewInt(0),
		pending:  bigStr("100000000000000000000"), // 100 oHYDX (1e20)
		maxSell:  bigStr("300000000000000000000"), // 300 HYDX cap
		strike:   bigStr("500000"),                // 0.5 USDC strike (6dp)
	}
}

func labels(p chain.Plan) []string {
	out := make([]string, len(p.Actions))
	for i, a := range p.Actions {
		out[i] = a.Label
	}
	return out
}

func eqLabels(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// decodeUint256Args strips the 4-byte selector and decodes N uint256 args.
func decodeUint256Args(t *testing.T, data []byte, n int) []*big.Int {
	t.Helper()
	u, _ := abi.NewType("uint256", "", nil)
	args := make(abi.Arguments, n)
	for i := range args {
		args[i] = abi.Argument{Type: u}
	}
	vals, err := args.Unpack(data[4:])
	if err != nil {
		t.Fatalf("decode args: %v", err)
	}
	out := make([]*big.Int, n)
	for i := range out {
		out[i] = vals[i].(*big.Int)
	}
	return out
}

func actionByLabel(p chain.Plan, label string) (chain.Action, bool) {
	for _, a := range p.Actions {
		if a.Label == label {
			return a, true
		}
	}
	return chain.Action{}, false
}

// ============================ happy path (9 legs) ============================

// TestStrikeLoop_HappyPath_NineLegs: full green-band cycle. P=$0.02 ≥ amber ⇒ full
// taper. pending=100 oHYDX, hydxBal=0 ⇒ exerciseAmount=100, sellAmount=100.
// price $1/HYDX ⇒ quotedOut huge ⇒ profitable. Asserts the 9 ordered legs +
// decoded scalar args.
func TestStrikeLoop_HappyPath_NineLegs(t *testing.T) {
	q := &fakeQuoter{
		priceUsdc:   big.NewInt(20000),              // $0.02 (≥ amber 18000) → full
		usdcPerHydx: bigStr("1000000"),              // $1.00 per HYDX (6dp)
		shares:      bigStr("50000000000000000000"), // 50e18 ICHI shares
		zipIsToken0: true,                           // token0-side restake
	}
	r := baseReader()
	j := newSLJob(q)

	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	want := []string{"claimReward", "borrow", "exercise", "sellHydx", "repay", "creditFreeValue", "recycle", "addLiquidity", "stake"}
	if !eqLabels(labels(plan), want) {
		t.Fatalf("labels = %v, want %v", labels(plan), want)
	}

	// exerciseAmount = min(100e18 full, maxSell-hydxBal=300e18) = 100e18.
	exAmt := bigStr("100000000000000000000")
	// strike = 500000; maxPayment = strike + 2% = 510000; borrowAmount = 510000.
	maxPayment := big.NewInt(510000)
	// sellAmount = hydxBal(0) + exerciseAmount = 100e18.
	sellAmt := bigStr("100000000000000000000")
	// quotedOut = HydxToUsdc(100e18 @ $1) = 100e18*1e6/1e18 = 100000000 (100 USDC, 6dp).
	// minOut = quotedOut - 2% = 100000000 - 2000000 = 98000000.
	minOut := big.NewInt(98000000)
	// conservativeNet = minOut - maxPayment = 98000000 - 510000 = 97490000.
	// recycleAmount = net * 100% = 97490000. creditAmount = 97490000.
	recycleAmt := big.NewInt(97490000)
	creditAmt := big.NewInt(97490000)
	// expectedZip = recycleAmount * 1e12 = 97490000e12.
	expectedZip := new(big.Int).Mul(recycleAmt, bigStr("1000000000000"))
	// expectedShares = 50e18; minShares = 50e18 - 2% = 49e18. stakeAmount = minShares.
	minShares := bigStr("49000000000000000000")
	deadline := big.NewInt(1_000_000 + 300)

	// borrow(borrowAmount)
	a, _ := actionByLabel(plan, "borrow")
	if got := decodeUint256Args(t, a.Data, 1); got[0].Cmp(maxPayment) != 0 {
		t.Errorf("borrow arg = %s, want %s", got[0], maxPayment)
	}
	if a.To != slFarmUtility {
		t.Errorf("borrow To = %s, want farmUtility", a.To.Hex())
	}
	// exercise(exerciseAmount, maxPayment, deadline)
	a, _ = actionByLabel(plan, "exercise")
	got := decodeUint256Args(t, a.Data, 3)
	if got[0].Cmp(exAmt) != 0 || got[1].Cmp(maxPayment) != 0 || got[2].Cmp(deadline) != 0 {
		t.Errorf("exercise args = %v, want [%s %s %s]", got, exAmt, maxPayment, deadline)
	}
	// sellHydx(sellAmount, minOut, deadline)
	a, _ = actionByLabel(plan, "sellHydx")
	got = decodeUint256Args(t, a.Data, 3)
	if got[0].Cmp(sellAmt) != 0 || got[1].Cmp(minOut) != 0 || got[2].Cmp(deadline) != 0 {
		t.Errorf("sellHydx args = %v, want [%s %s %s]", got, sellAmt, minOut, deadline)
	}
	// repay(borrowAmount)
	a, _ = actionByLabel(plan, "repay")
	if got := decodeUint256Args(t, a.Data, 1); got[0].Cmp(maxPayment) != 0 {
		t.Errorf("repay arg = %s, want %s", got[0], maxPayment)
	}
	// creditFreeValue(creditAmount)
	a, _ = actionByLabel(plan, "creditFreeValue")
	if got := decodeUint256Args(t, a.Data, 1); got[0].Cmp(creditAmt) != 0 {
		t.Errorf("creditFreeValue arg = %s, want %s", got[0], creditAmt)
	}
	// recycle(recycleAmount)
	a, _ = actionByLabel(plan, "recycle")
	if got := decodeUint256Args(t, a.Data, 1); got[0].Cmp(recycleAmt) != 0 {
		t.Errorf("recycle arg = %s, want %s", got[0], recycleAmt)
	}
	// addLiquidity(expectedZip, 0, minShares)
	a, _ = actionByLabel(plan, "addLiquidity")
	got = decodeUint256Args(t, a.Data, 3)
	if got[0].Cmp(expectedZip) != 0 || got[1].Sign() != 0 || got[2].Cmp(minShares) != 0 {
		t.Errorf("addLiquidity args = %v, want [%s 0 %s]", got, expectedZip, minShares)
	}
	// stake(minShares)
	a, _ = actionByLabel(plan, "stake")
	if got := decodeUint256Args(t, a.Data, 1); got[0].Cmp(minShares) != 0 {
		t.Errorf("stake arg = %s, want %s", got[0], minShares)
	}
}

// ============================ token1-side restake (9 legs) ============================

// TestStrikeLoop_HappyPath_Token1Side: identical to the happy path EXCEPT the
// quoter reports zipIsToken0=false (zipUSD is the vault's token1). The plan must
// build addLiquidity(0, expectedZip, minShares) — deposit on the token1 side —
// and stake(minShares); same 9 ordered labels, all other scalars unchanged.
func TestStrikeLoop_HappyPath_Token1Side(t *testing.T) {
	q := &fakeQuoter{
		priceUsdc:   big.NewInt(20000),
		usdcPerHydx: bigStr("1000000"),
		shares:      bigStr("50000000000000000000"),
		zipIsToken0: false, // token1-side restake
	}
	r := baseReader()
	j := newSLJob(q)

	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	want := []string{"claimReward", "borrow", "exercise", "sellHydx", "repay", "creditFreeValue", "recycle", "addLiquidity", "stake"}
	if !eqLabels(labels(plan), want) {
		t.Fatalf("labels = %v, want %v", labels(plan), want)
	}

	// Same scalars as the token0 happy path.
	recycleAmt := big.NewInt(97490000)
	expectedZip := new(big.Int).Mul(recycleAmt, bigStr("1000000000000"))
	minShares := bigStr("49000000000000000000")

	// addLiquidity(0, expectedZip, minShares) — recycled zipUSD on the token1 side.
	a, _ := actionByLabel(plan, "addLiquidity")
	got := decodeUint256Args(t, a.Data, 3)
	if got[0].Sign() != 0 || got[1].Cmp(expectedZip) != 0 || got[2].Cmp(minShares) != 0 {
		t.Errorf("addLiquidity args = %v, want [0 %s %s] (token1 side)", got, expectedZip, minShares)
	}
	// stake(minShares) unchanged.
	a, _ = actionByLabel(plan, "stake")
	if got := decodeUint256Args(t, a.Data, 1); got[0].Cmp(minShares) != 0 {
		t.Errorf("stake arg = %s, want %s", got[0], minShares)
	}
}

// ============================ recycle-skipped (6 legs) ============================

// TestStrikeLoop_RecycleSkipped_SixLegs: a profit so thin that recycleAmount
// floors to 0 ⇒ the recycle+addLiquidity+stake legs are skipped together; the
// first 6 legs still run.
func TestStrikeLoop_RecycleSkipped_SixLegs(t *testing.T) {
	// Make conservativeNet small enough that net*100%... actually recycleFraction is
	// 100%, so recycleAmount==0 only when conservativeNet==0. Use a quote where
	// minOut == maxPayment+0... we need net>0 for the profit gate to pass but
	// recycleAmount==0. With recycleFractionBps=10000, recycleAmount = net, so the
	// only way recycleAmount==0 with net>0 is impossible. Instead exercise the
	// branch with a fractional recycle that floors to 0: net=1, fraction=10000 →
	// recycle=1 (not 0). So use recycleFractionBps small. Override via a custom job.
	q := &fakeQuoter{
		priceUsdc:   big.NewInt(20000),
		usdcPerHydx: bigStr("1000000"),
		shares:      bigStr("50000000000000000000"),
	}
	r := baseReader()
	j := newSLJob(q)
	j.recycleFractionBps = 0 // forces recycleAmount = net*0/10000 = 0

	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	want := []string{"claimReward", "borrow", "exercise", "sellHydx", "repay", "creditFreeValue"}
	if !eqLabels(labels(plan), want) {
		t.Fatalf("labels = %v, want %v (recycle skipped)", labels(plan), want)
	}
	// creditFreeValue still gets the FULL net.
	a, _ := actionByLabel(plan, "creditFreeValue")
	if got := decodeUint256Args(t, a.Data, 1); got[0].Sign() == 0 {
		t.Errorf("creditFreeValue should still credit the full net, got 0")
	}
}

// ============================ no-op gates → empty plan ============================

func TestStrikeLoop_NoOp_ZeroTotalOHydx(t *testing.T) {
	q := &fakeQuoter{priceUsdc: big.NewInt(20000), usdcPerHydx: bigStr("1000000"), shares: big.NewInt(1)}
	r := baseReader()
	r.pending = big.NewInt(0)
	r.oHydxBal = big.NewInt(0)
	assertEmpty(t, newSLJob(q), r)
}

func TestStrikeLoop_NoOp_PriceBelowHalt(t *testing.T) {
	q := &fakeQuoter{priceUsdc: big.NewInt(14999), usdcPerHydx: bigStr("1000000"), shares: big.NewInt(1)} // < 15000 halt
	assertEmpty(t, newSLJob(q), baseReader())
}

func TestStrikeLoop_NoOp_ExerciseAmountZero(t *testing.T) {
	// hydxBal already == maxSell ⇒ sellRoom 0 ⇒ exerciseAmount 0.
	q := &fakeQuoter{priceUsdc: big.NewInt(20000), usdcPerHydx: bigStr("1000000"), shares: big.NewInt(1)}
	r := baseReader()
	r.hydxBal = bigStr("300000000000000000000") // == maxSell
	assertEmpty(t, newSLJob(q), r)
}

func TestStrikeLoop_NoOp_MaxPaymentOverCap(t *testing.T) {
	q := &fakeQuoter{priceUsdc: big.NewInt(20000), usdcPerHydx: bigStr("1000000"), shares: big.NewInt(1)}
	r := baseReader()
	r.strike = bigStr("2000000000000") // strike > maxBorrowPerCycle (1e12) → maxPayment over cap
	assertEmpty(t, newSLJob(q), r)
}

func TestStrikeLoop_NoOp_ProfitGate(t *testing.T) {
	// minOut ≤ maxPayment ⇒ unprofitable. Tiny HYDX price.
	q := &fakeQuoter{priceUsdc: big.NewInt(20000), usdcPerHydx: big.NewInt(1), shares: big.NewInt(1)} // ~0 USDC out
	assertEmpty(t, newSLJob(q), baseReader())
}

func assertEmpty(t *testing.T, j *StrikeLoopJob, r *slReader) {
	t.Helper()
	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan, got %d actions: %v", len(plan.Actions), labels(plan))
	}
}

// ============================ maxSell cap ============================

// TestStrikeLoop_MaxSellCap: tapered would be 300e18 but maxSell-hydxBal caps
// exerciseAmount to 200e18, and sellAmount = hydxBal + exerciseAmount = 300e18
// (== maxSell, the on-chain ExceedsMaxSell boundary, which is allowed: > reverts).
func TestStrikeLoop_MaxSellCap(t *testing.T) {
	q := &fakeQuoter{priceUsdc: big.NewInt(20000), usdcPerHydx: bigStr("1000000"), shares: bigStr("50000000000000000000")}
	r := baseReader()
	r.pending = bigStr("400000000000000000000") // 400 oHYDX (full taper would be 400)
	r.hydxBal = bigStr("100000000000000000000") // 100 HYDX already in Safe
	r.maxSell = bigStr("300000000000000000000") // cap 300
	j := newSLJob(q)

	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	// sellRoom = 300 - 100 = 200. exerciseAmount = min(400, 200) = 200e18.
	exAmt := bigStr("200000000000000000000")
	// sellAmount = hydxBal(100) + exerciseAmount(200) = 300e18 == maxSell.
	sellAmt := bigStr("300000000000000000000")
	a, _ := actionByLabel(plan, "exercise")
	if got := decodeUint256Args(t, a.Data, 3); got[0].Cmp(exAmt) != 0 {
		t.Errorf("exercise amount = %s, want %s (capped)", got[0], exAmt)
	}
	a, _ = actionByLabel(plan, "sellHydx")
	if got := decodeUint256Args(t, a.Data, 3); got[0].Cmp(sellAmt) != 0 {
		t.Errorf("sellHydx amount = %s, want %s (== maxSell boundary)", got[0], sellAmt)
	}
	if got := decodeUint256Args(t, a.Data, 3)[0]; got.Cmp(r.maxSell) > 0 {
		t.Errorf("sellAmount %s exceeds maxSell %s (would revert ExceedsMaxSell)", got, r.maxSell)
	}
}

// ============================ amber taper ============================

// TestStrikeLoop_AmberTaper: P in [halt, amber) ⇒ tapered = totalOHydx*50%.
func TestStrikeLoop_AmberTaper(t *testing.T) {
	q := &fakeQuoter{priceUsdc: big.NewInt(16000), usdcPerHydx: bigStr("1000000"), shares: bigStr("50000000000000000000")} // 15000 ≤ 16000 < 18000
	r := baseReader()
	r.pending = bigStr("100000000000000000000") // 100 oHYDX
	j := newSLJob(q)

	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	// tapered = 100 * 50% = 50e18; exerciseAmount = min(50, 300) = 50e18.
	exAmt := bigStr("50000000000000000000")
	a, _ := actionByLabel(plan, "exercise")
	if got := decodeUint256Args(t, a.Data, 3); got[0].Cmp(exAmt) != 0 {
		t.Errorf("amber exercise amount = %s, want %s (50%% taper)", got[0], exAmt)
	}
}

// ============================ boundary: P == amberPrice → full tier ============================

// TestStrikeLoop_AmberBoundary_IsFullTier: STRICT < means P == amberPrice is the
// HIGHER (full) tier, not amber.
func TestStrikeLoop_AmberBoundary_IsFullTier(t *testing.T) {
	q := &fakeQuoter{priceUsdc: big.NewInt(18000), usdcPerHydx: bigStr("1000000"), shares: bigStr("50000000000000000000")} // == amber
	r := baseReader()
	r.pending = bigStr("100000000000000000000")
	j := newSLJob(q)
	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	exAmt := bigStr("100000000000000000000") // full, not 50%
	a, _ := actionByLabel(plan, "exercise")
	if got := decodeUint256Args(t, a.Data, 3); got[0].Cmp(exAmt) != 0 {
		t.Errorf("P==amber exercise amount = %s, want full %s (strict < → higher tier)", got[0], exAmt)
	}
}

// ============================ read-error propagates ============================

func TestStrikeLoop_ReaderError_Propagates(t *testing.T) {
	q := &fakeQuoter{priceUsdc: big.NewInt(20000), usdcPerHydx: bigStr("1000000"), shares: big.NewInt(1)}
	r := baseReader()
	r.err = errors.New("rpc down")
	plan, err := newSLJob(q).Evaluate(context.Background(), r)
	if err == nil {
		t.Fatal("expected propagated read error")
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan on error, got %d", len(plan.Actions))
	}
}

// ============================ minShares==0 → recycle without restake ============================

// TestStrikeLoop_MinSharesZero_RecycleNoRestake: ZipToShares returns a value that
// floors to 0 after cushion ⇒ recycle runs but addLiquidity/stake are skipped.
func TestStrikeLoop_MinSharesZero_RecycleNoRestake(t *testing.T) {
	q := &fakeQuoter{priceUsdc: big.NewInt(20000), usdcPerHydx: bigStr("1000000"), shares: big.NewInt(10)} // 10 - 2% floors to 9? check
	// shares=10 → cushion 2% = 0 (10*200/10000 = 0) → minShares = 10. Need shares so
	// that floor → 0: shares such that shares - shares*200/10000 == 0 needs shares==0,
	// impossible. Instead set shares=0 directly (ZipToShares degenerate empty pool).
	q.shares = big.NewInt(0)
	r := baseReader()
	plan, err := newSLJob(q).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	want := []string{"claimReward", "borrow", "exercise", "sellHydx", "repay", "creditFreeValue", "recycle"}
	if !eqLabels(labels(plan), want) {
		t.Fatalf("labels = %v, want %v (recycle, no restake)", labels(plan), want)
	}
}
