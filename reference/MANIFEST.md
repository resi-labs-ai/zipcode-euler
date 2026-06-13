# reference/ — upstream repo manifest

The `reference/` tree (~5 GB, 48 cloned upstream repos, each with its own `.git`) is **gitignored**
— too large to vendor. This manifest pins every reference repo to its upstream URL + the exact commit
checked out locally, so anyone can reproduce it:

```bash
# clone one back into reference/ at the pinned commit:
git clone <url> reference/<name> && git -C reference/<name> checkout <commit>
```

## Tracked exception: `reference/rubicon/` (NOT a clone)
Small curated reference, **tracked in this repo** (gitignore-negated): Project Rubicon's verified
`LiquidStakedV3` source fetched 2026-06-12 from the Taostats explorer (implementation
`0x395d0996C345b6e16590dB82917c1BFb00577fba` on 964) + the live address book / audit links.
The 8x-01 bridge rework's proven-pattern provenance — see `reference/rubicon/README.md`.

## Other cloned bases (outside `reference/`, also gitignored)
| Path | Upstream URL | Pinned commit |
|---|---|---|
| `frontend/euler-lite` | https://github.com/euler-xyz/euler-lite.git | `b497117` |

## `reference/` repos
| Repo | Upstream URL | Pinned commit |
|---|---|---|
| `adversarial-spec` | https://github.com/zscole/adversarial-spec.git | `f90cf0c` |
| `baal-docs` | https://github.com/HausDAO/baal-docs.git | `75d6208` |
| `Baal` | https://github.com/HausDAO/Baal | `ee3d5ab` |
| `ccip-starter-kit-foundry` | https://github.com/smartcontractkit/ccip-starter-kit-foundry.git | `da26a78` |
| `centrifuge-liquidity-pools` | https://github.com/centrifuge/liquidity-pools.git | `e556c1a` |
| `chain-selectors` | https://github.com/smartcontractkit/chain-selectors.git | `c0421bd` |
| `chainlink-agent-skills` | https://github.com/smartcontractkit/chainlink-agent-skills.git | `d0c44cb` |
| `chainlink-ccip` | https://github.com/smartcontractkit/chainlink-ccip.git | `349cdba` |
| `chainlink-common` | https://github.com/smartcontractkit/chainlink-common.git | `37abc9ba` |
| `chainlink-datastreams-consumer` | https://github.com/euler-xyz/chainlink-datastreams-consumer.git | `01b9ed7` |
| `chainlink-evm` | https://github.com/smartcontractkit/chainlink-evm.git | `fdf8945351` |
| `chainlink-local` | https://github.com/smartcontractkit/chainlink-local.git | `f8c0efe` |
| `chainlink` | https://github.com/smartcontractkit/chainlink.git | `67f9a4b233` |
| `cre-bootcamp-2026` | https://github.com/smartcontractkit/cre-bootcamp-2026.git | `7e91d57` |
| `cre-cli` | https://github.com/smartcontractkit/cre-cli.git | `e414fa0` |
| `cre-sdk-go` | https://github.com/smartcontractkit/cre-sdk-go.git | `e2215d1` |
| `cre-sdk-typescript` | https://github.com/smartcontractkit/cre-sdk-typescript.git | `c4feb0d` |
| `cre-templates` | https://github.com/smartcontractkit/cre-templates.git | `c3944e9` |
| `dao-app-starter-vite` | https://github.com/HausDAO/dao-app-starter-vite.git | `e2c0a6f` |
| `daohaus-admin` | https://github.com/HausDAO/daohaus-admin.git | `9190b69` |
| `dev-docs` | https://github.com/HausDAO/dev-docs.git | `ecff721` |
| `docs` | https://github.com/base/docs.git | `27d229f` |
| `documentation` | https://github.com/smartcontractkit/documentation.git | `f5a1a71e` |
| `erc7540-reference` | https://github.com/ERC4626-Alliance/ERC-7540-Reference.git | `1ea70cc` |
| `ethereum-vault-connector` | https://github.com/euler-xyz/ethereum-vault-connector.git | `b9d557a` |
| `euler-earn` | https://github.com/euler-xyz/euler-earn.git | `b2fd6e6` |
| `euler-interfaces` | https://github.com/euler-xyz/euler-interfaces.git | `36b8982` |
| `euler-lite` | https://github.com/euler-xyz/euler-lite.git | `b4971171` |
| `euler-price-oracle` | https://github.com/euler-xyz/euler-price-oracle.git | `abfbfc9` |
| `euler-sdks` | https://github.com/euler-xyz/euler-sdks.git | `f7c58e6` |
| `euler-vault-kit` | https://github.com/euler-xyz/euler-vault-kit.git | `5b98b42` |
| `evk-periphery` | https://github.com/euler-xyz/evk-periphery.git | `23ea8c3c` |
| `evm-bittensor` | https://github.com/opentensor/evm-bittensor.git | `0b8eb3e` |
| `haus-tx-prepper` | https://github.com/HausDAO/haus-tx-prepper.git | `a2a0209` |
| `maple-withdrawal-manager` | https://github.com/maple-labs/withdrawal-manager.git | `b892d73` |
| `moloch-agent` | https://github.com/HausDAO/moloch-agent.git | `a3233de` |
| `moloch-skills` | https://github.com/HausDAO/moloch-skills.git | `408ea97` |
| `moneymarket-contracts` | https://github.com/3jane-protocol/moneymarket-contracts.git | `fb6c03e9` |
| `permissions-starter-kit` | https://github.com/gnosisguild/permissions-starter-kit.git | `d0aba7e` |
| `subtensor` | https://github.com/opentensor/subtensor.git | `1104f2a` |
| `x402-cre-price-alerts` | https://github.com/smartcontractkit/x402-cre-price-alerts.git | `d582019` |
| `zipcode-finance-server-prototype` | (not a git repo — local files) | — |
| `zipcode-finance-ui-prototype` | (not a git repo — local files) | — |
| `zodiac-core` | https://github.com/gnosisguild/zodiac-core.git | `6bf0d41` |
| `zodiac-guard-scope` | https://github.com/gnosisguild/zodiac-guard-scope.git | `3c5dcaf` |
| `zodiac-modifier-roles` | https://github.com/gnosisguild/zodiac-modifier-roles.git | `5501e32` |
| `zodiac-module-reality` | https://github.com/gnosisguild/zodiac-module-reality.git | `eee88bf` |
| `zodiac-safe-app` | https://github.com/gnosisguild/zodiac-safe-app.git | `e1b17ca` |
| `zodiac-wiki` | https://github.com/gnosisguild/zodiac-wiki.git | `224ff20` |
| `zodiac` | https://github.com/gnosisguild/zodiac | `36d0117` |
