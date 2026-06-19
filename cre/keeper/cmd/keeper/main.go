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
	"time"

	"github.com/ethereum/go-ethereum/ethclient"

	"cre-keeper/internal/chain"
	"cre-keeper/internal/config"
	"cre-keeper/internal/job"
	"cre-keeper/internal/keymgr"
	"cre-keeper/internal/quote"
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
	exitGate, err := cfg.MustAddr("ExitGate")
	if err != nil {
		return err
	}
	// The six StrikeLoopJob engine modules (KEEPER-01b). Each exposes operator()
	// and is driven state-changingly by the harvest loop — a wrong key fails fast
	// at startup (§8.7).
	harvest, err := cfg.MustAddr("HarvestVoteModule")
	if err != nil {
		return err
	}
	reservoir, err := cfg.MustAddr("ReservoirLoopModule")
	if err != nil {
		return err
	}
	exerciseMod, err := cfg.MustAddr("ExerciseModule")
	if err != nil {
		return err
	}
	sellMod, err := cfg.MustAddr("SellModule")
	if err != nil {
		return err
	}
	recycleMod, err := cfg.MustAddr("RecycleModule")
	if err != nil {
		return err
	}
	lpMod, err := cfg.MustAddr("LpStrategyModule")
	if err != nil {
		return err
	}
	checks := []job.IdentityCheck{
		{Name: "ExitGate", Addr: exitGate, AdminSig: "windowController()"},
		{Name: "HarvestVoteModule", Addr: harvest, AdminSig: "operator()"},
		{Name: "ReservoirLoopModule", Addr: reservoir, AdminSig: "operator()"},
		{Name: "ExerciseModule", Addr: exerciseMod, AdminSig: "operator()"},
		{Name: "SellModule", Addr: sellMod, AdminSig: "operator()"},
		{Name: "RecycleModule", Addr: recycleMod, AdminSig: "operator()"},
		{Name: "LpStrategyModule", Addr: lpMod, AdminSig: "operator()"},
	}
	identity := job.NewIdentityJob(signer.Address(), checks)

	// Burn job: retire szipUSD the engine Safe bought below NAV (8-B14). ExitGate
	// addr reused from MustAddr above; floor from cfg.MinBurnAmount (0 = any fill).
	burn := job.NewBurnJob(exitGate, cfg.MinBurnAmount)

	// Strike-loop job (KEEPER-01b): the auto-compounder harvest loop — the new
	// primary job, registered AFTER the burn. The HYDX/USDC pool address comes from
	// config (KEEPER_ADDR_HydxUsdcPool); the LP vault's pool is read off the vault.
	hydxUsdcPool, err := cfg.MustAddr("HydxUsdcPool")
	if err != nil {
		return err
	}
	maxBorrow, err := cfg.MustMaxBorrowPerCycle()
	if err != nil {
		return err
	}
	quoter := quote.NewProdQuoter(c, hydxUsdcPool, uint32(cfg.TwapPeriod/time.Second))
	strikeLoop := job.NewStrikeLoopJob(job.StrikeLoopConfig{
		Harvest:            harvest,
		Reservoir:          reservoir,
		Exercise:           exerciseMod,
		Sell:               sellMod,
		Recycle:            recycleMod,
		Lp:                 lpMod,
		Quoter:             quoter,
		CushionBps:         cfg.CushionBps,
		AmberFractionBps:   cfg.AmberFractionBps,
		RecycleFractionBps: cfg.RecycleFractionBps,
		HaltPriceUsdc:      cfg.HaltPriceUsdc,
		AmberPriceUsdc:     cfg.AmberPriceUsdc,
		DeadlineBuffer:     cfg.DeadlineBuffer,
		MaxBorrowPerCycle:  maxBorrow,
	})

	// SIGINT/SIGTERM → graceful stop.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// 4. startup invariant (§8.7): refuse to run with the wrong key / operator==owner.
	if _, err := identity.Evaluate(ctx, c); err != nil {
		return err
	}
	log.Info("startup identity assertion passed",
		"ExitGate", exitGate.Hex(), "HarvestVoteModule", harvest.Hex(),
		"ReservoirLoopModule", reservoir.Hex(), "ExerciseModule", exerciseMod.Hex(),
		"SellModule", sellMod.Hex(), "RecycleModule", recycleMod.Hex(),
		"LpStrategyModule", lpMod.Hex())

	// 5. register the jobs (IdentityJob heartbeat first, then BurnJob, then the
	//    StrikeLoopJob harvest loop) and run the loop.
	runner := job.NewRunner(c, []job.Job{identity, burn, strikeLoop}, cfg.PollInterval, log)
	runner.Run(ctx)
	return nil
}
