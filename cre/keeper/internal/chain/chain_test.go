package chain

import (
	"context"
	"errors"
	"math/big"
	"sync"
	"testing"
	"time"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient/simulated"

	"cre-keeper/internal/config"
	"cre-keeper/internal/keymgr"
)

// OnlyOperatorProbe creation bytecode (forge solc 0.8.24) — verbatim from the ticket.
const probeBytecode = "0x608060405234801561000f575f80fd5b505f80546001600160a01b0319163317905561015a8061002e5f395ff3fe608060405234801561000f575f80fd5b506004361061003f575f3560e01c80633fa4f24514610043578063552410771461005f578063570ca73514610074575b5f80fd5b61004c60015481565b6040519081526020015b60405180910390f35b61007261006d36600461010d565b6100b8565b005b5f546100939073ffffffffffffffffffffffffffffffffffffffff1681565b60405173ffffffffffffffffffffffffffffffffffffffff9091168152602001610056565b5f5473ffffffffffffffffffffffffffffffffffffffff163314610108576040517f7c214f0400000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b600155565b5f6020828403121561011d575f80fd5b503591905056fea2646970667358221220156c220f7fa39b0e12cc3a92ba44606f4c7f61d45dafc8ee52705be05efcfded64736f6c63430008180033"

// simulated.NewBackend hardcodes chainID 1337.
var simChainID = big.NewInt(1337)

// anvil acct #3 — the operator the probe records as its operator() in its ctor
// (the deployer == msg.sender).
const operatorKey = "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

// failBackend wraps a Backend to deterministically inject one failure for the
// nonce-gap regression. failSendOnce: SendTransaction returns an error the first
// time it is called (without touching the chain).
type failBackend struct {
	Backend
	failSendOnce bool
}

func (f *failBackend) SendTransaction(ctx context.Context, tx *types.Transaction) error {
	if f.failSendOnce {
		f.failSendOnce = false
		return errors.New("injected send failure")
	}
	return f.Backend.SendTransaction(ctx, tx)
}

// testRig bundles the simulated backend, the chain client, and the deployed probe.
type testRig struct {
	t       *testing.T
	backend *simulated.Backend
	chain   *Chain
	signer  *keymgr.Signer
	probe   common.Address
	stopFn  func()
}

func newRig(t *testing.T, b Backend) (*Chain, *keymgr.Signer) {
	t.Helper()
	signer, err := keymgr.LoadHex(operatorKey)
	if err != nil {
		t.Fatalf("load key: %v", err)
	}
	cfg := &config.Config{
		GasBufferBps:     3000,
		FeeCapMultiplier: 2,
		ConfirmTimeout:   30 * time.Second,
	}
	return NewChain(b, simChainID, signer, cfg), signer
}

// setupRig spins a simulated backend funded for the operator, an auto-commit
// goroutine, the Chain, and a deployed OnlyOperatorProbe.
func setupRig(t *testing.T, b Backend, sim *simulated.Backend) *testRig {
	t.Helper()
	c, signer := newRig(t, b)

	// Auto-commit goroutine: the backend mines only on Commit() (no auto-mine),
	// so spin one to resolve Submit's receipt poll. Standard pattern.
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
	stop := func() { stopOnce.Do(func() { close(done); <-exited }) } // wait for the committer before any Close

	rig := &testRig{t: t, backend: sim, chain: c, signer: signer, stopFn: stop}
	rig.probe = rig.deployProbe()
	return rig
}

