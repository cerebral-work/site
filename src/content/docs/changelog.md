# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- engram-backup.timer systemd user unit — runs `engram backup` every 6 hours with Persistent=true so missed triggers replay; installed via `make install-systemd`

### Fixed
- mesh-spawn wrapper now supervises `claude -p` with quadratic backoff + 20-restart cap (TOD-724); sync installed copy with repo via `make install-mesh`

## [0.6.1] - 2026-04-16

### Added
- **M12 complete — T64**: Graceful degradation when engram DB is down. `/health` stays 200, `/search` returns empty, dream cycles retry with backoff.
- **meshctl dash**: 3-line activity tail per worker (green tools / blue message types), git-tree column (`⚙ N ahead` + newest commit subject), blank separator between workers. JSON exposes `activity_tail[]`, `commits_ahead_main`, `newest_commit`.

### Fixed
- **mesh-spawn queue drain loop** now calls `coord heartbeat` per iteration — fixes false-positive "Dead" status on queue workers that were still executing tools but not refreshing `last_heartbeat`.

## [0.6.0] - 2026-04-16

### Added
- **M7 complete — Domain model & DDD migration**
  - T41: `EngramCompatStore` implements `ObservationReader`, `ObservationWriter`, `SearchBackend`, `TagStore`, `SessionRepository` from reverie-domain
  - T42: `ChunkMetadata` value object — neuroscience fields (strength, depth_score, session_spread, stability, consolidation_status) extracted from the domain Observation
  - T43: `ChunkKind`, `Layer`, `LayerRef` migrated to reverie-domain
- **M9 closed — Dream pipeline v2**
  - T52: Consolidation-status transitions (Staged→Consolidated→Archived) in the place phase
  - T53: `DreamJournal` struct — structured markdown + JSON run reports
- **M10 complete — Mesh coordination & file locking**
  - T54: File-lock integration tests (`scripts/file-lock-tests.sh`)
  - T55: File-lock metrics — emit `lock.acquired/released/conflict` to Redis fanout
  - T56: `file-lock detect-cycles <project>` — wait-for graph deadlock detection
  - T57: `crates/reverie-lock` — Rust port of the bash file-lock script
- **M11 follow-ups**
  - T59: Structured span attributes on dream cycle phases (duration, candidates, counts)
- **M12 partial — Production hardening**
  - T61: Chunk schema versioning enforced on deserialize with v1→v2 migration path
  - T62: `reveried backup` / `reveried restore` subcommands + pre-dream auto-backup
  - T63: Dream-cycle rate limiting (30min min interval, queue-1, skip-if-running)
- **Mesh automation**
  - `mesh-reap` script + systemd user timer — auto-reap dead sessions, orphan tmux, empty worktrees every 2 min (closes TOD-599)
  - Headless spawn by default in `mesh-spawn` — workers run via `setsid` instead of tmux, only the anchor keeps a tmux session
  - Fan-out queue pool — `mesh-spawn --queue` drain-loop workers that pull tasks from the Redis mesh queue; one Claude session drains N tasks (saves ~50% cold starts)
  - `meshctl init` expands from 7→9 steps: adds auto-reaper enable (step 4) and fan-out pool spawn (step 6). Flags: `--skip-reaper`, `--queue-workers <N>`
- **meshctl dash**
  - Per-session last-activity line (tool name + age from Claude jsonl logs) — surfaces false-positive "Dead" status on queue workers that haven't heartbeated but are still working
  - Respects `$COLUMNS` env for detached tmux sessions; clamps crossterm-reported width to [40, 160]
  - `Done` health status (cyan) distinct from `Dead` — workers that marked `blob.completed=true` but are idle post-task
- **Automation agents**
  - `~/.claude/agents/mesh-fan-out/AGENT.md` — dispatches backlog tickets to builder pool
  - `~/.claude/agents/reverie-deploy/AGENT.md` — build → deploy → verify → optional push/release
- **Tooling/CLI**
  - Dream CLI phases shipped (TOD-677): `reveried scan/classify/place/prune`
  - Subagent-stop auto-capture hook shipped (TOD-405)

### Fixed
- **coord register/heartbeat** preserves top-level `role` field on session rewrite (TOD-501)
- **meshctl dash** task-phase extraction reads `current_task.phase` instead of the missing `task` field
- **meshctl dash** `--json` mode and non-TTY mode (piped output) — was crashing with ENXIO
- **Deploy path**: scripts that copied to `~/.local/bin/engram` missed the actual systemd target `~/.local/bin/reveried`. Deploy agent now writes both.
- **reveried tests** — serialize env-mutation tests behind a `Mutex` (was flaky on parallel CI)
- **meshctl libc** dep added (was calling `libc::kill` without declaring the crate)

### Security
- **cargo-deny**: bumped `bitstream-io` to drop yanked `core2` transitive dep; bumped `rand` 0.8→0.9.4 (fixes RUSTSEC-2026-0097); bumped `opentelemetry` 0.27→0.31; allowed `BSL-1.0` for redis 1.2's `xxhash-rust`
- **rustls-webpki** 0.103.10→0.103.12 (RUSTSEC-2026-0098, RUSTSEC-2026-0099)

### Changed
- **Dependencies**: `redis` 0.27→1.2, `toml` 0.8→1.1, `procfs` 0.16→0.18, GitHub Actions bumps (checkout@6, upload-artifact@7)
- **CLAUDE.md**: added knowledge-placement SOP, agent/worker lane rules, pre-commit discipline
- **Milestone v0.5.0** (Linear) renamed to `v0.7.0 — Learned Intelligence Layer` to free the label for the shipped v0.5.0 release

### Reverted
- Repo split into separate meshctl repo — both crates stay in the reverie workspace (cancels TOD-712, TOD-719)

## [0.5.0] - 2026-04-15

### Added
- **M8 complete — Multi-factor scoring engine**
  - T44: Strength as post-RRF multiplier in hybrid search
  - T45: Depth weight (episodic 0.8x, consolidated 1.0x, semantic 1.2x)
  - T46: Session spread weight `ln(1+spread)/ln(2)` for cross-session signal
  - T47: Ebbinghaus stability decay in hybrid search ranking
  - T48: Feature flags for all lifecycle scoring factors (strength/depth/spread/stability)
- **M9 complete — Dream pipeline v2**
  - T49: SHY downscale phase (0.95x global scale, min_strength_floor pruning)
  - T50: Ebbinghaus stability updates as StabilizePhase (SM-2 inspired formula)
  - T51: Depth score promotion/demotion in place phase (1→2→3 with activity thresholds)
  - T52: Consolidation status transitions (Staged→Consolidated→Archived)
  - T53: DreamJournal structured output (markdown + JSON aggregated reports)
