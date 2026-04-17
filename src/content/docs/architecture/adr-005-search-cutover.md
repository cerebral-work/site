# ADR-005: Search Cutover — engram-compat → native reverie

**Status**: Proposed
**Date**: 2026-04-09
**Linear**: TOD-634 (epic), TOD-633 (time-decay gap)

## Context

The `/search` HTTP endpoint and `mem_search` MCP tool use `EngramCompatStore::search()`, which was built for byte-parity with Go engram. It provides:
- FTS5 full-text search with BM25 ranking
- Project/scope/type filtering
- Superseded observation filtering (TOD-583)

It does **not** provide:
- Time-decay boost (recency signal) — exists only in `sqlite_vec::ChunkStore`
- Vector similarity search (semantic matching)
- RRF fusion (combining text + vector scores)
- Tag-aware filtering in search results
- Chunk-level retrieval (sub-observation granularity)

Now that reveried is the production daemon (engram Go binary retired), byte-parity with Go is no longer a constraint. The native reverie backends (`ChunkStore`, `reverie-chunk`) are tested and ready.

## Decision

Cut over in four phases, each independently shippable.

### Phase 1: Time-decay in engram-compat (TOD-633)

Add the same decay formula from `sqlite_vec.rs` to `engram_compat::search()`:

```rust
let decay = 1.0 + RECENCY_BOOST * (-age_days / TAU).exp();
let final_rank = bm25_rank * decay;
```

Constants: `RECENCY_BOOST = 0.3`, `TAU = 30.0` (monthly half-life).

This is a one-function change with no wire format impact. The `rank` field already exists in `SearchResult`. Immediate benefit for all MCP consumers.

**Risk**: Low. BM25 scores are negative (SQLite convention), so the multiply preserves ordering direction. Tests exist in sqlite_vec to validate the formula.

### Phase 2: `/search/v2` hybrid endpoint

New route backed by `ChunkStore::hybrid_search()`:

```
GET /search/v2?q=...&project=...&limit=...&include_chunks=true
```

Response shape:
```json
{
  "results": [
    {
      "observation_id": 42,
      "chunk_id": "abc-123",
      "title": "...",
      "content": "...",        // chunk content, not full observation
      "score": 0.87,
      "tags": [{"facet": "Domain", "value": "infra"}]
    }
  ]
}
```

Old `/search` preserved unchanged. Clients opt in to v2.

**Prerequisite**: Production chunker pipeline must be running (observations → chunks on write).

### Phase 3: MCP migration

Update `dispatch_tool("mem_search")` in `mcp.rs` to:
1. Try ChunkStore hybrid search first
2. Fall back to engram-compat if ChunkStore is empty/unavailable
3. Format chunk results into the existing MCP response shape

The MCP response format (`content[0].text` with markdown) stays the same — only the backend changes.

### Phase 4: Deprecate engram-compat search

- Feature-flag the old path behind `legacy-search`
- Remove after one release cycle (v0.4.0)
- Delete `EngramCompatStore::search()` and related code

## Consequences

**Positive**:
- Recent observations rank higher (time-decay)
- Semantic search catches paraphrased queries (vector similarity)
- Chunk-level retrieval reduces context waste (return relevant paragraph, not 2000-word observation)
- Tag filtering enables faceted discovery

**Negative**:
- Two search backends to maintain during transition
- ChunkStore requires sqlite-vec compiled in (binary size +~2MB)
- Chunk pipeline must run continuously (latency between write and searchability)

**Neutral**:
- Wire format changes only in v2; existing clients unaffected until Phase 4

## Alternatives considered

1. **Port everything into engram-compat** — Keeps one backend but makes engram_compat.rs increasingly non-engram. Rejected: defeats the purpose of having native backends.

2. **Hard cutover in one release** — Simpler but risky. MCP consumers may depend on exact response shapes. Rejected: phased approach is safer.

3. **Proxy to external search service** — Overkill for single-node daemon. Rejected.
