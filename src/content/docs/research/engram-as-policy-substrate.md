# Engram as policy substrate — a retrospective on 2026-04-07

**Author**: anchor (claude-pid-2268)
**Date**: 2026-04-08
**Scope**: research / design note
**Related**: engram #404, #420, #422, #471, #501, #511, #518, #557, #574

## The question

What happens when you stop using a memory store as a journal and start using
it as the mesh's live operating context?

Yesterday was the first day we leaned hard into that. Four threads of policy
and routing work landed as typed engram observations, and by evening the
running mesh was consulting engram on boot instead of re-reading scattered
config files. This document captures what worked, what didn't, and the
pattern that emerged.

## Background

Prior to 2026-04-07, engram was mostly a bugfix + architecture notebook: you
found a gotcha, you wrote a `kind=bugfix` observation, you grepped for it
later when the same problem came back. Useful but passive. Policies lived in
CLAUDE.md, config files, shell scripts, and tribal knowledge.

The shift on 2026-04-07 was putting **live operational policy** into the
same observation store, under a dedicated `policy/*` topic namespace, and
then having running sessions treat those observations as binding.

## The four threads

### 1. Offload routing policy became a document, not code

[`#511`](../../../../home/ctodie/.engram/engram.db) —
`offload-to-llm — anchor routing policy v1 (local-first)`, topic
`policy/offload/anchor-v1`, `kind=decision`.

The rule — "prefer local LLM dispatch by default; Claude is the escalation
path, not the default" — landed as a rev'd observation instead of a config
file or a block in CLAUDE.md. Sessions read it via
`mem_search "offload policy"` and honor it at runtime. Because the
observation is keyed on `topic_key`, v1 can supersede v0 cleanly without
breaking history or fragmenting search results.

The interesting property: the policy is **legible** to any process that
speaks SQL + FTS5 against the engram DB. No parser, no schema, no
deployment. A new session boots, searches, reads, obeys.

### 2. Policy scope widened from "anchor-only" to "every role"

[`#471`](...) captured the 23:13Z directive: *"adopt local offload
policy"* — the hypervisor binding the rule to its own workflow, not just
fanning it out to peers. Topic `coord/policy/hypervisor-self-adopts-local-offload`.

This was the moment the policy became **reflexive**: the thing writing the
policy started obeying its own policy. It sounds trivial but it flips the
mental model. Policies in engram aren't orders the orchestrator hands down
and exempts itself from; they're invariants the orchestrator runs under. A
policy written by a session binds that session on its next turn.

### 3. Model routing preferences became tiered and legible

[`#420`](...) and [`#422`](...) logged the TOD-487 Phase 1 rollout in ~15
minute ticks as `kind=discovery` observations: ollama + CUDA warm-up,
`gemma3:4b` smoke passing, `qwen3-coder:30b` loading, mid-load pivot to
`gemma4:26b` exploration.

The value wasn't the individual log lines — it was that by end of day you
could `mem_search "TOD-487"` and reconstruct the full exploration
trajectory. What loaded, what smoked, what got skipped, and why. Model
selection stopped being a gut-feel chore and became an auditable sequence.
New sessions that wanted to know "which local model does the mesh prefer"
got the answer from engram, not from shell history or memory.

### 4. The policy registry itself

[`#501`](...) — a canonical index of all mesh + role policies, queryable
via `topic_key:policy/*` or `topic_key:coord/policy/*`. Per the directive
*"maintain policy registry."*

This is the moment engram went from notebook to **config database**. The
registry pattern means a new session can bootstrap its operational
constraints by walking one topic namespace instead of reading scattered
CLAUDE.md fragments. `mem_search topic_key:policy/*` returns the current
constitution of the mesh.

### 5. Install + wire-up as observation artifacts

[`#518`](...) logged the actual installation of `llm-offload` and
`anchor-offload` to `~/.local/bin/` with checksums and 6/6 smoke test
results. A binary install persisted as an engram observation.

This felt weird at first and then obvious. Future sessions that search for
`llm-offload` find not just the policy but the **receipt** of the install.
Drift detection gets cheap: compare current `~/.local/bin/llm-offload` to
the observation, flag if different. The observation doubles as a provenance
record and a rollback anchor.

### 6. The compound effect — the token-optimization TRIAD

[`#404`](...) captured the three-ticket architecture as a single
`kind=architecture` observation:

- TOD-481 — mesh state serialization
- TOD-482 — sentinel handoff protocol
- TOD-487 — local LLM offload bootstrap

Explained how they compound into ~5x orchestration throughput + 35-60%
inference cost reduction. Previously this kind of cross-ticket analysis
would have been a Linear comment that nobody re-reads. As an engram
observation with `topic_key:coord/architecture/token-optimization-triad`,
it surfaces on `mem_context project=reverie` when relevant sessions boot.

## What worked

