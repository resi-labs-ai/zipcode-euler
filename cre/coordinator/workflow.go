// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-01c — the loss-action producer (§8.4) → DefaultCoordinator (reportType 8).
//
// An off-chain loss / default-recovery event (lock / release / default / recovery / resolve / writeoff) arrives
// via the http trigger. The workflow reaches IDENTICAL consensus on the event record (string fields only),
// normalizes + DISPATCHES on the action discriminant, validates the per-action required fields, encodes the
// matching payload via the shared cre/zipreport library, and emits ONE WriteReport to the DefaultCoordinator as
// the §8.0 envelope abi.encode(uint8 reportType, bytes payload) — where the payload is itself the §8.4 inner
// abi.encode(uint8 action, bytes actionData). Encoding is delegated to cre/zipreport (CRE-00) — this slice does
// NOT re-implement the §8.0 envelope or the §8.4 inner action envelope.
//
// There is NO Proof gate on the loss family (§8.9/DEC-01 RESOLVED): the DefaultCoordinator exposes no on-chain
// boolean gate surface (its six decode tuples carry no booleans); the identical consensus over the loss facts
// IS the attestation, and the §13 Forwarder + Timelock-pinned workflow identity is the entry guard. Every
// well-formed action emits exactly one report — same posture CRE-01a (revaluation) built.
//
// Action discriminant → action byte / encoder / actionData tuple (all reportType 8):
//
//	lock      0 Lock      zipreport.CoordLock      (bytes32 lienId, address originator, uint256 amount)  M1-live
//	release   1 Release   zipreport.CoordRelease   (bytes32 lienId)                                      M1-live
//	default   2 Default_  zipreport.CoordDefault   (bytes32 lienId, uint256 atRisk)                      M2 demo
//	recovery  3 Recovery  zipreport.CoordRecovery  (bytes32 lienId, uint256 recoveryProceeds)            M2 demo
//	resolve   4 Resolve   zipreport.CoordResolve   (bytes32 lienId, uint256 capitalSlashAmount)          M2 demo
//	writeoff  5 WriteOff  zipreport.CoordWriteOff  (bytes32 lienId, uint256 capitalSlashAmount)          M2 demo
//
// The M1-live vs M2 distinction is OPERATIONAL, not a code gate — the encode handshake is identical machinery
// for all six; the producer builds + tests all six. Which actions fire when is documented in the README.
//
// This producer's only receiver is the DefaultCoordinator (rt8 economic action). It does NOT emit any
// ZipcodeController status marker — the bare reportType-5 default-STATUS report (§8.4 line 651) goes to the
// ZipcodeController and is CRE-01b's rt5, already built. The split is on the receiver, not on "default vs not".
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
	"github.com/smartcontractkit/cre-sdk-go/cre"

	zipreport "cre-zipreport"
)

// defaultWriteGasLimit is the WriteReport GasConfig.GasLimit fallback (used when cfg.WriteGasLimit == 0).
const defaultWriteGasLimit = uint64(600_000)

// Config is the static workflow config (parsed once at init via cre.ParseJSON[Config]). Every wiring slot
// (§17) is Config-driven and re-pointable — no hardcoded address. NOTE: the per-invocation loss event is NOT
// carried here — it arrives on the http trigger payload (see onLossEvent / K3).
type Config struct {
	ChainSelector  uint64   `json:"chainSelector"`  // the chain hosting the DefaultCoordinator
	Coordinator    string   `json:"coordinator"`    // the DefaultCoordinator receiver address (§17) — NOTE: Coordinator, not Controller
	WriteGasLimit  uint64   `json:"writeGasLimit"`  // WriteReport gas limit; 0 falls back to 600_000
	AuthorizedKeys []string `json:"authorizedKeys"` // optional; reserved for http.Config (left empty here)
}

