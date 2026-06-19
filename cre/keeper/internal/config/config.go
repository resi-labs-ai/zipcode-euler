// Package config loads and validates the keeper service configuration.
//
// The operator private key is deliberately NOT part of Config (it lives only in
// keymgr's input via KEEPER_OPERATOR_KEY) so a Config dump can never leak it.
package config

import (
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// Config is the keeper service configuration. Addresses are re-pointable (§17),
// supplied via env (KEEPER_ADDR_<NAME>) — never hard-coded in Go.
type Config struct {
	RPCURL           string                    `json:"rpc_url"`
	ChainID          uint64                    `json:"chain_id"`
	PollInterval     time.Duration             `json:"poll_interval"`
	GasBufferBps     uint64                    `json:"gas_buffer_bps"`     // gas-limit buffer in bps; 3000 => x1.30 (limit only)
	FeeCapMultiplier uint64                    `json:"fee_cap_multiplier"` // base-fee headroom knob (K3)
	ConfirmTimeout   time.Duration             `json:"confirm_timeout"`
	Modules          map[string]common.Address `json:"modules"` // address book keyed by name

	// MinBurnAmount is the BurnJob floor (KEEPER_MIN_BURN_AMOUNT, base-10). It is
	// env-only — `json:"-"` keeps it OUT of the JSON-file overlay (a *big.Int does
	// not round-trip cleanly through it). Default 0 = burn any non-zero fill;
	// unlike the scalar knobs, an explicit 0 is VALID here (no Validate rule).
	MinBurnAmount *big.Int `json:"-"`

	// ---- StrikeLoopJob knobs (KEEPER-01b, §8.7; TUNABLE / C4 reviewer-flagged) ----
	// Pinned M1 defaults applied before env+Validate; an explicit env 0 is rejected
	// for the bps/price knobs (mirrors the GasBufferBps rule).
	CushionBps         uint64        `json:"cushion_bps"`          // slippage/min-floor cushion in bps (200 = 2%)
	AmberFractionBps   uint64        `json:"amber_fraction_bps"`   // taper fraction in the amber band (5000 = 50%)
	RecycleFractionBps uint64        `json:"recycle_fraction_bps"` // fraction of the floor surplus to recycle (10000 = all)
	HaltPriceUsdc      uint64        `json:"halt_price_usdc"`      // halt below this HYDX price (USDC 6dp; 15000 = $0.015)
	AmberPriceUsdc     uint64        `json:"amber_price_usdc"`     // taper below this HYDX price (USDC 6dp; 18000 = $0.018)
	DeadlineBuffer     time.Duration `json:"deadline_buffer"`      // exercise/sell deadline = now + this (default 300s)
	TwapPeriod         time.Duration `json:"twap_period"`          // ICHI TWAP window for ZipToShares (default 3600s)

	// MaxBorrowPerCycle is the per-cycle borrow ceiling (KEEPER_MAX_BORROW_PER_CYCLE,
	// base-10 USDC 6dp). REQUIRED env (no safe default — it bounds per-cycle
	// exposure). env-only `json:"-"` (a *big.Int does not round-trip the JSON
	// overlay cleanly).
	MaxBorrowPerCycle *big.Int `json:"-"`
}

// defaults returns a Config seeded with the documented default values. Defaults
// are applied BEFORE env + Validate, so an unset KEEPER_GAS_BUFFER_BPS becomes
// 3000 (valid) while an explicit KEEPER_GAS_BUFFER_BPS=0 is rejected.
func defaults() Config {
	return Config{
		PollInterval:     30 * time.Second,
		GasBufferBps:     3000, // x1.30 on the gas LIMIT only
		FeeCapMultiplier: 2,    // base-fee headroom
		ConfirmTimeout:   60 * time.Second,
		Modules:          map[string]common.Address{},
		MinBurnAmount:    big.NewInt(0), // 0 = burn any non-zero fill (explicit 0 is valid)

		// StrikeLoopJob M1 defaults (TUNABLE, C4).
		CushionBps:         200,
		AmberFractionBps:   5000,
		RecycleFractionBps: 10000,
		HaltPriceUsdc:      15000,
		AmberPriceUsdc:     18000,
		DeadlineBuffer:     300 * time.Second,
		TwapPeriod:         3600 * time.Second,
		// MaxBorrowPerCycle has NO default (required env) — left nil so Validate fires.
	}
}

// Load builds a Config: defaults first, then an optional JSON file overlay
// (KEEPER_CONFIG_FILE), then env (env wins), then Validate.
func Load() (*Config, error) {
	cfg := defaults()

	if path := os.Getenv("KEEPER_CONFIG_FILE"); path != "" {
		if err := overlayJSONFile(&cfg, path); err != nil {
			return nil, err
		}
	}

	if err := overlayEnv(&cfg); err != nil {
		return nil, err
	}

	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func overlayJSONFile(cfg *Config, path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("config: reading KEEPER_CONFIG_FILE %q: %w", path, err)
	}
	if err := json.Unmarshal(raw, cfg); err != nil {
		return fmt.Errorf("config: parsing KEEPER_CONFIG_FILE %q: %w", path, err)
	}
	if cfg.Modules == nil {
		cfg.Modules = map[string]common.Address{}
	}
	return nil
}

func overlayEnv(cfg *Config) error {
	if v := os.Getenv("KEEPER_RPC_URL"); v != "" {
		cfg.RPCURL = v
	}
	if v := os.Getenv("KEEPER_CHAIN_ID"); v != "" {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return fmt.Errorf("config: KEEPER_CHAIN_ID %q: %w", v, err)
		}
		cfg.ChainID = n
	}
	if v := os.Getenv("KEEPER_GAS_BUFFER_BPS"); v != "" {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return fmt.Errorf("config: KEEPER_GAS_BUFFER_BPS %q: %w", v, err)
		}
		cfg.GasBufferBps = n
	}
	if v := os.Getenv("KEEPER_FEE_CAP_MULTIPLIER"); v != "" {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return fmt.Errorf("config: KEEPER_FEE_CAP_MULTIPLIER %q: %w", v, err)
		}
		cfg.FeeCapMultiplier = n
	}
	if v := os.Getenv("KEEPER_POLL_INTERVAL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return fmt.Errorf("config: KEEPER_POLL_INTERVAL %q: %w", v, err)
		}
		cfg.PollInterval = d
	}
	if v := os.Getenv("KEEPER_CONFIRM_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return fmt.Errorf("config: KEEPER_CONFIRM_TIMEOUT %q: %w", v, err)
		}
		cfg.ConfirmTimeout = d
	}
	// MinBurnAmount: env-only, base-10 *big.Int. Replace the default ONLY if the
	// var is non-empty (so the seeded 0 survives, per the defaults→json→env order).
	// Reject only an unparseable non-empty value (a Load error, not a Validate
	// rule — any parsed value ≥0 is valid; 0 = burn any non-zero fill).
	if v := os.Getenv("KEEPER_MIN_BURN_AMOUNT"); v != "" {
		n, ok := new(big.Int).SetString(v, 10)
		if !ok {
			return fmt.Errorf("config: KEEPER_MIN_BURN_AMOUNT %q is not a base-10 integer", v)
		}
		cfg.MinBurnAmount = n
	}

	// ---- StrikeLoopJob scalar knobs (uint bps/price; explicit 0 rejected by Validate) ----
	for _, kv := range []struct {
		env string
		dst *uint64
	}{
		{"KEEPER_CUSHION_BPS", &cfg.CushionBps},
		{"KEEPER_AMBER_FRACTION_BPS", &cfg.AmberFractionBps},
		{"KEEPER_RECYCLE_FRACTION_BPS", &cfg.RecycleFractionBps},
		{"KEEPER_HALT_PRICE_USDC", &cfg.HaltPriceUsdc},
		{"KEEPER_AMBER_PRICE_USDC", &cfg.AmberPriceUsdc},
	} {
		if v := os.Getenv(kv.env); v != "" {
			n, err := strconv.ParseUint(v, 10, 64)
			if err != nil {
				return fmt.Errorf("config: %s %q: %w", kv.env, v, err)
			}
			*kv.dst = n
		}
	}
	if v := os.Getenv("KEEPER_DEADLINE_BUFFER"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return fmt.Errorf("config: KEEPER_DEADLINE_BUFFER %q: %w", v, err)
		}
		cfg.DeadlineBuffer = d
	}
	if v := os.Getenv("KEEPER_TWAP_PERIOD"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return fmt.Errorf("config: KEEPER_TWAP_PERIOD %q: %w", v, err)
		}
		cfg.TwapPeriod = d
	}
	// MaxBorrowPerCycle: REQUIRED env, base-10 *big.Int (USDC 6dp). Set only if
	// present; Validate rejects a nil/zero value.
	if v := os.Getenv("KEEPER_MAX_BORROW_PER_CYCLE"); v != "" {
		n, ok := new(big.Int).SetString(v, 10)
		if !ok {
			return fmt.Errorf("config: KEEPER_MAX_BORROW_PER_CYCLE %q is not a base-10 integer", v)
		}
		cfg.MaxBorrowPerCycle = n
	}

	if cfg.Modules == nil {
		cfg.Modules = map[string]common.Address{}
	}
	const prefix = "KEEPER_ADDR_"
	for _, kv := range os.Environ() {
		key, val, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if !strings.HasPrefix(key, prefix) || len(key) == len(prefix) {
			continue
		}
		name := strings.TrimPrefix(key, prefix)
		if val == "" {
			continue
		}
		if !common.IsHexAddress(val) {
			return fmt.Errorf("config: %s=%q is not a valid hex address", key, val)
		}
		cfg.Modules[name] = common.HexToAddress(val)
	}
	return nil
}

