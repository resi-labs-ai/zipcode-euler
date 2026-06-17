// Package keymgr loads the operator hot key and signs transactions.
//
// SECURITY: the private key is NEVER logged, NEVER placed in an error string,
// NEVER embedded in Config. Only Address() is ever exposed.
package keymgr

import (
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"os"

	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// Signer holds the operator key and signs EIP-1559 transactions. The key is
// unexported and never surfaced.
type Signer struct {
	key  *ecdsa.PrivateKey
	addr common.Address
}

// Load reads the operator key. The primary path is the 0x-hex 32-byte key in
// KEEPER_OPERATOR_KEY. A documented secondary path is a geth keystore file via
// KEEPER_KEYSTORE_FILE + KEEPER_KEYSTORE_PASSWORD.
//
// Errors are loud but NEVER contain the key material.
func Load() (*Signer, error) {
	if ksPath := os.Getenv("KEEPER_KEYSTORE_FILE"); ksPath != "" {
		return loadKeystore(ksPath, os.Getenv("KEEPER_KEYSTORE_PASSWORD"))
	}

	hexKey := os.Getenv("KEEPER_OPERATOR_KEY")
	if hexKey == "" {
		return nil, errors.New("keymgr: KEEPER_OPERATOR_KEY is empty (set the operator hot key, 0x-hex)")
	}
	return LoadHex(hexKey)
}

// LoadHex builds a Signer from a 0x-hex (or unprefixed) 32-byte private key.
// The error is generic by design — it NEVER contains the key material.
func LoadHex(hexKey string) (*Signer, error) {
	// crypto.HexToECDSA accepts an unprefixed hex string.
	key, err := crypto.HexToECDSA(strip0x(hexKey))
	if err != nil {
		return nil, errors.New("keymgr: operator key is not a valid 0x-hex 32-byte private key")
	}
	return fromKey(key), nil
}

func loadKeystore(path, password string) (*Signer, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("keymgr: reading KEEPER_KEYSTORE_FILE %q: %w", path, err)
	}
	acct, err := keystore.DecryptKey(raw, password)
	if err != nil {
		// Do not surface the password or key — generic message.
		return nil, errors.New("keymgr: failed to decrypt keystore (bad file or KEEPER_KEYSTORE_PASSWORD)")
	}
	return fromKey(acct.PrivateKey), nil
}

func fromKey(key *ecdsa.PrivateKey) *Signer {
	return &Signer{
		key:  key,
		addr: crypto.PubkeyToAddress(key.PublicKey),
	}
}

// Address returns the operator address derived from the loaded key. This is the
// ONLY identifying value exposed about the key.
func (s *Signer) Address() common.Address { return s.addr }

// SignTx signs an EIP-1559 transaction for the given chainID.
func (s *Signer) SignTx(tx *types.Transaction, chainID *big.Int) (*types.Transaction, error) {
	return types.SignTx(tx, types.LatestSignerForChainID(chainID), s.key)
}

func strip0x(h string) string {
	if len(h) >= 2 && (h[:2] == "0x" || h[:2] == "0X") {
		return h[2:]
	}
	return h
}
