package job

import (
	"context"
	"errors"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// solvencyStubReader answers unreadablePairs() with a canned count (or an error).
type solvencyStubReader struct {
	skipped *big.Int
	err     error
}

func (s solvencyStubReader) CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	var got [4]byte
	copy(got[:], call.Data[:4])
	if got != sel("unreadablePairs()") {
		return nil, errors.New("stub: unexpected selector")
	}
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(s.skipped)
	return out, nil
}

func TestSolvencyProbe_AllReadable_NoError(t *testing.T) {
	j := NewSolvencyProbeJob(common.HexToAddress("0xA66"))
	plan, err := j.Evaluate(context.Background(), solvencyStubReader{skipped: big.NewInt(0)})
	if err != nil {
		t.Fatalf("expected no error at zero skips, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("probe must never plan actions, got %d", len(plan.Actions))
	}
}

func TestSolvencyProbe_UnreadablePairs_ErrorsLoudly(t *testing.T) {
	j := NewSolvencyProbeJob(common.HexToAddress("0xA66"))
	_, err := j.Evaluate(context.Background(), solvencyStubReader{skipped: big.NewInt(2)})
	if err == nil || !strings.Contains(err.Error(), "UNREADABLE") {
		t.Fatalf("expected loud unreadable-pairs error, got %v", err)
	}
}

func TestSolvencyProbe_ReadFailure_Errors(t *testing.T) {
	j := NewSolvencyProbeJob(common.HexToAddress("0xA66"))
	_, err := j.Evaluate(context.Background(), solvencyStubReader{err: errors.New("rpc down")})
	if err == nil {
		t.Fatal("expected error when the aggregator read itself fails")
	}
}