// deployProbe deploys OnlyOperatorProbe with a one-off RAW deploy tx (To:nil) —
// deploy is NOT a Submit path (Submit always has To).
func (r *testRig) deployProbe() common.Address {
	r.t.Helper()
	ctx := context.Background()
	from := r.signer.Address()

	nonce, err := r.chain.backend.PendingNonceAt(ctx, from)
	if err != nil {
		r.t.Fatalf("nonce: %v", err)
	}
	tip, err := r.chain.backend.SuggestGasTipCap(ctx)
	if err != nil {
		r.t.Fatalf("tip: %v", err)
	}
	head, err := r.chain.backend.HeaderByNumber(ctx, nil)
	if err != nil {
		r.t.Fatalf("head: %v", err)
	}
	maxFee := new(big.Int).Add(new(big.Int).Mul(head.BaseFee, big.NewInt(2)), tip)

	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   simChainID,
		Nonce:     nonce,
		GasTipCap: tip,
		GasFeeCap: maxFee,
		Gas:       1_000_000,
		To:        nil, // deploy
		Data:      common.FromHex(probeBytecode),
	})
	signed, err := r.signer.SignTx(tx, simChainID)
	if err != nil {
		r.t.Fatalf("sign deploy: %v", err)
	}
	if err := r.chain.backend.SendTransaction(ctx, signed); err != nil {
		r.t.Fatalf("send deploy: %v", err)
	}
	receipt := r.waitReceipt(signed.Hash())
	if receipt.Status != types.ReceiptStatusSuccessful {
		r.t.Fatalf("deploy reverted")
	}
	if receipt.ContractAddress == (common.Address{}) {
		r.t.Fatalf("no contract address")
	}
	return receipt.ContractAddress
}

