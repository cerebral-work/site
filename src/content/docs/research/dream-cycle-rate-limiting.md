# Dream Cycle Rate Limiting — Research

**Status**: research complete, 2026-04-16
**Covers**: T63 (Rate limiting for dream cycles)
**Conclusion**: `tokio::sync::Semaphore(1)` + `MissedTickBehavior::Skip` + minimum-interval guard covers all stacking vectors

---

## Problem

Dream cycles can be triggered by three sources simultaneously:
1. Session-end hook (coord message)
2. Cron interval (e.g., every 30 min)
3. Threshold trigger (observation count crosses N)

Without rate limiting, these can stack: two cycles run concurrently (corrupts `strength` writes),
or a slow cycle triggers another before it finishes.

---

## Tokio Primitives

### `MissedTickBehavior::Skip` — for cron trigger

```rust
use tokio::time::{interval, Duration, MissedTickBehavior};

let mut ticker = interval(Duration::from_secs(30 * 60));
ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

loop {
    ticker.tick().await;
    // If previous tick's work ran long, the next tick fires at the next
    // scheduled time (not immediately) — no burst.
    spawn_cycle_if_idle(&sem).await;
}
```

**Burst** (default): fires missed ticks immediately to "catch up" — wrong for dream cycles.
**Skip**: fires at next scheduled slot — correct behavior.
**Delay**: schedules from point of wake — drifts, unsuitable for regular intervals.

### `Arc<Semaphore>` with `try_acquire` — at-most-one-in-flight

```rust
use std::sync::Arc;
use tokio::sync::Semaphore;

static DREAM_SEM: LazyLock<Arc<Semaphore>> = LazyLock::new(|| Arc::new(Semaphore::new(1)));

async fn spawn_cycle_if_idle(state: Arc<AppState>) {
    let Ok(permit) = Arc::clone(&DREAM_SEM).try_acquire_owned() else {
        tracing::info!("dream cycle already running, skipping");
        return;
    };
    tokio::spawn(async move {
        let _permit = permit; // dropped at end of task, releases semaphore
        run_dream_cycle(state).await;
    });
}
```

`try_acquire_owned()` — non-blocking. If semaphore is taken (another cycle running), returns
`Err(TryAcquireError::NoPermits)` immediately. The spawned task holds the permit until it
completes; `_permit` drop releases the slot.

### Minimum-interval guard — prevents back-to-back trigger spam

```rust
use std::time::Instant;
use tokio::sync::Mutex;

struct DreamGuard {
    sem: Arc<Semaphore>,
    last_run: Mutex<Option<Instant>>,
    min_interval: Duration,
}

impl DreamGuard {
    async fn try_run(&self, state: Arc<AppState>) -> bool {
        let mut last = self.last_run.lock().await;
        if let Some(t) = *last {
            if t.elapsed() < self.min_interval {
                tracing::debug!(elapsed_secs = t.elapsed().as_secs(), "too soon, skipping");
                return false;
            }
        }
        let Ok(permit) = Arc::clone(&self.sem).try_acquire_owned() else {
            return false;
        };
        *last = Some(Instant::now());
        drop(last); // release mutex before spawning
        tokio::spawn(async move {
            let _permit = permit;
            run_dream_cycle(state).await;
        });
        true
    }
}
```

---

## Recommended Design (T63)

Three-layer protection:

| Layer | Mechanism | Prevents |
|-------|-----------|---------|
| 1. Min interval | `Mutex<Option<Instant>>` | Back-to-back trigger spam |
| 2. At-most-1 in-flight | `Semaphore(1)` + `try_acquire_owned()` | Concurrent cycles |
| 3. Cron behavior | `MissedTickBehavior::Skip` | Burst after slow cycle |

### Config (in `reveried.toml`)

```toml
[dream]
min_interval_secs = 1800      # 30 min — no two cycles within this window
cron_interval_secs = 1800     # cron fires every 30 min (independent)
```

`min_interval` is a hard floor that applies regardless of trigger source (cron, threshold, hook).

### Integration point

`DreamGuard` lives in `AppState` (or `Arc<DreamScheduler>`). All three trigger paths call
`guard.try_run(state)`. The guard is the single choke point.

---

## File Lock vs Semaphore

The backlog mentions using a file lock (`file-lock` on `dream-cycle`). File locks are appropriate
for multi-process or multi-machine coordination. For single-daemon use, an in-process `Semaphore`
is correct (lower overhead, no stale-lock cleanup needed). Use the file lock only if multiple
`reveried` instances can run concurrently (currently: no).

---

## References

- `MissedTickBehavior` docs: docs.rs/tokio/latest/tokio/time/enum.MissedTickBehavior.html
- `Semaphore::try_acquire_owned`: docs.rs/tokio/latest/tokio/sync/struct.Semaphore.html
- Rate-limited executor pattern: wcygan.io/post/tokio-rate-limiting/
