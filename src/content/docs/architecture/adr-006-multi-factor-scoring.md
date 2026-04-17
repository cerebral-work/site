# ADR-006: Multi-Factor Scoring Engine

**Status**: Proposed
**Date**: 2026-04-09

## Context

Reverie retrieval currently uses a 4-factor scoring pipeline in `ChunkStore::hybrid_search()` (`crates/reverie-store/src/backends/sqlite_vec.rs`). The `Chunk` data model (`crates/reverie-store/src/chunk.rs`) carries 4 additional neuroscience-grounded fields that are stored but not yet wired into search ranking. This ADR documents the full 8-factor scoring architecture — what's live, what's parked, and the formulas.

## The 8 Factors

### Group A — Search-time (live in `sqlite_vec.rs`)

| # | Factor | Source | Formula | Status |
|---|--------|--------|---------|--------|
| 1 | **BM25 text relevance** | FTS5 `bm25()` function | SQLite-native; scores are negative (lower = better) | Live |
| 2 | **Vector similarity** | `sqlite-vec` cosine distance | `bge-large-en-v1.5` embeddings, 1024-dim | Live (placeholder when no embedder) |
| 3 | **RRF fusion** | Reciprocal Rank Fusion | `score(d) = Σ 1/(k + rank_i(d))` with `k=30` | Live |
| 4 | **Time-decay boost** | `updated_at` timestamp | `decay = 1.0 + 0.3 * exp(-age_days / 30.0)` | Live |

### Group B — Lifecycle metadata (stored, not yet in ranking)

| # | Factor | Field | Range | Neuroscience model | Status |
|---|--------|-------|-------|-------------------|--------|
| 5 | **Synaptic strength** | `strength: f32` | 0.0–1.0 | SHY (Tononi/Cirelli) — decays during dream downscale | Stored, write-path parked |
| 6 | **Depth score** | `depth_score: u8` | 1–3 | 1=episodic (hippocampal), 2=intermediate, 3=semantic (neocortical) | Stored, defaults to 2 |
| 7 | **Session spread** | `session_spread: u32` | 1–∞ | Cross-session reactivation count (Hebbian co-activation) | Stored, defaults to 1 |
| 8 | **Stability** | `stability: f32` | 0.0–∞ | Ebbinghaus S parameter — higher = slower forgetting | Stored, defaults to 1.0 |

### Supporting fields (inputs to the 8 factors, not independent factors)

| Field | Type | Role |
|-------|------|------|
| `staleness_score` | `f32` | Computed: `time_since_access * decay_rate_per_kind` — input to prune decisions |
| `signal_score` | `f32` | Computed: `access_frequency * revision_count * kind_weight` — input to promote/demote |
| `access_count` | `u32` | Raw access counter — feeds `signal_score` and `session_spread` |
| `revision_count` | `u32` | Upsert counter — feeds `signal_score` |
| `consolidation_status` | `enum` | `Staged → Consolidated → Archived` — lifecycle state, not a ranking factor |

## Scoring Pipeline

### Current (v0.2)

```
query
  ├─ FTS5 BM25 → top-100 by text relevance
  ├─ sqlite-vec → top-100 by vector distance
  │
  └─ RRF fusion (k=30)
       │
       └─ time-decay boost
            │
            └─ final ranked list, truncated to k
```

```rust
// RRF: merge two ranked lists
for (rank, id) in fts_ranked.iter().enumerate() {
    *scores.entry(id).or_insert(0.0) += 1.0 / (RRF_K + (rank + 1) as f32);
}
for (rank, id) in vec_ranked.iter().enumerate() {
    *scores.entry(id).or_insert(0.0) += 1.0 / (RRF_K + (rank + 1) as f32);
}

// Time-decay: recent → 1.3x boost, old → 1.0x (no penalty)
let decay = 1.0 + RECENCY_BOOST * (-age_days / TAU).exp();
let final_score = rrf_score * decay;
```

### Target (v0.4+)

