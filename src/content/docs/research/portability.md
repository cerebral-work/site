# Portability Survey — 2026-04-16

Catalog of hardcoded paths, user-specific constants, and binary dependencies that block running reverie on a clean Debian/Ubuntu/WSL2 box with a different username.

---

## Inventory

| Location | What | Currently | Proposed override |
|----------|------|-----------|-------------------|
| **Absolute Paths** | | | |
| `scripts/mesh/mesh-spawn` (line 22) | `REPO_ROOT` | `/home/ctodie/projects/reverie` | `$REPO_ROOT` (infer from git or parent dir) |
| `scripts/mesh/mesh-spawn` (line 23) | `WORKTREE_BASE` | `/home/ctodie/projects` | `$WORKTREE_BASE` (default to parent of `$REPO_ROOT`) |
| `scripts/mesh/mesh-spawn` (line 24) | `COORD` | `$HOME/.claude/bin/coord` | OK — uses `$HOME` |
| `scripts/mesh/mesh-spawn` (line 25) | `FILE_LOCK` | `$HOME/.claude/bin/file-lock` | OK — uses `$HOME` |
| `scripts/anchor-offload.sh` (line 97) | OpenRouter binary | `/home/ctodie/.local/bin/openrouter-call` | `$HOME/.local/bin/openrouter-call` (hardcoded, needs $HOME) |
| `scripts/anchor-offload.sh` (line 5) | LLM binary | `$HOME/.local/bin/llm-offload` | OK — uses `$HOME` |
| `scripts/coord-heartbeat-keeper.sh` (line 18) | `COORD_ROOT` | `/tmp/claude-coord` | `$COORD_ROOT` env var (already supported) |
| `crates/reveried/src/sleeper_rebound.rs` (line 265) | `coord_bin()` fallback | `/home/ctodie/.claude/bin/coord` | `std::env::var("HOME")` has no fallback — needs default |
| `crates/meshctl/src/main.rs` (line 848, 851) | Anchor tmux session | `reverie-anchor` | Hardcoded session name — make configurable |
| `crates/meshctl/src/roles.rs` (line default) | `HOME` fallback | `/home/ctodie` | `std::env::var("HOME")` has fallback — OK |
| `crates/meshctl/src/layout.rs` (2 occurrences) | `HOME` fallback | `/home/ctodie` | `std::env::var("HOME")` has fallback — OK |
| `ops/systemd/user/reveried.service` (line 12) | Daemon binary | `/home/ctodie/.local/bin/engram` | Should use `~/.local/bin/engram` (systemd supports `~`) |
| **Coord paths** | | | |
| `crates/reveried/src/agent_watcher.rs` (line 58) | `coord_sessions_dir` default | `/tmp/claude-coord/sessions` | OK — already configurable via `AgentWatcherConfig` |
| `crates/meshctl/src/main.rs` (line lock_base) | Locks directory | `/tmp/claude-coord/locks` | Derived from `COORD_ROOT` — should be parameterized |
| `crates/meshctl/src/main.rs` (line sessions read) | Sessions directory | `/tmp/claude-coord/sessions` | Derived from `COORD_ROOT` |
| `crates/meshctl-tui/src/lib.rs` (lines msg_dir, session path) | Coord paths | `/tmp/claude-coord/messages`, `/tmp/claude-coord/sessions/{sid}.json` | Hardcoded — need env var |
| `crates/reverie-status-tui/src/data.rs` (line locks walk) | Locks directory | `/tmp/claude-coord/locks` | Hardcoded — need env var |
| `crates/reverie-lock/src/lib.rs` (line 62) | Session cache | `/tmp/claude-coord-session-id-{uid}` | Hardcoded — could use `$COORD_ROOT` |
| `crates/reverie-lock/src/lib.rs` (line 64) | Locks directory | `/tmp/claude-coord/locks/project:{project}:{area}` | Hardcoded — derive from env var |
| `scripts/mesh/worker-lifecycle-hook.sh` (lines) | Session & lock paths | `/tmp/claude-coord/sessions`, `/tmp/claude-coord/locks` | Hardcoded — need env var (will be inherited by hook) |
| `scripts/mesh/file-lock-gate-hook.sh` (lines) | Lock directory | `/tmp/claude-coord/locks/project:reverie:{AREA}` | Hardcoded — need env var |
| `scripts/file-lock-tests.sh` (lines) | Lock paths | `/tmp/claude-coord/locks/project:{PROJECT}:*` | Hardcoded in test — OK for tests |
| `scripts/mesh-status.sh` (lines) | Locks directory | `/tmp/claude-coord/locks` | Hardcoded — need env var |
| **Binary Dependencies** | | | |
| `coord` | Coord daemon (packaged in ~/.claude/bin/) | Required for mesh coordination | **Required** — install via Makefile |
| `mesh-spawn` | Mesh worker spawner (in scripts/mesh/) | Required for mesh scaling | **Required** — installed by `make install-mesh` |
| `file-lock` | File-locking gate hook (in scripts/mesh/) | Required for multi-writer coordination | **Required** — installed by `make install-mesh` |
| `tmux` | Terminal multiplexer | Required for mesh anchor & workers | **Required** — `apt install tmux` |
| `redis-cli` | Redis command-line client | Optional — used by `reverie-lock` for audit logging | **Optional** — test with `redis-cli PING` before use |
| `jq` | JSON query tool | Optional — used in some scripts | **Optional** — fallback to shell parsing |
| `systemctl` | Systemd service manager | Required for daemon lifecycle | **Required** — native on Debian/Ubuntu |
| `ollama` | Local LLM server | Optional — tiered fallback in anchor-offload | **Optional** — test with `ollama list` |
| `gpg` | GNU Privacy Guard | Optional — used for signed commits in pre-commit hook | **Optional** — skip signing if GPG unavailable |
| `cargo`, `rustc` | Rust toolchain | Required for building from source | **Required** — `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs` |
| `claude` CLI | Claude AI command-line (from Anthropic) | Optional — referenced in docs/comments | **Optional** — used in worktree/agent contexts only |
| `engram` | Memory database (Go binary) | Optional — smoke-test comparison against reveried | **Optional** — only needed for `make smoke` |
| `rtk` | RTK Rust testing kit | Optional — used in some test scenarios | **Optional** — only for RTK-based tests |
| **User-Specific Constants** | | | |
| Cargo.toml authors email | `chris@todie.io` | Hardcoded in workspace Cargo.toml | **Not portable** — intentional (project metadata) |
| GPG signing key | `29234C4D7EE749F2` | Referenced in `.pre-commit-config.yaml` (if present) | **Not portable** — can disable signing in pre-commit hook |
| GitHub username | `todie` | In docs/comments; git remote URL (if repo cloned) | **Not portable** — check with `git config user.github` |
| Tmux anchor session | `reverie-anchor` | Hardcoded in meshctl/sleeper_rebound | **Configurable** — add `REVERIE_ANCHOR_SESSION` env var |
| Entity aliases | `ctodie`, `chris` | Hardcoded test fixtures in reverie-store, reverie-domain | **Not portable** — test fixtures only, not runtime |
| Default project | `ctodie` | Used in engram_compat.rs tests and reverie-bench | **Not portable** — test/bench fixtures |
| Home fallback | `/home/ctodie` | Fallback in sleeper_rebound.rs, meshctl, reverie-lock | **Suboptimal** — should fail loudly or use root (not suitable) |
| **HOME Layout Assumptions** | | | |
| Project checkout | `~/projects/reverie` | Inferred from script defaults | Use `REPO_ROOT` env var or detect via git |
| Worktree siblings | `~/projects/reverie-wt-*` | Hardcoded in mesh-spawn, reverie-lock tests | Use `WORKTREE_BASE` env var |
| Claude bin directory | `~/.claude/bin/` | Standard location (OK) | Use `$HOME/.claude/bin` |
| Claude hooks directory | `~/.claude/hooks/` | Standard location (OK) | Use `$HOME/.claude/hooks` |
| Systemd user units | `~/.config/systemd/user/` | Standard XDG location (OK) | Use `$HOME/.config/systemd/user` |
| Local binaries | `~/.local/bin/` | Standard XDG location (OK) | Use `$HOME/.local/bin` |
| Engram database | `~/.engram/engram.db` or `~/.local/share/engram/engram.db` | Both searched in engram_compat_smoke.sh | OK — fallback chain is reasonable |
| Config directory | `~/.config/reverie/` | Hardcoded in anchor-offload, reverie-secret scripts | OK — standard XDG location |

