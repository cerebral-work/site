# log-sidecar-redis

Bash daemon that polls Redis diagnostics every 5 seconds and publishes
notable operational events to the `logs.redis.*` fanout bus.

Implements Phase 2 of `protocol/redis-log-fanout` v0.1 (TOD-519):
service-external signals that never flow through the reveried tracing
layer. Envelope shape matches `RedisFanout` — `v`, `ts`, `service`,
`host`, `level`, `pid`, `target`, `msg`, `fields` — so consumers can
treat sidecar messages and in-process tracing events identically.

## What it watches

| Signal              | Source                  | Channel           | Threshold                         |
| ------------------- | ----------------------- | ----------------- | --------------------------------- |
| New SLOWLOG entries | `SLOWLOG GET 10`        | `logs.redis.warn` | any entry with id > last-seen     |
| Client count delta  | `INFO clients`          | `logs.redis.info` | `abs(delta) > 5` between polls    |
| Memory pressure     | `INFO memory`           | `logs.redis.warn` | `used_memory_rss > 0.9 * maxmemory` |

Every event is also `XADD`'d to `logs:stream:redis` with
`MAXLEN ~ 10000`, mirroring the in-process fanout layer.

## Running

```bash
scripts/log-sidecar-redis                     # uses local redis-cli defaults
REDIS_URL=redis://host:6379 scripts/log-sidecar-redis
POLL_INTERVAL=10 scripts/log-sidecar-redis    # slower cadence
LOG_SIDECAR_DISABLED=1 scripts/log-sidecar-redis   # no-op exit
```

The sidecar is intentionally a single Bash file so it can run on any
host with `redis-cli` + `python3` (or `jq`) installed, no Rust
toolchain required. Typical deployment is as a sibling process to
`reveried` under systemd / supervisord.

## Resilience

- Ping probes Redis on every tick; if it's down, the sidecar backs off
  exponentially from 1s to a 60s cap with uniform jitter, matching the
  protocol's sidecar restart policy. It will never busy-loop.
- Transient per-poll errors (single failed `INFO`/`SLOWLOG`/emit) fall
  back to a 1–2s retry rather than exiting.
- `SIGTERM`/`SIGINT` → clean exit 0 via trap.
- State (`last_slowlog_id`, `last_client_count`) lives in memory only.
  Restarting the sidecar will re-emit the currently-resident slowlog
  ring; that's intentional, and cheaper than persisting state.

## Smoke

With `slowlog-log-slower-than 0` (to force entries), run the sidecar
for ~10s and issue a few `redis-cli PING`s — `XLEN logs:stream:redis`
must be ≥ 1 and each entry must parse as the v0.1 envelope shape.
`LOG_SIDECAR_DISABLED=1` must short-circuit to exit 0. Pointing
`REDIS_URL` at a dead port must produce visible exponential backoff
lines without crashing.