```
query
  ├─ FTS5 BM25 → top-100
  ├─ sqlite-vec → top-100
  │
  └─ RRF fusion (k=30)
       │
       └─ time-decay boost (factor 4)
            │
            └─ lifecycle re-rank:
                 score *= strength          (factor 5: SHY decay)
                 score *= depth_weight(d)   (factor 6: depth bonus)
                 score *= log(1 + spread)   (factor 7: cross-session signal)
                 score *= stability_decay() (factor 8: Ebbinghaus curve)
                 │
                 └─ final ranked list
```

The lifecycle re-rank multipliers are designed to be neutral at defaults:
- `strength=1.0` → 1.0x (no effect)
- `depth_score=2` → 1.0x (intermediate baseline)
- `session_spread=1` → `log(2) ≈ 0.69` normalized to 1.0
- `stability=1.0` → 1.0x (no effect)

This means newly ingested chunks score identically to today's pipeline. Only after dream cycles modify these fields does the lifecycle re-rank diverge from baseline.

## Dream Cycle Interactions

Each dream phase reads and writes different factors:

| Dream phase | Reads | Writes |
|-------------|-------|--------|
| **Scan** | — | Identifies candidates by `consolidation_status=Staged` |
| **Consolidate** | `session_spread`, age | `strength` (replay delta: `max * recency * ln(1+peers)`) |
| **Downscale** | `strength` | `strength` (global SHY decay, `todo!()` in v0.2) |
| **Prune** | `staleness_score`, `revision_count`, `duplicate_count` | Soft-delete (sets `deleted_at`) |
| **Place** | `consolidation_status`, activity score | `consolidation_status` (Staged→Consolidated) |
| **Promote** | `signal_score`, `depth_score` | `canonical_layer`, `depth_score` |

### Consolidate formula (live in `crates/reverie-dream/src/phases/consolidate.rs`)

```rust
/// delta = max * (1 / (1 + age_h)) * ln(1 + peer_count), clamped to [0, max]
pub fn compute_replay_delta(peer_count: usize, age_hours: f64, max_delta: f64) -> f64 {
    let recency = 1.0 / (1.0 + age_hours.max(0.0));
    let peer_factor = (1.0 + peer_count as f64).ln();
    (max_delta * recency * peer_factor).clamp(0.0, max_delta)
}
```

Default `max_strength_delta = 0.1`, `min_strength_floor = 0.01`.

## Neuroscience Mapping

| Biological concept | System factor | Mechanism |
|-------------------|---------------|-----------|
| **SHY** (Synaptic Homeostasis Hypothesis) | `strength` | Global downscale during dream; strong traces survive, weak decay |
| **Ebbinghaus forgetting curve** | `stability` | S parameter controls decay rate; higher S = flatter curve |
| **Systems consolidation** | `depth_score` | Hippocampal (episodic, depth=1) → neocortical (semantic, depth=3) over repeated access |
| **Hebbian learning** | `session_spread` | "Neurons that fire together wire together" — cross-session reactivation strengthens traces |
| **Sharp-wave ripples** | Consolidate phase | Fast-forward replay of recent patterns, strengthening co-activated traces |
| **CLS** (Complementary Learning Systems) | Interleaved pairs | Mix new and old patterns to prevent catastrophic interference |
| **Behavioral tagging** | `importance_tag` | High-salience events get persistent tags that resist forgetting |
| **Reconsolidation** (Nader) | Place phase | Retrieved memories become labile and must be restabilized — the act of re-placing is restabilization |

## Consequences

**Positive**:
- Chunks that survive multiple sessions and dream cycles naturally rank higher
- Stale, never-accessed chunks decay without manual curation
- The scoring pipeline is biologically plausible and self-documenting

**Negative**:
- 4 additional multipliers per search hit (negligible compute cost, but more tuning surface)
- Requires dream cycles to run for factors 5-8 to diverge from neutral — cold starts score identically to pure RRF

**Migration path**: Factors 5-8 can be enabled incrementally behind feature flags. Each factor is an independent multiplier; enabling one doesn't require the others.
