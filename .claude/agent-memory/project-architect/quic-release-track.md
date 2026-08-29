---
name: QUIC release track (6.0.0-rc series)
description: The SMB-over-QUIC feature is shipping as a numbered rc series, one OpenSpec change per issue
type: project
---

The SMB-over-QUIC surface is being released as a numbered release-candidate series, one OpenSpec
change per GitHub issue, each reviewed at the `/opsx:propose` gate:

- rc2 = `quic-fail-fast-on-tls-rejection` (issue #59, archived 2026-08-28) — TLS rejection became
  `EPROTO` + `NSOSStatusErrorDomain` underlying error instead of `ETIMEDOUT`.
- rc3 = `add-quic-certificate-probe` (issue #61, proposed 2026-08-29) — capture-only
  `SMBQUICCertificateProbe.fetchServerCertificateChain(server:timeout:)` for trust-on-first-use.

**Why:** the driving consumer is the user's own app **RandomPlayer**; each rc unblocks a concrete
affordance there (rc2: "why did it fail", rc3: "let the user trust this cert"). Interop is validated
against a Windows Server 2022 lab target (`win2k22.kaveman.intra`, self-signed leaf) and a
Samba/private-CA rig; env vars `SMB_QUIC_SERVER`, `SMB_QUIC_CA_DER` (the *lab CA*, not the leaf).

**How to apply:** when reviewing a QUIC change, assume the previous rc's design decisions are
binding constraints (notably: do not re-derive the D7 connect claim/handoff/deadline proofs), and
check that the change carries its own interop-gate tasks — unit tests alone never close a QUIC change.
