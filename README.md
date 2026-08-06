# zipcode-euler

Zipcode protocol contracts, CRE workflows, and docs.

## Frontend quickstart (local anvil)

This gives you a private copy of the protocol running on your own machine.
One script starts a local blockchain (a fork of Base mainnet), deploys every
protocol contract onto it, and writes the contract addresses and ABIs into
one folder for the frontend to read.

### 1. Install the tools (once)

- git, if you don't have it already.
- python3 (macOS ships with it; `python3 --version` should print a version).
- Foundry, the Ethereum toolkit. Install with:

  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  ```

  then open a NEW terminal and run `foundryup`. Check it worked:
  `forge --version` and `anvil --version` should both print a version.

### 2. Get a Base RPC url (once)

The local chain is a fork of Base mainnet, so it needs a url to read real
Base state from. Make a free account at https://www.alchemy.com (or Infura,
or QuickNode), create an app for "Base Mainnet", and copy its HTTPS url.
It looks like `https://base-mainnet.g.alchemy.com/v2/xxxxx`.

### 3. Run it

```bash
git clone https://github.com/resi-labs-ai/zipcode-euler.git
cd zipcode-euler
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/xxxxx ./contracts/script/bootstrap-local.sh
```

Paste your own url from step 2 in place of the `https://...` value.

The FIRST run downloads about 10 dependency repos and can take a while.
Runs after that take a couple of minutes.

### 4. What you get

When the script prints `DONE`, the local chain is running in the background
and keeps running after the script exits. You now have:

- A local RPC at `http://127.0.0.1:8545`, chainId `8453`. Point the frontend
  (or MetaMask) at this.
- `contracts/deployments/local/addresses.json` — every deployed contract,
  name to address.
- `contracts/deployments/local/abi/` — one ABI file per contract, named
  `<ContractName>.json`.
- A pre-funded test account to send transactions from. Its private key is
  anvil's standard test key
  `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`.
  This key is public and used by everyone's local anvil. Never send real
  funds to it.

### 5. Resetting or stopping

The chain lives only in memory. To stop it:

```bash
pkill anvil
```

To start fresh, stop it and run the step-3 script command again (from the
`zipcode-euler` folder; no need to clone again). Addresses change on every
fresh run, so re-read `addresses.json` after a reset.

If the script says port 8545 is already in use, that is a previous chain
still running. Stop it with `pkill anvil` first. This is deliberate: it
stops you from accidentally building against a stale chain.