---

## Minimum Viable Port

Five smallest changes that unblock a fresh-box install with a different username:

1. **Export `COORD_ROOT` from reveried/meshctl**
   - Change: In meshctl-tui/src/lib.rs, reverie-status-tui/src/data.rs, and shell hooks: read `COORD_ROOT` env var (default `/tmp/claude-coord`)
   - Impact: Allows users to override the coordination directory on first startup
   - Files: meshctl-tui/src/lib.rs, reverie-status-tui/src/data.rs, reverie-lock/src/lib.rs, scripts/mesh/worker-lifecycle-hook.sh, scripts/mesh/file-lock-gate-hook.sh

2. **Fix HOME fallback in sleeper_rebound.rs**
   - Change: Line 265, change `unwrap_or_else(|_| "/home/ctodie".into())` to panic or use only env var
   - Impact: Prevent silent use of wrong home directory; fail explicitly if HOME is unset
   - Files: crates/reveried/src/sleeper_rebound.rs

3. **Make anchor tmux session configurable**
   - Change: Add `REVERIE_ANCHOR_SESSION` env var (default `reverie-anchor`)
   - Impact: Allow teams to use different anchor session names
   - Files: crates/meshctl/src/main.rs, crates/meshctl/src/roles.rs

4. **Use `~` in systemd unit for engram binary**
   - Change: Line 12 in ops/systemd/user/reveried.service, replace `/home/ctodie/.local/bin/engram` with `%h/.local/bin/engram` (systemd expands `%h` to home)
   - Impact: Makes systemd unit portable; no hardcoded username
   - Files: ops/systemd/user/reveried.service

