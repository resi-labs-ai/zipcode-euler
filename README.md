# zipcode-euler — Build Plan & Index

A decentralized home-equity credit protocol. USDC suppliers mint **zipUSD** (a $1 utility dollar) and zap
into the junior **szipUSD** for yield; KYB'd HELOC originators (already feeding established secondary takeout
markets) draw warehouse credit lines against an on-chain 1/1 lien token, underwritten by a **Chainlink CRE +
Zipcode-subnet** engine and priced by a **Proof**-notarized appraisal. Euler is the first settlement venue;
the engine is venue-agnostic.

**This is the build plan + front door.** The *what/how* is the spec (`claude-zipcode.md`); this doc is the
*who builds what, when, → which §*. Every task below points to the section of the spec that defines it.

---

## 1. Read these in this order

| Doc | What it is |
|---|---|
| [`claude-zipcode.md`](./claude-zipcode.md) | **The spec** — token model, primitives (§3), net-new contracts (§4; venue boundary §4.7), supply/yield (§5), redemption (§6), oracle (§7), CRE (§8), control-flow (§9), lifecycle (§10), loss (§11), NAV/dashboard (§12), trust (§13), demo (§15), repo map (§16), **locked decisions (§17)**, glossary (§18). |
| [`vision.md`](./pending-docs/vision.md) | The *why* — problem, the CRE-underwriter insight, the two tokens, the three structures. |
| [`spv-lien-proof.md`](./pending-docs/spv-lien-proof.md) | The one open off-chain leg: SPV custody + the **Proof** family (lien/value/insurance). Collateral is **mocked** until this lands. **§6 lists the open risks** (Proof capability, insurance product, legal/regulatory, liquidation path). |
| [`audit/`](./audit/) — [`1-results.md`](./audit/1-results.md) / [`2.md`](./audit/2.md) / [`3-results.md`](./audit/3-results.md) | The is-it-garbage layer: **1-results** the money-model proof (accounting reconciles — passed) · **2** the M1 tx-by-tx acceptance harness (Foundry tests) · **3-results** the authority/gating wiring audit (no orphans — passed). The `1.md`/`3.md` proof *protocols* were retired into their results files; `audit/adversarial-spec/` (TBD) attacks beyond the spec. |

