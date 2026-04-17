# log-sidecar

Generic stderr/stdin → Redis log fanout daemon. One script, any service.

## What it does

Tails a log source (a file via `tail -F`, or stdin), classifies each line
into `info` / `warn` / `error`, and fans out to Redis per the
`protocol/redis-log-fanout v0.1` envelope:

- `PUBLISH logs.<service>.<level> <json-envelope>` — live pub/sub
- `XADD    logs:stream:<service> MAXLEN ~ 10000 * v 0 ts <ms> level <lvl> msg <raw>` — bounded history

Envelope shape:

```json
{"v":0,"ts":1712534400000,"service":"llama-server","level":"info","msg":"ready"}
```

## Usage

```bash
scripts/log-sidecar --service llama-server --source /var/log/llama-server.err
scripts/log-sidecar --service dashboard    --source stdin < /dev/stdin
llama-server 2>&1 >/dev/null | scripts/log-sidecar --service llama-server --source stdin
```

## Env vars

| Var                      | Default     | Meaning                                   |
| ------------------------ | ----------- | ----------------------------------------- |
| `LOG_SIDECAR_DISABLED`   | `0`         | `1` = drain source, publish nothing       |
| `REDIS_CLI`              | `redis-cli` | override binary (e.g. `redis-cli -n 1`)   |
| `LOG_SIDECAR_STREAM_MAX` | `10000`     | stream MAXLEN `~` cap                     |

## Backpressure

The tailer never blocks on Redis. Each publish forks a subshell with a
`timeout 1` around the `redis-cli` calls and is disowned. If Redis is down
or slow, lines are silently dropped (no-op). This is the mpsc-style
"prefer loss over stall" contract.

## Level classification

Simple case-insensitive regex on the raw line:

- `error` / `err` / `fatal` / `panic` → `error`
- `warn`                              → `warn`
- anything else (incl. `info`)        → `info`

## Subscriber example

```bash
redis-cli psubscribe 'logs.llama-server.*'
redis-cli xlen  logs:stream:llama-server
redis-cli xrange logs:stream:llama-server - + COUNT 10
```

## Acceptance checks

```bash
echo "test" | scripts/log-sidecar --service foo --source stdin
redis-cli xlen logs:stream:foo        # >= 1
LOG_SIDECAR_DISABLED=1 echo hi | scripts/log-sidecar --service foo --source stdin
# no new entries
```