func (r *testRig) waitReceipt(h common.Hash) *types.Receipt {
	r.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		rc, err := r.chain.backend.TransactionReceipt(context.Background(), h)
		if err == nil && rc != nil {
			return rc
		}
		if time.Now().After(deadline) {
			r.t.Fatalf("timeout waiting for receipt %s", h.Hex())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func setValueData(v uint64) []byte {
	u256, _ := abi.NewType("uint256", "", nil)
	packed, _ := abi.Arguments{{Type: u256}}.Pack(new(big.Int).SetUint64(v))
	return append(selector("setValue(uint256)"), packed...)
}

func newSim(t *testing.T, operator common.Address) (*simulated.Backend, Backend) {
	t.Helper()
	big := new(big.Int)
	big.SetString("1000000000000000000000", 10) // 1000 ETH
	sim := simulated.NewBackend(types.GenesisAlloc{
		operator: {Balance: big},
	})
	t.Cleanup(func() { sim.Close() })
	return sim, sim.Client()
}

func TestSubmit_SetValue_Spine(t *testing.T) {
	signer, err := keymgr.LoadHex(operatorKey)
	if err != nil {
		t.Fatalf("load key: %v", err)
	}
	sim, client := newSim(t, signer.Address())
	rig := setupRig(t, client, sim)
	defer rig.stopFn()

	ctx := context.Background()
	if err := rig.chain.ResyncNonce(ctx); err != nil {
		t.Fatalf("resync: %v", err)
	}

	// Capture the raw estimate to prove the buffer was applied.
	rawEst, err := client.EstimateGas(ctx, ethereum.CallMsg{
		From: signer.Address(), To: &rig.probe, Data: setValueData(42),
	})
	if err != nil {
		t.Fatalf("raw estimate: %v", err)
	}

	receipt, err := rig.chain.Submit(ctx, Action{
		Label: "setValue(42)", To: rig.probe, Data: setValueData(42),
	})
	if err != nil {
		t.Fatalf("submit setValue: %v", err)
	}
	if receipt.GasUsed == 0 {
		t.Fatalf("no gas used")
	}
	// The submitted tx's gas LIMIT must exceed the raw estimate (buffer applied).
	tx, _, err := rig.lookupTx(receipt.TxHash)
	if err != nil {
		t.Fatalf("lookup tx: %v", err)
	}
	if tx.Gas() <= rawEst {
		t.Errorf("gas buffer not applied: limit %d <= raw estimate %d", tx.Gas(), rawEst)
	}

	// value() == 42
	got, err := CallUint(ctx, rig.chain, rig.probe, "value()")
	if err != nil {
		t.Fatalf("CallUint value(): %v", err)
	}
	if got.Uint64() != 42 {
		t.Errorf("value() = %d, want 42", got.Uint64())
	}

	// Read round-trips: operator() == operator; value() == 42 (above).
	op, err := CallAddress(ctx, rig.chain, rig.probe, "operator()")
	if err != nil {
		t.Fatalf("CallAddress operator(): %v", err)
	}
	if op != signer.Address() {
		t.Errorf("operator() = %s, want %s", op.Hex(), signer.Address().Hex())
	}
}

func TestSubmit_TwoActionPlan_ConsecutiveNonces(t *testing.T) {
	signer, err := keymgr.LoadHex(operatorKey)
	if err != nil {
		t.Fatalf("load key: %v", err)
	}
	sim, client := newSim(t, signer.Address())
	rig := setupRig(t, client, sim)
	defer rig.stopFn()

	ctx := context.Background()
	if err := rig.chain.ResyncNonce(ctx); err != nil {
		t.Fatalf("resync: %v", err)
	}

	r1, err := rig.chain.Submit(ctx, Action{Label: "a1", To: rig.probe, Data: setValueData(7)})
	if err != nil {
		t.Fatalf("action 1: %v", err)
	}
	r2, err := rig.chain.Submit(ctx, Action{Label: "a2", To: rig.probe, Data: setValueData(9)})
	if err != nil {
		t.Fatalf("action 2: %v", err)
	}

	tx1, _, _ := rig.lookupTx(r1.TxHash)
	tx2, _, _ := rig.lookupTx(r2.TxHash)
	if tx2.Nonce() != tx1.Nonce()+1 {
		t.Errorf("nonces not consecutive: %d then %d", tx1.Nonce(), tx2.Nonce())
	}

	got, _ := CallUint(ctx, rig.chain, rig.probe, "value()")
	if got.Uint64() != 9 {
		t.Errorf("final value() = %d, want 9", got.Uint64())
	}
}

// TestSubmit_NonceGapRegression: a failed SendTransaction must NOT advance the
// local nonce, so the follow-up Action reuses the same slot (no gap nonce).
func TestSubmit_NonceGapRegression(t *testing.T) {
	signer, err := keymgr.LoadHex(operatorKey)
	if err != nil {
		t.Fatalf("load key: %v", err)
	}
	sim, client := newSim(t, signer.Address())

	// Deploy via a plain rig first (no fail injection) so the probe exists.
	rig := setupRig(t, client, sim)
	defer rig.stopFn()
	ctx := context.Background()

	// Now wrap the SAME backend with a one-shot send failure and rebuild the chain.
	fb := &failBackend{Backend: client, failSendOnce: true}
	c, _ := newRig(t, fb)
	if err := c.ResyncNonce(ctx); err != nil {
		t.Fatalf("resync: %v", err)
	}
	nonceBefore := c.nonce

	// This Submit's send is forced to fail → nonce must NOT advance.
	if _, err := c.Submit(ctx, Action{Label: "fails", To: rig.probe, Data: setValueData(1)}); err == nil {
		t.Fatal("expected forced send failure")
	}
	if c.nonce != nonceBefore {
		t.Fatalf("nonce advanced on failed send: %d -> %d", nonceBefore, c.nonce)
	}

	// The follow-up succeeds and must use the SAME nonce the failed one would have.
	receipt, err := c.Submit(ctx, Action{Label: "succeeds", To: rig.probe, Data: setValueData(99)})
	if err != nil {
		t.Fatalf("follow-up submit: %v", err)
	}
	tx, _, _ := rig.lookupTx(receipt.TxHash)
	if tx.Nonce() != nonceBefore {
		t.Errorf("follow-up used nonce %d, want %d (no gap)", tx.Nonce(), nonceBefore)
	}
}

func (r *testRig) lookupTx(h common.Hash) (*types.Transaction, bool, error) {
	return r.backend.Client().TransactionByHash(context.Background(), h)
}
