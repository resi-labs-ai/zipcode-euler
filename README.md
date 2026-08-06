# zipcode-euler

Zipcode protocol contracts, CRE workflows, and docs.

## Frontend quickstart (local anvil)

One command gives you a local Base fork with every protocol contract deployed,
plus the addresses and ABIs in one folder.

Requirements: git, [Foundry](https://getfoundry.sh) (forge, anvil, cast), python3,
and a Base mainnet RPC url (a free Alchemy/Infura/QuickNode endpoint is fine).

```bash
git clone https://github.com/resi-labs-ai/zipcode-euler.git
cd zipcode-euler
BASE_RPC_URL=<your Base mainnet RPC> ./contracts/script/bootstrap-local.sh
```

The first run clones ~10 pinned dependency repos into `reference/` (see
`reference/MANIFEST.md`), so it is slow once. Every run after that takes a
couple of minutes.

When it finishes, anvil is left running and you have:

- RPC: `http://127.0.0.1:8545`, chainId `8453`
- Addresses: `contracts/deployments/local/addresses.json` (contract name to address)
- ABIs: `contracts/deployments/local/abi/<ContractName>.json`
- Funded test key: anvil account #0
  (`0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`)

To reset the chain, stop anvil and run the script again. The script refuses to
start if port 8545 is already in use, so you never build against stale state.
