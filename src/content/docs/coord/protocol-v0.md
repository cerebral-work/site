# Claude Session Coordination Protocol — v0

**Status**: draft, ship-today scope (local filesystem backend)
**Target**: cooperating Claude Code sessions on one host, with a clear path to
multi-host (Redis / NATS / Postgres) in v1+.

## 1. Problem

Two or more Claude Code sessions running against the same workspace (either the
same user in multiple VSCode windows, or via `claude --resume`) collide in
subtle, silent ways. Examples observed 2026-04-07 during the MVP-B push:

1. **Git state contention** — peer session created a `reverie-wt-tod-412`
   worktree and modified `main.rs`; the primary session didn't discover the
   drift until `cargo` surfaced compile errors against the composed tree.
2. **`gh pr merge` race** — post-push mergeability is async on GitHub's side;
   back-to-back merges from different sessions hit `UNKNOWN` / `UNSTABLE` and
   error non-deterministically.
3. **`~/.claude/` file races** — both sessions tried to write hooks and
   settings simultaneously; last writer silently won.
4. **Branch-base drift** — peer branched from an older main, primary branched
   from a newer one; neither session could see that a shared helper struct had
   gained a field, and the merge train hit type errors at compose time.
5. **Daemon ownership ambiguity** — the cutover `engram serve` process is
   shared state, but neither session owned it; SIGTERM during in-place upgrade
   could kill the other session's in-flight requests.
6. **Pre-commit hook stash dance** — cargo-fmt's stash-then-restore silently
   dropped merge commits when the primary session was actively editing, because
   the peer session had unstaged changes the hook didn't know about.

**Missing layer**: peer-discoverable structured state that any cooperating
Claude session can read/write without stepping on each other.

## 2. Design principles

1. **Filesystem-backed for v0**. Zero infrastructure. Survives session crashes
   (the file is still there). Inspectable by `cat` + `jq`.
2. **Operation set isomorphic to Redis primitives**. Every v0 filesystem
   operation maps cleanly to a single Redis command (or Lua script), so v1 is
   a backend swap, not a protocol rewrite.
3. **Opt-in, non-blocking**. A session that doesn't implement coordination isn't
   broken — it just gets no peer awareness. Coord-aware sessions handle
   coord-unaware peers by treating the whole tree as "potentially contended".
4. **Arbitrary opaque blobs**. Every message carries a `blob` field that
   neither sender nor receiver parses — use for experimental / future-proof
   payloads without schema bumps.
5. **Short schemas, loud version bumps**. Schema version is prominent in every
   file; mismatch → other sessions ignore you gracefully.
6. **Liveness is heartbeat-based, not TCP-based**. File mtime + heartbeat
   timestamp + process check. Cheap and distributed-safe.

## 3. Wire format

### 3.1 Session record

```jsonc
{
  "schema": 1,
  "session_id": "c87d1c5c-ee1c-480d-9384-ca2481aa143b",
  "claude_pid": 5865,
  "claude_version": "2.1.92",
  "cwd": "/home/ctodie/projects/reverie",
  "bin": "/home/ctodie/.vscode-server/.../native-binary/claude",
  "started_at": "2026-04-07T09:47:00-04:00",
  "last_heartbeat": "2026-04-07T15:38:00-04:00",
  "owned_resources": {
    "worktrees": ["/home/ctodie/projects/reverie-tod-406"],
    "branches":  ["chris/tod-406-dream-classify"],
    "prs":       [34, 35],
    "processes": {
      "engram_serve_pid": 46183
    },
    "files": []
  },
  "current_task": {
    "ticket": "TOD-406",
    "phase":  "merging PR #34",
    "status": "in_progress"
  },
  "blob": {
    "schema_hint": "claude-coord-v0",
    "notes":       "free-form text",
    "handoffs":    [],
    "announcements": [],
    "custom":      {}
  }
}
```

### 3.2 Lock record

```jsonc
{
  "schema": 1,
  "resource": "main-branch",
  "owner_session_id": "c87d1c5c-...",
  "owner_pid": 5865,
  "acquired_at": "2026-04-07T15:40:00-04:00",
  "expires_at":  "2026-04-07T16:40:00-04:00",
  "reason":  "merging PR #34 to main"
}
```

### 3.3 Message record

```jsonc
{
  "schema": 1,
  "from_session_id": "c87d1c5c-...",
  "to_session_id":   "3443ca93-...",
  "sent_at": "2026-04-07T15:42:00-04:00",
  "kind":    "handoff",
  "subject": "TOD-407 is unblocked",
  "body":    "finished TOD-406 merge, TOD-407 place phase is all yours — scan/classify types are stable in phases/mod.rs now",
  "blob":    {}
}
```

