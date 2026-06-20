// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-01b — the controller lifecycle producer (§8.1) → ZipcodeController (reportType 1/2/4/5,6).
//
// An off-chain application / lifecycle event (origination, draw, close, default/liquidation) arrives via the
// http trigger. The workflow reaches IDENTICAL consensus on the event record (typed fields + the §8.9/§8.10
// Proof boolean gates), ENFORCES the Proof gate (fail-closed: a credit-fact report is emitted ONLY if every
// gate passes), encodes the matching payload via the shared cre/zipreport library, and emits ONE WriteReport
// to the ZipcodeController as the §8.0 envelope abi.encode(uint8 reportType, bytes payload). Encoding is
// delegated to cre/zipreport (CRE-00) — this slice does NOT re-implement the §8.0 handshake.
//
// Action discriminant → reportType / encoder / Proof-gate / siloId:
//
//	origination          rt1 RT_ORIGINATION   zipreport.Origination  Proof-gate=yes  carries siloId (CTR-03)
//	draw                 rt2 RT_DRAW          zipreport.Draw         Proof-gate=yes  NO siloId (re-resolved on-chain)
//	close                rt4 RT_CLOSE         zipreport.Close        Proof-gate=no
//	default/liquidation  rt5/rt6 RT_DEFAULT/  zipreport.Status       Proof-gate=no   (status marker, §8.4)
//	                          RT_LIQUIDATION
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
// (§17) is Config-driven and re-pointable — no hardcoded address. NOTE: the per-invocation lifecycle event
// is NOT carried here — it arrives on the http trigger payload (see onApplication / K3).
type Config struct {
	ChainSelector  uint64   `json:"chainSelector"`  // the chain hosting the ZipcodeController
	Controller     string   `json:"controller"`     // the ZipcodeController receiver address (§17)
	WriteGasLimit  uint64   `json:"writeGasLimit"`  // WriteReport gas limit; 0 falls back to 600_000
	AuthorizedKeys []string `json:"authorizedKeys"` // optional; reserved for http.Config (left empty here)
}

// Application is the consensus carrier (K2): string + bool + uintN scalar fields ONLY (plus a nested struct of
// bools) — unambiguously isIdenticalType + values.Wrap-able + JSON-native. Do NOT put common.Address /
// [32]byte / *big.Int here; parse those on the DON side AFTER consensus (parseBytes32 / big.Int.SetString in
// the handler), exactly as CRE-01a parses its Marks post-consensus. It is the union of every action's fields;
// per-action validation in the handler decides which are required.
type Application struct {
	Action     string `json:"action"`     // "origination"|"draw"|"close"|"default"|"liquidation"
	LienID     string `json:"lienId"`     // 0x… 32-byte hex (every action)
	ProofRef   string `json:"proofRef"`   // 0x… 32-byte hex (origination, draw)
	SiloID     string `json:"siloId"`     // 0x… 32-byte hex (origination ONLY — CTR-03)
	EquityMark string `json:"equityMark"` // base-10 string, 18-dp mark (origination, draw)
	DrawAmount string `json:"drawAmount"` // base-10 string (origination, draw)
	Cap        string `json:"cap"`        // base-10 string (origination)
	BorrowLTV  uint16 `json:"borrowLtv"`  // 1e4-scale (origination)
	LiqLTV     uint16 `json:"liqLtv"`     // 1e4-scale (origination)
	Status     uint8  `json:"status"`     // (default, liquidation)
	Gates      Gates  `json:"gates"`      // §8.9/§8.10 Proof booleans (origination, draw)
}

// Gates are the §8.9/§8.10 Proof booleans — each is an off-chain truth resolved to a boolean gate. For the
// build they arrive pre-computed on the trigger payload (the §8.9 mock seam, see observe). ALL must be true
// for a credit-fact report (origination, draw) to be emitted (fail-closed; §8.9).
type Gates struct {
	LienPerfected bool `json:"lienPerfected"` // §8.10 — boolean gate before mint
	Insured       bool `json:"insured"`       // §8.10 — boolean gate before mint
	IdentityOk    bool `json:"identityOk"`    // §8.10 — Plaid KYC/sanctions
	CreditOk      bool `json:"creditOk"`      // §8.10 — VantageScore band
	IncomeOk      bool `json:"incomeOk"`      // §8.10 — income ≥ threshold
	TitleClean    bool `json:"titleClean"`    // §8.10 — Pippin title
}

// pass reports whether every Proof gate is true (fail-closed all-must-pass, §8.9).
func (g Gates) pass() bool {
	return g.LienPerfected && g.Insured && g.IdentityOk && g.CreditOk && g.IncomeOk && g.TitleClean
}

