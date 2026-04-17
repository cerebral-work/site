# Sentinel → EventManager Handoff (Phase 0.5)

**Ticket:** TOD-481
**Status:** Design draft (phase 0.5 shim)
**Related:** TOD-420 (EventManager core), TOD-424 (EventManager wiring)
**Author:** worker-91952 (delegated from redis-manager claude-pid-72482, originating sentinel dispatch 2026-04-07 21:15Z)

## Summary

The coord sentinel today discovers session state by polling
`/tmp/claude-coord/sessions/*.json` on the filesystem and writing activity
observations directly into engram. This design replaces the polling loop with a
pull from a typed event stream, while deferring the real EventManager
implementation to TOD-420 / TOD-424.

Phase 0.5 ships **only the abstraction seam** — a `SentinelEventSource` trait
with a `FsPollSource` impl that preserves current behavior bit-for-bit. When
the real EventManager lands, swapping to `EventManagerSource` is a one-file
change and the sentinel's business logic stays untouched.

## Current State

```
                  ┌────────────────────────┐
                  │  sentinel (tick loop)  │
                  └───────────┬────────────┘
                              │  fs::read_dir()
                              ▼
              /tmp/claude-coord/sessions/*.json
                              │
                              ▼ diff vs. previous snapshot
                   activity observations
                              │
                              ▼
                      engram (mem_save)
```

Concrete behaviors currently driven by the fs poll:

- **session.register / dereg**: detected via `sessions/<id>.json` appearance or
  removal between ticks.
- **session.heartbeat**: `last_heartbeat` field delta on each session record.
- **lock.acquire / release**: `/tmp/claude-coord/locks/<resource>/record.json`
  mtime + owner changes.
- **inbox.deliver**: new files in `messages/inbox-<id>/`.
- **dispatch-order.issue**: out-of-band written to `dispatch-orders/*.json` by
  the hypervisor; sentinel reads them the same way it reads sessions.

Problems with polling:

1. **Latency vs. cost tradeoff.** A 2s tick misses sub-second state changes;
   shortening it burns CPU and disk IO for 20+ peers.
2. **No ordering guarantee.** Two filesystem events observed in the same tick
   are flattened into "current state" and historical ordering is lost.
3. **Replay is impossible.** Once a session or message file is removed, the
   sentinel cannot reconstruct the sequence for audit.
4. **Tight coupling.** Sentinel knows the on-disk layout of coord. Any
   migration (redis, durable queue) forces a sentinel rewrite.

## Target State

```
  ┌──────────┐    ┌──────────────┐    ┌───────────┐
  │ coord    │───►│ EventManager │───►│ sentinel  │
  │ writers  │    │ (pub/sub)    │    │ subscriber│
  └──────────┘    └──────────────┘    └───────────┘
       │                                    │
       │            other subscribers       │
       │          (dashboard, metrics,      │
       │          archivist, wizard…)       │
       ▼                                    ▼
   coord FS                           engram observations
```

Every coord state mutation emits a typed event on a single durable bus. The
sentinel (and any future subscriber) reads from a pull iterator rather than
the filesystem. The bus becomes the system-of-record for "what happened when";
the filesystem becomes a view.

## Phase 0.5: The Shim

Phase 0.5 is explicitly **not** the EventManager. It is the abstraction seam
so that the sentinel is written once against a trait, and the migration later
is mechanical.

What phase 0.5 ships:

1. `SentinelEventSource` trait (see skeleton below).
2. `FsPollSource` implementing the trait, internally doing exactly what the
   current sentinel tick does today (read dir, diff, emit events).
3. Sentinel tick loop rewritten to call `source.poll().await` and match on the
   returned `Vec<Event>` instead of hand-rolling diffs.
4. An `Event` envelope type with a `TxId`, `TxKind` enum, JSON payload and
   timestamp — **no** protobuf yet; a serde-json shape that leaves room for
   proto codegen when the protobuf feature request lands.

What phase 0.5 does **not** ship:

- A central EventManager process or crate (TOD-420).
- Any change to how coord writers persist state; they still write files.
- `EventManagerSource` — stubbed type only, no impl.
- Durable replay, filtering, or fan-out.

## Event Envelope

Draft serde-json shape. Field names are chosen so the eventual proto mapping
is a 1:1 field translation.

```jsonc
{
  "tx_id": "01JABCDEF0TXID…",        // ULID; monotonic within a source
  "tx_kind": "session.heartbeat",    // see TxKind enum below
  "ts": "2026-04-07T21:13:45.123Z",  // RFC3339, source-local clock
  "source": "fs-poll",               // identifies which EventSource emitted
  "session_id": "claude-pid-91952",  // nullable; present for session.* events
  "resource": null,                  // present for lock.* events
  "payload": { /* kind-specific */ }
}
```

### TxKind enum

| Kind | Payload shape | Notes |
|---|---|---|
| `session.register` | `{ role, task, blob }` | First observation of a session |
| `session.heartbeat` | `{ last_heartbeat, phase }` | Only emitted on change |
| `session.dereg` | `{ reason }` | Explicit `coord dereg` or cull |
| `lock.acquire` | `{ resource, owner_session }` | — |
| `lock.release` | `{ resource, owner_session }` | — |
| `inbox.deliver` | `{ to_session, msg_id, kind }` | Envelope only, not body |
| `dispatch.issue` | `{ order_id, assignee, ticket }` | Hypervisor → worker orders |

`tx_id` is a ULID generated by the source; it must be monotonic within a
source but not globally. The sentinel treats `(source, tx_id)` as the dedup
key for at-least-once delivery.

