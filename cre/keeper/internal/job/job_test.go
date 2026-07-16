package job

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"math/big"
	"sync"
	"testing"
	"time"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"cre-keeper/internal/chain"
)

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// ---- stub Reader for IdentityJob (anvil-free, simulated-free) ----

// stubReader returns canned ABI-encoded addresses keyed by the 4-byte selector
// in the call data: operator()/windowController() -> admin; owner() -> owner.
type stubReader struct {
	admin common.Address
	owner common.Address
}

func encodeAddr(a common.Address) []byte {
	addrT, _ := abi.NewType("address", "", nil)
	out, _ := abi.Arguments{{Type: addrT}}.Pack(a)
	return out
}

func sel(sig string) [4]byte {
	var s [4]byte
	copy(s[:], crypto.Keccak256([]byte(sig))[:4])
	return s
}

func (s stubReader) CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error) {
	if len(call.Data) < 4 {
		return nil, errors.New("stub: short calldata")
	}
	var got [4]byte
	copy(got[:], call.Data[:4])
	switch got {
	case sel("operator()"), sel("windowController()"):
		return encodeAddr(s.admin), nil
	case sel("owner()"):
		return encodeAddr(s.owner), nil
	default:
		return nil, errors.New("stub: unexpected selector")
	}
}

var (
	wantOperator = common.HexToAddress("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")
	timelock     = common.HexToAddress("0x89ae00000000000000000000000000000000beef")
	moduleAddr   = common.HexToAddress("0x61cdc9c8839753f520cc9dc4f2a733e132fe10e4")
)

func identityJob() *IdentityJob {
	return NewIdentityJob(wantOperator, []IdentityCheck{
		{Name: "FarmUtilityLoopModule", Addr: moduleAddr, AdminSig: "operator()"},
	})
}

func TestIdentityJob_Match_EmptyPlanNilErr(t *testing.T) {
	// operator()==want && owner()!=want ⇒ empty plan, nil error.
	r := stubReader{admin: wantOperator, owner: timelock}
	plan, err := identityJob().Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if len(plan.Actions) != 0 {
		t.Fatalf("expected empty plan, got %d actions", len(plan.Actions))
	}
}

func TestIdentityJob_OperatorMismatch_Errors(t *testing.T) {
	// operator()!=want ⇒ error.
	r := stubReader{admin: timelock, owner: timelock}
	if _, err := identityJob().Evaluate(context.Background(), r); err == nil {
		t.Fatal("expected operator-mismatch error")
	}
}

func TestIdentityJob_OperatorIsOwner_Errors(t *testing.T) {
	// owner()==want ⇒ error (the operator != owner guard fires, §8.7).
	r := stubReader{admin: wantOperator, owner: wantOperator}
	if _, err := identityJob().Evaluate(context.Background(), r); err == nil {
		t.Fatal("expected operator==owner guard to fire")
	}
}

// ---- Runner fail-safe: a job error logs-and-continues, never crashes ----

// errJob always errors in Evaluate.
type errJob struct{}

func (errJob) Name() string { return "errJob" }
func (errJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	return chain.Plan{}, errors.New("boom")
}

// countJob records each Evaluate call (proves the Runner continues past errJob).
type countJob struct {
	mu sync.Mutex
	n  int
}

func (c *countJob) Name() string { return "countJob" }
func (c *countJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	c.mu.Lock()
	c.n++
	c.mu.Unlock()
	return chain.Plan{}, nil // empty plan ⇒ no submit needed
}
func (c *countJob) count() int { c.mu.Lock(); defer c.mu.Unlock(); return c.n }

func TestRunner_FailSafe_ContinuesPastJobError(t *testing.T) {
	// A nil *Chain is safe here: ResyncNonce is the only Chain call per tick, and
	// both jobs return empty plans (no Submit). But ResyncNonce on a nil Chain
	// would panic — so use a real Chain over a simulated backend instead.
	c := newSimChain(t)

	counter := &countJob{}
	runner := NewRunner(c, []Job{errJob{}, counter}, time.Hour, quietLogger())

	// Run in a goroutine with a live context; the first tick runs immediately.
	// Poll for the effect, then cancel for a graceful stop.
	ctx, cancel := context.WithCancel(context.Background())
	doneRun := make(chan struct{})
	go func() { runner.Run(ctx); close(doneRun) }()

	waitFor(t, func() bool { return counter.count() >= 1 })
	cancel()
	<-doneRun

	if counter.count() < 1 {
		t.Fatalf("countJob did not run after errJob (fail-safe broken): n=%d", counter.count())
	}
}
