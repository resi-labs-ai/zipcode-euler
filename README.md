# zipcode-euler

Zipcode protocol contracts, CRE workflows, and docs.

## Run the protocol locally

Needs git, python3, [Foundry](https://getfoundry.sh) (`curl -L https://foundry.paradigm.xyz | bash`, new terminal, `foundryup`),
and a free Base mainnet RPC url from https://www.alchemy.com.

```bash
git clone https://github.com/resi-labs-ai/zipcode-euler.git
cd zipcode-euler
BASE_RPC_URL=<your Base RPC url> ./contracts/script/bootstrap-local.sh
```

That's it. The script forks Base into a local anvil chain, deploys all 33
protocol contracts, and leaves the chain running. First run also clones the
pinned dependencies below (slow once), later runs take a couple of minutes.

You get:

- RPC `http://127.0.0.1:8545`, chainId `8453`
- `contracts/deployments/local/addresses.json` — contract name to address
- `contracts/deployments/local/abi/<ContractName>.json` — the ABIs
- Funded test key (anvil #0, public, never send real funds to it):
  `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

Reset: `pkill anvil`, run the script again, re-read `addresses.json`
(addresses change each run). If it complains port 8545 is in use, `pkill anvil`.

### Pinned dependencies (the script clones these for you)

- `git clone https://github.com/euler-xyz/ethereum-vault-connector.git reference/ethereum-vault-connector` (commit `b9d557a`)
- `git clone https://github.com/euler-xyz/euler-vault-kit.git reference/euler-vault-kit` (commit `5b98b42`)
- `git clone https://github.com/euler-xyz/euler-price-oracle.git reference/euler-price-oracle` (commit `abfbfc9`)
- `git clone https://github.com/euler-xyz/euler-earn.git reference/euler-earn` (commit `b2fd6e6`)
- `git clone https://github.com/euler-xyz/evk-periphery.git reference/evk-periphery` (commit `23ea8c3c`)
- `git clone https://github.com/gnosisguild/zodiac-core.git reference/zodiac-core` (commit `6bf0d41`)
- `git clone https://github.com/smartcontractkit/x402-cre-price-alerts.git reference/x402-cre-price-alerts` (commit `d582019`)
- `git clone https://github.com/smartcontractkit/chainlink-ccip.git reference/chainlink-ccip` (commit `349cdba`)
- `git clone https://github.com/smartcontractkit/chainlink-evm.git reference/chainlink-evm` (commit `fdf8945351`)
- `git clone https://github.com/smartcontractkit/chainlink-local.git reference/chainlink-local` (commit `f8c0efe`)

Full manifest: `reference/MANIFEST.md`.
