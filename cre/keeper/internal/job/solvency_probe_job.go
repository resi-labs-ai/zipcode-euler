package job

import (
	"context"
	"fmt"

	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
)

// SolvencyProbeJob is a read-only monitor over the SeniorNavAggregator. The
// aggregator's Σ views isolate a broken venue with try/catch: a pool whose
// views revert counts as ZERO backing instead of bricking the whole solvency
// read. That zero must never pass silently — this probe reads all three skip
// counters every tick and errors loudly (the Runner logs it) whenever any is
// nonzero, meaning that counter's aggregate is currently a conservative LOWER
// BOUND with at least one venue unreadable. One counter per aggregate because
// the legs break independently: maxWithdraw (the illiquid leg only) simulates
// withdrawal across every strategy, so its call surface strictly contains the
// senior leg's — a pool can break the illiquid Σ while seniorBacking stays
// complete, and unreadablePairs() alone would report that state as healthy.
// Always returns an empty Plan.
type SolvencyProbeJob struct {
	aggregator common.Address
}

// NewSolvencyProbeJob builds the probe.
func NewSolvencyProbeJob(aggregator common.Address) *SolvencyProbeJob {
	return &SolvencyProbeJob{aggregator: aggregator}
}

// Name implements Job.
func (j *SolvencyProbeJob) Name() string { return "solvency-probe" }

// solvencyCounters maps each skip-counter selector to the aggregate it covers,
// for the alarm text.
var solvencyCounters = []struct {
	selector string
	covers   string
}{
	{"unreadablePairs()", "seniorBacking/systemCollateralization"},
	{"unreadableIlliquidPairs()", "illiquidSeniorValue"},
	{"unreadableActivePairs()", "activeSeniorBacking"},
}

// Evaluate reads all three skip counters and errors when any venue is
// unreadable on any leg.
func (j *SolvencyProbeJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	for _, c := range solvencyCounters {
		skipped, err := chain.CallUint(ctx, r, j.aggregator, c.selector)
		if err != nil {
			return chain.Plan{}, fmt.Errorf("solvency-probe: reading %s on %s: %w", c.selector, j.aggregator.Hex(), err)
		}
		if skipped.Sign() != 0 {
			return chain.Plan{}, fmt.Errorf(
				"solvency-probe: %s venue pair(s) UNREADABLE on %s — %s is a lower bound; probe the strict per-silo getters to find the broken venue",
				skipped, c.selector, c.covers)
		}
	}
	return chain.Plan{}, nil
}
