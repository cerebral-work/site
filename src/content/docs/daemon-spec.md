# Reverie Daemon — Specification

**Name**: `reverie` (or `reveried`)
**Language**: Rust
**Role**: Offline memory consolidation daemon — manages memory chunks across persistence layers, runs "dream" cycles to consolidate/prune/promote/demote knowledge, and enforces the placement framework.

> "Wintermute was hive mind, decision maker. Neuromancer was personality, immortality."
> Reverie is the sleep cycle between them — the process that turns raw experience into structured knowledge.

---

## 1. Core Metaphor: Sleep Consolidation

Biological memory consolidation during sleep:
1. **Replay** — hippocampus replays episodic memories to neocortex at 20x speed
2. **Strengthen** — frequently co-activated traces get stronger connections
3. **Prune** — weak/unreferenced traces are pruned (Ebbinghaus forgetting curve)
4. **Promote** — episodic memories become semantic knowledge (facts divorced from context)
5. **Integrate** — new knowledge is woven into existing schema

Reverie maps these to LLM memory operations:

| Sleep phase | Reverie operation | System action |
|------------|-------------------|---------------|
| Replay | **Scan** | Read all new observations since last cycle |
| Strengthen | **Reinforce** | Bump priority/revision count on frequently accessed obs |
| Prune | **Forget** | Delete stale, superseded, or low-signal observations |
| Promote | **Promote** | Move knowledge up: engram → auto-memory, or engram → CLAUDE.md |
| Demote | **Archive** | Move knowledge down: auto-memory → engram, or engram → Obsidian-only |
| Integrate | **Dream** | Synthesize multiple observations into higher-order insights |

---

## 2. Architecture

```
                    ┌──────────────────────┐
                    │      reveried        │
                    │                      │
                    │  ┌──── Scheduler ──┐ │
                    │  │ session-end     │ │
                    │  │ cron (4h)       │ │
                    │  │ manual trigger  │ │
                    │  └────────┬────────┘ │
                    │           │          │
                    │  ┌────────▼────────┐ │
                    │  │  Dream Engine   │ │
                    │  │                 │ │
                    │  │  scan()         │ │
                    │  │  classify()     │ │
                    │  │  place()        │ │
                    │  │  consolidate()  │ │
                    │  │  prune()        │ │
                    │  │  sync()         │ │
                    │  └────────┬────────┘ │
                    │           │          │
                    │  ┌────────▼────────┐ │
                    │  │  Layer Adapters │ │
                    │  │                 │ │
                    │  │  engram (HTTP)  │ │
                    │  │  auto-memory    │ │
                    │  │  claude.md      │ │
                    │  │  obsidian       │ │
                    │  └─────────────────┘ │
                    └──────────────────────┘
```

### Components

**Scheduler**: Triggers dream cycles on:
- Session end (hook: `~/.claude/hooks/reverie-dream.sh`)
- Periodic cron (every 4 hours while idle)
- Manual: `reverie dream --now`
- Threshold: >10 new observations since last cycle

**Dream Engine**: Core logic pipeline. Each cycle runs phases in order:
1. `scan()` — read new/changed observations from engram
2. `classify()` — apply placement decision tree to each observation
3. `place()` — move misplaced observations to correct layer
4. `consolidate()` — merge related observations into higher-order insights
5. `prune()` — delete stale/superseded/low-signal observations
6. `sync()` — push changes to Obsidian, update auto-memory index

**Layer Adapters**: Read/write interfaces to each persistence layer:
- `engram`: HTTP API (read) + MCP (write) or direct SQLite
- `auto-memory`: filesystem read/write to `~/.claude/projects/*/memory/`
- `claude.md`: filesystem read/write (with 200-line budget enforcement)
- `obsidian`: filesystem write to vault path (with topic_key dedup)

---

## 3. Memory Chunks

A **chunk** is the unit of knowledge that Reverie manages. It's layer-agnostic — the same chunk can exist in different representations across layers.

