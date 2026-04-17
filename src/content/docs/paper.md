# Reverie: A Neuroscience-Grounded Memory Consolidation Framework for LLM Coding Harnesses

**Status:** Skeleton (TOD-402). Benchmark numbers land in TOD-411.

## 1. Abstract

Reverie is a memory framework for LLM coding harnesses that treats long-term knowledge as a tiered cache hierarchy rather than a flat vector store. It combines a six-type, five-layer **placement taxonomy** (where each piece of knowledge belongs and why) with an offline **dream cycle** (scan, classify, place, consolidate, prune, sync) modeled on biological sleep consolidation. This paper documents the framework, the empirical audit that motivated it (105 observations, 62% tombstone rate), the SOTA survey that situates it against EverMemOS, CORE, Letta, A-MEM, Zep, and Mem0, and the evaluation plan against LoCoMo and LongMemEval. The 150-word elevator pitch goes here once the placeholder text is replaced with the final framing — covering placement taxonomy, dream cycle, and the LoCoMo wins TOD-411 will report.

- Elevator pitch (~150 words)
- Headline metrics: LoCoMo F1, write-churn reduction, placement-error reduction
- Framework one-liner: "Better architecture, not more memory"
- Source: obs #270, #272, #279, #280, #281, #283

## 2. Motivation

Modern LLM coding harnesses (Claude Code, Cursor, Windsurf) accumulate knowledge across sessions but lack a theory of where that knowledge belongs. The default pattern — dump everything into one vector store — degrades over time through duplication, misplacement, noise, and staleness. A full audit of the author's own engram-era memory stack (105 observations, 7 auto-memory files, 140 Obsidian notes, CLAUDE.md, three rules files) found a 62% ID tombstone rate from over-aggressive write-then-delete churn, nine cross-layer duplicates of a single rule ("Rust by default"), 14 observations with the wrong project tag, and behavioral directives stranded in search-only layers where they were never loaded. The binding constraint is not storage capacity but instruction-layer capacity (~200 lines of CLAUDE.md before adherence drops). Placement is a zero-sum game at the top of the hierarchy.

