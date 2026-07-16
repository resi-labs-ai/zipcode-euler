// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-01a — the WOOF-02 gas-bounded revaluation producer (§8.1) → ZipcodeOracleRegistry (reportType 3).
//
// An off-chain Proof-of-Value re-appraisal batch arrives via the http trigger. The workflow reaches
// IDENTICAL consensus on the (lien, mark) set, validates + dedups the full sweep, enforces equal-length,
// SHARDS into gas-bounded batches sized to MAX_LIENS_PER_REPORT, and emits ONE WriteReport per shard to the
// ZipcodeOracleRegistry as the §8.0 envelope abi.encode(uint8 reportType=3, bytes payload) where
// payload = abi.encode(address[] liens, uint256[] prices, uint32 ts). Encoding is delegated to the shared
// cre/zipreport library (zipreport.Revaluation, CRE-00) — this slice does NOT re-implement the handshake.
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

// defaultMaxLiensPerReport is the MAX_LIENS_PER_REPORT shard cap (§8.1) — a TUNABLE constant "calibrated on
// the target chain." The on-chain _processReport loop is O(n) with a per-entry decimals() staticcall + SSTORE,
// so 50 keeps a shard's processing well under the report GasLimit. Tune it on the target chain.
const defaultMaxLiensPerReport = 50

// defaultWriteGasLimit is the WriteReport GasConfig.GasLimit fallback (used when cfg.WriteGasLimit == 0).
const defaultWriteGasLimit = uint64(600_000)

// Config is the static workflow config (parsed once at init via cre.ParseJSON[Config]). Every wiring slot
// (§17) is Config-driven and re-pointable — no hardcoded address. NOTE: the per-invocation re-appraisal batch
// is NOT carried here — it arrives on the http trigger payload (see onReappraisal / K3).
type Config struct {
	ChainSelector     uint64   `json:"chainSelector"`     // the chain hosting the ZipcodeOracleRegistry
	Registry          string   `json:"registry"`          // the ZipcodeOracleRegistry receiver address (§17)
	MaxLiensPerReport int      `json:"maxLiensPerReport"` // the shard cap; <= 0 falls back to 50 (TUNABLE)
	WriteGasLimit     uint64   `json:"writeGasLimit"`     // WriteReport gas limit; 0 falls back to 600_000
	AuthorizedKeys    []string `json:"authorizedKeys"`    // optional; reserved for http.Config (left empty here)
}

// Marks is the consensus carrier (K2): parallel []string slices ONLY — unambiguously isIdenticalType +
// values.Wrap-able + JSON-native. Do NOT put []common.Address / []*big.Int here; parse on the DON side AFTER
// consensus. The lowercase liens/prices JSON tags are the off-chain feed contract (the wire shape K3 pins).
type Marks struct {
	Liens  []string `json:"liens"`  // hex lien-token addresses (the registry key)
	Prices []string `json:"prices"` // base-10 decimal strings of the 18-dp equity marks
}

// Shard is one gas-bounded, parsed-and-validated batch ready for zipreport.Revaluation.
type Shard struct {
	Liens  []common.Address
	Prices []*big.Int
}

func initFn(_ *Config, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[*Config], error) {
	// One trigger: http.Trigger (§8.1 — revaluation is http/event-driven, NO cron heartbeat). An empty
	// &httpcap.Config{} (no AuthorizedKeys) is valid for the build; keys are Config-driven when wired live.
	return cre.Workflow[*Config]{
		cre.Handler(httpcap.Trigger(&httpcap.Config{}), onReappraisal),
	}, nil
}

// onReappraisal is the single handler. It runs in DON mode and holds payload.Input ([]byte, the JSON batch
// body). It: (i) reaches identical consensus on the Marks carrier in node mode; (ii) validates + dedups +
// shards (shardRevaluation); (iii) stamps a single DON ts; (iv) encodes each shard via zipreport.Revaluation
// and emits one WriteReport per shard.
func onReappraisal(cfg *Config, runtime cre.Runtime, payload *httpcap.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// (i) Node-mode observation + identical consensus over the Marks carrier. The first type-param C of
	// RunInNodeMode is a FREE generic = []byte: we pass the raw trigger bytes verbatim into observe (NOT the
	// workflow *Config — *Config has no per-invocation trigger body; see K3).
	marks, err := cre.RunInNodeMode(payload.Input, runtime, observe,
		cre.ConsensusIdenticalAggregation[Marks]()).Await()
	if err != nil {
		return struct{}{}, err
	}

	// No-op fail-safe (K4): empty marks ⇒ no write; unset Registry ⇒ no write.
	if len(marks.Liens) == 0 && len(marks.Prices) == 0 {
		logger.Info("revaluation: no-op (empty marks)")
		return struct{}{}, nil
	}
	if cfg.Registry == "" {
		logger.Info("revaluation: no-op (registry unset)")
		return struct{}{}, nil
	}

	// (ii) Validate → dedup → shard (the WOOF-02 core). Pure + table-testable.
	maxPer := cfg.MaxLiensPerReport
	if maxPer <= 0 {
		maxPer = defaultMaxLiensPerReport
	}
	shards, err := shardRevaluation(marks, maxPer)
	if err != nil {
		return struct{}{}, err
	}
	logger.Info("revaluation: sharded", "totalLiens", len(marks.Liens), "shards", len(shards), "maxPer", maxPer)

	// (iii) DON-side single timestamp shared across all shards of this sweep. uint32(runtime.Now().Unix()) is
	// always <= chain time (DON time ≈ chain time), so the registry's FutureTimestamp guard never trips; and
	// runtime.Now() is monotonic across distinct sweeps, so StaleReport holds in normal operation.
	ts := uint32(runtime.Now().Unix())

	// (iv) One WriteReport per shard, each independently atomic on-chain. A shard write error is returned
	// (fail-safe: the §8.1 model tolerates a failed shard — its liens stay on the prior mark until next push).
	for i, shard := range shards {
		envelope, err := zipreport.Revaluation(shard.Liens, shard.Prices, ts)
		if err != nil {
			return struct{}{}, fmt.Errorf("shard %d encode: %w", i, err)
		}
		if err := writeReport(cfg, runtime, envelope); err != nil {
			return struct{}{}, fmt.Errorf("shard %d write: %w", i, err)
		}
	}
	return struct{}{}, nil
}

