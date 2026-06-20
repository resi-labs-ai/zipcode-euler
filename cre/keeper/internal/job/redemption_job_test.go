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

// ---- stub Reader for RedemptionJob (anvil-free, the primary binding proof) ----

// redemptionStubReader returns canned ABI values. Address getters are keyed by
// selector (juniorTrancheSafe()/queue()/zipUSD()/usdc() → addrs); scalar views by
// selector (scaleUp()/totalPending()/reservedAssets() → uints; maxWithdraw(address)
// → claimable). The two balanceOf(address) reads are keyed by call.To: the Job
// reads balanceOf on usdcAddr (→ usdcBalQueue) and on zipUSD (→ idleZip), which
// are distinct addresses the stub itself returns from usdc()/zipUSD(); a single
// shared bal cannot satisfy groups 1/4/6. Reuses sel/encodeAddr (job_test.go) and
// encodeUint (burn_job_test.go) — same package.
type redemptionStubReader struct {
	rqSafe   common.Address
	queue    common.Address
	zipUSD   common.Address
	usdcAddr common.Address

	scaleUp   *big.Int
	pending   *big.Int
	reserved  *big.Int
	claimable *big.Int

	usdcBalQueue *big.Int // balanceOf on usdcAddr
	idleZip      *big.Int // balanceOf on zipUSD

	err error
}

func (s redemptionStubReader) CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	if len(call.Data) < 4 {
		return nil, errors.New("stub: short calldata")
	}
	var got [4]byte
	copy(got[:], call.Data[:4])
	switch got {
	case sel("juniorTrancheSafe()"):
		return encodeAddr(s.rqSafe), nil
	case sel("queue()"):
		return encodeAddr(s.queue), nil
	case sel("zipUSD()"):
		return encodeAddr(s.zipUSD), nil
	case sel("usdc()"):
		return encodeAddr(s.usdcAddr), nil
	case sel("scaleUp()"):
		return encodeUint(s.scaleUp), nil
	case sel("totalPending()"):
		return encodeUint(s.pending), nil
	case sel("reservedAssets()"):
		return encodeUint(s.reserved), nil
	case sel("maxWithdraw(address)"):
		return encodeUint(s.claimable), nil
	case sel("balanceOf(address)"):
		// Key by call.To: usdcAddr → usdcBalQueue, zipUSD → idleZip.
		if call.To != nil && *call.To == s.usdcAddr {
			return encodeUint(s.usdcBalQueue), nil
		}
		if call.To != nil && *call.To == s.zipUSD {
			return encodeUint(s.idleZip), nil
		}
		return nil, errors.New("stub: balanceOf on unexpected address")
	default:
		return nil, errors.New("stub: unexpected selector")
	}
}

var (
	redOfframp = common.HexToAddress("0x0FFf000000000000000000000000000000000001")
	redQueue   = common.HexToAddress("0x9111000000000000000000000000000000000002")
	redRqSafe  = common.HexToAddress("0x5afe000000000000000000000000000000000003")
	redZipUSD  = common.HexToAddress("0x21f0000000000000000000000000000000000004")
	redUsdc    = common.HexToAddress("0x05dc000000000000000000000000000000000005")
)

// decodeUintArg decodes calldata of the form selector ++ abi.encode(uint256) and
// returns the decoded scalar. The selector is NOT trusted from PackUintCall — the
// caller asserts it separately via the [4]byte prefix.
func decodeUintArg(t *testing.T, data []byte) *big.Int {
	t.Helper()
	if len(data) < 4 {
		t.Fatalf("calldata too short: %x", data)
	}
	u256, _ := abi.NewType("uint256", "", nil)
	vals, err := abi.Arguments{{Type: u256}}.Unpack(data[4:])
	if err != nil {
		t.Fatalf("decode uint arg: %v", err)
	}
	return vals[0].(*big.Int)
}

func selPrefix(data []byte) [4]byte {
	var s [4]byte
	copy(s[:], data[:4])
	return s
}

