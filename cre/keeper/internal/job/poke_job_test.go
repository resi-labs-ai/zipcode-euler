package job

import (
	"context"
	"errors"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// pokeStubReader answers lastUpdate() with a canned timestamp (or an error).
type pokeStubReader struct {
	lastUpdate *big.Int
	err        error
}

func (s pokeStubReader) CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	var got [4]byte
	copy(got[:], call.Data[:4])
	if got != sel("lastUpdate()") {
		return nil, errors.New("stub: unexpected selector")
	}
	u256, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u256}}.Pack(s.lastUpdate)
	return out, nil
}

const pokeAfter = 1200 // 20 minutes, comfortably inside the oracle's W of 3600

var navOracleAddr = common.HexToAddress("0x00000000000000000000000000000000000000A0")

// A healthy sharefeeds pushes every 5 minutes, so the accumulator is never near the threshold and the job
// must stay silent. This is the steady state and it must not spend gas.
func TestPoke_FreshAccumulator_NoAction(t *testing.T) {
	j := NewPokeJob(navOracleAddr, pokeAfter)
	recent := big.NewInt(time.Now().Unix() - 60)
	plan, err := j.Evaluate(context.Background(), pokeStubReader{lastUpdate: recent})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("a fresh accumulator must produce no action, got %d", len(plan.Actions))
	}
}

// The case the job exists for: sharefeeds is down, the accumulator has aged past the threshold, and the
// bracket is heading for the spot fallback. One poke() must be planned.
func TestPoke_StaleAccumulator_PlansPoke(t *testing.T) {
	j := NewPokeJob(navOracleAddr, pokeAfter)
	stale := big.NewInt(time.Now().Unix() - (pokeAfter + 60))
	plan, err := j.Evaluate(context.Background(), pokeStubReader{lastUpdate: stale})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("a stale accumulator must plan exactly one poke, got %d", len(plan.Actions))
	}
	a := plan.Actions[0]
	if a.To != navOracleAddr {
		t.Fatalf("poke must target the NAV oracle, got %s", a.To.Hex())
	}
	want := sel("poke()")
	var got [4]byte
	copy(got[:], a.Data)
	if got != want {
		t.Fatalf("calldata must be poke(), got %x", a.Data)
	}
	if len(a.Data) != 4 {
		t.Fatalf("poke() takes no arguments, got %d bytes of calldata", len(a.Data))
	}
	if !strings.Contains(a.Label, "poke()") {
		t.Fatalf("label should say what it is doing, got %q", a.Label)
	}
}

// Exactly at the threshold it acts — the boundary belongs on the safe side, since being late is the failure
// and being early costs one idempotent transaction.
func TestPoke_AtThreshold_Acts(t *testing.T) {
	j := NewPokeJob(navOracleAddr, pokeAfter)
	at := big.NewInt(time.Now().Unix() - pokeAfter)
	plan, err := j.Evaluate(context.Background(), pokeStubReader{lastUpdate: at})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("the threshold itself must act, got %d actions", len(plan.Actions))
	}
}

// An unwired/pre-genesis oracle reads 0. That is not staleness, and poking it would be noise.
func TestPoke_NeverAccumulated_NoAction(t *testing.T) {
	j := NewPokeJob(navOracleAddr, pokeAfter)
	plan, err := j.Evaluate(context.Background(), pokeStubReader{lastUpdate: big.NewInt(0)})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("a never-accumulated oracle must produce no action, got %d", len(plan.Actions))
	}
}

// A read failure surfaces as an error so the Runner logs it; it must never be mistaken for "fresh".
func TestPoke_ReadFailure_Errors(t *testing.T) {
	j := NewPokeJob(navOracleAddr, pokeAfter)
	_, err := j.Evaluate(context.Background(), pokeStubReader{err: errors.New("rpc down")})
	if err == nil {
		t.Fatal("a failed lastUpdate() read must error, not silently report fresh")
	}
	if !strings.Contains(err.Error(), "lastUpdate()") {
		t.Fatalf("error should name the failed read, got: %v", err)
	}
}

// A lastUpdate ahead of the host clock (skew) must not underflow into a huge age and spam pokes.
func TestPoke_FutureTimestamp_NoAction(t *testing.T) {
	j := NewPokeJob(navOracleAddr, pokeAfter)
	ahead := big.NewInt(time.Now().Unix() + 300)
	plan, err := j.Evaluate(context.Background(), pokeStubReader{lastUpdate: ahead})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("clock skew must not trigger a poke, got %d actions", len(plan.Actions))
	}
}