func initFn(_ *Config, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[*Config], error) {
	// One trigger: http.Trigger (§8.1 — origination/lifecycle are http/event-driven, NO cron heartbeat). An
	// empty &httpcap.Config{} (no AuthorizedKeys) is valid for the build; keys are Config-driven when wired live.
	return cre.Workflow[*Config]{
		cre.Handler(httpcap.Trigger(&httpcap.Config{}), onApplication),
	}, nil
}

// onApplication is the single handler. It runs in DON mode and holds payload.Input ([]byte, the JSON event
// body). It: (i) reaches identical consensus on the Application carrier in node mode; (ii) dispatches on the
// action discriminant; (iii) validates the per-action required fields, enforces the §8.9 Proof gate for
// credit facts, encodes via zipreport, and emits ONE WriteReport.
func onApplication(cfg *Config, runtime cre.Runtime, payload *httpcap.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// (i) Node-mode observation + identical consensus over the Application carrier. The first type-param C of
	// RunInNodeMode is a FREE generic = []byte: we pass the raw trigger bytes verbatim into observe (NOT the
	// workflow *Config — *Config has no per-invocation trigger body; see K3).
	app, err := cre.RunInNodeMode(payload.Input, runtime, observe,
		cre.ConsensusIdenticalAggregation[Application]()).Await()
	if err != nil {
		return struct{}{}, err
	}

	// No-op fail-safe (K4): unset Controller ⇒ no write, log, return nil.
	if strings.TrimSpace(cfg.Controller) == "" {
		logger.Info("controller: no-op (controller unset)")
		return struct{}{}, nil
	}

	// (ii) Dispatch on the normalized action discriminant ("Origination"/" origination " all match).
	action := strings.ToLower(strings.TrimSpace(app.Action))

	var envelope []byte
	switch action {
	case "origination":
		envelope, err = buildOrigination(app, logger)
	case "draw":
		envelope, err = buildDraw(app, logger)
	case "close":
		envelope, err = buildClose(app)
	case "default":
		envelope, err = buildStatus(app, zipreport.ControllerDefault)
	case "liquidation":
		envelope, err = buildStatus(app, zipreport.ControllerLiquidation)
	default:
		// Unknown or empty action ⇒ error, no write (a malformed event is a producer-side bug to surface).
		return struct{}{}, fmt.Errorf("controller: unknown action %q", app.Action)
	}
	if err != nil {
		return struct{}{}, err
	}
	// A gated-out credit fact returns (nil, nil) — fail-closed no-op, no write.
	if envelope == nil {
		return struct{}{}, nil
	}

	// (iii) One WriteReport per gated-pass event → the ZipcodeController. A write error is RETURNED (the §8.1
	// model surfaces it; do not swallow).
	if err := writeReport(cfg, runtime, envelope); err != nil {
		return struct{}{}, fmt.Errorf("controller: write %s: %w", action, err)
	}
	return struct{}{}, nil
}

// observe is the node-mode observation function. It returns the Application carrier for identical consensus.
//
// §8.9/§8.10 MOCK FEED — replace this json.Unmarshal of the trigger event with per-node
// httpcap.Client.SendRequest to the real Proof / Plaid / Credit-Karma / Pippin / DART / Block-Analitica feeds
// + on-node zk/hash/cert-chain verify, deriving Gates + EquityMark per node; the RunInNodeMode + consensus +
// gate + encode + write machinery is unchanged. For the build, every node json.Unmarshals the identical
// trigger-supplied event (deterministic → identical consensus holds), INCLUDING the Gates booleans — i.e. the
// off-chain Proof/feed verdicts arrive pre-computed in the payload this window.
//
// MUST NOT call runtime.GetSecret: NodeRuntime has no SecretsProvider, and §8.1 forbids secrets in a
// consensus observation. Any future DON-only secret read (a real-feed token, §8.10) stays in the handler.
func observe(in []byte, _ cre.NodeRuntime) (Application, error) {
	var app Application
	if err := json.Unmarshal(in, &app); err != nil {
		return Application{}, fmt.Errorf("observe: unmarshal application: %w", err)
	}
	return app, nil
}

// ──────────────────────────────────────────────────────────────────────── per-action build (validate → gate → encode)

