# Coord heartbeat model (TOD-443)

## Why

Once Redis TTL eviction lands (TOD-437), any session whose `last_heartbeat`
stops advancing will be evicted as dead. Without an automatic heartbeat, a
peer Claude session that registered hours ago looks indistinguishable from a
crashed one. We need `last_heartbeat` to advance whenever the session is
actually doing work — without spawning a long-lived background daemon.

## Design: hooks, not a daemon

We piggyback on Claude Code's hook system. No new processes to supervise, no
PID files, no systemd unit. Two hooks cover the lifecycle:

| Hook         | Trigger                          | Action                                                  |
| ------------ | -------------------------------- | ------------------------------------------------------- |
| PostToolUse  | After every tool call            | `coord heartbeat` (fire-and-forget, backgrounded)       |
| SessionStart | When the Claude session boots    | `coord register --task ...` (re-register resets TTL)    |

### PostToolUse = heartbeat-on-activity

Every tool the agent runs (Bash, Read, Edit, Grep, ...) triggers a single
`coord heartbeat &` call. Cost: one fork + a tiny Redis HSET. The hook is
**fire-and-forget** — backgrounded with `&` and `disown`, stdout/stderr
silenced. The tool call returns immediately; the heartbeat races to Redis on
its own. If the `coord` binary is missing the hook is a no-op (`exit 0`), so
machines without coord installed never see errors.

A session that is idle (no tool calls) does not heartbeat — and that is
correct. An idle session has nothing to coordinate; if it stays idle past the
TTL, eviction is the right outcome.

### SessionStart = TTL reset on wake

When a session resumes (new shell, reboot, Claude Code restart) the
SessionStart hook re-runs `coord register`. Because `register` is idempotent
on `(host, pid, session_id)` and resets `last_heartbeat`, this gives a clean
"I'm back" signal without requiring the session to do any tool work first.
Task name is read from `.claude-task` if present, falling back to `session`.

### No background daemon

We deliberately do **not** run a `while sleep 30; coord heartbeat` loop.
Reasons:

1. Lifecycle: nothing cleanly kills it when the session ends.
2. Liveness lie: a daemon heartbeats even when the agent is wedged or the
   user has walked away. Activity-driven heartbeats reflect real liveness.
3. Cost: one Redis write per tool call is cheaper than one per 30s for idle
   sessions, and self-throttling for active ones.

## Files

- `scripts/coord-heartbeat-hook.sh` — the hook body, <10 lines.
- `scripts/install-coord-hooks.sh` — idempotent installer (uses `jq` to edit
  `~/.claude/settings.json`; safe to re-run).

## Install

```bash
./scripts/install-coord-hooks.sh
```

Re-running prints `coord hooks: already installed` and exits 0.

## Uninstall

Remove the entries from `~/.claude/settings.json` under
`hooks.PostToolUse` and `hooks.SessionStart`, and delete
`~/.claude/hooks/coord-heartbeat.sh`. No other state.
