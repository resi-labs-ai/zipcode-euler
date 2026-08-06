package job

import (
	"bytes"
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
//
// FILL-TRIGGERED (ratified 2026-07-28, replacing the old any-balance floor): the
// burn fires only on EVIDENCE OF A FILL — GPv2Settlement.filledAmount(uid) for
// the module's live/last bid uid, a mapping a szipUSD donor cannot touch. A
// stranger dust-donating szipUSD to the Safe therefore never costs the keeper a
// tx ("let the dusters dust"): the donation sits — already excluded from the NAV
// denominator, so it distorts nothing — until the next real fill sweeps the FULL
// balance (loot + any dust) in one burn. The old KEEPER_MIN_BURN_AMOUNT floor is
// gone: within a fill-evidenced burn there is no configurable "keep some ghost
// shares" mode — the whole balance burns, every time.
//
// STATE (deliberate exception to the stateless-poll doctrine, safe under the
// single-threaded Runner): lastUid (the bid uid being tracked) and lastFilled
// (the filledAmount already acted on, LATCHED ONLY WHEN THE BALANCE IS OBSERVED
// EMPTY). Latch-on-empty makes a failed submit self-heal: until a burn actually
// drains the Safe, filled > lastFilled keeps re-emitting the plan. On a keeper
// restart the state re-learns from the live bid; a pre-restart balance with no
// live bid waits for the next round's fill — harmless, the oracle already
// excludes it.
type BurnJob struct {
	exitGate common.Address
	buyBurn  common.Address

	lastUid    []byte
	lastFilled *big.Int
}

// NewBurnJob builds the burn job. exitGate is the ExitGate address; buyBurn is
// the SzipBuyBurnModule (the bid uid + settlement source). Both re-pointable,
// from cfg.MustAddr.
func NewBurnJob(exitGate, buyBurn common.Address) *BurnJob {
	return &BurnJob{exitGate: exitGate, buyBurn: buyBurn, lastFilled: big.NewInt(0)}
}

// Name implements Job.
func (j *BurnJob) Name() string { return "burn" }

// Evaluate reads the engine Safe's szipUSD balance via the Gate's own views and,
// if a NOT-YET-ACTED-ON fill is evidenced on the tracked bid uid, returns a
// one-Action Plan calling ExitGate.burnFor(fullBalance). Read-only: it never
// submits (the spine does, K4).
//
// Re-read addresses each tick — §17 re-pointable; do NOT cache shareToken /
// engineSafe / settlement across ticks (a Timelock re-point must take effect).
func (j *BurnJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	// 1. shareToken (= szipUSD), read via the Gate — never hard-coded.
	shareToken, err := chain.CallAddress(ctx, r, j.exitGate, "shareToken()")
	if err != nil {
		// Propagate read errors (RPC failure): the Runner logs + continues (fail-safe).
		return chain.Plan{}, err
	}

	// 2. juniorTrancheEngine. If unwired (zero), no-op (NOT an error): burnFor would
	//    revert NotWired. (§7: juniorTrancheEngine resolves to the main/rq Safe — one
	//    address, two role names; the mechanic is identical.)
	//
	//    The getter is juniorTrancheEngine(), NOT engineSafe(). ExitGate renamed the slot
	//    (ExitGate.sol:53) but kept the OLD word in its event name (EngineSafeSet, :72),
	//    which is how this straggler survived: strike_loop_job.go and winddown_lp_job.go
	//    were both updated, this one was not. ExitGate has no fallback/receive, so the
	//    retired selector REVERTED — every tick errored and no burn plan was ever produced.
	engineSafe, err := chain.CallAddress(ctx, r, j.exitGate, "juniorTrancheEngine()")
	if err != nil {
		return chain.Plan{}, err
	}
	if engineSafe == (common.Address{}) {
		return chain.Plan{}, nil
	}

	// 3. the pre-burn balance = the engine Safe's szipUSD.
	bal, err := chain.CallUintWithAddr(ctx, r, shareToken, "balanceOf(address)", engineSafe)
	if err != nil {
		return chain.Plan{}, err
	}

	// 4. track the live bid uid: a NEW uid resets the fill latch (each posted bid
	//    starts unfilled). An EMPTY uid keeps the last one — fills can land and the
	//    bid then cancel/expire; filledAmount(lastUid) stays queryable forever.
	uid, _, err := chain.CallBytesUint(ctx, r, j.buyBurn, "currentBid()")
	if err != nil {
		return chain.Plan{}, err
	}
	if len(uid) != 0 && !bytes.Equal(uid, j.lastUid) {
		j.lastUid = append([]byte(nil), uid...)
		j.lastFilled = big.NewInt(0)
	}

	// 5. no uid ever observed ⇒ no fill evidence possible ⇒ no-op (a balance —
	//    necessarily donations or a pre-restart remainder — waits for the next
	//    round's fill; the oracle already excludes it).
	if len(j.lastUid) == 0 {
		return chain.Plan{}, nil
	}

	// 6. fill evidence: the settlement's cumulative filledAmount for the tracked
	//    uid — donor-untouchable (only solver settlements write it). The
	//    settlement address is read LIVE off the module (§17).
	settlement, err := chain.CallAddress(ctx, r, j.buyBurn, "settlement()")
	if err != nil {
		return chain.Plan{}, err
	}
	filled, err := chain.CallUintWithBytes(ctx, r, settlement, "filledAmount(bytes)", j.lastUid)
	if err != nil {
		return chain.Plan{}, err
	}

	// 7. balance empty ⇒ LATCH (the burn that drained it has mined — or there was
	//    nothing to do) and no-op. Latching only here (never at plan emission)
	//    makes a failed submit retry naturally next tick.
	if bal.Sign() == 0 {
		j.lastFilled = filled
		return chain.Plan{}, nil
	}

	// 8. balance present but NO new fill since the latch ⇒ dust/donations only —
	//    sit. ("Let the dusters dust": no gas is ever spent on a donor's schedule.)
	if filled.Cmp(j.lastFilled) <= 0 {
		return chain.Plan{}, nil
	}

	// 9. Burn the FULL engine-Safe balance (bal) — loot + any dust that rode along.
	//    Rationale for full-balance (unchanged): burnFor also burns `amount` Loot
	//    from the Gate; the invariant szipUSD.totalSupply() == Loot.balanceOf(gate)
	//    (ExitGate.sol:30-32) makes Loot(gate) ≥ balanceOf(engineSafe) always, so
	//    the Loot side cannot under-flow. If it ever did, EstimateGas (the spine's
	//    dry-run, KEEPER-00 K3) catches the revert → no send → retry next tick.
	//
	// GasLimit 0 ⇒ the spine estimates; EstimateGas doubles as a dry-run (K3).
	//
	// ⚠️ NO-DOUBLE-BURN is a property of the SYNCHRONOUS spine — load-bearing.
	//    chain.Submit blocks on the receipt (KEEPER-00 K3) and the Runner is
	//    single-threaded, so a burn tx fully mines (draining the Safe's szipUSD)
	//    BEFORE the next Evaluate reads the balance — which then sees 0, latches
	//    lastFilled (step 7), and no-ops. If a future change makes submission
	//    async/parallel, the double-burn window reopens and this job needs an
	//    explicit pending-burn guard.
	//
	// Re-point race (rare, self-correcting — noted, not gated): the reads above are
	// separate eth_calls; a Timelock re-point landing mid-Evaluate could mix old
	// and new wiring for one tick. The dry-run catches any resulting revert →
	// retry next tick — a rare governance event, never an unsafe burn.
	return chain.Plan{Actions: []chain.Action{{
		Label: "burnFor",
		To:    j.exitGate,
		Data:  chain.PackUintCall("burnFor(uint256)", bal),
	}}}, nil
}