## Interface

Trait skeleton — ships in phase 0.5 with only `FsPollSource` implemented.
`EventManagerSource` is a marker type reserved for TOD-420/424.

```rust
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub tx_id: String,
    pub tx_kind: TxKind,
    pub ts: chrono::DateTime<chrono::Utc>,
    pub source: String,
    pub session_id: Option<String>,
    pub resource: Option<String>,
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TxKind {
    SessionRegister,
    SessionHeartbeat,
    SessionDereg,
    LockAcquire,
    LockRelease,
    InboxDeliver,
    DispatchIssue,
}

/// Pull-style event source feeding the sentinel tick loop.
///
/// Implementations must be cancel-safe: dropping a `poll` future mid-flight
/// must not lose events (the next `poll` should return them).
#[async_trait]
pub trait SentinelEventSource: Send + Sync {
    /// Return every event observed since the previous successful call.
    ///
    /// An empty vector means "nothing new"; it is not an error. Errors are
    /// reserved for unrecoverable conditions (coord root unreadable, etc.).
    async fn poll(&mut self) -> anyhow::Result<Vec<Event>>;

    /// Identifier recorded in `Event::source`. Stable across restarts so
    /// downstream dedup works.
    fn name(&self) -> &'static str;
}

/// Filesystem-polling source. Preserves today's sentinel behavior.
pub struct FsPollSource {
    coord_root: std::path::PathBuf,
    // cached snapshot of previous tick for diffing
    prev: SnapshotState,
}

/// Reserved for TOD-420/424. Not implemented in phase 0.5.
pub struct EventManagerSource { /* … */ }

#[derive(Default)]
struct SnapshotState { /* session/lock/inbox maps */ }
```

The sentinel tick loop collapses to:

```rust
loop {
    let events = source.poll().await?;
    for ev in events {
        handle_event(ev).await?;
    }
    tokio::time::sleep(tick_interval).await;
}
```

`handle_event` is the sentinel's business logic — writing observations to
engram, pinging peers, enforcing cull deadlines, etc. None of it knows the
source is filesystem polling, so swapping to EventManager is mechanical.

## Migration Path

1. **Phase 0.5 (this ticket, TOD-481).** Land the trait + `FsPollSource` +
   rewrite sentinel tick to use it. No behavior change.
2. **Phase 1 (TOD-420).** Stand up the EventManager crate: in-process
   broadcast channel, JSON serialization, per-subscriber cursor.
3. **Phase 2 (TOD-424).** Wire coord writers to publish into EventManager
   alongside filesystem writes (dual-write period).
4. **Phase 3.** Implement `EventManagerSource` as a subscriber. Gate the
   sentinel on an env flag `SENTINEL_SOURCE=event-manager`; default stays
   `fs-poll` until soak is clean.
5. **Phase 4.** Flip default. Delete `FsPollSource` and the dual-write code.

Each step is independently revertible.

## RFC / Open Questions

1. **Cancellation semantics.** `async fn poll` is cancel-safe only if the
   source buffers events it has already read from disk but not yet returned.
   `FsPollSource` can enforce this cheaply (read into Vec, take ownership
   before any await). Do we codify this in the trait docs as a hard
   requirement, or accept "best effort" and make callers not drop futures
   mid-poll?

2. **Clock skew.** `Event::ts` is source-local. For `fs-poll` that's file
   mtime, which is fine. For a future `EventManagerSource` fed from remote
   coord nodes, do we want an additional `ingress_ts` field so the sentinel
   can tell "when it happened" from "when we saw it"? Suggest: yes, add now
   and leave null in phase 0.5.

3. **`tx_id` uniqueness.** ULID-per-source is enough for dedup within one
   sentinel run. Across sentinel restarts, `FsPollSource` has no persistent
   cursor, so it re-emits the last snapshot on boot. Downstream consumers
   need to tolerate this (idempotent writes to engram). Acceptable?

4. **Payload schema governance.** The `payload` is `serde_json::Value` so new
   kinds don't break the envelope. Long-term we probably want per-kind typed
   payloads (a `#[serde(tag = "tx_kind", content = "payload")]` enum). Is it
   worth paying the churn cost now, or wait until TOD-420 when the proto
   schema forces a decision?

5. **Backpressure.** `poll` returns all events since the last call, which
   could be unbounded if the sentinel tick stalls. Do we want a
   `max_batch: usize` parameter, or trust the sentinel to keep up and alert
   on lag?

6. **Where does the trait live?** Options: a new `reverie-events` crate (most
   future-proof), inside `reverie-store` under `events/` (already has a
   sibling `http/` module), or temporarily in `reverie-sync`. Recommendation:
   new `reverie-events` crate so TOD-420/424 can depend on it without pulling
   in store.

7. **Testing story.** Phase 0.5 needs an `InMemorySource` test double
   implementing the trait with a `VecDeque<Event>` — trivial, but should it
   ship in the crate under `#[cfg(test)]` or as a public helper for downstream
   subscriber tests? Suggest: public under a `testing` feature flag.

## Acceptance for Phase 0.5

- Trait + `FsPollSource` + `Event` envelope exist and are compiled into the
  sentinel build path.
- Sentinel tick loop uses `source.poll()` exclusively; no direct `fs::read_dir`
  calls remain in the business-logic module.
- Unit tests: one per `TxKind` proving `FsPollSource` emits the right event
  shape from a synthetic coord root.
- Soak test: run the new sentinel against a live coord root for ≥10 minutes
  and confirm observation output is byte-identical to the old sentinel.
- No changes to coord writers.
- No `EventManagerSource` implementation.
