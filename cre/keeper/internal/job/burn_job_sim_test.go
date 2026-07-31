package job

import (
	"context"
	"math/big"
	"testing"
	"time"

	"cre-keeper/internal/chain"
)

// BurnFillProbe creation bytecode (forge solc 0.8.24) — from BurnFillProbe.sol at
// the keeper root (the repo probe pattern). The probe returns itself as
// shareToken()/engineSafe()/settlement(); settable bal/uidPresent/filled;
// burnFor(amount) records lastBurned and zeroes bal.
const burnFillProbeBytecode = "0x608060405234801561000f575f80fd5b506107108061001d5f395ff3fe608060405234801561000f575f80fd5b50600436106100b2575f3560e01c806370a082311161006f57806370a0823114610178578063754d6806146101a857806379b27d19146101c4578063ae47d43f146101e0578063def18101146101fe578063f24ff18d1461021d576100b2565b80632479fb6e146100b65780633d79d1c8146100e657806351160630146101045780636ad8b13c146101225780636c9fa59e1461013e5780636f5d0f0b1461015c575b5f80fd5b6100d060048036038101906100cb91906103ea565b61023b565b6040516100dd919061044d565b60405180910390f35b6100ee610247565b6040516100fb919061044d565b60405180910390f35b61010c61024c565b60405161011991906104a5565b60405180910390f35b61013c600480360381019061013791906104f3565b610253565b005b61014661026f565b60405161015391906104a5565b60405180910390f35b61017660048036038101906101719190610548565b610276565b005b610192600480360381019061018d919061059d565b610286565b60405161019f919061044d565b60405180910390f35b6101c260048036038101906101bd9190610548565b610290565b005b6101de60048036038101906101d99190610548565b610299565b005b6101e86102a3565b6040516101f5919061044d565b60405180910390f35b6102066102a9565b604051610214929190610652565b60405180910390f35b61022561037a565b60405161023291906104a5565b60405180910390f35b5f600254905092915050565b5f5481565b5f30905090565b8060035f6101000a81548160ff02191690831515021790555050565b5f30905090565b806001819055505f808190555050565b5f80549050919050565b805f8190555050565b8060028190555050565b60015481565b60605f60035f9054906101000a900460ff161561037057603867ffffffffffffffff8111156102db576102da610680565b5b6040519080825280601f01601f19166020018201604052801561030d5781602001600182028036833780820191505090505b5091505f5b603881101561036e5760ab60f81b838281518110610333576103326106ad565b5b60200101907effffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff191690815f1a9053508080600101915050610312565b505b815f915091509091565b5f30905090565b5f80fd5b5f80fd5b5f80fd5b5f80fd5b5f80fd5b5f8083601f8401126103aa576103a9610389565b5b8235905067ffffffffffffffff8111156103c7576103c661038d565b5b6020830191508360018202830111156103e3576103e2610391565b5b9250929050565b5f8060208385031215610400576103ff610381565b5b5f83013567ffffffffffffffff81111561041d5761041c610385565b5b61042985828601610395565b92509250509250929050565b5f819050919050565b61044781610435565b82525050565b5f6020820190506104605f83018461043e565b92915050565b5f73ffffffffffffffffffffffffffffffffffffffff82169050919050565b5f61048f82610466565b9050919050565b61049f81610485565b82525050565b5f6020820190506104b85f830184610496565b92915050565b5f8115159050919050565b6104d2816104be565b81146104dc575f80fd5b50565b5f813590506104ed816104c9565b92915050565b5f6020828403121561050857610507610381565b5b5f610515848285016104df565b91505092915050565b61052781610435565b8114610531575f80fd5b50565b5f813590506105428161051e565b92915050565b5f6020828403121561055d5761055c610381565b5b5f61056a84828501610534565b91505092915050565b61057c81610485565b8114610586575f80fd5b50565b5f8135905061059781610573565b92915050565b5f602082840312156105b2576105b1610381565b5b5f6105bf84828501610589565b91505092915050565b5f81519050919050565b5f82825260208201905092915050565b5f5b838110156105ff5780820151818401526020810190506105e4565b5f8484015250505050565b5f601f19601f8301169050919050565b5f610624826105c8565b61062e81856105d2565b935061063e8185602086016105e2565b6106478161060a565b840191505092915050565b5f6040820190508181035f83015261066a818561061a565b9050610679602083018461043e565b9392505050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52604160045260245ffd5b7f4e487b71000000000000000000000000000000000000000000000000000000005f52603260045260245ffdfea26469706673582212204dd4410f032ec8c2953cb38724f303ac293a675d669e56d3e6986ecf2824d8fb64736f6c63430008180033"

