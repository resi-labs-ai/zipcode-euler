# reports/design/baal-spec.md — full DRAFT spec for the szipUSD junior vault (spec-ready, staging for claude-zipcode.md)

> **What this file is.** A **complete, spec-ready draft** of the szipUSD junior-vault subsystem, written in
> `claude-zipcode.md` section form so it can be approved item-by-item and then integrated section-by-section into the
> canonical spec — after which a builder window resumes `kickoff.md` to build one ticket at a time. Each component
> states **what it is, how it works, where it lives, how it interacts, and the `reference/` source to build from.**
> Authored 2026-06-07.
>
> **Status: DRAFT — pending item-by-item approval. Not yet integrated into `claude-zipcode.md`.**
>
> **The one-line mental model.** The junior is a **yield refinery** whose bet is *harvested yield > IL + xALPHA
> risk*. It stacks six value flows into junior NAV — **xALPHA LM emissions, oHYDX, veHYDX fees (paid as xALPHA +
> zipUSD), the xALPHA LST APR, haircut buy-and-burn accretion, and duration-risk xALPHA slash yield** — on a
> **zipUSD-lean 70/30 LP** that minimizes
> the IL it must cover (full stack: §10.6), all marked honestly by the NAV oracle and made non-dumpable by the
> windowed/soulbound custody layer. **Separately**, the protocol's *business* revenue — lending spread + arb (§10.7)
> — accrues to the **team treasury, not the junior**. None of it required a new primitive: the exotic behavior is
> emergent from "make the share NAV-proportional and transferable, keep the Loot in one gate, let the protocol
> deposit its own emissions."
>
> **Key locked decisions:**
> 1. **Two-token model** — internal Baal `Loot` (soulbound, Gate-only, ragequit-bearing) vs user **szipUSD**
>    (transferable ERC20).
> 2. **NAV-proportional issuance** against a **hybrid TWAP NAV oracle** (W≈4h); deposits never 1:1.
> 3. **Generalized fair-value issuance** — deposit any whitelisted basket asset valued at §3 → shares at current
>    price; USDC-zap and protocol **xALPHA in-kind** deposits are two wrappers on one core. **No haircut.**
> 4. **xALPHA = a Bittensor LST + emission program** — value comes from real subnet emissions via the LST exchange
>    rate; the protocol deposits its monthly emissions as **POL-as-liquidity-mining**.
> 5. **Secondary = CoW** over `szipUSD/USDC` (in-repo zodiac swap SDK). **8-B14 buy-and-burn** in scope from start.
> 6. **Loss is pari-passu** (junior-vs-senior the only tranche; no team subordination; "first-loss floor" = exit
>    constraint). **The Gate is the sole real-Loot holder.**
>
> **Source-of-truth hierarchy:** (1) `claude-zipcode.md` (integration target); (2) `reference/<repo>` source;
> (3) `reference/BAAL-ZODIAC-REFERENCE-MAP.md` (builder file:line index).

---

## 0. Where everything lives (paths)

| What | Path |
|---|---|
| Canonical spec (integration target) | `claude-zipcode.md` |
| This draft spec | `reports/design/baal-spec.md` (repo root) |
| Builder reference index (file:line map) | `reference/BAAL-ZODIAC-REFERENCE-MAP.md` |
| Baal contracts (canonical) | `reference/Baal/` |
| Zodiac base contracts (inherit) | `reference/zodiac-core/` |
| Zodiac address book + SDK | `reference/zodiac/` |
| Roles modifier v2 (warehouse) + **CoW swap SDK** | `reference/zodiac-modifier-roles/` (`packages/sdk/src/swaps/`) |
| **xALPHA LST + CCIP bridge spec** | `tickets/bridge/8x-01-szalpha-wrapper-cct.md` (+ `reference/evm-bittensor/`, `reference/subtensor/precompiles/`) |
| ERC-7540 senior queue fork | `reference/erc7540-reference/` (+ `reference/maple-withdrawal-manager/`) |
| Engine design narrative | `pending-docs/auto-sodomizer.md` (+ `hydrex.md`, `treasury.md`, `monitoring.md`) |
| Deposit module ticket (RE-AUTHOR — §15) | `tickets/woof/WOOF-06-deposit-module.md` |
| Deposit interface ticket (RE-AUTHOR — §15) | `tickets/inflow/INFLOW-06-deposit-module.md` |
| Deposit report (UPDATE — §15) | `reports/WOOF-06-report.md` |
| Progress / ledger | `tickets/PROGRESS.md`, `tickets/LEDGER.md` |
| Cross-session memory | `…/memory/baal-zodiac-foundation.md` |

---

## 1. Architecture at a glance (two-token model)

**szipUSD = the junior vault = a Baal (Moloch v3) DAO** whose Gnosis Safe basket trends toward **mostly the staked
zipUSD/xALPHA ICHI LP** (gauge-farmed on Hydrex), with USDC/HYDX/oHYDX as transient harvest-cycle working capital.
Two tokens:

- **Internal — Baal `Loot`** (18-dec, soulbound/paused at summon): the ragequit-bearing instrument. **Only the Exit
  Gate holds it and ragequits it, in liquidity windows.**
- **User — `szipUSD` (the "`$LOOT`" share)**: a **transferable 18-dec ERC20**, minted/burned **1:1** by the Gate
  against the Gate's Loot. Fixed-supply, non-rebasing — NAV accrues in *price*. Confers **no direct ragequit**, only
  a windowed claim.

```
 depositor USDC ──WOOF-06 zap──► zipUSD (1:1) ─┐
 protocol xALPHA emissions (monthly, in-kind) ─┴─► Gate.depositFor(asset, value, receiver)
                                                     [valued at §3 mark; mint Loot to Gate; mint szipUSD to receiver]
        ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
        ▼
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  szipUSD Baal DAO                                                                                          │
 │   ┌────────────────────────┐         ┌──────────────────────────┐                                         │
 │   │ MAIN Safe (RQ target) =│  CRE    │ SIDECAR Safe (NOT RQ      │  basket → mostly staked ICHI LP        │
 │   │ FREE equity            │◄───────►│ target) = COMMITTED equity│  (zipUSD~70% / xALPHA~30%) + working    │
 │   │ (redeemable in windows)│ rotate  │ (= utilization); FREEZE;  │  USDC/HYDX/oHYDX                        │
 │   └──────────┬─────────────┘ on line │ runs auto-sodomizer       │                                         │
 │              │ real Loot      open/  └──────────────────────────┘                                         │
 │              ▼                close                                                                         │
 │   ┌──────────────────────────────────────┐   mints 1:1   ┌───────────────────────────────┐                │
 │   │ EXIT GATE  (sole Loot holder; mint    │ ────────────► │ szipUSD (transferable ERC20)  │ ── trades on ─►│
 │   │ authority manager=2; sole RQ caller;  │ ◄─── burn ─── └───────────────────────────────┘     CoW        │
 │   │ intent queue; windows; paired burnLoot)│                                                                │
 │   └──────────────────────────────────────┘                                                                │
 │   §3 NAV oracle (hybrid push/read/compose + on-chain TWAP) — prices issuance & exit.                        │
 │   §7 8-B14 buy-and-burn: engine USDC ──CoW BUY szipUSD @ TWAP-NAV−d──► burn szipUSD + paired burnLoot.      │
 │   §10 engine 8-B5…8-B14 (auto-sodomizer): one immutable CRE operator; emission program + HYDX extraction.   │
 └─────────────────────────────────────────────────────────────────────────────────────────────────────────┘

 SENIOR side (separate, never conflate): CreditWarehouse Safe (EulerEarn shares; senior backing for zipUSD)
 governed by a Zodiac Roles-modifier-v2 (8-Bw); senior zipUSD→USDC exit = ZipRedemptionQueue (ERC-7540, §12).
```

**Load-bearing ideas:** (1) two tokens — soulbound Gate-only Loot vs transferable szipUSD; (2) NAV-proportional,
generalized, fair-value issuance (§3/§4); (3) two exits — patient window-RQ at NAV (§5) / impatient CoW sale (§6);
(4) structural sidecar freeze (§8) + pari-passu provision-that-recovers loss (§9); (5) haircut buy-and-burn (§7);
(6) the engine is an **emission-fed POL-as-liquidity-mining refinery** (§10).

---

## 2. [→ §2] Token model

### 2.1 zipUSD — the senior $1 utility dollar
`ESynth`-based (`reference/evk-periphery` `ESynth`), minted 1:1 by value on USDC deposit (WOOF-06), backed by the
CreditWarehouse (§11); senior redemption = the ERC-7540 queue (§12). Inside the junior it is a **basket asset** held
at $1 (§3) and **rehypothecated into LP depth** by the engine (§10).

### 2.2 Internal Baal Loot — the ragequit-bearing instrument
- `LootERC20` (`reference/Baal/contracts/LootERC20.sol`) — `ERC20Upgradeable`, **no `decimals()` override → 18 dec**.
  Owned by Baal; **paused at summon** (`BaalSummoner.sol:303`); mint/burn bypass the pause (`from==0`/`to==0`).
- **Held by the Exit Gate ONLY** — exactly one real-Loot holder (the genesis seed mints to the Gate too; the team
  receives **szipUSD**, §4.3). Soulbound because `ragequit` (`Baal.sol:619`, `_ragequit:637`) is permissionless on
  the holder and **cannot be gated/paused**; keeping all Loot in the Gate makes windowed exit enforceable.
- `totalSupply()` = loot + shares (`Baal.sol:999`); mint **only Loot** (never Shares) → clean ragequit pro-rata.

### 2.3 szipUSD (`$LOOT`) — the transferable user share (NET-NEW)
- A standard **transferable 18-dec ERC20** the Gate mints/burns; **fixed-supply, non-rebasing** (NAV accrues in
  price). The only token a user holds.
- **Invariant:** `szipUSD.totalSupply() == lootToken.balanceOf(gate)` (the engine-Safe's transient pre-burn holding,
  §7, is excluded from the issuance/exit denominator — treated as already-retired).
- **Rights:** a windowed redemption claim via the Gate (§5) + free transfer/trade (§6). **No direct ragequit.**

### 2.4 Tranching — junior vs senior is the only tranche
- szipUSD (junior) is **first-loss vs zipUSD (senior)**. **Inside the junior, everyone is pari passu** — the team's
  POL is ordinary junior equity. **No subordinated team buffer.**
- The **"first-loss coverage floor" is an exit constraint** (§5.4): the Gate won't process exits that drain junior
  NAV below the level needed to keep the senior whole. It governs *how much can leave*, not *who absorbs loss*.
- **Consequence (by design):** the protocol deposits its emissions monthly (§4.3/§10), so it **steadily becomes the
  dominant junior holder** — best first-loss alignment, POL-sticky, exit-constrained like everyone.

---

## 3. [→ §7] NAV oracle — hybrid composition + on-chain TWAP

**Decision (locked): hybrid push-price / read-quantity / compose-and-accumulate on-chain.** CRE pushes only the
prices that cannot be sourced on Base; the contract reads all quantities and on-chain prices trustlessly, composes
NAV on-chain, and maintains the TWAP on-chain. Rationale: per-leg auditability, on-chain deviation circuit-breaking
of pushed legs, and a TWAP the operator cannot retroactively shape.

### 3.1 Component
**`SzipNavOracle is ReceiverTemplate`** (reuse the proven CRE push-cache pattern from WOOF-02
`ZipcodeOracleRegistry`). It (a) caches pushed prices, (b) reads on-chain quantities across **both** Safes incl.
staked positions, (c) composes spot NAV, (d) maintains a cumulative TWAP accumulator on `navPerShare`.

### 3.2 Per-leg sources
| Leg | Valuation | On/off-chain |
|---|---|---|
| zipUSD | **$1** (loss captured once, via §9 provisions — not via this mark) | constant |
| USDC | $1 (or Chainlink USDC/USD) | on-chain |
| **xALPHA** | **two layers:** `exchangeRate (staked alpha ÷ xAlpha supply, from validator stake) × alphaUSD (subnet TAO/alpha AMM TWAP × TAO/USD)` | exchange-rate = robust bridged stake-accounting; **alphaUSD = the only market leg → TWAP + staleness + circuit-break** |
| HYDX | Hydrex pool **TWAP** (HYDX/USDC), else pushed if thin | on-chain (fallback pushed) |
| oHYDX | **intrinsic = HYDX × (1 − exerciseDiscount)**, `exerciseDiscount` read on-chain from the option contract at mark time; marked post-exercise | derived |
| **ICHI LP (incl. staked in gauge)** | **reserves × {zipUSD $1, xALPHA as above} at pool TWAP** — **IL is marked-through** (true reserve value, not hidden) | hybrid |

