# Publishing Rust Crates from a Cargo-Workspace Monorepo

*Research doc — Reverie project — 2026-04-08*
*Scope: crates.io and alternative registries, tooling survey, recommended workflow for `~/projects/reverie`.*
*Companion doc: `docs/research/rust-monorepo-make-wrapper.md` (parallel research on Make/justfile wrappers for workspace task running).*

---

## Executive summary

1. **Cargo itself got the main feature you want in Rust 1.90 (Sept 2025):** `cargo publish --workspace` now publishes all workspace members to crates.io in correct topological order in a single invocation. This obsoletes the third-party `cargo-publish-workspace` / `cargo-publish-ordered` hacks from 2022–2024. Reverie already targets `rust-version = "1.94"`, so this is free.
2. **For automation, use `release-plz`** — it is the only tool that combines conventional-commits changelog generation, `cargo-semver-checks` integration, release PRs, and multi-crate workspace publishing with zero config files. `cargo-release` is the manual fallback; `cargo-workspaces` is a lighter CLI; `cargo smart-release` (part of `gitoxide`) is single-maintainer and less polished.
3. **Default unpublished crates to `publish = false`.** In a workspace that mixes a daemon binary, CLI tools, benches, and libs, the cost of an accidental publish is real and the fix (yanking) is loud. Mark every non-library crate `publish = false` at creation time and only flip when you decide to ship.
4. **Keep `version.workspace = true` for now, but plan the split.** Reverie's libs are still at v0.1.0 and have no downstream users. When the first lib hits a stable API, move it off the shared workspace version onto its own track (tokio, axum, clap all do this). Until then, lockstep is fine and saves cognitive overhead.
5. **First publish target: `hotswap-listener`.** It is the only crate in the tree that is self-contained (no `reverie-*` deps), broadly reusable (zero-downtime restart is a general need), and its scaffold `Cargo.toml` already has keywords/categories/readme fields filled in — the owner clearly intended it for crates.io. Everything else depends on `reverie-store`, which is not ready for an external API contract.

---

## 1. Which crates make sense to publish?

Current workspace members (from `Cargo.toml`):

| Crate | Type | Depends on reverie-* | Publish candidacy |
|---|---|---|---|
| `reveried` | daemon binary | store, dream, gate, sync | **No** — binary distribution via GitHub releases, not crates.io |
| `meshctl` | CLI bin | likely store | Maybe — CLIs do get published (e.g. `ripgrep`, `just`) but only once mature |
| `meshctl-tui` | TUI bin | likely store | **No** — too coupled |
| `reverie-bench` | bench harness | internal | **No** — dev-only |
| `reverie-store` | lib | — | Deferred — core data model, needs API freeze |
| `reverie-dream` | lib | store | Deferred — couples to store |
| `reverie-gate` | lib | store | Deferred — couples to store |
| `reverie-sync` | lib | store | Deferred — couples to store |
| `reverie-tracee` | lib | ? | Deferred |
| `reverie-introspect` | lib | ? | Deferred |
| `reverie-proto` | lib | — (leaf) | **Yes, eventually** — protocol crate, natural published artifact |
| `hotswap-listener` | lib | — | **Yes, first** — zero reverie deps, general-purpose |

**Do binaries belong on crates.io?** Yes, if `cargo install <name>` is a reasonable install path for users. `ripgrep`, `just`, `bat`, `tokei` all publish their binary crates. Reveried doesn't qualify because (a) it needs a sidecar DB path, supervisor wiring, systemd unit, and (b) the intended install story is `make install` or a distro package. Keep `reveried` at `publish = false`.

**Recommended publish list:**

- **Now (when ready):** `hotswap-listener`
- **Soon:** `reverie-proto` (once wire format is stable)
- **Eventually:** `reverie-store` (once the chunk model is frozen at v1.0)
- **Maybe:** `meshctl` as a `cargo install meshctl` target once the API surface stabilizes
- **Never:** `reveried`, `meshctl-tui`, `reverie-bench`, `reverie-tracee` (dev-only)

