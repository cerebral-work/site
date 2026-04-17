# Coord Observability (TOD-441)

The `coord` binary writes an append-only JSONL audit log of every mutating
operation. This is the v0 (filesystem) backend; a Redis stream variant lands
with TOD-437.

## Audit log

- **Path**: `$COORD_ROOT/audit.log` (default `/tmp/claude-coord/audit.log`).
- **Format**: one JSON object per line, UTF-8, LF terminated.
- **Append-only**: never edited in place. Rotation is via atomic rename.
- **Rotation**: when the file exceeds `COORD_AUDIT_MAX_BYTES` (default 10 MiB)
  it is renamed to `audit.log.1`. Existing `audit.log.1`/`audit.log.2` shift
  forward; the oldest beyond `COORD_AUDIT_KEEP` (default 3) is deleted.
- **Read tooling**: `coord log tail|stats|locks|session`, `coord metrics`.

### Schema

| Field         | Type    | Notes                                              |
|---------------|---------|----------------------------------------------------|
| `ts`          | string  | ISO-8601 UTC, second precision                     |
| `op`          | string  | One of the ops below                               |
| `actor`       | string  | Originating `session_id`                           |
| `target`      | string  | Resource name, peer id, or session id              |
| `result`      | string  | `ok`, `noop`, `denied`, `timeout`, `cascade`, `err`|
| `duration_ms` | integer | Wall-clock from cmd entry to log emission          |

Optional extra fields may be appended (e.g. `kind` on `send`, `count`/`drain`
on `recv`). Consumers MUST ignore unknown fields.

### Logged ops

`register`, `dereg`, `heartbeat`, `lock`, `unlock`, `steal`, `send`, `recv`,
`project-lock`, `project-unlock`.

Read-only ops (`peers`, `status`, `log`, `metrics`, `migrate`) are NOT logged.

## `coord log` subcommand

```
coord log tail    [--op OP] [--actor ID] [--resource R] [--since DURATION] [-n N]
coord log stats   [--since DURATION]
coord log locks   [--resource R]
coord log session <id>
```

`--since` accepts `30s`, `10m`, `1h`, `24h`, `7d`. `-n` defaults to 50.

- **tail**: prints matching JSONL records, oldest first across rotated files.
- **stats**: groups by op, computes total, plus lock-hold percentiles
  (p50/p95/max in seconds, computed by pairing each `lock ok` with the next
  `unlock ok|cascade` for the same target).
- **locks**: timeline of `lock`/`unlock`/`steal` events.
- **session**: every record where `actor == <id>`.

Unknown flags hard-error.

## `coord metrics`

Prometheus text format, computed on demand from current state + the audit log.
No persistent metric state.

| Metric                            | Type    | Source                              |
|-----------------------------------|---------|-------------------------------------|
| `coord_sessions_live`             | gauge   | live session files                  |
| `coord_locks_held{resource=...}`  | gauge   | `$COORD_ROOT/locks/*` directories   |
| `coord_messages_sent_total`       | counter | `op == send` and `result == ok`     |
| `coord_messages_received_total`   | counter | `op == recv` and `result == ok`     |

## Tuning

| Env var                 | Default                          |
|-------------------------|----------------------------------|
| `COORD_AUDIT_LOG`       | `$COORD_ROOT/audit.log`          |
| `COORD_AUDIT_MAX_BYTES` | `10485760` (10 MiB)              |
| `COORD_AUDIT_KEEP`      | `3` rotated files                |
