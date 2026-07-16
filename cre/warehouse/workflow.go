// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-04 — the senior-warehouse op producer (§8.5) → WarehouseAdminModule (opType 1/2/3/4).
//
// An off-chain warehouse-op event (supply / approve / redeem / repay) arrives via the http trigger. The
// workflow reaches IDENTICAL consensus on the event record (string fields only), normalizes + DISPATCHES on
// the op discriminant, validates the per-op required fields, encodes the matching payload via the shared
// cre/zipreport library, and emits ONE WriteReport to the WarehouseAdminModule as the §8.5 envelope
// abi.encode(uint8 opType, bytes payload). Encoding is delegated to cre/zipreport (CRE-00) — this slice does
// NOT re-implement the §8.5 envelope or any payload encode.
//
// There is NO Proof gate on the warehouse op family (§8.9 / CRE-01a/01c posture): the WarehouseAdminModule
// exposes no on-chain boolean gate surface — its decode is a pure (opType, payload) → one pinned
// Roles-forwarded call (Roles.execTransactionWithRole, Call-only, params pinned). The identical consensus over
// the op facts IS the attestation, and the §13 distinct-Forwarder + Timelock-pinned workflow identity + the
// Zodiac Roles scope (the real param-pinning security boundary) are the entry guards. Every well-formed op
// emits exactly one report. There is NO Gates struct and no "emit only if gates pass" branch.
//
// Op discriminant → opType byte / encoder / payload tuple / the pinned Safe call the adapter re-encodes:
//
//	supply   1 SUPPLY   zipreport.WhSupplyReport   (uint256 amount)               eePool.deposit(amount, SAFE)
//	approve  2 APPROVE  zipreport.WhApproveReport  (uint256 amount)               usdc.approve(eePool, amount)
//	redeem   3 REDEEM   zipreport.WhRedeemReport   (uint256 shares)               eePool.redeem(shares, SAFE, SAFE)
//	repay    4 REPAY    zipreport.WhRepayReport    (address dest, uint256 amount) usdc.transfer(redemptionBox, amount)
//
// The adapter holds NO custody and enforces NO scope of its own beyond the dest==redemptionBox self-check —
// the security boundary is the Zodiac Roles scope. The producer sizes the scalars; the on-chain policy pins the
// identities (the receiver/spender/redeem-owner are adapter-injected from wiring). The producer carries ONLY
// the REPAY `dest` (§8.5: the one carried field; scope-pinned EqualTo(redemptionBox)) plus the four magnitudes.
package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	httpcap "github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"

	zipreport "cre-zipreport"
)

// defaultWriteGasLimit is the WriteReport GasConfig.GasLimit fallback (used when cfg.WriteGasLimit == 0).
const defaultWriteGasLimit = uint64(600_000)

// Config is the static workflow config (parsed once at init via cre.ParseJSON[Config]). Every wiring slot
// (§17) is Config-driven and re-pointable — no hardcoded address. NOTE: the per-invocation warehouse op event
// is NOT carried here — it arrives on the http trigger payload (see onWarehouseOp / K3).
type Config struct {
	ChainSelector  uint64   `json:"chainSelector"`  // the chain hosting the WarehouseAdminModule
	Warehouse      string   `json:"warehouse"`      // the WarehouseAdminModule receiver address (§17) — NOTE: Warehouse
	WriteGasLimit  uint64   `json:"writeGasLimit"`  // WriteReport gas limit; 0 falls back to 600_000
	AuthorizedKeys []string `json:"authorizedKeys"` // optional; reserved for http.Config (left empty here)

	// CRE-02b — the reserve-gated redemption funding leg (the cron path). DEFAULT-OFF: FundingEnabled is false
	// unless explicitly set, so onFundingTick is a no-op (zero reads, zero writes) until ops activate it. No new
	// ADDRESS slots for safe/eePool/usdc/queue — those are read OFF the warehouse adapter (re-pointable, §17). The
	// EXCEPTION is CoverageGate (the adapter has no gate getter), Config-sourced like buyburn-bid (zero ⇒ covered).
	FundingEnabled   bool   `json:"fundingEnabled"`   // K3: false (default) ⇒ onFundingTick emits ZERO reports
	FundingSchedule  string `json:"fundingSchedule"`  // cron schedule for onFundingTick (e.g. "0 */5 * * * *")
	CoverageGate     string `json:"coverageGate"`     // ICoverageGate (DurationFreezeModule); zero ⇒ treat covered() = true
	HarvestReserve   string `json:"harvestReserve"`   // 6-dp USDC held back for the harvest engine (CRE-06 constant)
	SafetyBuffer     string `json:"safetyBuffer"`     // 6-dp USDC operational buffer (CRE-06 constant)
	MaxRedeemPerTick string `json:"maxRedeemPerTick"` // 6-dp USDC per-tick REDEEM ceiling; "" / "0" ⇒ no upper clamp

	// CRE-02c — the cross-silo redemption solver (the multi-pool generalization of the CRE-02b funding leg).
	// DEFAULT-OFF: SolverEnabled is false unless explicitly set, so onSolverTick is a no-op (zero reads, zero
	// writes) until ops activate it. K2 MUTUAL EXCLUSION: enable exactly ONE of FundingEnabled / SolverEnabled —
	// both target the SAME shared-queue shortfall, so onFundingTick no-ops when SolverEnabled is true. REUSES the
	// per-pool HarvestReserve / SafetyBuffer / MaxRedeemPerTick knobs above (NO CoverageGate — per-silo freeze is
	// read from the registry).
	SolverEnabled  bool     `json:"solverEnabled"`  // K3: false (default) ⇒ onSolverTick emits ZERO reports
	SolverSchedule string   `json:"solverSchedule"` // cron schedule for onSolverTick (e.g. "0 */5 * * * *")
	SiloRegistry   string   `json:"siloRegistry"`   // SiloRegistry address — the live silo set + per-silo gate source
	Warehouses     []string `json:"warehouses"`     // the writable WAM set (the silo→WAM binding, joined by warehouseSafe)
}

