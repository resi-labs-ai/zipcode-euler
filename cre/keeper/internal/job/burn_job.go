package job

import (
	"context"
	"math/big"

	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
)

// BurnJob is the burn half of the hybrid buy-burn cycle (§7 / 8-B14): a CoW fill
// lands szipUSD in the engine Safe, and this job retires it via
// ExitGate.burnFor(amount) (onlyWindowController). "Pure supply reduction, NO
// asset payout … NAV-per-share ticks up for stayers" (ExitGate.sol:197-206).
//
// Why NO coverage/freshness gate (unlike the bid): SzipNavOracle._effectiveSupply
// EXCLUDES the engine Safe's pre-burn szipUSD (SzipNavOracle.sol:608-613), and
// that is the per-share denominator (spotNavPerShare():474) — so a lagging or
// missed burn cannot dilute or inflate NAV-per-share. The burn is housekeeping,
// not a price-affecting step; gating it would be wrong, not safer.
type BurnJob struct {
	exitGate common.Address
	minBurn  *big.Int
}

// NewBurnJob builds the burn job. exitGate is the ExitGate address (re-pointable,
// from cfg.MustAddr("ExitGate")); minBurn is the config floor (0 = burn any
// non-zero fill).
func NewBurnJob(exitGate common.Address, minBurn *big.Int) *BurnJob {
	return &BurnJob{exitGate: exitGate, minBurn: minBurn}
}

// Name implements Job.
func (j *BurnJob) Name() string { return "burn" }

// Evaluate reads the engine Safe's szipUSD balance via the Gate's own views and,
// if a fill ≥ the floor is present, returns a one-Action Plan calling
// ExitGate.burnFor(balance). Read-only: it never submits (the spine does, K4).
//
// Re-read addresses each tick — §17 re-pointable; do NOT cache shareToken /
// engineSafe across ticks (a Timelock setShareToken/setEngineSafe must take
// effect).
func (j *BurnJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	// 1. shareToken (= szipUSD), read via the Gate — never hard-coded.
	shareToken, err := chain.CallAddress(ctx, r, j.exitGate, "shareToken()")
	if err != nil {
		// Propagate read errors (RPC failure): the Runner logs + continues (fail-safe).
		return chain.Plan{}, err
	}

	// 2. engineSafe. If unwired (zero), no-op (NOT an error): burnFor would revert
	//    NotWired. (§7: there may be no separate engine Safe — engineSafe() may
	//    resolve to the same address as the main/rq Safe; harmless, the mechanic
	//    is identical.)
	engineSafe, err := chain.CallAddress(ctx, r, j.exitGate, "engineSafe()")
	if err != nil {
		return chain.Plan{}, err
	}
	if engineSafe == (common.Address{}) {
		return chain.Plan{}, nil
	}

	// 3. the fill amount = the engine Safe's szipUSD balance.
	bal, err := chain.CallUintWithAddr(ctx, r, shareToken, "balanceOf(address)", engineSafe)
	if err != nil {
		return chain.Plan{}, err
	}

	// 4. no fill / below floor ⇒ no-op (empty plan, nil error).
	if bal.Sign() == 0 || bal.Cmp(j.minBurn) < 0 {
		return chain.Plan{}, nil
	}

	// 5. Burn the FULL engine-Safe balance (bal), NOT a min with the Gate's Loot.
	//    Rationale: burnFor also burns `amount` Loot from the Gate, requiring
	//    Loot.balanceOf(gate) ≥ amount. By construction the Gate is the sole Loot
	//    minter/custodian and mints Loot to itself 1:1 with each szipUSD share
	//    (ExitGate.sol:172-173); the invariant szipUSD.totalSupply() ==
	//    Loot.balanceOf(gate) holds at all times (ExitGate.sol:30-32), and the
	//    engine Safe's szipUSD is a SUBSET of that supply — so
	//    Loot(gate) ≥ balanceOf(engineSafe) always holds and the burn cannot
	//    under-flow the Loot side. (A CoW fill only MOVES already-minted szipUSD
	//    into the engine Safe; the paired soulbound Loot was minted to the Gate at
	//    the original deposit and never leaves.) If the invariant were ever
	//    violated, EstimateGas (the spine's dry-run, KEEPER-00 K3) catches the
	//    revert → no send, no nonce advance → retry next tick with a freshly-read
	//    balance — genuine recovery, never an unsafe partial state.
	//
	// GasLimit 0 ⇒ the spine estimates; EstimateGas doubles as a dry-run (K3).
	//
	// ⚠️ NO-DOUBLE-BURN is a property of the SYNCHRONOUS spine — load-bearing.
	//    chain.Submit blocks on the receipt (KEEPER-00 K3) and the Runner is
	//    single-threaded (jobs run sequentially per tick), so a burn tx fully
	//    mines (draining the engine Safe's szipUSD, ExitGate.sol:204) BEFORE the
	//    next Evaluate reads the balance — which then sees 0 → empty plan. There
	//    is no in-flight window for a duplicate burnFor, so NO in-flight guard is
	//    needed. This safety rests on Submit being synchronous + the Runner
	//    single-threaded: if a future change makes submission async/parallel, the
	//    double-burn window reopens and this job needs an explicit pending-burn
	//    guard.
	//
	// Re-point race (rare, self-correcting — noted, not gated): shareToken() /
	// engineSafe() / balanceOf are three separate eth_calls; a Timelock re-point
	// landing mid-Evaluate could read a balance on the old token while burnFor
	// burns via the live shareToken at execution. The dry-run catches the size
	// mismatch → retry next tick — a rare governance event, never an unsafe burn.
	return chain.Plan{Actions: []chain.Action{{
		Label: "burnFor",
		To:    j.exitGate,
		Data:  chain.PackUintCall("burnFor(uint256)", bal),
	}}}, nil
}