// baseReader is a fully-wired reader with all addresses set; the per-test scalars
// are filled in by each group.
func redBaseReader() redemptionStubReader {
	return redemptionStubReader{
		rqSafe: redRqSafe, queue: redQueue, zipUSD: redZipUSD, usdcAddr: redUsdc,
		scaleUp: big.NewInt(0), pending: big.NewInt(0), reserved: big.NewInt(0),
		claimable: big.NewInt(0), usdcBalQueue: big.NewInt(0), idleZip: big.NewInt(0),
	}
}

// Group 1: all three legs, ordered.
func TestRedemptionJob_AllThreeLegs_Ordered(t *testing.T) {
	scaleUp := bigStr("1000000000000")          // 1e12
	r := redBaseReader()
	r.scaleUp = scaleUp
	r.pending = bigStr("3000000000000")          // 3e12 ⇒ pending >= scaleUp
	r.usdcBalQueue = bigStr("1000000000000000000") // 1e18 ⇒ freeUsdc > 0
	r.claimable = big.NewInt(5)
	r.idleZip = bigStr("100000000000000000000") // large
	target := bigStr("10000000000000") // 10e12
	j := NewRedemptionJob(redOfframp, target)

	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 3 {
		t.Fatalf("expected 3 actions, got %d", len(plan.Actions))
	}

	// settleEpoch → queue, no args.
	if plan.Actions[0].To != redQueue {
		t.Errorf("action[0].To = %s, want queue %s", plan.Actions[0].To.Hex(), redQueue.Hex())
	}
	if selPrefix(plan.Actions[0].Data) != sel("settleEpoch()") {
		t.Errorf("action[0] selector = %x, want settleEpoch() %x", selPrefix(plan.Actions[0].Data), sel("settleEpoch()"))
	}
	if len(plan.Actions[0].Data) != 4 {
		t.Errorf("settleEpoch() must be selector-only (4 bytes), got %d", len(plan.Actions[0].Data))
	}

	// claim → offramp, arg == claimable.
	if plan.Actions[1].To != redOfframp {
		t.Errorf("action[1].To = %s, want offramp %s", plan.Actions[1].To.Hex(), redOfframp.Hex())
	}
	if selPrefix(plan.Actions[1].Data) != sel("claim(uint256)") {
		t.Errorf("action[1] selector = %x, want claim(uint256)", selPrefix(plan.Actions[1].Data))
	}
	if got := decodeUintArg(t, plan.Actions[1].Data); got.Cmp(big.NewInt(5)) != 0 {
		t.Errorf("claim arg = %s, want 5", got)
	}

	// requestRedeem → offramp, arg == floorToUnit(min(gap,idle),scaleUp).
	gap := new(big.Int).Sub(target, r.pending) // 7e12
	wantEscrow := floorToUnit(gap, scaleUp)     // min(gap,idle)=gap; floored = 7e12
	if plan.Actions[2].To != redOfframp {
		t.Errorf("action[2].To = %s, want offramp %s", plan.Actions[2].To.Hex(), redOfframp.Hex())
	}
	if selPrefix(plan.Actions[2].Data) != sel("requestRedeem(uint256)") {
		t.Errorf("action[2] selector = %x, want requestRedeem(uint256)", selPrefix(plan.Actions[2].Data))
	}
	if got := decodeUintArg(t, plan.Actions[2].Data); got.Cmp(wantEscrow) != 0 {
		t.Errorf("escrow arg = %s, want %s", got, wantEscrow)
	}
}

// Group 2: settle-only.
func TestRedemptionJob_SettleOnly(t *testing.T) {
	r := redBaseReader()
	r.scaleUp = bigStr("1000000000000")
	r.pending = bigStr("3000000000000")
	r.usdcBalQueue = bigStr("1000000000000000000")
	r.claimable = big.NewInt(0)
	j := NewRedemptionJob(redOfframp, big.NewInt(0)) // target 0

	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("expected 1 action, got %d", len(plan.Actions))
	}
	if plan.Actions[0].To != redQueue || selPrefix(plan.Actions[0].Data) != sel("settleEpoch()") {
		t.Errorf("expected lone settleEpoch→queue, got To=%s sel=%x", plan.Actions[0].To.Hex(), selPrefix(plan.Actions[0].Data))
	}
}