- **xALPHA value source (the integrity story).** Per `tickets/bridge/8x-01-szalpha-wrapper-cct.md`, xALPHA is a wstETH/cToken-
  style LST: its exchange rate is `staked alpha ÷ supply` read from the **validator stake** (Subtensor precompiles
  StakingV2 `0x805` / Metagraph `0x802`), **no DEX, no pool price** in the mint/redeem path — so the **$100k/mo
  subnet emissions accrue here as a rising exchange rate** (real, non-manipulable). Only the `alphaUSD` conversion
  rides the subnet AMM (thin-pool/depth risk) → that leg is TWAP'd + guarded. Value floor = redeemability
  (`redeem → unstake → bridge → AMM` is always callable, per the 8x-01 ticket). Ground §3's xALPHA leg against
  `tickets/bridge/8x-01-szalpha-wrapper-cct.md` at build.
- **Quantities** (balances of every leg across MAIN + SIDECAR + the **staked** ICHI LP read off the gauge) are read
  on-chain — never trust a pushed balance.
- **veHYDX is NOT a markable leg.** The permalocked veNFT (8-B7) is non-redeemable, so it carries **~0 principal** in
  NAV; only the realized **oHYDX + veHYDX fees** it produces are marked, once claimed into the basket. Marking
  permalocked veHYDX as liquidatable principal would overstate NAV.

### 3.3 Composition, TWAP, safety rails
- `spotNAV = Σ (quantityₗ × priceₗ)` across both Safes; `navPerShareSpot = spotNAV / (szipUSD.totalSupply() −
  engineSafePendingBurn)`.
- **On-chain accumulator:** each push, `cumNavPerShare += navPerShareSpot × dt`; consumers read `twapNavPerShare`
  over governed window **W ≈ 4h** (§14). (Fixed, decoupled from harvest cadence: residents are bracket-protected at
  any W, loss recognition bypasses W, the LP and pushed legs are already per-leg-guarded — so W optimizes for
  transactor freshness, and a slow on-chain-trending basket wants a few hours, not a day.)
- **Bracket:** entry `navEntry = max(spot, twap)`; exit `navExit = min(spot, twap)` (protects resident holders both
  directions).
- **Staleness guard:** each pushed leg carries `maxAge`; if stale → **issuance reverts/pauses**, exits price off the
  last good mark.
- **Deviation circuit-break:** a pushed leg moving > `maxDeviation` vs prior is rejected/flagged.
- **Markdown injection:** the **DefaultCoordinator (§9) is the sole writer** of an impairment provision; it takes
  effect **immediately, downward** (never TWAP-smoothed up); recovery writes it back up.

### 3.4 Invariants
- The protocol **never reads the szipUSD *market* (CoW) price** for accounting — issuance/exit/buyback price off
  `SzipNavOracle` only.
- **No self-issuance haircut.** Because the xALPHA value is real (subnet emissions via the LST exchange rate) and the
  mark is externally anchored + guarded, in-kind deposits (§4.3) issue at the **full fair-value mark**; a haircut
  would mis-credit the protocol's real contribution to existing holders.

---

## 4. [→ §4.5 / 8-B2] Issuance — generalized NAV-proportional minting (in the Gate)

> **Consolidation (LOCKED):** the old "8-B2 mint shaman" is absorbed into the Exit Gate — the Gate holds `manager`
> (2), is the szipUSD minter/burner, and is the sole ragequit caller. A single atomic mint-Loot-and-mint-szipUSD
> can't desync the `szipUSD.totalSupply == gate Loot` invariant, and `manager` (needed for the §7 burn anyway) lives
> in exactly one place.

### 4.1 The one issuance core
Issuance = **deposit a whitelisted basket asset, valued at §3, → shares at the current bracketed share price.** Two
wrappers feed it: the **USDC zap** (WOOF-06: USDC→zipUSD→deposit) and the protocol's **in-kind xALPHA** deposit
(§4.3). Canonical entrypoint: **`Gate.depositFor(asset, amount, receiver) → shares`** — the caller passes the raw
`asset`+`amount`; **the Gate owns valuation** (via §3), so no caller can assert a value. One formula:
```
require(navOracle.fresh())                                  // §3.3 staleness
value   = §3-mark(asset, amount)                            // zipUSD $1 ⇒ value == zipAmount
navEntry = max(navOracle.spot(), navOracle.twap())          // §3.3 bracket
shares   = (value * 1e18) / navEntry                        // round DOWN
baal.mintLoot([gate], [shares])                             // manager(2); Loot to the Gate
szipUSD.mint(receiver, shares)                              // transferable share to the user
// invariant: szipUSD.totalSupply == lootToken.balanceOf(gate)
```
Example: NAV $1.20, deposit $12 → 10 shares. NAV $0.80 → 15 shares (comparative-entry door, automatic).

### 4.2 Rounding & genesis
- Shares round **down** (favor the vault).
- **`navPerShare₀ = $1.00`.** The protocol seeds the basket (the genesis zipUSD/xALPHA ICHI POL); the Gate mints
  `seedUSD × 1e18 / $1.00` Loot to itself and **szipUSD to the team Safe**. szipUSD opens at $1.00; the bracketed
  TWAP NAV is the drift above it. The seed is **pari-passu junior equity** (§2.4) — large + POL-sticky, so it
  supplies early first-loss capacity and keeps `totalSupply` far from zero (closes the first-depositor inflation
  attack; round-down is belt-and-suspenders).

### 4.3 The xALPHA in-kind deposit (POL-as-liquidity-mining — manual, fair-value)
- Each month the protocol **manually deposits its subnet xALPHA emissions** through the same `depositFor` path,
  valued at the §3 mark, receiving shares at the current price into the team Safe. **Manual = the team-multisig
  decision is the gate; no autonomous CRE, no separate governance machine, no haircut.** Front-loading is just a
  larger manual deposit.
- **Share-credit = value of what is *deposited* (the xALPHA) only.** Activating resting vault zipUSD into LP is a
  **separate, value-neutral engine rebalance** (§10) that mints **no** shares — it just makes the resting zipUSD
  productive. So: $100k xALPHA deposit → 100k shares at $1; engine then pairs that xALPHA with ~$233k resting zipUSD
  into the 70/30 LP (forward HYDX for *all* holders). Non-dilutive at issuance, accretive forward.
- This is **POL as liquidity mining**: the emission is captured as protocol equity + owned LP instead of paid to
  mercenaries; the windowed/soulbound structure (§2/§5) makes it **non-dumpable**; the auto-sodomizer (§10) turns it
  into HYDX extraction.

### 4.4 Interactions
Reads §3; writes §2.2/§2.3; fed by WOOF-06 (USDC) + the protocol (xALPHA); denominator feeds §5/§7; the LP rebalance
is §10.

---

## 5. [→ §6.4] The Exit Gate — custody + windowed redemption (the patient path)

### 5.1 What it is
The **sole Loot custodian**, **szipUSD minter/burner**, **mint authority (manager=2)**, **sole ragequit caller**,
**intent-queue + window processor**, and **paired-burn coordinator** for §7. A Zodiac module on the Safe(s) and/or
holding manager. (NET-NEW; absorbs the old "8-B3 lock/freeze shaman" + the 8-B2 mint shaman.)

### 5.2 Patient redemption
1. `requestExit(szipUSDAmount)` → share escrowed + queued; **no assets move**.
2. **Liquidity window** (rides the harvest cadence — the engine unstakes the ICHI LP each cycle, §10, so the basket
   is liquid in MAIN): the Gate calls `Baal.ragequit(to=gate, shares=0, loot=lootForQueue, sortedTokens[])`
   (`Baal.sol:619`; **`tokens[]` ascending**, `:625`) → receives basket pro-rata → pays each queued exiter at
   **`navExit = min(spot, twap)`** → burns the matching szipUSD (invariant preserved).
3. UX: **one position** ("szipUSD: $X, ~Y% APR"); status **Requested → Window opens ~<date> → Claimable → Claimed**
   with next-window estimate + estimated payout. Never expose raw Loot / Gate internals.

### 5.3 Frozen slice not redeemable here (partial-fill-per-window)
Window exits reach only **free** MAIN equity; the **committed** slice lives in the non-ragequittable sidecar (§8),
not redeemable until those lines close — that is the freeze. So the Gate **partial-fills queued exits against free
equity each window (above the §5.4 coverage floor); the unfilled remainder stays queued and keeps accruing**, and is
filled in later windows as lines close and equity rotates SIDECAR→MAIN (§8.5). **No forfeit — the queue is the
retention.** The impatient alternative (out *now*, incl. the frozen slice) is selling szipUSD on CoW (§6).

### 5.4 Coverage floor = the freeze (structural, NOT a governed knob)
The floor is **not a separate percentage** — it *is* the freeze. "Back all utilized credit lines" = the committed
slice the sidecar already locks (§8, `lockedFraction = atRiskAmount/basketNAV`). The Gate fulfills exits only from
**free** equity; the committed slice stays frozen until lines close, then rotates SIDECAR→MAIN and frees (§8.5). So
junior NAV can never drain below the utilized first-loss backing — enforced structurally by the freeze, with **no
coverageFloor value to set.**

### 5.5 Interactions
Holds §2.2; controls §2.3; prices via §3; window cadence from §10; floor §14; paired-burn for §7; freeze boundary §8.

---

## 6. [→ §6.4 / new] Secondary market — CoW over szipUSD/USDC (the impatient path)

### 6.1 What it is
Because szipUSD is a normal ERC20, the impatient exit is **selling szipUSD/USDC on CoW** — instant, peer-funded,
**no basket touched, no window**. The *market* prices the duration/impairment risk (marked-NAV vs clearing-price
divergence lives here); §5 stays the patient, NAV-priced path. Two honest exit prices, neither forced.

### 6.2 Why CoW (not an AMM, not a bespoke book)
An AMM would need passive szipUSD LPs and get arbed against a stale provision (worst asset for a bonding curve). A
bespoke CLOB would force tokenizing/operator-running a book. **CoW** is an off-chain order book with on-chain batch
settlement of standard ERC20s — **already in-repo** as a zodiac pattern:
`reference/zodiac-modifier-roles/packages/sdk/src/swaps/` (`getCowQuote`, `signCowOrder`, `allowCowOrderSigning`,
`encodeSignOrder`, `postCowOrder`, `cowOrderbookApi`). `SigningScheme.PRESIGN` lets a **Safe** place CoW orders
on-chain.

### 6.3 Participants & invariant
Any user trades szipUSD/USDC on CoW directly; the protocol posts the discounted resting bid via **8-B14** (§7).
**Never** feeds §3 accounting (§3.4).

---

## 7. [→ §4.5.1 / 8-B14] Haircut buy-and-burn module — IN SCOPE FROM THE START

### 7.1 What it is
A CRE-driven Zodiac module on the engine Safe making the protocol the **discounted buyer of last resort** for
szipUSD, funded by engine USDC, **burning everything it buys** — manufacturing a duration premium for patient
holders out of impatient sellers' haircuts, with no separate yield source.

### 7.2 Mechanics (one-sided — bid only)
- **Bid:** resting **`BUY szipUSD`** CoW order at **`navExit × (1 − d)`** — where **`navExit = min(spot, twap)`**
  (§3, the buyer-conservative bracket: the protocol pays USDC, so it marks at the *lower* of spot/twap so a
  downward-trending NAV, e.g. just after a `writeProvision` step-down, can't make it overpay; NAV $1.15, d=10% →
  ≤ $1.035), `sellToken=USDC`, `partiallyFillable=true`, far `validTo` (bounded TTL), via **PRESIGN** (§6.2) from a
  **plain engine Zodiac Module (§10.1, `is Module`, one immutable CRE operator)** mutating the engine Safe by
  `exec(...,Operation.Call)` — **NOT** a Roles-scoped Safe (§10.1 governs the whole 8-B5…B14 family; the module
  exists precisely to enforce these bounds **on-chain**). **No sell side** — primary mint at NAV (§4) dominates any
  sell offer.
- **On fill → paired burn (a separate seam):** the bought szipUSD lands in the engine Safe; on the next CRE tick the
  **windowController** (the CRE keeper, the same authority that opens redemption windows) calls **`ExitGate.burnFor`**,
  which (the Gate holding `manager=2`) does **`burnLoot([gate],[amt])`** (`Baal.sol:834` → `_burnLoot:847` = pure
  supply reduction, **NO asset payout, no window, no liquidity constraint**) **and** burns the matching engine-Safe
  szipUSD. The burn is **not** the buy module's authority (the module only signs the bid); supply drops and the
  seller's haircut accretes to remaining holders. (Ragequit is the wrong tool — it *extracts* assets; the protocol
  wants to *retire* the share and leave assets in the basket. That is `burnLoot`.) The keeper computes the burn
  `amount` from the on-chain `szipUSD.balanceOf(engineSafe)` (not from fill events), and orders **fill → burnFor →
  re-post** so no unburned szipUSD accumulates in the Safe across cycles (it is excluded from the NAV denominator, so
  a residual would silently overstate NAV until burned).
