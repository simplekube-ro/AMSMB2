---
name: patterns-quic-interop-batch-d
description: SMB-over-QUIC live interop (add-quic-transport Batch D) — Apple↔lxin/quic active_connection_id_limit incompat, rig DKMS patch, docker-proxy caveat, env-gated interop tests
metadata:
  type: project
---

# SMB-over-QUIC live interop (add-quic-transport Batch D, tasks 4.1–4.4)

`AMSMB2Tests/SMB2QUICInteropTests.swift` — 14 live tests, `#if canImport(Network)`, env-gated on
`SMB_QUIC_SERVER` (also SMB_QUIC_SHARE/USER/PASSWORD/CA_DER); skip cleanly with no env (suite stays
green). Run per-test or small `--filter` batches, NOT all 14 at once (docker-proxy caveat below).
`docs/INTEROP-QUIC.md` = repeatable procedure + 5 traps + results.

## Headline finding: Apple NWProtocolQUIC ↔ lxin/quic incompatibility (RFC 9000 §18.2)
Apple's `NWProtocolQUIC` advertises QUIC transport param `active_connection_id_limit = 64`.
lxin/quic (`quic.ko`, through HEAD 03a9c7c) rejects any value `> 8` with `-EINVAL` →
`CONNECTION_CLOSE(TRANSPORT_PARAMETER_ERROR(8))` right after ACKing the client Initial, before any
ServerHello. Server-side symptom: `tstream_tls_quic_handshake: NT_STATUS_INTERNAL_ERROR` (GnuTLS
logs nothing — killed below TLS). Client symptom: connect hangs to the connect deadline →
`POSIXError(.ETIMEDOUT)` "…last waiting error: Socket is not connected". RFC violation: the value is
the peer's storage willingness; only `< 2` is invalid, larger MUST be accepted. **No client-side
remedy** — NWProtocolQUIC doesn't expose the param.

### 3-stack discriminator technique (how to prove client vs server)
Point a THIRD QUIC stack at the same server. Host had OpenSSL 3.5.5 (has a QUIC client):
`openssl s_client -quic -alpn smb -connect host:443 -CAfile ca.crt`. OpenSSL (advertises
active_connection_id_limit=2) CONNECTED; Apple failed → server works, Apple client is the delta.
Refuted red herrings via decrypted-Initial diff: both Apple & OpenSSL fragment ClientHello across
2 Initials and both use zero-length SCID — neither is the cause; the delta was the CID limit (64 vs 2).

### Rig fix (server-side DKMS patch — authorized reversible rig change)
`/usr/src/quic-*/modules/net/quic/frame.c`, ACTIVE_CONNECTION_ID_LIMIT case (~:3328): keep
`if (value < QUIC_CONN_ID_LEAST) return -EINVAL;`, replace the `> QUIC_CONN_ID_LIMIT` reject with
`if (value > QUIC_CONN_ID_LIMIT) value = QUIC_CONN_ID_LIMIT;` (QUIC_CONN_ID_LIMIT=8 in connid.h; it
caps CIDs WE issue, so clamping the stored copy is safe). Then:
`sudo cp frame.c frame.c.bak-interop` → `sudo dkms build --force quic/<ver> -k $(uname -r)` →
`dkms install --force` → `docker stop samba-quic` → `sudo rmmod quic && sudo modprobe quic` →
`docker start samba-quic` → verify (QUIC-drop 0 in log.smbd + loopback smbclient lists hello.txt).
Upstream unpatched → issue draft in change scratchpad `lxin-quic-issue-draft.md`. Post-patch:
first-contact + full matrix pass; D2 4-byte framing CONFIRMED (SMB2 PDUs parse over the QUIC stream).

## docker userland UDP-proxy caveat (rig test-infra, NOT an SMB/QUIC bug)
Rig publishes QUIC via `-p 443:443/udp` = userland `docker-proxy`. Under a sustained QUIC
connect/disconnect burst (whole 14-test suite back-to-back, amplified by negative tests flooding
UDP to a non-listener + 30s-timeout pileup) the proxy WEDGES for new LAN flows → all new `.quic`
connects hang to ETIMEDOUT, while server-side loopback smbclient (bypasses proxy) stays healthy and
log.smbd shows the same INTERNAL_ERROR. Recovery: `docker restart samba-quic`. Fresh proxy handles
~7+ consecutive sessions; run tests in small batches. Real fix: `--network host` or kernel-NAT UDP
publish. This is why a full-suite run showed 10 fails but every test passes individually.

## Rig ops notes
- ssh `ubuntu-brix.kaveman.intra` has passwordless sudo + tcpdump (host & container); tshark now
  installed on the host. Rolling captures: team lead keeps /tmp/amsmb2-*.pcap (root-owned).
- Raise Samba TLS debug: edit `~/smb-quic-rig/smb.conf` `log level = 3 tls:10`, `docker restart` —
  but GnuTLS emits nothing when the kernel QUIC layer kills the connection pre-TLS (the TP-reject
  case). Health check: `grep -c "ignore listening on transport quic" /opt/samba/var/log.smbd`==0.
- QUIC pkt decode from tcpdump hex: long header first byte `0xc?` = Initial, next 4 bytes = version
  (00000001 = v1); Length is a varint after token-len (0x44xx = 2-byte varint). Two same-DCID
  Initials µs apart w/ different payloads = split ClientHello, not retransmits.
- Snapshot/restore discipline for every rig file touched: `cp X X.bak-interop`, restore + re-verify
  server-side smbclient health when done. Left retained: frame.c.bak-interop, README.md.bak-interop.

## Interop test specifics
- md5 via `import CryptoKit` (Insecure.MD5). Demo reference file baked (rig-specific, env-overridable):
  //demo `Documentary/iss-earth.mp4`, 4591054 B, md5 ed7a9569933dcf5af07f2e60fa4e7256.
- Trust matrix live: customRoots([labCA-DER]) correct FQDN + SAN short name `ubuntu-brix` → success;
  `.system` → rejects lab cert (system-trust enforced); `.insecureNoVerification` → success;
  unrelated runtime-openssl anchor → rejected. Wrong-hostname case is manual-only (can't make a
  resolvable non-SAN name w/o editing DNS) — unit `evaluateCustomRootsTrust` already proves it.
- CA→DER once: `openssl x509 -in ca.crt -outform DER -out ca.der`.
