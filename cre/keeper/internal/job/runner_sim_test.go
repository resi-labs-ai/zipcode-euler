package job

import (
	"context"
	"math/big"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient/simulated"

	"cre-keeper/internal/chain"
	"cre-keeper/internal/config"
	"cre-keeper/internal/keymgr"
)

// OnlyOperatorProbe creation bytecode (forge solc 0.8.24) — verbatim from the ticket.
const probeBytecode = "0x608060405234801561000f575f80fd5b505f80546001600160a01b0319163317905561015a8061002e5f395ff3fe608060405234801561000f575f80fd5b506004361061003f575f3560e01c80633fa4f24514610043578063552410771461005f578063570ca73514610074575b5f80fd5b61004c60015481565b6040519081526020015b60405180910390f35b61007261006d36600461010d565b6100b8565b005b5f546100939073ffffffffffffffffffffffffffffffffffffffff1681565b60405173ffffffffffffffffffffffffffffffffffffffff9091168152602001610056565b5f5473ffffffffffffffffffffffffffffffffffffffff163314610108576040517f7c214f0400000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b600155565b5f6020828403121561011d575f80fd5b503591905056fea2646970667358221220156c220f7fa39b0e12cc3a92ba44606f4c7f61d45dafc8ee52705be05efcfded64736f6c63430008180033"

// anvil acct #3 (deployer ⇒ probe.operator()).
const operatorKey = "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

var simChainID = big.NewInt(1337) // simulated.NewBackend hardcodes 1337.

type simEnv struct {
	t      *testing.T
	sim    *simulated.Backend
	chain  *chain.Chain
	signer *keymgr.Signer
	probe  common.Address
	stop   func()
}

func setValueData(v uint64) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	packed, _ := abi.Arguments{{Type: u256}}.Pack(new(big.Int).SetUint64(v))
	sel := crypto.Keccak256([]byte("setValue(uint256)"))[:4]
	return append(sel, packed...)
}

// newSimChain builds a Chain over a funded simulated backend (no probe). Used by
// the fail-safe test which only needs ResyncNonce to succeed.
func newSimChain(t *testing.T) *chain.Chain {
	t.Helper()
	env := newSimEnv(t, false)
	return env.chain
}

func newSimEnv(t *testing.T, deploy bool) *simEnv {
	t.Helper()
	signer, err := keymgr.LoadHex(operatorKey)
	if err != nil {
		t.Fatalf("load key: %v", err)
	}
	bal := new(big.Int)
	bal.SetString("1000000000000000000000", 10)
	sim := simulated.NewBackend(types.GenesisAlloc{signer.Address(): {Balance: bal}})
	t.Cleanup(func() { sim.Close() })
	client := sim.Client()

	cfg := &config.Config{GasBufferBps: 3000, FeeCapMultiplier: 2, ConfirmTimeout: 30 * time.Second}
	c := chain.NewChain(client, simChainID, signer, cfg)

	done := make(chan struct{})
	exited := make(chan struct{})
	go func() {
		defer close(exited)
		for {
			select {
			case <-done:
				return
			default:
				sim.Commit()
				time.Sleep(5 * time.Millisecond)
			}
		}
	}()
	var stopOnce sync.Once
	stop := func() { stopOnce.Do(func() { close(done); <-exited }) } // wait for the committer to fully stop before any Close
	t.Cleanup(stop)

	env := &simEnv{t: t, sim: sim, chain: c, signer: signer, stop: stop}
	if deploy {
		env.probe = env.deployProbe(client, probeBytecode)
	}
	return env
}

