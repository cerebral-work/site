# ADR-008: Canonical Redis Key Schemas

**Status**: Accepted
**Date**: 2026-04-09
**Linear**: TOD-552 (engram #552)

## Context

The reverie mesh uses Redis for real-time coordination: log streaming,
event audit trails, observation queues, and (planned) coord session/lock
state. Key names are currently scattered as string literals across Rust
code (`log_fanout.rs`, `meshctl-tui`), shell scripts (`log-sidecar`,
`coord-with-fanout`), and documentation (`protocol-v0.md`, `coord.proto`).

Without a single source of truth, key names drift, collisions go
undetected, and TTL/type expectations are implicit. This ADR defines the
canonical schema and points to the `redis_schemas` module that enforces
it in Rust code.

## Decision

All Redis keys used by the mesh follow the schemas below. New keys MUST
be added here and to `reverie_store::redis_schemas` before use.

### Key Catalog

#### Sessions (coord backend — planned)

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `sessions:{pid}` | HASH | 600s refresh | Per-session state: task, status, last_heartbeat, blob |
| `sessions:index` | ZSET | — | Score = last_heartbeat epoch; member = pid |

Fields in `sessions:{pid}`: `task`, `status`, `last_heartbeat`, `blob`,
`registered_at`, `capabilities`.

#### Locks

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `locks:{resource}` | STRING | 300s | SET NX EX — value = owner pid |
| `locks:project:{project}:{area}` | STRING | 300s | Scoped project lock (file-lock) |

#### Task Queues

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `tasks:queue:{priority}` | LIST | — | LPUSH/RPOP work items; priority ∈ {high, normal, low} |
| `tasks:inbox:{peer}` | LIST | — | Per-peer message inbox (coord send) |

#### Event Streams

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `events:all` | STREAM | MAXLEN ~10000 | Global event bus |
| `events:audit:wake` | STREAM | MAXLEN ~10000 | Wake audit events (pseudoagent triggers) |
| `events:audit:pseudoagent_wake` | STREAM | MAXLEN ~10000 | Pseudoagent-specific wake events |

#### Observation Queues

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `observations:queue:pending` | STREAM | MAXLEN ~10000 | Observations awaiting consolidation |
| `observations:queue:dead` | STREAM | MAXLEN ~10000 | Failed/rejected observations |

#### Log Streams

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `logs:stream:{service}` | STREAM | MAXLEN ~10000 | Per-service structured log stream |

Pubsub channels (not keys, but part of the schema):

| Channel | Description |
|---------|-------------|
| `logs.{service}.{level}` | Real-time log fan-out; level ∈ {info, warn, error} |

#### Metrics

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `metrics:{counter}` | STRING | — | Atomic INCR counters |

#### Deduplication

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `seen:{hash}` | ZSET | — | Score = epoch seen; member = content hash. Prune scores < now - 86400 |

#### Mesh Internal

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `reverie:env:log` | STREAM | MAXLEN ~10000 | Environment/runtime log stream |
| `meshctl:prom:audit` | STREAM | MAXLEN ~10000 | Prometheus audit scrape results |

### Naming Conventions

1. **Namespace separator**: colon (`:`)
2. **Hierarchy**: `<domain>:<entity>:<qualifier>`
3. **Dynamic segments**: `{placeholder}` — always lowercase, no spaces
4. **No trailing colons**
5. **Stream MAXLEN**: always approximate (`~`) to avoid blocking on exact trim

### TTL Policy

- Session hashes: 600s, refreshed on heartbeat
- Locks: 300s, owner must refresh or release
- Streams: capped by MAXLEN, not TTL
- Counters and ZSETs: no TTL (prune via application logic)

## Consequences

- All Rust code MUST use `reverie_store::redis_schemas` key builders
  instead of inline string formatting.
- Shell scripts SHOULD reference this ADR for key names. A future linter
  can enforce consistency (out of scope).
- Adding a new key requires updating this ADR, the `redis_schemas` module,
  and a review from a mesh maintainer.
