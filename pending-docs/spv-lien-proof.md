# zipcode-euler — SPV & the Proof Attestation Layer (lien · value · insurance)

> The off-chain leg: how the on-chain 1/1 lien token is bound to a **real, legally perfected lien** on a
> home (custodied by an SPV), how its **value** and **insurance** are established, and the **proofs** that
> make all three verifiable before the protocol extends credit. This was the least-defined link in the
> system; it is now **addressed by a notarization service ("Proof")**, with one residual trusted leg — the
> SPV's legal execution on recovery (§5). No emojis. **Status: ADDRESSED via Proof — residual trust noted.**

## 1. Why this exists
The protocol prices and lends against a 1/1 `LienCollateralToken` (`claude-zipcode.md` §4.2). On-chain, the
mint, the price (the oracle equity mark), and the gating are all verifiable. But whether a **real,
enforceable lien** stands behind that token — and what it is worth, and whether it is insured — are
**off-chain facts**. The whole collateral premise, and the "default is a timing problem, recovery pays it
back" thesis (`vision.md`), rests on them. This doc is how **Proof** (a notarization service over the SPV's
document set) shrinks that trust to a verifiable attestation.

## 2. The bridge — the Proof family
- An **SPV** holds the perfected lien off-chain (the legal owner of the claim on the home).
- The on-chain `LienCollateralToken` is the protocol's representation of that lien.
- **Proof** (a notarization API) attests, over the SPV's documents, a **family** of facts the CRE
  underwriting workflow consumes as gates/values before a line is opened:
  - **Proof of Lien** — the lien exists, is recorded at the expected position against the expected
    property, and the protocol (via the SPV) **owns / has valid claim** to it. Boolean gate before mint.
  - **Proof of Value** — the institution-grade origination appraisal (the value the loan was underwritten
    on), surfaced from the document set → the oracle equity mark. (This replaces the aspirational Subnet 46
    AVM as the valuation source; the Zipcode subnet's role is the DON/validation fabric, not the appraiser.)
  - **Proof of Insurance** — an off-chain insurance policy covers the position. A **gate at origination**
    (don't lend without it) and the **claim path at recovery** (covers the foreclosure shortfall).

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
- **Authoritative source of "perfected":** the **Proof notarization service**, attesting over the SPV's
  recorded documents (it notarizes whichever record applies — recorder reference, title binder, SPV
  statement — rather than us choosing one upfront).
- **What the proof attests:** lien existence + recording position + ownership/claim (Proof of Lien); the
  appraised value (Proof of Value); insurance coverage (Proof of Insurance).
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

### 6.1 DEC-01 — the Proof capability gate (the one external dependency the off-chain half rests on)
**Status: UNCONFIRMED.** We *assert* a notarization service ("Proof") can attest the collateral facts; we
have **not** confirmed it can. DEC-01 is that confirmation. It gates three tracks — **CRE** (live origination,
`claude-zipcode.md §8.9`), the **subnet** (Proof-family fetch + zk-verify, §8.10), and **M2-loss** (recovery
oracles) — and until it clears, all three build against **mock Proof inputs** (the contracts already test
against mock reports, so this is not a Solidity blocker; `claude-zipcode.md §15` runs on mocks).

**The binding constraint — "CRE-consumable form."** It is not enough that Proof *knows* a fact; the CRE
workflow must be able to fetch it in a way the DON can agree on. Per `claude-zipcode.md §8.1`, each attestation
must be:
- **Per-lien** — a discrete response keyed to one lien, not a portfolio score.
- **zkTLS-provable** — fetched in node mode (`http.Client.SendRequest`) and verified at the subnet/node layer
  (Reclaim/EigenLayer or subnet-native), so raw PII never enters consensus; only the proof / derived bound does
  (`runtime.GetSecret` is DON-only).
- **Identical-consensus-able** — because the value is a notarized *fact* (one appraisal), the DON aggregates
  with `ConsensusIdenticalAggregation` (`reference/cre-sdk-go/cre/consensus_aggregators.go:33`), **not** a
  median. Every node must fetch the **same bytes** — so Proof's response must be **deterministic and signed**, not
  a freshly-timestamped or non-reproducible payload. A fuzzy/streaming/clock-stamped API breaks identical
  consensus and would force a redesign of the aggregation model.

**The attestation family — what each is, how CRE consumes it, where it surfaces, and the fallback if Proof can't.**

| Attestation | Asserts | CRE form | On-chain surface (`§8.0`) | Status | Fallback if Proof can't |
|---|---|---|---|---|---|
| **Proof of Lien** | lien exists + recorded position + SPV owns/has valid claim | identical-consensus **boolean gate** | precondition only; `proofRef` commitment in origination/draw (types 1/2). No gate → no report → no mint | UNCONFIRMED | a different recorder/title feed per jurisdiction; without it there is **no mint path** (hard block, no graceful degrade) |
| **Proof of Value** | the institution-grade origination appraisal (home value − senior debt) | identical-consensus **value** → `equityMark` | `equityMark` in types 1/2 + revaluation type 3 (→registry, §8.1) | UNCONFIRMED | a separate appraisal/AVM feed surfaced through the same identical-consensus path; the conservatism then lives in the LTV gap (§4.2), not the mark |
| **Proof of Insurance** | a policy covers the position | identical-consensus **boolean gate** + a coverage figure | precondition at origination; coverage figure at recovery feeds the §11 waterfall | UNCONFIRMED + **no product** (see §6.2) | direct-from-carrier attestation — but the product itself may not exist; if so, re-decide the backstop stack (§6.2) |
| **Recovery milestones** (M2) | default status + foreclosure/force-sale proceeds | DON-signed status/recovery report | type 5/6 → controller; `recoveryProceeds` → `DefaultCoordinator` (M2) | UNCONFIRMED | manual/oracle-attested recovery receipts via Erebor; gates M2-loss only, not M1 origination |

**The DEC-01 clearance checklist (what concretely closes the gate):**
1. Obtain Proof's **actual API spec**; confirm each row above is producible as a **per-lien, signed,
   deterministic, zkTLS-provable** response (the identical-consensus bar above).
2. For each field Proof **cannot** do, pin the named fallback feed (column 6) and confirm it meets the same bar.
3. Resolve the **insurance product** question (§6.2) — or re-decide the backstop ordering if no product exists.
4. Pin the **SPV / custody partner** and the on-chain↔legal handoff: mint authorization tied to Proof of Lien;
   release/`burn` tied to a **verifiable SPV release** (§3, `claude-zipcode.md §4.4c`).
5. Author the **per-jurisdiction Proof schema** + the **CRE integration of each endpoint** (the per-endpoint
   fetch/zk-verify/aggregate wiring that becomes part of CRE-01 / the subnet track).

**What DEC-01 does NOT remove (residual trust, even when cleared):** (a) Proof's own notarization integrity
(shrunk to a notarization-service trust, not eliminated); (b) the **SPV's legal execution on recovery**
(irreducibly trusted, mitigated only by **secondaries-first** originator selection, §5/§4). These are noted, not
closed by DEC-01.

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
