// Package chain is the keeper's go-ethereum client seam: typed view-read helpers
// (read.go) and the nonce-safe submit spine (here). Action/Plan live here too
// (action.go) so chain.Submit can consume an Action without importing job (C1).
package chain

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"sync"
	"time"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"cre-keeper/internal/config"
	"cre-keeper/internal/keymgr"
)

// Backend is the minimal method set the submit spine + reads need. Both
// *ethclient.Client and the simulated.Client returned by
// (*simulated.Backend).Client() satisfy this (the simulated Client interface
// exposes the same method set; its impl embeds *ethclient.Client), which lets
// the spine be tested deterministically without anvil. Depend on this method
// set, NOT on extracting *ethclient.Client.
type Backend interface {
	CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error)
	PendingNonceAt(ctx context.Context, account common.Address) (uint64, error)
	SuggestGasTipCap(ctx context.Context) (*big.Int, error)
	HeaderByNumber(ctx context.Context, number *big.Int) (*types.Header, error)
	EstimateGas(ctx context.Context, call ethereum.CallMsg) (uint64, error)
	SendTransaction(ctx context.Context, tx *types.Transaction) error
	TransactionReceipt(ctx context.Context, txHash common.Hash) (*types.Receipt, error)
}

// Chain wraps a Backend with the operator signer and submit policy.
type Chain struct {
	backend          Backend
	privateBackend   Backend // optional MEV-protected send path (nil = none); only SendTransaction routes here
	chainID          *big.Int
	signer           *keymgr.Signer
	gasBufferBps     uint64
	feeCapMultiplier uint64
	confirmTimeout   time.Duration

	mu    sync.Mutex
	nonce uint64 // in-process counter, mutex-guarded
}

// NewChain constructs a Chain. cmd/keeper builds it (no unexported-field access
// across packages). chainID is stored as *big.Int (Config's uint64 → SetUint64).
func NewChain(backend Backend, chainID *big.Int, signer *keymgr.Signer, cfg *config.Config) *Chain {
	return &Chain{
		backend:          backend,
		chainID:          chainID,
		signer:           signer,
		gasBufferBps:     cfg.GasBufferBps,
		feeCapMultiplier: cfg.FeeCapMultiplier,
		confirmTimeout:   cfg.ConfirmTimeout,
	}
}

// SetPrivateBackend installs an OPTIONAL MEV-protected send path. When set, an
// Action with Private==true has ONLY its SendTransaction routed through b; nonce,
// fees, gas estimate, and the receipt poll all stay on the public backend (a
// private tx still lands on-chain, so the public backend observes the receipt).
func (c *Chain) SetPrivateBackend(b Backend) { c.privateBackend = b }

// CallContract lets Chain satisfy Reader (so jobs can read through it).
func (c *Chain) CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error) {
	return c.backend.CallContract(ctx, call, blockNumber)
}

// ResyncNonce sets the local counter to PendingNonceAt(signer). The Runner calls
// this once at the start of each tick so the counter tracks externally-landed
// txs / key rotation.
func (c *Chain) ResyncNonce(ctx context.Context) error {
	n, err := c.backend.PendingNonceAt(ctx, c.signer.Address())
	if err != nil {
		return fmt.Errorf("chain: resync nonce: %w", err)
	}
	c.mu.Lock()
	c.nonce = n
	c.mu.Unlock()
	return nil
}

