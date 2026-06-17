// Command keeper is the (K) read→compute→submit spine: the single immutable CRE
// operator's off-chain embodiment (§8.7/§13). NOT a wasip1 workflow — a native
// go-ethereum service that submits ordinary txs. See build/tickets/cre/CRE-OPS-ROUTING.md.
package main

import (
	"context"
	"log/slog"
	"math/big"
	"os"
	"os/signal"
	"syscall"

	"github.com/ethereum/go-ethereum/ethclient"

	"cre-keeper/internal/chain"
	"cre-keeper/internal/config"
	"cre-keeper/internal/job"
	"cre-keeper/internal/keymgr"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	if err := run(log); err != nil {
		log.Error("keeper exiting", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	// 1. config + key (fail-fast; key never logged).
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	signer, err := keymgr.Load()
	if err != nil {
		return err
	}
	log.Info("loaded operator key", "address", signer.Address().Hex())

	// 2. dial + chain client.
	client, err := ethclient.Dial(cfg.RPCURL)
	if err != nil {
		return err
	}
	chainID := new(big.Int).SetUint64(cfg.ChainID)
	c := chain.NewChain(client, chainID, signer, cfg)

	// 3. build the identity check list from config (re-pointable addresses, §17).
	reservoir, err := cfg.MustAddr("ReservoirLoopModule")
	if err != nil {
		return err
	}
	exitGate, err := cfg.MustAddr("ExitGate")
	if err != nil {
		return err
	}
	checks := []job.IdentityCheck{
		{Name: "ReservoirLoopModule", Addr: reservoir, AdminSig: "operator()"},
		{Name: "ExitGate", Addr: exitGate, AdminSig: "windowController()"},
	}
	identity := job.NewIdentityJob(signer.Address(), checks)

	// SIGINT/SIGTERM → graceful stop.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// 4. startup invariant (§8.7): refuse to run with the wrong key / operator==owner.
	if _, err := identity.Evaluate(ctx, c); err != nil {
		return err
	}
	log.Info("startup identity assertion passed",
		"ReservoirLoopModule", reservoir.Hex(), "ExitGate", exitGate.Hex())

	// 5. register IdentityJob as a heartbeat and run the loop.
	runner := job.NewRunner(c, []job.Job{identity}, cfg.PollInterval, log)
	runner.Run(ctx)
	return nil
}
