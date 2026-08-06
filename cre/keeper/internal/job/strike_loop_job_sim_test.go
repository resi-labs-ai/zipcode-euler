package job

import (
	"context"
	"math/big"
	"testing"
	"time"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"cre-keeper/internal/chain"
)

// StrikeLoopProbe creation bytecode (forge solc 0.8.24, --optimize) — verbatim
// from the authored cre/keeper/StrikeLoopProbe.sol. The probe returns scripted
// view values for the gate reads AND records the ordered (selector, args) of
// every state-changing leg the Runner submits. One probe stands in for all six
// engine modules + the oHYDX/HYDX tokens (à la the KEEPER-01a burn probe).
const strikeLoopProbeBytecode = "0x608060405234801561000f575f80fd5b506111438061001d5f395ff3fe608060405234801561000f575f80fd5b506004361061020f575f3560e01c8063a195191411610123578063c32920b9116100ab578063e2702bbe1161007a578063e2702bbe14610609578063ef998cf014610625578063f24ff18d14610641578063f7c618c11461065f578063fef1c96a1461067d5761020f565b8063c32920b914610581578063c5ebeaec1461059f578063dd1c35bc146105bb578063e20ccec3146105eb5761020f565b8063ad8f5008116100f2578063ad8f5008146104ef578063b88a802f1461050d578063b8eb354614610517578063bd3daa8614610535578063c195fc74146105655761020f565b8063a195191414610469578063a694fc3a14610485578063a6f19c84146104a1578063aa50bec1146104bf5761020f565b80634c3f2476116101a65780637d141154116101755780637d141154146103c25780637dbf67a7146103e057806384acbb89146103fc578063900407bc1461042f578063a08d874c1461044d5761020f565b80634c3f24761461032857806350a48df51461034657806370a0823114610376578063754d6806146103a65761020f565b80632c16cd8a116101e25780632c16cd8a1461028b578063371fd8e6146102be5780633d79d1c8146102da578063422f1043146102f85761020f565b806306f94a0d146102135780630dca59c114610231578063137ee36e1461024f57806320f8968a1461026d575b5f80fd5b61021b61069b565b6040516102289190610ef4565b60405180910390f35b6102396106a4565b6040516102469190610ef4565b60405180910390f35b6102576106aa565b6040516102649190610ef4565b60405180910390f35b6102756106b3565b6040516102829190610f4c565b60405180910390f35b6102a560048036038101906102a09190610f93565b6106ba565b6040516102b59493929190610ff8565b60405180910390f35b6102d860048036038101906102d39190610f93565b610710565b005b6102e26107c3565b6040516102ef9190610ef4565b60405180910390f35b610312600480360381019061030d919061103b565b6107c9565b60405161031f9190610ef4565b60405180910390f35b610330610884565b60405161033d9190610f4c565b60405180910390f35b610360600480360381019061035b919061103b565b61088b565b60405161036d9190610ef4565b60405180910390f35b610390600480360381019061038b91906110b5565b610946565b60405161039d9190610ef4565b60405180910390f35b6103c060048036038101906103bb9190610f93565b610951565b005b6103ca61095b565b6040516103d79190610f4c565b60405180910390f35b6103fa60048036038101906103f59190610f93565b610962565b005b61041660048036038101906104119190610f93565b61096c565b6040516104269493929190610ff8565b60405180910390f35b6104376109b3565b6040516104449190610ef4565b60405180910390f35b61046760048036038101906104629190610f93565b6109bf565b005b610483600480360381019061047e9190610f93565b6109c9565b005b61049f600480360381019061049a9190610f93565b610a7c565b005b6104a9610b2f565b6040516104b69190610f4c565b60405180910390f35b6104d960048036038101906104d4919061103b565b610b36565b6040516104e69190610ef4565b60405180910390f35b6104f7610bf1565b6040516105049190610ef4565b60405180910390f35b610515610bf7565b005b61051f610ca9565b60405161052c9190610ef4565b60405180910390f35b61054f600480360381019061054a9190610f93565b610caf565b60405161055c9190610ef4565b60405180910390f35b61057f600480360381019061057a9190610f93565b610cba565b005b610589610cc4565b6040516105969190610ef4565b60405180910390f35b6105b960048036038101906105b49190610f93565b610ccd565b005b6105d560048036038101906105d09190610f93565b610d80565b6040516105e29190610ef4565b60405180910390f35b6105f3610e39565b6040516106009190610ef4565b60405180910390f35b610623600480360381019061061e91906110b5565b610e3f565b005b61063f600480360381019061063a9190610f93565b610e81565b005b610649610e8b565b6040516106569190610f4c565b60405180910390f35b610667610eae565b6040516106749190610f4c565b60405180910390f35b610685610eb5565b6040516106929190610f4c565b60405180910390f35b5f600654905090565b60065481565b5f600254905090565b5f30905090565b5f805f805f600586815481106106d3576106d26110e0565b5b905f5260205f2090600402019050805f015f9054906101000a900460e01b8160010154826002015483600301549450945094509450509193509193565b6005604051806080016040528063371fd8e660e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff191681526020018381526020015f81526020015f815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c0217905550602082015181600101556040820151816002015560608201518160030155505050565b60015481565b5f6005604051806080016040528063422f104360e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff1916815260200186815260200185815260200184815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c021790555060208201518160010155604082015181600201556060820151816003015550508190509392505050565b5f30905090565b5f600560405180608001604052806350a48df560e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff1916815260200186815260200185815260200184815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c021790555060208201518160010155604082015181600201556060820151816003015550508290509392505050565b5f6001549050919050565b8060018190555050565b5f30905090565b8060068190555050565b6005818154811061097b575f80fd5b905f5260205f2090600402015f91509050805f015f9054906101000a900460e01b908060010154908060020154908060030154905084565b5f600580549050905090565b8060048190555050565b6005604051806080016040528063a195191460e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff191681526020018381526020015f81526020015f815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c0217905550602082015181600101556040820151816002015560608201518160030155505050565b6005604051806080016040528063a694fc3a60e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff191681526020018381526020015f81526020015f815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c0217905550602082015181600101556040820151816002015560608201518160030155505050565b5f30905090565b5f6005604051806080016040528063aa50bec160e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff1916815260200186815260200185815260200184815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c021790555060208201518160010155604082015181600201556060820151816003015550508290509392505050565b60045481565b6005604051806080016040528063b88a802f60e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff191681526020015f81526020015f81526020015f815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c02179055506020820151816001015560408201518160020155606082015181600301555050565b60035481565b5f6004549050919050565b8060028190555050565b5f600354905090565b6005604051806080016040528063c5ebeaec60e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff191681526020018381526020015f81526020015f815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c0217905550602082015181600101556040820151816002015560608201518160030155505050565b5f6005604051806080016040528063dd1c35bc60e01b7bffffffffffffffffffffffffffffffffffffffffffffffffffffffff191681526020018481526020015f81526020015f815250908060018154018082558091505060019003905f5260205f2090600402015f909190919091505f820151815f015f6101000a81548163ffffffff021916908360e01c02179055506020820151816001015560408201518160020155606082015181600301555050819050919050565b60025481565b805f806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff16021790555050565b8060038190555050565b5f8054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b5f30905090565b5f805f9054906101000a900473ffffffffffffffffffffffffffffffffffffffff16905090565b5f819050919050565b610eee81610edc565b82525050565b5f602082019050610f075f830184610ee5565b92915050565b5f73ffffffffffffffffffffffffffffffffffffffff82169050919050565b5f610f3682610f0d565b9050919050565b610f4681610f2c565b82525050565b5f602082019050610f5f5f830184610f3d565b92915050565b5f80fd5b610f7281610edc565b8114610f7c575f80fd5b50565b5f81359050610f8d81610f69565b92915050565b5f60208284031215610fa857610fa7610f65565b5b5f610fb584828501610f7f565b91505092915050565b5f7fffffffff0000000000000000000000000000000000000000000000000000000082169050919050565b610ff281610fbe565b82525050565b5f60808201905061100b5f830187610fe9565b6110186020830186610ee5565b6110256040830185610ee5565b6110326060830184610ee5565b95945050505050565b5f805f6060848603121561105257611051610f65565b5b5f61105f86828701610f7f565b935050602061107086828701610f7f565b925050604061108186828701610f7f565b9150509250925092565b61109481610f2c565b811461109e575f80fd5b50565b5f813590506110af8161108b565b92915050565b5f602082840312156110ca576110c9610f65565b5b5f6110d7848285016110a1565b91505092915050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52603260045260245ffdfea26469706673582212206a166ea9452b388d5fe5d0a77ac30276f63d196b32563eaf87e3c61b3870c2f664736f6c63430008180033"