- **No treasury inventory, no window-RQ, no mark-to-NAV.**

### 7.3 Trace
Seller sells a $1.15 share for $1.035 (eats $0.115). Paired burn drops supply by 1 → assets `1.15S − 1.035` over
`S − 1` → navPerShare ticks up; total lift `$0.115` across remaining holders.

### 7.4 Bounds (governed, §14)
Discount `d` (`0 < d < 1`, enforced at the setter AND re-asserted at post); max engine-USDC to bids/cycle
(`buybackCap`; `buybackCap == 0` is the clean kill-switch — all bids revert); **single resting bid at a time**
(outstanding signed USDC ≤ `buybackCap`); **never bid ≥ NAV** (priced at `navExit × (1 − d) = min(spot, twap) × (1 −
d)`, the §3 buyer-conservative mark, gated on `oracle.fresh()`); never read szipUSD market price (§3.4); priced off
§3 only. Re-posting after a partial fill = **cancel (presignature→false, approval→0) then a NEW `validTo`/uid** — a
stale presignature plus a refreshed approval would let the unfilled remainder fill twice (over `buybackCap`).

---

## Substrate scaffold — 8-B1 [→ claude-zipcode.md §4.5]

**What it is.** The Baal (Moloch v3) DAO + its **main Gnosis Safe** (the avatar / ragequit target; holds FREE
equity) + a **non-ragequittable sidecar Safe** (holds COMMITTED equity, §8) + the Loot and Shares ERC20 clones — all
produced by **one call** to the **already-deployed** `BaalAndVaultSummoner`. Baal is solc **0.8.7 and live on Base**,
so 8-B1 is a **summon SCRIPT** that calls the deployed summoner through interfaces — NOT a contract we compile from
Baal source (same "interact, don't compile" rule as the Euler deps).

**Where it lives.** `contracts/script/SummonSubstrate.s.sol` calling the deployed `BaalAndVaultSummoner` on Base
8453; interface stubs `contracts/src/interfaces/baal/IBaalSummoner.sol` + `IBaal.sol` (verify vs `reference/Baal`).