**Message kinds (open set, recognized by convention)**:

- `handoff` — task handoff between sessions
- `warn` — non-fatal advisory ("don't touch X, I'm mid-merge")
- `emergency` — stop-the-line ("main is broken on HEAD~2, roll back")
- `status` — informational broadcast ("dream benchmark running on :17437")
- `request` — ask a peer to do something
- `reply` — answer to a `request`

## 4. Filesystem layout (v0 backend)

```
/tmp/claude-coord/
├── schema                              # file containing "1" — version marker
├── sessions/
│   ├── c87d1c5c-....json                # per-session state
│   └── 3443ca93-....json
├── locks/
│   ├── main-branch/                     # atomic dir = held lock
│   │   ├── owner                        # session id
│   │   └── record.json                  # lock record from §3.2
│   └── engram-serve/
└── messages/
    ├── inbox-c87d1c5c/                  # one dir per destination session
    │   └── 2026-04-07T15-42-00Z-001.json
    └── inbox-3443ca93/
```

- **Atomic lock**: `mkdir` of the resource dir is the atomic primitive. If
  `mkdir` succeeds, you own the lock. Release via `rm -rf`.
- **Message ordering**: filename prefix is an ISO timestamp + sequence number,
  so sorted directory listing is the delivery order.
- **Schema file**: single-line version. All sessions writing under
  `/tmp/claude-coord/` MUST check `cat schema` first and refuse if mismatched.

## 5. Operation set (the stable API)

| Op | Shell | Redis equivalent (v1) | Notes |
|---|---|---|---|
| register | `coord register [--task ...]` | `HSET coord:session:<id> ...; ZADD coord:sessions <now> <id>` | Idempotent. |
| heartbeat | `coord heartbeat` | `HSET coord:session:<id> last_heartbeat <now>; ZADD coord:sessions <now> <id>` | Call every 30s. |
| peers | `coord peers [--live]` | `ZRANGEBYSCORE coord:sessions <now-5m> +inf` | `--live` filters stale. |
| lock | `coord lock <resource> [--ttl 1h] [--reason ...]` | `SET coord:lock:<r> <id> NX EX <ttl-sec>` | Blocks until acquired or timeout. |
| unlock | `coord unlock <resource>` | Lua: `del only if value == <id>` | Owner-only. |
| steal | `coord steal <resource>` | Lua: `del only if ttl expired OR owner pid dead` | Recovers stuck locks. |
| send | `coord send <peer> <kind> <subject> [--body ...]` | `LPUSH coord:inbox:<peer> <msg>` | Fire and forget. |
| recv | `coord recv [--drain]` | `RPOP coord:inbox:<self>` (or LRANGE) | Non-blocking. |
| update | `coord update [--task ...] [--status ...] [--blob ...] [--merge-blob]` | `HSET coord:session:<id> ...` | Patch own session record (task, status, blob) without full re-register. |
| broadcast | `coord broadcast <kind> <subject> [--body ...] [--live-only]` | `for peer in SMEMBERS coord:sessions: LPUSH coord:inbox:<peer> <msg>` | Send a message to every peer (optionally only live ones). |
| dereg | `coord dereg` | `DEL coord:session:<id>; ZREM coord:sessions <id>` | On session end. Alias: `coord deregister`. |
| log | `coord log [tail\|stats\|locks\|session] [...]` | — | Query the audit log. Subcommands: `tail` (filter + tail entries), `stats` (op counts + lock-hold percentiles), `locks` (lock/unlock/steal history), `session <id>` (all events for a session). |
| metrics | `coord metrics` | — | Prometheus-format metrics: live sessions, held locks, message counters. |
| project-lock | `coord project-lock <project> [--area X]` | `SET coord:lock:project:<p>[:<a>] <id> NX EX <ttl>` | Convenience over `lock`; tags scope=project. |
| project-unlock | `coord project-unlock <project> [--area X]` | (same as unlock) | Owner-only release. |
| status | `coord status` | — | Human-readable dump of own state. |

All operations return exit code 0 on success, non-zero on error, with JSON on
stdout and human-readable text on stderr. Machine-friendly, human-inspectable.

## 6. Liveness and stale cleanup

A session is **stale** if:

- `now - last_heartbeat > STALE_HEARTBEAT_THRESHOLD` (default 5 minutes), OR
- `kill -0 $claude_pid` fails (process gone), OR
- `claude_pid` is reused by a different command (check `/proc/$pid/comm` if
  Linux; fall back to process age if macOS).