// deployProbe deploys the given creation bytecode and returns its address. The
// bytecode is a parameter so different probes (OnlyOperatorProbe,
// ExitGateBurnProbe) can be deployed through the same plumbing.
func (e *simEnv) deployProbe(client interface {
	PendingNonceAt(context.Context, common.Address) (uint64, error)
	SuggestGasTipCap(context.Context) (*big.Int, error)
	HeaderByNumber(context.Context, *big.Int) (*types.Header, error)
	SendTransaction(context.Context, *types.Transaction) error
	TransactionReceipt(context.Context, common.Hash) (*types.Receipt, error)
}, bytecode string) common.Address {
	e.t.Helper()
	ctx := context.Background()
	from := e.signer.Address()
	nonce, err := client.PendingNonceAt(ctx, from)
	if err != nil {
		e.t.Fatalf("nonce: %v", err)
	}
	tip, err := client.SuggestGasTipCap(ctx)
	if err != nil {
		e.t.Fatalf("tip: %v", err)
	}
	head, err := client.HeaderByNumber(ctx, nil)
	if err != nil {
		e.t.Fatalf("head: %v", err)
	}
	maxFee := new(big.Int).Add(new(big.Int).Mul(head.BaseFee, big.NewInt(2)), tip)
	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID: simChainID, Nonce: nonce, GasTipCap: tip, GasFeeCap: maxFee,
		Gas: 1_000_000, To: nil, Data: common.FromHex(bytecode),
	})
	signed, err := e.signer.SignTx(tx, simChainID)
	if err != nil {
		e.t.Fatalf("sign: %v", err)
	}
	if err := client.SendTransaction(ctx, signed); err != nil {
		e.t.Fatalf("send: %v", err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		rc, err := client.TransactionReceipt(ctx, signed.Hash())
		if err == nil && rc != nil {
			if rc.Status != types.ReceiptStatusSuccessful {
				e.t.Fatalf("deploy reverted")
			}
			return rc.ContractAddress
		}
		if time.Now().After(deadline) {
			e.t.Fatalf("deploy receipt timeout")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// waitFor polls cond until true or a 10s deadline (test failure on timeout).
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if cond() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("waitFor: condition not met within deadline")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// planJob returns a fixed Plan (used to drive the Runner end-to-end).
type planJob struct {
	name string
	plan chain.Plan
}

func (p planJob) Name() string { return p.name }
func (p planJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	return p.plan, nil
}

// TestRunner_EndToEnd_SubmitsPlan drives a 2-action plan through the Runner on
// the simulated backend and asserts both writes landed (value()==final).
func TestRunner_EndToEnd_SubmitsPlan(t *testing.T) {
	env := newSimEnv(t, true)

	j := planJob{name: "setter", plan: chain.Plan{Actions: []chain.Action{
		{Label: "set-7", To: env.probe, Data: setValueData(7)},
		{Label: "set-11", To: env.probe, Data: setValueData(11)},
	}}}
	runner := NewRunner(env.chain, []Job{j}, time.Hour, quietLogger())

	ctx, cancel := context.WithCancel(context.Background())
	doneRun := make(chan struct{})
	go func() { runner.Run(ctx); close(doneRun) }()
	waitFor(t, func() bool {
		v, err := chain.CallUint(context.Background(), env.chain, env.probe, "value()")
		return err == nil && v.Uint64() == 11
	})
	cancel()
	<-doneRun

	got, err := chain.CallUint(context.Background(), env.chain, env.probe, "value()")
	if err != nil {
		t.Fatalf("CallUint value(): %v", err)
	}
	if got.Uint64() != 11 {
		t.Errorf("value() = %d, want 11 (both actions landed in order)", got.Uint64())
	}
}

// TestRunner_AbortOnFirstError stops the rest of a plan after the first failing
// Action. Action 1 reverts (setValue from the operator is fine; instead we make
// the first action target a bogus selector on the probe so EstimateGas reverts),
// so the second action MUST NOT execute.
func TestRunner_AbortOnFirstError(t *testing.T) {
	env := newSimEnv(t, true)

	// First write a known value so we can detect whether action 2 ran.
	if err := env.chain.ResyncNonce(context.Background()); err != nil {
		t.Fatalf("resync: %v", err)
	}
	if _, err := env.chain.Submit(context.Background(), chain.Action{
		Label: "seed", To: env.probe, Data: setValueData(5),
	}); err != nil {
		t.Fatalf("seed submit: %v", err)
	}

	// Action 1 calls a non-existent function selector ⇒ the probe has no fallback,
	// so EstimateGas reverts ⇒ Submit returns error WITHOUT sending. Action 2
	// (setValue(77)) must then be aborted.
	bogus := crypto.Keccak256([]byte("doesNotExist()"))[:4]
	// Action 1 reverts in EstimateGas ⇒ Submit errors without sending ⇒ the Runner
	// aborts the rest of the plan, so action 2 (setValue 77) is never submitted.
	// calls counts Evaluate invocations so we can wait for SEVERAL ticks: if the
	// abort were broken, action 2 (which DOES need mining) would land 77 well
	// within that window (the auto-commit goroutine is mining).
	var calls int64
	j := &countingPlanJob{
		inner: planJob{name: "aborter", plan: chain.Plan{Actions: []chain.Action{
			{Label: "reverts", To: env.probe, Data: bogus},
			{Label: "set-77", To: env.probe, Data: setValueData(77)},
		}}},
		calls: &calls,
	}
	runner := NewRunner(env.chain, []Job{j}, 10*time.Millisecond, quietLogger())

	ctx, cancel := context.WithCancel(context.Background())
	doneRun := make(chan struct{})
	go func() { runner.Run(ctx); close(doneRun) }()
	// Wait for at least 3 ticks — ample time for a (broken) action 2 to mine.
	waitFor(t, func() bool { return atomic.LoadInt64(&calls) >= 3 })
	cancel()
	<-doneRun

	got, err := chain.CallUint(context.Background(), env.chain, env.probe, "value()")
	if err != nil {
		t.Fatalf("CallUint value(): %v", err)
	}
	if got.Uint64() != 5 {
		t.Errorf("value() = %d, want 5 (action 2 must NOT have run after action 1 aborted)", got.Uint64())
	}
}

// countingPlanJob wraps planJob and counts Evaluate calls (atomic).
type countingPlanJob struct {
	inner planJob
	calls *int64
}

func (c *countingPlanJob) Name() string { return c.inner.Name() }
func (c *countingPlanJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	atomic.AddInt64(c.calls, 1)
	return c.inner.Evaluate(ctx, r)
}
