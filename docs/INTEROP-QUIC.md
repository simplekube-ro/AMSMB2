# SMB-over-QUIC interop procedure (AMSMB2 `add-quic-transport`)

This is the repeatable procedure for verifying AMSMB2's `.quic` transport against a live
SMB-over-QUIC server. The reference server is **Samba 4.23+** with the lxin/quic kernel module
(`quic.ko`); Windows Server 2025 is the other conformant target (deferred until a Windows host is
available — see the design's Open Questions).

> **Lab-only.** The rig below uses lab credentials and a private CA. Do not reuse them outside the
> lab.

## Reference rig

Standing rig verified 2026-07-24 on `ubuntu-brix.kaveman.intra` (Ubuntu 26.04, kernel 7.0):

- **Host**: `quic.ko` via DKMS (`dkms status quic`), loaded at boot
  (`/etc/modules-load.d/quic.conf`). Source: github.com/lxin/quic; DKMS rebuilds on kernel
  upgrade. Requires a kernel ≥ 6.1 (verified on 7.0).
- **Container**: `samba-quic:4.23.6` (Samba 4.23.6 + libquic, lxin/quic "samba" branch). Rig dir
  `~/smb-quic-rig/` (Dockerfile, entrypoint.sh, smb.conf, tls/, share).

  ```
  docker run -d --name samba-quic --restart unless-stopped --network host \
    -v $HOME/smb-quic-rig:/rig-src:ro -v /home/kman/demo:/demo:ro samba-quic:4.23.6
  ```

  Use `--network host` (not `-p 443:443/udp`) so the QUIC listener binds host UDP/443 directly —
  the userland `docker-proxy` wedges under sustained QUIC load (see trap #5).

- **TLS**: lab CA (`~/smb-quic-rig/tls/ca.crt`, CN="AMSMB2 QUIC Lab CA") + server cert with SANs
  `ubuntu-brix.kaveman.intra`, `ubuntu-brix`, `localhost`. The CA (DER-converted) is the trust
  anchor for `SMBQUICConfiguration.customRoots`.
- **Credentials**: `smbtest` / `quictest1`. Shares: `//host/share` (writable),
  `//host/demo` (read-only real media).

### Server health check

Healthy start = **no** `ignore listening on transport quic` line in the container's
`/opt/samba/var/log.smbd`. That warning means the QUIC listener was dropped (see trap #2) and smbd
is serving TCP only. `ss(8)` cannot list `IPPROTO_QUIC` sockets — verify with a client connect or
`tcpdump udp port 443`.

Server-side loopback sanity:

```
docker exec samba-quic /opt/samba/bin/smbclient //localhost/share \
  -U smbtest%quictest1 -s /rig/smb.conf \
  --option="client smb transports=quic" \
  --option="tls verify peer = ca_and_name" -c ls
```

## Running the AMSMB2 interop tests

The live tests live in `AMSMB2Tests/SMB2QUICInteropTests.swift`. They **skip cleanly** unless
`SMB_QUIC_SERVER` is set, so CI (no env) is unaffected.

```
SMB_QUIC_SERVER=ubuntu-brix.kaveman.intra \
SMB_QUIC_SHARE=share \
SMB_QUIC_USER=smbtest \
SMB_QUIC_PASSWORD=quictest1 \
SMB_QUIC_CA_DER=/path/to/ca.der \
  swift test --disable-sandbox --filter SMB2QUICInteropTests
```

Convert the lab CA to DER once: `openssl x509 -in ca.crt -outform DER -out ca.der`.

Coverage: first-contact NEGOTIATE (the D2 framing proof), NTLM auth + share enumeration, directory
listing, 8 MiB write/read round-trip (md5), real-media read from `//demo` verified against a
server-side md5, cancel-mid-transfer, best-effort disconnect, numeric-target rejection,
QUIC-only failure mode (no TCP fallback), and the live TLS trust matrix (custom root correct/short
hostname, `.system` rejection of the lab cert, `.insecureNoVerification`, unrelated-anchor
rejection). The wrong-hostname trust case is **manual-only** here (producing a resolvable non-SAN
name for the rig without editing system DNS is out of scope); the unit suite already proves
wrong-host rejection in `evaluateCustomRootsTrust`.

## Traps

1. **libquic version `.pc` patch** — Samba requires `libquic >= 1.1`, but upstream's `.pc` reports
   `1.0`; without patching the installed `.pc` to `1.1`, Samba's `configure` silently disables
   QUIC. (Build the lxin/quic "samba" branch and patch the `.pc`.)
2. **TLS key uid/permissions** — the TLS private key must be uid-0 / mode 0600, or smbd drops the
   QUIC listener with only a warning (see health check) and serves TCP only.
3. **`ss(8)` blindness** — `ss` cannot list `IPPROTO_QUIC` sockets. Health-check with a client
   connect or `tcpdump udp port 443`. `smbclient` default TLS verification demands a CRL; use
   `tls verify peer = ca_and_name` with the lab CA. Clients must target a **DNS name**, not an IP
   (matches AMSMB2's numeric-host rejection policy).
4. **lxin/quic rejects Apple's `active_connection_id_limit` (server-side kernel patch required
   until upstreamed)** — Apple's Network.framework QUIC (`NWProtocolQUIC`) advertises the QUIC
   transport parameter `active_connection_id_limit = 64`. lxin/quic (through at least HEAD
   `03a9c7c`) rejects any value `> 8` with `-EINVAL`, closing the handshake with
   `CONNECTION_CLOSE(TRANSPORT_PARAMETER_ERROR)` before any ServerHello — surfacing server-side as
   `tstream_tls_quic_handshake: NT_STATUS_INTERNAL_ERROR`. This violates RFC 9000 §18.2 (the value
   is the peer's storage willingness; only `< 2` is invalid — larger values MUST be accepted).
   OpenSSL's QUIC client (advertises `2`) and Samba's own client are unaffected, so same-stack
   testing never exercised it.

   **Symptom from the AMSMB2 side**: `.quic` connect hangs to the connect deadline and throws
   `POSIXError(.ETIMEDOUT)` ("QUIC connect timed out … last waiting error: Socket is not
   connected"). Reproduces regardless of trust policy (including `.insecureNoVerification`).

   **There is no client-side remedy** — `NWProtocolQUIC` does not expose the connection-ID limit.
   The rig fix is a one-line clamp in the kernel module. On the rig, in
   `/usr/src/quic-<ver>/modules/net/quic/frame.c`, the
   `QUIC_TRANSPORT_PARAM_ACTIVE_CONNECTION_ID_LIMIT` case (near `frame.c:3328`):

   ```c
   /* before: rejects RFC-legal large values */
   if (value < QUIC_CONN_ID_LEAST || value > QUIC_CONN_ID_LIMIT)
       return -EINVAL;
   params->active_connection_id_limit = value;

   /* after: keep the < LEAST reject, clamp large values (RFC 9000 §18.2) */
   if (value < QUIC_CONN_ID_LEAST)
       return -EINVAL;
   if (value > QUIC_CONN_ID_LIMIT)
       value = QUIC_CONN_ID_LIMIT;
   params->active_connection_id_limit = value;
   ```

   `QUIC_CONN_ID_LIMIT` (== 8) is the module's own cap on connection IDs it will *issue*; clamping
   the stored value is safe.

   **Fixed upstream (2026-07-25).** This clamp was merged into lxin/quic master as commit
   `47ca73f` — our PR [lxin/quic#78](https://github.com/lxin/quic/pull/78) for issue
   [#77](https://github.com/lxin/quic/issues/77) (fork `simplekube-ro/quic`, commit `08dbf11`).
   **Rigs built from lxin/quic ≥ `47ca73f` need no local patch.** This rig was updated to pure
   upstream master (`quic/1.0+git47ca73f`) on 2026-07-25 and re-verified 14/14 (26 s) against the
   interop suite; the previously-patched `quic/1.0+git0d750a4` tree is kept registered in DKMS as a
   rollback. The manual patch and rebuild below are retained only for reference, or for building a
   tree that predates the fix.

   To patch a pre-`47ca73f` tree, apply the change, then rebuild + hot-swap the module:

   ```
   sudo cp frame.c frame.c.bak-interop          # snapshot before editing
   sudo dkms build  --force quic/<ver> -k $(uname -r)
   sudo dkms install --force quic/<ver> -k $(uname -r)
   docker stop samba-quic
   sudo rmmod quic && sudo modprobe quic        # load the patched module
   docker start samba-quic                       # re-verify health afterwards
   ```

   **DKMS gotcha when building from upstream master:** upstream's autotools build exposes no
   top-level `all` target for the kernel module, so a DKMS tree built from upstream (e.g.
   `quic/1.0+git47ca73f`) needs the slim kernel-module `Makefile` copied from the older
   `0d750a4` DKMS tree's `modules/net/quic/` before `dkms build` will succeed.

5. **Use host networking, not the docker userland UDP proxy** — publishing QUIC with
   `-p 443:443/udp` uses docker's **userland** `docker-proxy` for UDP, which wedges for new LAN
   flows under a sustained QUIC connect/disconnect burst (e.g. the whole 14-test suite
   back-to-back): new `.quic` connects then hang to the connect deadline and throw
   `POSIXError(.ETIMEDOUT)`, while server-side loopback `smbclient` (which bypasses the proxy)
   keeps working and `log.smbd` shows `tstream_tls_quic_handshake: NT_STATUS_INTERNAL_ERROR`. It is
   a rig networking artifact, not an SMB/QUIC problem (recover with `docker restart samba-quic`).

   **Resolution (rig now runs this way):** start the container with `--network host` instead of
   `-p 443:443/udp` — the QUIC listener binds host UDP/443 directly, dropping the userland proxy
   entirely:

   ```
   docker run -d --name samba-quic --restart unless-stopped --network host \
     -v $HOME/smb-quic-rig:/rig-src:ro -v /home/kman/demo:/demo:ro samba-quic:4.23.6
   ```

   With host networking the full `SMB2QUICInteropTests` suite runs stably in a single pass. (If
   host UDP/443 is otherwise occupied on a given box, fall back to the userland proxy and drive
   the suite in small `--filter` batches — a fresh proxy handles ~7+ consecutive sessions.)

## Interop results (verified 2026-07-24, patched rig)

Against `ubuntu-brix.kaveman.intra` (Samba 4.23.6 + patched `quic.ko`), macOS client, all
`SMB2QUICInteropTests` pass: first-contact NEGOTIATE, NTLM share enumeration, directory listing,
8 MiB write/read (md5 identical), 4.59 MB real-media read (md5 == server), cancel-mid-transfer,
best-effort disconnect, numeric-target rejection (EINVAL), QUIC-only failure mode (no TCP
fallback), and the TLS trust matrix (custom root correct + SAN short name → success; `.system`
→ rejects the lab cert; `.insecureNoVerification` → success; unrelated anchor → rejected).

- **D2 4-byte framing: confirmed.** Multiple SMB2 operations (NEGOTIATE, tree connect, directory
  enumeration, multi-MB reads/writes) parse cleanly through libsmb2's direct-transport byte-stream
  reader over the QUIC stream — a framing mismatch could not parse. The tunnel carries
  length-prefixed SMB2 verbatim; no fork-seam frame-stripping is needed.
- **No premature idle teardown / keepalive tuning needed.** Multi-MB transfers and interleaved
  connect/op/disconnect cycles complete within `NWProtocolQUIC` defaults; the connect deadline
  (`SMBQUICConfiguration.connectTimeout`) and libsmb2's servicing timers govern the rest.
- **TLS trust rejection: RESOLVED — it now fails fast with `EPROTO`.** Network.framework still
  reports a verify-failed QUIC handshake (`.system` against the lab cert, or `.customRoots` with an
  unrelated anchor) as the *non-terminal* `.waiting(.tls(status))` rather than `.failed`, so it
  originally waited out `connectTimeout` and surfaced as `POSIXError(.ETIMEDOUT)` —
  indistinguishable by code from an unreachable server. The transport now classifies `.waiting` at
  the connection-driver seam: a `.tls` wait is **fatal** and claims the connect outcome immediately,
  every other wait stays transient and deadline-bounded. A trust rejection is therefore
  `POSIXError(.EPROTO)`, reported as soon as the handshake fails, carrying the Security `OSStatus`
  as an `NSOSStatusErrorDomain` `NSError` under `userInfo[NSUnderlyingErrorKey]`. `ETIMEDOUT` from
  a QUIC connect now means "endpoint unreachable/unresponsive" — or a `connectTimeout` shorter
  than the handshake itself, in which case the deadline still wins. The interop rejection tests
  still run a known-good reachability control first, so a down rig skips rather than reporting an
  unrelated connect error.
- The wrong-hostname trust case is manual-only (see the test-run section); the unit suite proves
  it in `evaluateCustomRootsTrust`.

### Windows Server 2022 (2026-08-28)

Second interop target: `win2k22.kaveman.intra`, share `Share`, SMB-over-QUIC with a **self-signed**
server certificate (the leaf is its own anchor).

- `.customRoots([leaf .cer])` and `.insecureNoVerification` connect successfully; `.system` is
  rejected with Security status `-9808` (`errSSLBadCert`), since a self-signed leaf chains to no
  system root.
- Throughput: a 1.1 GB read completes at ~34 MB/s over QUIC versus ~38 MB/s over TCP against the
  same host, with identical MD5 — QUIC is within ~10% of TCP, and the payload round-trips byte-exact.

Live trust matrix after the fail-fast change (scratch harness against the same host, credentials
`testuser`, the server's own `.cer` fetched from the share as the `.customRoots` anchor):

| Policy | Outcome |
|---|---|
| `.system` | rejected in **0.20 s** (was: full `connectTimeout`) — `POSIXError(.EPROTO)` (errno 100), description `QUIC TLS error: -9808: bad certificate format`, `userInfo[NSUnderlyingErrorKey]` = `NSOSStatusErrorDomain -9808` |
| `.customRoots([server .cer])` | connected in 0.06 s, directory listing OK |
| `.insecureNoVerification` | connected in 0.07 s; 1.1 GB read in 33.1 s (33.4 MB/s), MD5 `4e63a5b7cec8a34f9dfb938f755b5dfe` |
| `.tcp` (control) | connected in 0.15 s; same file in 31.1 s (35.5 MB/s), identical MD5 |

The certificate is self-signed (`CN=win2k22.kaveman.intra`, SAN `DNS:win2k22.kaveman.intra,
DNS:192.168.20.164`), so `.customRoots` uses the leaf itself as the sole anchor.

The interop suite itself also runs against this host (`SMB_QUIC_SERVER=win2k22.kaveman.intra
SMB_QUIC_SHARE=Share SMB_QUIC_CA_DER=<the server .cer>`): `testTrustSystemRejectsLabCert` and
`testTrustUnrelatedAnchorRejected` pass with `EPROTO` / `-9808` surfacing in 0.018 s and 0.013 s;
`testTrustCustomRootCorrectHostSucceeds` and `testTrustInsecureSucceeds` pass.
`testTrustCustomRootShortNameSucceeds` is Samba-rig-specific (its default short name is
`ubuntu-brix`, and this certificate's SAN carries no short name) — dialling that unreachable name
still produces the transient-wait `ETIMEDOUT`, i.e. an unreachable host and a trust rejection
are now different codes on a real server.

### D8 disconnect / server-close observations (2026-07-24)

Captured by the opt-in observation tests (`SMB_QUIC_OBSERVE=1`,
`testObserveDisconnectServerTeardown` / `testObserveServerInitiatedClose`, which self-coordinate
with the rig over ssh `smbstatus`):

- **Best-effort local disconnect → server-side teardown observed.** After `disconnectShare()`, the
  server's `smbstatus` still showed the session briefly, then reaped it — observed teardown latency
  **≈ 2.2 s**. Consistent with D8: the local disconnect is best-effort (the DISCONNECT PDU may not
  reach the wire before seam teardown), and the server independently reaps the idle session shortly
  after. Not a guaranteed-DISCONNECT-delivery guarantee — a best-effort observation.
- **Server-initiated close → our client surfaces `POSIXError(.ENOTCONN)`.** Restarting the server
  mid-session (SIGTERM to smbd), the client's next operation failed with
  `POSIXError(.ENOTCONN)` ("SMB2 server not connected") — libsmb2's mapping of the closed QUIC
  connection. No hang, no crash; the failure is surfaced promptly and cleanly.

## Real-media share

`//host/demo` — read-only bind mount of real media. `Documentary/iss-earth.mp4` (4,591,054 bytes,
md5 `ed7a9569933dcf5af07f2e60fa4e7256`) is the reference file for the large-read integrity test.
`smb.conf` `force user = ubuntu` maps SMB access to uid 1000 to match host ownership.
