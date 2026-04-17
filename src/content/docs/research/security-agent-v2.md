# Security Agent v2: Research & Improvements

**Date**: 2026-04-16
**Author**: Security Research
**Status**: Proposal (ready for review)

---

## 1. Current State Summary

The reverie security agent (`reverie-security` role) is a **read-only reviewer** that audits supply-chain and vulnerability risks via:

- **Dependency auditing**: `cargo deny` (weekly CI schedule, on every PR/push via `EmbarkStudios/cargo-deny-action@v2`)
- **Secrets scanning**: via delegated `/secrets-scanner` subagent (runs on demand)
- **Lock discipline**: manual review of `Cargo.lock` changes; security agent has explicit write permission to Cargo.lock for emergency bumps
- **Code review**: OWASP top-10 spot-checks via `Grep` tool
- **Memory integration**: saves findings to engram as `kind=vulnerability` or `kind=advisory`

**Capabilities** (per `crates/meshctl/src/roles.rs:283–317`):
- Run `cargo deny` + `cargo audit`
- Audit lock files and dependency versions
- Review code for OWASP top-10
- Write security advisories in `docs/security/`
- Use `/secrets-scanner` agent

**Hard boundaries**:
- Cannot modify source code outside `docs/security/` and `Cargo.lock`
- Cannot merge PRs or push to main

**Tools**: `cargo deny`, `cargo audit`, `/secrets-scanner`, `Grep`, `mem_save`

---

## 2. Current Coverage vs. Threat Model

| Threat Model | Current Coverage | Gap | Severity |
|---|---|---|---|
| **Dependency vulnerabilities (CVE/RUSTSEC)** | `cargo deny` (weekly + on-PR); deny.toml tracks 2 ignored advisories (RUSTSEC-2024-0436, RUSTSEC-2025-0119) | No SLA for triage/response; advisory ignore list is not auto-reviewed; no SBOM generation | M |
| **Transitive supply-chain attacks** | `cargo deny` tracks sources (unknown-registry=deny, unknown-git=warn) | No `cargo-vet` consensus voting; no attestation chain validation; no hash pinning beyond lock file | M-H |
| **Secrets leakage (API keys, tokens)** | `.gitignore` has `.secrets`, `.env`; `/secrets-scanner` agent available on-demand | No pre-commit hook enforcement; no CI-gated secret detection; no periodic git history scan; scanner only runs when requested | H |
| **License compliance violations** | `deny.toml` allowlist (11 licenses) checked in CI | No SBOM export; no license-change detection alerts; no dashboard | L-M |
| **Malicious commit signers** | None | No GPG signature verification in release workflow; no SLSA provenance | H |
| **Privilege escalation (worker sandbox)** | Documented in ops: no setuid, no sudo, unprivileged deploy path | No runtime sandboxing verification; no capability audit of binaries | M |
| **Container/Docker image scanning** | None | No Dockerfiles found; no image SCA if containerization added | L (for now) |
| **Unsafe code audits** | None | 5335-line Cargo.lock with untrusted deps; no `cargo-geiger` scans | M |
| **Lock file mutations (Cargo.lock tampering)** | Manual review; security agent can write | No commit signature verification; no immutability enforcement in CI | M |
| **Dependency version pinning drift** | `Cargo.lock` tracked in repo; multiple-versions="allow" | No policy enforcement on semver bounds; no audit trail of bumps | L-M |

---

## 3. Automation Gaps

### Currently Missing

1. **Pre-commit secret scanning** — `.env`, `.secrets` in `.gitignore` but no git hook validation
2. **Periodic dep audit cycle** — only on schedule (weekly) + PR; no urgent re-runs for zero-days
3. **SBOM generation** — no bill-of-materials export for release artifacts or vendored deps
4. **GPG commit signature verification** — release workflow doesn't gate on signed commits
5. **Runtime capability audit** — binaries deployed unprivileged but no verification of capability set
6. **Cargo-vet** integration — no consensus voting on transitive deps, only deny rules
7. **Unsafe code scanning** (`cargo-geiger`) — no inventory of unsafe blocks
8. **Git history scanning** — no periodic sweep for leaked secrets in past commits
9. **Dependency deprecation tracking** — no alerts when a dep is archived/unmaintained (e.g., `paste`, `number_prefix` in deny ignore list)
10. **Lock file integrity checks** — no signature verification or immutability enforcement on Cargo.lock in CI