A **lock is revocable** if:

- Its owner session is stale, AND
- `now > record.expires_at`, AND
- At least 10 minutes have elapsed since acquisition.

Any live peer can call `coord steal <resource>` to break a stuck lock. The
steal is logged in the broken lock's `record.json` before unlink so there's an
audit trail.

## 7. Coordination rules for Claude sessions

### At session start

1. `coord register --task <description>` — write own session file
2. `coord peers` — enumerate live peers; if any, surface them in the first
   response to the user (e.g., "There are 2 other Claude sessions running on
   this repo: c87d... in /projects/reverie, 3443... resuming my session.")
3. Start a heartbeat loop: `coord heartbeat` every 30s via a backgrounded
   shell process or a hook firing on every tool call.

### Before any shared-state action

| Action | Lock | Rationale |
|---|---|---|
| `git checkout main` | `main-branch` | Prevent lost work |
| `git push main` | `main-push` | Prevent race |
| `gh pr merge N` | `pr-merge-queue` | Prevent `UNKNOWN` mergeability races |
| `cargo build` on main worktree | `cargo-build` | Prevent CPU thrash + target/ corruption |
| Modify `~/.claude/*` | `claude-config` | Prevent lost writes |
| `kill` or `mv` on `~/.local/bin/engram` | `engram-serve` | Daemon cutover safety |
| Spawn a background agent | (register under `owned_resources.agents`) | Peer awareness |
| Edit/merge files in a shared project tree | `coord project-lock <project> [--area X]` | Serialize peer sessions on the same files without going through the coarse `main-branch` lock |

### Project merge locks

Two cooperating sessions touching the same repo collide most often *inside* a
single file region (e.g. both editing `engram_compat.rs` while rebasing
adjacent PRs). The `main-branch` lock is too coarse — it blocks unrelated work
on other crates. Project locks give a middle granularity:

- `coord project-lock <project>` — whole-project lock; resource id
  `project:<project>` (e.g. `project:reverie`). Use when rewriting many files
  or running a global format pass.
- `coord project-lock <project> --area <area>` — area-scoped lock; resource id
  `project:<project>:<area>` (e.g. `project:reverie:engram_compat`,
  `project:reverie:dream-runner`). Use when you know exactly which file or
  module you're going to touch.

`area` is a free-form slug — convention is the crate or module name, no path
separators. Two sessions on different `--area` values acquire independently;
two on the same `--area` serialize. The whole-project lock and any area lock
are *independent* — they do not currently nest. If you need exclusion across
all areas, take the whole-project lock.

Lock records carry `scope: "project"` so peers can filter project locks out of
`coord status` when they only care about cross-cutting locks like
`pr-merge-queue`.

### On tool errors that look suspicious

Before retrying a failed git/gh/cargo op, run `coord peers` to check if a peer
is doing the same thing. If so, wait for their lock to release instead of
fighting.

### At session end

`coord dereg` removes own session file and releases all held locks. Session
crashes (no dereg) are handled by the stale cleanup rule in §6.

## 8. Multi-host evolution path

### v0 (this doc) — local filesystem

- Backend: `/tmp/claude-coord/`
- Works across WSL/Linux/macOS on one host
- No dependencies, zero setup
- Single-user (filesystem permissions)

### v1 — Redis

Swap `coord` binary's backend from filesystem to Redis via a backend enum
selected by `COORD_BACKEND=redis` + `COORD_REDIS_URL=redis://...`.

Mapping (already canonicalized in §5):

```
coord register  → HSET coord:session:<id>; ZADD coord:sessions <now> <id>
coord heartbeat → HSET coord:session:<id> last_heartbeat <now>; ZADD ...
coord peers     → ZRANGEBYSCORE coord:sessions <now-5m> +inf
coord lock      → SET coord:lock:<r> <id> NX EX <ttl>
coord unlock    → EVAL "if redis.call('GET', K) == ARGV[1] then DEL K end"
coord steal     → Lua: DEL only if ttl expired
coord send      → LPUSH coord:inbox:<peer> <msg>
coord recv      → LRANGE then DEL (or RPOP in loop)
coord dereg     → DEL + ZREM
```

**Benefits**:
- Atomic ops are single commands — no `mkdir` gymnastics
- `BLPOP` gives real push semantics (recv can block with timeout)
- `PUBLISH`/`SUBSCRIBE` enables push notifications for cross-session events
- Cluster-capable (multiple hosts coordinate via shared Redis)

**Cost**:
- Requires Redis running (single-node for dev; replicated for prod)
- Network hop per op (negligible on LAN, painful on high-latency VPN)

### v1 alt — NATS JetStream

Similar mapping but uses NATS primitives:
- KV bucket for sessions and locks (atomic ops built-in)
- Stream per inbox (persistent, replayable, TTL-managed)
- PubSub for real-time peer events

Better for "truly multi-host, potentially across WAN" because NATS has
first-class clustering + leaf nodes + JetStream file-backed persistence.

### v1 alt — Postgres

For installations that already run Postgres:
- Table `coord_sessions` with trigger on UPDATE for stale cleanup
- `SELECT ... FOR UPDATE SKIP LOCKED` for lock acquisition
- `LISTEN`/`NOTIFY` for push events
- Full SQL observability — any peer can query history

### v2 — HTTP gateway

For sessions in browser tabs or locked-down environments where local FS + Redis
both unavailable: stand up a small HTTP gateway (Cloudflare Worker + KV for
storage) that exposes the coord API as JSON-RPC. Latency ~50ms vs ~1ms local,
but unblocks hostile environments.

## 8a. Schema evolution and migrations

The v0 schema is intentionally shaped like a protobuf message — field numbers
are reserved in comments on the JSON Schema, and a draft `.proto` file ships
alongside it at `docs/coord/coord.proto`. When v1 Redis/NATS lands, the
migration to real protobuf is mechanical (`protoc --rust_out=...`), not a
design exercise.

Full migration rules, version history, compatibility matrix, and the
`coord migrate` subcommand design: `docs/coord/migrations.md`.

**TL;DR**:
- JSON for v0, protobuf-shaped. `.proto` co-located, not compiled.
- Never rename a field. Never reuse a field number. Add new; deprecate old.
- `schema: <int>` in every record. Bump on breaking changes.
- Unknown fields preserved via `blob._unknown` for forward compat.
- `coord migrate` is a no-op today; real migrations land alongside schema 2.
- Protobuf cut-over happens at v1 (first network-backed implementation).

## 9. Binary + schema artifacts

Shipped alongside this doc:

- **`~/.claude/bin/coord`** — shell implementation of the v0 backend (bash +
  `jq`). ~200 LOC. Single file, self-contained. Drop into `$PATH`.
- **`~/.claude/coord/schema-v0.json`** — JSON Schema (draft 2020-12) for the
  session + lock + message records in §3. Machine-validatable.
- **`~/.claude/CLAUDE.md`** addendum — global rule that all Claude Code
  sessions on this machine MUST register + heartbeat + acquire locks before
  shared-state actions.

See `~/.claude/bin/coord --help` and `~/.claude/coord/schema-v0.json` for the
concrete artifacts.

## 10. Forward compatibility (v0 → v1)

The shell binary, schema, and global rule ship TODAY. v1 is a pure backend swap
— no caller (Claude session) code changes required. The trigger to ship v1 is:

1. Two Claude sessions on different hosts need to coordinate, OR
2. Local filesystem becomes a performance bottleneck (hundreds of heartbeats
   per minute), OR
3. A user wants audit history of coordination events (v0 forgets on reboot)

Until one of those is true, v0 is enough.

## 11. Open questions

- **Should `coord` be a Rust binary** (compiled from `crates/reverie-coord`)
  instead of shell? Pros: cross-platform without bash, typed, testable.
  Cons: compilation step, more moving parts for a v0. **Decision**: start
  with shell, port to Rust when the shell hits its limits (probably around
  the v1 Redis backend when we need a Redis client).
- **How do we handle Claude Code itself crashing between `register` and
  `dereg`**? The stale cleanup in §6 handles it eventually (5 min + 10 min
  lock timeout), but there's a window where peers see a ghost. **Mitigation**:
  emit a dereg on the Claude Code `exit` hook if one exists, fall back to
  heartbeat expiry.
- **Locking granularity**: is `main-branch` too coarse? Should we have
  `main-read` vs `main-write`? **Decision**: start coarse, refine when contention
  actually warrants it.
- **What about worktrees?** Each worktree has its own index and can hold its
  own locks without colliding on the primary's. We track worktrees under
  `owned_resources.worktrees` but don't lock them separately for v0.

## 12. Trigger conditions for this doc

File as a follow-up Linear ticket. The doc + binary ship when:

- User explicitly approves (this session), OR
- A third Claude session joins the primary + peer and causes a visible
  collision

Target: ship v0 tonight, observe for 1 week, then either promote to v1 Redis
or declare v0 sufficient.
