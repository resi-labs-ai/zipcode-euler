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
// balanceOf(address)->bal. An optional err short-circuits every call (the
// RPC-failure branch). Reuses sel/encodeAddr from job_test.go (same package).
type burnStubReader struct {
	shareTok common.Address
	engine   common.Address
	bal      *big.Int
	err      error
}

func encodeUint(v *big.Int) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(v)
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
	default:
		return nil, errors.New("stub: unexpected selector")
	}
}

var (
	burnGate   = common.HexToAddress("0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e")
	burnShare  = common.HexToAddress("0x33aD3E23aE000000000000000000000000000001")
	burnEngine = common.HexToAddress("0x000000000000000000000000000000000000E516")
)

// TestBurnJob_Fill_ExactCalldata is the load-bearing binding: balance 100 ≥
// minBurn 0 ⇒ a one-Action plan to exitGate with Data byte-equal to
// 0x6f5d0f0b ++ <uint256 100>.
func TestBurnJob_Fill_ExactCalldata(t *testing.T) {
	r := burnStubReader{shareTok: burnShare, engine: burnEngine, bal: big.NewInt(100)}
	j := NewBurnJob(burnGate, big.NewInt(0))
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

// TestBurnJob_ZeroBalance_NoOp: balance 0 ⇒ empty plan, nil error.
func TestBurnJob_ZeroBalance_NoOp(t *testing.T) {
	r := burnStubReader{shareTok: burnShare, engine: burnEngine, bal: big.NewInt(0)}
	plan, err := NewBurnJob(burnGate, big.NewInt(0)).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan, got %d actions", len(plan.Actions))
	}
}

// TestBurnJob_BelowFloor_NoOp: balance 5, minBurn 10 ⇒ empty plan, nil error.
func TestBurnJob_BelowFloor_NoOp(t *testing.T) {
	r := burnStubReader{shareTok: burnShare, engine: burnEngine, bal: big.NewInt(5)}
	plan, err := NewBurnJob(burnGate, big.NewInt(10)).Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan (below floor), got %d actions", len(plan.Actions))
	}
}

// TestBurnJob_Unwired_NoOp: engineSafe == 0x0 ⇒ empty plan, nil error.
func TestBurnJob_Unwired_NoOp(t *testing.T) {
	r := burnStubReader{shareTok: burnShare, engine: common.Address{}, bal: big.NewInt(100)}
	plan, err := NewBurnJob(burnGate, big.NewInt(0)).Evaluate(context.Background(), r)
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
	plan, err := NewBurnJob(burnGate, big.NewInt(0)).Evaluate(context.Background(), r)
	if err == nil {
		t.Fatal("expected a propagated read error")
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan on error, got %d actions", len(plan.Actions))
	}
}
