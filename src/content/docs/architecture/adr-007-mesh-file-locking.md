# ADR-007: Mesh File Locking

**Status**: Accepted (shipped)
**Date**: 2026-04-09

## Context

Multiple Claude Code sessions (anchor + N workers) operate on the same reverie workspace simultaneously via git worktrees. The coord protocol (v0, `docs/coord/protocol-v0.md`) provides session registration, heartbeats, messaging, and coarse-grained locks (`main-branch`, `pr-merge-queue`, `cargo-build`, `claude-config`). But these locks are resource-level, not file-level — two workers can both hold `cargo-build` while editing different files in the same crate, causing merge conflicts or compile errors.

Observed failure modes (from the 2026-04-07 sprint):
1. Two workers edit `engram_compat.rs` in separate worktrees — merge train hits type conflicts
2. Worker adds a field to `Chunk` while another worker adds a method — both compile alone, fail on merge
3. Worker edits `CLAUDE.md` while anchor is also editing — last writer wins silently

## Decision

Add a file-level locking layer (`file-lock`) on top of the coord project-lock primitive. Implemented as `~/.claude/bin/file-lock` — a ~130-line bash script that normalizes file paths into coord lock areas.

### Architecture

```
┌─────────────────────────────────────────────────┐
│  Claude Code session (anchor or worker)         │
│                                                 │
│  file-lock acquire reverie chunk.rs             │
│      │                                          │
│      ▼                                          │
│  normalize_area("chunk.rs")                     │
│      → "file::reverie-store__src__chunk.rs"     │
│      │                                          │
│      ▼                                          │
│  coord project-lock reverie                     │
│      --area "file::reverie-store__src__chunk.rs" │
│      --reason "editing chunk.rs"                │
│      │                                          │
│      ▼                                          │
│  /tmp/claude-coord/locks/                       │
│      project:reverie:file::reverie-store__...   │
│          ├── owner    (session ID)              │
│          └── record.json  (reason, timestamp)   │
└─────────────────────────────────────────────────┘
```

### Commands

```bash
# Acquire a lock (blocks if held; fails with rollback on conflict)
file-lock acquire <project> <file> [<file>...]

# Release a lock
file-lock release <project> <file> [<file>...]

# Check if a file is locked (exit 0=free, 1=locked)
file-lock check <project> <file>

# List all file locks for a project
file-lock list <project>

# Acquire, run command, release (RAII pattern)
file-lock guard <project> <file> [<file>...] -- <command>
```

### Path normalization

The `normalize_area()` function strips absolute path prefixes and converts `/` to `__` for flat lock directory naming:

```
/home/ctodie/projects/reverie/crates/reverie-store/src/chunk.rs
  → strip /home/*/projects/reverie*/
  → strip crates/
  → reverie-store/src/chunk.rs
  → file::reverie-store__src__chunk.rs
```

This means locks are crate-relative: `file-lock acquire reverie crates/reverie-store/src/chunk.rs` and `file-lock acquire reverie reverie-store/src/chunk.rs` resolve to the same area.

### Atomicity

Multi-file locking is all-or-nothing. If acquiring lock N fails, locks 1..N-1 are rolled back:

```bash
file-lock acquire reverie chunk.rs search.rs
# If search.rs is already locked → chunk.rs is released → exit 1
```

### Guard pattern

The `guard` subcommand acquires locks, runs a command, and releases on exit (success or failure):

```bash
file-lock guard reverie engram_compat.rs scoring.rs -- cargo test -p reverie-store
```

This is the recommended pattern for worker dispatch: the anchor includes `file-lock guard` in the worker's task to ensure locks are always released.

## Storage

Locks live under `/tmp/claude-coord/locks/` as directories:

```
/tmp/claude-coord/locks/
  project:reverie:file::reverie-store__src__chunk.rs/
    ├── owner         # plain text: session ID (e.g., "claude-pid-19972")
    └── record.json   # {"reason": "editing chunk.rs", "timestamp": "..."}
```

Locks are ephemeral (cleared on reboot via `/tmp`). This is intentional — stale locks from crashed sessions are the primary failure mode of persistent lock stores. The coord heartbeat + stale cleanup (5-minute timeout, per protocol-v0 §6) handles crashed sessions.

## Integration with worker dispatch

The anchor's worker dispatch protocol includes file-lock obligations:

1. **Anchor** identifies files the worker will touch
2. **Anchor** acquires file-locks before spawning the worker (or includes `file-lock guard` in the task)
3. **Worker** operates within its worktree, knowing no sibling touches those files
4. **Worker** releases locks on completion (explicit `file-lock release` or `guard` auto-release)
5. **Anchor** verifies locks are released before merging the worker's branch

### Failure recovery

| Scenario | Recovery |
|----------|----------|
| Worker crashes without releasing | Coord stale cleanup reclaims after 5 min |
| Worker holds lock too long | Anchor can `coord steal` the underlying project-lock |
| Lock check shows dead owner PID | `/orphan-lock-clean` skill reclaims in-place |
| Worker needs a file locked by sibling | `coord send` to anchor requesting handoff |

## Consequences

**Positive**:
- Eliminates merge conflicts from concurrent file edits across worktrees
- All-or-nothing multi-file locking prevents partial-edit races
- Guard pattern ensures cleanup on worker crash/error
- Path normalization makes lock areas deterministic regardless of invocation directory

**Negative**:
- Granularity is per-file, not per-function — two workers editing different functions in the same file must serialize
- Bash implementation limits portability (WSL2/Linux only; macOS untested)
- `/tmp` storage means locks don't survive reboot (acceptable for ephemeral sessions)

**Neutral**:
- Lock contention visibility is limited to `file-lock list` output — no metrics/tracing yet
- No deadlock detection (workers hold ≤3 files typically; cycles are unlikely)

## Alternatives considered

1. **Git merge-level conflict resolution** — Let workers edit freely, resolve at merge time. Rejected: merge conflicts in Rust code are rarely auto-resolvable and waste tokens on rebase/fixup.

2. **Crate-level locking** — Lock entire crates instead of files. Rejected: too coarse. Workers routinely edit different files in the same crate (`reverie-store` has 15+ source files).

3. **Advisory locks via `flock(2)`** — POSIX file locks. Rejected: doesn't compose with coord's existing lock store, and git worktrees mean the "same file" is at different paths.