// LossEvent is the consensus carrier (K2): STRING fields ONLY — unambiguously isIdenticalType
// (reference/cre-sdk-go/cre/consensus_aggregators.go:198-225) + values.Wrap-able + JSON-native. Do NOT put
// common.Address / [32]byte / *big.Int here; parse those on the DON side AFTER consensus (parseBytes32 /
// parseAddress / parsePositiveBig / parseNonNegBig in the handler), exactly as CRE-01a/01b parse post-consensus.
// It is the UNION of every action's fields; per-action validation in the handler decides which are required.
// NO Gates struct — there is no Proof gate on the loss family (§8.9).
type LossEvent struct {
	Action             string `json:"action"`             // "lock"|"release"|"default"|"recovery"|"resolve"|"writeoff"
	LienID             string `json:"lienId"`             // 0x… 32-byte hex (every action)
	Originator         string `json:"originator"`         // 0x… 20-byte hex (lock ONLY — the release recipient, §13)
	Amount             string `json:"amount"`             // base-10, xALPHA 18-dp (lock ONLY)
	AtRisk             string `json:"atRisk"`             // base-10, 18-dp USD (default ONLY)
	RecoveryProceeds   string `json:"recoveryProceeds"`   // base-10, 18-dp USD (recovery ONLY)
	CapitalSlashAmount string `json:"capitalSlashAmount"` // base-10, xALPHA 18-dp (resolve, writeoff)
}

func initFn(_ *Config, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[*Config], error) {
	// One trigger: http.Trigger (§8.4 — default/recovery are off-chain-event-driven, NO cron heartbeat). An
	// empty &httpcap.Config{} (no AuthorizedKeys) is valid for the build; keys are Config-driven when wired live.
	return cre.Workflow[*Config]{
		cre.Handler(httpcap.Trigger(&httpcap.Config{}), onLossEvent),
	}, nil
}

// onLossEvent is the single handler. It runs in DON mode and holds payload.Input ([]byte, the JSON event
// body). It: (i) reaches identical consensus on the LossEvent carrier in node mode; (ii) dispatches on the
// action discriminant; (iii) validates the per-action required fields, encodes via zipreport, and emits ONE
// WriteReport. There is NO Proof gate — every well-formed action emits exactly one report.
func onLossEvent(cfg *Config, runtime cre.Runtime, payload *httpcap.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// (i) Node-mode observation + identical consensus over the LossEvent carrier. The first type-param C of
	// RunInNodeMode is a FREE generic = []byte: we pass the raw trigger bytes verbatim into observe (NOT the
	// workflow *Config — *Config has no per-invocation trigger body; see K3).
	ev, err := cre.RunInNodeMode(payload.Input, runtime, observe,
		cre.ConsensusIdenticalAggregation[LossEvent]()).Await()
	if err != nil {
		return struct{}{}, err
	}

	// No-op fail-safe (K4): unset Coordinator ⇒ no write, log, return nil.
	if strings.TrimSpace(cfg.Coordinator) == "" {
		logger.Info("coordinator: no-op (coordinator unset)")
		return struct{}{}, nil
	}

	// (ii) Dispatch on the normalized action discriminant ("Lock"/" lock " all match).
	action := strings.ToLower(strings.TrimSpace(ev.Action))

	var envelope []byte
	switch action {
	case "lock":
		envelope, err = buildLock(ev)
	case "release":
		envelope, err = buildRelease(ev)
	case "default":
		envelope, err = buildDefault(ev)
	case "recovery":
		envelope, err = buildRecovery(ev)
	case "resolve":
		envelope, err = buildResolve(ev)
	case "writeoff":
		envelope, err = buildWriteOff(ev)
	default:
		// Unknown or empty action ⇒ error, no write (a malformed event is a producer-side bug to surface).
		return struct{}{}, fmt.Errorf("coordinator: unknown action %q", ev.Action)
	}
	if err != nil {
		return struct{}{}, err
	}

	// (iii) One WriteReport per well-formed event → the DefaultCoordinator. A write error is RETURNED (the §8.4
	// model surfaces it; do not swallow). The producer does NOT pre-check the coordinator's status machine or the
	// escrow bond size — anticipated on-chain reverts (BadStatus / ZeroAtRisk / ZeroOriginator / ZeroAmount /
	// SelfOriginator / BondExists / ExceedsBond) are on-chain backstops; this propagates as the write error.
	if err := writeReport(cfg, runtime, envelope); err != nil {
		return struct{}{}, fmt.Errorf("coordinator: write %s: %w", action, err)
	}
	return struct{}{}, nil
}