// packBoolCall encodes sig ++ abi.encode(bool) for the probe's setUidPresent.
func packBoolCall(sig string, v bool) []byte {
	arg := make([]byte, 32)
	if v {
		arg[31] = 1
	}
	return append(chain.PackCall(sig), arg...)
}

// TestBurnJob_SimEndToEnd_FillTriggered deploys the BurnFillProbe on the
// simulated backend and proves the fill-triggered contract end to end:
//   phase 1 — a DONATION (bal 7, live uid, filled 0) sits: no burn ever fires.
//   phase 2 — a FILL (setFilled 42, bal 42+7) sweeps the FULL balance in one
//             burnFor(49): lastBurned()==49, bal()==0.
func TestBurnJob_SimEndToEnd_FillTriggered(t *testing.T) {
	env := newSimEnv(t, false) // no OnlyOperatorProbe; we deploy the fill probe ourselves.
	probe := env.deployProbe(env.sim.Client(), burnFillProbeBytecode)

	ctx := context.Background()
	if err := env.chain.ResyncNonce(ctx); err != nil {
		t.Fatalf("resync: %v", err)
	}

	// Phase-1 state: live uid, NO fill, a 7-wei donation on the Safe.
	for _, a := range []chain.Action{
		{Label: "uid-present", To: probe, Data: packBoolCall("setUidPresent(bool)", true)},
		{Label: "donate-7", To: probe, Data: chain.PackUintCall("setBal(uint256)", big.NewInt(7))},
	} {
		if _, err := env.chain.Submit(ctx, a); err != nil {
			t.Fatalf("%s submit: %v", a.Label, err)
		}
	}

	burn := NewBurnJob(probe, probe) // gate == module == probe (it answers both surfaces)
	runner := NewRunner(env.chain, []Job{burn}, 10*time.Millisecond, quietLogger())

	runCtx, cancel := context.WithCancel(ctx)
	doneRun := make(chan struct{})
	go func() { runner.Run(runCtx); close(doneRun) }()

	// Phase 1: give the runner several ticks — the donation must SIT (no fill evidence).
	time.Sleep(100 * time.Millisecond)
	if v, err := chain.CallUint(ctx, env.chain, probe, "lastBurned()"); err != nil || v.Sign() != 0 {
		cancel()
		<-doneRun
		t.Fatalf("donation without fill must never burn: lastBurned=%v err=%v", v, err)
	}

	// Phase 2: a fill lands — loot 42 joins the donation (bal 49), filled 42.
	// (Submit while the runner runs is safe: the spine serializes on the nonce via
	// the same chain instance? No — pause the runner first for determinism.)
	cancel()
	<-doneRun
	if err := env.chain.ResyncNonce(ctx); err != nil {
		t.Fatalf("resync: %v", err)
	}
	for _, a := range []chain.Action{
		{Label: "fill-42", To: probe, Data: chain.PackUintCall("setFilled(uint256)", big.NewInt(42))},
		{Label: "bal-49", To: probe, Data: chain.PackUintCall("setBal(uint256)", big.NewInt(49))},
	} {
		if _, err := env.chain.Submit(ctx, a); err != nil {
			t.Fatalf("%s submit: %v", a.Label, err)
		}
	}

	runCtx2, cancel2 := context.WithCancel(ctx)
	doneRun2 := make(chan struct{})
	go func() { runner.Run(runCtx2); close(doneRun2) }()

	waitFor(t, func() bool {
		v, err := chain.CallUint(ctx, env.chain, probe, "lastBurned()")
		return err == nil && v.Uint64() == 49
	})
	cancel2()
	<-doneRun2

	bal, err := chain.CallUint(ctx, env.chain, probe, "bal()")
	if err != nil {
		t.Fatalf("CallUint bal(): %v", err)
	}
	if bal.Sign() != 0 {
		t.Errorf("bal() = %s, want 0 (the burn must have drained loot + donation together)", bal.String())
	}
}
