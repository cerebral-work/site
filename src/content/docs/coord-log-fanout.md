# coord log fanout (TOD-507)

`scripts/coord-with-fanout` is a thin bash wrapper around `~/.claude/bin/coord`
that publishes a structured envelope to Redis on every coord operation,
per `protocol/redis-log-fanout v0.1`.

## What gets emitted

For each invocation the wrapper emits two envelopes: one **pre** (before the
real coord binary runs) and one **post** (after, with `duration_ms` and
`exit_code` filled in). On a non-zero exit code the post envelope is raised
to `level=error`.

Destinations:

- **Pubsub channel**: `logs.coord.{info,warn,error}`
- **Stream**: `logs:stream:coord` (capped via `MAXLEN ~ 10000`)

## Envelope shape

```json
{
  "v": 0,
  "ts": "2026-04-07T12:34:56.789Z",
  "service": "coord",
  "host": "<hostname>",
  "level": "info",
  "pid": 12345,
  "target": "coord::register",
  "msg": "coord.register start",
  "fields": {
    "op": "register",
    "session": "<session_id>",
    "resource": "",
    "peer": "",
    "duration_ms": 0,
    "phase": "pre",
    "exit_code": 0
  }
}
```

`op` is the first positional arg passed to coord (`register`, `heartbeat`,
`send`, `recv`, `lock`, `unlock`, `dereg`, ...). `resource` is populated for
`lock` / `unlock` / `steal`. `session` resolves via `COORD_SESSION_ID >
CLAUDE_SESSION_ID > unknown`, matching the real coord binary.

## Subscribing

```bash
# Tail all levels in real time:
redis-cli psubscribe 'logs.coord.*'

# Replay recent history from the stream:
redis-cli XREVRANGE logs:stream:coord + - COUNT 20

# Just error envelopes:
redis-cli psubscribe 'logs.coord.error'
```

## Safety properties

- **Fire-and-forget**: each redis-cli call is wrapped in a `timeout` and
  backgrounded, so redis being slow or down never blocks the underlying
  coord op. The wrapper's exit code is always the real coord's exit code.
- **Bypass**: set `LOGS_COORD_DISABLED=1` to skip all publishes entirely.
- **No source modification**: `~/.claude/bin/coord` is never touched.
  Drop the wrapper on your `PATH` ahead of the bin directory, or alias
  `coord=~/projects/reverie/scripts/coord-with-fanout`.

## Tunables (env)

| Var | Default | Purpose |
|---|---|---|
| `LOGS_COORD_DISABLED` | unset | `1` disables all publishes |
| `LOGS_COORD_REDIS_TIMEOUT` | `0.25` | per-call redis timeout (seconds) |
| `COORD_BIN` | `~/.claude/bin/coord` | underlying coord binary |
| `REDIS_CLI` | `redis-cli` | redis client binary |

Refs: TOD-507, `protocol/redis-log-fanout v0.1`, `principle/immutable-eventlog`.