// Validate rejects an invalid configuration. Scalar knobs are always checked.
// Address-book entries are checked lazily via MustAddr (a job declares the names
// it needs); unreferenced book entries may be absent/zero.
func (c *Config) Validate() error {
	if c.RPCURL == "" {
		return fmt.Errorf("config: RPCURL is required (KEEPER_RPC_URL)")
	}
	if c.ChainID == 0 {
		return fmt.Errorf("config: ChainID must be non-zero (KEEPER_CHAIN_ID)")
	}
	if c.GasBufferBps == 0 {
		return fmt.Errorf("config: GasBufferBps must be non-zero (KEEPER_GAS_BUFFER_BPS)")
	}
	if c.FeeCapMultiplier == 0 {
		return fmt.Errorf("config: FeeCapMultiplier must be non-zero (KEEPER_FEE_CAP_MULTIPLIER)")
	}
	if c.PollInterval <= 0 {
		return fmt.Errorf("config: PollInterval must be > 0 (KEEPER_POLL_INTERVAL)")
	}
	if c.ConfirmTimeout <= 0 {
		return fmt.Errorf("config: ConfirmTimeout must be > 0 (KEEPER_CONFIRM_TIMEOUT)")
	}

	// ---- StrikeLoopJob scalar knobs (always checked; defaults make bare env valid) ----
	// bps knobs must be in (0, 10000] — an explicit 0 is rejected (mirrors GasBufferBps).
	if c.CushionBps == 0 || c.CushionBps > 10000 {
		return fmt.Errorf("config: CushionBps must be in (0,10000] (KEEPER_CUSHION_BPS)")
	}
	if c.AmberFractionBps == 0 || c.AmberFractionBps > 10000 {
		return fmt.Errorf("config: AmberFractionBps must be in (0,10000] (KEEPER_AMBER_FRACTION_BPS)")
	}
	if c.RecycleFractionBps == 0 || c.RecycleFractionBps > 10000 {
		return fmt.Errorf("config: RecycleFractionBps must be in (0,10000] (KEEPER_RECYCLE_FRACTION_BPS)")
	}
	// price thresholds: 0 < haltPriceUsdc < amberPriceUsdc.
	if c.HaltPriceUsdc == 0 {
		return fmt.Errorf("config: HaltPriceUsdc must be > 0 (KEEPER_HALT_PRICE_USDC)")
	}
	if c.HaltPriceUsdc >= c.AmberPriceUsdc {
		return fmt.Errorf("config: require 0 < HaltPriceUsdc(%d) < AmberPriceUsdc(%d) (KEEPER_HALT_PRICE_USDC/KEEPER_AMBER_PRICE_USDC)", c.HaltPriceUsdc, c.AmberPriceUsdc)
	}
	if c.DeadlineBuffer <= 0 {
		return fmt.Errorf("config: DeadlineBuffer must be > 0 (KEEPER_DEADLINE_BUFFER)")
	}
	if c.TwapPeriod <= 0 {
		return fmt.Errorf("config: TwapPeriod must be > 0 (KEEPER_TWAP_PERIOD)")
	}
	// MaxBorrowPerCycle is NOT checked here — it is a StrikeLoopJob precondition,
	// enforced lazily by MustMaxBorrowPerCycle at job wiring (the same lazy pattern
	// as MustAddr: the spine + a BurnJob-only deploy never reference it).
	return nil
}