// buildOrigination validates the rt1 required fields, enforces the §8.9 Proof gate, and encodes
// zipreport.Origination. Returns (nil, nil) on a gate-fail (fail-closed no-op), (env, nil) on success, or
// (nil, err) on a missing/malformed required field.
func buildOrigination(app Application, logger *slog.Logger) ([]byte, error) {
	lienID, err := parseBytes32(app.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("origination: lienId: %w", err)
	}
	siloID, err := parseBytes32(app.SiloID, false) // required, non-zero (CTR-03 fill-target)
	if err != nil {
		return nil, fmt.Errorf("origination: siloId: %w", err)
	}
	proofRef, err := parseBytes32(app.ProofRef, true) // optional, may be zero
	if err != nil {
		return nil, fmt.Errorf("origination: proofRef: %w", err)
	}
	equityMark, err := parsePositiveBig(app.EquityMark) // required, > 0 (seedPrice price==0 guard reverts)
	if err != nil {
		return nil, fmt.Errorf("origination: equityMark: %w", err)
	}
	drawAmount, err := parseNonNegBig(app.DrawAmount) // required, present, may be 0
	if err != nil {
		return nil, fmt.Errorf("origination: drawAmount: %w", err)
	}
	cap, err := parseNonNegBig(app.Cap) // required, present, may be 0
	if err != nil {
		return nil, fmt.Errorf("origination: cap: %w", err)
	}
	// BorrowLTV / LiqLTV are uint16 1e4-scale — no producer-side range check (Block Analitica owns the bounds, §8.10).

	// §8.9 Proof gate: ALL gates true → emit; any false → NO report (fail-closed no-op).
	if !app.Gates.pass() {
		logger.Info("controller: origination gate failed (fail-closed no-op)", "lienId", app.LienID)
		return nil, nil
	}

	return zipreport.Origination(lienID, proofRef, equityMark, app.BorrowLTV, app.LiqLTV, drawAmount, cap, siloID)
}

// buildDraw validates the rt2 required fields, enforces the §8.9 Proof gate, and encodes zipreport.Draw. NO
// SiloID is sent (the controller re-resolves the venue from the stored r.siloId; §8.0 534-538).
func buildDraw(app Application, logger *slog.Logger) ([]byte, error) {
	lienID, err := parseBytes32(app.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("draw: lienId: %w", err)
	}
	proofRef, err := parseBytes32(app.ProofRef, true) // optional, may be zero
	if err != nil {
		return nil, fmt.Errorf("draw: proofRef: %w", err)
	}
	equityMark, err := parsePositiveBig(app.EquityMark) // required, > 0 (re-anchored mark; seedPrice guard)
	if err != nil {
		return nil, fmt.Errorf("draw: equityMark: %w", err)
	}
	drawAmount, err := parseNonNegBig(app.DrawAmount) // required, present, may be 0
	if err != nil {
		return nil, fmt.Errorf("draw: drawAmount: %w", err)
	}

	// §8.9 Proof gate: same all-must-pass → else no-op.
	if !app.Gates.pass() {
		logger.Info("controller: draw gate failed (fail-closed no-op)", "lienId", app.LienID)
		return nil, nil
	}

	return zipreport.Draw(lienID, proofRef, equityMark, drawAmount)
}

// buildClose validates the rt4 required field (lienId only; all other carrier fields are ignored) and encodes
// zipreport.Close. NO Proof gate — the on-chain observeDebt==0 check is the gate.
func buildClose(app Application) ([]byte, error) {
	lienID, err := parseBytes32(app.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("close: lienId: %w", err)
	}
	return zipreport.Close(lienID)
}

// buildStatus validates the rt5/rt6 required fields (lienId + status) and encodes zipreport.Status. NO Proof
// gate — a status marker, off-chain truth (§8.4); any uint8 status is valid (the M1 contract emits it verbatim).
func buildStatus(app Application, reportType uint8) ([]byte, error) {
	lienID, err := parseBytes32(app.LienID, false) // required, non-zero
	if err != nil {
		return nil, fmt.Errorf("status: lienId: %w", err)
	}
	return zipreport.Status(reportType, lienID, app.Status)
}

// ──────────────────────────────────────────────────────────────────────── parsing helpers (post-consensus)

// parseBytes32 validates a hex bytes32 string BEFORE conversion. common.HexToHash silently zero-pads/truncates
// bad input, so a malformed feed entry would become the wrong key — validate the hex (0x prefix + exactly 64
// hex chars) FIRST. If !allowZero, the zero value is rejected (lienId/siloId must be non-zero; proofRef, an
// off-chain commitment, may be zero). Adapted from CRE-01a's parseLien (40→64 hex, address→[32]byte).
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

// parsePositiveBig parses a base-10 integer string and requires it to be > 0 (the controller's
// seedPrice→_writePrice price==0 guard reverts PriceOracle_InvalidAnswer).
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

// parseNonNegBig parses a base-10 integer string that must be PRESENT (a missing/non-base-10 value is an
// error) but may be 0. A negative value is rejected (the on-chain types are uint256).
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

// writeReport generates a §8.0 report from the pre-encoded envelope and writes it to the controller receiver.
// Copied from cre/revaluation/workflow.go (the proven WriteReport idiom), with the gas limit + receiver taken
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
		Receiver:  common.HexToAddress(cfg.Controller).Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: gasLimit},
	}).Await()
	return err
}