---

## 2. `publish = false` as default

Yes — use `publish = false` in every crate's `[package]` section that is not actively targeting crates.io. Two reasons:

1. **Accidents are permanent.** `cargo publish` is idempotent per (name, version) — once a version is up, you cannot replace it, only yank, and the name is reserved forever. A half-tested crate that leaks to crates.io damages the namespace.
2. **`cargo publish --workspace` (Rust 1.90+) will skip any crate with `publish = false`** — this is the one-line safety net that lets you run a single workspace-wide publish command without auditing every member.

Convention in large workspaces (bevy, tokio-rs/mini-redis, many matrix-org repos): every `[package]` section defaults to `publish = false` on creation; maintainers explicitly flip it to `publish = ["crates-io"]` (or remove the line) on a crate's first real release.

Reverie should adopt this now: add `publish = false` to all 11 crates in a single PR. The eventual publish candidates lose the line (or get `publish = ["crates-io"]` for clarity) when they're ready.

---

## 3. Version coordination: workspace vs per-crate

**Current state (Reverie):** `version.workspace = true` in every member → all crates move together at 0.1.0. This is the "lockstep" model.

**Lockstep pros:**
- One number to think about, one changelog, one release
- Matches user mental model when crates are tightly coupled (all reverie-* libs are)
- Trivial automation: bump root `[workspace.package].version`, run `cargo publish --workspace`
- `release-plz` handles it natively

**Lockstep cons:**
- A patch to `hotswap-listener` forces a version bump on `reverie-store` even if store hasn't changed — churns downstream Cargo.locks for no reason
- Semver becomes coarser: any breaking change in any crate forces a major across the whole workspace
- docs.rs users see misleading version numbers (a v2.0.0 crate with no actual changes since v1.3.0)

**What big projects do (surveyed April 2026):**

- **tokio** — per-crate versioning. `tokio`, `tokio-util`, `tokio-stream`, `tokio-macros` all carry independent versions. The tokio-rs org explicitly calls this out in their release docs. Each crate has its own CHANGELOG.md.
- **axum** — per-crate. `axum`, `axum-core`, `axum-extra`, `axum-macros` released independently. The axum 0.7 release was a coordinated multi-crate bump but versions weren't identical.
- **clap** — per-crate. `clap`, `clap_derive`, `clap_builder`, `clap_complete` all independent.
- **ratatui** — lockstep across `ratatui`, `ratatui-core`, `ratatui-macros`. Simpler, smaller team.
- **bevy** — lockstep. Every member moves at the bevy version. They accept the churn in exchange for the mental simplicity — this is the closest peer pattern for reverie.

**Mixing the two models** is supported: set `version.workspace = true` on the crates you want locked, and hardcode `version = "x.y.z"` on the ones that go independent. `hotswap-listener` already does exactly this (`version = "0.0.0"` literal, not workspace-inherited) — that's the template.

**Recommendation for reverie:** stay lockstep until the first crate has an external downstream. At that point, move that crate to its own version track by replacing `version.workspace = true` with a literal. Incremental migration, no big-bang refactor needed.

---

## 4. Publishing order and the tooling landscape

**The problem (pre-Rust 1.90):** `cargo publish` is a single-crate command. If `reverie-store` depends on `hotswap-listener`, you must publish `hotswap-listener` first, wait ~30s for the crates.io index to refresh, then publish `reverie-store`. Get the order wrong and the second publish fails with "no matching package found" because the index hasn't caught up.