// MustMaxBorrowPerCycle returns the required per-cycle borrow ceiling, erroring
// if it was not set (KEEPER_MAX_BORROW_PER_CYCLE unset/empty) or is zero. The
// StrikeLoopJob wiring calls this — lazy validation parallel to MustAddr, so a
// BurnJob-only deployment that never references it is unaffected.
func (c *Config) MustMaxBorrowPerCycle() (*big.Int, error) {
	if c.MaxBorrowPerCycle == nil || c.MaxBorrowPerCycle.Sign() <= 0 {
		return nil, fmt.Errorf("config: MaxBorrowPerCycle is required and must be > 0 (set KEEPER_MAX_BORROW_PER_CYCLE, USDC 6dp)")
	}
	return new(big.Int).Set(c.MaxBorrowPerCycle), nil
}

// MustAddr returns the address registered under name, erroring loudly if a
// referenced name is missing or the zero address. A job/startup-check calls this
// to declare which names it needs (scoped address validation, K1).
func (c *Config) MustAddr(name string) (common.Address, error) {
	addr, ok := c.Modules[name]
	if !ok || addr == (common.Address{}) {
		return common.Address{}, fmt.Errorf("config: required module address %q is missing or zero (set KEEPER_ADDR_%s)", name, name)
	}
	return addr, nil
}