```rust
struct Chunk {
    /// Stable identity — survives cross-layer migration
    id: ChunkId,              // UUID or content-hash
    topic_key: String,        // family/slug — the conceptual identity

    /// Content
    title: String,
    content: String,          // markdown
    kind: ChunkKind,          // Directive, Preference, Decision, Reference, Heuristic, Session

    /// Placement
    canonical_layer: Layer,   // where this chunk SHOULD live
    current_layers: Vec<LayerRef>,  // where it currently exists (with layer-specific IDs)

    /// Lifecycle
    created: DateTime,
    last_accessed: DateTime,
    access_count: u32,
    revision_count: u32,
    staleness_score: f32,     // computed: time since access * decay rate per kind
    signal_score: f32,        // computed: access frequency * revision count * kind weight

    /// Neuroscience additions (see ADR-006)
    strength: f32,            // SHY-model synaptic strength (decays during dream downscale)
    depth_score: u8,          // 1 = episodic, 2 = intermediate, 3 = semantic
    session_spread: u32,      // distinct sessions that accessed this chunk
    stability: f32,           // Ebbinghaus S parameter — higher = slower forgetting
    importance_tag: Option<String>,  // optional salience tag from write gate
    consolidation_status: ConsolidationStatus,  // Staged → Consolidated → Archived
    schema_id: String,        // "reverie.chunk.v1" — forward-compatible versioning
    version: u32,             // monotonic version counter

    /// Relationships
    related_to: Vec<ChunkId>, // conceptual links (heuristic triads, etc.)
    supersedes: Option<ChunkId>,
    superseded_by: Option<ChunkId>,

    /// Provenance
    source_session: String,
    source_project: String,
}

enum ChunkKind {
    Directive,    // CLAUDE.md — behavioral rules
    Preference,   // auto-memory — user feedback, work style
    Decision,     // engram — project decisions, architecture
    Reference,    // Obsidian — deep knowledge, books, theory
    Heuristic,    // Obsidian MOC — engineering principles
    Session,      // engram — session summaries
    Config,       // engram — tool configs, API details
    Bug,          // engram — bugfixes with root cause
}

enum Layer {
    InstructionFile,  // CLAUDE.md, rules/
    SessionMemory,    // auto-memory (MEMORY.md index)
    StructuredDb,     // engram (SQLite + FTS5)
    KnowledgeBase,    // Obsidian vault
}

enum ConsolidationStatus {
    Staged,       // newly ingested, not yet processed by a dream cycle
    Consolidated, // processed and placed by the dream engine
    Archived,     // demoted to long-term storage / Obsidian
}
```

### Neuroscience field reference

| Field | Type | Default | Model | Role |
|-------|------|---------|-------|------|
| `strength` | f32 | 1.0 | SHY (Tononi/Cirelli) | Synaptic strength; global downscale during dream decays weak traces |
| `depth_score` | u8 | 2 | Systems consolidation | 1=episodic/hippocampal, 2=intermediate, 3=semantic/neocortical |
| `session_spread` | u32 | 1 | Hebbian learning | Cross-session reactivation count; "fire together, wire together" |
| `stability` | f32 | 1.0 | Ebbinghaus forgetting | S parameter controlling decay rate; higher = flatter forgetting curve |
| `importance_tag` | Option | None | Behavioral tagging | High-salience events get persistent tags resisting forgetting |
| `consolidation_status` | enum | Staged | Sleep staging | Tracks lifecycle: new → processed → archived |

These fields are stored in the `observations` SQL table as nullable columns (via `REVERIE_COLUMNS` migration in `engram_compat.rs`) and as first-class fields on the `Chunk` struct (`reverie-store/src/chunk.rs`). The `reverie-domain` crate's `Observation` entity intentionally omits them — it models the engram-compatible surface, not the dream-engine internals. See ADR-006 for how these fields feed into the multi-factor scoring pipeline.

### Chunk lifecycle

```
Created (mem_save) → Classified (placement tree) → Placed (correct layer)
    ↓                                                      ↓
    └──── if misplaced ────────────────────────── Migrated (move to correct layer)
                                                           ↓
                                            ┌── Reinforced (accessed frequently)
                                            ├── Consolidated (merged with related)
                                            ├── Promoted (moved up: engram → auto-memory)
                                            ├── Demoted (moved down: auto-memory → engram)
                                            └── Pruned (deleted: stale, superseded, low-signal)
```

---

## 4. Dream Cycles

### 4.1 Scan

```rust
fn scan(&self) -> Vec<Chunk> {
    // 1. Read all engram observations since last dream
    // 2. Read all auto-memory files (check mtimes)
    // 3. Read CLAUDE.md (check mtime)
    // 4. Build chunk index: map topic_key → Vec<LayerRef>
    // 5. Detect: new chunks, modified chunks, cross-layer duplicates
}
```

### 4.2 Classify (Placement Decision Tree)

```rust
fn classify(&self, chunk: &Chunk) -> Layer {
    match chunk.kind {
        Directive => Layer::InstructionFile,
        Preference => Layer::SessionMemory,
        Decision | Bug | Config | Session => Layer::StructuredDb,
        Reference | Heuristic => Layer::KnowledgeBase,
    }
    // Override: if CLAUDE.md is at capacity (>190 lines),
    //   demote lowest-blast-radius directives to auto-memory
}
```