func sel4(sig string) [4]byte {
	var s [4]byte
	copy(s[:], crypto.Keccak256([]byte(sig))[:4])
	return s
}

// TestStrikeLoop_SimEndToEnd deploys the StrikeLoopProbe, seeds its scripted
// views, wires every engine-module config + token getter at the probe, injects a
// fake Quoter (profitable, full-taper), runs the Job through the Runner, and
// asserts the probe recorded the EXACT ordered (selector, args) sequence the
// Plan should submit.
func TestStrikeLoop_SimEndToEnd(t *testing.T) {
	env := newSimEnv(t, false)
	probe := env.deployProbe(env.sim.Client(), strikeLoopProbeBytecode)

	// Seed scripted views: engineSafe = a non-zero addr; balanceOf = 0 (so
	// oHydxBal = hydxBal = 0); pending = 100e18 oHYDX; maxSell = 300e18; strike =
	// 500000 (0.5 USDC, 6dp).
	seed := func(label string, data []byte) {
		if _, err := env.chain.Submit(context.Background(), chain.Action{Label: label, To: probe, Data: data}); err != nil {
			t.Fatalf("%s submit: %v", label, err)
		}
	}
	if err := env.chain.ResyncNonce(context.Background()); err != nil {
		t.Fatalf("resync: %v", err)
	}
	seed("setEngineSafe", append(crypto.Keccak256([]byte("setEngineSafe(address)"))[:4], encodeAddr(probe)...))
	seed("setBal-0", chain.PackUintCall("setBal(uint256)", big.NewInt(0)))
	seed("setPending", chain.PackUintCall("setPending(uint256)", bigStr("100000000000000000000")))
	seed("setMaxSell", chain.PackUintCall("setMaxSell(uint256)", bigStr("300000000000000000000")))
	seed("setStrike", chain.PackUintCall("setStrike(uint256)", big.NewInt(500000)))

	// Fake Quoter: $0.02 price (full tier), $1/HYDX out, 50e18 shares.
	q := &fakeQuoter{
		priceUsdc:   big.NewInt(20000),
		usdcPerHydx: bigStr("1000000"),
		shares:      bigStr("50000000000000000000"),
		zipIsToken0: true, // sim asserts token0-side addLiquidity(expectedZip, 0, minShares)
	}
	j := NewStrikeLoopJob(StrikeLoopConfig{
		Harvest: probe, FarmUtility: probe, Exercise: probe, Sell: probe, Recycle: probe, Lp: probe,
		Quoter:             q,
		CushionBps:         200,
		AmberFractionBps:   5000,
		RecycleFractionBps: 10000,
		HaltPriceUsdc:      15000,
		AmberPriceUsdc:     18000,
		DeadlineBuffer:     300 * time.Second,
		MaxBorrowPerCycle:  bigStr("1000000000000"),
	})
	j.clock = fixedClock(2_000_000)

	runner := NewRunner(env.chain, []Job{j}, 10*time.Millisecond, quietLogger())
	ctx, cancel := context.WithCancel(context.Background())
	doneRun := make(chan struct{})
	go func() { runner.Run(ctx); close(doneRun) }()

	// Wait until all 9 legs are recorded.
	waitFor(t, func() bool {
		n, err := chain.CallUint(context.Background(), env.chain, probe, "recordCount()")
		return err == nil && n.Uint64() >= 9
	})
	cancel()
	<-doneRun

	// Expected ordered (selector, args).
	expExZip := new(big.Int).Mul(big.NewInt(97490000), bigStr("1000000000000")) // recycleAmount*1e12
	deadline := big.NewInt(2_000_000 + 300)
	type want struct {
		sig        string
		a0, a1, a2 *big.Int
	}
	wants := []want{
		{"claimReward()", big.NewInt(0), big.NewInt(0), big.NewInt(0)},
		{"borrow(uint256)", big.NewInt(510000), big.NewInt(0), big.NewInt(0)},
		{"exercise(uint256,uint256,uint256)", bigStr("100000000000000000000"), big.NewInt(510000), deadline},
		{"sellHydx(uint256,uint256,uint256)", bigStr("100000000000000000000"), big.NewInt(98000000), deadline},
		{"repay(uint256)", big.NewInt(510000), big.NewInt(0), big.NewInt(0)},
		{"creditFreeValue(uint256)", big.NewInt(97490000), big.NewInt(0), big.NewInt(0)},
		{"recycle(uint256)", big.NewInt(97490000), big.NewInt(0), big.NewInt(0)},
		{"addLiquidity(uint256,uint256,uint256)", expExZip, big.NewInt(0), bigStr("49000000000000000000")},
		{"stake(uint256)", bigStr("49000000000000000000"), big.NewInt(0), big.NewInt(0)},
	}

	n, err := chain.CallUint(context.Background(), env.chain, probe, "recordCount()")
	if err != nil {
		t.Fatalf("recordCount: %v", err)
	}
	if int(n.Uint64()) != len(wants) {
		t.Fatalf("recordCount = %d, want %d", n.Uint64(), len(wants))
	}

	for i, w := range wants {
		gotSel, a0, a1, a2 := readRecord(t, env.chain, probe, i)
		wantSel := sel4(w.sig)
		if gotSel != wantSel {
			t.Errorf("record[%d] selector = %x, want %x (%s)", i, gotSel, wantSel, w.sig)
		}
		if a0.Cmp(w.a0) != 0 || a1.Cmp(w.a1) != 0 || a2.Cmp(w.a2) != 0 {
			t.Errorf("record[%d] (%s) args = [%s %s %s], want [%s %s %s]", i, w.sig, a0, a1, a2, w.a0, w.a1, w.a2)
		}
	}
}