// WarehouseOp is the consensus carrier (K2): STRING fields ONLY — unambiguously isIdenticalType
// (reference/cre-sdk-go/cre/consensus_aggregators.go:198-225) + values.Wrap-able + JSON-native. Do NOT put
// common.Address / [32]byte / *big.Int here; parse those on the DON side AFTER consensus (parseAddress /
// parsePositiveBig in the handler), exactly as CRE-01c parses post-consensus. It is the UNION of every op's
// fields; per-op validation in the handler decides which are required. NO Gates struct — there is no Proof gate
// on the warehouse op family (§8.9).
type WarehouseOp struct {
	Op     string `json:"op"`     // "supply"|"approve"|"redeem"|"repay"
	Amount string `json:"amount"` // base-10; supply/approve/repay (USDC, 6-dp)
	Shares string `json:"shares"` // base-10; redeem ONLY (EulerEarn shares, 18-dp)
	Dest   string `json:"dest"`   // 0x… 40-hex; repay ONLY (the pinned REPAY sink — must be redemptionBox on-chain)
}

func initFn(cfg *Config, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[*Config], error) {
	// TWO triggers, ONE workflow id (P1 — the option-(b) premise). The workflow id is per deployed binary, NOT per
	// handler: a cre.Workflow[*Config] registers multiple cre.Handlers in one binary, so BOTH the http manual-ops
	// path (onWarehouseOp, CRE-04) and the cron funding heartbeat (onFundingTick, CRE-02b) write under the
	// warehouse's single pinned expectedWorkflowId. A separate CRE-02b binary could NOT WriteReport (the
	// ReceiverTemplate pins exactly one author), which is why the sizing folds in here.
	//   - http.Trigger → onWarehouseOp: the §8.5 manual-ops path (UNCHANGED). Empty &httpcap.Config{} (no
	//     AuthorizedKeys) is valid for the build; keys are Config-driven when wired live.
	//   - cron.Trigger → onFundingTick: the reserve-gated redemption funding leg (CRE-02b), DEFAULT-OFF via
	//     FundingEnabled. The cron fires regardless; onFundingTick returns immediately when funding is disabled.
	//   - cron.Trigger → onSolverTick: the CRE-02c cross-silo redemption solver, DEFAULT-OFF via SolverEnabled
	//     (the THIRD handler, K1). The cron fires regardless; onSolverTick returns immediately when disabled. K2:
	//     enable exactly one of FundingEnabled / SolverEnabled (both fund the same shared-queue shortfall).
	return cre.Workflow[*Config]{
		cre.Handler(httpcap.Trigger(&httpcap.Config{}), onWarehouseOp),
		cre.Handler(cron.Trigger(&cron.Config{Schedule: cfg.FundingSchedule}), onFundingTick),
		cre.Handler(cron.Trigger(&cron.Config{Schedule: cfg.SolverSchedule}), onSolverTick),
	}, nil
}