// Submit performs nonce → EIP-1559 gas → sign → send → wait-receipt for one
// Action. It is nonce-safe: the local counter advances ONLY after a successful
// SendTransaction, so a failed estimate/send leaves the slot free for the next
// Action (no gap nonce). EstimateGas doubles as a dry-run: a revert returns the
// error WITHOUT sending and WITHOUT advancing the nonce.
//
// Private routing: ONLY the SendTransaction call is routed through the private
// backend, and only when action.Private && a private backend is configured.
// Nonce/fees/gas-estimate/receipt-poll all stay on the public backend — a private
// tx still lands on-chain, so the public backend observes the receipt.
func (c *Chain) Submit(ctx context.Context, action Action) (*types.Receipt, error) {
	// 1. nonce: read the current LOCAL counter under the mutex. Do NOT call
	//    PendingNonceAt per Action — ResyncNonce seeded it for the tick, and a
	//    per-Action PendingNonceAt would return the same nonce for a not-yet-mined
	//    predecessor and collide.
	c.mu.Lock()
	nonce := c.nonce
	c.mu.Unlock()

	from := c.signer.Address()

	// 2. fees
	tipCap, err := c.backend.SuggestGasTipCap(ctx)
	if err != nil {
		return nil, fmt.Errorf("chain: suggest gas tip cap: %w", err)
	}
	header, err := c.backend.HeaderByNumber(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("chain: header by number: %w", err)
	}
	baseFee := header.BaseFee
	if baseFee == nil {
		baseFee = new(big.Int)
	}
	// maxFee = baseFee*FeeCapMultiplier + tipCap (FeeCapMultiplier = base-fee
	// headroom knob; a transient spike past maxFee is a liveness stall, not a
	// safety bug).
	maxFee := new(big.Int).Mul(baseFee, new(big.Int).SetUint64(c.feeCapMultiplier))
	maxFee.Add(maxFee, tipCap)

	to := action.To

	// 3. gas limit (with EstimateGas as a dry-run)
	gasLimit := action.GasLimit
	if gasLimit == 0 {
		est, err := c.backend.EstimateGas(ctx, ethereum.CallMsg{From: from, To: &to, Data: action.Data})
		if err != nil {
			// The call would revert: do NOT send, do NOT advance the nonce.
			return nil, fmt.Errorf("chain: estimate gas (dry-run) for %q: %w", action.Label, err)
		}
		// gasLimit = est*(10000+GasBufferBps)/10000
		buffered := new(big.Int).SetUint64(est)
		buffered.Mul(buffered, new(big.Int).SetUint64(10000+c.gasBufferBps))
		buffered.Div(buffered, big.NewInt(10000))
		gasLimit = buffered.Uint64()
	}

	// 4. build + sign + send
	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   c.chainID,
		Nonce:     nonce,
		GasTipCap: tipCap,
		GasFeeCap: maxFee,
		Gas:       gasLimit,
		To:        &to, // production Submit ALWAYS sets To (it never deploys)
		Data:      action.Data,
	})
	signed, err := c.signer.SignTx(tx, c.chainID)
	if err != nil {
		return nil, fmt.Errorf("chain: sign tx for %q: %w", action.Label, err)
	}
	// Choose the send backend: the private one ONLY for a Private action when set.
	sendBackend := c.backend
	if action.Private && c.privateBackend != nil {
		sendBackend = c.privateBackend
	}
	if err := sendBackend.SendTransaction(ctx, signed); err != nil {
		// Failed send: leave the counter unchanged so the next Action reuses the slot.
		return nil, fmt.Errorf("chain: send tx for %q: %w", action.Label, err)
	}
	// Advance the local nonce ONLY after a successful send.
	c.mu.Lock()
	c.nonce = nonce + 1
	c.mu.Unlock()

	// 5. wait for the receipt; require Status == 1.
	return c.waitReceipt(ctx, signed.Hash(), action.Label)
}

func (c *Chain) waitReceipt(ctx context.Context, hash common.Hash, label string) (*types.Receipt, error) {
	deadline := time.Now().Add(c.confirmTimeout)
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		receipt, err := c.backend.TransactionReceipt(ctx, hash)
		if err == nil && receipt != nil {
			if receipt.Status != types.ReceiptStatusSuccessful {
				return receipt, fmt.Errorf("chain: tx reverted for %q (tx %s)", label, hash.Hex())
			}
			return receipt, nil
		}
		// ethereum.NotFound is expected until mined; surface anything else.
		if err != nil && !errors.Is(err, ethereum.NotFound) {
			return nil, fmt.Errorf("chain: receipt poll for %q (tx %s): %w", label, hash.Hex(), err)
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("chain: confirm timeout for %q (tx %s)", label, hash.Hex())
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}
