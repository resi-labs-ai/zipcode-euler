package job

import (
	"bytes"
	"context"
	"errors"
	"math/big"
	"testing"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// ---- stub Reader for BurnJob (anvil-free, the primary proof) ----

// burnStubReader returns canned ABI-encoded values keyed by the 4-byte selector
// in the call data: shareToken()->shareTok, engineSafe()->engine,
// balanceOf(address)->bal, currentBid()->(uid, sell), settlement()->settle,
// filledAmount(bytes)->filled. An optional err short-circuits every call (the
// RPC-failure branch). Reuses sel/encodeAddr from job_test.go (same package).
type burnStubReader struct {
	shareTok common.Address
	engine   common.Address
	settle   common.Address
	bal      *big.Int
	uid      []byte   // currentBid() uid (nil = no live bid)
	filled   *big.Int // filledAmount(bytes) for ANY uid queried
	err      error
}

func encodeUint(v *big.Int) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(v)
	return out
}

func encodeBytesUint(b []byte, v *big.Int) []byte {
	bytesT, _ := abi.NewType("bytes", "", nil)
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: bytesT}, {Type: u256}}.Pack(b, v)
	return out
}

func (s burnStubReader) CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	if len(call.Data) < 4 {
		return nil, errors.New("stub: short calldata")
	}
	var got [4]byte
	copy(got[:], call.Data[:4])
	switch got {
	case sel("shareToken()"):
		return encodeAddr(s.shareTok), nil
	case sel("engineSafe()"):
		return encodeAddr(s.engine), nil
	case sel("balanceOf(address)"):
		return encodeUint(s.bal), nil
	case sel("currentBid()"):
		return encodeBytesUint(s.uid, big.NewInt(0)), nil
	case sel("settlement()"):
		return encodeAddr(s.settle), nil
	case sel("filledAmount(bytes)"):
		f := s.filled
		if f == nil {
			f = big.NewInt(0)
		}
		return encodeUint(f), nil
	default:
		return nil, errors.New("stub: unexpected selector")
	}
}

var (
	burnGate   = common.HexToAddress("0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e")
	burnModule = common.HexToAddress("0x0000000000000000000000000000000000000B14")
	burnSettle = common.HexToAddress("0x9008D19f58AAbD9eD0D60971565AA8510560ab41")
	burnShare  = common.HexToAddress("0x33aD3E23aE000000000000000000000000000001")
	burnEngine = common.HexToAddress("0x000000000000000000000000000000000000E516")
	burnUid    = bytes.Repeat([]byte{0xAB}, 56) // a 56-byte GPv2 uid stand-in
)

// TestBurnJob_FillEvidence_ExactCalldata is the load-bearing binding: a live uid
// with filledAmount 40 > latch 0 and balance 100 ⇒ a one-Action plan to exitGate
// with Data byte-equal to 0x6f5d0f0b ++ <uint256 100> (the FULL balance, not the
// fill size — dust rides along).
func TestBurnJob_FillEvidence_ExactCalldata(t *testing.T) {
	r := burnStubReader{
		shareTok: burnShare, engine: burnEngine, settle: burnSettle,
		bal: big.NewInt(100), uid: burnUid, filled: big.NewInt(40),
	}
	j := NewBurnJob(burnGate, burnModule)
	plan, err := j.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("expected 1 action, got %d", len(plan.Actions))
	}
	a := plan.Actions[0]
	if a.To != burnGate {
		t.Errorf("To = %s, want exitGate %s", a.To.Hex(), burnGate.Hex())
	}
	// 0x6f5d0f0b ++ abi.encode(uint256 100): the verified burnFor(uint256) selector.
	want := append([]byte{0x6f, 0x5d, 0x0f, 0x0b}, encodeUint(big.NewInt(100))...)
	if !bytes.Equal(a.Data, want) {
		t.Errorf("Data = %x, want %x", a.Data, want)
	}
}

// TestBurnJob_DonationWithoutFill_Sits: balance present but the tracked bid has
// ZERO fills ⇒ no burn — a donor can never schedule a burn ("let the dusters
// dust"). The balance is already NAV-excluded, so sitting is harmless.
func TestBurnJob_DonationWithoutFill_Sits(t *testing.T) {
	r := burnStubReader{
		shareTok: burnShare, engine: burnEngine, settle: burnSettle,
		bal: big.NewInt(5), uid: burnUid, filled: big.NewInt(0),
	}
	plan, err := NewBurnJob(burnGate, burnModule).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan (no fill evidence), got %d actions", len(plan.Actions))
	}
}

// TestBurnJob_NoUidEverSeen_Sits: balance present but NO live bid and no
// remembered uid (fresh keeper) ⇒ no fill evidence possible ⇒ sit until the next
// round's fill sweeps it.
func TestBurnJob_NoUidEverSeen_Sits(t *testing.T) {
	r := burnStubReader{
		shareTok: burnShare, engine: burnEngine, settle: burnSettle,
		bal: big.NewInt(100), uid: nil, filled: big.NewInt(40),
	}
	plan, err := NewBurnJob(burnGate, burnModule).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan (no uid), got %d actions", len(plan.Actions))
	}
}