- **M11 complete — Observability**
  - T58: `#[instrument]` tracing spans on all async HTTP handlers
  - T59: Structured span attributes on dream cycle phases (duration, counts, candidates)
  - T60: Prometheus metrics for scoring pipeline (search duration, factor counters, dream histograms)
- **M12 partial — Production hardening**
  - T62: `reveried backup` / `reveried restore` subcommands + pre-dream auto-backup
  - T63: Dream cycle rate limiting (30min min interval, queue-1, skip-if-running)
- **M7 partial — Domain model**
  - T43: Migrate ChunkKind, Layer, ConsolidationStatus to reverie-domain crate

### Fixed
- **meshctl dash TUI**: Terminal-width-aware rendering, ANSI-aware line truncation, non-TTY loop mode, `--json` output, `current_task.phase` extraction
- **CI**: Updated bitstream-io 4.9→4.10 to drop yanked core2, removed stale license allowances from deny.toml

## [0.4.1] - 2026-04-15

### Added
- **`meshctl dash`** — Live terminal health dashboard polling coord sessions every 2s. Shows role, PID, health (Working/Idle/Dead with color), heartbeat age, dirty files, and task phase.
- **Auto-respawn CLI flag** — `reveried serve --auto-respawn` enables sleeper rebound for flatlined workers. Expanded `CANONICAL_ROLES` to include memory, release, security, and research roles.
- **Hybrid search: depth_weight** (T45) — Depth-based scoring in `ChunkStore::hybrid_search()`: episodic (depth=1) → 0.8x, consolidated (depth=2) → 1.0x, semantic (depth=3) → 1.2x.
- **Hybrid search: spread_weight** (T46) — Cross-session signal: `ln(1 + session_spread) / ln(2)`. Chunks accessed across many sessions rank higher.

### Fixed
- **meshctl libc dependency** — Added missing `libc` crate dependency for `pid_exists()` function.
- **Clippy lints** — Fixed `nonminimal_bool`, `write_literal`, `collapsible_if` in meshctl dash code.

### Security
- **rustls-webpki** — Updated 0.103.10 → 0.103.12 (RUSTSEC-2026-0098, RUSTSEC-2026-0099: URI name constraint and wildcard name constraint bypass).

## [0.4.0] - 2026-04-10

### Added
- **MeshState types + StateReducer** — Typed graph state (`task_id`, `phase`, `outputs`, `checkpoint`) with merge semantics. `StateUpdate` variant in `SleeperMessage`. Foundation for all graph abstractions. (`reverie-domain`)
- **MeshNode trait + DispatchedNode** — Async node interface for graph execution. `DispatchedNode` wraps coord send/poll into typed node. `PassthroughNode` for testing. (`meshctl`)
- **MeshGraph engine** — Conditional edge routing with `EdgeCondition` predicates. `MeshGraphBuilder` with fluent API and validation. Cycle guard (100 steps). `single_node_graph` bridge for backward compat. (`meshctl`)
- **Subgraph composition** — `SubgraphNode` (nested graph as node) + `AggregateNode` (parallel fan-out with `merge_union`). Enables complex multi-role orchestration workflows. (`meshctl`)
- **Plan-and-execute** — `meshctl execute --decompose` decomposes directives into subtask DAGs via heuristic planner. `Plan`/`PlannedTask` types with role routing per subtask. (`meshctl`)
- **Graph-aware checkpoints** — Extended `Checkpoint` with `current_node`, `edge_to`, `mesh_state` for graph resumption. `GET /checkpoints/resume/:task_id` endpoint. (`reveried`)
- **Coord protocol graph extensions** — `--output` on reply (typed `MeshState`), `--graph` on request (graph context), `--graph-state` on register (`blob.graph_state`). Backward-compatible.
- **Sleeper rebound activation** — `on_health_event` wired to `try_respawn`. Agent watcher emits per-agent `sleeper_flatline` events. Rebound loads dream journal checkpoint and injects into respawned worker.
- **SleeperMessage into coord protocol** — `coord send --type` flag (task/ping/reply/fault/checkpoint), `coord recv --parse` extracts type field. Executor uses typed dispatch.
- **Dream journal lifecycle hook** — `PostToolUse` handler in `worker-lifecycle-hook.sh` POSTs checkpoints to reveried. Fire-and-forget via background curl.

### Fixed
- **Mutex poison recovery** — Replaced `.expect("state poisoned")` with `.unwrap_or_else(|e| e.into_inner())` + warning log in event handlers. Daemon no longer panics on recoverable state.

### Security
- **HTTP input validation** — `DefaultBodyLimit` 10MB globally. Session ID validation (128 chars, alphanumeric). Search query length limits. Returns 400 for invalid input.

## [0.3.1] - 2026-04-10

### Added
- **Sleeper abstraction** — Renamed "pseudoagent" to "sleeper" across codebase, aligning with neuroscience theme. Added `SleeperWake`/`SleeperAck` event variants with `WakeMethod` enum. New `docs/architecture/sleepers.md` spec with sleep-biology vocabulary.
- **SleeperMessage typed inbox** — `SleeperMessage` enum in `reverie-domain` with 5 variants (Task, Ping, Reply, Fault, Checkpoint), `Priority`/`TaskStatus` enums, backward-compatible `parse()` for legacy JSON.
- **Sleeper rebound infrastructure** — `SleeperRebound` handler with per-role circuit breaker (max 3/hour), 30s grace period, `SubToken::noop()` for disabled state. Infrastructure-only — `on_health_event` activation deferred to v0.4.0.
- **Dream journal checkpointing** — `POST/GET /checkpoints` endpoints in reveried for persisting sleeper task progress. Keyed by `session_id`, TTL-based expiry, `by-role` lookup route.
- **Heartbeat semantics split** — Split `last_heartbeat` into `last_poked_at` (anchor) + `last_acked_at` (sleeper). Backward-compatible dual-write. AgentWatcher prefers `last_acked_at` for staleness.
- **Capability-based routing** — `meshctl route <task>` scores roles by keyword overlap with declared capabilities + idle-time bonus from coord sessions.
- **Executor semantics** — `meshctl execute <directive>` dispatches to best-fit sleeper via coord, polls for reply with exponential backoff retry (configurable timeout/retries).
- **Composable role specs** — YAML `traits:` section in mesh-roles config. Traits define reusable capability/tool sets; roles inherit via `traits: [...]` with deduplication.
- **README overhaul** — CI/license/MSRV badges, "Why Reverie?" section, grouped 15-crate workspace table (Core/Mesh/Observability/Benchmark), expanded quickstart.