(Roadmap that is **not** M1/M2 build spec lives in [§8 Future Development](#8-future-development).)

---

## 2. MVP scope

**In the end-July MVP** — the M1 loop live on **Base mainnet** (Euler venue) + supply side + visible product
(deploy + test on mainnet — the farm/vault deps are 8453-only; see `tickets/PROGRESS.md`):
- **Loop:** underwrite (Proof gates, mocked) → mint lien → seed Proof-of-Value → `openLine/fund/draw` (Erebor)
  → permissionless repay → close → `LienReleased`. (§15)
- **Supply side:** the **zap** (deposit → zipUSD → stake into szipUSD = **Loot**), yield routing, 30-day epoch
  redeem (senior), junior **ragequit** + ~30d **lock** / Duration-Bond **freeze**. (§5/§6)
- **Engine:** Shape-B CRE workflows; the Zipcode-subnet container/DON layer. (§7/§8)
- **Frontend:** `euler-lite` (Vue) with the Inflow surfaces + the solvency dashboard. (§12)

**Explicitly deferred** (do not build for the MVP):
- Full **M2 loss/default machinery** — `DefaultCoordinator`/`LienXAlphaEscrow` are **M1-sketch interfaces only**.
- **Real Proof/SPV integration** — collateral stays mocked.
- **Shape A** (subnet-as-DON), **venue 2** (Aave/Morpho), **structures TWO/THREE** (P2P / MBS), the **post-M1
  xALPHA reward layer** (depositor incentive emission + the zipUSD/xALPHA POL pair + the treasury-buyback closed
  loop, §17). **NOTE — the Hydrex farm loop is NOT deferred:** it is part of the **M1 `szipUSD` vault** (the 8-B
  chain). The **xALPHA CCIP bridge is now pulled INTO M1** (2026-06-06) to source it; dev validates
  builds against a **stand-in test xALPHA token** so nothing stalls on CCT registration (see the §4 bridge note).

**Two clocks:** **2026-06-11 demo** (frontend "real enough" to show) · **end-July MVP** (the above, live).

---

## 3. Locked design decisions (recap — authoritative in `claude-zipcode.md` §17)

1. Cash-reserve ratio → **fixed-%**. 2. Redemption epoch → **30d, no mid-epoch cancel**. 3. **Duration Bond**
+ haircut → governed (≈180d / ≈0.65); fires on default OR duration squeeze. 4. xALPHA price → **CRE feed**.
5. szipUSD = a **Baal/Moloch-v3 Loot share** on a Gnosis Safe basket; **exit = ragequit** (pro-rata, in-kind),
**no cap**, floor on loan exposure; **first-loss = WITHHOLD, not markdown**; zipUSD = **$1 utility**; the **zap**.
6. Surplus recovery → originator/homeowner; shortfalls → **insurance first, xALPHA last-resort (sold for
realized loss, never peg defense)**; unrecoverable residual socializes **passively** (smaller basket → smaller
ragequit slices), never a seizure. 7. Demo → M1 base loop + supply / M2 loss. 8. Valuation → **event-driven
Proof** (no heartbeat/AVM/HPI). 9. Perspectives → **dropped**. 10. **Venue-agnostic**, Euler = config one
(§4.7). 11. Underwriting fabric → **Zipcode subnet** (Shape B for M1, Shape A endgame). 12. Attestation →
the **Proof family** gates before mint.

Full text + rationale: **§17**.

---

## 4. Build tasks — per team

> Conventions: `[ ]` = task; **§** = the defining section in `claude-zipcode.md`. "M2" tasks are deferred
> (sketch only for the MVP).

### WOOF — contracts + wiring (Base mainnet, Euler venue)
**Setup**
- [x] Foundry project; EVK/EVC/oracle deps + `remappings.txt` (model `reference/evk-periphery`). §16 — **materialized + builds green** (`contracts/`, WOOF-00, 2026-06-06); interfaces + Base address book on-chain-verified.
- [x] `reference/` in `.gitignore`; **Base mainnet** RPC + deployer; selector `ethereum-mainnet-base-1`. (RPC in gitignored `contracts/.env`.)

**Deploy + configure (vanilla Euler/OZ/Chainlink — no code change).** §3 / §16
- [ ] `EulerEarn` pool (`EulerEarnFactory`); `setFeeRecipient(szipUSD)`, `setFee(f)`, `setIsAllocator(adapter)`. §9
- [ ] Isolated market via `GenericFactory.createProxy` (model `EdgeFactory`); flat `IRMLinearKink(baseRate,0,0,kink)`;
      `setHookConfig(gatingHook, OP_BORROW|OP_LIQUIDATE)`; `setLTV` (gap=cushion); `setGovernorAdmin(adapter)`. §9
- [ ] Per-line `ROUTER_i` minted + wired `escrowVault→LIEN_i→registry` + frozen (`transferGovernance(0)`) inside `openLine` (NO shared router / NO `govSetFallbackOracle` — per-line-router redesign); OZ `TimelockController` (≈2d) governs §17 params only; cash-reserve fixed-%. §4.1/§4.7/§9
- [ ] `ESynth` (zipUSD) instance; capacity → `ZipDepositModule` + `szipUSD`; **renounce `ESynth` ownership** after. §9

**Build — net-new contracts** (model from the cited reference; build behind the `IZipcodeVenue` boundary, §4.7).
- [x] `LienCollateralToken` (fixed 1e18 @18dec; constant name/symbol; identity=address) + `LienTokenFactory` (CREATE2 salt=keccak256(lienId)). §4.2 — **built + 14/14 tests green** (`contracts/`, 2026-06-06)
- [x] `ZipcodeOracleRegistry` (RedstoneCoreOracle *pattern*; long validity window; mark = Proof-of-Value − senior debt; guards zero/`uint208`/decimals; **no HPI band**; event-driven writes; venue-neutral cache). §4.1 — **built + 34/34 tests green** (`contracts/`, 2026-06-06)
- [x] `CREGatingHook` (EVC `isAccountOperatorAuthorized` operator-check — each line borrows on a fresh per-line account, **borrowDriver/adapter**-as-operator, §4.4; borrow+liquidate gated, repay ungated). §4.3 — **built + 8/8 tests green** (`contracts/`, 2026-06-06; error `NotAuthorizedOperator()` `0x3d9adf1c`)
- [x] `ZipcodeController` (report ABI `(reportType, payload)` with `proofRef`, **no `regionalHPI`**; drives venue via `IZipcodeVenue`; **no EVC handle / no `wireVenueOperator`** — the per-line operator grant is the adapter's `LineAccount` job inside `openLine`, §4.4/§4.7; Forwarder immutability via `renounceOwnership` (base `setForwarderAddress`/`onReport` are non-virtual) + set identity **before** renounce). §4.4 — **MATERIALIZED + BUILT-VERIFIED 2026-06-06** (`contracts/src/ZipcodeController.sol`; `forge build` green + **26/26 tests on a live Base-mainnet fork**, 102/102 total; zero EVC coupling, no-controller-operator-wiring borrow proven; zero-spec-guess keepsake)
- [x] **`IZipcodeVenue` + `EulerVenueAdapter` + `LineAccount`** (openLine — deploys a fresh per-line borrower account (`LineAccount`) + wires the-adapter-as-operator / setLineLimits/fund/draw (operator `batch`)/observeDebt/liquidate; adapter holds the Euler roles). §4.7 — **MATERIALIZED + BUILT-VERIFIED 2026-06-06** (`contracts/src/venue/`; `forge build` green + **20/20 tests on a live Base-mainnet fork**, 76/76 total; EVK/EVC/EulerRouter live, EulerEarn mocked at 0.8.26)
- [ ] `ZipDepositModule` (1:1 mint via `ESynth` + the **`zap`** = deposit→mint→stake; USDC parks in `EulerEarn` with the **`CreditWarehouse` Safe** as the share `receiver`). **RE-AUTHOR after 8-Bw + 8-B2** (the old EE-share-custody / `setStakingVault` / `szipUSD.stake` seam is superseded by the Baal redesign — item-7 obligation). §4.5
- [ ] **`CreditWarehouse` (8-Bw)** — the senior-backing custody **Gnosis Safe** holding the `EulerEarn` pool shares; owner **GOD-EOA → governance multisig**; routine ops (SUPPLY/APPROVE/REDEEM/REPAY) via the **Zodiac Roles Modifier v2** (audited Gnosis Guild infra), scoped by an owner-applied permissions policy + a thin CRE-Forwarder-gated role-member adapter. **No bespoke privileged contract.** §4.5
- [ ] **`szipUSD` = the Baal/Moloch-v3 + Zodiac junior NAV vault (item 8, decomposed into the 8-B chain).** Deposit zipUSD → **Loot**; a **Gnosis Safe** holds the basket (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP gauge-farmed on Hydrex); **exit = ragequit** (pro-rata, in-kind), gated by a ~30-day **lock-shaman** + the Duration-Bond **freeze-shaman**. **NAV tracked from multiple oracles for display, not a redemption primitive.** **First-loss = WITHHOLD, not markdown.** **Depositor return = the HYDX-vamp yield + xALPHA subsidy + Duration-Bond premium** (the real lending APR/fees are the protocol's, privatized → treasury → xALPHA, §17). Strategy modules (deposit/lock-freeze/NAV-oracle/reservoir-borrow/LP/harvest/exercise/range-sell/recycle) are Baal shamans + Zodiac modules driven by a CRE strategy-admin robot. **No cap**; floor on loan exposure. §4.5 / §6.4 / §11
- [ ] `ZipRedemptionQueue` (fork MIT `erc7540-reference` + clean-room Maple pro-rata; 30d epoch, no mid-epoch cancel). §4.5 / §6.1
- [ ] **(M2-sketch)** `LienXAlphaEscrow` (per-lien xALPHA bond custody only — the loss-escrow/share-move half is GONE; `slashXAlphaToCapital` alpha→TAO→USDC last-resort / `slashXAlphaToCohort` in-kind priced premium) + `DefaultCoordinator` (**composed**: default → **freeze/WITHHOLD** the at-risk slice → recovery waterfall (secondary→insurance→xALPHA) → on confirmed shortfall, the **three levers** (sequester+burn the frozen junior's zipUSD / sell junior yield→USDC / sell junior xALPHA→USDC). **No `_realizeMarkdown`, no share-move, no escrow.** §4.6 / §11
- [ ] **(M2)** Systemic **duration-squeeze lock** (Duration Bond **trigger B**): on-chain utilization-floor trigger + a socialized pro-rata **freeze** that **withholds** the at-risk slice from **ragequit** (frozen-but-earning); **no xALPHA premium** (no slash). §11 / §6.4 / §8.2
- [ ] **(resolved — M1 scope)** No on-chain economic liquidation: `liquidate` is a **defensive gate only** (block external seizure of an interest-underwater line); the controller never calls it. Default→resolution is **off-chain** (secondary purchase / insurance + foreclosure) surfaced as permissionless `repay`; the **withhold/recovery** bookkeeping (no markdown) is `DefaultCoordinator` (**M2**). §4.3 / §4.4e / §11

### CRE — Go workflows, Shape B (user or WOOF)
- [ ] Underwriting/origination: `http.Trigger` → node-mode **Proof family** fetch (+ identity/income/credit/title proofs) → identical-consensus → `GenerateReport`/`WriteReport`; **event-driven re-pricing, no heartbeat/Subnet-46/HPI**. §8.1
- [ ] Redemption settle: 30-day `cron.Trigger` → `settleEpoch()`. §8.3
- [ ] xALPHA price feed (Duration Bond premium NAV + szipUSD bonus APR). §7 / §8
- [ ] Project/secrets config; DON-only `GetSecret` (no PII in node-mode consensus). §8
- [ ] **(M2)** Default/recovery report `(lienId, status, foreclosure+insurance)` → `DefaultCoordinator`. §8.4

### Subnet dev — Bittensor / Zipcode subnet
- [ ] Validator/miner **containers**: fetch each API + **zk-verify** (no PII) + consensus. §7 / §8.1
- [ ] **Proof-family fetch** (lien/value/insurance) into the containers. §8.5
- [ ] **DON → CRE (Shape B)** integration — subnet-validated inputs feed a standard Chainlink CRE DON that signs. §7 / §13

### Inflow team — frontend surfaces (Vue, inside `euler-lite`)
- [ ] Originator onboarding surface. §15 (KYB'd originator path)
- [ ] USDC depositor / **zap** UX (deposit → zipUSD → szipUSD). §5
- [ ] Map surfaces onto `euler-lite` pages (earn / borrow / onboarding).
- [ ] Solvency **dashboard** — NAV, zipUSD supply, peg, szipUSD APR, utilization, insurance coverage. §12

### Branding / Designer
- [ ] `euler-lite` (Nuxt/Vue) fork, branded for zipcode (the team convergence point).

### Off-chain / legal (user) — mocked for the MVP, real for production
- [ ] **Proof** integrations (lien/value/insurance notarization API). `spv-lien-proof.md` / §8.5
- [ ] **SPV** custody partner + the on-chain↔legal handoff. `spv-lien-proof.md`
- [ ] **Erebor** dollar leg (off-ramp on draw, on-ramp on repay). §9
- [ ] **Insurance** carrier (the off-chain policy covering capital shortfalls). §11 / `spv-lien-proof.md`
- [ ] **Verify Proof's capability** — can it attest lien / ownership / value / insurance per-lien, in a CRE-consumable form? `spv-lien-proof.md` §6.1
- [ ] **Source the insurance product** — carrier / policy terms / premium for second-lien HELOC default coverage. `spv-lien-proof.md` §6.2
- [ ] **Legal / regulatory scoping** — lending licenses, securities analysis (xALPHA / szipUSD / Duration Bond), SPV structure, KYB/AML. `spv-lien-proof.md` §6.3

### Subgraph / indexing — **owner TBD** (recommend shared WOOF/Inflow or infra)
> **Stack:** a The Graph subgraph for event-aggregated metrics (NAV/APR/utilization history, epochs) + direct
> view reads for cheap point-in-time values (`debtOf`, supply, share price); the frontend queries the subgraph
> directly (GraphQL). Starts once WOOF pins the event signatures; runs concurrently. (Subgraph-vs-custom-indexer
> is a hosting choice — same entity schema; confirm at kickoff.)
- [ ] Index the §9 events: `LienCreated`/`LienReleased`, `Borrow`/`Repay`/`Allocation`, deposit/`zap`/mint, stake/unstake, `EpochSettled`/`Claimable`, `RegistryPriceSeed`; *(M2)* default/Duration-Bond/recovery. Plus pool/registry state: EulerEarn `totalAssets`/`totalSupply`/share-price, per-line `debtOf`, registry `cache[lien]`, zipUSD `totalSupply`, szipUSD shares. §9
- [ ] Derive the §12 dashboard metrics: (1) NAV = idle USDC + marked loan value; (2) zipUSD minted + peg (= secondary-AMM price, §6.2); (3) szipUSD APR + Duration-Bond premium APR; (4) utilization / free liquidity (the §6.3 / §11-trigger-B squeeze early-warning); (5) insurance coverage = on-chain xALPHA fund (`LienXAlphaEscrow`) + CRE-published off-chain policy figure (Proof of Insurance, §8.5). Optionally surface I1–I4 (`audit/1-results.md`) as live solvency indicators. §12

### xALPHA bridge (**M1**) + treasury closed loop (**post-MVP**) — (owner TBD)
> **The xALPHA bridge is now M1 (2026-06-06)** — it sources the xALPHA the M1 `szipUSD` farm-loop basket + the
> first-loss bond require: an xALPHA liquid-staking wrapper over Bittensor subnet alpha + a CCIP (964↔8453)
> bridge. **Build:** [`bridge/xalpha-bridge-impl.md`](./bridge/xalpha-bridge-impl.md) (wrapper + CCT bridge,
> canonical-vs-fork, precompile/ABI map). **Don't stall on external gates** (CCT registration on chain 964, the
> canonical-vs-fork call): **validate builds against a stand-in test xALPHA token** on the Base fork and swap the
> real token in when the lane is live — plan the real path, no blocking. **Still post-MVP:** the closed-loop
> *economics* (treasury buyback / peg-arb / POL / depositor incentive budget) — [`pending-docs/treasury.md`](./pending-docs/treasury.md);
> it consumes the protocol, not the reverse.
- [ ] ~~**`sdVAULT` — separate szipUSD/xALPHA autocompounder**~~ **FOLDED INTO item 8 (2026-06-06).** The
      auto-sodomizer engine (ICHI-LP-on-Hydrex + the oHYDX farm/exercise/range-sell/recycle loop + the CRE harvest
      robot) is **no longer a separate post-MVP `sdVAULT`** — it **IS** the `szipUSD` vault's core strategy set
      (Baal shamans + Zodiac modules), now specced in `claude-zipcode.md` §4.5 and decomposed into the **8-B
      ticket chain** (WOOF item 8 above; full design `pending-docs/auto-sodomizer.md`). **Yield routing is
      RESOLVED** (real lending yield is the protocol's → treasury → buys xALPHA; depositors subsidized by xALPHA +
      the HYDX/USDC pool, §17). **SCOPE RESOLVED (2026-06-06):** the **full Hydrex farm loop is IN the M1 staking
      vault** — the whole 8-B chain (incl. 8-B5…8-B11: reservoir/borrow, LP, harvest, exercise, range-sell,
      recycle, CRE robot) is M1, not deferred. **xALPHA source RESOLVED (2026-06-06):** the **CCIP bridge is
      pulled INTO M1** (it feeds the basket + the bond), and **dev validates builds against a stand-in test xALPHA
      token** — plan the real lane, don't block on CCT registration. §4.5 / `auto-sodomizer.md`
- [ ] Decide canonical xAlpha vs self-built `szALPHA` fork (economic call → `pending-docs/treasury.md`).
- [ ] Resolve the open CCT-registration gate on chain 964 (testnet-945 attempt or Chainlink ping) — **plan it, don't block; dev validates against a stand-in test xALPHA token meanwhile.** `bridge/xalpha-bridge-impl.md` §4
- [ ] Build per the chosen path: wrapper over public Subtensor precompiles + CCT pool (964↔8453). `bridge/xalpha-bridge-impl.md` §5–6

---

## 5. Sequencing — first vs concurrent

**Now → the 2026-06-11 demo:** the visible piece is the **Inflow + Designer** frontend (`euler-lite` fork +
branding + Vue surfaces). Subnet, CRE, and off-chain are **represented as mock** at the demo.

**Concurrent tracks toward end-July:**
1. **WOOF** — net-new contracts behind `IZipcodeVenue` + the vanilla-Euler wiring.
2. **Subnet dev** — containers + Proof fetch + DON integration.
3. **CRE** — origination + redemption workflows.
4. **Off-chain** — Proof/SPV/insurance; **partly blocked → mocked** so it doesn't gate M1.
5. **Subgraph** — indexing + metrics (feeds the dashboard).

**Critical path = the M1 loop on Base mainnet:** vanilla-Euler config + the net-new contracts + the CRE
origination workflow. Because **collateral is mocked**, the open off-chain leg does **not** block the M1
build (§15) — that's the point of mocking it. Frontend + subgraph run in parallel and converge on the live
loop for the end-July MVP.

---

## 6. Genuinely open (off-chain/integration — not Solidity blockers)
- **SPV custody partner + Proof integrations** — Proof addresses the attestation; the SPV partner, the
  Proof-of-Insurance policy terms, and the CRE wiring of each Proof endpoint are still to pin
  (`spv-lien-proof.md`). Collateral mocked until they land.
- **Shape A (subnet-as-DON)** — the endgame where subnet validators are the signing DON; requires Chainlink
  provisioning; not M1-blocking (§7/§13).

---

## 7. Repo layout & conventions

Where each §4 task's deliverable lands (the "Deliverable" path on every ticket resolves here):

```
zipcode-euler/
├── README.md  claude-zipcode.md  nextsteps.md   # build map · the spec · handoff
├── kickoff.md  superintendent.md   # ticket-authoring: builder-window prompt · persistent reviewer role
├── tickets/          # the authored tickets (the product)
│   ├── PROGRESS.md   # process ledger — DONE/NEXT, open spec gaps ("what's next")
│   ├── LEDGER.md     # component design digest + cross-ticket obligations (final review)
│   └── woof/ …       # per-team ticket folders
├── reports/          # one builder-window report per item → the superintendent's review trail
├── pending-docs/     # decide / why / open — not the contract build spec
│   └── vision.md  spv-lien-proof.md  treasury.md
├── bridge/           # post-MVP xALPHA workstream (pairs with pending-docs/treasury.md)
│   └── xalpha-bridge-impl.md  xALPHA-apr.md
├── audit/            # is-it-garbage layer: conformance oracles + adversarial probing
│   ├── 1-results.md  # money-model proof (I1–I4 invariants + golden numbers)
│   ├── 2.md          # M1 tx-by-tx acceptance harness (→ contracts/test/)
│   ├── 3-results.md  # authority/gating audit (matrix + negative-test source)
│   └── adversarial-spec/   # multi-model debate (the reference/adversarial-spec plugin) — our config/findings
├── reference/        # read-only reference repos (already here)
├── contracts/        # Foundry — WOOF
│   ├── src/
│   │   ├── LienCollateralToken.sol  LienTokenFactory.sol
│   │   ├── ZipcodeOracleRegistry.sol  CREGatingHook.sol  ZipcodeController.sol
│   │   ├── venue/    IZipcodeVenue.sol  EulerVenueAdapter.sol
│   │   ├── supply/   ZipDepositModule.sol  ZipRedemptionQueue.sol
│   │   │   ├── szipUSD/        # the Baal/Moloch-v3 + Zodiac junior vault (item 8 / 8-B): Loot + Safe basket +
│   │   │   │                   #   shamans (deposit/lock-freeze) + Zodiac strategy modules + CRE robot
│   │   │   └── CreditWarehouse/ # senior EE-share custody Safe + Zodiac Roles Modifier v2 admin + CRE adapter (8-Bw)
│   │   └── loss/     LienXAlphaEscrow.sol  DefaultCoordinator.sol   # M2 — xALPHA bond custody + withhold/3-lever
│   ├── script/       # deployment / wiring
│   ├── test/         # Foundry tests = the audit/2.md acceptance + the audit/1-results.md invariants
│   └── foundry.toml  remappings.txt
├── cre/              # Go CRE workflows (wasip1) — CRE team
├── subnet/           # Bittensor containers + Proof fetch — subnet dev
├── subgraph/         # indexing — TBD owner
└── frontend/         # the euler-lite (Vue) fork, branded + Inflow surfaces — Inflow + Designer
```

**Conventions**
- **`reference/` is read-only.** Model from it, never edit it. It holds the Euler / CRE / 3Jane / euler-lite
  source that everything is built against.
- **One contract per file**, named exactly as the symbol (`ZipcodeOracleRegistry.sol`). Folders group by
  role: `venue/` (the `IZipcodeVenue` boundary), `supply/`, `loss/` (M2-sketch).
- **Ownership by folder:** `contracts/` = WOOF · `cre/` = CRE · `subnet/` = subnet dev · `subgraph/` = TBD ·
  `frontend/` = Inflow + Designer.
- **One deliverable path per task:** each §4 task produces the file at its path here (e.g. the
  `EulerVenueAdapter` task → `contracts/src/venue/EulerVenueAdapter.sol`).

---

## 8. Future Development

Post-MVP structured-product components that are **designed but deliberately out of the M1/M2 build spine**. Not
blockers, not authored as tickets yet — captured here so the intent is not lost. Pull each into the regular
one-item-per-window ticketing when its dependencies land.

### 8-B9b — Patient range-sell module (HYDX→USDC spike-harvesting LP)

**What it is.** A second HYDX→USDC selling mode that *complements* (does **not** replace) the 8-B9 `SellModule`
immediate market-sell. The HYDX/USDC pool is thin and net-draining, so a weekly market-sell bleeds ~3% slippage
(~$10k on a 300k-HYDX clip — acceptable, "gets the job done"). But HYDX **spikes roughly once every 6–8 weeks**, and
patient liquidity can sell *into* those spikes at far better prices than dumping into a dead pool.

**Mechanism (a single-sided concentrated sell ladder).**
- Deposit **single-sided HYDX** as an Algebra/UniV3-style concentrated-liquidity band, **+5% → +50% above the
  deposit mark price** (a passive sell ladder: as price rises through the band, the position auto-converts HYDX →
  USDC). This is the HYDX/USDC **UniV3-style deposit capacity that lives OUTSIDE the ICHI vault** (distinct from the
  8-B6 ICHI ALM position).
- **Auto-withdraw** the LP once price reaches **+50% from the initial deposit mark** (the position is then mostly/
  fully USDC); collect + close.
- Plumbing = the Algebra **NonfungiblePositionManager** (`mint`/`decreaseLiquidity`/`collect`/`burn`) — the
  `INonfungiblePositionManager` interface already exists in the repo (Algebra `deployer` field verified). This is a
  **new Zodiac module** (NFPM-driven, recipient-pinned to the engine Safe) **plus a new CRE automator** to manage
  deposit timing + the +50% withdrawal trigger. (Reconciles the superseded "UP-regime range-rest of the residual"
  note in `pending-docs/auto-sodomizer.md §9.1` / `hydrex.md §9.1` — that ladder is THIS module, now specced.)

**The tension that keeps it a COMPLEMENT, not a replacement.** The strike-repay leg carries an **open borrow accruing
interest** (8-B5) and an unstaked LP slice (no emissions) — it cannot wait 6–8 weeks for a spike, so it MUST stay the
8-B9 immediate market-sell. Patient range-sell fits only the **non-time-critical HYDX**: the residual/free-value HYDX
above the strike, the veHYDX-rebase HYDX, and any regime where the strike is treasury-USDC-financed (no borrow). So
the mature engine runs **8-B9 (immediate, repay leg) + 8-B9b (patient, spike-harvest) side by side**, the CRE robot
routing each clip to the right path.

**Depends on.** 8-B9 (the immediate baseline) + a new CRE automator + the out-of-ICHI HYDX/USDC range capacity.
**Status:** deferred (M2/post-MVP), tracked as `8-B9b` in `tickets/PROGRESS.md`.
- **Foundry:** `remappings.txt` models `reference/evk-periphery/remappings.txt`; deps point into `reference/`.
  Tests in `contracts/test/` **are** the acceptance harness — `audit/2.md` (tx-by-tx M1) + the I1–I4
  invariants (`audit/1-results.md`).
- **`frontend/` is a fork of `reference/euler-lite`** (Nuxt/**Vue**), branded; Inflow authors surfaces in Vue
  inside it (not React).
- **`cre/` workflows are Go → `wasip1`** (model `reference/cre-sdk-go/standard_tests`).
- **`subnet/`** holds the validator/miner container code + the Proof-family fetch; feeds CRE (Shape B).
- **The spec is the source of truth.** Every file traces to a `claude-zipcode.md` § (see §4 above).
  Don't invent mechanisms the spec doesn't define — log it as a finding.
- **`loss/` is M2-sketch** (interface sketches only for the MVP; full state machines detailed before M2).
