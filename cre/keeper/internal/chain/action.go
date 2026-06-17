package chain

import "github.com/ethereum/go-ethereum/common"

// Action is a single state-changing call the keeper submits. It carries ONLY
// scalar/encoded calldata a job built (§8.7 bounded blast radius) — never raw
// operator authority beyond the entrypoint. GasLimit 0 ⇒ estimate.
//
// Action/Plan live in internal/chain (NOT internal/job) so chain.Submit can
// consume an Action without importing job — see C1 (one-way job → chain).
type Action struct {
	Label    string
	To       common.Address
	Data     []byte
	GasLimit uint64 // 0 ⇒ estimate (with the gas buffer applied)
}

// Plan is an ordered sequence of Actions a Job returns. An empty Plan is a
// no-op (skipped). Submission is ordered + abort-on-first-error (K4).
type Plan struct {
	Actions []Action
}