// observe is the node-mode observation function. It returns the LossEvent carrier for identical consensus.
//
// §8.4/§8.9 MOCK FEED — replace this json.Unmarshal of the trigger event with per-node
// httpcap.Client.SendRequest to the real recovery/foreclosure/insurance feeds + on-node hash/cert-chain verify,
// deriving the loss magnitudes (atRisk / recoveryProceeds / capitalSlashAmount) + the capital-vs-premium split
// per node; the RunInNodeMode + consensus + dispatch + encode + write machinery is unchanged. For the build,
// every node json.Unmarshals the identical trigger-supplied loss event (deterministic → identical consensus
// holds).
//
// MUST NOT call runtime.GetSecret: NodeRuntime has no SecretsProvider, and §8.1/§8.4 forbid secrets + PII in a
// consensus observation. Any future DON-only secret read (a real-feed token) stays in the handler.
func observe(in []byte, _ cre.NodeRuntime) (LossEvent, error) {
	var ev LossEvent
	if err := json.Unmarshal(in, &ev); err != nil {
		return LossEvent{}, fmt.Errorf("observe: unmarshal loss event: %w", err)
	}
	return ev, nil
}

// ──────────────────────────────────────────────────────────────────────── per-action build (validate → encode)

// buildLock validates the action-0 required fields and encodes zipreport.CoordLock.
// required: lienId (bytes32, non-zero), originator (address, non-zero — escrow ZeroOriginator), amount (>0 —
// escrow ZeroAmount). Returns (env, nil) on success or (nil, err) on a missing/malformed required field.
func buildLock(ev LossEvent) ([]byte, error) {
	lienID, err := parseBytes32(ev.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("lock: lienId: %w", err)
	}
	originator, err := parseAddress(ev.Originator) // required, non-zero (the RELEASE recipient, §13)
	if err != nil {
		return nil, fmt.Errorf("lock: originator: %w", err)
	}
	amount, err := parsePositiveBig(ev.Amount) // required, > 0 (escrow reverts ZeroAmount)
	if err != nil {
		return nil, fmt.Errorf("lock: amount: %w", err)
	}
	return zipreport.CoordLock(lienID, originator, amount)
}

// buildRelease validates the action-1 required field (lienId only; all other carrier fields ignored) and
// encodes zipreport.CoordRelease.
func buildRelease(ev LossEvent) ([]byte, error) {
	lienID, err := parseBytes32(ev.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("release: lienId: %w", err)
	}
	return zipreport.CoordRelease(lienID)
}

// buildDefault validates the action-2 required fields and encodes zipreport.CoordDefault.
// required: lienId (bytes32, non-zero), atRisk (>0 — the contract reverts ZeroAtRisk).
func buildDefault(ev LossEvent) ([]byte, error) {
	lienID, err := parseBytes32(ev.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("default: lienId: %w", err)
	}
	atRisk, err := parsePositiveBig(ev.AtRisk) // required, > 0 (contract reverts ZeroAtRisk)
	if err != nil {
		return nil, fmt.Errorf("default: atRisk: %w", err)
	}
	return zipreport.CoordDefault(lienID, atRisk)
}

// buildRecovery validates the action-3 required fields and encodes zipreport.CoordRecovery.
// required: lienId (bytes32, non-zero), recoveryProceeds (present, may be 0 — the contract tolerates a 0 heal).
func buildRecovery(ev LossEvent) ([]byte, error) {
	lienID, err := parseBytes32(ev.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("recovery: lienId: %w", err)
	}
	recoveryProceeds, err := parseNonNegBig(ev.RecoveryProceeds) // required, present, may be 0
	if err != nil {
		return nil, fmt.Errorf("recovery: recoveryProceeds: %w", err)
	}
	return zipreport.CoordRecovery(lienID, recoveryProceeds)
}

// buildResolve validates the action-4 required fields and encodes zipreport.CoordResolve.
// required: lienId (bytes32, non-zero), capitalSlashAmount (present, may be 0 — 0 skips the capital slash,
// routes all to cohort).
func buildResolve(ev LossEvent) ([]byte, error) {
	lienID, err := parseBytes32(ev.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("resolve: lienId: %w", err)
	}
	capitalSlashAmount, err := parseNonNegBig(ev.CapitalSlashAmount) // required, present, may be 0
	if err != nil {
		return nil, fmt.Errorf("resolve: capitalSlashAmount: %w", err)
	}
	return zipreport.CoordResolve(lienID, capitalSlashAmount)
}

