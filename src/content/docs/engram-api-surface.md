# Engram (Go) API surface — reverse-engineering reference

**Purpose:** Enumerate every HTTP route, MCP tool, SQL table, and quirk in the
upstream Go `engram` daemon so the Reverie Rust rewrite (`reveried`) can ship
as a true drop-in replacement. **Future Claude sessions and human readers
should be able to use this as the canonical spec for the engram surface
without re-reading the Go source.**

**Source:** `~/.claude/plugins/marketplaces/engram/` (Christian's fork of
github.com/Gentleman-Programming/engram). Three files cover ~99% of the
surface:

| File | LOC | What's in it |
|---|---:|---|
| `internal/server/server.go` | 616 | HTTP route registration + handlers |
| `internal/mcp/mcp.go` | 1209 | MCP stdio tool registration + handlers |
| `internal/store/store.go` | 3595 | SQLite schema, migrations, all data ops |

**Linear ticket:** [TOD-266](https://linear.app/todie/issue/TOD-266) — this
file is the deliverable.

**Conventions in this doc:**
- All line numbers refer to the source files in the engram repo at the time
  of writing. Re-read the source if upstream has since changed.
- Default port: `7437` (engram listens on this — `reveried` must too).
- Default bind: `127.0.0.1` (localhost only — no external auth required).
- Error envelope: every error response is `{"error": "<message>"}` with the
  appropriate HTTP status. JSON encoding is `application/json`.
- Success envelope: route-specific (no global wrapper). See per-route shapes.

---

## Section 1 — HTTP routes (21 routes)

Routes registered on a stdlib `http.ServeMux` via `s.mux.HandleFunc("METHOD
/path", handler)`. Go 1.22+ pattern syntax with method prefixes and `{id}`
placeholders. All in `internal/server/server.go:98–138`.

### Inventory

| # | Method | Path | Handler |
|---:|---|---|---|
| 1 | GET | `/health` | `handleHealth` |
| 2 | POST | `/sessions` | `handleCreateSession` |
| 3 | POST | `/sessions/{id}/end` | `handleEndSession` |
| 4 | GET | `/sessions/recent` | `handleRecentSessions` |
| 5 | POST | `/observations` | `handleAddObservation` |
| 6 | POST | `/observations/passive` | `handlePassiveCapture` |
| 7 | GET | `/observations/recent` | `handleRecentObservations` |
| 8 | GET | `/observations/{id}` | `handleGetObservation` |
| 9 | PATCH | `/observations/{id}` | `handleUpdateObservation` |
| 10 | DELETE | `/observations/{id}` | `handleDeleteObservation` |
| 11 | GET | `/search` | `handleSearch` |
| 12 | GET | `/timeline` | `handleTimeline` |
| 13 | POST | `/prompts` | `handleAddPrompt` |
| 14 | GET | `/prompts/recent` | `handleRecentPrompts` |
| 15 | GET | `/prompts/search` | `handleSearchPrompts` |
| 16 | GET | `/context` | `handleContext` |
| 17 | GET | `/export` | `handleExport` |
| 18 | POST | `/import` | `handleImport` |
| 19 | GET | `/stats` | `handleStats` |
| 20 | POST | `/projects/migrate` | `handleMigrateProject` |
| 21 | GET | `/sync/status` | `handleSyncStatus` |

### Per-route specifications

#### 1. `GET /health`

```http
GET /health → 200
{"status": "ok", "service": "engram", "version": "0.1.0"}
```

No params. Always returns 200. Used as a liveness check by `mem` bash client.

---

#### 2. `POST /sessions`

```http
POST /sessions → 201 / 400
Content-Type: application/json

{"id": "<session-id>", "project": "<project>", "directory": "<cwd>"}

→ 201 {"id": "<id>", "status": "created"}
→ 400 {"error": "id and project are required"}
```

Required: `id`, `project`. Optional: `directory`. Calls
`store.CreateSession(id, project, directory)`. Triggers `notifyWrite()` for
sync coordination.

---

#### 3. `POST /sessions/{id}/end`

```http
POST /sessions/{id}/end → 200
Content-Type: application/json

{"summary": "<text>"}  // optional

→ 200 {"id": "<id>", "status": "completed"}
```

Path param: `id`. Body: optional `summary`. Sets `sessions.ended_at` and
`sessions.summary`.

---

#### 4. `GET /sessions/recent`

```http
GET /sessions/recent?project=<p>&limit=<n>  // limit defaults to 5
→ 200 [Session, Session, ...]
```

Returns the most recently started sessions. `project` query optional. Each
`Session` is the JSON shape from §3.

---

#### 5. `POST /observations`

```http
POST /observations → 201 / 400 / 500
Content-Type: application/json

{
  "session_id": "<id>",      // required
  "type":       "<category>", // required
  "title":      "<text>",     // required
  "content":    "<text>",     // required
  "tool_name":  "<text>",     // optional
  "project":    "<text>",     // optional
  "scope":      "project|personal", // optional, default "project"
  "topic_key":  "<slug>"      // optional — triggers upsert behaviour
}

→ 201 {"id": <int64>, "status": "saved"}
→ 400 {"error": "session_id, title, and content are required"}
→ 500 {"error": "<store error>"}
```

Backed by `store.AddObservation(p)`. **This is where the topic_key upsert,
content-hash dedup, scope normalization, project normalization, and
`<private>` tag stripping all happen** — see §4 for the full semantics.

---

#### 6. `POST /observations/passive`

```http
POST /observations/passive → 200 / 400
Content-Type: application/json

{
  "session_id": "<id>",        // required
  "content":    "<text>",      // required
  "project":    "<text>",      // optional
  "source":     "<text>"       // optional, e.g. "subagent-stop"
}

→ 200 {"extracted": <int>, "saved": <int>, "duplicates": <int>}
```

Extracts learnings from a "## Key Learnings:" or "## Aprendizajes Clave:"
section in `content`, saves each as a separate observation. Duplicates are
detected and skipped. Used by post-tool / sub-agent hooks. Pattern lives in
`store.go:3449` (`learningHeaderPattern`).

---

#### 7. `GET /observations/recent`

```http
GET /observations/recent?project=<p>&scope=<s>&limit=<n>
// limit defaults to MaxContextResults (config-driven, ~20)
→ 200 [Observation, Observation, ...]
```

`scope` filter is normalized: `personal` → `personal`, anything else →
`project`. Soft-deleted rows excluded.

---

#### 8. `GET /observations/{id}`

```http
GET /observations/{id} → 200 / 404
→ 200 Observation
→ 404 {"error": "observation not found"}
```

Path param: numeric `id`.

---

#### 9. `PATCH /observations/{id}`

```http
PATCH /observations/{id} → 200 / 400 / 404
Content-Type: application/json

{
  "type":      "<text>",     // all fields optional but at least one required
  "title":     "<text>",
  "content":   "<text>",
  "project":   "<text>",
  "scope":     "<text>",
  "topic_key": "<text>"
}

→ 200 Observation (the updated row)
→ 400 {"error": "at least one field is required"}
→ 404 {"error": "<not found>"}
```

Partial update — only provided fields are written. Fields use Go pointer
semantics (`*string`) so `null` and "absent" are distinguished from empty.

---

#### 10. `DELETE /observations/{id}`

```http
DELETE /observations/{id}?hard=true|false → 200
→ 200 {"id": <int64>, "status": "deleted", "hard_delete": <bool>}
```

Default is soft delete (sets `deleted_at`). `?hard=true` permanently removes
the row. `?hard=` accepts anything `strconv.ParseBool` understands.

---

#### 11. `GET /search`

```http
GET /search?q=<query>&type=<t>&project=<p>&scope=<s>&limit=<n>
// q is required, others optional
// limit defaults to 10
→ 200 [SearchResult, SearchResult, ...]
→ 400 {"error": "q parameter is required"}
```

Each `SearchResult` is an `Observation` plus a `rank: float64` from the
FTS5 bm25 score. **Query sanitization:** `sanitizeFTS()` wraps each
whitespace-split term in double quotes (`fix auth bug` → `"fix" "auth"
"bug"`) so FTS5 mini-language operators don't trip on user input.

---

#### 12. `GET /timeline`

```http
GET /timeline?observation_id=<id>&before=<n>&after=<n>
// observation_id required
// before/after default to 5 each
→ 200 TimelineResult
→ 400 {"error": "observation_id parameter is required"}
→ 404 {"error": "<not found>"}
```

Returns chronological context — the N observations before and after the
focus observation, in the same project+scope. Used by the
`mem_timeline` MCP tool for progressive disclosure after a search.

---

#### 13. `POST /prompts`

```http
POST /prompts → 201 / 400
{"session_id": "<id>", "content": "<text>", "project": "<text>"}
→ 201 {"id": <int64>, "status": "saved"}
→ 400 {"error": "session_id and content are required"}
```

Saves a user prompt (separate from observations). Same `<private>` tag
stripping as observations.

---

#### 14. `GET /prompts/recent`

```http
GET /prompts/recent?project=<p>&limit=<n>  // limit defaults to 20
→ 200 [Prompt, Prompt, ...]
```

---

#### 15. `GET /prompts/search`

```http
GET /prompts/search?q=<query>&project=<p>&limit=<n>  // limit defaults to 10
→ 200 [Prompt, Prompt, ...]
→ 400 {"error": "q parameter is required"}
```

FTS5 search over `prompts_fts`.

---

#### 16. `GET /context`

```http
GET /context?project=<p>&scope=<s>&limit=<n>&compact=<bool>
→ 200 {"context": "<formatted markdown>"}
```

Returns a multi-section markdown blob with recent sessions, observations,
and prompts. **`compact` is a `strconv.ParseBool` value** — accepts
`1|0|t|f|T|F|TRUE|FALSE|True|False|true|false`. Unknown values silently
leave Compact at its zero value (this is a known engram footgun — `?compact=yes`
silently ignored). `limit` overrides the per-section default (~20 by config).
The "## Recent Observations" section uses `Compact` to skip preview content
and emit only `[type] **title**` lines, saving ~80% of the token budget.

---

#### 17. `GET /export`

```http
GET /export → 200
Content-Type: application/json
Content-Disposition: attachment; filename=engram-export.json
```

Returns the entire DB as a single JSON document (`ExportData`). Used for
backup + cross-machine migration.

---

#### 18. `POST /import`

```http
POST /import → 200 / 400 / 500
Content-Type: application/json
// Body: ExportData JSON, max 50 MB
→ 200 ImportResult
→ 400 {"error": "invalid json: <details>"}
```

Body capped at 50 MB via `http.MaxBytesReader`. Restores observations,
sessions, prompts.

---

#### 19. `GET /stats`

```http
GET /stats → 200
→ 200 Stats
```

`Stats` shape (from `internal/store/store.go:71`):

```go
type Stats struct {
    TotalSessions     int      `json:"total_sessions"`
    TotalObservations int      `json:"total_observations"`
    TotalPrompts      int      `json:"total_prompts"`
    Projects          []string `json:"projects"`
}
```

---

#### 20. `POST /projects/migrate`

```http
POST /projects/migrate → 200 / 400 / 500
Content-Type: application/json
// Body capped at 1 KB
{"old_project": "Engram", "new_project": "engram"}

→ 200 {"status": "migrated", "old_project": "...", "new_project": "...",
       "observations": <int>, "sessions": <int>, "prompts": <int>}
→ 200 {"status": "skipped", "reason": "names are identical" | "no records found"}
→ 400 {"error": "old_project and new_project are required"}
```

Bulk-renames a project across observations, sessions, prompts. Used to fix
project-name drift (e.g. `Engram` vs `engram-memory` vs `ENGRAM`). The
`mem_merge_projects` MCP tool wraps this with a comma-separated `from` list.

`MigrateResult` shape (from `store.go:2251`):

```go
type MigrateResult struct {
    Migrated            bool  `json:"migrated"`
    ObservationsUpdated int64 `json:"observations_updated"`
    SessionsUpdated     int64 `json:"sessions_updated"`
    PromptsUpdated      int64 `json:"prompts_updated"`
}
```

---

#### 21. `GET /sync/status`

```http
GET /sync/status → 200
// Sync disabled:
{"enabled": false, "message": "background sync is not configured"}
// Sync enabled:
{"enabled": true, "phase": "<text>", "last_error": "<text>",
 "consecutive_failures": <int>, "backoff_until": "<rfc3339>",
 "last_sync_at": "<rfc3339>"}
```

The cloud-sync feature is opt-in. If `s.syncStatus == nil`, returns the
disabled stub. Reveried can ship the disabled stub on day one and add real
sync as a follow-up.

---

## Section 2 — MCP tools (16 tools)

Tools registered in `internal/mcp/mcp.go::registerTools`. Each tool has an
allowlist gate (`shouldRegister`) so the same binary serves multiple
profiles:

- **`--tools=agent`**: 12 tools — the default for Claude Code MCP integration.
- **all 16**: includes admin tools (`mem_delete`, `mem_stats`, `mem_timeline`,
  `mem_merge_projects`).

### Per-tool annotation values

Every engram MCP tool sets four annotation hints. Reveried's MCP adapter must
register tools with the same values for client compat. From
`internal/mcp/mcp.go::registerTools`:

| Tool | ReadOnly | Destructive | Idempotent | OpenWorld | Defer |
|---|:---:|:---:|:---:|:---:|:---:|
| `mem_search` | ✓ | · | ✓ | · | · |
| `mem_save` | · | · | · | · | · |
| `mem_update` | · | · | · | · | ✓ |
| `mem_suggest_topic_key` | ✓ | · | ✓ | · | ✓ |
| `mem_delete` | · | ✓ | · | · | ✓ |
| `mem_save_prompt` | · | · | · | · | · |
| `mem_context` | ✓ | · | ✓ | · | · |
| `mem_stats` | ✓ | · | ✓ | · | ✓ |
| `mem_timeline` | ✓ | · | ✓ | · | ✓ |
| `mem_get_observation` | ✓ | · | ✓ | · | · |
| `mem_session_summary` | · | · | · | · | · |
| `mem_session_start` | · | · | ✓ | · | ✓ |
| `mem_session_end` | · | · | ✓ | · | ✓ |
| `mem_capture_passive` | · | · | ✓ | · | ✓ |
| `mem_merge_projects` | · | ✓ | ✓ | · | ✓ |

(`mem_session_summary` and `mem_context` are tagged "core — always in
context" in source comments — they are NOT deferred even though some have
`OpenWorld=false`.)

### Tool inventory + signatures

#### `mem_save` (agent)

```
title:      string  *required* — short, searchable
content:    string  *required* — structured (**What/Why/Where/Learned**)
type:       string  — decision|architecture|bugfix|pattern|config|discovery|learning|manual
session_id: string  — default "manual-save-{project}"
project:    string  — falls back to cfg.DefaultProject
scope:      string  — project (default) | personal
topic_key:  string  — opt-in upsert key, e.g. "architecture/auth-model"
```

Returns plain text with the new observation ID. **Backed by
`store.AddObservation` — same code path as `POST /observations`** — so all
the upsert/dedup/normalization rules in §4 apply identically.

---

#### `mem_search` (agent, read-only)

```
query:   string  *required*
type:    string  — filter
project: string  — filter (defaults to cfg.DefaultProject if empty)
scope:   string  — filter
limit:   number  — default 10, max 20
```

Returns formatted multi-line text — `[N] #<id> (type) — title\n  <preview>\n  ...`.
Previews truncate at 300 chars and append a `[preview]` marker; the result
text includes a footer instructing the agent to call `mem_get_observation`
for the full body.

---

#### `mem_update` (agent, deferred)

```
id:        number  *required*
title:     string  — partial update
content:   string  — partial update
type:      string  — partial update
project:   string  — partial update
scope:     string  — partial update
topic_key: string  — partial update
```

Same shape as `PATCH /observations/{id}`.

---

#### `mem_suggest_topic_key` (agent, read-only, deferred)

```
type:    string  — observation type
title:   string  — preferred input
content: string  — fallback if title empty
```

Pure function (no DB writes) — generates a stable slug from
`type/title-slugified`. Used by Claude before calling `mem_save` when it
wants the next save to upsert an existing observation.

---

#### `mem_delete` (admin, deferred)

```
id:          number  *required*
hard_delete: boolean — default false (soft delete)
```

Same as `DELETE /observations/{id}?hard=...`.

---

#### `mem_save_prompt` (agent)

```
content:    string  *required*
session_id: string  — default "manual-save-{project}"
project:    string
```

Same as `POST /prompts`.

---

#### `mem_context` (agent, read-only — core, always loaded)

```
project: string  — filter
scope:   string  — project (default) | personal
limit:   number  — default 20
```

Returns the formatted markdown context blob (sessions + observations +
prompts), same as `GET /context`. **This is what the SessionStart hook
calls to inject context into Claude's system reminder.**

---

#### `mem_stats` (admin, read-only, deferred)

No args. Returns text summary of total counts.

---

#### `mem_timeline` (admin, read-only, deferred)

```
observation_id: number  *required*
before:         number  — default 5
after:          number  — default 5
```

Same as `GET /timeline`.

---

#### `mem_get_observation` (agent, read-only)

```
id: number  *required*
```

Returns the full content + metadata of one observation. Called after
`mem_search` to get the untruncated body.

---

#### `mem_session_summary` (agent — core, always loaded)

```
session_id: string  *required*
content:    string  *required* — must use the structured "## Goal /
                                  ## Instructions / ## Discoveries /
                                  ## Accomplished / ## Goal Achievement"
                                  format documented in the tool description
project:    string
```

Saves a session summary to the `sessions.summary` column. The structured
format is enforced by tool description, not validated server-side.

---

#### `mem_session_start` (agent, deferred)

```
id:        string  *required*
project:   string  *required*
directory: string  — optional
```

Same as `POST /sessions`.

---

#### `mem_session_end` (agent, deferred)

```
id:      string  *required*
summary: string  — optional
```

Same as `POST /sessions/{id}/end`.

---

#### `mem_capture_passive` (agent, deferred)

```
content:    string  *required*
session_id: string
project:    string
source:     string  — e.g. "subagent-stop", "session-end"
```

Same as `POST /observations/passive`.

---

#### `mem_merge_projects` (admin, destructive, deferred)

```
from: string  *required* — comma-separated list of source project names
to:   string  *required* — canonical destination project name
```

Wraps `POST /projects/migrate`, applied iteratively for each source name.

---

## Section 3 — SQLite schema

Schema lives in `internal/store/store.go::migrate()` starting at line 437.
Migrations are forward-only and idempotent (`CREATE TABLE IF NOT EXISTS`,
`addColumnIfNotExists` helper for column additions, `migrateLegacyObservationsTable`
for the one historical destructive migration).

### Tables (7)

#### `sessions`

```sql
CREATE TABLE sessions (
    id         TEXT PRIMARY KEY,
    project    TEXT NOT NULL,
    directory  TEXT NOT NULL,
    started_at TEXT NOT NULL DEFAULT (datetime('now')),
    ended_at   TEXT,
    summary    TEXT
);
```

#### `observations`

```sql
CREATE TABLE observations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    sync_id         TEXT,
    session_id      TEXT    NOT NULL REFERENCES sessions(id),
    type            TEXT    NOT NULL,
    title           TEXT    NOT NULL,
    content         TEXT    NOT NULL,
    tool_name       TEXT,
    project         TEXT,
    scope           TEXT    NOT NULL DEFAULT 'project',
    topic_key       TEXT,
    normalized_hash TEXT,
    revision_count  INTEGER NOT NULL DEFAULT 1,
    duplicate_count INTEGER NOT NULL DEFAULT 1,
    last_seen_at    TEXT,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    deleted_at      TEXT
);
```

#### `user_prompts`

```sql
CREATE TABLE user_prompts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    sync_id    TEXT,
    session_id TEXT    NOT NULL REFERENCES sessions(id),
    content    TEXT    NOT NULL,
    project    TEXT,
    created_at TEXT    NOT NULL DEFAULT (datetime('now'))
);
```

### Response value shapes (Go structs from store.go)

These are the wire shapes for `GET /timeline`, `GET /export`, `POST /import`,
`POST /projects/migrate`, `GET /stats`, `POST /observations/passive`, and the
`compact` flag on `GET /context`. All field names + JSON tags must be
replicated exactly in reveried's Rust types so the differential smoke test
([TOD-368](https://linear.app/todie/issue/TOD-368)) passes.

```go
// internal/store/store.go:78
type TimelineEntry struct {
    ID             int64   `json:"id"`
    SessionID      string  `json:"session_id"`
    Type           string  `json:"type"`
    Title          string  `json:"title"`
    Content        string  `json:"content"`
    ToolName       *string `json:"tool_name,omitempty"`
    Project        *string `json:"project,omitempty"`
    Scope          string  `json:"scope"`
    TopicKey       *string `json:"topic_key,omitempty"`
    RevisionCount  int     `json:"revision_count"`
    // ... other Observation fields follow
}

// internal/store/store.go:97
type TimelineResult struct {
    Focus        Observation     `json:"focus"`        // anchor observation
    Before       []TimelineEntry `json:"before"`       // chronological
    After        []TimelineEntry `json:"after"`        // chronological
    SessionInfo  *Session        `json:"session_info"` // containing session
    TotalInRange int             `json:"total_in_range"`
}

// internal/store/store.go:231
type ExportData struct {
    Version      string        `json:"version"`
    ExportedAt   string        `json:"exported_at"`
    Sessions     []Session     `json:"sessions"`
    Observations []Observation `json:"observations"`
    Prompts      []Prompt      `json:"prompts"`
}

// internal/store/store.go:1851
type ImportResult struct {
    SessionsImported     int `json:"sessions_imported"`
    ObservationsImported int `json:"observations_imported"`
    PromptsImported      int `json:"prompts_imported"`
}

// internal/store/store.go:2251 — note: type is `MigrateResult`, NOT `MigrationResult`
type MigrateResult struct {
    Migrated            bool  `json:"migrated"`
    ObservationsUpdated int64 `json:"observations_updated"`
    SessionsUpdated     int64 `json:"sessions_updated"`
    PromptsUpdated      int64 `json:"prompts_updated"`
}

// internal/store/store.go:71
type Stats struct {
    TotalSessions     int      `json:"total_sessions"`
    TotalObservations int      `json:"total_observations"`
    TotalPrompts      int      `json:"total_prompts"`
    Projects          []string `json:"projects"`
}

// internal/store/store.go:3442
type PassiveCaptureResult struct {
    Extracted  int `json:"extracted"`  // total learnings found in text
    Saved      int `json:"saved"`      // new observations created
    Duplicates int `json:"duplicates"` // skipped (already existed)
}

// internal/store/store.go:1618
type ContextOptions struct {
    Limit   int  // 0 → use MaxContextResults default
    Compact bool // false → render full content previews; true → compact mode
}
```

### Out of scope for reveried — `migrateLegacyObservationsTable`

Engram has one historical destructive migration
(`internal/store/store.go:564::migrateLegacyObservationsTable`) that
converts pre-v0.x schemas to the current observations table. **Reveried
does not implement this.** It only matters for users coming from very old
engram versions; current users have already been migrated. If reveried
opens an unmigrated DB it should error loudly with a "run engram once to
migrate first" message rather than attempting the migration itself.

#### Sync tables (post-MVP, can stub)

```sql
CREATE TABLE sync_chunks (
    chunk_id    TEXT PRIMARY KEY,
    imported_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE sync_state (
    target_key           TEXT PRIMARY KEY,
    lifecycle            TEXT NOT NULL DEFAULT 'idle',
    last_enqueued_seq    INTEGER NOT NULL DEFAULT 0,
    last_acked_seq       INTEGER NOT NULL DEFAULT 0,
    last_pulled_seq      INTEGER NOT NULL DEFAULT 0,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    backoff_until        TEXT,
    lease_owner          TEXT,
    lease_until          TEXT,
    last_error           TEXT,
    updated_at           TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE sync_mutations (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
    target_key  TEXT NOT NULL REFERENCES sync_state(target_key),
    entity      TEXT NOT NULL,
    entity_key  TEXT NOT NULL,
    op          TEXT NOT NULL,
    payload     TEXT NOT NULL,
    source      TEXT NOT NULL DEFAULT 'local',
    occurred_at TEXT NOT NULL DEFAULT (datetime('now')),
    acked_at    TEXT,
    project     TEXT NOT NULL DEFAULT ''
);

CREATE TABLE sync_enrolled_projects (
    project     TEXT PRIMARY KEY,
    enrolled_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

### Virtual tables (FTS5)

```sql
CREATE VIRTUAL TABLE observations_fts USING fts5(
    title, content, tool_name, type, project, topic_key,
    content='observations', content_rowid='id'
);

CREATE VIRTUAL TABLE prompts_fts USING fts5(
    content, project,
    content='user_prompts', content_rowid='id'
);
```

Both use FTS5's `external content` mode (`content=`+`content_rowid=`),
which means **the FTS index is kept in sync via triggers** rather than
storing the data twice. The full set of triggers from
`internal/store/store.go:644-693`:

```sql
-- observations_fts ai/au/ad triggers
CREATE TRIGGER obs_fts_insert AFTER INSERT ON observations BEGIN
    INSERT INTO observations_fts(rowid, title, content, tool_name, type, project, topic_key)
    VALUES (new.id, new.title, new.content, new.tool_name, new.type, new.project, new.topic_key);
END;

CREATE TRIGGER obs_fts_delete AFTER DELETE ON observations BEGIN
    INSERT INTO observations_fts(observations_fts, rowid, title, content, tool_name, type, project, topic_key)
    VALUES ('delete', old.id, old.title, old.content, old.tool_name, old.type, old.project, old.topic_key);
END;

CREATE TRIGGER obs_fts_update AFTER UPDATE ON observations BEGIN
    INSERT INTO observations_fts(observations_fts, rowid, title, content, tool_name, type, project, topic_key)
    VALUES ('delete', old.id, old.title, old.content, old.tool_name, old.type, old.project, old.topic_key);
    INSERT INTO observations_fts(rowid, title, content, tool_name, type, project, topic_key)
    VALUES (new.id, new.title, new.content, new.tool_name, new.type, new.project, new.topic_key);
END;

-- prompts_fts ai/au/ad triggers (store.go:678+)
CREATE TRIGGER prompt_fts_insert AFTER INSERT ON user_prompts BEGIN
    INSERT INTO prompts_fts(rowid, content, project)
    VALUES (new.id, new.content, new.project);
END;

CREATE TRIGGER prompt_fts_delete AFTER DELETE ON user_prompts BEGIN
    INSERT INTO prompts_fts(prompts_fts, rowid, content, project)
    VALUES ('delete', old.id, old.content, old.project);
END;

CREATE TRIGGER prompt_fts_update AFTER UPDATE ON user_prompts BEGIN
    INSERT INTO prompts_fts(prompts_fts, rowid, content, project)
    VALUES ('delete', old.id, old.content, old.project);
    INSERT INTO prompts_fts(rowid, content, project)
    VALUES (new.id, new.content, new.project);
END;
```

Reveried's storage migration must create these triggers verbatim — without
them, INSERT/UPDATE/DELETE on the base tables won't propagate to the FTS
indexes and search results will diverge from engram.

### Indexes

```sql
CREATE INDEX idx_obs_session  ON observations(session_id);
CREATE INDEX idx_obs_type     ON observations(type);
CREATE INDEX idx_obs_project  ON observations(project);
CREATE INDEX idx_obs_created  ON observations(created_at DESC);
CREATE INDEX idx_obs_scope    ON observations(scope);
CREATE INDEX idx_obs_sync_id  ON observations(sync_id);
CREATE INDEX idx_obs_topic    ON observations(topic_key, project, scope, updated_at DESC);
CREATE INDEX idx_obs_deleted  ON observations(deleted_at);
CREATE INDEX idx_obs_dedupe   ON observations(normalized_hash, project, scope, type, title, created_at DESC);
CREATE INDEX idx_prompts_session ON user_prompts(session_id);
CREATE INDEX idx_prompts_project ON user_prompts(project);
CREATE INDEX idx_prompts_created ON user_prompts(created_at DESC);
CREATE INDEX idx_prompts_sync_id ON user_prompts(sync_id);
CREATE INDEX idx_sync_mutations_target_seq ON sync_mutations(target_key, seq);
CREATE INDEX idx_sync_mutations_pending    ON sync_mutations(target_key, acked_at, seq);
CREATE INDEX idx_sync_mutations_project    ON sync_mutations(project);
```

### Migration backfills

Engram's `migrate()` function runs these UPDATE statements on existing
databases to fill in fields added in later migrations. **Reveried's compat
layer must be a no-op against an already-migrated DB** — these are safe to
re-run because they all use `WHERE x IS NULL OR x = ''` guards:

```sql
UPDATE observations SET scope = 'project' WHERE scope IS NULL OR scope = '';
UPDATE observations SET topic_key = NULL WHERE topic_key = '';
UPDATE observations SET revision_count = 1 WHERE revision_count IS NULL OR revision_count < 1;
UPDATE observations SET duplicate_count = 1 WHERE duplicate_count IS NULL OR duplicate_count < 1;
UPDATE observations SET updated_at = created_at WHERE updated_at IS NULL OR updated_at = '';
UPDATE observations SET sync_id = 'obs-' || lower(hex(randomblob(16))) WHERE sync_id IS NULL OR sync_id = '';

UPDATE user_prompts SET project = '' WHERE project IS NULL;
UPDATE user_prompts SET sync_id = 'prompt-' || lower(hex(randomblob(16))) WHERE sync_id IS NULL OR sync_id = '';

INSERT OR IGNORE INTO sync_state (target_key, lifecycle, updated_at)
VALUES ('cloud', 'idle', datetime('now'));
```

---

## Section 4 — Quirks + edge cases

### Project name normalization (`store.go:3216`)

```go
func NormalizeProject(project string) (normalized, warning string) {
    n := strings.TrimSpace(strings.ToLower(project))
    // Collapse multiple consecutive hyphens / underscores.
    for strings.Contains(n, "--") { n = strings.ReplaceAll(n, "--", "-") }
    for strings.Contains(n, "__") { n = strings.ReplaceAll(n, "__", "_") }
    return n, "<warning if changed>"
}
```

Applied on **every read and every write path** that accepts a `project`
filter or value. Reveried must apply the same rules or queries will silently
miss observations.

### Topic key normalization (`store.go:3340`)

```go
func normalizeTopicKey(topic string) string {
    v := strings.TrimSpace(strings.ToLower(topic))
    if v == "" { return "" }
    v = strings.Join(strings.Fields(v), "-")  // collapse all whitespace runs to single hyphen
    if len(v) > 120 { v = v[:120] }            // hard cap at 120 chars
    return v
}
```

### Scope normalization (`store.go:3203`)

```go
func normalizeScope(scope string) string {
    v := strings.TrimSpace(strings.ToLower(scope))
    if v == "personal" { return "personal" }
    return "project"  // <-- the default for ANY other value (including empty)
}
```

Only `personal` and `project` exist. Anything else collapses to `project`.

### Content normalization for dedup hashing (`store.go:3359`)

```go
func hashNormalized(content string) string {
    normalized := strings.ToLower(strings.Join(strings.Fields(content), " "))
    return hex.EncodeToString(sha256.Sum256([]byte(normalized))[:])
}
```

`strings.Fields` collapses all whitespace runs (including newlines). So
`"Foo\n bar"` and `"foo bar"` produce the same hash.

### `<private>` tag stripping (`store.go:3412`)

```go
var privateTagRegex = ...   // matches <private>...</private>

func stripPrivateTags(s string) string {
    result := privateTagRegex.ReplaceAllString(s, "[REDACTED]")
    return strings.TrimSpace(result)
}
```

Applied to **both title and content** on every save. Used by callers who
want to mark sensitive substrings as session-only — the substring becomes
`[REDACTED]` in the persisted row.

### `AddObservation` upsert pipeline (`store.go:948`)

This is the central save path used by both `POST /observations` and
`mem_save`. The order of operations matters for compat:

1. **Normalize project** via `NormalizeProject`.
2. **Strip `<private>` tags** from title + content.
3. **Truncate content** to `cfg.MaxObservationLength`, append
   `"... [truncated]"` if cut. (Default is large; check store config.)
4. **Normalize scope** (`personal` or `project`).
5. **Compute `normalized_hash`** from the truncated/stripped content.
6. **Normalize topic_key** (lowercase, hyphenate spaces, cap at 120 chars).
7. **If `topic_key != ""`** → look up the most recent live observation in
   the same `(topic_key, project, scope)` tuple and **UPDATE in place**:
   - bumps `revision_count`
   - rewrites `type`, `title`, `content`, `tool_name`, `topic_key`, `normalized_hash`
   - sets `last_seen_at = updated_at = datetime('now')`
   - returns the existing ID
8. **Else** → look up an observation with the same `(normalized_hash,
   project, scope, type, title)` created within the **dedupe window**
   (default 15 minutes, configurable via `cfg.DedupeWindow`):
   - if found, bump `duplicate_count` + `last_seen_at` + `updated_at`,
     return the existing ID (no rewrite)
9. **Else** → INSERT a new row with a fresh `sync_id` (`obs-<32 hex>`).
10. **Enqueue a sync mutation** for the cloud sync target.

The upsert window default of 15 minutes means: saving the same observation
twice within 15 minutes bumps `duplicate_count`. Saving it again at minute
16 creates a new row.

### `dedupeWindowExpression` (`store.go:3365`)

```go
func dedupeWindowExpression(window time.Duration) string {
    if window <= 0 { window = 15 * time.Minute }
    minutes := int(window.Minutes())
    if minutes < 1 { minutes = 1 }
    return "-" + strconv.Itoa(minutes) + " minutes"
}
```

The returned string goes into a `datetime('now', ?)` SQLite call. The
floor of 1 minute prevents pathological 0-window deletion loops.

### FTS5 query sanitization (`store.go:3421`)

```go
func sanitizeFTS(query string) string {
    words := strings.Fields(query)
    for i, w := range words {
        w = strings.Trim(w, `"`)
        words[i] = `"` + w + `"`
    }
    return strings.Join(words, " ")
}
```

Wraps each whitespace-split term in literal double quotes. Without this,
FTS5's mini-language interprets characters like `:` (column filter), `AND`,
`OR`, `NOT`, `NEAR`, `(`, `)` and produces "no such column" errors on
natural-language input. **Reveried's sqlite-vec backend already does the
equivalent** in `query()` — see the comment on `crates/reverie-store/src/
backends/sqlite_vec.rs::SqliteVecBackend::query`.

### Sync ID generation

Format: `<entity-prefix>-<32 hex chars>` produced by
`'obs-' || lower(hex(randomblob(16)))` in SQL or `newSyncID("obs")` in Go.
Must be globally unique and stable across the lifetime of the row. Reveried
should reuse the same scheme so existing rows from engram.db round-trip
through Reverie unchanged.

### Soft deletes

Setting `deleted_at = datetime('now')` rather than removing the row. All
read paths add `WHERE deleted_at IS NULL` filters. Hard delete (DELETE
statement) is only triggered by `?hard=true` on the HTTP route or
`hard_delete: true` on the MCP tool.

### Authentication / binding

No authentication. Engram binds to `127.0.0.1:7437` by default. Anything on
the local machine can talk to it. Reveried should match — if you need
multi-machine, use the sync features, not network exposure.

### Write notification (`s.notifyWrite()`)

Every write handler calls `s.notifyWrite()` which signals a channel that
the sync subsystem watches. When sync is disabled, the channel has no
readers and the call is a no-op. When implementing in Rust, this becomes
either a `tokio::sync::Notify` or just a no-op until sync ships.

---

## Section 5 — Reverie mapping (implementation guidance)

Concrete translation from engram concepts to Reverie types:

| Engram concept | Reverie equivalent | Notes |
|---|---|---|
| `observations` row | `reverie_store::Chunk` | Reverie's Chunk is a strict superset; the engram fields all map directly. See mapping table below. |
| `sessions` row | New `sessions` table OR `Chunk { kind: Session }` | I recommend a **dedicated `sessions` table** for MVP — the lookup patterns (by session_id from observations) are point-queries, not graph traversals, and a join table is simpler than synthetic Chunks. |
| `user_prompts` row | New `user_prompts` table OR `Chunk { kind: ??? }` | Same recommendation — dedicated table. |
| `sync_*` tables | Stub for MVP | Reveried can implement `GET /sync/status` returning `{enabled: false}` and skip the rest. Add real sync as a follow-up ticket. |

### `Observation` → `Chunk` field mapping

```
engram.id              → chunks.rowid (autoincrement INTEGER) — keep this
                         numeric so existing engram observation IDs in
                         hooks and skills round-trip.
engram.sync_id         → chunks.sync_id  (new column)
engram.session_id      → chunks.session_id (new column, FK to sessions)
engram.type            → chunks.kind  — but engram uses a free-text type
                         column while reverie's Chunk has an enum. Solution:
                         keep BOTH a free-text `type` column for compat
                         AND derive `kind` from it on read.
engram.title           → chunks.title
engram.content         → chunks.content (Reverie's body field)
engram.tool_name       → chunks.tool_name (new nullable column)
engram.project         → chunks.source_project (rename in Reverie)
engram.scope           → chunks.scope (new column — `project`|`personal`)
                         OR derive from canonical_layer.
engram.topic_key       → chunks.topic_key (already exists)
engram.normalized_hash → chunks.normalized_hash (new column)
engram.revision_count  → chunks.revision_count (already exists)
engram.duplicate_count → chunks.duplicate_count (new column)
engram.last_seen_at    → chunks.last_accessed (already exists, semantics match)
engram.created_at      → chunks.created (already exists)
engram.updated_at      → chunks.updated_at (new column OR derived from version bumps)
engram.deleted_at      → chunks.deleted_at (new column) OR
                         consolidation_status = Archived (less faithful)
```

Reverie's neuroscience-only fields (`strength`, `depth_score`, `stability`,
`signal_score`, `staleness_score`, `session_spread`, `consolidation_status`)
have no engram equivalent — populate them with sensible defaults on import:

```rust
strength: 1.0,
depth_score: 1,
stability: 1.0,
signal_score: 0.0,
staleness_score: 0.0,
session_spread: 1,
consolidation_status: ConsolidationStatus::Staged,
schema_id: "reverie.chunk.v1".to_string(),
version: 1,
related_to: vec![],
supersedes: None,
superseded_by: None,
```

### Reverie should reuse existing engram.db (compat layer, not migration)

The cleanest cutover path is **read/write the existing `engram.db` file
directly** rather than migrating to a separate `reverie.db`. Reasons:

1. **Instant rollback.** If reveried has a bug, stop it, restart engram,
   no data movement needed.
2. **Zero downtime.** No migration window where the user can't save new
   observations.
3. **Schema is already compatible.** Reveried can add new columns via
   `ALTER TABLE` migrations that are no-ops on the engram-managed columns.
4. **Sync coexistence.** As long as both daemons aren't running
   simultaneously, the WAL+SQLite locking is sufficient.

Reverie's neuroscience fields become **new nullable columns** added by
reveried's migration on first start. Engram doesn't read them; reveried
populates them lazily as observations are touched. Pre-existing engram
observations get default values (`strength=1.0`, etc.) on first read.

### Implementation order

Follow the MVP critical path:

1. **TOD-266 (this doc)** ✅
2. Implement reveried HTTP server matching §1 routes 1-1.
3. Implement reveried MCP stdio adapter matching §2 tool surface 1-1.
4. Implement schema-compat layer: open existing `engram.db`, add reveried's
   new columns via `ALTER TABLE`, populate defaults.
5. Differential smoke test: replay every `mem` bash command + every MCP
   tool call against both `engram` and `reveried`, diff the JSON output.
6. Cutover (TOD-271): stop engram, swap `~/.local/bin/engram` symlink to
   reveried, restart Claude Code MCP. Rollback = revert symlink.

---

## Status

| Section | Status |
|---|---|
| §1 HTTP routes — inventory + per-route shapes | ✅ |
| §2 MCP tools — inventory + per-tool args | ✅ |
| §3 SQL schema — tables + columns + indexes + virtual tables | ✅ |
| §4 Quirks — normalization, dedup, FTS sanitization, soft delete | ✅ |
| §5 Reverie mapping — Chunk field mapping + cutover strategy | ✅ |

This document is the deliverable for [TOD-266](https://linear.app/todie/issue/TOD-266).
With this in hand, the next critical-path tickets (TOD-268 HTTP server,
TOD-269 MCP stdio adapter) can be implemented in parallel.