// Group 3: claim-only (freeUsdc==0 because usdcBalQueue==0).
func TestRedemptionJob_ClaimOnly(t *testing.T) {
	r := redBaseReader()
	r.scaleUp = bigStr("1000000000000")
	r.pending = bigStr("3000000000000")
	r.usdcBalQueue = big.NewInt(0) // freeUsdc == 0 ⇒ no settle
	r.claimable = big.NewInt(42)
	j := NewRedemptionJob(redOfframp, big.NewInt(0)) // target 0

	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("expected 1 action, got %d", len(plan.Actions))
	}
	if plan.Actions[0].To != redOfframp || selPrefix(plan.Actions[0].Data) != sel("claim(uint256)") {
		t.Fatalf("expected lone claim→offramp")
	}
	if got := decodeUintArg(t, plan.Actions[0].Data); got.Cmp(big.NewInt(42)) != 0 {
		t.Errorf("claim arg = %s, want 42", got)
	}
}

// Group 4: escrow gating. Keep settle/claim off (usdcBalQueue=0, claimable=0,
// pending<scaleUp) so any emitted action is the escrow leg only.
func TestRedemptionJob_EscrowGating(t *testing.T) {
	scaleUp := bigStr("1000000000000") // 1e12

	// (a) gap>0 && idle>=scaleUp ⇒ requestRedeem(floored).
	t.Run("enabled_emits_floored", func(t *testing.T) {
		r := redBaseReader()
		r.scaleUp = scaleUp
		r.pending = big.NewInt(0)
		r.idleZip = bigStr("5000000000000") // 5e12
		target := bigStr("3000000000000")   // 3e12 ⇒ gap=3e12
		plan, err := NewRedemptionJob(redOfframp, target).Evaluate(context.Background(), r)
		if err != nil {
			t.Fatalf("err: %v", err)
		}
		if len(plan.Actions) != 1 || selPrefix(plan.Actions[0].Data) != sel("requestRedeem(uint256)") {
			t.Fatalf("expected lone requestRedeem, got %d actions", len(plan.Actions))
		}
		want := floorToUnit(bigStr("3000000000000"), scaleUp) // min(3e12,5e12)=3e12
		if got := decodeUintArg(t, plan.Actions[0].Data); got.Cmp(want) != 0 {
			t.Errorf("escrow = %s, want %s", got, want)
		}
	})

	// (b) idle<scaleUp ⇒ no escrow leg.
	t.Run("idle_sub_unit_no_leg", func(t *testing.T) {
		r := redBaseReader()
		r.scaleUp = scaleUp
		r.pending = big.NewInt(0)
		r.idleZip = big.NewInt(500000000000) // 0.5e12 < scaleUp
		target := bigStr("3000000000000")
		plan, err := NewRedemptionJob(redOfframp, target).Evaluate(context.Background(), r)
		if err != nil {
			t.Fatalf("err: %v", err)
		}
		if len(plan.Actions) != 0 {
			t.Fatalf("expected no escrow leg, got %d actions", len(plan.Actions))
		}
	})

	// (c) pending>=target (gap<=0) ⇒ no escrow leg.
	t.Run("no_gap_no_leg", func(t *testing.T) {
		r := redBaseReader()
		r.scaleUp = scaleUp
		r.pending = bigStr("5000000000000") // >= target
		r.idleZip = bigStr("100000000000000")
		target := bigStr("3000000000000")
		plan, err := NewRedemptionJob(redOfframp, target).Evaluate(context.Background(), r)
		if err != nil {
			t.Fatalf("err: %v", err)
		}
		if len(plan.Actions) != 0 {
			t.Fatalf("expected no escrow leg (no gap), got %d actions", len(plan.Actions))
		}
	})

	// (d) target==0 ⇒ never an escrow leg.
	t.Run("target_zero_no_leg", func(t *testing.T) {
		r := redBaseReader()
		r.scaleUp = scaleUp
		r.pending = big.NewInt(0)
		r.idleZip = bigStr("100000000000000")
		plan, err := NewRedemptionJob(redOfframp, big.NewInt(0)).Evaluate(context.Background(), r)
		if err != nil {
			t.Fatalf("err: %v", err)
		}
		if len(plan.Actions) != 0 {
			t.Fatalf("expected no escrow leg (target 0), got %d actions", len(plan.Actions))
		}
	})
}

