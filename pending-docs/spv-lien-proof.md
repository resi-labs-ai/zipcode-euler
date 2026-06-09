# zipcode-euler — SPV & the Proof Attestation Layer (lien · value · insurance)

> The off-chain leg: how the on-chain 1/1 lien token is bound to a **real, legally perfected lien** on a
> home (custodied by an SPV), how its **value** and **insurance** are established, and the **proofs** that
> make all three verifiable before the protocol extends credit. This was the least-defined link in the
> system; it is now a **two-layer model** (§6.1): **authoritative fact-feeds** (county recorder/title, appraiser,
> carrier) supply existence/value/insurance, and **Proof** notarizes that the SPV's lien instrument is genuine +
> ours. Residual trusted leg = the SPV's legal execution on recovery (§5). No emojis. **Status: DEC-01 RESOLVED
> (model decided 2026-06-09) — the business legs (insurance product, SPV, legal) are tracked separately, §6.2/§6.3.**

## 1. Why this exists
The protocol prices and lends against a 1/1 `LienCollateralToken` (`claude-zipcode.md` §4.2). On-chain, the
mint, the price (the oracle equity mark), and the gating are all verifiable. But whether a **real,
enforceable lien** stands behind that token — and what it is worth, and whether it is insured — are
**off-chain facts**. The whole collateral premise, and the "default is a timing problem, recovery pays it
back" thesis (the README Vision), rests on them. This doc is how **Proof** (a notarization service over the SPV's
document set) shrinks that trust to a verifiable attestation.

## 2. The bridge — the Proof family (two layers: fact-feed + Proof wrapper)
- An **SPV** holds the perfected lien off-chain (the legal owner of the claim on the home).
- The on-chain `LienCollateralToken` is the protocol's representation of that lien.
- Each attestation the CRE consumes is **two layers**: an **authoritative fact-feed** (the truth) wrapped by
  **Proof** (genuineness + ownership + integrity of the SPV's *instrument*; identity-verified, tamper-sealed
  x.509 — *not* the truth of the contents). Each is fetched node-mode → identical consensus (§8.1):
  - **Proof of Lien** — *fact:* a **county recorder / title feed** (e.g. Pippin/DART) confirms the lien exists,
    recorded at the expected position against the property — the **anti-fabrication source** (a real lien is in
    the public record; a manufactured one is not). *Proof:* seals that the SPV's lien instrument + assignment is
    genuine and **ours**. Boolean gate before mint.
  - **Proof of Value** — *fact:* the institution-grade origination **appraisal** → the oracle equity mark (NOT
    the Subnet-46 AVM; the subnet is the DON/validation fabric, not the appraiser). *Proof:* seals the appraisal
    document's genuineness.
  - **Proof of Insurance** — *fact:* the **carrier** confirms a policy covers the position. *Proof:* seals the
    binder. A gate at origination + the claim path at recovery.
- Fabrication is further blunted by **KYB'd originators** + **secondaries-first selection** (§5).

## 3. Where it plugs in
- **Origination** (`claude-zipcode.md` §8.1 / §8.5): the CRE workflow fans in the Proof family alongside
  the other underwriting inputs. The controller mints the lien token + opens the line **only if Proof of
  Lien AND Proof of Insurance pass**, priced by Proof of Value. **Critical ordering:** no line is issued
  until the lien is perfected in the SPV — so there is **no uncollateralized-credit path** (an originator
  cannot draw against a lien that does not yet exist).
- **Close/release** (`claude-zipcode.md` §4.4c): burning the token + `LienReleased` signals the SPV to
  release the recorded lien — the proof's inverse.
- **Recovery** (`claude-zipcode.md` §11): on homeowner default the SPV exercises the lien (foreclose /
  force-sale); recovered USD returns via Erebor and repays the loan. HELOCs are often second liens (junior
  to the first mortgage in foreclosure), so recovery may fall short — the **insurance** (Proof of Insurance)
  covers the capital hole, with xALPHA as the last-resort backstop. The SPV is the legal enforcement arm.

## 4. Open questions — now answered
- **Authoritative source of "perfected":** the **county recorder / title feed** for existence + recording
  position (the fact), with **Proof** sealing that the SPV's instrument + assignment is genuine and ours.
- **What each layer attests:** the **fact-feeds** (recorder/title, appraiser, carrier) supply existence /
  value / insurance; **Proof** supplies genuineness + ownership + integrity of the instrument — *not* the truth
  of the contents (the DEC-01 finding, §6.1).
- **Jurisdiction variance:** lien-perfection rules differ by state; the Proof schema generalizes across the
  record types it notarizes (per-jurisdiction as needed).
- **Residual trust:** even with Proof you still trust (a) Proof's notarization integrity and (b) the SPV's
  legal execution on recovery. Proof shrinks (a) to a notarization-service trust; (b) remains a trusted leg,
  mitigated by **secondaries-first selection** — we serve originators already feeding established takeout
  markets, not net-new adverse-selected risk.

## 5. Status & what's left to pin
**ADDRESSED** via the Proof family (lien / value / insurance). The remaining genuinely-trusted leg is the
SPV's legal execution on recovery (foreclosure), softened by serving secondaries-aligned originators. Still
to pin before collateral moves from **mocked → real**:
- the specific **SPV / custody partner** and the exact on-chain ↔ legal handoff (mint authorization tied to
  Proof of Lien; release/burn tied to a verifiable SPV release);
