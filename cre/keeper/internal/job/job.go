// Package job is the keeper's read→compute→submit spine: the Job interface
// (Evaluate is pure read+decide) plus the fail-safe Runner that schedules jobs
// and submits their Plans. job imports chain (one-way, C1); chain never imports job.
package job

import (
	"context"
	"log/slog"
	"time"

	"cre-keeper/internal/chain"
)

// Job is the read→compute seam. Evaluate is PURE (read + decide); it never
// submits. The Runner alone submits the returned Plan. KEEPER-01 plugs
// harvest/burn/settle jobs in here.
type Job interface {
	Name() string
	Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error)
}

// Runner schedules jobs on a ticker and submits their Plans fail-safe.
type Runner struct {
	chain    *chain.Chain
	jobs     []Job
	interval time.Duration
	log      *slog.Logger
}

// NewRunner builds a Runner.
func NewRunner(c *chain.Chain, jobs []Job, interval time.Duration, log *slog.Logger) *Runner {
	return &Runner{chain: c, jobs: jobs, interval: interval, log: log}
}

// Run drives the poll loop until ctx is cancelled (SIGINT/SIGTERM via
// signal.NotifyContext). It is fail-safe: a job's Evaluate error or an aborted
// plan submission is logged and the loop continues — liveness-only failure,
// never unsafe (CRE-OPS-ROUTING §"Failure mode = LIVENESS-ONLY, FAIL-SAFE").
func (r *Runner) Run(ctx context.Context) {
	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()

	// Run an immediate first tick, then on every interval.
	r.tick(ctx)
	for {
		select {
		case <-ctx.Done():
			r.log.Info("runner: context done, stopping")
			return
		case <-ticker.C:
			r.tick(ctx)
		}
	}
}

func (r *Runner) tick(ctx context.Context) {
	// ResyncNonce first so the local counter tracks externally-landed txs.
	if err := r.chain.ResyncNonce(ctx); err != nil {
		r.log.Error("runner: resync nonce failed, skipping tick", "err", err)
		return
	}
	for _, j := range r.jobs {
		select {
		case <-ctx.Done():
			return
		default:
		}
		r.runJob(ctx, j)
	}
}

func (r *Runner) runJob(ctx context.Context, j Job) {
	plan, err := j.Evaluate(ctx, r.chain)
	if err != nil {
		// Fail-safe: log and continue to the next job.
		r.log.Error("job evaluate failed", "job", j.Name(), "err", err)
		return
	}
	if len(plan.Actions) == 0 {
		return // empty plan ⇒ no-op
	}
	// Ordered + abort-on-first-error: submit each Action in order; on the FIRST
	// error, log and STOP the rest of THIS plan (a partially-applied ordered
	// sequence — e.g. borrow-without-repay — is the one unsafe outcome to avoid).
	for _, action := range plan.Actions {
		select {
		case <-ctx.Done():
			return
		default:
		}
		receipt, err := r.chain.Submit(ctx, action)
		if err != nil {
			r.log.Error("plan aborted on action error",
				"job", j.Name(), "action", action.Label, "err", err)
			return
		}
		r.log.Info("action submitted",
			"job", j.Name(), "action", action.Label, "tx", receipt.TxHash.Hex())
	}
}
