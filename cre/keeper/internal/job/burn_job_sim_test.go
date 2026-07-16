package job

import (
	"context"
	"math/big"
	"testing"
	"time"

	"cre-keeper/internal/chain"
)

// ExitGateBurnProbe creation bytecode (forge solc 0.8.24) — verbatim from the
// KEEPER-01a ticket. The probe returns itself as shareToken()/engineSafe() and
// has a settable balanceOf; burnFor(amount) records lastBurned and zeroes bal.
const burnProbeBytecode = "0x608060405234801561000f575f80fd5b506101758061001d5f395ff3fe608060405234801561000f575f80fd5b506004361061007a575f3560e01c806370a082311161005857806370a08231146100bf578063754d6806146100d3578063ae47d43f146100e5578063f24ff18d14610099575f80fd5b80633d79d1c81461007e5780636c9fa59e146100995780636f5d0f0b146100a7575b5f80fd5b6100865f5481565b6040519081526020015b60405180910390f35b604051308152602001610090565b6100bd6100b53660046100ee565b6001555f8055565b005b6100866100cd366004610105565b505f5490565b6100bd6100e13660046100ee565b5f55565b61008660015481565b5f602082840312156100fe575f80fd5b5035919050565b5f60208284031215610115575f80fd5b813573ffffffffffffffffffffffffffffffffffffffff81168114610138575f80fd5b939250505056fea2646970667358221220c9a7c02dc3dc048c1d5616b8e178ae26aa22535355520195286671f488d68c6464736f6c63430008180033"

// TestBurnJob_SimEndToEnd deploys the ExitGateBurnProbe on the simulated backend,
// seeds bal=42, runs BurnJob through the Runner, and asserts the burn drained it
// (lastBurned()==42 and bal()==0). Reuses newSimEnv/waitFor/simChainID and the
// generalized deployProbe.
func TestBurnJob_SimEndToEnd(t *testing.T) {
	env := newSimEnv(t, false) // no OnlyOperatorProbe; we deploy the burn probe ourselves.
	probe := env.deployProbe(env.sim.Client(), burnProbeBytecode)

	// Seed the engine-Safe balance: setBal(42) = 0x754d6806 ++ uint256(42).
	if err := env.chain.ResyncNonce(context.Background()); err != nil {
		t.Fatalf("resync: %v", err)
	}
	if _, err := env.chain.Submit(context.Background(), chain.Action{
		Label: "setBal-42",
		To:    probe,
		Data:  chain.PackUintCall("setBal(uint256)", big.NewInt(42)),
	}); err != nil {
		t.Fatalf("setBal submit: %v", err)
	}

	// The probe returns itself as shareToken()/engineSafe(), so the gate address
	// IS the probe address. minBurn 0 ⇒ burn any non-zero fill.
	burn := NewBurnJob(probe, big.NewInt(0))
	runner := NewRunner(env.chain, []Job{burn}, 10*time.Millisecond, quietLogger())

	ctx, cancel := context.WithCancel(context.Background())
	doneRun := make(chan struct{})
	go func() { runner.Run(ctx); close(doneRun) }()

	waitFor(t, func() bool {
		v, err := chain.CallUint(context.Background(), env.chain, probe, "lastBurned()")
		return err == nil && v.Uint64() == 42
	})
	cancel()
	<-doneRun

	bal, err := chain.CallUint(context.Background(), env.chain, probe, "bal()")
	if err != nil {
		t.Fatalf("CallUint bal(): %v", err)
	}
	if bal.Sign() != 0 {
		t.Errorf("bal() = %s, want 0 (the burn must have drained it)", bal.String())
	}
}