// TestBurnJob_LatchOnEmpty_ThenDonationSits is the stateful heart: (tick 1)
// balance 0 with filled 40 ⇒ LATCH, no-op; (tick 2) a donation lands (balance 7,
// filled still 40 == latch) ⇒ sits. The latch means "this fill was already acted
// on (or there was nothing to act on)".
func TestBurnJob_LatchOnEmpty_ThenDonationSits(t *testing.T) {
	j := NewBurnJob(burnGate, burnModule)

	tick1 := burnStubReader{
		shareTok: burnShare, engine: burnEngine, settle: burnSettle,
		bal: big.NewInt(0), uid: burnUid, filled: big.NewInt(40),
	}
	plan, err := j.Evaluate(context.Background(), tick1)
	if err != nil || len(plan.Actions) != 0 {
		t.Fatalf("tick1: want empty plan/nil err, got %d actions, %v", len(plan.Actions), err)
	}

	tick2 := burnStubReader{
		shareTok: burnShare, engine: burnEngine, settle: burnSettle,
		bal: big.NewInt(7), uid: burnUid, filled: big.NewInt(40),
	}
	plan, err = j.Evaluate(context.Background(), tick2)
	if err != nil {
		t.Fatalf("tick2: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("tick2: donation after latch must sit, got %d actions", len(plan.Actions))
	}
}

// TestBurnJob_FailedSubmit_Retries: emitting a plan does NOT latch — if the burn
// tx failed (balance still present next tick, filled unchanged and > latch), the
// plan re-emits until the balance is observed empty.
func TestBurnJob_FailedSubmit_Retries(t *testing.T) {
	j := NewBurnJob(burnGate, burnModule)
	r := burnStubReader{
		shareTok: burnShare, engine: burnEngine, settle: burnSettle,
		bal: big.NewInt(100), uid: burnUid, filled: big.NewInt(40),
	}
	for tick := 1; tick <= 2; tick++ {
		plan, err := j.Evaluate(context.Background(), r)
		if err != nil {
			t.Fatalf("tick%d: %v", tick, err)
		}
		if len(plan.Actions) != 1 {
			t.Fatalf("tick%d: want the burn plan re-emitted, got %d actions", tick, len(plan.Actions))
		}
	}
}

// TestBurnJob_NewUidResetsLatch: a repost (new uid) resets fill tracking — the
// new bid starts unfilled, so a stale high latch from the old uid can never mask
// the new bid's first fill, and old fill evidence can never burn on the new bid's
// behalf.
func TestBurnJob_NewUidResetsLatch(t *testing.T) {
	j := NewBurnJob(burnGate, burnModule)

	// tick 1: old uid fully latched at 40 (balance empty).
	oldUid := bytes.Repeat([]byte{0xAA}, 56)
	tick1 := burnStubReader{
		shareTok: burnShare, engine: burnEngine, settle: burnSettle,
		bal: big.NewInt(0), uid: oldUid, filled: big.NewInt(40),
	}
	if _, err := j.Evaluate(context.Background(), tick1); err != nil {
		t.Fatalf("tick1: %v", err)
	}

	// tick 2: NEW uid, its first fill (filled 10 < old latch 40), balance present ⇒
	// must burn (the reset makes 10 > 0 count).
	newUid := bytes.Repeat([]byte{0xBB}, 56)
	tick2 := burnStubReader{
		shareTok: burnShare, engine: burnEngine, settle: burnSettle,
		bal: big.NewInt(25), uid: newUid, filled: big.NewInt(10),
	}
	plan, err := j.Evaluate(context.Background(), tick2)
	if err != nil {
		t.Fatalf("tick2: %v", err)
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("tick2: new uid's fill must trigger a burn, got %d actions", len(plan.Actions))
	}
}

// TestBurnJob_Unwired_NoOp: engineSafe == 0x0 ⇒ empty plan, nil error.
func TestBurnJob_Unwired_NoOp(t *testing.T) {
	r := burnStubReader{shareTok: burnShare, engine: common.Address{}, bal: big.NewInt(100)}
	plan, err := NewBurnJob(burnGate, burnModule).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan (unwired), got %d actions", len(plan.Actions))
	}
}

// TestBurnJob_ReaderError_Propagates: a Reader error ⇒ (empty plan, err) so the
// Runner logs + continues (fail-safe).
func TestBurnJob_ReaderError_Propagates(t *testing.T) {
	r := burnStubReader{err: errors.New("rpc down")}
	plan, err := NewBurnJob(burnGate, burnModule).Evaluate(context.Background(), r)
	if err == nil {
		t.Fatal("expected a propagated read error")
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan on error, got %d actions", len(plan.Actions))
	}
}
