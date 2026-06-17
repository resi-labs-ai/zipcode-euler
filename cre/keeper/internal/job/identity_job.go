package job

import (
	"context"
	"fmt"

	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
)

// IdentityCheck is one module to probe. AdminSig is its admin getter — explicit,
// no magic name-matching ("operator()" or "windowController()").
type IdentityCheck struct {
	Name     string
	Addr     common.Address
	AdminSig string
}

// IdentityJob is the reference read-only identity/liveness probe (the template
// KEEPER-01 clones). It reads each check's admin getter and owner() and asserts
// the §8.7 invariant: admin == loaded key AND owner != loaded key
// (operator != owner). It makes NO state-changing write — always an empty Plan.
type IdentityJob struct {
	want   common.Address
	checks []IdentityCheck
}

// NewIdentityJob builds the probe. want is the loaded operator key's address.
func NewIdentityJob(want common.Address, checks []IdentityCheck) *IdentityJob {
	return &IdentityJob{want: want, checks: checks}
}

// Name implements Job.
func (j *IdentityJob) Name() string { return "identity" }

// Evaluate reads each check and asserts operator==want && owner!=want. Any
// failure returns an error (the Runner logs it — a wrong/misconfigured key is a
// loud liveness failure, not silent). Always returns an empty Plan (read-only).
func (j *IdentityJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	for _, c := range j.checks {
		admin, err := chain.CallAddress(ctx, r, c.Addr, c.AdminSig)
		if err != nil {
			return chain.Plan{}, fmt.Errorf("identity: reading %s on %s (%s): %w", c.AdminSig, c.Name, c.Addr.Hex(), err)
		}
		if admin != j.want {
			return chain.Plan{}, fmt.Errorf("identity: %s.%s == %s, want operator %s (wrong key / misconfigured)",
				c.Name, c.AdminSig, admin.Hex(), j.want.Hex())
		}
		// §8.7 operator != owner: the keeper's address must NOT be the module owner.
		owner, err := chain.CallAddress(ctx, r, c.Addr, "owner()")
		if err != nil {
			return chain.Plan{}, fmt.Errorf("identity: reading owner() on %s (%s): %w", c.Name, c.Addr.Hex(), err)
		}
		if owner == j.want {
			return chain.Plan{}, fmt.Errorf("identity: %s.owner() == operator %s — operator MUST NOT be owner (§8.7)",
				c.Name, j.want.Hex())
		}
	}
	return chain.Plan{}, nil
}