// Group 5: no-op / fail-safe.
func TestRedemptionJob_NoOpAndFailSafe(t *testing.T) {
	// queue()==0x0 ⇒ empty plan, nil err.
	t.Run("unwired_queue", func(t *testing.T) {
		r := redBaseReader()
		r.queue = common.Address{}
		plan, err := NewRedemptionJob(redOfframp, big.NewInt(0)).Evaluate(context.Background(), r)
		if err != nil {
			t.Fatalf("expected nil err, got %v", err)
		}
		if len(plan.Actions) != 0 {
			t.Fatalf("expected empty plan, got %d", len(plan.Actions))
		}
	})

	// rqSafe()==0x0 ⇒ empty plan, nil err.
	t.Run("unwired_rqSafe", func(t *testing.T) {
		r := redBaseReader()
		r.rqSafe = common.Address{}
		plan, err := NewRedemptionJob(redOfframp, big.NewInt(0)).Evaluate(context.Background(), r)
		if err != nil {
			t.Fatalf("expected nil err, got %v", err)
		}
		if len(plan.Actions) != 0 {
			t.Fatalf("expected empty plan, got %d", len(plan.Actions))
		}
	})

	// scaleUp()==0 ⇒ empty plan, nil err.
	t.Run("zero_scaleUp", func(t *testing.T) {
		r := redBaseReader()
		r.scaleUp = big.NewInt(0)
		r.usdcBalQueue = bigStr("1000000000000000000")
		r.pending = bigStr("3000000000000")
		plan, err := NewRedemptionJob(redOfframp, big.NewInt(0)).Evaluate(context.Background(), r)
		if err != nil {
			t.Fatalf("expected nil err, got %v", err)
		}
		if len(plan.Actions) != 0 {
			t.Fatalf("expected empty plan, got %d", len(plan.Actions))
		}
	})

	// Reader error ⇒ (empty plan, err).
	t.Run("reader_error", func(t *testing.T) {
		r := redemptionStubReader{err: errors.New("rpc down")}
		plan, err := NewRedemptionJob(redOfframp, big.NewInt(0)).Evaluate(context.Background(), r)
		if err == nil {
			t.Fatal("expected a propagated read error")
		}
		if len(plan.Actions) != 0 {
			t.Fatalf("expected empty plan on error, got %d", len(plan.Actions))
		}
	})
}

// Group 6: escrow floor — min(gap,idle) not a whole multiple of scaleUp ⇒ floored.
// scaleUp=1e12, idle=2.5e12, gap large ⇒ escrow == 2e12.
func TestRedemptionJob_EscrowFloored(t *testing.T) {
	scaleUp := bigStr("1000000000000") // 1e12
	r := redBaseReader()
	r.scaleUp = scaleUp
	r.pending = big.NewInt(0)
	r.idleZip = bigStr("2500000000000") // 2.5e12
	target := bigStr("100000000000000") // large ⇒ gap large
	plan, err := NewRedemptionJob(redOfframp, target).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(plan.Actions) != 1 || selPrefix(plan.Actions[0].Data) != sel("requestRedeem(uint256)") {
		t.Fatalf("expected lone requestRedeem, got %d actions", len(plan.Actions))
	}
	want := bigStr("2000000000000") // 2e12
	if got := decodeUintArg(t, plan.Actions[0].Data); got.Cmp(want) != 0 {
		t.Errorf("escrow = %s, want 2e12 (floored)", got)
	}
}
