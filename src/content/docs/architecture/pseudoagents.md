# Pseudoagents

Status: draft (control-room lane, 2026-04-08)
Cross-refs: engram #554, #558, #559, #560; `docs/architecture/event-manager.md`

## What is a pseudoagent

A **pseudoagent** is any mesh participant that appears as an agent in the
coord registry but cannot drive its own tick. It shares the agent interface
(`coord register`, inbox, heartbeat, role spec) but is externally clocked.

Examples in the current reverie mesh:

| Kind | Wake source | Notes |
|---|---|---|
| Claude Code session | `tmux send-keys` from anchor or EventManager | #554/#558 — cannot self-loop |
| Bash watcher (e.g. `mesh-poke`, `mesh-drain`) | cron / systemd timer | has no inbox of its own |
| One-shot subagent (Task tool) | single `Agent` invocation | replies once and exits |
| Future EventManager `agent_watcher` timer | `tokio::time::interval` | `tokio::spawn` per agent (#559 §B) |

A **real agent** self-ticks: it has an internal loop and emits heartbeats as
a side effect of doing work. A pseudoagent's heartbeat is emitted *by its
waker*, on its behalf, as proof of wake delivery — **not** proof of work.

## Why the distinction matters

1. **Heartbeat semantics.** A pseudoagent's `last_heartbeat` tells you
   "someone poked it recently", not "it is alive and working". Fake liveness
   (#554) is the direct consequence of erasing this distinction.
2. **Wake routing.** Every wake to a pseudoagent is an out-of-band channel
   (tmux keystrokes, redis stream, HTTP POST). Out-of-band channels are
   *not* observable through `coord recv` — so they need their own audit.
3. **Kill safety.** `tmux send-keys -t reverie-anchor "kill %" Enter` is
   syntactically indistinguishable from a wake poke until you audit the
   payload. A misrouted kill is a normal bug in this model, not an
   exception — the system must be designed so misroutes are *traceable*.
4. **Clock isolation.** Each pseudoagent has its own tick cadence, set by
   its waker. There is no shared mesh clock. Drift is normal.

## Invariants

- P1. Every wake to a pseudoagent MUST emit an audit event before the wake
  side effect is issued. Order: `audit → wake`, never the reverse.
- P2. An audit event MUST include: `{ts, waker, target, method, fence, payload_hash, reason}`.
- P3. A pseudoagent's `last_heartbeat` field in the coord registry MUST be
  renamed or flagged so consumers cannot confuse it with a real liveness
  signal. Proposal: `last_poked_at` + `last_acked_at` pair.
- P4. Wake methods form a closed set. v0: `tmux_send_keys`, `redis_xadd`,
  `http_post`, `process_signal`. Anything else is a bug.
- P5. Kills are wakes. A kill (`C-c`, `SIGTERM`, `/quit`) uses the same
  wake channel as a normal poke and MUST go through the same audit path.
  There is no separate kill channel.

## Audit stream

Redis stream: `events:audit:wake`

Payload (JSON string field `payload`):

```json
{
  "ts": "2026-04-08T07:12:33Z",
  "waker": "claude-pid-81905",
  "waker_role": "anchor",
  "target": "reverie-control-room",
  "target_sid": "claude-pid-59017",
  "method": "tmux_send_keys",
  "fence": 4217,
  "payload_sha256": "9f...",
  "payload_preview": "Tick: drain inbox via 'coord recv --drain'...",
  "reason": "periodic-tick",
  "correlation_id": "01J..."
}
```

Retention: `XTRIM MAXLEN ~ 50000` (rotated by control-room).
Consumer groups: `observability` (dashboard), `forensics` (on-demand replay).

## Event variant proposal (for reverie-store EventManager)

Add to `crates/reverie-store/src/events/types.rs::Event`:

```rust
PseudoagentWake {
    ts: Instant,
    waker: String,           // sid of waker
    target: String,          // sid or tmux session name
    method: WakeMethod,      // enum: TmuxSendKeys | RedisXadd | HttpPost | ProcessSignal
    fence: u64,
    payload_sha256: [u8; 32],
    reason: String,          // e.g. "periodic-tick", "urgent-dispatch", "kill"
},
PseudoagentAck {
    ts: Instant,
    target: String,
    fence: u64,
    latency: Duration,
},
```

Tag strings: `"pseudoagent_wake"`, `"pseudoagent_ack"`.

## Tooling deliverables (control-room lane)

1. `~/.local/bin/tmux-send-audit` — wrapper that logs then calls
   `tmux send-keys`. Drop-in replacement; same flags.
2. Patch `mesh-poke` and any other script calling `tmux send-keys` on a
   `reverie-*` session to go through the wrapper.
3. Redis stream consumer: `control-room` tails `events:audit:wake` and
   ships to `/var/log/reverie/wake-audit.ndjson` (or engram, whichever
   archive lane prefers).
4. EventManager Phase 1 (#559): `agent_watcher` timer emits
   `PseudoagentWake` / `PseudoagentAck` via the in-proc EventManager AND
   XADDs to the redis audit stream.
5. Schema change to coord registry: split `last_heartbeat` into
   `last_poked_at` / `last_acked_at`. Dual-write during migration.

## Non-goals (explicit)

- Promoting pseudoagents to real agents. The whole point is that "real
  self-looping Claude Code sessions" are not something we can ship today.
- Building a unified kill channel. Kills ride the wake channel (P5).
- Cross-host pseudoagent registry. Single-host only for v0.
