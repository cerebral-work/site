# LDAP + Kerberos — research for reverie mesh auth

Status: research (2026-04-08, control-room lane)
Source: background research subagent + control-room synthesis
Cross-refs: `docs/architecture/pseudoagents.md`, Part H env-map

## TL;DR

- **Now**: do nothing. Reverie is single-user + localhost. No auth layer is needed.
- **When multi-host** (GPU workers on remote boxes, coord bridge across machines): mTLS with an internal CA via `rustls` + `rcgen`. Pure Rust, 1–2 weeks, scales well.
- **When multi-user + audit/compliance**: FreeIPA (Kerberos + LDAP + DNS bundled). 3–4 weeks, moderate maintenance, only worth it if the team already runs AD or has compliance requirements forcing it.

## Part 1 — Background

### LDAP (RFC 4511)
- Directory protocol, **not** an auth protocol. Stores hierarchical entries (Distinguished Names → attributes).
- Canonical schemas: inetOrgPerson, posixAccount, posixGroup.
- Three major implementations:
  - **OpenLDAP** — lightweight, C daemon, sysadmin-friendly, minimal web UI.
  - **389 Directory Server** — enterprise-grade, Red Hat lineage, rich replication.
  - **FreeIPA** — bundles 389 DS + MIT Kerberos + BIND DNS + Dogtag CA + NTP into a turnkey identity suite. What most "LDAP + Kerberos" installations actually run today.

### Kerberos (RFC 4120)
- Ticket-based auth for untrusted networks. Single sign-on via a trusted Key Distribution Center (KDC).
- Principals (`user@REALM`, `HTTP/host.example.com@REALM`), keytabs, service principal names (SPNs), cross-realm trust.
- **MIT Kerberos** is the de-facto standard on Linux. **Heimdal** is the BSD-licensed alternative with a simpler API surface.

### How they compose
LDAP is the **identity store**. Kerberos is the **auth protocol**. SASL/GSSAPI is the glue: a client binds to LDAP with a Kerberos ticket, no password crosses the wire. FreeIPA packages all three plus a CA so you can issue X.509 certs from the same identity database.

## Part 2 — Modern context (2025–2026)

- **OIDC / OAuth2 won for new projects.** Web / cloud / mobile / SaaS all consolidated on bearer tokens + JWKS.
- **LDAP + Kerberos persists in**:
  - Windows AD shops (AD speaks Kerberos natively)
  - HPC clusters (NFSv4 `sec=krb5` for shared storage)
  - Air-gapped / classified environments
  - Long-lived filesystems with UID-based permissions
- **New greenfield projects** rarely pick this stack. The operational burden (keytab rotation, clock skew, DNS correctness, replication conflicts) is significant.

## Part 3 — Reverie applicability

Reverie today:
- Single-user WSL2 dev box
- Localhost-only bind for reveried (:7437), redis (:6379), memcached, ollama, grafana stack
- Filesystem trust for coord protocol (`/tmp/claude-coord/`)
- No remote attack surface

**Does a single-user WSL2 mesh need this stack?** No.

Cases where it would start to matter:
- **Multi-user mesh**: reveried shared across multiple human accounts on the same box or over SSH. Auth + audit + per-user quota starts to matter.
- **Cross-host federation**: reveried on a workstation, GPU workers on a remote box with a TLS-bearing coord bridge. Service-to-service identity matters.
- **Passwordless SSH to remote workers**: GSSAPI-authenticated SSH with automatic forwarded tickets. Nice UX, no password prompts, full audit.
- **NFSv4 `sec=krb5`**: shared `/home/shared/reverie-mesh` across hosts with encryption and authentication at the filesystem layer.
- **Service-to-service auth**: reveried → redis → ollama → openrouter proxy all authenticating each other so a compromise of one doesn't leak the others.

A "reverie adopts Kerberos" experiment would require: a KDC (MIT or Heimdal), `krb5.conf`, a keytab per service, SASL configuration on redis, GSSAPI-enabled SSH, and a convention for mapping reverie roles to Kerberos principals. Non-trivial.

## Part 4 — Lightweight alternatives worth comparing

### SPIFFE / SPIRE
- Workload identity framework. Issues short-lived X.509 SVIDs signed by a workload identity provider (SPIRE server + per-node SPIRE agents).
- Designed for Kubernetes / microservices. Overkill for a single-host mesh. Shines when you have cross-cluster workload-to-workload auth.

### Tailscale / Headscale
- WireGuard mesh with identity. Every node gets a stable IP + cert from a control plane (Tailscale SaaS or self-hosted Headscale).
- Zero-config cross-host networking with identity baked in. Would trivially unlock multi-host reverie, but introduces a new external dependency (or a self-hosted Headscale).

### mTLS with an internal CA (**RECOMMENDED for multi-host**)
- `rustls` for TLS, `rcgen` to generate a self-signed root CA + service certs in pure Rust, short cert TTLs with a cron rotator.
- Pure-Rust end-to-end, memory-safe, zero C dependencies, async-friendly.
- Covers the 80% of the value of Kerberos (service-to-service identity, encrypted transport, audit log of cert issuance) with 20% of the operational surface.
- ~1–2 weeks to build, low maintenance burden.

