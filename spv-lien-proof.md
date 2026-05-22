# zipcode-euler — SPV & Lien-Perfection Proof (open)

> The trusted off-chain leg: how the on-chain 1/1 lien token is bound to a **real, legally perfected
> lien** on a home (custodied by an SPV), and the **proof** that the lien exists and is enforceable
> before the protocol treats the token as collateral. This is the **least-defined link** in the system
> and the gating dependency for non-mocked collateral. **Status: OPEN.** No emojis.

## 1. Why this exists
The protocol prices and lends against a 1/1 `LienCollateralToken` (`claude-zipcode.md` §3.2). On-chain,
the mint, the price (the oracle equity mark), and the gating are all verifiable. But whether a **real,
enforceable lien** stands behind that token is an **off-chain legal fact** — and nothing on-chain proves
it today. The whole collateral premise — and the "default is a timing problem, recovery pays it back"
thesis (`risk-vision.md`) — rests on it. `claude-zipcode.md` §9 lists SPV legal custody/enforceability as
an explicit **trusted** assumption; this doc is the plan to shrink that trust with a proof.

## 2. The bridge
- An **SPV** holds the perfected lien off-chain (the legal owner of the claim on the home).
- The on-chain `LienCollateralToken` is the protocol's representation of that lien.
- A **lien-perfected proof** ties the two: an attestation that the lien is recorded at the expected
  position against the expected property, consumed by the CRE underwriting workflow as a gate before mint.

## 3. Where it plugs in
- **Origination** (`claude-zipcode.md` §4.1 / §5): the underwriting workflow already fans in
  Reclaim/EigenLayer zkTLS proofs (identity, title, lien position). Add a **"lien-perfected" boolean
  gate** to that set — the controller mints the lien token + opens the line only if the proof passes.
- **Close/release** (`claude-zipcode.md` §3.4c): burning the token + `LienReleased` signals the SPV to
  release the recorded lien — the proof's inverse.
- **Recovery** (`tokenomics-layer.md` §5): on default the SPV exercises the lien (foreclose / force-sale);
  the recovered USD returns via Erebor and repays the loan (the recovery loop). The SPV is the legal
  enforcement arm that makes "recovery" real.

## 4. Open questions
- **Authoritative source of "perfected":** county recorder confirmation? a title insurer's binder? the
  SPV's own attestation? Each differs in trust and provability.
- **What the Reclaim proof attests:** a recording reference + lien position, a title-insurance policy, or
  a signed SPV statement — and how zkTLS reaches that source.
- **SPV custody partner** and the exact on-chain ↔ legal handoff (mint authorization tied to the proof;
  release/burn tied to a verifiable SPV release).
- **Jurisdiction variance:** lien-perfection rules differ by state; the proof schema must generalize or be
  per-jurisdiction.
- **Residual trust:** even with the proof you still trust (a) the proof's source and (b) the SPV's legal
  execution on recovery. The proof shrinks (a); (b) remains a trusted leg.

## 5. Status
OPEN — the proof schema does not exist yet. Until it does, collateral is mocked (`claude-zipcode.md` §11
proof-of-operations uses mocked proof inputs). This is off-chain/legal work, not a Solidity blocker, but
it is the prerequisite for real collateral and the **one remaining open thread** from the design review.