### Fixed
- **coord register/heartbeat role preservation** (#61) — Re-register now uses read-modify-write to preserve `role` field. `blob_extra` defaults to `{}` instead of empty string.
- **mem_save FK constraint** (#60) — Lazy session creation via `INSERT OR IGNORE` on first observation. Removed duplicate INSERT using raw `p.session_id`.
- **Rate-limit sharding** (#62) — Rate limit key sharded by `project:session_id`. Each mesh worker gets its own 10/min bucket. Empty session_id falls back to global bucket.
- **meshctl init layout** — Replaced `tmux split-window -p` (fails in non-TTY) with `-l` absolute sizing.

### Changed
- **meshctl init** cold-boot layout uses absolute pane sizes instead of percentage-based splits.

## [0.3.0] - 2026-04-10

### Added
- **8-factor scoring engine** — Multi-factor retrieval scoring replacing
  simple RRF + time-decay. Factors: semantic, lexical, recency, resonance
  (Ebbinghaus stability), importance (kind-weighted), session spread,
  hippocampal pattern separation, emotional valence. Configurable weights.
- **Hippocampal encoding** — DG sparse pattern separation (1024→4096-dim,
  5% sparsity), CA1 novelty detection, CA3 pattern completion. Hamming
  distance for orthogonality checks.
- **Emotional valence** — 4D valence (urgency, certainty, blast_radius,
  relevance) on observations. Heuristic computation on ingest.
- **Procedural memory** — Learned workflows with steps, triggers,
  proficiency tracking. Domain entity + store variants + bench scenarios.
- **Entity/relationship graph** — Named entities (person/project/tool/concept)
  with aliases, entity links to observations, coreference resolution.
- **Metacognitive audit** — 7 health checks (recency bias, staleness,
  duplication, layer misplacement, write churn, orphan rate, topic
  concentration). CLI: `reveried audit [--fix]`.
- **Token-budget search** — `search_within_budget()` greedy-fills results
  within a token budget. Engram-compat endpoint.
- **Time-decay in engram-compat** — Port BM25 time-decay boost to the
  production search path (TOD-633/T37).
- **Neuroscience fields on Observation** — strength, stability, depth_score,
  session_spread, access_count, consolidation_status. Wired into sqlite-vec
  schema + scoring.
- **Domain model extensions** — ConsolidationStatus enum, Valence value
  object, Entity/EntityLink types, Procedure/Step/Trigger types,
  ScoringFactors/ScoredHit, 6 new repository trait ports.
- **Dream cycle feedback loop** — Consolidate phase persists strength
  deltas, place phase persists depth_score promotions, reconsolidation
  bumps stability on access.
- **Ablation benchmarks** — 8-config ablation matrix, CORTEX-style
  leaderboard table, regression gates per phase.
- **meshctl status** — Worker columns (type/dirty/commits/locks), MESH
  aggregate counters, COST line from mesh-cost, SESSION line (model/
  context/tokens/turns), QUEUE line (pending/inflight/done/dead), TRACE
  section (eBPF kernel events from reverie-tracee), GPU VRAM usage,
  OpenRouter balance. Flicker-free pane rendering.
- **meshctl sessions** — Subcommands: clean (kill dead sessions, release
  orphan locks, remove empty worktrees), up (spawn canonical workers),
  down (teardown all workers).
- **meshctl init** — Rewritten to use mesh-spawn with deterministic
  registration. 5 canonical roles with worker types.
- **Mesh tooling** — mesh-spawn (worker lifecycle, --queue drain loop),
  mesh-enqueue (Redis stream XADD), mesh-drain (queue monitoring),
  mesh-cost (per-worker token tracking), mesh-heal (self-healing
  watchdog for 10 services), file-lock (file-level contention).
- **Job queue** — Redis STREAM-based task queue with consumer groups.
  Workers pull tasks via XREADGROUP, ACK on completion, dead letter
  on failure. Persistent drain loop mode.
- **Kernel tracing** — aquasec/tracee privileged container for eBPF
  events, reverie-tracee consumer aggregates per-process, wired into
  meshctl status.
- **Self-healing** — mesh-heal monitors reveried, redis, memcached,
  prometheus, grafana, tracee, ollama, coord-keeper. Auto-restart on
  failure, 60s loop.
- **Worker lifecycle hooks** — Stop hook auto-deregisters from coord
  and releases file locks. PreToolUse hook blocks edits on locked files.
- **reverie-domain** — New crate for pure DDD types and repository traits
  (TOD-635). Hexagonal architecture: domain types (`Observation`,
  `ObservationId`, `TopicKey`, `Chunk`, `Tag`), repository traits, and
  error types. No runtime dependencies — pure domain modeling.
- **reverie-discovery** — New crate for shared service endpoint resolution.
  Layered chain: env var → systemd unit parsing → well-known defaults.
  Replaces hardcoded ports across meshctl, meshctl-tui, reverie-status-tui.
  7 unit tests + 1 doctest.
- **tracee start** — New `start` subcommand for tracee with auto-start in
  `run`. Simplifies daemon lifecycle management.
- **meshctl svc** — Dynamic service reflection from systemd user units.
  Subcommands: list, port, url, bind, status, health, env. JSON output
  for scripting (`--json`).
- **meshctl init step 3** — Auto-start reveried via systemd if not running.
  Health-check with 5s timeout, fail hard if unreachable.
- **release.yml** — CI/CD release pipeline with feature gate. Tag-triggered
  (`v*` or `<crate>-v*`), validates version against Cargo.toml, checks
  CHANGELOG entry, runs full CI, packages binaries, creates GitHub Release.
- **Independent crate versions** — Tier A publishable crates (store, dream,
  gate, sync, chunk, discovery, proto) get independent semver. Tier B internal
  crates get `publish = false`.

### Changed
- **workspace deps** — Converted all inter-crate dependencies to workspace
  references for consistent version management.
- **meshctl init** — Renumbered from 6 to 7 steps (new reveried ensure step).
  Ollama and reveried URLs resolved dynamically via reverie-discovery.
- **meshctl init** — Step 7 (was 6) sets up a canonical `reverie-anchor` tmux
  dashboard layout: 70% main pane, 30% right split for live `meshctl status -p`
  and reveried log tail, plus a full-width heartbeat ticker bar at the bottom.
  New `--attach` flag execs into the anchor session after init completes.

### Fixed
- **store: tag reads** — Tags now returned on `GET /observations/:id`;
  `PATCH` correctly replaces tags instead of appending (TOD-632).
- **store: search_by_tag** — Added `supersedes`/`superseded_by` columns to
  search_by_tag query, fixing column index 17 panic.
- **health endpoint** — Use `CARGO_PKG_VERSION` instead of hardcoded version
  string; add `serde_yaml` workspace dependency.
- **meshctl-init.yml** — Stale port 3031→7437 for reveried health check.

### Documentation
- **ADR-005** — Search cutover plan + M6 backlog milestone (TOD-633, TOD-634).
- **Backlog grooming** — Mark T22/T23 done, T33 superseded, update T30 status.

### Chore
- **MIT hygiene** — NOTICE, DCO, SECURITY, CODEOWNERS, SPDX headers, publish
  guards across all crates.

## [0.2.0] - 2026-04-09

### Added
- **TOD-584** — Structured multi-tag system with faceted tag table. New
  `chunk_tags` SQLite table keyed on `(chunk_id, facet, value)` with indexes
  on facet+value and chunk_id. Store methods: `add_tags`, `remove_tags`,
  `get_tags`, `search_by_tag`. MCP `mem_save` accepts optional `tags` array
  of `{facet, value}` objects. MCP `mem_search` accepts optional `facet` and
  `tag_value` parameters for tag-filtered queries. Five standard facets
  (Domain, Project, Phase, Role, Severity) documented but not enforced.
  Fully backward compatible — existing observations work without tags.
- **TOD-486** — `/mem-distill` skill (`scripts/mem-distill.sh`) for end-of-session
  reverie observation consolidation. Pulls recent observations via engram
  `/context/smart`, clusters by topic_key prefix (strips date/version suffixes),
  summarizes each cluster via `~/.local/bin/llm-task summarize` (gemma4:26b,
  zero cloud cost), and stages anchor observations as JSONL to `/tmp` for
  operator review before `mem_save`. Args: `--since 6h --project reverie
  --dry-run --max-anchors 3`. SKILL.md install to `~/.claude/skills/` requires
  `coord lock claude-config` — defer to operator post-merge.
- **TOD-487 Phase 1** — `crates/reverie-llm-router/` skeleton with `LlmBackend`
  trait, `CompletionRequest`/`CompletionResponse`/`Message` types, and a
  `LocalLlama` backend that talks to any OpenAI-compatible local server.
  Defaults to the wizard's `reverie-ollama` container at `localhost:11434`
  running `qwen3-coder:30b` (RTX 5090, GPU). Integration test
  `tests/local_llama_smoke.rs` verified end-to-end against the live ollama
  instance (~14s round-trip, model returned `PROXY OK`). Phase 2 adds the
  `Router` + `RoutingPolicy`; Phase 3 wraps it as an MCP server.
- **TOD-394** — Production-grade in-place upgrade infrastructure.
  New `reveried upgrade` subcommand orchestrates a graceful handoff:
  verifies a new binary, backs up the old one, atomically swaps it into
  place, SIGUSR2s the running daemon, polls `/health` reading the
  `X-Reveried-Pid` response header until it reports the new PID, and
  rolls back on failure. Under the hood, `serve_with_handoff` replaces
  `http::serve` on the hot path: binds the listener with `SO_REUSEPORT`
  so old and new daemons can co-bind the same port, writes a pidfile at
  `~/.local/state/reveried/serve.pid`, layers the `X-Reveried-Pid` header
  onto every response via `tower-http::set-header`, and runs a SIGUSR2
  handler that fork+execs `current_exe()` and triggers axum graceful
  shutdown. Engram had no upgrade pattern — this is greenfield.
  Complements the systemd supervisor + autoupgrade timer shipped under
  TOD-393 (PR #57): the systemd path handles crash recovery + scheduled
  upgrades, this path handles zero-downtime in-process upgrades for
  hot-deploys.
- **make dev** — cargo-watch target that rebuilds reveried on every
  source change (watching reveried, reverie-store, reverie-sync,
  reverie-gate) and then invokes `scripts/dev-restart.sh` for an atomic
  binary swap + health check. Override `REVERIED_PORT` / `REVERIED_BIN`
  to run against a dev port without touching `:7437`.
- **scripts/dev-restart.sh** — atomic dev-time daemon restart. Reads
  PID from the pidfile, falls back to `pgrep`, TERM-then-KILL, respawns
  via nohup, polls `/health` for up to 5s, reports elapsed time to
  healthy state.
- **TOD-455** — Operator dashboard scaffold (phase 1): SvelteKit app at
  `apps/dashboard/` with Tailwind dark theme, 7 mock-data panels (peers,
  locks, work queues, event stream, alerts, metrics sparklines, reverie
  observations), and a `reveried serve --dev` flag that binds the HTTP
  daemon to port 7438 with permissive CORS for `localhost:5173`. Vite
  HMR round-trip measured at ~36ms.
- **TOD-456** — `coord register --role <name>` and `--blob '<json>'` flags.
  `--role` seeds `blob.role` on the initial atomic write. `--blob` shallow-
  merges a JSON object onto the seeded blob; rejects arrays, scalars, and
  null with a clear error. Both apply on first register — no follow-up
  `coord update` round-trip needed. 9-test suite at
  `scripts/coord_register_metadata_test.sh`.
- **TOD-448** — Backfill `coord broadcast`, `coord project-lock`, and
  `coord project-unlock` in `docs/coord/protocol-v0.md`. Adds rows to the
  §5 operation table and a new §5a "Detailed subcommand reference"
  section documenting synopsis, semantics, error cases, and example
  usage for each. Unblocks the TOD-446 `coord-docs-sync` CI check.
  Doc-only — no `scripts/coord` changes.
- **TOD-431** — `coord update` subcommand for mutating session
  state without re-registering. Supports `--task <phase>`,
  `--status <pending|in_progress|blocked|done>`, `--blob '<json-obj>'`
  (replace), and `--blob '<json-obj>' --merge-blob` (shallow merge).
  Refuses non-object blobs, lone `--merge-blob`, unknown flags, and
  missing session records. Writes are atomic via same-directory
  `mktemp` + `mv` so concurrent readers never see partial JSON. Tests
  in `scripts/coord_update_test.sh` (13 cases).
- **TOD-430** — `scripts/coord` is now tracked in the repo (mirroring the
  installed `~/.claude/bin/coord` binary) along with `scripts/coord-tests.sh`,
  a 33-case test suite covering strict-flag parsing across every subcommand.
- **TOD-441** — Coord audit log + observability. `scripts/coord` now
  appends a JSONL record to `$COORD_ROOT/audit.log` for every mutating
  op (`register`, `dereg`, `heartbeat`, `lock`, `unlock`, `steal`,
  `send`, `recv`, `project-lock`, `project-unlock`), with atomic
  rename-based rotation at 10 MiB (3 files kept). New `coord log
  tail|stats|locks|session` query subcommand and `coord metrics`
  Prometheus endpoint (`coord_sessions_live`, `coord_locks_held`,
  `coord_messages_sent_total`, `coord_messages_received_total`).
  Full schema in `docs/coord/observability.md`; protocol doc updated
  with §9b. Pure bash + jq, no new deps. Tests in
  `scripts/coord_audit_log_test.sh` (13 cases, all passing).

### Fixed
- **TOD-459** — `scripts/coord` no longer collapses subagent sessions
  onto their parent's record. The session-id resolver now honors a
  `COORD_SUBAGENT_ID` env var (suffixing derived ids as
  `claude-pid-<N>-sub-<tag>`) and a new `coord register --as-subagent
  <name>` flag, plus an explicit `COORD_SESSION_ID` override at the top
  of the precedence chain. Previously, every subagent walked the same
  `/proc/$$` PPid chain to the parent Claude pid and stomped the
  parent's task / heartbeat fields on every `coord register` call. New
  6-case regression suite in `scripts/coord_subagent_session_id_test.sh`.
  Doc section "Subagent session ids" added to
  `docs/coord/protocol-v0.md` §11a.
- **TOD-430** — `coord dereg --session <peer>` no longer silently
  deregisters the *caller's* session. The dereg subcommand previously had
  no arg-parsing loop at all, so unknown flags were ignored and the
  command always acted on the caller. All `coord` subcommands now hard-error
  on unknown flags and explicitly reject `--session` with a pointer to
  `coord steal` for stale-lock recovery. Documented in
  `docs/coord/protocol-v0.md` §7 ("CLI flag handling (strict)").

### Changed
- **TOD-258** — Global SessionStart hook
  (`~/.claude/hooks/engram-start.sh`) now prefers `GET /context/smart`
  for boot context with a transparent fallback to `GET /context` when
  the route 404s, making the hook forward- and backward-compatible
  across reveried versions and the Go engram rollback binary. Updated
  `docs/operations.md` with a "Boot context" section documenting the
  curl pattern.

### Fixed
- **TOD-258** — `scripts/engram_compat_smoke.sh` passed the port
  positionally (`engram serve "$PORT"`), which post-cutover reveried
  rejects. Switched to `--port "$PORT"` so `make smoke` works against
  the Rust daemon.

### Added
- **TOD-447** — Schema versioning scaffold for coord session records.
  Froze the current schema as `scripts/coord-schema-v1.json` with a
  byte-identical `scripts/coord-schema-latest.json` mirror, created
  `scripts/migrations/` with an authoring contract and a runnable no-op
  template (`0_to_1_example.sh`), added a pure bash+jq drift CI at
  `.github/workflows/coord-schema-drift.yml` that guards the
  latest-vs-highest invariant and exercises every migration script,
  and documented the versioning + migration rules in
  `docs/coord/schema.md`. `scripts/coord` itself is untouched; the
  `coord migrate` runner is deferred to a follow-up ticket to avoid
  collision with concurrent in-flight edits.
- **TOD-406** — `reverie-dream` classify phase: read-only second dream phase
  that re-infers the `type` field for each scan candidate via a deterministic
  heuristic chain (structured `**What/Why/Where**` blocks, prefix matches for
  `Fixed`/`Decided`/etc., keyword markers for `pattern`/`discovery`/
  `architecture`) and records decisions into a new
  `DreamContext.type_changes: HashMap<i64, String>` for downstream phases to
  persist. Ships the `Classifier` trait + `MockClassifier` test double + a
  no-op `LlmClassifier` placeholder so the dream cycle stays offline by
  default; the real Anthropic-backed classifier and `REVERIED_CLASSIFY_MODEL`
  env wiring land in a follow-up. Eight integration tests cover each
  heuristic branch, the mock-classifier fallback path for undecided `manual`
  observations, and the empty-candidates noop.
- **TOD-260** — `reverie-bench boot-tokens` subcommand and
  `crates/reverie-bench/src/boot_tokens.rs` module: snapshots the live
  `~/.engram/engram.db` to a tempfile, spawns an isolated `reveried serve`
  on an ephemeral port (default 17437, refuses 7437), and measures the
  SessionStart context block across four configurations
  (`baseline-parity`, `reveried-smart`, `reveried-smart-narrow`,
  `reveried-smart-scoped`). Tokenizes responses with `python3 -m tiktoken`
  (cl100k_base) when available, falling back to a `bytes / 4` heuristic
  with a clear disclaimer in the rendered markdown report. Writes
  `reports/boot-tokens-<ts>.md` with bytes / est-tokens / observation
  count / session count plus a "reduction vs baseline" delta table.
  First live run against the user's engram.db (project `ctodie`, 70
  observations) measured baseline-parity at 7184 B / ~1796 tokens
  vs reveried-smart at 5053 B / ~1263 tokens (-30%) and
  reveried-smart-narrow at 3206 B / ~801 tokens (-55%). See
  `docs/operations.md` § "Boot token measurement".
- **TOD-401** — `reverie-bench churn` subcommand and `reverie_bench::churn`
  module. Replays a synthetic stream of candidate observations through two
  passes (ungated baseline vs `GatePipeline::default()`) and renders a
  markdown report comparing churn ratios. At N=1000 with the spec'd
  fixture mix (40% valid / 30% dup / 15% oversized / 10% directive / 5%
  spam) the gate cuts churn from 60.0% to 0.0% — a 100% reduction, well
  above the 50% ship target. Sample report in
  `reports/churn-bench-20260407T000000.md`.
- **TOD-400** — `reverie-dream` scan phase: real implementation of the first
  dream cycle phase. Walks every non-soft-deleted observation via the new
  `EngramCompatStore::all_live_observations()` helper, scores each row with
  the SWR-inspired priority formula
  `recency * access * importance * novelty` (1-week recency half-life,
  log-scaled access on revision+duplicate counts with a small floor so
  first-run observations still rank, static type-weight table mirroring the
  TOD-400 ticket, novelty as `1 - max_jaccard` against peers sharing the
  same `topic_key`), and returns the top-N candidates on a new
  `DreamContext`. Adds a minimal `runner` module (`DreamContext`,
  `DreamPhase` trait, `PhaseReport`) as forward-compatible scaffolding for
  TOD-397's full runner. Eight tests (2 unit + 6 integration via
  `EngramCompatStore::open_in_memory()`) cover empty store, `top_n`
  truncation, `min_age_hours` filtering, type-weight ordering, and the
  novelty penalty on topic-key twins. `docs/operations.md` gains a "Dream
  cycle phases" section documenting the phase table, the `scan` tunables
  (`top_n`, `min_age_hours`), and sample output from a real engram snapshot
  (96 observations scanned, 50 selected, 1.24ms).
- **TOD-273** — `observations.discovery_tokens` column (INTEGER, nullable) is
  now tracked as a reveried-additive column. `AddObservationParams` gains an
  optional `discovery_tokens` field so callers can record the approximate
  agent token cost of discovering a memory (search fan-out, tool churn).
  Migration is idempotent via the existing `REVERIE_COLUMNS` +
  `add_column_if_not_exists` path — old engram DBs ALTER-add the column on
  next open and pre-existing rows read back as `None`. The field
  `skip_serializing_if = "Option::is_none"`, so the wire shape for old
  observations is byte-identical to upstream engram.
- **TOD-274** — `SearchResult.token_count` (optional) carries an estimated
  token cost for the `content` field (`ceil(bytes / 4)`, min 1 — rough BPE
  average for English). Populated only when the new
  `SearchOptions.include_tokens` flag is set; the HTTP handler exposes this
  as `GET /search?...&include_tokens=true`. The default `/search` response
  is byte-identical to upstream engram (parity lock preserved for TOD-368).
  The `mem_search` MCP tool is intentionally unchanged — no token_count in
  MCP responses.
- **TOD-257** — `GET /context/smart?project=<name>&limit=<n>` route,
  project-aware tiered context loader. Composes three tiers into a single
  markdown blob: Tier A (recent in-project, 60% of budget), Tier B
  (high-signal project anchors where `revision_count + duplicate_count ≥ 3`,
  30%), Tier C (cross-cutting recent `scope='personal'` rows across all
  projects, 10%). Lives alongside the byte-parity `/context` handler
  without touching it. Four new `ReveriedConfig` knobs
  (`smart_context_tier_a_weight`, `_b_weight`, `_c_weight`,
  `smart_context_default_limit`) expose the weights and default budget;
  Tier B and Tier C are floored and Tier A absorbs the rounding remainder
  so the total always matches `limit`. New
  `EngramCompatStore::high_signal_observations` helper powers Tier B. See
  `docs/reveried-config.md` and `docs/operations.md` for curl examples and
  worked budgets.
- **TOD-399** — `reverie-gate::rules::PlacementRule` is the first concrete
  `GateRule`. It wraps the TOD-357 placement-linter logic so that directive-
  shaped content (R5) is hard-rejected with "directive belongs in CLAUDE.md"
  and oversized content (R2) is hard-rejected with "content belongs in
  Obsidian" *before* the write hits the store. Respects the existing
  `lint:ignore:R2` / `lint:ignore:R5` / `lint:ignore:all` markers. The cap
  is driven by the new `gate_max_content_chars` config knob (default 2000).
- **TOD-403** — `reverie-gate::rules::DedupRule` adds two-phase write-time
  deduplication. Phase 1 looks up the engram-compat `normalized_hash` in the
  candidate's `topic_key` family within `gate_dedup_window` (default 15 min)
  and rejects any exact-hash hit. Phase 2 is a Jaccard-over-bag-of-words
  fallback against the last 5 observations with the same `topic_key`, with a
  configurable `gate_similarity_threshold` (default 0.85). Cosine-similarity
  over embeddings is deferred to **TOD-255** and documented in the module.
- **TOD-404** — `reverie-gate::rules::BudgetRule` enforces per-project
  admission limits: a rolling 60-second rate limit
  (`gate_rate_limit_per_minute`, default 10) and a hard project cap
  (`gate_project_cap`, default 10000). Uses `ctx.now` so every rule in a
  pipeline run observes a consistent wall-clock.
- **TOD-399/403/404** — `GatePipeline::default()` now wires placement → dedup
  → budget (cheapest-first so structural rejections never touch the DB).
  Five new `ReveriedConfig` knobs: `gate_max_content_chars`,
  `gate_dedup_window`, `gate_similarity_threshold`,
  `gate_rate_limit_per_minute`, `gate_project_cap`. Four new
  `EngramCompatStore` helpers back the rules:
  `recent_by_topic_key`, `count_recent_observations_in_project`,
  `count_live_observations_in_project`, and `find_by_content_hash`.

- **TOD-398** — `reveried gate` subcommand. Reads a candidate observation
  from stdin (engram `AddObservationParams` JSON shape), runs it through a
  `GatePipeline` (currently `GatePipeline::default()` = `AlwaysAccept` until
  TOD-399/403/404 ship real rules), and either persists the accepted
  candidate via `EngramCompatStore::add_observation` or reports a rejection
  on stderr + exit 1. Supports `--dry-run` (no write) and `--reject-log`
  (append rejected candidates as JSONL, default
  `~/.local/state/reveried/gate-rejects.jsonl`). Gate logic lives in
  `crates/reveried/src/gate_cmd.rs` so the integration suite
  (`crates/reveried/tests/gate_integration.rs`) can drive it end-to-end via
  the compiled binary.
- **TOD-402** — Research write-up skeleton at `docs/paper.md`. Nine sections
  (abstract, motivation, placement taxonomy, architecture, dream cycle,
  evaluation, related work, anti-patterns, release notes) with placeholder
  prose, concrete sub-item bullets, and citations to engram observations
  #270, #272, #279, #280, #281, #283. Cross-references MVP-B tickets
  TOD-396/397 (architecture), TOD-400/406/407/408/409 (dream phases), and
  TOD-401/410/351/354 (evaluation). The Evaluation section carries a
  `TODO(TOD-411)` marker so real benchmark numbers land with that ticket.
  Linked from `README.md` as the project's design paper.
- **TOD-397** — `reveried dream` entry point. New `reverie_dream::runner`
  module orchestrates a six-phase pipeline (scan → classify → place →
  consolidate → prune → sync) via a `DreamPhase` trait, with all phases
  shipping as stubs (real implementations land in TOD-400/406/407/408/409).
  Successful non-dry-run cycles append a markdown entry to
  `~/.local/state/reveried/journal.md` (overridable via `REVERIED_STATE_DIR`
  / `XDG_STATE_HOME`); the journal self-truncates to the last 100 runs once
  it crosses 1 MiB. CLI gains `--dry-run` and `--phase <name>` flags
  alongside the existing `--now`. 5 unit tests cover phase ordering,
  `--phase` filtering, dry-run journal suppression, journal markdown format,
  and append-on-second-run.
- **TOD-395** — `docs/mvp-b/auto-capture-triggers.md`: design doc defining the
  three auto-capture triggers for MVP-B (`subagent-stop`, `session-end`,
  `passive-save`), the `CandidateObservation` JSON shape on stdin to
  `reveried gate`, the rejection log layout
  (`~/.local/state/reveried/gate-rejects.jsonl`), per-trigger test plans, and
  open questions about the harness hook contract. `subagent-stop` ships first;
  `session-end` ships in the same PR if test plan §5.2 passes; `passive-save`
  is deferred. Cross-references TOD-396 (`GatePipeline` trait), TOD-398
  (`reveried gate` subcommand), TOD-405 (subagent-stop hook wiring). Linked
  from the new `docs/operations.md`.
- **TOD-396** — `reverie-gate::pipeline` introduces the trait-based write-gate
  abstraction: `GateRule`, `GatePipeline`, `CandidateObservation`,
  `GateContext`, `RuleResult`, and `GateDecision`. The runner executes rules
  in order, short-circuits on the first `Reject`, and threads `Modify`
  rewrites into the next rule's input. Ships with an `AlwaysAccept` no-op
  rule used by `GatePipeline::default()`; real rules (placement, dedup,
  budget) land via TOD-399/403/404.

### Fixed
- **TOD-392** — `reveried serve` and `reveried mcp` now resolve `--db` via the
  same chain Go engram uses (`cmd/engram/main.go:139`,
  `internal/store/store.go:255`): CLI `--db` flag → `$ENGRAM_DATA_DIR/engram.db`
  → `$HOME/.engram/engram.db`. Previously defaulted to a hardcoded XDG path
  (`~/.local/share/engram/engram.db`) that engram does not use, so migrating
  users would silently boot against an empty database — caught during the
  TOD-271 cutover. Both subcommands now log the resolved path at startup so
  any future drift is visible. New unit tests pin the resolution order.
- **TOD-379** (closes TOD-380) — MCP default-project resolution. Reveried now
  detects a default project at daemon startup using engram's chain (`--project`
  flag → `REVERIED_PROJECT` env → `git config --get remote.origin.url` → repo
  basename, normalized via `engram_quirks::normalize_project`) and applies it
  to every MCP tool call whose `project` field is missing or empty. Mirrors
  engram's `MCPConfig.DefaultProject` (`internal/mcp/mcp.go:29`) at the same
  7 handler sites engram patches (`mem_search`, `mem_save`, `mem_save_prompt`,
  `mem_context`, `mem_session_summary`, `mem_session_start`,
  `mem_capture_passive` — engram lines 635, 692, 859, 890, 1038, 1072, 1106).
  Also brings `mem_search` empty-results text into engram parity (`No memories
  found for: "<query>"`, `internal/mcp/mcp.go:651`), which the smoke test
  exposed once the default-project filter started narrowing reveried's result
  set to match engram. New `default_project` knob in `ReveriedConfig` (TOML)
  pins a value and bypasses detection. `make smoke` now reports 19/19 PASS
  (was 17/19), unblocking the TOD-271 cutover.
- **TOD-368 follow-up** — `scripts/engram_compat_smoke.sh`: isolated the
  engram MCP subprocess to the same snapshot DB as the engram HTTP server.
  Previously the harness only sandboxed `HOME` for `engram serve`; the
  per-test `engram mcp` invocations inherited the real `HOME` and read the
  user's live `~/.engram/engram.db`, poisoning every MCP diff with DB-state
  drift (mem_stats / mem_search / mem_context / sessions_recent all reported
  spurious failures). Fix exports `ENGRAM_DATA_DIR` (engram's highest-priority
  override) so every child process — both `serve` and every `mcp` — reads
  the same `$SMOKE_DIR/engram-data/engram.db` snapshot. Added a startup
  sandbox sanity check that aborts (exit 3) if the engram HTTP and engram
  MCP processes report different `mem_stats` session counts, so the silent-
  lie failure mode is now impossible.
- **TOD-368** — Wire-format parity with Go engram across 8 divergences caught
  by the differential smoke test:
  - MCP `tools/call` responses no longer emit `isError: false` on the success
    path (engram omits it via Go `omitempty`).
  - `mem_suggest_topic_key` now returns `Suggested topic_key: <key>` instead of
    a bare slug, matching `internal/mcp/mcp.go:778`.
  - `mem_get_observation` MCP error string is now `Observation #<id> not
    found` (capitalised, with hash) — engram's HTTP and MCP layers use
    different miss strings; both are now matched.
  - `/stats` JSON now uses engram's `total_sessions` / `total_observations` /
    `total_prompts` field names plus a `projects: []string` slice (`null` when
    empty), replacing reveried's prior bespoke shape.
  - `/export` envelope now always emits `version` + `exported_at`
    (engram-format `YYYY-MM-DD HH:MM:SS` UTC timestamp), and the
    `sessions` / `observations` / `prompts` slice fields serialise to JSON
    `null` when empty (Go nil-slice encoding) instead of `[]`.
  - `/sessions/recent`, `/prompts/recent`, `/prompts/search`,
    `/observations/recent`, and `/search` now serialise an empty result set
    as bare JSON `null` rather than `[]`, matching engram's nil-slice
    response body.
  - `/sessions/recent` now returns `SessionSummary` rows (`observation_count`,
    no `directory`) instead of `Session`, matching engram's
    `Store.RecentSessions` projection.
  - `/context` and `mem_context` now render the engram markdown layout
    byte-for-byte: `## Memory from Previous Sessions` header,
    `### Recent Sessions` / `### Recent User Prompts` / `### Recent
    Observations` sections in that order, `**project** (started_at): summary
    [N observations]` session bullets, `[type] **title**: <preview>`
    observation bullets, code-point-based truncation, and an empty string
    when there is nothing to render. The `mem_context` MCP wrapper appends
    the engram stats footer and falls back to `No previous session memories
    found.` when the context is empty.
- New `crates/reverie-store/tests/wire_format.rs` integration suite pins
  every fix above against engram's documented wire output so we can't
  silently regress.
- **TOD-368 final** — Two remaining wire-format divergences caught by the
  post-ripple smoke:
  - `/timeline` HTTP route: the 404 error envelope now reads
    `{"error":"timeline: observation #<id> not found: sql: no rows in result set"}`
    (byte-identical to engram's Go store error; matches the string the MCP
    dispatch layer already returned).
  - `recent_sessions` SQL: the `ORDER BY` clause now reads
    `MAX(COALESCE(o.created_at, s.started_at)) DESC`, matching
    `internal/store/store.go:840`. The old `datetime(s.started_at) DESC`
    surfaced empty test-fixture sessions over the ones users were actively
    writing into; this restores engram's "recent activity" semantics.
- **TOD-368 follow-up** — Reshape `TimelineResult` to match upstream engram
  byte-for-byte: add `TimelineEntry` struct, populate `session_info` and
  `total_in_range`, and switch the SQL to engram's same-session/`id <`/`id >`
  windowing (`internal/store/store.go:1360-1458`). Replace JSON pretty-print
  bodies for `mem_get_observation` and `mem_timeline` with the hand-formatted
  text engram returns (`internal/mcp/mcp.go:953-1027`). Match engram's
  `Timeline error: timeline: observation #N not found: sql: no rows in result
  set` error string verbatim.

### Added
- **TOD-270** — `reverie-sync` adapters for the MVP-A drop-in cutover.
  `ObsidianAdapter` ports the upstream `engram-to-obsidian` Python hook to
  Rust, reading observations directly from `EngramCompatStore` and writing
  one Obsidian note per observation with frontmatter (`engram-id`,
  `engram-type`, `topic-key`, `project`, `scope`, `sync_id`, tags) deduped
  by `topic_key` first, slug second. State is persisted to
  `<vault>/_System/.engram-sync-state.json` in the same JSON shape as the
  Python script so the two are mutually compatible. `AutoMemoryAdapter`
  and `ClaudeMdAdapter` are intentional no-ops — auto-memory and CLAUDE.md
  are user-curated layers (see canceled TOD-261 / TOD-263).

### Fixed
- **TOD-371** — `EngramCompatStore::get_observation` now hides
  soft-deleted rows (matching engram's `Store.GetObservation`); the
  previous implementation surfaced tombstones to callers.
- **TOD-371** — `EngramCompatStore::passive_capture` now correctly
  extracts numbered learning lists, parses `### Learnings` headers,
  enforces engram's 20-char / 4-word minimum item length, strips
  markdown (`**bold**`, `` `code` ``, `*italic*`), and walks sections
  in reverse to prefer the most recent valid one — matching the engram
  `ExtractLearnings` semantics. Previously only `- `/`* ` bullets were
  recognized.

### Added
- **TOD-352** — Closet/drawer pattern on `Chunk`. Adds `summary: Option<String>`
  to the chunk model (lossless YAML frontmatter round-trip, omitted when
  `None`), a new lightweight `ChunkSummary` "closet pointer"
  (`{id, topic_key, title, summary}`), and `Chunk::derived_summary` /
  `Chunk::as_summary` helpers that fall back to a UTF-8-safe preview of
  `content` when no explicit summary is set. `SearchEngine` (previously a
  stub) now exposes the closet/drawer surface: `search()` returns
  `Vec<ChunkSummary>` (no body shipped), `search_full()` returns full
  `Vec<Chunk>`, and `get_chunk(id)` opens a single drawer. Default search
  no longer materializes verbatim bodies — token cost on multi-hit
  queries drops by roughly the body/summary ratio (typically 5–20×).
- **TOD-372** — `reveried` config file at `~/.config/reveried/config.toml`
  with `--config <path>` override and engram-parity defaults for
  `max_observation_length` (50000), `max_context_results` (20),
  `max_search_results` (20), and `dedupe_window` (15 min). New
  `ReveriedConfig` in `reverie-store::config` and
  `EngramCompatStore::open_with_config()` plumbing. Documented in
  `docs/reveried-config.md`.
- **TOD-368** — `scripts/engram_compat_smoke.sh`: differential smoke test
  harness comparing `reveried` vs the upstream Go `engram` daemon byte-for-byte
  on every HTTP route and MCP tool against COPIES of the same starting
  `engram.db`. Includes JSON normalization (sorted keys, redacted timestamps /
  UUIDs / ANSI / version / tmp paths), idempotent cleanup, optional
  `--write-mode` for mutating routes, and a `make smoke` / `make smoke-write`
  target. Pre-cutover gate — exit code is the FAIL count. Engram is sandboxed
  via a fake `$HOME` so the user's live DB is never touched.
- **TOD-357** — `reverie-lint` CLI in `reverie-gate`: placement linter that
  scans an engram observation database and flags 5 placement-framework
  violations (R1 preference-not-in-auto-memory, R2 oversized-for-engram,
  R3 near-duplicate, R4 stale-session-summary, R5 directive-in-engram).
  Each rule has a configurable threshold and supports per-rule
  suppression via a `lint:ignore:RN` (or `lint:ignore:all`) marker in
  the observation content. Text and `--json` output, optional
  `--fail-on-findings` for CI gating.
- **TOD-367** — `EngramCompatStore`: drop-in compatible SQLite backend that
  reads/writes the upstream `engram.db` file, including the full schema,
  FTS5 triggers, topic_key upsert, content-hash dedup, `<private>` tag
  stripping, and 8 reveried-additive columns. Gated behind the new
  `backend-engram-compat` feature on `reverie-store`.
- **TOD-268** — engram-compatible axum HTTP server in `reverie-store::http`
  exposing all 21 routes from `docs/engram-api-surface.md` §1, plus
  `reveried serve` wiring with `--db/--bind/--port/--log` flags.
- Initial project scaffold: Cargo workspace with `reveried` and `reverie-bench` crates
- CLI skeleton for both binaries (clap derive)
- Full project infrastructure: Makefile, CI/CD, pre-commit, lint configs
- Documentation: daemon spec, LoCoMo harness spec, backlog

### Research
- 10 neuroscience mechanisms mapped to implementation
- 9 competitive systems analyzed (SOTA survey)
- 13 empirical findings from memory audit (105 → 39 observations)
- 5 synthesized insights (gravitational collapse, 200-line ceiling, adaptive forgetting, content-addressed sync, metadata pollution)
- Placement decision tree formalized
- LoCoMo benchmark integration plan