// readRecord calls probe.record(i) → (bytes4 sel, uint256 a0, uint256 a1, uint256 a2).
func readRecord(t *testing.T, r chain.Reader, probe common.Address, i int) ([4]byte, *big.Int, *big.Int, *big.Int) {
	t.Helper()
	data := chain.PackUintCall("record(uint256)", big.NewInt(int64(i)))
	out, err := r.CallContract(context.Background(), ethereum.CallMsg{To: &probe, Data: data}, nil)
	if err != nil {
		t.Fatalf("record(%d): %v", i, err)
	}
	b4, _ := abi.NewType("bytes4", "", nil)
	u, _ := abi.NewType("uint256", "", nil)
	vals, err := abi.Arguments{{Type: b4}, {Type: u}, {Type: u}, {Type: u}}.Unpack(out)
	if err != nil {
		t.Fatalf("decode record(%d): %v", i, err)
	}
	return vals[0].([4]byte), vals[1].(*big.Int), vals[2].(*big.Int), vals[3].(*big.Int)
}

// TestStrikeLoop_SimStrandedDebt_RepaysAndDoesNotBorrow is the end-to-end half of the self-heal guard.
// The probe is seeded with a live outstandingDebt() — the state an aborted tick leaves behind, since the
// Runner stops a Plan on the first action error (job.go:85-99) and borrow sits four legs ahead of repay.
// The Job must submit repay(debt) and NOTHING else: no claimReward, and above all no borrow, which would
// ratchet the debt higher every tick.
func TestStrikeLoop_SimStrandedDebt_RepaysAndDoesNotBorrow(t *testing.T) {
	env := newSimEnv(t, false)
	probe := env.deployProbe(env.sim.Client(), strikeLoopProbeBytecode)

	seed := func(label string, data []byte) {
		if _, err := env.chain.Submit(context.Background(), chain.Action{Label: label, To: probe, Data: data}); err != nil {
			t.Fatalf("%s submit: %v", label, err)
		}
	}
	if err := env.chain.ResyncNonce(context.Background()); err != nil {
		t.Fatalf("resync: %v", err)
	}
	seed("setEngineSafe", append(crypto.Keccak256([]byte("setEngineSafe(address)"))[:4], encodeAddr(probe)...))
	seed("setBal-0", chain.PackUintCall("setBal(uint256)", big.NewInt(0)))
	seed("setPending", chain.PackUintCall("setPending(uint256)", bigStr("100000000000000000000")))
	seed("setMaxSell", chain.PackUintCall("setMaxSell(uint256)", bigStr("300000000000000000000")))
	seed("setStrike", chain.PackUintCall("setStrike(uint256)", big.NewInt(500000)))

	// The state an aborted tick leaves behind: 12,345 USDC borrowed and never repaid.
	stranded := bigStr("12345000000")
	seed("setDebt", chain.PackUintCall("setDebt(uint256)", stranded))

	j := NewStrikeLoopJob(StrikeLoopConfig{
		Harvest: probe, FarmUtility: probe, Exercise: probe, Sell: probe, Recycle: probe, Lp: probe,
		Quoter:             &fakeQuoter{priceUsdc: big.NewInt(20000), usdcPerHydx: bigStr("1000000"), shares: big.NewInt(1)},
		CushionBps:         200,
		AmberFractionBps:   5000,
		RecycleFractionBps: 10000,
		HaltPriceUsdc:      15000,
		AmberPriceUsdc:     18000,
		DeadlineBuffer:     300 * time.Second,
		MaxBorrowPerCycle:  bigStr("1000000000000"),
	})

	plan, err := j.Evaluate(context.Background(), env.sim.Client())
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("expected exactly one action (repay), got %v", labels(plan))
	}
	if plan.Actions[0].Label != "repayStrandedDebt" {
		t.Fatalf("expected repayStrandedDebt, got %q", plan.Actions[0].Label)
	}
	for _, a := range plan.Actions {
		if a.Label == "borrow" {
			t.Fatal("borrowed on top of stranded debt — the ratchet this guard exists to stop")
		}
	}
	want := chain.PackUintCall("repay(uint256)", stranded)
	if string(plan.Actions[0].Data) != string(want) {
		t.Fatalf("repay calldata:\n got %x\nwant %x", plan.Actions[0].Data, want)
	}
}
