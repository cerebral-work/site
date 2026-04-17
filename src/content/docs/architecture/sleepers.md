# Sleeper Architecture

Sleepers are coord-registered agents that run autonomously between anchor
pokes. The anchor dispatches work via `coord send` and pokes sleepers to
wake them; sleepers heartbeat back to prove liveness.

## Vocabulary

| Biology term     | Coord equivalent  | Description                        |
|------------------|-------------------|------------------------------------|
| Sleep spindle    | Heartbeat         | Periodic liveness signal           |
| Poke             | `--poke` flag     | Anchor nudges a sleeper awake      |
| Ack              | `last_acked_at`   | Sleeper proves it is doing work    |

## Heartbeat Split

Prior to this change, a single `last_heartbeat` field served double duty
as both "the anchor poked me" and "I am alive and working". This made it
impossible to distinguish a sleeper that was poked but never responded
from one that is actively processing.

The split introduces two new fields alongside `last_heartbeat`:

- **`last_poked_at`** -- set by the anchor via `coord heartbeat --poke`.
  Records when the sleeper was last nudged.
- **`last_acked_at`** -- set by the sleeper's own `coord heartbeat` (no
  `--poke` flag). Proof-of-work: the sleeper is alive and processing.

`last_heartbeat` continues to be written on every heartbeat (poke or ack)
for backward compatibility during the migration period. Readers (e.g.
`agent_watcher`) prefer `last_acked_at` when present, falling back to
`last_heartbeat` for old session records.

## Invariants

- **P1: Registration** -- `coord register` initializes all three fields
  (`last_heartbeat`, `last_poked_at`, `last_acked_at`) to the current
  timestamp.
- **P2: Backward compatibility** -- `last_heartbeat` is always written.
  Old readers that only know `last_heartbeat` continue to work.
- **P3: Poke vs. ack distinction** -- **Implemented.** `coord heartbeat`
  sets `last_acked_at`; `coord heartbeat --poke` sets `last_poked_at`.
  The agent watcher uses `last_acked_at` (when available) for staleness
  checks, so a poke alone does not reset the liveness clock.
- **P4: Staleness** -- A sleeper is considered dead when `last_acked_at`
  (or `last_heartbeat` if `last_acked_at` is absent) exceeds the
  configured stale-heartbeat threshold.
