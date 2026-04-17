# Operations — reveried HTTP surface

Reveried exposes two context-loading routes. They coexist on the same
daemon and are wired by `crates/reverie-store/src/http/mod.rs`.

## `GET /context` — engram-parity loader

Byte-for-byte identical to upstream engram's `FormatContextWithOptions`
(`internal/store/store.go:1642`). Pinned by TOD-368; do not modify. This
remains the compatibility fallback for older daemons; the SessionStart
hook now prefers `/context/smart` (see "Boot context" below) and only
falls back to `/context` if `/context/smart` 404s.

```bash
curl -s 'http://127.0.0.1:8755/context?project=reverie&limit=20' | jq .
```

## `GET /context/smart` — project-aware tiered loader (TOD-257)

Composes three tiers into a single markdown blob so a single SessionStart
hook call surfaces both *active work*, *durable project anchors*, and
*cross-cutting personal notes* without any tier monopolising the budget.

### Query parameters

| Param | Type | Default | Meaning |
|---|---|---|---|
| `project` | string | none | Project name for Tier A and Tier B. If omitted, Tier A and Tier B are skipped and only Tier C fires. |
| `limit` | usize | `smart_context_default_limit` (15) | Total bullet budget across all three tiers. |

### Response

```json
{
  "context": "## Memory — Smart Context\n\n### Active work (recent in project)\n- [decision] **…**: …\n..."
}
```

When every tier is empty, the `context` field is the literal string
`"No previous session memories found."` — the same fallback engram's
compat path uses so SessionStart hooks can branch on it identically.

### Tier composition

| Tier | Source | Query | Budget |
|---|---|---|---|
| A — active work | `recent_observations(project)` | most recent in-project rows | `floor(limit * tier_a_weight)` + rounding remainder |
| B — anchors | `high_signal_observations(project, min_activity=3)` | `revision_count + duplicate_count ≥ 3`, ordered by that sum | `floor(limit * tier_b_weight)` |
| C — cross-cutting | `recent_observations(scope='personal')` (all projects) | recent personal-scope rows | `floor(limit * tier_c_weight)` |

Tier B and Tier C are floored; any rounding slack flows back into Tier A
so "what am I doing right now" is favoured on awkward budgets.

### Worked budgets

With the default weights (0.6 / 0.3 / 0.1):

| `limit` | Tier A | Tier B | Tier C |
|---|---|---|---|
| 15 | 10 | 4 | 1 |
| 10 | 7 | 3 | 0 |
| 5 | 4 | 1 | 0 |
| 3 | 2 | 0 | 0 |

### Example

```bash
curl -s 'http://127.0.0.1:8755/context/smart?project=reverie&limit=15' | jq -r '.context'
```

Expected response shape:

```
## Memory — Smart Context

### Active work (recent in project)
- [decision] **Pin context route to engram byte parity**: ...
- [discovery] **high_signal query uses revision+duplicate sum**: ...
- ...

### Project anchors (high revision/dup count)
- [architecture] **5-layer memory hierarchy**: ...
- ...

### Cross-cutting (recent personal-scope, all projects)
- [config] **RTK proxy rewrites grep/sed**: ...
```

### Tuning

The three weights and the default limit are
[`ReveriedConfig`](./reveried-config.md) knobs. Edit
`~/.config/reveried/config.toml` and restart the daemon:

```toml
smart_context_tier_a_weight = 0.5
smart_context_tier_b_weight = 0.35
smart_context_tier_c_weight = 0.15
smart_context_default_limit = 10
```

The weights do not need to sum to 1.0 — Tier B and Tier C are floored,
and Tier A absorbs whatever is left so the total always matches `limit`.

## Boot context (SessionStart hook)

As of TOD-258, the global SessionStart hook
(`~/.claude/hooks/engram-start.sh`) calls `/context/smart` by default and
transparently falls back to `/context` when the route is missing (older
reveried / rollback to the Go engram binary):

```bash
curl -sf --max-time 2 "http://127.0.0.1:${PORT}/context/smart?project=${PROJECT}&limit=15" \
  || curl -sf --max-time 2 "http://127.0.0.1:${PORT}/context?project=${PROJECT}&limit=15"
```

This makes the hook forward- and backward-compatible: new daemons emit
the 3-tier markdown response, old daemons still return the byte-parity
`/context` blob, and rollback is a no-op for the hook.

# Reveried — Operations

Operator-facing notes for running `reveried` in production.

## MVP-B: auto-capture & write-gate

- [Auto-capture trigger design](mvp-b/auto-capture-triggers.md) — which harness
  events fire `reveried gate`, the `CandidateObservation` JSON shape, the
  rejection log layout, and per-trigger test plans (TOD-395).

## Dream cycle phases

The dream engine is a pipeline of six phases that run offline to consolidate
the observation corpus. Phases today (TOD-400 and onward):

| Phase | Status | Ticket |
|-------|--------|--------|
| `scan` | shipped | TOD-400 |
| `classify` | stub | TOD-401 |
| `replay` / `interleave` / `reconsolidate` / `downscale` / `promote` | stub | — |

### `scan` — SWR-inspired priority queue

The scan phase walks every non-soft-deleted observation in the store and
scores it using an SWR-inspired priority formula
(`priority = recency * access * importance * novelty`), then returns the
top-N highest-priority rows as consolidation candidates. See
`crates/reverie-dream/src/scan.rs` for the full derivation.

Run it against a live store (once the `reveried dream` CLI lands with
TOD-397) like:

```sh
reveried dream --phase scan
# phase=scan counts={"scanned": 96, "selected": 50} duration=1.24ms
#    1. [decision] decision/engram-context-limit-compact-upstream :: Engram PRs merged in fork...
#    2. [decision] decision/engram-session-start-optimization :: Engram SessionStart hook optimized...
#   ...
```

Tunables on `ScanPhase`:

- `top_n` (default **50**) — maximum number of candidates passed downstream
- `min_age_hours` (default **1.0**) — observations younger than this are
  excluded so freshly captured rows aren't consolidated before the user has
  had a chance to refine them

Until `reveried dream` ships, the phase can be exercised directly from Rust
or via the ignored live-snapshot test:

```sh
REVERIE_SCAN_SNAPSHOT=/tmp/engram-snap.db \
  cargo test -p reverie-dream live_snapshot -- --ignored --nocapture
```
