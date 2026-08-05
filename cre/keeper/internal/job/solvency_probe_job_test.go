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

// solvencyStubReader answers the three skip counters with per-selector canned
// counts (or an error). Per-selector because the legs break independently —
// the exact state the probe exists to catch is one counter nonzero while the
// others are zero.
type solvencyStubReader struct {
	senior   *big.Int // unreadablePairs()
	illiquid *big.Int // unreadableIlliquidPairs()
	active   *big.Int // unreadableActivePairs()
	err      error
}

func (s solvencyStubReader) CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	var got [4]byte
	copy(got[:], call.Data[:4])
	var v *big.Int
	switch got {
	case sel("unreadablePairs()"):
		v = s.senior
	case sel("unreadableIlliquidPairs()"):
		v = s.illiquid
	case sel("unreadableActivePairs()"):
		v = s.active
	default:
		return nil, errors.New("stub: unexpected selector")
	}
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(v)
	return out, nil
}

func zeroSkips() solvencyStubReader {
	return solvencyStubReader{senior: big.NewInt(0), illiquid: big.NewInt(0), active: big.NewInt(0)}
}

func TestSolvencyProbe_AllReadable_NoError(t *testing.T) {
	j := NewSolvencyProbeJob(common.HexToAddress("0xA66"))
	plan, err := j.Evaluate(context.Background(), zeroSkips())
	if err != nil {
		t.Fatalf("expected no error at zero skips, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("probe must never plan actions, got %d", len(plan.Actions))
	}
}

func TestSolvencyProbe_UnreadablePairs_ErrorsLoudly(t *testing.T) {
	j := NewSolvencyProbeJob(common.HexToAddress("0xA66"))
	r := zeroSkips()
	r.senior = big.NewInt(2)
	_, err := j.Evaluate(context.Background(), r)
	if err == nil || !strings.Contains(err.Error(), "UNREADABLE") {
		t.Fatalf("expected loud unreadable-pairs error, got %v", err)
	}
}

// The regression the per-leg counters exist for: a maxWithdraw-only outage
// breaks the illiquid Σ alone. Pre-fix the probe read only unreadablePairs()
// and reported this state as healthy.
func TestSolvencyProbe_IlliquidOnlyOutage_ErrorsLoudly(t *testing.T) {
	j := NewSolvencyProbeJob(common.HexToAddress("0xA66"))
	r := zeroSkips()
	r.illiquid = big.NewInt(1)
	_, err := j.Evaluate(context.Background(), r)
	if err == nil || !strings.Contains(err.Error(), "illiquidSeniorValue") {
		t.Fatalf("expected loud illiquid-leg error naming the degraded aggregate, got %v", err)
	}
}

func TestSolvencyProbe_ActiveOnlyOutage_ErrorsLoudly(t *testing.T) {
	j := NewSolvencyProbeJob(common.HexToAddress("0xA66"))
	r := zeroSkips()
	r.active = big.NewInt(1)
	_, err := j.Evaluate(context.Background(), r)
	if err == nil || !strings.Contains(err.Error(), "activeSeniorBacking") {
		t.Fatalf("expected loud active-leg error naming the degraded aggregate, got %v", err)
	}
}

func TestSolvencyProbe_ReadFailure_Errors(t *testing.T) {
	j := NewSolvencyProbeJob(common.HexToAddress("0xA66"))
	_, err := j.Evaluate(context.Background(), solvencyStubReader{err: errors.New("rpc down")})
	if err == nil {
		t.Fatal("expected error when the aggregator read itself fails")
	}
}