### Biscuit tokens / Macaroons
- Capability-based auth: tokens carry caveats (e.g. "read-only", "expires at T", "only for project X") that can be locally verified and attenuated.
- `biscuit-auth` crate is pure Rust, mature enough for production. Datalog-based caveat language is powerful but has a learning curve.
- Good fit for delegation patterns (meshctl hands control-room a token that's restricted to "build reveried only, no other commands").

### systemd unit-level credentials
- `sd_peer_cred` lets a unix-socket server read the authenticated uid/gid of its peer.
- Near-zero setup, no crypto. Only works on a single host over unix sockets. Not a network auth solution but very cheap for single-host service-to-service trust.

### TPM2-backed secrets (systemd-creds)
- `systemd-creds encrypt --with-key=tpm2` binds a secret to hardware so only this machine can decrypt it at boot.
- Orthogonal to network auth but useful for the "where do API keys live" question.

## Part 5 — Rust ecosystem

| Crate | Version | Purpose | Verdict |
|---|---|---|---|
| `ldap3` | 0.12+ | Full LDAP client incl. SASL/GSSAPI | Mature, binds to `libsasl2` + `libgssapi` (C FFI, painful errors) |
| `libgssapi` | 0.8+ | Thin wrapper around MIT libgssapi | Works but unergonomic. No pure-Rust alternative. Kerberos in Rust is painful. |
| `rustls` | 0.23+ | TLS 1.2/1.3 implementation | **First-class**. Async-friendly, memory-safe, no `openssl` dependency. |
| `rcgen` | 0.13+ | Generate X.509 certs programmatically | **First-class** for building an internal CA. |
| `x509-parser` | 0.16+ | Parse X.509 certs | Solid. |
| `biscuit-auth` | 5.x | Capability tokens | Pure Rust, production-ready for the right use case. |
| `tonic-tls` / `axum-server` | latest | mTLS wiring for gRPC / HTTP | Both support client-cert verification out of the box. |

**Verdict**: the pure-Rust mTLS path (`rustls` + `rcgen`) is **dramatically** easier to build and maintain than the Kerberos path. Kerberos in Rust means C FFI, cryptic error messages, and a whole separate KDC to run. Only pay that cost if you have a compliance requirement forcing it.

## Part 6 — Recommendation

Three options, ranked by (security gain / effort):

### Option A — Status quo (recommended **now**)
- Keep localhost trust. Single user, single host, no network surface.
- **Effort: 0**
- **Security gain: 0**
- **Risk: 0 (for current threat model)**

### Option B — mTLS with internal CA (recommended for **multi-host**)
- Build a small `reverie-ca` binary using `rcgen` that generates a root CA + per-service certs with 7-day TTL.
- Wire `rustls` into reveried's axum server, redis (stunnel wrapper or native TLS config), and coord bridge.
- Daily cron rotates certs; `systemd-reload` signals services to pick up the new files.
- **Effort: 1–2 weeks**
- **Security gain: HIGH** — service-to-service identity, encrypted transport, audit trail.
- **Maintenance: LOW** — mostly cron + cert rotation script.

### Option C — Full FreeIPA / Kerberos (recommended for **multi-user + audit**)
- Stand up FreeIPA in a container or on a dedicated VM. Every host joins the realm.
- Per-service keytabs, SASL/GSSAPI binds, GSSAPI-authenticated SSH, NFSv4 `sec=krb5` if shared storage enters the picture.
- Operators use `kinit` once per day, everything else flows from their ticket.
- **Effort: 3–4 weeks**
- **Security gain: VERY HIGH** — full SSO, audit, Windows AD interop.
- **Maintenance: MODERATE** — keytab rotation, clock skew monitoring, replication health.

## Part 7 — Open questions

Before any of B or C is worth pursuing, answer these:

1. **Will reverie ever run multi-host?** GPU workers on remote boxes? If yes, B is on the table.
2. **Will reverie ever support multi-user?** Multiple humans sharing the same reverie instance? If yes, C may be on the table.
3. **Audit / compliance requirements?** SOC2, HIPAA, FedRAMP would all push toward C. Pure dev box: neither.
4. **Downstream service auth?** Do openrouter, anthropic api, ollama HTTP support token-based auth that could integrate with an identity provider? (Anthropic API: bearer token. OpenRouter: bearer token. Ollama: no auth by default, `OLLAMA_HOST` trusts localhost.)
5. **Encryption in transit OR audit+non-repudiation OR both?** mTLS covers the first. Kerberos ticket logs cover the second. Both together = FreeIPA.
6. **Team expertise?** Windows AD shop → Kerberos is familiar. Cloud-native team → OIDC or mTLS is familiar.
7. **Hardware?** TPM2 available on any reverie host? Unlocks systemd-creds as a cheap secret-at-rest story.

## Citations

- [RFC 4511 — Lightweight Directory Access Protocol (LDAP): The Protocol](https://datatracker.ietf.org/doc/html/rfc4511)
- [RFC 4120 — The Kerberos Network Authentication Service (V5)](https://datatracker.ietf.org/doc/html/rfc4120)
- [MIT Kerberos Documentation](https://web.mit.edu/kerberos/)
- [FreeIPA Project](https://www.freeipa.org/)
- [SPIFFE / SPIRE](https://spiffe.io/)
- [rustls](https://github.com/rustls/rustls)
- [rcgen](https://github.com/rustls/rcgen)
- [biscuit-auth](https://github.com/biscuit-auth/biscuit)
- [Tailscale](https://tailscale.com/) / [Headscale](https://github.com/juanfont/headscale)

---

Control-room lane · research only · not a decision.
