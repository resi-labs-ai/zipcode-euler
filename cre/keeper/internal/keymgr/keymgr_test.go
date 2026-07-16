package keymgr

import (
	"strings"
	"testing"
)

// Anvil account #3 (the dev creOperator). Key never appears in production output.
const (
	anvilAcct3Key  = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
	anvilAcct3Addr = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
)

func TestLoad_HexKey_KnownAddress(t *testing.T) {
	t.Setenv("KEEPER_OPERATOR_KEY", anvilAcct3Key)
	s, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := s.Address().Hex(); got != anvilAcct3Addr {
		t.Errorf("Address() = %s, want %s", got, anvilAcct3Addr)
	}
}

func TestLoad_HexKey_NoPrefix(t *testing.T) {
	// Unprefixed hex must also load to the same address.
	t.Setenv("KEEPER_OPERATOR_KEY", strings.TrimPrefix(anvilAcct3Key, "0x"))
	s, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := s.Address().Hex(); got != anvilAcct3Addr {
		t.Errorf("Address() = %s, want %s", got, anvilAcct3Addr)
	}
}

func TestLoad_RejectEmpty(t *testing.T) {
	t.Setenv("KEEPER_OPERATOR_KEY", "")
	_, err := Load()
	if err == nil {
		t.Fatal("expected empty key to be rejected")
	}
}

func TestLoad_RejectGarbage(t *testing.T) {
	garbage := "0xnot-a-valid-hex-private-key-zzzz"
	t.Setenv("KEEPER_OPERATOR_KEY", garbage)
	_, err := Load()
	if err == nil {
		t.Fatal("expected garbage key to be rejected")
	}
	// The error must NEVER contain the key material.
	if strings.Contains(err.Error(), garbage) || strings.Contains(err.Error(), "not-a-valid") {
		t.Errorf("error leaked key material: %v", err)
	}
}

func TestErrors_NeverLeakValidKey(t *testing.T) {
	// Even a structurally-near-valid-but-bad key must not be echoed.
	bad := "0x" + strings.Repeat("z", 64)
	t.Setenv("KEEPER_OPERATOR_KEY", bad)
	_, err := Load()
	if err == nil {
		t.Fatal("expected bad key to be rejected")
	}
	if strings.Contains(err.Error(), bad) {
		t.Errorf("error leaked key: %v", err)
	}
}