**The fix (Rust 1.90, Sept 2025):** `cargo publish --workspace` — ([InfoWorld, Rust 1.90 workspace publishing](https://www.infoworld.com/article/4060262/rust-1-90-brings-workspace-publishing-support-to-cargo.html)). Cargo now computes a topological sort, waits for index propagation between crates, and skips `publish = false` members. This is the right primitive for Reverie — we're on 1.94, so it's available today.

**Third-party tools (pre-1.90 landscape, still relevant for automation):**

| Tool | Focus | Last release (April 2026) | Verdict |
|---|---|---|---|
| [`release-plz`](https://crates.io/crates/release-plz) | End-to-end: changelog + semver-check + release PR + publish | Active, monthly-plus releases, maintained by Marco Ieni | **Top pick.** Only tool that does the whole loop without config. |
| [`cargo-release`](https://github.com/crate-ci/cargo-release) | Manual release ceremony: version bump, tag, publish | Active, crate-ci org | Good fallback when you want direct control and no CI automation. No changelog support. |
| [`cargo-workspaces`](https://crates.io/crates/cargo-workspaces) | CLI for workspace-wide version bumps and publishes | Active, pksunkara | Lightweight alternative to cargo-release; similar ceremony, less opinion. |
| [`cargo smart-release`](https://github.com/Byron/gitoxide) | Part of gitoxide | Byron's personal tool | Functional but single-maintainer and tied to gitoxide's release cycle. Avoid. |
| [`cargo-publish-workspace`](https://github.com/foresterre/cargo-publish-workspace) | Topological publish only | "Minimal maintenance" per lib.rs | Obsolete post-1.90. |
| [`cargo-publish-ordered`](https://crates.io/crates/cargo-publish-ordered) | Topological publish only | Active | Obsolete post-1.90. |

Sources: [release-plz why doc](https://release-plz.dev/docs/why), [Tweag "Publish all your crates everywhere all at once"](https://www.tweag.io/blog/2025-07-10-cargo-package-workspace/), [Orhun blog on automated Rust releases](https://blog.orhun.dev/automated-rust-releases/).

---

## 5. `cargo publish --dry-run` — what it catches and misses

**What it checks:**
- `Cargo.toml` is well-formed, has required fields (name, version, license or license-file, description)
- Package builds from a clean `target/package/` extraction (catches "works on my machine" because of uncommitted files)
- All dependencies resolve with the versions specified (path-only deps are rejected)
- Manifest metadata is within size limits
- README file exists if `readme` is set

**What it does NOT catch:**
- **Broken docs** — `cargo doc` is not run. docs.rs failures only surface after upload.
- **API breakage** — not a semver tool. Use `cargo-semver-checks`.
- **Missing `rust-version`** — wildcard MSRV is allowed and produces noisy consumer warnings.
- **`#[doc(hidden)]` items leaking into public API** — not inspected.
- **Feature matrix breakage** — only the default feature set is compiled. A feature combination that doesn't build will pass dry-run and fail post-publish for users.
- **Wrong license SPDX** — the string is not validated against SPDX.
- **Index propagation delays** in multi-crate publish — dry-run is per-crate.

Always pair `--dry-run` with: `cargo doc --no-deps`, `cargo hack check --feature-powerset --no-dev-deps` (or a subset), and `cargo semver-checks check-release`.

---

## 6. Path deps vs version deps

Cargo's actual behavior (from [Cargo Book — Specifying Dependencies, Multiple Locations section](https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html)):

> The `path` dependency is used locally, and when published to a registry like crates.io, the `version` is used instead. The `path` key is removed at publish time.

**Practical rule:** for every inter-crate dep inside a workspace that will be published, write both:

```toml
reverie-store = { path = "../reverie-store", version = "0.1.0" }
```

Reverie already does this in `reveried/Cargo.toml` and `reverie-dream/Cargo.toml`. Good.

**Gotcha:** if you forget the `version =` and only write `path =`, local dev works fine but `cargo publish` on the downstream crate fails with "all path dependencies must also specify a version". Workspaces hide this bug for a long time because 95% of your dev loop never runs `cargo publish`.

**`cargo-autoinherit`** ([Mainmatter blog](https://mainmatter.com/blog/2024/03/18/cargo-autoinherit/)) helps with the inverse problem (DRYing third-party deps into `[workspace.dependencies]`), but does not help with inter-crate path+version pairs. Those still need to be written by hand — or inserted automatically by `release-plz` / `cargo-release`, which update the `version =` field across all dependents when they bump a crate.

---

## 7. README and docs.rs metadata

**Mandatory for crates.io to accept a publish:**
- `name`, `version`, `edition`
- `description` (one-line)
- `license` or `license-file`

**Mandatory for a *respectable* listing (soft requirements, strongly recommended):**
- `readme = "README.md"` with the file present
- `repository` pointing at the source (crates.io links it as "Repository")
- `documentation` — optional, defaults to docs.rs, which is fine
- `homepage` — optional, only useful if you have a project website
- `keywords` — up to 5, lowercase, alphanumeric+hyphens; feeds crates.io search
- `categories` — from the fixed list at <https://crates.io/category_slugs>; feeds category browsing
- `rust-version` — MSRV. Without this, consumers get no guardrail and cargo's MSRV-aware resolver can't help them.

**Linters:**
- [`cargo-check-publish`](https://crates.io/crates/cargo-check-publish) — lightweight, not widely adopted
- [`cargo-release`'s `pre-release-verify` hook](https://github.com/crate-ci/cargo-release) — most complete metadata check in practice
- `release-plz` internally validates before opening a release PR

Recommendation: don't bother with a dedicated linter. Let `release-plz` or `cargo-release` fail the CI job if metadata is missing.

---

## 8. Automated release workflows

**Pattern A — manual `cargo-release`:**

```bash
cargo release minor --execute  # bumps, tags, pushes, publishes
```

Pros: direct control, well-understood, works offline. Cons: requires local crates.io token, no changelog automation, easy to forget steps.

**Pattern B — tag-triggered GitHub Action calling `cargo publish`:**

```yaml
on:
  push:
    tags: ['v*']
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo publish --workspace --token ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

Pros: minimal. Cons: no version-bump automation, no changelog, no semver guard, easy to tag the wrong commit.

**Pattern C — `release-plz` (recommended):**

`release-plz` runs on every push to main and opens a "Release PR" that bumps versions (from conventional commits), updates CHANGELOG.md, and updates Cargo.lock. When a human merges that PR, a second workflow detects the version change and runs `cargo publish --workspace`. Integration with `cargo-semver-checks` is built in.

```yaml
# .github/workflows/release-plz.yml
name: Release-plz
on:
  push:
    branches: [main]
permissions:
  pull-requests: write
  contents: write
jobs:
  release-plz:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: dtolnay/rust-toolchain@stable
      - uses: MarcoIeni/release-plz-action@v0.5
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

Pros: full loop, zero config needed, conventional-commits native, semver-check integrated, changelog maintained for you, works with `publish = false`. Cons: opinionated about conventional commits (fine for reverie — project already uses them).

**Pattern D — `changesets` (JS world, adapted):** exists for Rust via community scripts but is less mature than release-plz. Skip.

**Recommendation:** Pattern C. Reverie already uses conventional commits and already has a CHANGELOG append skill.

Source: [Orhun Parmaksız — "Fully Automated Releases for Rust Projects"](https://blog.orhun.dev/automated-rust-releases/).

---

## 9. Breaking change detection: `cargo-semver-checks`

[`cargo-semver-checks`](https://github.com/obi1kenobi/cargo-semver-checks) is the community standard. As of late 2025 it ships 245 lints and runs in about a minute on most crates (per [clidragon's GSoC 2025 writeup](https://clidragon.github.io/blog/gsoc-2025/)).

**CI wiring (standalone):**

```yaml
- name: Check semver
  uses: obi1kenobi/cargo-semver-checks-action@v2
```

By default it compares your current crate against the latest non-prerelease, non-yanked version on crates.io and fails the job on violations.

**CI wiring (via release-plz):** nothing to do. `release-plz` calls `cargo-semver-checks` automatically when opening a release PR and adjusts the proposed version bump (patch → minor → major) based on the verdict.

**Gotcha:** semver-checks can only compare against a *published* baseline. For a crate's first publish, it's a no-op. For private registries, you need to provide a baseline via `--baseline-rev` (a git ref).

---

## 10. Pre-publish safety checklist

Copy-paste checklist for every first publish:

```markdown
## First-publish checklist for <crate-name>

### Metadata
- [ ] `name` is unique on crates.io (check via `cargo search`)
- [ ] `description` is a complete sentence, ends with a period
- [ ] `license` is a valid SPDX expression (e.g. "MIT" or "MIT OR Apache-2.0")
- [ ] `repository` points at the public git repo
- [ ] `readme = "README.md"` and file exists at crate root
- [ ] `keywords` has 1–5 entries, lowercase
- [ ] `categories` has 1–5 entries from https://crates.io/category_slugs
- [ ] `rust-version` is set (no wildcard MSRV)
- [ ] `publish = false` is NOT present (or is set to `["crates-io"]`)

### Content
- [ ] README has: title, one-paragraph pitch, install, 10-line usage example, license
- [ ] CHANGELOG.md exists with an entry for this version
- [ ] LICENSE file at crate root (cargo publish includes it)
- [ ] No `#[doc(hidden)]` on items that should be private (move them to a `pub(crate)` module instead)
- [ ] `cargo doc --no-deps` builds without warnings
- [ ] Public API has rustdoc on every `pub` item

### Dependencies
- [ ] All `path = ...` workspace deps also have `version = "x.y.z"`
- [ ] No git dependencies in the published crate (crates.io rejects them)
- [ ] No dev-dependencies leak into the public API
- [ ] Optional dependencies are behind features with clear names

### Verification
- [ ] `cargo publish --dry-run` succeeds
- [ ] `cargo package --list` shows only the files you intend to ship
- [ ] `cargo semver-checks check-release` (if not a first publish)
- [ ] `cargo test --all-features` and `cargo test --no-default-features` both pass
- [ ] `cargo hack check --feature-powerset --no-dev-deps` (if using cargo-hack)

### Git hygiene
- [ ] Working tree is clean
- [ ] On main branch, at the commit you intend to tag
- [ ] Tag name matches `v0.1.0` convention
```

**Common first-publish mistakes:**
1. License file not in the crate directory (only at repo root) — `cargo package` won't include it
2. README at repo root instead of crate root, with `readme = "../README.md"` — rejected
3. Path deps without version (works locally, fails at publish)
4. `#[doc(hidden)] pub fn` — consumers can still call it, you're now on the hook for semver
5. Missing `rust-version` → MSRV drift hits users

---

## 11. Multi-crate releases in one PR

`release-plz` and `cargo-release --workspace` both handle atomic multi-crate bumps:

- **`release-plz`:** opens one PR that bumps N crates. `Cargo.lock` is updated in the same PR. Merge → publishes all N in topological order via `cargo publish --workspace`.
- **`cargo-release --workspace`:** same idea, run locally: `cargo release minor --workspace --execute`. Updates all `version` fields, updates `Cargo.lock`, creates one git tag per crate, publishes in order.

**Lockfile implication:** publishing does NOT update downstream users' `Cargo.lock` — those only change when users run `cargo update`. But YOUR own `Cargo.lock` does change during the release PR because inter-crate version bumps propagate. Commit that update in the same PR.

**Gotcha with lockstep versioning:** if all 11 crates share `version.workspace = true`, bumping that one field bumps all 11 at once. `release-plz` handles it; `cargo publish --workspace` publishes all 11 (minus `publish = false`). This is the intended lockstep behavior.

---

## 12. Alternative / private registries

Tools surveyed:

- **[Kellnr](https://kellnr.io/)** — self-hosted Rust registry, Rust-native, docker image, sparse-registry API since 2.3.4. Actively maintained by Bitfalter. Runs on a Raspberry Pi. **Top pick if you need private crates.**
- **`cargo-index`** — low-level tool for managing a git-backed registry index. Too raw for solo use.
- **Shipyard.rs** — hosted private registry service. Paid. Overkill for solo.
- **Cloudsmith / Gemfury / JFrog Artifactory** — multi-language registries with Cargo support. Appropriate in an org, overkill for solo.

**Mixing public + private:**

```toml
# .cargo/config.toml
[registries.kellnr]
index = "sparse+https://kellnr.example.com/api/v1/crates/"

# crate Cargo.toml
[package]
publish = ["kellnr"]  # only to the private registry
```

**Verdict for reverie (solo dev):** don't bother. There's no proprietary bit in the current workspace; every library is MIT-licensed and open-source. If a future need for a private crate arises, Kellnr in a docker container is a 15-minute setup. Until then, public crates.io only.

---

## 13. Yanks, mistakes, and recovery

`cargo yank --version 0.2.1` marks a version as "do not use for new resolves". It is NOT a delete — the version stays downloadable, existing `Cargo.lock` files pinning it still resolve. It just prevents NEW dependents from picking it up.

**When to yank:**
- Published a version with a critical bug or security issue
- Published a version that accidentally leaked secrets/debug code
- Published a version with a broken feature set that fails to compile

**When NOT to yank:**
- Minor doc issue → just publish a patch release
- Stylistic regret → just publish next version
- "I want to rename the crate" → yanking doesn't help; publish under the new name, deprecate the old

**Recovery flow:**
1. `cargo yank --version x.y.z -p <crate>` — immediate
2. Fix the issue on main
3. Bump patch: `x.y.z` → `x.y.(z+1)`
4. `cargo publish --workspace`
5. Post a note: GitHub release notes, CHANGELOG entry explaining the yank, optional RUSTSEC advisory if security
6. If you need to unyank later: `cargo yank --version x.y.z -p <crate> --undo`

**Name squatting:** once published, the name is yours forever. You can't publish a "replacement" under the same name at a lower version. Plan your first publish's version carefully — starting at `0.1.0` (not `0.0.1`) is the convention.

---

## 14. Specific recommendations for Reverie

**Is publishing worth it right now?**

No — with one exception. Reverie is a v0.1.0 pre-release project with no external users and no stable API. Publishing reverie-store or reverie-dream now would lock in an API contract that is actively churning (Chunk model is still being iterated, dream pipeline is being tuned). Every patch would require a semver bump and every semver bump would require a crates.io release.

**The exception: `hotswap-listener`.** It's a scaffold (v0.0.0) designed from day one as a standalone general-purpose library. It has zero reverie-specific deps. The keywords, categories, and README fields in its `Cargo.toml` were clearly filled out with crates.io in mind. Once the supervisor-fork design is implemented and has tests, publishing it at v0.1.0 would:

1. Claim the name before someone else does
2. Give the Reverie project one concrete example of the publish pipeline working end-to-end
3. Attract potential users / feedback on the API
4. Not lock in anything that reverie-* depends on

**Concrete sequence when ready:**

1. **One-shot hygiene PR (can do today):**
   - Add `publish = false` to every crate's `[package]` section except `hotswap-listener`
   - Verify all inter-crate deps have both `path =` and `version =`
   - Add `keywords` and `categories` to the crates that will eventually publish
   - Commit. No release yet.

2. **Install tooling:**
   - `cargo install release-plz` (local dev use)
   - Add `release-plz` GitHub Action to `.github/workflows/release-plz.yml`
   - Add `CARGO_REGISTRY_TOKEN` secret to the GitHub repo settings

3. **Finish `hotswap-listener`:**
   - Implement the supervisor-fork from `docs/research/hotswap-listener-design.md`
   - Write README with usage example
   - Write LICENSE (MIT) at the crate root
   - Run through the pre-publish checklist in section 10
   - Bump to v0.1.0 and flip `publish` (remove `= false`)

4. **First publish:**
   - `cargo publish --dry-run -p hotswap-listener`
   - `cargo publish -p hotswap-listener`
   - Tag: `git tag hotswap-listener-v0.1.0 && git push --tags`
   - Announce in CHANGELOG.md

5. **Iterate on automation:**
   - First few releases done manually to confirm the loop
   - Once comfortable, let release-plz drive

6. **Revisit yearly:** when a reverie-* lib's API stabilizes, split it off the shared workspace version, add it to the publish list, and let release-plz handle the multi-crate PR.

---

## Tools verdict (one paragraph)

For Reverie today: **`release-plz` is the right tool.** It is the only option that combines conventional-commits changelog generation, automatic `cargo-semver-checks` integration, PR-based release review, and multi-crate workspace publishing — with zero config files required, native `publish = false` respect, and built-in support for Rust 1.90's `cargo publish --workspace`. `cargo-release` is the manual fallback for when you want to cut a release from your laptop without touching CI; keep it installed as a secondary tool (`cargo install cargo-release`) for emergencies. `cargo-workspaces` is a lighter CLI that doesn't add much on top of cargo's native 1.90 workspace support — skip it. `cargo smart-release` is tied to gitoxide's single-maintainer release cycle — avoid. The obsolete `cargo-publish-workspace` / `cargo-publish-ordered` tools are no longer needed on Rust ≥1.90.

---

## Out of scope

This doc intentionally skips:

- **Binary distribution** (GitHub Releases, Homebrew tap, AUR, Nix flake, cargo-binstall) — covered separately when `reveried` ships its first binary release.
- **Docker image publishing** (Docker Hub, ghcr.io) — deploy concern, not a crates.io concern.
- **Mirror / proxy registries** for air-gapped or China-compliance scenarios — not a current need.
- **Legal review of the MIT license** — assumed fine; the repo already declares it.
- **docs.rs configuration** (`[package.metadata.docs.rs]`) — will cover when `reverie-store` or `reverie-proto` approaches first publish; until then default docs.rs build is sufficient.
- **CLA / DCO signing** — solo project, no contributors yet.
- **`cargo-dist`** for binary artifact pipelines — different problem space from crates.io publishing. Worth a separate doc when reveried cuts its first binary release.
- **Parallel research on Make/justfile wrappers** — see sibling doc `docs/research/rust-monorepo-make-wrapper.md`.

---

## Sources

- [Rust 1.90 brings workspace publishing support to Cargo — InfoWorld](https://www.infoworld.com/article/4060262/rust-1-90-brings-workspace-publishing-support-to-cargo.html)
- [release-plz — crates.io](https://crates.io/crates/release-plz) and [release-plz.dev — Why](https://release-plz.dev/docs/why)
- [Fully Automated Releases for Rust Projects — Orhun Parmaksız](https://blog.orhun.dev/automated-rust-releases/)
- [Publish all your crates everywhere all at once — Tweag, 2025-07](https://www.tweag.io/blog/2025-07-10-cargo-package-workspace/)
- [cargo-release — crate-ci/cargo-release](https://github.com/crate-ci/cargo-release)
- [cargo-semver-checks — obi1kenobi](https://github.com/obi1kenobi/cargo-semver-checks)
- [cargo-semver-checks-action](https://github.com/obi1kenobi/cargo-semver-checks-action)
- [GSoC 2025: Making cargo-semver-checks faster — clidragon](https://clidragon.github.io/blog/gsoc-2025/)
- [Cargo Book — Specifying Dependencies (Multiple Locations)](https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html)
- [cargo-autoinherit — Mainmatter blog](https://mainmatter.com/blog/2024/03/18/cargo-autoinherit/)
- [Kellnr — The private Rust Crate Registry](https://kellnr.io/)
- [Release-plz: release Rust packages from CI — Marco Ieni](https://www.marcoieni.com/2022/06/release-plz-release-rust-packages-from-ci/)