- the **Proof-of-Insurance** policy terms (what is covered, by whom, claim timing — itself a duration leg);
- the per-jurisdiction **Proof schema** and the CRE integration of each Proof endpoint.
This is off-chain/legal + integration work, not a Solidity blocker; `claude-zipcode.md` §15
proof-of-operations runs on mocked Proof inputs until the integrations land. **(These items are formalized as
the DEC-01 clearance checklist in §6.1 — that is the authoritative gate.)**

## 6. Open risks to address (surfaced in the design review — not yet closed)
These are the load-bearing assumptions the design *names but has not verified*. They are off-chain/real-world
risks, and any of them could reshape the protocol if reality says no. Ordered by stakes.

### 6.1 DEC-01 — the Proof capability gate — **RESOLVED (model decided 2026-06-09)**
**Was:** "can Proof attest lien/value/insurance/recovery in a CRE-consumable form?" **Finding (the Proof.com API
was reviewed):** a notarization attests **signer identity + document integrity/execution — NOT the truth of the
contents.** A real, notarized document can still state a false value; the notary doesn't catch that. So Proof
**cannot be the *fact* oracle.** Resolution — a **two-layer model**:

- **Facts = authoritative feeds**, each fetched node-mode → identical consensus (§8.1):
  - **county recorder / title** (e.g. Pippin/DART) — existence + recording position; the **anti-fabrication**
    source (a manufactured lien isn't in the public record);
  - **appraiser / appraisal** — value → `equityMark`;
  - **carrier** — insurance in force;
  - (M2) **recovery receipts** via Erebor — foreclosure/force-sale proceeds.
- **Proof = the integrity / ownership wrapper:** the SPV's lien **instrument + assignment**, identity-verified,
  tamper-sealed (x.509 under Proof's CA). Attests *genuine, executed, unaltered, ours* — not the facts.
- **CRE mechanics (buildable; the binding "CRE-consumable" bar is met by construction):** Proof's API returns a
  sealed PDF behind a **rotating pre-signed URL** (no canonical hash, no signed-JSON, no verify-by-API) → the DON
  **downloads the sealed artifact, hashes it on-node, and verifies the x.509 chain** → identical bytes for
  `ConsensusIdenticalAggregation`. Auth is a shared bearer token → fetched **DON-only via `runtime.GetSecret`**.
  The recorder/appraiser/carrier feeds surface the same per-lien identical-consensus way.
- **Anti-fabrication** (the "manufactured lien" risk): the **recorder/title feed** + **KYB'd originators** +
  **secondaries-first selection** (§5) — not Proof alone.

**Not a build blocker.** CRE-01 builds against **mock Proof + mock feeds** and swaps the real endpoints in as they
integrate (the xALPHA-stand-in pattern). The API→subnet→CRE fetch/zk-verify/aggregate wiring is build-time work on
the CRE-01 / subnet track, not a gate. The reportType surfaces are unchanged (`proofRef` in types 1/2,
`equityMark`, recovery 5/6).

**Still open — their own risks, NOT this gate:** the **insurance product** (§6.2 — may not exist), **legal /
regulatory** (§6.3), and pinning the **actual vendors** (recorder/title, appraisal, carrier, the SPV/custody
partner + the verifiable-release handoff). These gate *live, real-collateral* origination + the M2 loss side;
they do not block the M1 build or the proof-of-operations (which runs on mocks, `claude-zipcode.md §15`).

**Residual trust (irreducible, even now):** Proof's own notarization integrity + the **SPV's legal execution on
recovery** — mitigated, not eliminated, by secondaries-first selection.

### 6.2 Insurance — no carrier, no product, no terms
We made **off-chain insurance the PRIMARY capital backstop for the senior** (junior → insurance → xALPHA). But
insurance covering **second-lien HELOC default losses** is not a standard product. There is currently no
carrier, no policy terms, no premium, no claim-timing.
- **To do:** determine whether such coverage exists (mortgage/credit/lien insurance, surety, or a captive);
  pin **what it covers** (homeowner default? second-lien wipeout in foreclosure?), the **premium cost** (it
  eats the spread — feed into the unit-economics model), and **claim timing** (itself a duration leg, §11).
- **If it doesn't exist as a product:** the capital stack reverts to junior + recovery + xALPHA-sale, and the
  "senior is safe" story weakens — re-decide the backstop ordering.

### 6.3 Legal / regulatory — unscoped, possibly the actual gate
Lending against **US home equity**, an **SPV** holding liens, **KYB'd** originators, a securities-ish token
(**xALPHA**), and **locking depositor capital** (the **Duration Bond**) is a large legal surface that the
design has touched zero. This may gate launch more than the Solidity.
- **To do:** scope (a) **lending licensing** (state-by-state for home-equity credit / warehouse), (b) a
  **securities analysis** of xALPHA, szipUSD, and the Duration Bond (locked yield instrument), (c) the **SPV**
  legal structure + jurisdiction, (d) **KYB/AML** obligations, (e) **consumer-lending law** on the underlying
  HELOCs. Get counsel before mainnet.

### 6.4 Liquidation of a 1/1 lien (M1) — no real path
`claude-zipcode.md` §4.4e says "controller is the only liquidator; MBS absorption deferred." So **M1 has no
concrete liquidation mechanism** — on default a line simply accrues and waits for off-chain recovery. The
real "liquidation" of a home-equity lien *is* the off-chain path (SPV forecloses / force-sells → recovery via
Erebor → repay → close), so it belongs here, not in an on-chain liquidator market.
- **To do:** spec the M1 default→resolution path explicitly as the **off-chain SPV recovery loop**, and
  decide whether any on-chain `liquidate` is exercised in M1 at all (or whether default is purely
  delinquency-mark → SPV recovery → permissionless repay → controller close).