### 4.3 Place (Migration)

```rust
fn place(&self, chunk: &Chunk, target: Layer) -> Result<()> {
    // 1. Write to target layer (adapter)
    // 2. Update chunk.current_layers
    // 3. If chunk existed in another layer, delete the old copy
    // 4. If target is auto-memory, regenerate MEMORY.md index
    // 5. Never delete from CLAUDE.md without confirmation
}
```

### 4.4 Consolidate (Dreaming)

The most novel operation. Synthesis of multiple related observations into higher-order knowledge.

```rust
fn consolidate(&self, chunks: &[Chunk]) -> Vec<ConsolidationAction> {
    // 1. Group chunks by topic_key family
    // 2. For each group with 3+ members:
    //    a. Check if a MOC/summary already exists
    //    b. If not, generate one (via LLM or template)
    //    c. Create new chunk at higher abstraction level
    //    d. Link original chunks as children
    // 3. For chunks that supersede each other:
    //    a. Keep the newest, mark older as superseded
    //    b. Merge any unique content from older into newer
    // 4. For session summaries older than 30 days:
    //    a. Extract still-relevant discoveries into standalone chunks
    //    b. Archive the summary (demote to Obsidian journal)
}
```

**Dream examples:**
- 3 bugfixes in the same module → consolidated into a "known issues" reference note
- 5 session summaries with repeated "discovery" → extracted into a standalone pattern
- Decision A superseded by Decision B → merge, keep B, link A as historical context
- 10 project status observations for unsigned-paas → consolidated into a project health dashboard note

### 4.5 Prune (Forgetting)

```rust
fn prune(&self, chunks: &[Chunk]) -> Vec<PruneAction> {
    // Score each chunk: signal_score / staleness_score
    // Prune if:
    //   - staleness_score > threshold (kind-dependent)
    //   - superseded_by is set (newer version exists)
    //   - access_count == 0 && age > 30 days
    //   - duplicate detected (same topic_key in same layer)
    //   - test/marker data (topic_key starts with "startup/test")

    // Staleness thresholds by kind:
    //   Session: 30 days (archive, don't delete)
    //   Config: 90 days (configs change slowly)
    //   Decision: 180 days (decisions are long-lived)
    //   Bug: 60 days (if resolved)
    //   Reference: never (human-curated)
    //   Heuristic: never (philosophical, timeless)
}
```

### 4.6 Sync

```rust
fn sync(&self) -> Result<SyncReport> {
    // 1. Run engram-to-obsidian sync (with topic_key dedup)
    // 2. Regenerate MEMORY.md index from auto-memory files
    // 3. Validate CLAUDE.md line count (warn if >190)
    // 4. Write dream journal: what was consolidated, pruned, migrated
    // 5. Update last-dream timestamp in engram
}
```

---

## 5. Write Gate (Pre-Save Hook)

Runs BEFORE `mem_save` — the prevention layer that stops misplacement at write time.

```rust
fn gate(&self, proposed: &Chunk) -> GateDecision {
    let target = self.classify(proposed);

    // Check 1: Is this already stored elsewhere?
    if let Some(existing) = self.find_by_topic_key(&proposed.topic_key) {
        if existing.canonical_layer == target {
            return GateDecision::Upsert(existing.id); // update in place
        } else {
            return GateDecision::Redirect(target); // wrong layer, redirect
        }
    }

    // Check 2: Is this derivable from code/git?
    if self.is_derivable(proposed) {
        return GateDecision::Reject("derivable from code — don't store");
    }

    // Check 3: Will this be needed in a future session?
    if proposed.kind == ChunkKind::Session && proposed.staleness_score > 0.8 {
        return GateDecision::Reject("ephemeral — won't be useful later");
    }

    // Check 4: Capacity check for instruction layer
    if target == Layer::InstructionFile && self.claude_md_lines() > 190 {
        return GateDecision::Redirect(Layer::SessionMemory); // overflow to auto-memory
    }

    GateDecision::Allow(target)
}
```

---

## 6. Dream Journal

Each dream cycle produces a journal entry — an observation of what the daemon did:

```markdown
## Dream Cycle 2026-04-05 03:00

**Scanned**: 8 new observations since last cycle
**Classified**: 2 misplaced (behavioral content in engram → auto-memory)
**Placed**: 2 migrations executed
**Consolidated**: 3 unsigned-paas status obs → 1 project health summary
**Pruned**: 1 stale config (dns record, superseded)
**Synced**: 4 notes to Obsidian, MEMORY.md regenerated

**CLAUDE.md budget**: 171/200 lines (29 remaining)
**Engram count**: 41 observations
**Auto-memory**: 12 files
**Obsidian**: 133 notes
```