5. **Fix anchor-offload.sh hardcoded openrouter path**
   - Change: Line 97, replace `/home/ctodie/.local/bin/openrouter-call` with `$HOME/.local/bin/openrouter-call`
   - Impact: Respects `$HOME` environment variable
   - Files: scripts/anchor-offload.sh

---

## Non-goals

These are explicitly out of scope:

- **Email addresses, GPG keys, GitHub accounts** — project metadata. Users should fork/rebrand as needed.
- **Entity aliases ("ctodie", "chris")** — part of the test/benchmark fixtures. Not runtime-critical.
- **Default project in bench/smoke tests** — fixtures can be parameterized per test invocation.
- **Signed commits** — pre-commit hook can be disabled with `--no-verify` if GPG key is unavailable.
- **Worktree naming scheme** — `reverie-wt-{role}` is a documented convention; keep it.

---

## Risks & Open Questions

1. **Coord root migration**: Changing `COORD_ROOT` requires killing all running coord sessions. Should this be a one-time init step or auto-migrated?

2. **Lock semantics**: `/tmp/claude-coord` assumes Unix tmpfs. On Windows WSL2, `/tmp` is shared with host; could cause collisions if multiple WSL instances run reverie. Consider `$XDG_RUNTIME_DIR` or user-scoped subdirectory.

3. **Systemd `%h` support**: Verify `%h` expansion works in `Type=simple` services on all target distros (Debian 11+, Ubuntu 20.04+).

4. **Fallback for missing HOME**: sleeper_rebound.rs, meshctl, and reverie-lock all have `/home/ctodie` fallbacks. Panic or use `/root` when HOME is unset? Recommend panic (fail-fast).

5. **Logging directory**: `/tmp/anchor-offload.log`, `/tmp/coord-heartbeat-keeper.log` are hardcoded. Consider moving to `$HOME/.local/state/reverie/` (per systemd state directory best practice).

6. **Multi-user scenarios**: If multiple users run reverie on the same box, shared `/tmp/claude-coord` will cause conflicts. Consider scoping to `$UID` or `$XDG_RUNTIME_DIR` (which is already per-user).

---

## Implementation Priority

- **P0 (blocking)**: Export `COORD_ROOT` (#1), fix HOME fallback (#2), make anchor session configurable (#3).
- **P1 (usability)**: Systemd unit portability (#4), anchor-offload.sh (#5).
- **P2 (future)**: Multi-user isolation, logging directory standardization, worktree path detection.

---

Generated by portability survey (TOD-729). Last updated: 2026-04-16.