// onWarehouseOp is the single handler. It runs in DON mode and holds payload.Input ([]byte, the JSON event
// body). It: (i) reaches identical consensus on the WarehouseOp carrier in node mode; (ii) dispatches on the
// op discriminant; (iii) validates the per-op required fields, encodes via zipreport, and emits ONE
// WriteReport. There is NO Proof gate — every well-formed op emits exactly one report.
func onWarehouseOp(cfg *Config, runtime cre.Runtime, payload *httpcap.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// (i) Node-mode observation + identical consensus over the WarehouseOp carrier. The first type-param C of
	// RunInNodeMode is a FREE generic = []byte: we pass the raw trigger bytes verbatim into observe (NOT the
	// workflow *Config — *Config has no per-invocation trigger body; see K3).
	ev, err := cre.RunInNodeMode(payload.Input, runtime, observe,
		cre.ConsensusIdenticalAggregation[WarehouseOp]()).Await()
	if err != nil {
		return struct{}{}, err
	}

	// No-op fail-safe (K4): unset Warehouse ⇒ no write, log, return nil.
	if strings.TrimSpace(cfg.Warehouse) == "" {
		logger.Info("warehouse: no-op (warehouse unset)")
		return struct{}{}, nil
	}

	// (ii) Dispatch on the normalized op discriminant ("Supply"/" supply " all match).
	op := strings.ToLower(strings.TrimSpace(ev.Op))

	var envelope []byte
	switch op {
	case "supply":
		envelope, err = buildSupply(ev)
	case "approve":
		envelope, err = buildApprove(ev)
	case "redeem":
		envelope, err = buildRedeem(ev)
	case "repay":
		envelope, err = buildRepay(ev)
	default:
		// Unknown or empty op ⇒ error, no write (a malformed event is a producer-side bug to surface).
		return struct{}{}, fmt.Errorf("warehouse: unknown op %q", ev.Op)
	}
	if err != nil {
		return struct{}{}, err
	}

	// (iii) One WriteReport per well-formed event → the WarehouseAdminModule. A write error is RETURNED (the
	// §8.5 model surfaces it; do not swallow). The producer does NOT pre-check the Safe balance, the Roles
	// scope, or the on-chain redemptionBox — anticipated on-chain reverts (EE ZeroShares/cap, Roles
	// ParameterNotAllowed / ModuleTransactionFailed, WrongRedemptionBox, insufficient shares/USDC) are on-chain
	// backstops; this propagates as the write error.
	if err := writeReport(cfg, runtime, envelope); err != nil {
		return struct{}{}, fmt.Errorf("warehouse: write %s: %w", op, err)
	}
	return struct{}{}, nil
}

// observe is the node-mode observation function. It returns the WarehouseOp carrier for identical consensus.
//
// §8.5/§8.9 MOCK FEED — replace this json.Unmarshal of the trigger event with the §8.5 on-chain NAV sizing:
// per-node evmClient.CallContract reading eePool.convertToAssets(eePool.balanceOf(warehouseSafe)) + the
// redemption shortfall / recovery draw, deriving amount/shares per node; the RunInNodeMode + consensus +
// dispatch + encode + write machinery is unchanged. For the build, every node json.Unmarshals the identical
// trigger-supplied op event (deterministic → identical consensus holds).
//
// MUST NOT call runtime.GetSecret: NodeRuntime has no SecretsProvider, and §8.1/§8.5 forbid secrets in a
// consensus observation. Any future DON-only secret read (a real authenticated off-chain shortfall feed token)
// stays in the handler.
func observe(in []byte, _ cre.NodeRuntime) (WarehouseOp, error) {
	var ev WarehouseOp
	if err := json.Unmarshal(in, &ev); err != nil {
		return WarehouseOp{}, fmt.Errorf("observe: unmarshal warehouse op: %w", err)
	}
	return ev, nil
}

// ──────────────────────────────────────────────────────────────────────── per-op build (validate → encode)

// buildSupply validates the opType-1 required field and encodes zipreport.WhSupplyReport.
// required: amount (*big.Int, base-10, > 0 — deposit(0) reverts EE ZeroShares → Roles ModuleTransactionFailed).
func buildSupply(ev WarehouseOp) ([]byte, error) {
	amount, err := parsePositiveBig(ev.Amount) // required, > 0
	if err != nil {
		return nil, fmt.Errorf("supply: amount: %w", err)
	}
	return zipreport.WhSupplyReport(amount)
}

// buildApprove validates the opType-2 required field and encodes zipreport.WhApproveReport.
// required: amount (*big.Int, base-10, > 0 — the exact-amount allowance the next deposit pulls against).
func buildApprove(ev WarehouseOp) ([]byte, error) {
	amount, err := parsePositiveBig(ev.Amount) // required, > 0 (exact-amount allowance)
	if err != nil {
		return nil, fmt.Errorf("approve: amount: %w", err)
	}
	return zipreport.WhApproveReport(amount)
}