---

## 4. Integration Gaps with Other Roles

### Handoffs

| From/To | Current | Missing |
|---|---|---|
| **anchor → security** | Manual request for audit; no auto-dispatch | No threat-model-driven dispatches; no escalation path for zero-days |
| **security → release** | Security agent outputs advisory docs; no blockers on release | No gating: release doesn't wait for final security sign-off; no security metadata in release notes |
| **builder → security** | Builder flags vuln findings; security reviews | No pre-flight checks before builder runs cargo build; no sandbox policy enforcement |
| **ops → security** | None | No runtime vulnerability scanning of deployed reveried; no daemon capability audit |
| **security → anchor** | Saves findings to engram | No escalation signal for high-severity vulns; no auto-ticket creation |

### Proposed Handoffs

- **Anchor dispatches critical zero-day audit** → security role spins up high-effort audit
- **Security gates release** → release waits for security approval (advisory review + SLSA check)
- **Builder requests pre-build audit** → security runs `cargo-geiger` + deny check before compile
- **Ops requests cap audit** → security verifies binaries have minimal capabilities (no SETUID, no CAP_SYS_ADMIN)

---

## 5. Tooling Opportunities

### Tier 1 (High Impact, Available)

| Tool | Purpose | Effort | Why reverie needs it |
|---|---|---|---|
| **`cargo-audit`** | Scan Cargo.lock for known vulns (db-driven) | S | Already in role; not actively integrated in CI/role workflow |
| **`cargo-deny`** | Lint graph/sources/advisories/licenses | S | Already in CI; needs deeper integration (graph linting for transitive bloat) |
| **`cargo-vet`** | Consensus voting on supply-chain integrity | M | Complement deny.toml with human-vetted transitive attestations |
| **`cargo-geiger`** | Count unsafe blocks and associated risk | S | Inventory unsafe code; highlight deps with high unsafe ratio |
| **gitleaks** | Scan repo history for secrets | S | Pre-commit hook + periodic CI scan; prevent commit if match found |
| **semgrep** | SAST: find patterns (injection, logic flaws) | M | Deep code review beyond OWASP spot-checks; CI gating |

### Tier 2 (Medium Impact, Enterprise)

| Tool | Purpose | Effort | Notes |
|---|---|---|---|
| **`osv-scanner`** | Unified vuln detection across ecosystems | M | Better than cargo-deny for cross-language projects; reverie is Rust-only (lower priority) |
| **`trivy`** | Comprehensive SCA + container scanning | M | Future-proofing if Dockerfiles added; image scanning for CI/CD artifacts |
| **`grype`** | Syft-generated SBOM + vuln matching | M | Generate and sign SBOM for releases; attach to release artifacts |

### Tier 3 (Lower Priority for reverie v1)

| Tool | Purpose | Notes |
|---|---|---|
| **`cargo-supply-chain`** | Audit download counts, publish date | Informational; low risk for private single-author projects |
| **`sandboxing` (bubblewrap, gVisor)** | Runtime sandboxing for reveried workers | Out of scope; requires daemon redesign |

---

## 6. Seven Concrete Improvements (MVP + Future)

### **1. CI-Gated Pre-commit Secret Scanning**

**What**: Add `gitleaks` scan to GitHub Actions; block commits with secrets in CI; add `.git/hooks/pre-commit` for local dev.

**Why**: `.env` and `.secrets` in `.gitignore` prevent accidental staging, but don't block if developer forces add or edits history. Zero-days from leaked API keys.

**Effort**: S

**Dependencies**: gitleaks binary in GHA; `~/.git/hooks/pre-commit` template (can be auto-installed via Makefile)

**Ticket**: TOD-XXX

---

### **2. Automated Unsafe Code Inventory via cargo-geiger**

**What**: Run `cargo-geiger` in CI weekly; generate unsafe ratio report; save to `docs/security/unsafe-code-audit.md`.

**Why**: 5335-line Cargo.lock with transitive deps; no visibility into unsafe code density or risk hotspots. Builder doesn't know if a dependency is unsafe-heavy.

**Effort**: S

**Dependencies**: Integrate `cargo-geiger` into security agent; add to CI scheduled job; create report template