- **Typed observations + topic_key upsert.** Policies could rev
  (`policy/offload/anchor-v1` → `v2`) without losing history or duplicating
  topics. This is the single most important property for a config database
  that's going to live for months.
- **`kind=decision` for directives, `kind=discovery` for status ticks.**
  A clean taxonomy when walking the namespace. Decisions are load-bearing;
  discoveries are logs. Search weight can differ by kind.
- **Policy registry (#501) as the one index.** Walk the topic namespace,
  bootstrap constraints. One query, not twelve grep passes.
- **Hypervisor eating its own policy (#471).** Closed the loop. Policies
  became invariants the writer also obeys, which is the only way a
  multi-session mesh stays coherent without a central authority.
- **Install receipts as observations (#518).** Drift detection for free.
  Provenance as a side effect.

## What was rough

- **Weekly Anthropic quota blew to 229% (#557)** despite the local-first
  policy. Observations describe intent; they don't enforce. The gap is
  between "policy in engram" and "policy as an enforceable hook." Policy
  documents do not block tool calls. We need a PreToolUse hook (or the
  equivalent mesh-wide) that reads the policy observation and refuses
  violations.
- **No TTL or decay tuning for policy observations.** They sit at full
  strength forever and compete with ephemeral discoveries for search
  results. Need a `kind=policy` with different decay rules, or a
  `policy_tier` field that pins them above regular decay.
- **No liveness test for "is this policy currently honored."** Policies are
  write-only until something breaks and you audit. Every policy should have
  a paired `kind=verification` observation that encodes the check
  (e.g. "weekly quota < 100%").
- **Registry (#501) isn't auto-generated.** It's hand-curated, which means
  it goes stale. Want a nightly cron that walks `topic_key:policy/*` and
  rewrites #501 from ground truth.
- **Topic naming conventions are inconsistent.** `policy/offload/anchor-v1`
  vs `coord/policy/hypervisor-self-adopts-local-offload` vs
  `policy/registry`. A convention doc (or even a linter) would help.

## The deeper lesson

Yesterday was the first time engram stopped being a journal and started
being the mesh's **live operating context**. Policies, install receipts,
routing preferences, compound architecture analyses — all in the same
typed store, and sessions started consulting it on boot instead of
re-reading CLAUDE.md. That's the shift:

> Engram isn't memory of what happened. It's the live operating context.

The bootstrap runbook at #574 (`infra/mesh-bootstrap-runbook`) is a direct
descendant of this pattern: mesh-bootstrap knowledge lives in engram so
new sessions can reconstruct the mesh without reading scattered files.
It's the same move, applied to lifecycle instead of policy.

## Implications

If engram is the operating context, then a few things need to follow:

1. **Policies need enforcement primitives**, not just documentation. A
   hook runtime that reads `topic_key:policy/*` on every tool call and
   refuses violations is the natural next step. This is the gap that let
   the quota blow through 229%.

2. **Observations need kind-aware decay.** Policies should pin, discoveries
   should fade, bugfixes should fade unless re-read, directives should
   expire on a schedule. The current flat decay curve mixes signals.

3. **Search weight should be topic-aware.** A `mem_search "auth"` should
   rank `policy/auth/*` above `discoveries/auth/*` when the querying
   session is booting, and the reverse when debugging. Context matters.

4. **The registry should be a view, not a table.** `#501` is a snapshot; it
   drifts. Engram should expose a virtual observation type — "current
   policies" — that's computed at query time from the topic namespace.

5. **Provenance for installs should be mandatory.** Any script written to
   `~/.local/bin/` or any binary swapped at `~/.local/bin/reveried` should
   automatically emit a `kind=discovery` observation with checksum + size +
   source ref. This closes the loop between the filesystem and the policy
   store.

6. **Policy + lifecycle are dual.** The reveried lifecycle work (the
   4-layer plan in `docs/ops/reveried-lifecycle.md`) is the same move for
   daemon state that yesterday's work was for agent policy. Both treat
   engram as the source of truth for operational state, not just history.
   Treat them as the same initiative.

## Cross-references

- **#404** — token-optimization TRIAD architecture
- **#420** — TOD-487 Phase 1 ollama+CUDA+gemma3:4b live
- **#422** — TOD-487 Phase 1 watch tick 35 (qwen3 → gemma4 pivot)
- **#471** — hypervisor self-adopts local offload policy
- **#501** — policy/registry index
- **#511** — offload-to-llm anchor routing policy v1
- **#518** — llm-offload installed at ~/.local/bin (install receipt)
- **#557** — peers-qwen-only-v1 (forced by quota burn, extends #511)
- **#574** — infra/mesh-bootstrap-runbook (the direct descendant of this pattern)
- `~/.claude/CLAUDE.md` — CRITICAL offload mode (the current enforcement shim)
- `docs/ops/reveried-lifecycle.md` — lifecycle-as-engram-substrate (sibling initiative, in flight)
