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
// read. That zero must never pass silently — this probe reads
// unreadablePairs() every tick and errors loudly (the Runner logs it) whenever
// the count is nonzero, meaning every aggregate total is currently a
// conservative LOWER BOUND with at least one venue unreadable. Added with the
// per-silo isolation fix, ahead of Morpho/Aave venues; with an all-EulerEarn
// board the count cannot become nonzero. Always returns an empty Plan.
type SolvencyProbeJob struct {
	aggregator common.Address
}

// NewSolvencyProbeJob builds the probe.
func NewSolvencyProbeJob(aggregator common.Address) *SolvencyProbeJob {
	return &SolvencyProbeJob{aggregator: aggregator}
}

// Name implements Job.
func (j *SolvencyProbeJob) Name() string { return "solvency-probe" }

// Evaluate reads unreadablePairs() and errors when any venue is unreadable.
func (j *SolvencyProbeJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	skipped, err := chain.CallUint(ctx, r, j.aggregator, "unreadablePairs()")
	if err != nil {
		return chain.Plan{}, fmt.Errorf("solvency-probe: reading unreadablePairs() on %s: %w", j.aggregator.Hex(), err)
	}
	if skipped.Sign() != 0 {
		return chain.Plan{}, fmt.Errorf(
			"solvency-probe: %s venue pair(s) UNREADABLE — seniorBacking/systemCollateralization are lower bounds; probe seniorBackingOf(siloId) per silo to find the broken venue",
			skipped)
	}
	return chain.Plan{}, nil
}