**Ticket**: TOD-XXX

---

### **3. cargo-vet Integration for Transitive Supply-Chain Attestation**

**What**: Adopt `cargo-vet` in addition to `deny.toml`; require security agent to audit high-risk transitive deps via community consensus.

**Why**: `deny.toml` blocks unsafe registries but doesn't validate *code quality* of transitive deps (e.g., `fastembed → tokenizers → paste` — archived, unmaintained). cargo-vet enables voting-based trust model.

**Effort**: M

**Dependencies**: Maintain `supply-chain.toml` vouching for audited deps; integrate into CI (allow+block); security agent owns audit SLA

**Ticket**: TOD-XXX

---

### **4. Security Agent Auto-Dispatch on Zero-Day (Anchor Integration)**

**What**: Anchor monitors RUSTSEC feed; auto-dispatches security role with `coord send --kind request --subject "ZERO_DAY_ALERT" ...` if new advisory matches reverie deps.

**Why**: Weekly schedule catches advisories between PRs, but 7-day gap on critical CVEs is unacceptable. Current path is manual.

**Effort**: M

**Dependencies**: Anchor integration with RUSTSEC feed (curl + parse); security role handles high-effort zeroday triage requests; `/herald-audit` skill integration

**Ticket**: TOD-XXX

---

### **5. SBOM Generation & Signed Release Artifacts**

**What**: Generate SPDX JSON/XML SBOM via `cargo-metadata`; sign with GPG; attach to GitHub release. Include license inventory.

**Why**: No way for users to verify supply-chain integrity or audit licenses post-deployment. SLSA level 1 (provenance) not possible without SBOM.

**Effort**: M

**Dependencies**: `cargo-metadata` / `syft`; GPG key setup for maintainer; `gh release upload` with artifact signing

**Ticket**: TOD-XXX

---

### **6. GPG Commit Signature Verification in Release Workflow**

**What**: Release workflow checks that release tag is signed by trusted key; blocks unsigned releases.

**Why**: No way to verify release authenticity. Malicious actor could tag + release without maintainer knowledge.

**Effort**: S

**Dependencies**: GH branch protection rule: require signed commits; release workflow calls `git verify-tag`; maintainer GPG key in GH

**Ticket**: TOD-XXX

---

### **7. Mandatory Security Sign-Off for Releases**

**What**: Release workflow gates on security agent approval: security agent runs final audit, posts `approve` comment, release waits for that comment before `gh release create`.

**Why**: Currently release can ship without security review. Builder could push vuln code, anchor could merge, and release could happen in minutes. No human checkpoint.

**Effort**: M

**Dependencies**: Anchor watches for security `approve` comment; release workflow polls for it; security agent has explicit capability

**Ticket**: TOD-XXX

---

## 7. Minimum Viable v2 (Ship First)

Prioritized by impact × effort:

### **Phase 1 (Week 1–2)**

1. **CI-Gated Secret Scanning** (Effort: S; Impact: H)
   - Add `gitleaks` to `.github/workflows/ci.yml` (preflight job)
   - Block merge if secrets detected
   - Add pre-commit hook template to repo

2. **Unsafe Code Inventory** (Effort: S; Impact: M)
   - Weekly `cargo-geiger` run; save report to `docs/security/unsafe-code-audit.md`
   - Include top-10 most-unsafe deps

3. **GPG Signature Verification** (Effort: S; Impact: H)
   - Release workflow: `git verify-tag` before releasing
   - Branch protection rule: require signed commits on main

### **Phase 2 (Week 3–4)**

4. **SBOM Generation** (Effort: M; Impact: M)
   - Generate + sign SBOM in release workflow
   - Attach to GitHub release

5. **Security Sign-Off Gate** (Effort: M; Impact: H)
   - Release waits for security agent approval comment
   - Security agent runs final audit (deny + geiger + manual spot-check)

### **Phase 3 (Post-v2)**

6. **cargo-vet Integration** (Effort: M; Impact: M)
7. **Zero-Day Auto-Dispatch** (Effort: M; Impact: H)

---

## 8. Role Spec Diff (v1 → v2)

