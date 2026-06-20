// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-00 scaffold — the clone-me wasip1 workflow template for the Zipcode (R) report-path track.
//
// It demonstrates the SDK patterns the existing workflows do NOT, so CRE-01/03/04 can copy them verbatim:
//   - a DON-only GetSecret read (§8.10: raw PII must never enter a consensus observation — the secret is
//     read on the DON runtime in the handler, NEVER inside the node-mode observation function);
//   - RunInNodeMode + ConsensusIdenticalAggregation over a single uint64 carrier (a known values.Wrap-able
//     scalar — avoids the multi-field-struct Wrap question);
//   - the §8.0 GenerateReport -> WriteReport write path, encoding via the shared cre/zipreport library.
//
// ───────────────────────────────────────────────────────────────────────────────────────────────────────
// THIS IS A SKELETON. The worked example pushes an illustrative LpMark — it implements NONE of the
// CRE-01/03/04 business logic (no underwriting, no NAV/LP math, no revaluation sharding, no Proof gating).
// The observed `mark` is a hard-coded constant, NOT a data feed. Replace the marked seams with your own.
// ───────────────────────────────────────────────────────────────────────────────────────────────────────
package main

import (
	"log/slog"
	"math/big"

	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"

	zipreport "cre-zipreport"
)

const writeGasLimit = uint64(600_000)

// templateMark is the illustrative, deterministic observation value. TEMPLATE: replace with your ticket's
// real per-node observation (e.g. a chain read aggregated to a consensus mark).
const templateMark uint64 = 1_000_000

type Config struct {
	Schedule      string `json:"schedule"`      // heartbeat cron, e.g. "0 */5 * * * *"
	ChainSelector uint64 `json:"chainSelector"` // the chain hosting the report receiver
	Receiver      string `json:"receiver"`      // the §8.0 report receiver (the WriteReport target)
	SecretId      string `json:"secretId"`      // the DON-only secret id (illustrative read; see §8.10)
}

func initFn(cfg *Config, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[*Config], error) {
	return cre.Workflow[*Config]{
		cre.Handler(cron.Trigger(&cron.Config{Schedule: cfg.Schedule}), onCron),
	}, nil
}

// onCron is the single handler: DON-only secret read -> node-mode observation + consensus -> DON-side
// stamp + zipreport encode -> GenerateReport -> WriteReport.
func onCron(cfg *Config, runtime cre.Runtime, _ *cron.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// (i) DON-only secret read (§8.10). This runs on the DON `runtime` — NEVER inside the node-mode
	// observation below, because raw secret material must never enter a consensus observation. It is
	// FAIL-SAFE and ILLUSTRATIVE: on error or empty value we log and PROCEED. The secret is a demo of the
	// call shape, NOT a precondition for the write — so the sim test needs no seeded secret/namespace.
	// `cre.SecretRequest` is the alias for sdk.SecretRequest (runtime.go:14), so no new chainlink-protos
	// import is added.
	if cfg.SecretId != "" {
		secret, err := runtime.GetSecret(&cre.SecretRequest{Id: cfg.SecretId}).Await()
		switch {
		case err != nil:
			logger.Warn("TEMPLATE: DON-only secret read failed; proceeding (illustrative)", "id", cfg.SecretId, "err", err)
		case secret.Value == "":
			logger.Warn("TEMPLATE: DON-only secret empty; proceeding (illustrative)", "id", cfg.SecretId)
		default:
			logger.Info("TEMPLATE: DON-only secret read ok (value not logged)", "id", cfg.SecretId)
		}
	}

	// (ii) Gather the observation in node mode and reach identical consensus. Carrier = a single uint64
	// scalar (values.Wrap-able). Do NOT consensus the timestamp — that is stamped DON-side below.
	mark, err := cre.RunInNodeMode(cfg, runtime, observe, cre.ConsensusIdenticalAggregation[uint64]()).Await()
	if err != nil {
		return struct{}{}, err
	}

	// Fail-safe skip: nothing to push, or no receiver configured.
	if mark == 0 || cfg.Receiver == "" {
		logger.Info("TEMPLATE: no-op (mark==0 or receiver unset)", "mark", mark, "receiver", cfg.Receiver)
		return struct{}{}, nil
	}

	// (iii) DON-side: stamp the time (the runtime.Now() idiom) and encode the report. TEMPLATE: replace
	// this zipreport.LpMarkReport call with your ticket's zipreport.Xxx call (Origination, Draw, NavLeg…).
	ts := uint32(runtime.Now().Unix())
	envelope, err := zipreport.LpMarkReport(new(big.Int).SetUint64(mark), ts)
	if err != nil {
		return struct{}{}, err
	}

	// (iv) The §8.0 write path: GenerateReport -> WriteReport to cfg.Receiver.
	return struct{}{}, writeReport(cfg, runtime, envelope)
}

// observe is the node-mode observation function. It MUST NOT call GetSecret (NodeRuntime has no
// SecretsProvider, and §8.10 forbids secrets in a consensus observation). It returns a deterministic
// uint64. TEMPLATE: replace the constant with your per-node read.
func observe(_ *Config, _ cre.NodeRuntime) (uint64, error) {
	return templateMark, nil
}

// writeReport generates a §8.0 report from the pre-encoded envelope and writes it to the receiver
// (cre/buyburn-bid/workflow.go:268 idiom).
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
	client := &evm.Client{ChainSelector: cfg.ChainSelector}
	_, err = client.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(cfg.Receiver).Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: writeGasLimit},
	}).Await()
	return err
}