// buildWriteOff validates the action-5 required fields and encodes zipreport.CoordWriteOff.
// required: lienId (bytes32, non-zero), capitalSlashAmount (present, may be 0).
func buildWriteOff(ev LossEvent) ([]byte, error) {
	lienID, err := parseBytes32(ev.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("writeoff: lienId: %w", err)
	}
	capitalSlashAmount, err := parseNonNegBig(ev.CapitalSlashAmount) // required, present, may be 0
	if err != nil {
		return nil, fmt.Errorf("writeoff: capitalSlashAmount: %w", err)
	}
	return zipreport.CoordWriteOff(lienID, capitalSlashAmount)
}

// ──────────────────────────────────────────────────────────────────────── parsing helpers (post-consensus)

// parseBytes32 validates a hex bytes32 string BEFORE conversion. common.HexToHash silently zero-pads/truncates
// bad input, so a malformed feed entry would become the wrong key — validate the hex (0x prefix + exactly 64
// hex chars) FIRST. If !allowZero, the zero value is rejected (lienId must be non-zero). Reused verbatim from
// CRE-01b's parseBytes32 (cre/controller/workflow.go:266-286).
func parseBytes32(s string, allowZero bool) ([32]byte, error) {
	if !strings.HasPrefix(s, "0x") && !strings.HasPrefix(s, "0X") {
		return [32]byte{}, fmt.Errorf("missing 0x prefix")
	}
	hexBody := s[2:]
	if len(hexBody) != 64 {
		return [32]byte{}, fmt.Errorf("want 64 hex chars, got %d", len(hexBody))
	}
	for _, c := range hexBody {
		isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !isHex {
			return [32]byte{}, fmt.Errorf("non-hex char %q", c)
		}
	}
	var b [32]byte
	copy(b[:], common.HexToHash(s).Bytes())
	if !allowZero && b == ([32]byte{}) {
		return [32]byte{}, fmt.Errorf("zero value")
	}
	return b, nil
}

// parseAddress validates a hex address string BEFORE conversion. common.HexToAddress does NOT error on bad
// input (it silently zero-pads/truncates), so validate the hex (0x prefix + exactly 40 hex chars) and reject
// the zero address FIRST. The lock originator is the RELEASE recipient (§13) and the escrow reverts
// ZeroOriginator on address(0). Cloned from cre/revaluation/workflow.go's parseLien (the 40-hex address shape).
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

// parsePositiveBig parses a base-10 integer string and requires it to be > 0 (lock Amount → escrow ZeroAmount;
// default AtRisk → contract ZeroAtRisk). Reused verbatim from CRE-01b (cre/controller/workflow.go:288-299).
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

// parseNonNegBig parses a base-10 integer string that must be PRESENT (a missing/non-base-10 value is an error)
// but may be 0 (recovery RecoveryProceeds + resolve/writeoff CapitalSlashAmount — the contract tolerates 0). A
// negative value is rejected (the on-chain types are uint256). Reused verbatim from CRE-01b
// (cre/controller/workflow.go:303-312).
func parseNonNegBig(s string) (*big.Int, error) {
	v, ok := new(big.Int).SetString(strings.TrimSpace(s), 10)
	if !ok {
		return nil, fmt.Errorf("not a base-10 integer: %q", s)
	}
	if v.Sign() < 0 {
		return nil, fmt.Errorf("must be >= 0, got %s", v.String())
	}
	return v, nil
}

// ──────────────────────────────────────────────────────────────────────── the write path

// writeReport generates a §8.0 report from the pre-encoded envelope and writes it to the coordinator receiver.
// Copied from cre/controller/workflow.go (the proven WriteReport idiom), with the gas limit + receiver taken
// from Config.
func writeReport(cfg *Config, runtime cre.Runtime, envelope []byte) error {
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
		Receiver:  common.HexToAddress(cfg.Coordinator).Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: gasLimit},
	}).Await()
	return err
}
