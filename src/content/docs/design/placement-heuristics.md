# Placement Heuristics — Knowledge Type Routing

How to decide where knowledge lives across reverie's 5-layer persistence stack.

Covers: T15 (decision tree), T16 (anti-pattern catalog), T17 (scope/project semantics), T18 (write-side gating).

---

## 1. Decision Tree (T15)

For any piece of knowledge the system considers persisting:

```
Is it a directive Claude must follow every session?
│
├─ YES → CLAUDE.md (if room under ~200 lines) or rules/ file
│        Capacity is zero-sum. Every line added pushes something
│        below the attention threshold.
│
└─ NO
   │
   Is it user feedback correcting Claude behavior?
   │
   ├─ YES → Auto-memory (feedback type)
   │        Loaded every session via MEMORY.md index.
   │        Include why + how-to-apply so edge cases resolve.
   │
   └─ NO
      │
      Is it a user preference or identity trait?
      │
      ├─ YES → Auto-memory (user type)
      │        One consolidated profile, not fragments.
      │
      └─ NO
         │
         Is it deep reference knowledge (books, theory, protocols)?
         │
         ├─ YES → Obsidian (with optional engram pointer)
         │        Wikilinks, MOCs, backlinks. Not searchable by LLM
         │        unless explicitly fetched via MCP.
         │
         └─ NO
            │
            Is it a curated collection of related principles?
            │
            ├─ YES → Obsidian MOC (not individual engram rows)
            │        FTS5 can't express graph relationships.
            │        Bulk-load pattern, not one-at-a-time search.
            │
            └─ NO
               │
               Is it a project decision, architecture, bug, or status?
               │
               ├─ YES → Engram (project-scoped, topic_key set)
               │        On-demand search. ~3ms read. FTS5 keyword.
               │        Dedup via topic_key upsert.
               │
               └─ NO
                  │
                  Is it derivable from code, git, or filesystem?
                  │
                  ├─ YES → Don't store it.
                  │        Code is authoritative. git log has history.
                  │
                  └─ NO → Engram (personal-scoped) as default
                          project="" for cross-cutting knowledge.
```

### Layer properties

| Layer | Auto-loaded? | Capacity | Latency | Affordance |
|-------|-------------|----------|---------|------------|
| CLAUDE.md / rules/ | Yes | ~200 lines (adherence drops after) | 0ms | Directive tone, no search needed |
| Auto-memory (MEMORY.md) | Yes, via index | ~200 line index | 0ms | Behavioral, preference |
| Engram | No — on-demand search | Unbounded | ~3ms read | FTS5 keyword, project-scoped, dedup via topic_key |
| Obsidian | No — explicit fetch | Unbounded | N/A (human browse or MCP) | Wikilinks, MOCs, backlinks, frontmatter |
| Code itself | No | N/A | N/A | git history, types — derivable, authoritative |

---

## 2. Anti-Pattern Catalog (T16)

| Anti-pattern | Example | Root cause | Fix |
|-------------|---------|------------|-----|
| **Same fact in 3+ layers** | "Rust default" in CLAUDE.md + auto-memory + engram + 2 Obsidian notes | Aggressive save policy + no dedup | Single authoritative home per fact |
| **Sync without dedup** | Obsidian has 5+ duplicate pairs from different sync passes | Hook creates notes by observation, not by topic | Content-hash or topic_key-based dedup in sync |
| **Historical snapshot in behavioral layer** | `config_self_improve.md` in auto-memory (point-in-time record, not directive) | Type confusion: was a fact, stored as behavior | Historical → engram, behavioral → auto-memory |
| **Directive in search-only layer** | Ground rules #203, #204 in engram not CLAUDE.md | Didn't exist when rules were written | Promote to always-loaded layer |
| **Flat rows for graph data** | 23 heuristics as individual engram rows vs Obsidian MOC with relationships | FTS5 can't express relationships | Collections → Obsidian MOC, individual lookups → engram |
| **Session context as project tag** | `project=claude-relay` on personal-scope observations | Project inherited from session, not set from content | Explicit project assignment (see §3) |
| **Speculative save + delete** | 61% ID tombstone rate (163 deletions out of 269 IDs) | Write-then-regret pattern | Write-side gating (see §4) |

### Detection signals

- **Duplicate**: same `topic_key` or >0.85 semantic similarity across layers
- **Misplaced directive**: `kind=decision` or `kind=architecture` containing "always", "never", "must" language
- **Stale snapshot**: `updated_at` >30 days + `access_count=0`
- **Orphan pointer**: engram observation references Obsidian note that doesn't exist (or vice versa)

---

## 3. Scope & Project Field Semantics (T17)

### Convention

| scope | project | Meaning |
|-------|---------|---------|
| `personal` | `""` (empty) | Applies to the user across all projects |
| `project` | `reverie` | Applies only within the named project |
| `personal` | `reverie` | **Invalid** — personal scope + specific project is contradictory |

### Rules

1. **Never inherit project from session context.** Set it explicitly based on content. A personal preference discovered during a reverie session is still `project=""`.

2. **`scope=personal` implies `project=""`**. If the content is about the user (identity, preferences, workflow), it's personal-scope regardless of which project surfaced it.

3. **`scope=project` requires a non-empty `project` field.** Project-scoped knowledge without a project tag is unsearchable in project-filtered queries.

4. **Cross-cutting project knowledge** (applies to 2+ projects but not all): use `project=""` with explicit tags listing the relevant projects. Don't duplicate the observation per project.

### Migration

Observations currently violating these rules (identified in T06/T07):
- #2, #7, #8, #9, #10, #21, #173, #174 — personal content tagged with session project
- #175 — sand mandalas (personal philosophy, tagged `claude-relay`)

Fix: batch `mem_update` to correct `project` and `scope` fields.

---

## 4. Write-Side Gating Heuristic (T18)

Before any `mem_save`, answer these four questions. If any answer is "stop", don't write.

### Checklist

1. **Will I need this in a future session?**
   - If the knowledge is only useful right now (debugging state, temporary plan, in-flight task details): **stop**.
   - Session-local context belongs in tasks or conversation, not persistent memory.

2. **Is this already stored elsewhere?**
   - Check: CLAUDE.md, auto-memory MEMORY.md index, `mem_search` for similar topic_key.
   - If found: **stop** (or `mem_update` the existing record).
   - Duplicate writes are the #1 source of memory pollution.

3. **Which layer matches the access pattern?**
   - Apply the decision tree (§1). If the right home is Obsidian or CLAUDE.md, don't default to engram out of convenience.

4. **Is this a fact or a directive?**
   - Facts (architecture decisions, research findings, benchmarks): engram or Obsidian.
   - Directives (behavioral rules, preferences, corrections): CLAUDE.md or auto-memory.
   - Never store a directive in a search-only layer.

### Goal

Reduce the 61% write-then-delete churn rate. Every unnecessary write costs an LLM tool call + MCP round-trip, paid twice when the observation is later deleted.

### Relationship to T34

This section defines the *heuristic* — the questions to ask. T34 (M4) defines the *implementation* — a pre-save hook that automates these checks. The heuristic is the spec; T34 is the code.