- 62% write-then-delete churn (obs #270, F9)
- 9 cross-layer duplicates of a single rule (obs #270, F2)
- 14 wrong-project tags + 38 empty project fields (obs #270, F4)
- CLAUDE.md adherence drop above ~200 lines (obs #270, F3)
- Engram serving 4 incompatible roles simultaneously (obs #270, F1)
- No consolidation pass — every write is permanent until manually pruned
- Source: obs #270 (13 findings), obs #272 (anti-patterns)

## 3. Placement taxonomy

Reverie classifies every piece of knowledge along two axes: a **type** (one of six knowledge categories) and a **persistence layer** (one of five tiers analogous to a CPU cache). The decision tree from obs #272 routes each new observation to exactly one home, eliminating dual-write duplication. The six knowledge types are: (1) session-loaded directives, (2) user feedback corrections, (3) user preferences/identity, (4) deep reference knowledge, (5) curated principle collections, and (6) project decisions/architecture/bugs. The five layers — registers, L1, RAM, disk, cold store — map onto CLAUDE.md, auto-memory, the reveried SQLite store, the Obsidian vault, and code+git respectively. A seventh implicit rule ("derivable from code → don't store") is unique to coding-harness memory and absent from every competing system surveyed.

- 6 knowledge types (directives, feedback, preferences, reference, MOCs, project decisions)
- 5 layers: registers (CLAUDE.md) / L1 (auto-memory) / RAM (reveried) / disk (Obsidian) / cold (code+git)
- Decision tree (8 branches) — obs #272
- Anti-patterns: same fact in 2+ layers, directive in search-only layer, sync without dedup, project field inherited from session not content, historical snapshot as directive
- Cognitive mapping: hippocampus = working memory layers, neocortex = long-term layers, sleep replay = session summary, reconsolidation = topic_key upsert, forgetting = compaction
- Source: obs #272, #270 (F1, F2, F11, F13)

## 4. Architecture

Reverie ships as `reveried`, a single-process daemon that wires four crates (`reverie-store`, `reverie-gate`, `reverie-dream`, `reverie-sync`) behind one MCP and HTTP surface. Every write flows through the **write-gate pipeline**, which classifies the knowledge type, checks for cross-layer duplicates, enforces the derivability rule, and either accepts the write into the staging tier or rejects it with a placement suggestion. A separate **dream runner** wakes on a four-tier schedule (session-end, nightly, weekly, monthly) and walks the consolidation pipeline. The architecture deliberately keeps the fast path (gate → staging) and the slow path (dream → consolidated store) on separate code paths — direct writes to the consolidated tier would cause the catastrophic interference that CLS theory predicts.

- `reveried` daemon: store + gate + dream + sync in one process
- Crates: `reverie-store` (SQLite + FTS5 + sqlite-vec), `reverie-gate` (placement, dedup, derivability, budget), `reverie-dream` (6-phase pipeline), `reverie-sync` (Obsidian, auto-memory, CLAUDE.md adapters), `reverie-bench` (LoCoMo harness)
- Write-gate pipeline: classify → dedup → derivability → budget → staging
- Diagrams (TBD): daemon process diagram, gate state machine, dream scheduler timeline
- Cross-references: TOD-396 (gate trait), TOD-397 (dream runner)
- Source: README workspace table, obs #280 (CLS fast/slow path separation)

## 5. The dream cycle

The dream cycle is a six-phase offline pipeline that runs while the harness is idle: **scan** (priority queue ordered by recency × access × importance × novelty, not FIFO), **classify** (assign knowledge type via the placement taxonomy), **place** (route to the correct layer), **consolidate** (gist extraction, schema interleaving, reconsolidation on access), **prune** (SHY-style global proportional decay, archive then delete), and **sync** (push canonical copies into Obsidian / auto-memory / CLAUDE.md without re-introducing duplicates). Each phase maps onto a specific neuroscience mechanism documented in obs #280: SWR replay drives the priority queue, systems consolidation drives the staging-to-consolidated promotion, schema theory governs the classify/place decisions, synaptic homeostasis (SHY) governs the prune phase, and reconsolidation makes every read a write opportunity.

- 6 phases: scan → classify → place → consolidate → prune → sync
- 4-tier schedule: session-end (SWR replay), nightly (systems consolidation + CLS interleaving), weekly (SHY decay + interference audit), monthly (schema evolution)
- 10 neuroscience mechanisms: SWR replay, systems consolidation, CLS, reconsolidation, schema theory, SHY, behavioral tagging, interference, levels of processing, spacing effect
- New data-model fields: strength, depth_score, session_spread, stability, importance_tag, consolidation_status
- Critical principle: consolidation is not summarization (summarization is ~25% of biological consolidation)
- Cross-references: TOD-400 (scan), TOD-406 (classify), TOD-407 (place), TOD-408 (consolidate), TOD-409 (prune)
- Source: obs #280

## 6. Evaluation

Reverie is evaluated on three axes: (1) **LoCoMo F1** (Maharana et al., arXiv:2402.17753) — 50 conversations, 305 turns average, 7,512 questions across single-hop / multi-hop / temporal / commonsense / adversarial — with the observation-RAG top-5 baseline at 41.4% and the current SOTA leaderboard ranging from Mem0 (66.9%) to EverMemOS (92.3%); (2) **LongMemEval** (ICLR 2025, 500 questions, up to 1.5M tokens) for long-horizon stress; and (3) **write-churn reduction** measured against the 62% tombstone-rate baseline from the engram-era audit. Ablation graphs will isolate the contribution of the gate, the dream cycle, hybrid search, and entity resolution. Final numbers land with TOD-411.

<!-- TODO(TOD-411): fill in real numbers -->

- LoCoMo F1 table (vs EverMemOS 92.3%, Backboard 90.1%, Hindsight 89.6%, Zep 75.1%, Mem0 66.9%, LangMem 58.1%, engram baseline 80%)
- LongMemEval scores (single-session, multi-session, temporal, knowledge-update, abstention)
- Write-churn reduction vs 62% tombstone baseline
- Ablation: gate-only / dream-only / gate+dream / +hybrid search / +entity resolution
- Per-question-type breakdown (single-hop, multi-hop, temporal, commonsense, adversarial)
- Cross-references: TOD-401 (churn bench), TOD-410 (LoCoMo impact), TOD-351 (scoped ablation), TOD-354 (LongMemEval)
- Source: obs #281, #283

## 7. Related work

The 2025-2026 LLM-memory landscape splits into four families: (1) **brain-inspired consolidation** (EverMemOS 92.3%, Hindsight 89.6%, A-MEM with Zettelkasten reconsolidation), (2) **temporal knowledge graphs** (CORE 88% with temporal PageRank, Zep/Graphiti 94.8% DMR with a 4-timestamp validity model, Remembra with entity resolution + temporal decay), (3) **OS-style virtual context** (Letta/MemGPT ~83%, modeled on virtual memory paging), and (4) **production CRUD pipelines** (Mem0 66.9% with explicit ADD/UPDATE/DELETE/NOOP, LangMem 58.1% with procedural self-modification). Reverie sits closest to family (1) but borrows the validity-interval idea from Zep and the procedural-memory idea from LangMem. The unique contribution is the derivability rule and the placement taxonomy itself — no surveyed system asks "should this be stored at all?" before writing.

- 9 systems: EverMemOS, CORE, Letta/MemGPT, A-MEM, Zep/Graphiti, Remembra, Mem0, LangMem, Claude auto-memory
- 6 key papers: UC San Diego cache hierarchy (March 2026), Tsinghua "Memory in the Age of AI Agents" (Dec 2025), HAI ACT-R, EverMemOS, MAGMA, H-MEM
- Validates Reverie: gravitational collapse, forgetting-as-feature, 5-layer tiering, topic_key upsert
- Challenges Reverie: no graph structure, no entity resolution, no dynamic promotion/demotion, no validity intervals, no shared cross-agent layer
- Unique to Reverie: derivability rule (coding-harness-specific)
- Source: obs #279

## 8. Anti-patterns

This section catalogs the failure modes a write-gate prevents — drawn from the engram-era audit (obs #270) and the placement-framework anti-patterns list (obs #272). The dominant pattern is **dual-write intent without dedup**: a directive instructs the agent to "save to engram AND Obsidian," and without a gate that recognizes the cross-layer relationship, every save creates a parallel pair that drift apart over time. The audit found this pattern produced five duplicate Obsidian note pairs from a single sync pass, three copies of the same engineering-principles document, and a user profile split across three observations in three different project scopes. Each anti-pattern is paired with the gate rule that catches it.

- Dual-write intent without dedup → cross-layer duplicate detector (obs #270 F12, F2)
- Same fact in 2+ layers → staleness cascade (obs #272)
- Behavioral directive in search-only layer → high blast radius if unloaded (obs #272, obs #270 F1)
- Sync without dedup → parallel notes (obs #270 F7)
- Project field inherited from session, not content → 14 wrong tags (obs #270 F4)
- Historical snapshot in behavioral layer → point-in-time record masquerading as directive (obs #272)
- Engram serving 4 incompatible roles → role confusion (obs #270 F1)
- CLAUDE.md > 200 lines → adherence drop (obs #270 F3)
- 6 session summaries with empty topic_key → unsearchable (obs #270 F8)
- 23 heuristics stored as flat FTS5 rows when graph-shaped → wrong affordance (obs #270 F6)
- Source: obs #270 (13 findings), obs #272 (5 anti-patterns)

## 9. Open-source release notes

Reverie is released under [TBD license] as a drop-in replacement for engram (byte-identical wire compat on the MCP and HTTP surfaces). Existing engram users can swap binaries without touching their database — `reveried` reads the same `~/.engram/engram.db` and exposes the same MCP tool names. New users get a one-line install, a `reveried init` command that scaffolds a config file, and a `reveried dream --dry-run` command that previews what the consolidation pass would do without writing. This section will document install, configuration, the MCP/HTTP API surface, and the migration path from engram once the v0.1 release ships.

- Install: `cargo install reveried` (or prebuilt binaries)
- Quick start: `reveried serve --db ~/.engram/engram.db`
- Configuration: `~/.config/reverie/reveried.toml` (see `docs/reveried-config.md`)
- MCP API: identical to engram (mem_search, mem_save, mem_save_prompt, mem_context, mem_session_summary, mem_session_start, mem_capture_passive)
- HTTP API: identical to engram (see `docs/engram-api-surface.md`)
- Migration from engram: zero-touch, same DB, same wire format (TOD-392 default-path resolution)
- Rollback: keep the engram binary; both daemons read the same DB
- Source: README, `docs/daemon-spec.md`, `docs/reveried-config.md`