**How it works — the summon recipe.**
`summonBaalAndVault(initializationParams, initializationActions, saltNonce, referrer, name) → (daoAddress,
vaultAddress)` (`BaalAndVaultSummoner.sol`): (1) `summonBaalFromReferrer(...)` deploys Baal + main Safe + Loot/Shares
clones and runs the init-actions; (2) `summonVault(dao,name) → deployAndSetupSafe(dao)` deploys the **sidecar Safe**
(DAO-controlled, registered in the summoner's `vaults` map, **not** the ragequit target). The script reads the
addresses from the **return tuple** `(daoAddress=baal, vaultAddress=sidecar)` plus **getters** on the Baal —
`mainSafe = IBaal(baal).avatar()` (== `.target()`), `loot = IBaal(baal).lootToken()`, `shares =
IBaal(baal).sharesToken()` — NOT the `SummonBaal` event (a Solidity script can't parse the event of an external
call; the return tuple + getters are exact and verifiable).

`initializationActions` order (`getBaalParams`): `setAdminConfig` → `setGovernanceConfig` → `setShamans` →
`mintShares` → `mintLoot` → (NEW) **`executeAsBaal`** (the admin-injection). For szipUSD, settled here:
- `setAdminConfig(pauseShares=true, pauseLoot=true)` → confirms **Loot soulbound from genesis** (the actual pause is
  already set by `BaalSummoner.deployTokens` at `BaalSummoner.sol:303-304`; this action is the explicit, resilient
  intent and a no-op if already paused).
- `setGovernanceConfig(...)` → **permanently-inert defaults**. Authority comes from **Safe ownership** (below), not
  votes, and **Shares stay 0 forever**, so no Baal proposal can ever be sponsored/passed. Set sane voting/grace and
  a `sponsorThreshold` that no one can ever meet (zero Shares ⇒ inert regardless). Ops runs through the **team-admin
  signer + the CRE operator module**, never Baal proposals.
- `setShamans([], [])` at summon → **no shaman yet** (no Gate address yet). The Exit Gate (item 3) gets
  **manager(2)** post-deploy — **not** via a Baal proposal (governance is inert) but via the **team-admin Safe
  signer** calling `setShamans([gate],[2])` through the main Safe (`Safe.execTransaction` → `Baal.setShamans`,
  `baalOnly` satisfied because the caller is the avatar). **This is the one seam 8-B1 leaves open** — and it is now
  **reachable** because of the admin-injection below.
- `mintShares([], [])` = **zero Shares forever** (keeps ragequit pro-rata pure-Loot AND keeps governance inert);
  `mintLoot([], [])` = **zero Loot at summon** (the genesis seed mint, §4.3, happens later via the Gate once it holds
  manager).
- **`executeAsBaal(mainSafe, 0, <add-owner>)` (NEW — the authority injection).** Adds the **team multisig as a Safe
  owner/signer** so the substrate is **driveable** (see "Authority model"). Because `executeAsBaal` (`Baal.sol:601`)
  does a raw `.call` **as the Baal**, the payload must route through the Safe's self-authorized owner-management:
  `<add-owner> = execTransactionFromModule(mainSafe, 0, addOwnerWithThreshold(TEAM_MULTISIG, 1), Call)` (Baal is an
  enabled module on the main Safe ⇒ the Safe calls **itself** ⇒ `authorized` passes). A direct
  `executeAsBaal(mainSafe, 0, addOwnerWithThreshold(...))` would **revert** (caller = Baal ≠ Safe). This needs the
  **main-Safe address at encode time** → see "Authority model" for the compute-then-assert.
- Role locks (`lockManager`/`lockGovernor`/`lockAdmin`) **deferred** until the Gate is wired as manager + the engine
  module set is settled (the team-admin signer applies them later).

**Authority model (RATIFIED 2026-06-07 — two-tier: admin vs operator).** The summoner forces each Safe to be owned
**1/1 by the Baal** (`configureSafe`: `setup(owners=[baal],1)` + `enableModule(baal)`). With **zero Shares the Baal
is governance-inert** (no proposal can pass) and the Safe is otherwise undriveable — so the substrate would ship
**frozen**. Resolution:
- **Admin = the team multisig, added as a Safe OWNER/signer** on both Safes (cold, trusted). It governs the **module
  set** (enable/disable/swap Zodiac modules = "change what the CRE can do"), grants the Exit Gate `manager(2)` via
  `setShamans`, and does all wiring — via the native `Safe.execTransaction` (owner) path.
- **CRE operator = a Zodiac MODULE** the admin enables; it drives the series of strategy modules (8-B5…14) via their
  `onlyOperator` entrypoints (hot key, narrow blast radius). **Enabling a module = full Safe power**, so only the
  admin (never the hot CRE key) may change the set.
- **Injection window:** post-summon the Safe is inert, so the **only** authority-injection point is the summon
  init-actions (which run as the avatar/Safe). 8-B1 injects the team owner there (the `executeAsBaal` action above).
  The **main-Safe address** needed for that action is **computed before summon** from the live
  `GnosisSafeProxyFactory.proxyCreationCode()` + configured `gnosisSingleton` + the chosen `saltNonce` (Safe 1.3.0
  `createProxyWithNonce`, empty initializer per `BaalSummoner.sol:233`), and the script **asserts `computed ==
  IBaal(baal).avatar()` after summon** (revert on mismatch). Computed-then-verified against live code — **not** a
  blind hardcode (the WOOF-00 address lesson).
- **Sidecar:** created by `summonVault` **after** summon, so its owner-add can't ride the Baal `setUp` init-actions.
  The team-admin (now an owner of the main Safe) adds itself to the **sidecar** post-summon by driving the main Safe
  → `Baal.executeAsBaal(sidecar, 0, execTransactionFromModule(sidecar, 0, addOwnerWithThreshold(TEAM,1), Call))`
  (Baal is the sidecar's enabled module). 8-B1's script does this as a second, team-signed step (fork-proven).

**The two Safes.** Main = Baal avatar/target; `ragequit` pays `balanceOf(mainSafe)` pro-rata → FREE equity. Sidecar
= `deployAndSetupSafe(dao)`, DAO-controlled but **not** the ragequit target → balances never enter ragequit math →
COMMITTED equity (§8 / item 9). Both are reachable by the CRE/Zodiac modules (`execTransactionFromModule`) once the
team-admin enables those modules; item-9 rotation and item-10 strategies move funds across them.

**What it touches.** Item 2 (NAV oracle) sums balances across **both** Safe addresses; item 3 (Gate) consumes
`baal`+`loot`, gets manager(2) post-deploy **via the team-admin signer** (not a proposal), ragequits main; item 9
rotates equity main↔sidecar; item 10 / the team-admin `enableModule`s the CRE operator + strategy modules on the
Safe(s); the genesis seed (item 3, §4.3) is the first Loot/szipUSD mint after the Gate holds manager.

**Source + Base 8453 addresses (from `reference/Baal/deployments/base/`; verify on-chain at build).**
`BaalAndVaultSummoner.sol` (`summonBaalAndVault`, `summonVault`, `vaults`/`vaultIdx`), `BaalSummoner.sol`
(`summonBaalFromReferrer`, `deployAndSetupSafe`, `encodeMultisend`, `configureSafe`, public `gnosisSingleton`),
`Baal.sol` (`executeAsBaal:601`, `setShamans:686`, `setAdminConfig:749`, `setGovernanceConfig:853`, `mintLoot:814`,
`avatar`/`target`/`lootToken`/`sharesToken`/`totalLoot`/`totalShares` getters), `test/utils/baal.ts`
(`getBaalParams` — the init-action + governanceConfig ABI encoding).
- BaalAndVaultSummoner = `0x2eF2fC8a18A914818169eFa183db480d31a90c5D`
- BaalSummoner = `0x22e0382194AC1e9929E023bBC2fD2BA6b778E098`
- Baal singleton = `0xE0F33E95aF46EAd1Fe181d2A74919bff903cD5d4`
- Loot singleton = `0x52acf023d38A31f7e7bC92cCe5E68d36cC9752d6`
- Shares singleton = `0xc650B598b095613cCddF0f49570FfA475175A5D5`
- Safe proxy factory (1.3.0, for the main-Safe address compute) = `0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2`
  (`BaseAddresses.SAFE_PROXY_FACTORY_1_3_0`; **verify it is the factory `BaalSummoner` is configured with** at build)

**Params (all settled here — no open economic knobs).** `pauseLoot/pauseShares = true`; governance config =
**permanently-inert** defaults (un-meetable `sponsorThreshold`; zero Shares makes it moot regardless); **Shares = 0
forever**, Loot-at-summon = 0; `saltNonce`/`referrer`/`name` = deploy metadata; **admin = the team multisig added as
a Safe owner/signer at summon** (the `executeAsBaal` action); manager(2)→Gate granted post-deploy by that admin
signer (not a proposal); role-locks deferred. `TEAM_MULTISIG` is a deploy parameter (env/constructor arg; a test
address on the fork, the real Gnosis multisig in production). The earlier open question — *is `BaalAndVaultSummoner`
on Base?* — is **RESOLVED: yes** (`0x2eF2…`), so we call it.

---

## 8. [→ §11] The freeze — structural sidecar + CRE main↔sidecar rotation (item 9)

### 8.1 What it is
The freeze is the **portfolio-level split** that makes the utilization-committed junior equity non-redeemable while
credit lines are live, by holding it in the **non-ragequittable sidecar** (item 8) instead of the main Safe. It is
**structural, pro-rata, NOT per-depositor**: every szipUSD is a pro-rata claim on the *whole* basket (main+sidecar),
but window-RQ only reaches the main Safe (the sidecar isn't the ragequit target), so a uniform `lockedFraction` of
everyone's claim is effectively frozen — enforced automatically by ragequit math, no per-member bookkeeping.

### 8.2 Sizing
`lockedFraction = atRiskAmount / basketNAV`, where `atRiskAmount` = junior equity committed as first-loss backing
for live credit lines (= warehouse **utilization**, §11/§12). The CRE keeps **sidecar value ≈ atRiskAmount** (+ the
boost it accrues); **free main equity = basketNAV − sidecar value** is what window exits can reach.

### 8.3 Rotation (the mechanic)
A **CRE-operated Zodiac module** (the rotation lives in the engine / CRE-op surface — item 10 / 8-B11), enabled on
**both** Safes, moves basket value between them via inherited `exec(…Call)` → Safe `execTransactionFromModule`:
- **Line opens (draw)** → `atRiskAmount`↑ → rotate value **MAIN→SIDECAR** (commit/freeze).
- **Line closes/repays** → `atRiskAmount`↓ → rotate value **SIDECAR→MAIN** (release → redeemable).
- CRE rebalances as NAV drifts to keep sidecar ≈ committed equity.
- **Wiring:** each Safe is owned 1/1 by the Baal with the Baal enabled as a module (`BaalSummoner.configureSafe`:
  `setup(owners=[baal],1)` + `enableModule(baal)`). The CRE rotation/engine modules must therefore be
  `enableModule`'d on **both** Safes via a **post-deploy Baal-authorized bootstrap** (same class of wiring step as
  the Gate's manager grant). Once enabled, the module moves funds with no further authorization.

### 8.4 Frozen-but-earning (the boost)
The sidecar **runs the auto-sodomizer** (item 10), so committed equity keeps earning while reserved; that yield is
the **duration-risk boost** (§9.2 / §10.6 #6) accruing to whoever holds through the freeze. On rotation back to main
at line close, committed principal + accrued boost returns to free/redeemable.

### 8.5 How exits see the freeze (interaction with the Gate, item 3)
A window-RQ pays `balanceOf(mainSafe)` pro-rata (sidecar excluded), so the Gate fulfills queued exits **only up to
the free main equity above the coverage floor (§5.4) each window**; the **unfulfilled remainder stays queued and
still-earning**, fulfilled in later windows as lines close and equity rotates back. **No forfeit — the queue IS the
retention**; a holder who wants out *now* (incl. the frozen slice) sells szipUSD on CoW (§6).
> **Refinement to item 3 (§5):** the Gate's window logic is **partial-fill-per-window against free equity, remainder
> re-queued and still-accruing** (folded into §5.3).

### 8.6 Triggers (freeze ≠ markdown, per §9.5)
- **Trigger A (default):** the committed slice **stays frozen** + the slashed xALPHA bond lands in the sidecar, until
  §9 resolution. (Markdown is §9; the freeze is here.)
- **Trigger B (utilization-squeeze):** when utilization crosses `U_lock`, freeze escalates (rotate more
  MAIN→SIDECAR) to protect liquidity — **a time-hold, no markdown**.

### 8.7 Interactions
Item 8 (the two Safes); item 3 (exits consume free/committed state — partial-fill refinement, §8.5); item 10
(auto-sodomizer = the boost, and hosts the rotation module); §9 (default keeps the slice frozen); §11/§12
(`atRiskAmount`/utilization source); item 2 (NAV sums both Safes).

### 8.8 Source + params (settled here)
`BaalSummoner.configureSafe`/`deployAndSetupSafe` (sidecar = Baal-owned 1/1 + Baal-as-module); Zodiac `Module.exec` →
Safe `execTransactionFromModule` for cross-Safe transfers; CRE-operator pattern (`auto-sodomizer.md §8`); utilization
from §11/§12. **Params (governed defaults — set by governance with real utilization data; do NOT change the build):**
`U_lock` (trigger-B escalation point), `U_max` (hard ceiling on committed/lent fraction), `maxLockFraction` (cap so
≥ `(1−maxLockFraction)` always stays redeemable); `lockedFraction` is a formula, not a knob; `coverageFloor` is
item 3's (§5.4), referenced not redefined; CRE operator = the single immutable operator.

---

## 9. [→ §4.6 / §11] Loss model — conservative provision marked on a staircase of verified facts

### 9.1 Principle
Junior-vs-senior is the only tranche; inside the junior everyone is pari passu (§2.4). A bad loan is marked **down
over time on verified facts** — **never one big step at resolution, never a discretionary guess** — because loan
cycles rarely resolve cleanly. The mark starts **conservative** (you know least at default) and mostly steps **up**
as real cash lands. The junior backing the at-risk line is **frozen (non-RQ, §8) until resolution**, so the mark can
move while the slice can't be exited at a wrong price.

**The asset/risk model (sets the `recoveryFloor` direction).** The underlying is **insured,
home-equity-collateralized, secondary-market-connected HELOC credit**, so the **primary risk is DURATION, not
loss.** A default is therefore predominantly a **freeze / duration-extension** (§8), **not** a write-down;
`recoveryFloor` is **HIGH** (low loss-given-default) → the **day-one provision is small.** A 2008-style
secondary-market freeze just **extends the freeze duration** (the slice waits longer, accruing) — it does **not**
convert to permanent loss. A hard markdown happens **only on a verified residual loss** (insurance denied **and**
foreclosure recovers < principal) — the rare tail, via the staircase. The specific `recoveryFloor` % is
**underwriting-derived per originator/insurance terms** (LTV, coverage), not a protocol-wide knob.

### 9.2 The markdown model — a staircase of facts
1. **Default declared (trigger A):** the committed slice **freezes** (sidecar, §8) — *this* is the dominant effect
   (duration). The `DefaultCoordinator` (sole NAV-markdown writer, §3.3) writes a **conservative provision**
   `= atRiskPrincipal × (1 − recoveryFloor)`, with **`recoveryFloor` HIGH** (insured/collateralized → low LGD, §9.1)
   so the **day-one markdown is small**; `recoveryFloor` is **underwriting-derived per originator/insurance**
   (deterministic — nobody estimates a per-event recovery). NAV marks down pro-rata, immediately (usually slightly).
2. **Re-marks on events:** each subsequent **verified foreclosure milestone / cash receipt** re-marks — *down* on an
   adverse verified milestone, *up* by the realized amount as recovery lands. Every move is tied to a provable event,
   not an opinion. A messy multi-month resolution = **many small fact-steps**, converging to truth.
3. **True-up at resolution:** the final realized loss is locked; any over-provision releases. (Resolution is the
   true-up; the conservative marks in steps 1–2 come first.)
- **Cohort separation (why mark early):** a loss recognized *before* you deposit is already in the NAV you pay → you
  buy at the post-loss price and **don't inherit** old losses (only go-forward recovery risk on what you bought).
  Waiting until resolution would dump pre-existing losses onto fresh deposits.
- **Duration premium falls out of pari-passu:** szipUSD claims the *whole* basket (MAIN+SIDECAR), so the frozen
  slice's boost (§10.6 #6 slash yield + auto-sodomizer) + recovery accrue to **whoever holds through the freeze**;
  impatient sellers exit on §6 (CoW) and forgo it. No per-holder boost machinery.

### 9.3 The recovery waterfall (each realized tier writes the provision UP)
1. **Secondary lien sale** (sell the defaulted lien — secondaries-first GTM).
2. **Insurance** payout (coverage on the lien).
3. **xALPHA bond liquidation** (`LienXAlphaEscrow` slash → alpha→TAO→USDC into the sidecar; also §10.6 #6 slash yield).
4. **Residual → frozen junior** (first-loss; whatever remains after 1–3).

### 9.4 Authority, oracles, and the integrity bound
- **`DefaultCoordinator`** (CRE-gated) is the **sole** NAV-markdown writer, and its power is **bounded**: it can mark
  down only by `atRiskAmount × (1 − recoveryFloor)` (formula × governed param) on a **verified default**, and write
  up only by **verified realized receipts**. It **cannot set an arbitrary NAV** — the most dangerous power is a
  formula over facts plus a governed constant, never an estimate.
- **Custom "Proof" API oracles for the foreclosure/recovery process (NET-NEW build requirement).** Extends the lien
  **`Proof` notarization API** (memory `lien-perfection-proof-and-risk`; today attests lien-in-SPV + ownership) to
  also attest **default, each foreclosure-process milestone, insurance payout, secondary-sale proceeds, and bond
  liquidation** — each **with proof**, CRE-pushed to the `DefaultCoordinator`. The DON attests **facts, never
  estimates**; that is what keeps the staircase honest. (One Proof-oracle event = one provable re-mark.)
- **Governed:** `recoveryFloor` (per asset class) + the resolution criteria.

### 9.5 Freeze (B) ≠ markdown (A)
A **utilization-squeeze freeze (trigger B)** is a **pure time-hold — no markdown** (liquidity protection; the frozen
slice keeps earning; window exits limited to free equity). A **provision is written only on an actual default
(trigger A)**. Freezing is not impairing.

### 9.6 Components & spec
`DefaultCoordinator` (CRE-gated, bounded markdown writer) + `LienXAlphaEscrow` (slashable bond → sidecar) + the
**Foreclosure `Proof` oracle(s)** (§9.4). Spec: `claude-zipcode.md §4.6` + §11 (two triggers, the duration bond, the
permanent-loss levers). M2 scope.

---

## 10. [→ §4.5.1] The yield engine — auto-sodomizer + the emission program

### 10.1 The modules (8-B5…8-B14)
Each is a **Zodiac Module** (`is Module`, inherit `reference/zodiac-core/contracts/core/Module.sol`) `enableModule`'d
on the Safe(s), mutating the Safe only via inherited `exec(to,value,data,Operation.Call)` (`Module.sol:43`). Deploy
as CREATE2 clones via `ModuleProxyFactory.deployModule`; init in `setUp(bytes)` under `initializer`. **One immutable
CRE operator** is the only caller (`onlyOperator`; `auto-sodomizer.md §8` invariant 1).

| Module | Role |
|---|---|
| 8-B5 | reservoir USDC vault + LP-collateral borrow |
| 8-B6 | LP / stake (gauge) |
| 8-B7 | harvest + vote (`exerciseVe` floor) |
| 8-B8 | exercise oHYDX |
| 8-B9 | market-sell |
| 8-B10 | recycle (USDC → backed zipUSD → into the vault basket → NAV accretion; the single sink) |
| 8-B11 | CRE op surface |
| 8-B12 | monitoring |
| **8-B14** | **haircut buy-and-burn (§7) — in scope from start** |

### 10.2 The steady-state target (the OUTPUT objective)
Drive the basket toward **mostly the staked zipUSD/xALPHA ICHI LP** (zipUSD ~70% / xALPHA ~30%, governed/ICHI-config
ratio). zipUSD is the productive base; **xALPHA is a depth activator held only to the minimum LP-depth requirement,
never speculatively**; USDC/HYDX/oHYDX are **transient harvest-cycle working capital**, not steady-state holdings.
"More ICHI in the vault, the better." As the basket converges, the only volatile/off-chain-priced leg (xALPHA's
`alphaUSD`) shrinks to a thin minority of NAV → NAV becomes increasingly on-chain-priced and stable (reinforces the
short W, §3.3).

### 10.3 The xALPHA emission program (the INPUT strategy — POL-as-liquidity-mining)
- **Source:** the protocol's Bittensor subnet produces alpha emissions (~`$100k/mo` budget, §14), accruing to the
  validator stake → the xALPHA LST exchange rate (§3.2). Secondary source: slashed duration bonds (§9.3, "when
  appropriate").
- **Deployment:** the protocol **deposits the monthly emissions in-kind** (§4.3) for fair-value shares; the engine
  then **auto-pairs that xALPHA with resting vault zipUSD into the 70/30 ICHI LP** (a value-neutral rebalance) and
  **stakes it in the Hydrex gauge for HYDX** — the auto-sodomizer drains HYDX and recycles it back in.
- **Net:** the emission becomes owned LP + protocol equity (not mercenary rewards), activates resting depositor
  capital into yield, and deepens LP — all at once. End-state scale target ≈ $15M USDC deposited for zipUSD; ~$100k/mo
  xALPHA activates ~$250k/mo of resting zipUSD into LP.

### 10.4 Anti-dump + value integrity (why this is sound, not dilutive)
- **Non-dumpable:** the emission goes into vault-owned LP; the protocol's claim is windowed-RQ szipUSD (§2/§5) → no
  emission sell-pressure → the xALPHA price (and thus the mark) stays healthy.
- **Real value:** the $100k/mo is **real subnet emissions** showing up in the LST exchange rate (stake accounting,
  not a pool price the protocol can pump, §3.2) → full fair-value issuance is correct (§3.4, no haircut).
- **IL marked-through** (§3.2): the 70/30 LP is marked at true reserve value; the scheme is value-additive only if
  harvested HYDX clears IL + xALPHA risk — the engine's core bet, tracked in §12.

### 10.5 Source
`pending-docs/auto-sodomizer.md` (+ §11 the compounding flywheel) + `hydrex.md`; xALPHA mark/source
`tickets/bridge/8x-01-szalpha-wrapper-cct.md`. Hydrex/engine addresses in `claude-zipcode.md §4.5.1` + `pending-docs/hydrex.md §2.5`.

### 10.6 The yield stack — what covers IL (junior NAV sources)
The engine's bet: **harvested yield > IL + xALPHA risk.** The IL-covering stack, each a distinct flow marked **once**
into junior NAV (§3), no double-count:
1. **xALPHA in-kind emissions** (the LM program, §4.3/§10.3) — new basket value.
2. **oHYDX** option emissions (8-B7/8-B8) — exercised → HYDX → recycled.
3. **veHYDX voting rewards** — gauge/pool fees + incentives paid as **xALPHA + zipUSD**, **non-RQ-able**, flowing
   into the basket.
4. **xALPHA LST APR** — subnet staking rewards accruing in the LST *exchange rate* (§3.2) of the *existing* xALPHA.
5. **Haircut buy-and-burn** (§7) — impatient-seller haircuts accrete via supply reduction.
6. **Duration-risk xALPHA slash yield** — slashed duration bonds (§9.3 `LienXAlphaEscrow`) routed into the sidecar
   accrue to junior NAV as the compensation for bearing the freeze/duration risk.

Plus an IL **reducer** (not a flow): the **70/30 zipUSD-lean** LP minimizes IL for a given xALPHA move (lower
volatile-asset weight ⇒ less IL). No double-count: the LST APR (existing xALPHA's exchange rate) ≠ the LM deposit
(new xALPHA) ≠ the veHYDX fees (pool trading fees) ≠ the slash yield (defaulter-bond transfers) — distinct sources
that partly arrive denominated in xALPHA.

### 10.7 Economic boundary — Baal vault NAV vs team treasury
The junior is compensated for bearing first-loss by the §10.6 **subsidy-funded refinery — NOT the credit spread.**
Four flows accrue to the **team treasury, never the Baal basket**, and are **never counted in junior NAV** (§3 marks
basket assets only):
1. **xALPHA ⇄ ALPHA arbitrage** (LST mint/redeem arb, `tickets/bridge/8x-01-szalpha-wrapper-cct.md`).
2. **zipUSD ⇄ USDC arbitrage** (the peg, §6.2/§12).
3. **~6% APR on the credit lines** (lending interest, §11).
4. **0.2% flat facility fee on revolving credit**, per line on fulfillment.

Nominally earmarked for xALPHA buyback; given the self-sustaining refinery + §7 buy-and-burn, more likely deployed to
**protocol expansion** (treasury policy, not a vault mechanism). The junior is compensated by the §10.6 refinery, so
**lending yield (B.3/B.4) routes to the treasury — full stop.** Ref
`pending-docs/treasury.md`.

---

## 10.8 Per-module detailed specs (8-B5…8-B13) — closed one at a time

### 8-B5 — strike loop: borrow the warehouse's idle USDC against the ICHI LP
**What it is.** The EVK isolated market + CRE-gated module that finances the oHYDX exercise strike by **borrowing the
~30% strike from the warehouse's idle USDC — the `USDC Resting Vault` (the portion EulerEarn has NOT allocated to
credit lines)** — against the **ICHI LP posted as collateral**, repaid immediately from the HYDX sale. Safe **not by
avoiding depositor capital, but by being overcollateralized (the LP) + short-term + CRE-only.**

**Where it lives.** An **EVK isolated market** = (1) the warehouse's **`USDC Resting Vault`** (the EulerEarn
allocation target holding idle USDC, §11), (2) an **ICHI-LP escrow collateral vault**, (3) a dedicated `EulerRouter`
— the EVK/EVC machinery proven in WOOF-04/05. Plus a **CRE-gated Zodiac module** (`is Module`, `onlyOperator`)
exposing `postCollateral`/`borrow`/`repay`/`withdrawCollateral`. Borrower-of-record = the **szipUSD Safe via its own
EVC account**.

**How it works (one ordered loop per harvest, size-gated by §4 caps).**
1. Unstake an LP slice from the gauge (8-B6).
2. `postCollateral` the slice into the ICHI-LP escrow vault.
3. `borrow` the ~30% strike USDC **from the warehouse `USDC Resting Vault`** (idle, un-utilized).
4. Exercise oHYDX → HYDX (8-B8).
5. **Market-sell** HYDX→USDC (8-B9) immediately.
6. `repay` → `withdrawCollateral` (unlocks at debt=0) → re-stake the LP (8-B6).
The borrow **revolves** — the idle USDC is out only for the loop window, then back in the resting vault.

**Why this shape.** Self-collateralizing (default needs >71% single-order slippage, never placed); market-sell not
resting (must repay immediately; pool net-draining, no buy-side); regime gate (UP/FLAT only; DOWN → `exerciseVe`,
8-B7).

**Hard invariants.** The strike borrow is **overcollateralized by the ICHI LP**, **repaid from the HYDX
sale** each loop, **CRE-permissioned only**, **short-term (one loop window)**, and draws **only un-utilized resting
USDC — never USDC already committed to a credit line**. Depositor USDC is *used* but *protected by the LP collateral*;
worst case = a **stall** (LP unstaked + borrow open, over-collateralized), **not depositor bad debt**.

**What it touches.** **§11 warehouse — the `USDC Resting Vault` is the borrow source** (idle USDC only); 8-B6
(unstake/re-stake), 8-B8 (exercise), 8-B9 (sell), §4 caps + regime gate (8-B11), 8-B12 (monitor the loop), item 8/9
(runs in the Safe; sidecar for the frozen slice).

**Source + addresses (verify on-chain at build).** EVK isolated market = `reference/euler-vault-kit` (EVault, escrow
vault) + `reference/ethereum-vault-connector` (EVC account) + `reference/evk-periphery` (`EulerRouter`) — same stack
as WOOF-04/05; `reference/euler-earn` (the allocator + resting vault, §11); `reference/zodiac-core` `Module`. USDC
`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`; oHYDX `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78` (`discount()`=30);
SwapRouter `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`.

**Params (settled — no open economic decision).** Strike ≈ oHYDX `discount()` = 30% (read on-chain); loop slice size
= §4 soft-bleed caps (8-B12); regime gate = CRE policy (8-B11); EVK market config (LP-collateral LTV must permit the
30% borrow, over-collateralized — set at deploy). Reuses proven WOOF-04/05 EVK patterns → low build risk.

### 8-B6 — LP / stake (gauge)
**What it is.** The module that builds + maintains the **zipUSD/xALPHA ICHI LP** and **stakes it in the Hydrex
gauge** to farm oHYDX, and unstakes/re-stakes slices for the harvest loop (8-B5). This LP is the engine's core
productive position and the steady-state target (§10.2).

**Where it lives.** A CRE-gated Zodiac module (`is Module`, `onlyOperator`) on the Safe, driving: the **ICHI managed
vault** (ALM_ICHI_UNIV3) for zipUSD/xALPHA — add liquidity via `deposit(deposit0, deposit1, to=Safe)`, LP token = the
ICHI vault share; and the **Hydrex gauge** on our pool — `gauge = Voter.gauges(ourPool)`, `gauge.deposit` to stake /
`gauge.withdraw` to unstake.

**How it works.** Build LP (`ICHIVault.deposit`, at the 70/30 target 8-B13 maintains) → `gauge.deposit` to start
farming oHYDX. For the harvest loop / rotation: `gauge.withdraw(slice)` (emissions pause on the slice) → … →
re-stake `gauge.deposit` (8-B5 steps a/e).

**What it touches.** 8-B5 (unstake/re-stake slices), 8-B7 (claims gauge oHYDX + fees), 8-B13 (70/30 ratio + LP
rebuild), §10.3 (the emission program's xALPHA is paired into this LP), item 9 (the staked LP is the basket's core
asset across main/sidecar), item 2 (NAV marks the staked LP via reserves×TWAP, reading the staked position).

**Source + addresses (verify on-chain at build).** `auto-sodomizer.md §4/§9`; `hydrex.md §2.5`: ICHI Vault Factory
`0x2b52c416F723F16e883E53f3f16435B51300280a`, Deposit Guard `0x9A0EBEc47c85fD30F1fdc90F57d2b178e84DC8d8`, Voter
`0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b`; gauge type **ALM_ICHI_UNIV3** (memory `hydrex-gauge-architecture`);
`reference/zodiac-core` `Module`.

**Build PREREQUISITE (hard gate, `hydrex.md §9.5/§10`).** Our pool's gauge must exist and be live — **verify
`Voter.gauges(ourPool) != 0` before wiring.** Creating/whitelisting our zipUSD/xALPHA gauge (`VoterV5.createGauge`,
ALM_ICHI_UNIV3) is an **external Hydrex-governance dependency**, and the POL pool itself is created at deploy.
**Params (settled):** LP ratio 70/30 (§14, maintained by 8-B13); no open economic decision.

### 8-B7 — harvest + vote (exerciseVe floor)
**What it is.** The epoch module that (1) **claims** gauge oHYDX + veHYDX fees to the basket, (2) **defends the vote
floor** by `exerciseVe`-ing a slice (free permalock → grows veHYDX → keeps our gauge fed), (3) **votes** the veHYDX
each epoch (`Voter.vote`, resets weekly) to steer emissions to our gauge, and (4) claims the anti-dilution **rebase**
on the veNFT.

**Where it lives.** CRE-gated Zodiac module (`is Module`, `onlyOperator`) on the Safe (which custodies the
account's veHYDX veNFTs), driving `gauge.getReward()` → oHYDX; `oHYDX.exerciseVe(amount, recipient)` (free permalock,
mints a fresh account-owned veNFT each call); **account-keyed** `Voter.vote(address[],uint256[])` / `Voter.reset()`
(**no tokenId** — VoterV5 is account-keyed); rebase via the **RewardsDistributor** (`Minter._rewards_distributor()`)
`claim_many(uint256[] tokenIds)`. (On-chain-verified 2026-06-08 — the §10.8 surface below supersedes any tokenId-keyed
`vote(tokenId,…)`/`reset(tokenId)`/`balanceOfNFT(tokenId)` phrasing; the floor read is account-aggregate
`ve.getVotes(account)`.)

**How it works (vote-floor-FIRST, inv. 8).** Per epoch: claim → classify regime (8-B11 / `hydrex.md §9.2`) → take
the **vote-floor slice first** via `exerciseVe`, sized to keep our gauge **meaningfully fed, not to chase dominance**
(`hydrex.md §4/§8`: defend a floor; the 62% insider sink is un-winnable). **DOWN regime → more to `exerciseVe`** (the
hedge: never dump into weakness); UP/FLAT → the remainder to the sell path (8-B8/8-B9). Re-vote each epoch; claim
rebase (7%→0% by ~wk64). `exerciseVe` is **free** (permalock, no strike).

**What it touches.** 8-B8/8-B9 (the non-floor slice → exercise + sell), 8-B5 (the sell loop it feeds), 8-B10/8-B13
(free-value routing/compound), §10.6 #3 (the veHYDX **fees in xALPHA+zipUSD** are a refinery source flowing to the
basket), item 2 (NAV: **veHYDX is permalocked/non-redeemable → marked at ~0 principal; only the realized oHYDX +
fees it produces count, as claimed** — §3.2 note).

**Source + addresses (on-chain-verified Base 8453, 2026-06-08).** `hydrex.md §4/§8/§9.2/§2.6`; `auto-sodomizer.md §4
(steps 1/3a/6) / §8 inv 8`. Voter `0xc69E3eF39E3fFBcE2A1c570f8d3ADF76909ef17b` (account-keyed
`vote(address[],uint256[])` `0x6f816a20` / `reset()` `0xd826f88f` / `getEpochDuration()` = 604800 / `ve()`), veHYDX
`0x25B2ED7149fb8A05f6eF9407d9c8F878f59cd1e1` (`getVotes(address)` account-aggregate floor, `tokenOfOwnerByIndex`,
`balanceOfNFT`), oHYDX `0xA1136031150E50B015b41f1ca6B2e99e49D8cB78` (`exerciseVe(amount, recipient)` → fresh nftId),
RewardsDistributor `0x6FCa200fE1F71Be1b8714aCFB5e9d3a147cceD42` (= `Minter._rewards_distributor()`;
`claim(uint256)` / `claim_many(uint256[])` / `claimable(uint256)`), Minter
`0xA7D64625F45548a19B2A19e28E7546bb2839003E`; `reference/zodiac-core` `Module`.

**Params (settled — governed CRE policy, no user economic decision).** Vote-floor size = "enough to keep the gauge
fed" (governed, `hydrex.md §4/§8`); lock-vs-sell split = regime-driven (8-B11) + **front-loaded** (edge is weeks
38–64 as the rebase sunsets — re-budget the split, `hydrex.md §12`); `exerciseVe` is free permalock (not a knob).

### 8-B8 — exercise oHYDX
**What it is.** The module that exercises oHYDX → HYDX **within the strike loop (8-B5)**: pays the ~30% strike in
USDC (borrowed in 8-B5) to convert the gauge's oHYDX into liquid HYDX for the market-sell (8-B9). Distinct from the
**free** `exerciseVe` permalock (8-B7) — this is the *paid* exercise of the sell slice.

**Where it lives.** CRE-gated Zodiac module (`is Module`, `onlyOperator`) on the Safe, calling oHYDX
(`OptionTokenV4`, fork-verified Base 8453).

**How it works (8-B5 step c).** Profitability-cutoff pre-check (skip if HYDX < **$0.015** — the loop cutoff, user-ratified 2026-06-08; $0.018 = the amber/taper-start tier → route those tokens to `exerciseVe`
instead, `hydrex.md §2.4`) → `oHYDX.exercise(amount, maxPayment, recipient[, deadline])` (**prefer the deadline
overload**) paying `max(30%·2h-TWAP, $0.01 floor)` per token → HYDX to the Safe. Strike USDC is the 8-B5 borrow; the
HYDX is immediately market-sold (8-B9) to repay.

**What it touches.** 8-B5 (the borrowed strike funds `maxPayment`; the loop wraps this call), 8-B7 (regime/floor
decides exercise-vs-`exerciseVe`; soft-halt reroutes to ve), 8-B9 (sell the resulting HYDX), item 2 (oHYDX marked at
intrinsic pre-exercise, §3.2).

**Source + addresses (fork-verified Base 8453, 2026-06-06).** oHYDX (`OptionTokenV4`)
`0xA1136031150E50B015b41f1ca6B2e99e49D8cB78`: `exercise(amount,maxPayment,recipient)` **and**
`exercise(amount,maxPayment,recipient,deadline)` (prefer deadline), `getDiscountedPrice(amount)`,
`getTimeWeightedAveragePrice(amount)`, **`getMinPaymentAmount()` — no args**, `discount()` (= 30).
`auto-sodomizer.md §4(c)/§9`; `reference/zodiac-core` `Module`.

**Params (settled — no open economic decision).** Strike = `max(30%·TWAP, $0.01)` read from oHYDX (`discount()`=30 +
`getDiscountedPrice`/`getMinPaymentAmount`), not a knob; profitability cutoff **$0.015** (governed, `hydrex.md §2.4`; $0.018 = amber/taper-start, $0.01 = mechanical dead floor);
`maxPayment` slippage bound set per call.

### 8-B9 — market-sell
**What it is.** The module that **market-sells HYDX→USDC** (the strike-loop repay leg, 8-B5) and **zipUSD→xALPHA on
our POL** (the Mode B/C buy leg, 8-B10/8-B13), via the Hydrex SwapRouter, sized within the soft-bleed caps.

**Where it lives.** CRE-gated Zodiac module (`is Module`, `onlyOperator`) on the Safe, calling
`SwapRouter.exactInputSingle`.

**How it works.** Immediately after exercise (8-B8), HYDX→USDC to **repay the 8-B5 borrow** — a **market** sell, not
a resting order (must repay now; the HYDX/USDC pool is net-draining with no buy-side, `hydrex.md §2.3`). Every sell
is bounded by the §9.3 soft-bleed caps (these **size the loop**, not "sell slowly"). The same module does
zipUSD→xALPHA on our POL for the recycle/compound buy leg.

**What it touches.** 8-B5 (repay leg of the loop), 8-B8 (sells the exercised HYDX), 8-B10/8-B13 (zipUSD→xALPHA buy
leg), 8-B12 (caps/regime/profitability-halt), the HYDX/USDC **exit pool** (`0x51f0…`) — the **binding constraint**
(net-draining, ~$429k, *not ours to grow*, `hydrex.md §5`).

**Source + addresses (verify at build).** `SwapRouter` `0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e`
(`exactInputSingle`); HYDX/USDC pool `0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2`; USDC
`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`; HYDX `0x00000e7efa313F4E11Bfff432471eD9423AC6B30`.
`auto-sodomizer.md §4(d)/§5/§9`; `hydrex.md §9.3`; `reference/zodiac-core` `Module`.

**Params (settled — governed caps, surfaced in 8-B12).** Soft-bleed caps (`hydrex.md §9.3`): per-order slippage
≤2–3%, per-epoch volume ≤1–2% of pool USDC, never faster than the 2h-TWAP, taper $0.033 → amber-taper ~$0.018 → halt $0.015. No open
economic decision.

### 8-B10 — recycle / payout (Mode A/B)
**What it is.** The module that routes the harvest's **free value** (§4 step 4f) to depositors via the Treasury-owned
allocation policy — **Mode A (clean USDC pro-rata)** and **Mode B (boosted xALPHA recycle loop)**. (Mode C compound =
8-B13.)

**Where it lives.** CRE-gated Zodiac module (`is Module`, `onlyOperator`) on the Safe.

**How it works.**
- **Mode A — clean USDC:** net USDC distributed pro-rata to szipUSD shares (cash leaves; no AUM growth; the plain
  USDC-yield fallback).
- **Mode B — boosted xALPHA recycle loop (`treasury.md §4.7`):** net free USDC → **deposit into loan book/warehouse**
  (real AUM) → **mint zipUSD (backed 1:1 by that USDC)** → **swap zipUSD→xALPHA on our POL** (8-B9 buy leg; fee
  recaptured, we own LP+veNFT) → distribute xALPHA as a **"+30% boost."** Retains USDC in the loan book
  (AUM-accretive), markets louder.
- Mode selection / the A/B/C split is a **Treasury-owned vault parameter** (§11.2), set in the CRE workflow (8-B11),
  per-vault not per-deposit.

**Load-bearing invariant (§8 inv 3).** The Mode-B boost buy-side is funded **ONLY by HYDX-extracted (free) value** —
never reserves, never unbacked mint (the Mode-B zipUSD is deposit-backed by construction). Payouts are **realized
distributions, not NAV** (`auto-sodomizer.md §7`).

**What it touches.** 8-B9 (zipUSD→xALPHA buy leg), 8-B5 (source of free value), 8-B13 (Mode C — the sibling sink),
the warehouse/loan book + `ZipDepositModule` (Mode B deposits USDC → senior backing → backed zipUSD mint), 8-B11
(allocation policy/weights), item 2 (payouts are realized, not marked into NAV).

**Source (verify at build).** `auto-sodomizer.md §6/§11.2/§8 inv 3`; `treasury.md §4.7`; `ZipDepositModule`
(WOOF-06); `SwapRouter` (8-B9); `reference/zodiac-core` `Module`.

**Params — OPEN Treasury policy (the engine's one genuinely-open decision; weight-agnostic mechanism, NOT a build
blocker).** The concrete **A/B/C default weights**, the **taper schedule** (compound-weighted in the growth window →
boost/clean as the HYDX bleed degrades), and whether the vote-floor `exerciseVe` slice (§4 step 3) is taken
before/after the Mode-C budget. `auto-sodomizer.md §11.2`: "the mechanism is weight-agnostic; only the numbers are
open — pin when engine economics are finalized (`treasury.md`)." **Owned by Treasury, deferred to `treasury.md`.**

### 8-B11 — CRE op surface
**What it is.** The **single CRE-operator surface** — the `onlyOperator` entrypoints through which the **one immutable
CRE workflow** drives every engine module (harvest/exercise/borrow/sell/payout/compound) **and** the main↔sidecar
rotation (item 9 / §8.3). The orchestration seam + the regime classifier + the split policy live here.

**Where it lives.** A custom **`onlyOperator`** modifier + the immutable operator address on each module (Zodiac's
`onlyOwner` is admin-only, so it can't be the op gate — `auto-sodomizer.md §8 inv 1`). The **off-chain CRE workflow**
(the orchestrator; same trust pattern as `tickets/bridge/8x-02-xalpha-apr-cre.md`) computes regime/splits/sizes and calls these
entrypoints. **The CRE workflow itself is a separate build** (`claude-zipcode.md §8.7`; CRE-05 build, not yet run);
8-B11 is the *on-chain surface* it calls.

**How it works (per epoch + on triggers).** claim → classify regime (price vs short EMA: UP/FLAT/DOWN,
`hydrex.md §9.2`) → split (vote-floor-first, then the §11.2 A/B/C weights) → drive the strike loop (8-B5/8-B8/8-B9)
→ route free value (8-B10/8-B13) → re-vote + rebalance (8-B7) → rotate main↔sidecar per utilization (item 9). Every
mutating call is `onlyOperator`.

**Invariant (`auto-sodomizer.md §8 inv 1`).** **ONE immutable CRE operator** is the only writer of
harvest/exercise/borrow/sell/payout/compound/rotation. Immutable = set at deploy. This permissioning is what makes
the revolving borrow (8-B5) safe — it kills the external oracle-manipulation exploit.

**What it touches.** Every module 8-B5…8-B13 (it is their only caller); item 9 (hosts the rotation); 8-B12 (consumes
its regime/caps/halts); the CRE workflow (`claude-zipcode.md §8.7`).

**Source (verify at build).** `auto-sodomizer.md §3/§8 inv 1`; `hydrex.md §10` (bot pipeline: Watcher → Rebalancer →
Voter); `claude-zipcode.md §8.7`; `reference/zodiac-core` `Module`; `reference/cre-*` for the workflow.

**Params (settled).** Operator = the single immutable CRE workflow address (deploy-time). Regime classifier, split
policy (= 8-B10's open weights), caps (8-B12) are CRE-workflow policy. No *additional* open economic decision beyond
8-B10's allocation weights.

### 8-B12 — monitoring
**What it is.** The read-only metrics + surveillance surface: NAV, **trailing-realized APR**, the **TVL cap** (the
critical governor), utilization `U`, IL-vs-HYDX, plus the surveillance tripwires (race / whale / extraction / floor /
backing / clock). Feeds §12, the depositor UI, and the CRE gates (8-B11).

**Where it lives.** **On-chain:** the NAV + trailing-APR computation (CRE-published on-chain, reuse
`tickets/bridge/8x-02-xalpha-apr-cre.md` pattern) + the `maxDeposit` **TVL gate** (the WOOF-06 deposit gate). **Off-chain:** the
read-only dashboard (multicall + archive + event indexer) — **full spec in `monitoring.md`.**

**How it works (the metrics).**
- **NAV** = (ICHI LP value + idle basket + accrued undistributed proceeds + in-flight loop balance **net of the open
  borrow**) / supply — what §3 (item 2) computes; 8-B12 surfaces it.
- **APR — trailing realized only** = USD actually distributed over trailing 7d, annualized ÷ avg TVL. **Never a
  projection** (§8 inv 7); degrades visibly as the HYDX bleed bites — by design.
- **TVL cap (§8 inv 6 — the primary failure mode if absent).** `maxDeposit` gates so `expected_weekly_oHYDX_sold ≤
  pool_absorption(measured)`; an uncapped vault dumps faster than the market clears → kills its own APR. **Re-derived
  each epoch** from measured net Swap flow (`hydrex.md §5`).
- **Tripwires (`monitoring.md`):** the race (vote-power), the whale (team lock-power jump = regime-change tripwire),
  extraction (USDC depth, fill curve, net flow), floor (spread, distance-to-$0.01, profitability-halt), **backing
  (szipUSD backing ratio; `<1` pages Treasury)**, clock (rebase/decay/sunset). Each amber/red maps to a §9 action.

**What it touches.** §12; item 2 (NAV/APR feed); 8-B11 (gates consume regime/caps/halt); 8-B5/8-B9 (TVL + soft-bleed
caps size the loop); WOOF-06 (`maxDeposit` TVL gate); the depositor UI (trailing-realized only).

**Source (verify at build).** `auto-sodomizer.md §7/§8 inv 6&7`; `hydrex.md §10`; **`monitoring.md` (full
surveillance spec)**; `tickets/bridge/8x-02-xalpha-apr-cre.md` (the on-chain APR/NAV publish pattern); `reference/cre-*`.

**Params (settled).** TVL cap = a **measured formula** (re-derived each epoch, not a static knob); trailing-realized
only; soft-bleed caps (8-B9); tripwire thresholds (`monitoring.md §3` escalation tiers, governed). No open economic
decision.

### 8-B13 — REMOVED (absorbed into 8-B10)
**Superseded.** The Mode-C compounder / LP-rebalance evaluator (balanced ICHI add: size xALPHA, swap zipUSD→xALPHA
to fund the short leg) is **fully subsumed by 8-B10 recycle + 8-B6 single-sided LP.** The 8-B10 recycle mints
backed zipUSD into the basket and 8-B6 single-sides it into the gauge-staked LP — so the balanced-add / swap-to-fund
machinery is moot (single-sided LP needs no xALPHA leg). There is one sink (recycle → NAV), not three modes; the
engine's on-chain contracts end at 8-B10. See `claude-zipcode.md §4.5.1`.

**Where it lives.** CRE-gated Zodiac module (`is Module`, `onlyOperator`) on the Safe.

**How it works (the LP-rebalance evaluator, per epoch).**
1. **Budget** `B` = the Mode-C slice of `freeValueAccrued` (the §11.2 allocation policy, 8-B10/8-B11).
2. **Deposit `B` to the warehouse** (`EE_POOL.deposit(B, CreditWarehouse)`) + **mint backed zipUSD** (the §4.5 zap /
   `ZipDepositModule` path; backing per 8-Bw) — the USDC is now senior backing **and** lending capacity.
3. **Read** the ICHI vault's target `xALPHA:zipUSD` ratio `r` → `xNeeded = r · zipToDeposit`.
4. **Inventory check:** `xHave ≥ xNeeded` → add directly; `xHave < xNeeded` → **swap** part of the fresh
   zipUSD→xALPHA on our POL (8-B9, fee recaptured), **slippage-capped**, to cover the shortfall.
5. **Re-derive** the balanced (zipUSD, xALPHA) pair from *actual* post-swap balances (no second swap, no dust chase).
6. **Add + stake:** ICHI `deposit(zipAmount, xAlphaAmount)` → LP → `gauge.deposit` (8-B6).
7. **Account:** decrement `freeValueAccrued` by `B`.

**The flywheel.** dump HYDX → free-value USDC → warehouse (credit capacity↑) → mint backed zipUSD → grow staked LP
(emissions↑) → dump more HYDX. Bounded by the TVL cap (§7/8-B12), soft-bleed caps (§4), free-value-only (§8 inv 3).

**Invariants (`auto-sodomizer.md §11.3` + §8 inv 3).** **Free-value-only** (spends only `freeValueAccrued`; the
zipUSD it mints is backed 1:1 by the just-deposited USDC — deposit precedes mint; never depositor USDC/reserves/
unbacked mint); **swap is buy-side + per-order slippage-capped**; **no idle-xALPHA accumulation** (convert on demand,
use on-hand xALPHA first — the `xHave ≥ xNeeded` branch is where the §10.3 emission/depositor xALPHA gets paired);
**backing is automatic** (USDC deposited before mint → new zipUSD always senior-backed; the credit-expansion and
LP-growth legs are the **same capital, never double-counted**).

**What it touches.** 8-B10 (the Mode-C free-value slice), 8-B6 (add+stake LP), 8-B9 (zipUSD→xALPHA swap), the
`CreditWarehouse`/`EE_POOL` + `ZipDepositModule` (deposit→backing→backed mint, same as Mode B/WOOF-06), §10.2 (holds
the 70/30 steady-state), §10.3 (pairs the emission-program xALPHA via the `xHave` branch).

**Source (verify at build).** `auto-sodomizer.md §6/§11/§11.1/§11.3`; ICHI `deposit` + gauge (8-B6); `EE_POOL`/
`CreditWarehouse` (§11/8-Bw, `reference/euler-earn`); `ZipDepositModule` (WOOF-06); `SwapRouter` (8-B9);
`reference/zodiac-core` `Module`.

**Params (settled).** Ratio `r` read on-chain from the ICHI vault (not a knob); zipUSD backing ratio per 8-Bw; the
Mode-C budget `B` = the §11.2 weight (= 8-B10's open Treasury policy); swap slippage cap (8-B9). No *additional* open
decision.

---

## 11. [→ §4.5] Senior backing — CreditWarehouse + Roles modifier (8-Bw) (separate)

**What it is.** The **senior-backing custody**: a dedicated Gnosis Safe holding **EulerEarn (ERC-4626) shares** (the
senior backing for zipUSD), governed by a **Zodiac Roles-modifier-v2** so a CRE adapter can do **only** the warehouse
operations — SUPPLY/APPROVE/REDEEM/REPAY — **Call-only, receiver pinned to the Safe.** It backs the **senior**
(zipUSD); **separate from the junior Baal sidecar (§8) — never conflate.**

**Structure (allocator).** EulerEarn is an **allocator** — it directs the deposited USDC across (a) a **`USDC Resting
Vault`** (the un-utilized USDC not yet lent) and (b) **per-line isolated credit lines** (each individually deployed,
WOOF-04). The **`USDC Resting Vault` is the source the strike loop (8-B5) borrows from** — the ICHI LP is listed as
collateral against the resting vault, so the engine does **short-term option-exercising against the existing pool of
un-utilized warehouse USDC** (CRE-only, overcollateralized). No separate "treasury" borrow vault exists.

**Where it lives.** The **CreditWarehouse Safe** + a **Roles-modifier-v2** instance enabled on it (the access-control
engine) + a **CRE adapter** (the sole role-holder) through which all warehouse ops route. Deploy script + the Roles
scope config (generated via `zodiac-roles-sdk`).

**How it works.**
- The Safe holds EulerEarn shares. Ops (standard ERC-4626, `reference/euler-earn/src/EulerEarn.sol`):
  `approve` (USDC→EulerEarn), `deposit(assets, receiver=Safe)` (`:560`, supply USDC → shares),
  `redeem(shares, receiver=Safe, owner=Safe)` (`:596`) / `withdraw` (`:580`) (shares → USDC), repay.
- The **Roles-modifier-v2** scopes a CRE-adapter role to **only** those selectors on **only** the EulerEarn (+USDC)
  targets, **Call-only** (`ExecutionOptions.None`, no delegatecall), with the **`receiver`/`owner` params pinned to
  the Safe** (`EqualToAvatar`) so funds can't be redirected. `Roles.assignRoles` (`:69`) assigns the adapter the
  role; `Roles.execTransactionWithRole` (`:153`) executes scoped calls; scopes built via
  `PermissionBuilder.scopeTarget` (`:86`) / `scopeFunction` (`:133`) with `EqualToAvatar`/`EqualTo` conditions.
- The CRE workflow drives supply/redeem as deposits/redemptions flow.

**What it touches.** zipUSD (the warehouse is its 1:1 senior backing — `ESynth` mints against it); WOOF-06 (USDC →
warehouse → backed zipUSD); **8-B10/8-B13** (Mode B/C deposit free-value USDC here → senior backing + lending
capacity); **§12** senior queue (redeems shares → USDC to fulfill zipUSD redemptions); the built **lending core
(WOOF-01…05)** — the warehouse is the senior capital the isolated credit lines draw against.

**Source + addresses (verify at build).** `reference/euler-earn` `EulerEarn.sol` (`deposit:560`/`mint:571`/
`withdraw:580`/`redeem:596`), `EulerEarnFactory`; `reference/zodiac-modifier-roles` `Roles.sol`
(`assignRoles:69`/`execTransactionWithRole:153`), `PermissionBuilder.sol` (`scopeTarget:86`/`scopeFunction:133`),
`Types.sol` (`ExecutionOptions.None`, `EqualToAvatar`/`EqualTo`), `zodiac-roles-sdk`. Roles Modifier v2 mastercopy
(Base) `0x9646fDAD06d3e24444381f44362a3B0eB343D337`.

**Build notes.** EulerEarn pins **solc 0.8.26 ≠ our 0.8.24 → MOCK it** in tests (interact with the deployed vault on
a fork, as WOOF-04/05 did). Reuse the WOOF-05 EulerEarn wiring (curator-timelock-0, `baseUsdcMarket`).

**Params (settled — security config, not economic).** The scoped selector set (deposit/approve/redeem/withdraw/
repay); Call-only; `receiver`/`owner` pinned `EqualToAvatar`; the EulerEarn curator/timelock config (per WOOF-05).
No open economic decision.

---

## 12. [→ §6.1] Senior redemption — ZipRedemptionQueue (separate)

**What it is.** The **SENIOR exit**: zipUSD → USDC via an **ERC-7540 async epoch queue** with **pro-rata partial
fills** when the warehouse can't satisfy everyone at once. **NOT the junior Exit Gate (§5)** — different instrument
(zipUSD = the senior $1 dollar, not the szipUSD junior share), different exit. Never conflate.

**Where it lives.** A **fork of `reference/erc7540-reference`** (`BaseERC7540` + `ControlledAsyncRedeem`) + a
Maple-style pro-rata settle (`reference/maple-withdrawal-manager`). Contract `contracts/src/supply/
ZipRedemptionQueue.sol`.

**How it works (`requestRedeem → fulfill → claim`).**
1. **`requestRedeem(shares=zipUSD, controller, owner)`** (`ControlledAsyncRedeem.sol:39`) — user queues; zipUSD
   escrowed; returns `requestId`.
2. **`settleEpoch()` on a 30-day boundary via CRE cron** — the operator redeems warehouse EulerEarn shares → USDC
   (§11), then **`fulfillRedeem(controller, shares)`** (`:65`, `onlyOwner` = operator) for queued requests,
   **pro-rata** when available USDC < total requested (Maple-style settle).
3. **`withdraw(assets, receiver, controller)` / `redeem`** (`:81`) — user claims the fulfilled USDC
   (`claimableRedeemRequest:57`).

**Why a queue (not instant).** zipUSD is backed by the warehouse (EulerEarn shares + credit lines), which isn't
instantly liquid; the epoch + pro-rata fill **throttles redemptions to warehouse liquidity** (the draw-vs-redemption
contention, claude `§6.2/§6.3`), protecting the senior backing.

**What it touches.** zipUSD (the redeemed instrument); **§11 warehouse** (the queue pulls USDC by redeeming EulerEarn
shares); the junior **coverage floor (§5.4)** (the senior must stay backed); the CRE cron (`settleEpoch`); WOOF-06
(the inverse mint). Distinct from the junior Exit Gate (§5).

**Source (verify at build).** `reference/erc7540-reference` (`BaseERC7540`, `ControlledAsyncRedeem`:
`requestRedeem:39`, `fulfillRedeem:65`, `claimableRedeemRequest:57`, `withdraw:81`);
`reference/maple-withdrawal-manager` (`MapleWithdrawalManager` — pro-rata settle); `reference/euler-earn` (warehouse
redeem). **Low novelty — a fork + a settle.**

**Params (settled).** Epoch boundary = **30 days** (governed); pro-rata settle when undersupplied. No open economic
decision.

---

## 13. [→ §4.5 / §4.5.1] Build components & order

| Item | Component | Status |
|---|---|---|
| 8-B1 | Substrate scaffold — Baal MAIN Safe **+ sidecar** via deployed `BaalAndVaultSummoner` (Base `0x2eF2…`); a summon SCRIPT (Baal is 0.8.7, deployed) | **SPEC CLOSED** (see "Substrate scaffold — 8-B1") |
| **SzipNavOracle** | §3 hybrid NAV oracle (`is ReceiverTemplate`) | NET-NEW |
| **Exit Gate + szipUSD** | §4/§5 — Loot custody, manager(2) mint/burn, szipUSD ERC20, sole RQ, queue+windows, paired burn | NET-NEW |
| 8-B5…8-B10 | engine modules — strike loop / LP-stake / harvest-vote / exercise / sell / recycle (§10.8, per-module); 8-B11 CRE-op + 8-B12 monitor are off-chain. **8-B13 REMOVED** (absorbed into 8-B10) | **SPEC CLOSED** |
| **8-B14** | haircut buy-and-burn (§7) | NET-NEW, **in scope** |
| 8-Bw | CreditWarehouse + Roles (§11) | **BUILT-VERIFIED 2026-06-09** (`WarehouseAdminModule` is ReceiverTemplate Roles-v2 member; 23/23 fork, 424/424 total; `tickets/sodo/8-Bw-credit-warehouse.md`) |
| DefaultCoordinator / LienXAlphaEscrow / **Foreclosure Proof oracle(s)** | loss side (§9) — bounded markdown + recovery waterfall + foreclosure-milestone attestation | spec'd (M2), TODO |
| ZipRedemptionQueue | senior queue (§12) | spec'd, TODO |
| WOOF-06 / INFLOW-06 | deposit zap + interface (§15) | **RE-AUTHOR** |

**Build order:** (1) 8-B1 substrate (MAIN+sidecar via `BaalAndVaultSummoner`); (2) **SzipNavOracle** (§3 — issuance
depends on it); (3) **Exit Gate + szipUSD** (§4/§5, incl. the §7 paired-burn hooks); (4) **re-author WOOF-06 +
INFLOW-06** (§15) against the now-correct seams; (5) build WOOF-06, then **8-B14** (§7), then engine 8-B5…8-B10
(8-B13 removed — absorbed into 8-B10), then 8-Bw, then loss side, then queue.

> Reconcile-first (memory `ticket-authoring-method`): spec-gap → fix `claude-zipcode.md` FIRST (after this draft is
> approved + integrated), then the ticket, then cold-build zero-guess.

---

## 14. [→ §17] Parameter rollup (index only — NOT a review checklist)

> These are **defined with their components** (each row's `Meaning` names the owning mechanism) and are
> **operational/governed defaults**, not decisions to make in a basket. Most are ops hygiene (oracle guards, spend caps, utilization
> limits, bond term) set by governance later with real data. **Only two are genuine economic calls** — `recoveryFloor`
> (§9, markdown harshness) and `coverageFloor` (§5, senior cushion) — and each is decided *in its own section's
> review*, not here. This table is just the §17 where-defined index.

| Param | Meaning | Proposed |
|---|---|---|
| `navPerShare₀` | genesis share price | **$1.00** |
| `W` | NAV TWAP window | **4h — LOCKED 2026-06-07** (fixed, decoupled from harvest) |
| `maxAge` | NAV push staleness bound | governed |
| `maxDeviation` | per-push circuit-break | governed |
| **self-issuance haircut** | discount on in-kind xALPHA deposits | **NONE — full fair-value mark** |
| `d` | haircut buyback discount to TWAP NAV | governed (illustrated 10%) |
| `buybackCap` | max engine USDC to bids / cycle | governed |
| ~~`coverageFloor`~~ | RESOLVED — **not a knob**; = the freeze's utilization-committed slice (§5.4/§8) | — |
| `recoveryFloor` | day-one provision `= atRisk×(1−floor)`; **HIGH** (insured/collateralized → duration-risk, §9.1) | direction LOCKED; % underwriting-derived per originator/insurance |
| window cadence | liquidity-window frequency | governed (harvest-linked) |
| **xALPHA emission budget** | monthly in-kind deposit size | **~$100k/mo (subnet emission rate)** |
| **LP target ratio** | zipUSD : xALPHA in the ICHI LP | **~70:30 (governed / ICHI-config)** |
| `U_lock` / `U_max` / `maxLockFraction` | utilization triggers / freeze ceiling | governed (§11) |
| bond length | xALPHA duration bond term | governed (§11) |

**Locked decisions (for the §17 log):** two-token model; Gate sole real-Loot holder; Gate absorbs the
mint shaman; NAV-proportional bracketed issuance; hybrid on-chain-accumulator NAV oracle (W≈4h); two-layer xALPHA
mark; generalized in-kind fair-value issuance with **no haircut**; POL-as-liquidity-mining emission program; CoW
secondary; 8-B14 buy-and-burn in scope; pari-passu loss / no team subordination; "first-loss floor" = exit
constraint; **loss = conservative provision marked on a staircase of verified facts** (governed `recoveryFloor` +
Proof-attested foreclosure events + realized-receipt write-ups, bounded `DefaultCoordinator`, true-up at resolution).

---

## 15. The WOOF-06 / INFLOW-06 / WOOF-06-report re-author (specific targets)

> Re-authored **after** this draft is approved + integrated, in the build window (reconcile spec → ticket → build).

### 15.1 `tickets/woof/WOOF-06-deposit-module.md`
Current ticket mints **on-behalf Loot to the user** (`depositFor(zipAmount, msg.sender)` + `Zapped(…loot)` + raw-Loot
`ZeroLoot`/`ResidualBalance`). **All wrong** under the two-token model. Re-author to:
- `zap` ends with `Gate.depositFor(asset=zipUSD, amount=zipMinted, receiver)` (NOT `msg.sender`-as-Loot-holder; the
  **Gate values it via §3**, the caller does not pass a value). The Gate mints **Loot to itself** and **szipUSD to
  `receiver`**; `depositFor` **returns the szipUSD share amount**.
- Issuance **NAV-proportional + bracketed + staleness-guarded + round-down** (§3/§4) — read `SzipNavOracle`, not 1:1.
- Events/asserts move to the **szipUSD** share: `Zapped(user, usdcIn, zipMinted, sharesOut)`;
  `ZeroLoot`/`ResidualBalance` → **`ZeroShares`/share-residual** against szipUSD credited to `receiver`.
- Verify `ESynth` + the Gate seam + `SzipNavOracle` faces against `reference/` at build; drop "DOC-ALIGNED ONLY".

### 15.2 `tickets/inflow/INFLOW-06-deposit-module.md`
Frontend half (verify vs `reference/euler-lite`). Re-author to: one **szipUSD position** view ("szipUSD: $X, ~Y% APR"),
**NAV/share** from `SzipNavOracle`, the **transferable** ERC20 share (not soulbound, not raw Loot); deposit-preview
`sharesOut = value / navEntry`; surface both exits (window redeem status track §5.2 + sell on CoW §6); drop all
"on-behalf Loot to user" / soulbound-claim language.

### 15.3 `reports/WOOF-06-report.md`
Status → **STALE → RE-AUTHORED-PENDING**; record that the two-token / NAV-issuance redesign invalidated the prior
`depositFor(zipAmount, msg.sender)`→user-Loot build; the keepsake (`contracts/src/supply/ZipDepositModule.sol`) is
against the retired seam and must be rebuilt; blocked until 8-B1 + SzipNavOracle + Gate land.

---

## 16. Reference repos & canonical-source rules

> Full file:line map: `reference/BAAL-ZODIAC-REFERENCE-MAP.md`.

| Repo (`reference/…`) | Use for |
|---|---|
| `Baal` | **CANONICAL** Baal: `Baal.sol` (bitmask, mint/burn, `ragequit`), `BaalSummoner`, `BaalAndVaultSummoner` (sidecar), `LootERC20`. |
| `zodiac-core` | **base contracts to inherit** — `Module`/`Modifier`/`Operation`/`ModuleProxyFactory` for 8-B5…8-B14. |
| `zodiac` | address book + `deployAndSetUpModule`, module ABIs. |
| `zodiac-modifier-roles` | **Roles v2 (warehouse)** + **`packages/sdk/src/swaps/` CoW order SDK** (§6/§7). |
| `tickets/bridge/8x-01-szalpha-wrapper-cct.md`, `evm-bittensor`, `subtensor` | **xALPHA LST + mark source** (precompiles `0x805`/`0x802`; CCIP/CCT bridge) for §3/§10. |
| `erc7540-reference`, `maple-withdrawal-manager` | senior queue (§12). |
| `euler-earn`, `euler-vault-kit`, `ethereum-vault-connector`, `evk-periphery`, `euler-price-oracle` | venue (Euler): EulerEarn (warehouse), EVK, EVC, `ESynth` (zipUSD). |
| `cre-*`, `chainlink-*` | CRE workflow + push-oracle plumbing. |
| `euler-lite`, `zipcode-finance-ui-prototype` | frontend (INFLOW). |
| `baal-v3.5` | **DECOY — ignore.** | `zodiac-module-reality` | **IGNORE** (optimistic-oracle gov). |

**Canonical-source rules:** Baal → `reference/Baal` (never `baal-v3.5`); inherit Zodiac → `reference/zodiac-core`;
addresses/SDK → `reference/zodiac`; warehouse access control + CoW SDK → `reference/zodiac-modifier-roles` v2;
xALPHA mark → `tickets/bridge/8x-01-szalpha-wrapper-cct.md` + Subtensor precompiles.

---

## 17. Base mainnet (8453) address book (verify on-chain at build)

| Contract | Address |
|---|---|
| Zodiac ModuleProxyFactory v1.2.0 | `0x000000000000aDdB49795b0f9bA5BC298cDda236` |
| Zodiac Roles Modifier v2 mastercopy | `0x9646fDAD06d3e24444381f44362a3B0eB343D337` |
| Baal singleton (template) | `0xE0F33E95aF46EAd1Fe181d2A74919bff903cD5d4` |
| **BaalAndVaultSummoner (8-B1 — main+sidecar)** | `0x2eF2fC8a18A914818169eFa183db480d31a90c5D` |
| BaalSummoner | `0x22e0382194AC1e9929E023bBC2fD2BA6b778E098` |
| Loot singleton | `0x52acf023d38A31f7e7bC92cCe5E68d36cC9752d6` |
| Shares singleton | `0xc650B598b095613cCddF0f49570FfA475175A5D5` |
| Baal Advanced Token Summoner | `0x97Aaa5be8B38795245f1c38A883B44cccdfB3E11` |
| Gnosis MultiSend (Base) | `0x998739BFdAAdde7C933B942a68053933098f9EDa` |
| Tribute Minion (Base) | `0x00768B047f73D88b6e9c14bcA97221d6E179d468` |
| Poster (DAO metadata) | `0x000000000000cd17345801aa8147b8D3950260FF` |
| DAOhaus Base subgraph id | `7yh4eHJ4qpHEiLPAk9BXhL5YgYrTrRE6gWy8x4oHyAqW` |

Hydrex/engine, CoW (`GPv2Settlement`/`VaultRelayer`), and the xALPHA CCT bridge / Subtensor precompile addresses to
be pinned at build from `pending-docs/hydrex.md §2.5`, `reference/zodiac-modifier-roles` swaps, and
`tickets/bridge/8x-01-szalpha-wrapper-cct.md`.

---

## 18. Corrected / load-bearing facts (do not re-derive wrongly)

1. **Loot is 18-decimal** (`LootERC20`, no `decimals()` override); `mintLoot`/`burnLoot` take **base units** →
   fractional shares native; no "integer-share slashing".
2. **`burnLoot` = pure supply reduction, NO asset payout** (`_burnLoot:847`), manager-only (`:834`), **no
   window/liquidity** → the §7 buy-and-burn retire path. Only **`ragequit`** moves assets (§5).
3. **Shaman bitmask: admin=1, manager=2, governor=4** (verified; ops docs are BACKWARDS). The Gate needs **manager**.
4. **`ragequit` cannot be gated/paused** → soulbound Loot in the Gate + windowed RQ is the only enforcement;
   `tokens[]` **ascending** (`:625`); mint **only Loot** (not Shares).
5. **Mint/burn bypass the Loot pause** (`from==0`/`to==0`).
6. **Zodiac clone constructor is dead** — init in `setUp` under `initializer`; init/ownerless the mastercopy.
7. **xALPHA value = LST exchange rate `staked alpha ÷ supply` (stake accounting, NO pool price) × `alphaUSD`
   (subnet AMM TWAP × TAO/USD)** — only the `alphaUSD` leg is a market price (`tickets/bridge/8x-01-szalpha-wrapper-cct.md`).
   Subnet emissions accrue in the exchange rate → in-kind issuance is **full fair-value, NO haircut** (§3.4).
8. **The protocol never reads the szipUSD market price for accounting** (§3.4).
9. **Senior (ERC-7540 queue, §12) ≠ junior (Exit Gate, §5).**
10. **`baal-v3.5` is a decoy; `zodiac-module-reality` is irrelevant.**

---

## 19. One-paragraph orientation for a fresh agent

Zipcode's **szipUSD junior vault** on **Base mainnet (8453)** is a **Baal (Moloch v3) + Zodiac** DAO and a **yield
refinery** whose bet is *harvested yield > IL*: into junior NAV it stacks **xALPHA LM emissions + oHYDX + veHYDX fees
+ the xALPHA LST APR + haircut buy-and-burn accretion + duration-risk xALPHA slash yield** on a zipUSD-lean 70/30 LP
(§10.6); the protocol's lending
spread + arb revenue accrue **separately to the team treasury, not the junior** (§10.7; end-state — M1 keeps lending
yield to the junior). It is **two tokens**:
internal **Baal Loot** (soulbound, held and ragequitted **only by the Exit Gate**, in windows) and the user-facing
**szipUSD** (a **transferable ERC20** the Gate mints 1:1 against that Loot). Issuance is **NAV-proportional and
generalized** — deposit any whitelisted basket asset, valued at the **hybrid TWAP NAV oracle** (§3: xALPHA marked as
LST-exchange-rate × subnet-AMM-USD with only the market leg TWAP'd; entry `max(spot,twap)`, exit `min`), → shares at
the current price (round down, no haircut). The protocol runs **POL-as-liquidity-mining**: it deposits its monthly
xALPHA emissions in-kind for fair-value shares, and the engine pairs them with resting zipUSD into the staked 70/30
ICHI LP to drain HYDX — non-dumpable because the share is windowed-RQ. Patient exit = the Gate's windowed ragequit at
NAV; impatient exit = **sell szipUSD on CoW**; the protocol's **8-B14 buy-and-burn** posts discounted CoW bids and
`burnLoot`s the fills, actualizing haircuts to patient holders. The **freeze** is the structural non-ragequittable
**sidecar**; **loss** is a **pari-passu provision-that-recovers** (junior-vs-senior the only tranche; the "first-loss
floor" is an exit constraint). The **senior** zipUSD exit is a *separate* ERC-7540 queue + the Roles-governed
CreditWarehouse — never conflate. Ground every contract claim in `reference/` via `BAAL-ZODIAC-REFERENCE-MAP.md` and
the xALPHA mark in `tickets/bridge/8x-01-szalpha-wrapper-cct.md`; obey §18.