// buildRedeem validates the opType-3 required field and encodes zipreport.WhRedeemReport.
// required: shares (*big.Int, base-10, > 0 — redeem(0) is a wasted no-op write the producer never intends).
func buildRedeem(ev WarehouseOp) ([]byte, error) {
	shares, err := parsePositiveBig(ev.Shares) // required, > 0
	if err != nil {
		return nil, fmt.Errorf("redeem: shares: %w", err)
	}
	return zipreport.WhRedeemReport(shares)
}

// buildRepay validates the opType-4 required fields and encodes zipreport.WhRepayReport.
// required: dest (address, non-zero — the adapter reverts WrongRedemptionBox if it is not the wired
// redemptionBox; the producer carries it per §8.5, does NOT read on-chain to pre-check), amount (*big.Int,
// base-10, > 0 — a 0-value transfer is a meaningless wasted write).
func buildRepay(ev WarehouseOp) ([]byte, error) {
	dest, err := parseAddress(ev.Dest) // required, non-zero (the carried REPAY sink, §8.5)
	if err != nil {
		return nil, fmt.Errorf("repay: dest: %w", err)
	}
	amount, err := parsePositiveBig(ev.Amount) // required, > 0
	if err != nil {
		return nil, fmt.Errorf("repay: amount: %w", err)
	}
	return zipreport.WhRepayReport(dest, amount)
}

// ──────────────────────────────────────────────────────────────────────── parsing helpers (post-consensus)

// parseAddress validates a hex address string BEFORE conversion. common.HexToAddress does NOT error on bad
// input (it silently zero-pads/truncates), so validate the hex (0x prefix + exactly 40 hex chars) and reject
// the zero address FIRST. The REPAY dest must be a non-zero address (the adapter reverts WrongRedemptionBox on
// any non-redemptionBox dest, and the Roles scope pins EqualTo(redemptionBox)). Reused verbatim from CRE-01c
// (cre/coordinator/workflow.go:284-303).
func parseAddress(s string) (common.Address, error) {
	if !strings.HasPrefix(s, "0x") && !strings.HasPrefix(s, "0X") {
		return common.Address{}, fmt.Errorf("missing 0x prefix")
	}
	hexBody := s[2:]
	if len(hexBody) != 40 {
		return common.Address{}, fmt.Errorf("want 40 hex chars, got %d", len(hexBody))
	}
	for _, c := range hexBody {
		isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !isHex {
			return common.Address{}, fmt.Errorf("non-hex char %q", c)
		}
	}
	addr := common.HexToAddress(s)
	if addr == (common.Address{}) {
		return common.Address{}, fmt.Errorf("zero address")
	}
	return addr, nil
}

// parsePositiveBig parses a base-10 integer string and requires it to be > 0. No warehouse magnitude tolerates
// 0: supply deposit(0) reverts EE ZeroShares; approve is an exact-amount allowance; redeem(0) is a wasted
// no-op; a 0-value repay transfer is meaningless. Reused verbatim from CRE-01c
// (cre/coordinator/workflow.go:307-316).
func parsePositiveBig(s string) (*big.Int, error) {
	v, ok := new(big.Int).SetString(strings.TrimSpace(s), 10)
	if !ok {
		return nil, fmt.Errorf("not a base-10 integer: %q", s)
	}
	if v.Sign() <= 0 {
		return nil, fmt.Errorf("must be > 0, got %s", v.String())
	}
	return v, nil
}

// ──────────────────────────────────────────────────────────────────────── the write path

// writeReport generates a §8.0 report from the pre-encoded envelope and writes it to the single configured
// warehouse receiver (cfg.Warehouse). It delegates to writeReportTo — the CRE-04 / CRE-02b call sites are
// unchanged.
func writeReport(cfg *Config, runtime cre.Runtime, envelope []byte) error {
	return writeReportTo(cfg, runtime, common.HexToAddress(cfg.Warehouse), envelope)
}

// writeReportTo generates a §8.0 report from the pre-encoded envelope and writes it to an EXPLICIT receiver
// (CRE-02c: each silo's own WarehouseAdminModule). Copied from cre/coordinator/workflow.go (the proven
// WriteReport idiom), with the gas limit from Config and the receiver passed in.
func writeReportTo(cfg *Config, runtime cre.Runtime, receiver common.Address, envelope []byte) error {
	report, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: envelope,
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		return err
	}
	gasLimit := cfg.WriteGasLimit
	if gasLimit == 0 {
		gasLimit = defaultWriteGasLimit
	}
	client := &evm.Client{ChainSelector: cfg.ChainSelector}
	_, err = client.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  receiver.Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: gasLimit},
	}).Await()
	return err
}