```yaml
security:
  description: "security auditor — secret scanning, dep audit, lock discipline, vuln triage, release sign-off"
  session: "reverie-security"
  worktree: "~/projects/reverie-wt-security"
  effort: "low"  # → "medium" (more active)
  model: "sonnet"
  reasoning_effort: "high"
  max_context: 128_000
  capabilities:
    - "run cargo deny / cargo audit / cargo-vet / cargo-geiger"
    - "audit lock files and dependency versions"
    - "review code for OWASP top-10 vulnerabilities"
    - "write security advisories in docs/security/"
    # NEW:
    - "scan git history for secrets via gitleaks"
    - "generate and sign SBOM (SPDX) for releases"
    - "approve/block releases via coord reply with security-sign-off"
    - "receive zero-day alerts from anchor; triage RUSTSEC advisories"
    - "audit runtime capabilities of deployed binaries"
  hard_boundaries:
    - "never modify source code outside docs/security/ and Cargo.lock"
    - "never merge PRs or push to main"
  tools:
    - "cargo deny"
    - "cargo audit"
    - "cargo-vet"                    # NEW
    - "cargo-geiger"                 # NEW
    - "gitleaks"                     # NEW
    - "/secrets-scanner agent"
    - "Grep"
    - "mem_save"
    - "gh" (for SBOM upload, comment posting)  # NEW
  task_affinity:
    - "audit"
    - "scan"
    - "vulnerability"
    - "dependency"
    - "zero-day"                     # NEW
    - "release-audit"                # NEW
    - "sbom"                         # NEW
```

---

## 9. Related Linear Tickets

**Current**:
- **TOD-721**: Bump ratatui for RUSTSEC-2026-0002 — demonstrates urgent zero-day triage path (currently manual)
- **TOD-722**: Ignore number_prefix advisory — illustrates gap in advisory lifecycle (no auto-review of ignores)

**To File (v2 Scope)**:
- **TOD-800** (S): CI-gate secret scanning via gitleaks
- **TOD-801** (S): Weekly unsafe code inventory (cargo-geiger)
- **TOD-802** (M): SBOM generation + signing
- **TOD-803** (M): cargo-vet integration for transitive attestation
- **TOD-804** (M): Security sign-off gate for releases
- **TOD-805** (M): Zero-day auto-dispatch (anchor ↔ security)
- **TOD-806** (S): GPG commit signature verification in release workflow

---

## 10. Appendix: Threat Model Prioritization

### Exploitable Today (if attacker has repo access)

1. **Unsigned releases** — release tag could be forged; no GPG check
2. **Secrets in history** — if dev force-adds `.env`, no CI blocker
3. **Transitive supply-chain attack** — malicious deep-tree dep not validated

### Exploitable via Supply Chain (third-party compromise)

1. **Malicious RUSTSEC advisory injection** — advisories trusted without multi-source verification
2. **Unsafe code in dependencies** — no visibility into risk density

### Out of Scope (Reverie v1)

- Runtime exploitation via sandboxing breakout
- DNS/registry hijacking (would require GitHub Actions infra compromise)
- Maintainer account compromise (GH 2FA + GPG mitigate)

---

## 11. Success Criteria

**v2 Done When**:

- [ ] Gitleaks blocks commits with secrets in CI + local pre-commit hook installed
- [ ] Weekly unsafe code report generated and tracked
- [ ] Release tag must be GPG-signed; CI enforces verification
- [ ] SBOM generated for every release, signed + published
- [ ] Security agent auto-gets zero-day alerts; responds with triage ticket + recommendation
- [ ] Release gates on security agent sign-off comment
- [ ] Cargo-vet supply-chain.toml audited for top-20 transitive deps

---

## 12. References

- **SLSA Framework**: https://slsa.dev (levels 0–4; reverie aiming for L1–L2)
- **OWASP Top 10**: https://owasp.org/Top10/
- **RUSTSEC Advisory Database**: https://rustsec.org/
- **Cargo-vet RFC 1857**: https://github.com/rust-lang/rfcs/pull/3270
- **SPDX SBOM Format**: https://spdx.dev/
- **Threat Model**: Google Threat Dragon; PASTA; STRIDE applied to Rust supply chain

---

**Status**: Ready for anchor → builder hand-off + Linear ticket creation
**Next**: File TOD-800..806; prioritize Phase 1; update security role in roles.rs post-MVP completion