// observe is the node-mode observation function. It returns the Marks carrier for identical consensus.
//
// §8.9 MOCK FEED — replace this json.Unmarshal of the trigger batch with a per-node
// httpcap.Client.SendRequest to the real Proof-of-Value feed + on-node hash/cert-chain verify (§8.10) when
// the endpoints integrate; the RunInNodeMode + consensus + shard + write machinery is unchanged. For the
// build, every node json.Unmarshals the identical trigger-supplied batch (deterministic → identical
// consensus holds).
//
// MUST NOT call runtime.GetSecret: NodeRuntime has no SecretsProvider, and §8.1 forbids secrets in a
// consensus observation. Any DON-only secret read (none needed this slice) stays in the handler.
func observe(in []byte, _ cre.NodeRuntime) (Marks, error) {
	var m Marks
	if err := json.Unmarshal(in, &m); err != nil {
		return Marks{}, fmt.Errorf("observe: unmarshal marks: %w", err)
	}
	return m, nil
}

// shardRevaluation validates, dedups, and shards a consensus Marks set into gas-bounded batches. Pure +
// table-testable (the WOOF-02 core, K4):
//  1. length-equal len(Liens) == len(Prices) (error early — do NOT rely on the on-chain LengthMismatch);
//  2. parse each lien (validate hex FIRST — common.HexToAddress silently zero-pads bad input; reject the zero
//     address) + price (new(big.Int).SetString(s,10); reject ok==false AND zero);
//  3. dedup across the FULL sweep — a lien appearing twice is an error (fail-closed; on-chain it is silent
//     last-write-wins, a footgun §8.1 mandates the producer prevent);
//  4. shard into batches of <= maxPer, preserving order.
func shardRevaluation(m Marks, maxPer int) ([]Shard, error) {
	if len(m.Liens) != len(m.Prices) {
		return nil, fmt.Errorf("shardRevaluation: len(liens)=%d != len(prices)=%d (LengthMismatch)", len(m.Liens), len(m.Prices))
	}
	if maxPer <= 0 {
		return nil, fmt.Errorf("shardRevaluation: maxPer must be > 0, got %d", maxPer)
	}

	n := len(m.Liens)
	liens := make([]common.Address, 0, n)
	prices := make([]*big.Int, 0, n)
	seen := make(map[common.Address]struct{}, n)

	for i := 0; i < n; i++ {
		addr, err := parseLien(m.Liens[i])
		if err != nil {
			return nil, fmt.Errorf("shardRevaluation: lien[%d]=%q: %w", i, m.Liens[i], err)
		}
		if _, dup := seen[addr]; dup {
			return nil, fmt.Errorf("shardRevaluation: duplicate lien %s (fail-closed dedup)", addr.Hex())
		}
		seen[addr] = struct{}{}

		price, ok := new(big.Int).SetString(m.Prices[i], 10)
		if !ok {
			return nil, fmt.Errorf("shardRevaluation: price[%d]=%q: not a base-10 integer", i, m.Prices[i])
		}
		if price.Sign() <= 0 {
			return nil, fmt.Errorf("shardRevaluation: price[%d]=%q: must be > 0 (on-chain price==0 guard)", i, m.Prices[i])
		}

		liens = append(liens, addr)
		prices = append(prices, price)
	}

	shards := make([]Shard, 0, (n+maxPer-1)/maxPer)
	for start := 0; start < n; start += maxPer {
		end := start + maxPer
		if end > n {
			end = n
		}
		shards = append(shards, Shard{
			Liens:  liens[start:end],
			Prices: prices[start:end],
		})
	}
	return shards, nil
}

// parseLien validates a hex address string BEFORE conversion. common.HexToAddress does NOT error on bad input
// (it silently zero-pads/truncates), so a malformed feed entry would become address(0) and corrupt a mark —
// validate the hex (0x prefix + 40 hex chars) and reject the zero address first.
func parseLien(s string) (common.Address, error) {
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

// writeReport generates a §8.0 report from the pre-encoded envelope and writes it to the registry receiver.
// Copied verbatim from cre/scaffold/workflow.go (the proven WriteReport idiom), with the gas limit + receiver
// taken from Config.
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
		Receiver:  common.HexToAddress(cfg.Registry).Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: gasLimit},
	}).Await()
	return err
}