---

## 7. CLI Interface

```bash
reverie dream              # run one dream cycle now
reverie dream --dry-run    # show what would change
reverie scan               # just scan, report placement issues
reverie classify <id>      # classify a single observation
reverie place <id> <layer> # manually move an observation
reverie prune --dry-run    # show what would be pruned
reverie status             # show layer counts, budget, last dream
reverie journal            # show recent dream journals
reverie gate <json>        # test write gate on proposed observation
```

---

## 8. Configuration

```toml
# ~/.config/reverie/config.toml

[scheduler]
on_session_end = true
cron = "0 */4 * * *"       # every 4 hours
threshold_new_obs = 10      # dream after N new observations

[layers]
claude_md = "~/.claude/CLAUDE.md"
auto_memory = "~/.claude/projects/-home-ctodie/memory/"
engram_url = "http://127.0.0.1:7437"
obsidian_vault = "~/vault"  # resolves symlink

[budget]
claude_md_max_lines = 200
claude_md_warn_lines = 190
auto_memory_max_files = 20
auto_memory_index_max_lines = 200

[staleness]
session_days = 30
config_days = 90
decision_days = 180
bug_resolved_days = 60

[consolidation]
min_group_size = 3          # consolidate groups of 3+
session_archive_days = 30   # archive sessions older than this
enable_llm_synthesis = false  # requires API key for dream synthesis

[llm]
# Optional: use Claude API for dream synthesis (consolidate step)
api_key_env = "ANTHROPIC_API_KEY"
model = "claude-haiku-4-5-20251001"  # cheap model for consolidation
max_tokens_per_dream = 2000
```

---

## 9. Integration Points

### Claude Code hooks
```json
// settings.json
{
  "hooks": {
    "SessionStop": [{
      "command": "reverie dream --quiet",
      "timeout": 30
    }],
    "PreToolUse": [{
      "matcher": "mcp__plugin_engram_engram__mem_save",
      "command": "reverie gate --stdin",
      "timeout": 5
    }]
  }
}
```

### engram-rs (Phase 4)
When engram is rewritten in Rust, reverie can be a library crate consumed by engram-rs rather than a separate daemon. The dream engine becomes `engram-rs dream`, the write gate becomes built-in to `mem_save`.

### Obsidian
Dream journals written to `50-Journal/dreams/` in the vault. Consolidation results to appropriate PARA folders.

---

## 10. Development Phases

### v0.1 — Scan + Classify (read-only)
- Scan all layers, build chunk index
- Classify every chunk, report misplacements
- No writes. Validates the placement framework.

### v0.2 — Write Gate
- PreToolUse hook for mem_save
- Redirects misplaced saves to correct layer
- Reject derivable/ephemeral content

### v0.3 — Place + Prune
- Execute migrations (move chunks between layers)
- Delete stale/superseded observations
- Regenerate MEMORY.md index

### v0.4 — Consolidate (Dream)
- Group related chunks, generate summaries
- Archive old session summaries to Obsidian
- Optional LLM synthesis for high-quality consolidation

### v0.5 — Scheduler + Journal
- Session-end hook, cron, threshold triggers
- Dream journal output
- `reverie status` dashboard

### v1.0 — Absorb into engram-rs
- Becomes a library crate
- Dream engine runs inside engram process
- Write gate is native to mem_save path
- Single binary: `engram dream`, `engram gate`, `engram sync`

---

## 11. Open Questions

1. **Should consolidation use an LLM?** Template-based merging is deterministic and free. LLM synthesis produces higher-quality summaries but costs tokens and introduces non-determinism. Could use haiku for cheap synthesis.

2. **How to handle CLAUDE.md edits?** The daemon writing to CLAUDE.md risks breaking the user's carefully curated instructions. Should it propose changes (PR model) or execute them directly?

3. **Cross-user generalization?** The placement framework was derived from one user's system. Is the taxonomy universal or personal? The 6 knowledge types seem general; the specific layers (engram, Obsidian) are implementation-specific.

4. **Relationship to engram-rs?** If Reverie becomes a crate inside engram-rs, the daemon model is unnecessary — it's just a `dream` subcommand. But keeping it separate allows running dreams without engram (e.g., for users with different backends).

5. **Temporal decay functions** — should staleness be linear, exponential, or step-function? Ebbinghaus curve is exponential with a long tail. Decisions probably have a step function (valid until superseded). Sessions have linear decay.

6. **Entity resolution** — Remembra's key insight: "knowing WHO matters as much as WHAT." Should chunks track entities (people, projects, tools) and resolve cross-references? This would catch "Jyovani" mentioned in 3 different observations as the same person.
