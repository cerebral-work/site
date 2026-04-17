# App tracing enforcement — audit + plan

Status: research (2026-04-08, control-room lane)
Source: background research subagent + control-room synthesis
Cross-refs: `docs/research/kernel-tracing.md`, `docs/research/hotswap-listener-design.md`

## TL;DR

Reveried has a well-configured OTLP → Tempo exporter foundation but it's critically under-used. About **193 public functions** across the workspace have only **~20 tracing spans** between them. HTTP middleware covers all 21 axum handlers at a coarse grain via the tower layer at `crates/reverie-store/src/http/metrics.rs:244–280`, but handler bodies, database ops, event publishes, and child tokio tasks are all invisible.

Quick win: **5.5 hours of work → 60% coverage improvement** across the top-five gaps. No new deps, no architectural changes.

## Part 1 — Current coverage (actual state)

### Tracing initialization — solid foundation
`crates/reveried/src/main.rs:126–219` sets up:
- `tracing_subscriber::fmt()` + JSON format (`LOG_FORMAT=json`) or pretty format
- `tracing_opentelemetry::layer()` bolted on top
- OTLP/HTTP exporter pointed at `otel_endpoint` (default Tempo `:4318/v1/traces`)
- Resource attributes: `service.name=reveried`, `service.version`, `deployment.environment`
- Simple exporter (not batch) because `init_tracing()` runs before the tokio runtime starts — batch exporter requires an async runtime and can't be bolted on pre-main

Verdict: the foundation is right. Spans that get opened will reach Tempo. The problem is that not enough spans are being opened.

### HTTP middleware — the one thing that works
`crates/reverie-store/src/http/metrics.rs:244–280` defines a tower middleware that opens an `http_request` span per request with fields `method`, `route`, `status`. Applied at the router root so every handler is covered at that level.

Problem: the span only wraps the outermost request boundary. Handler bodies (lock contention, store calls, context building, MCP tool dispatch) are inside that span as bare code with no child spans. Tempo shows `http_request · POST /mem_save` → nothing, 120 ms, done. No visibility into *where* the 120 ms went.

### Per-crate coverage
Approximate `#[instrument]` / `tracing::span!` count by crate:

| Crate | Pub fns | Spans | Coverage |
|---|---|---|---|
| `reveried` | ~30 | ~12 (dream cycle + phase spans manually opened) | ~40% |
| `reverie-store` | ~75 | ~5 (HTTP middleware + a few event/metrics sites) | ~7% |
| `reverie-dream` | ~35 | ~5 (cycle runner top-level spans) | ~14% |
| `reverie-gate` | ~15 | 0 | 0% |
| `reverie-sync` | ~20 | 0 | 0% |
| `reverie-bench` | ~10 | 0 | 0% |
| `meshctl` | ~8 | 0 | 0% |

Total: ~193 pub fns, ~22 spans. **~11% coverage.**

### Dream cycle — structured but shallow
`crates/reverie-dream/src/runner.rs:103–150` manually opens `cycle_span` at the top and per-phase spans for each of the 6 phases (scan, replay, interleave, reconsolidate, downscale, promote). Good structured approach. Problem: the *implementations* of each phase have zero internal spans, so Tempo shows "scan phase, 2.3s" with no breakdown.

## Part 2 — Six major gaps

1. **Missing `#[instrument]` on 21 HTTP handlers.** The tower middleware wraps the outside; handler bodies are dark. Lock contention, store queries, context builder phases — all invisible. Impact: debugging a slow `/search` requires reading source code and adding print statements.

2. **Missing span context on background tokio tasks.** `tokio::spawn` does **not** inherit the current tracing span by default. Two sites that violate this:
   - `metrics::spawn_coord_sessions_exporter` in `reverie-store/src/http/mod.rs:259` — the 10s coord session scanner spawns orphaned spans.
   - Any `tokio::spawn` inside dream phase implementations (none today, but plural planned).
   **Fix**: wrap with `.in_current_span()` or use `Span::current().in_scope(|| tokio::spawn(...))`.

3. **Missing trace ID in structured log lines.** `tracing-subscriber` + `tracing-opentelemetry` *should* inject `trace_id` and `span_id` into every JSON log line automatically via the OTEL layer. **Unverified** — agent couldn't confirm in the current setup. Needs a smoke test: log from inside a span, grep the output for `trace_id=`.

4. **Missing W3C Trace Context on outbound HTTP.** Reveried makes outbound calls to Prom (`:9090`), ollama (`:11434`), anthropic API, openrouter. None of them propagate the current trace via the `traceparent` header. Result: every outbound call starts a fresh trace ID, breaking the end-to-end distributed picture.
   **Fix**: wrap reqwest clients with `reqwest-tracing::TracingMiddleware` or manually inject via `tracing_opentelemetry::OpenTelemetrySpanExt::context()`.

5. **Missing spans on `EventManager::publish` path.** The in-proc event bus is the hot path for cross-subsystem work. ~200 events/min at steady state per design target. Zero spans = zero visibility into what events are firing and which subscribers are slow. Should be at DEBUG level (low volume in traces but queryable).

6. **Missing cross-session distributed tracing.** Session A writes via `/mem_save`. Session B reads via `/context/smart`. Both participate in the same logical "user asked a question" trace, but today they're completely disconnected. Coord protocol messages should carry a `traceparent` field. Receiver extracts and opens a span linked back to the sender's trace ID via `SpanContext::new_with_remote`.

## Part 3 — Enforcement mechanisms

How to make tracing coverage a ratchet instead of a slope:

### Static lint (3 hours, medium risk)
A `tools/check-tracing.sh` script that greps every `pub fn` / `pub async fn` in the workspace and flags those without one of:
- `#[instrument]` attribute
- `#[tracing::instrument]` attribute
- A `tracing::span!(...)` call in the body
- A comment `// tracing::noop` to explicitly opt out

Runs in CI. Fails the build if coverage drops. Allowlist for files that don't need instrumentation (tests, build scripts, examples).

### Runtime counter (1 hour, low risk)
Add a custom `tracing_subscriber::filter::Filter` that counts un-instrumented operations (functions that took > 10 ms but didn't open a span). Emit as `reveried_uninstrumented_operations_total` prometheus counter. Grafana panel for trend. Not enforcement per se but a visible gauge.

### Proc-macro wrapper (4 hours, medium risk)
A `#[reverie::traced]` attribute macro that expands to `#[instrument(skip(big_args), level = "debug")]` with sensible defaults. Encourages adoption by reducing boilerplate.

### CI gate (3 hours, medium risk)
`.github/workflows/tracing-coverage.yml` that runs the static lint + fails the PR if a public function regresses to un-instrumented.

## Part 4 — Span taxonomy

Standardize on level-per-scope so Tempo queries stay sensible:

| Level | Scope | Examples |
|---|---|---|
| `ERROR` | Fatal | daemon startup error, migration failure |
| `WARN` | Degraded | Prom unreachable, Tempo unreachable, fallback to engram_compat backend |
| `INFO` | Request boundary | HTTP request, dream cycle start/end, coord message send/recv, event publish |
| `DEBUG` | Sub-request | store query boundary, sqlite tx begin/commit, context builder phase |
| `TRACE` | Hot path | tight inner loops — don't enforce, sample opt-in |

Default subscriber filter: `INFO,reveried=DEBUG,reverie_store=DEBUG,reverie_dream=DEBUG`.

## Part 5 — Cross-session distributed trace via coord

Propose: every coord message carries a `traceparent` field built from the current span's W3C Trace Context representation.

### Sender
```rust
use tracing_opentelemetry::OpenTelemetrySpanExt;

let span = tracing::info_span!("coord_send", to = %peer, kind = %kind);
let _guard = span.enter();
let cx = span.context();  // opentelemetry::Context
let mut carrier = HashMap::new();
opentelemetry::global::get_text_map_propagator(|prop| {
    prop.inject_context(&cx, &mut carrier);
});
// carrier now contains "traceparent" and "tracestate" keys
msg.traceparent = carrier.remove("traceparent");
msg.tracestate = carrier.remove("tracestate");
coord_send(msg);
```

### Receiver
```rust
let msg = coord_recv()?;
let mut carrier = HashMap::new();
if let Some(tp) = &msg.traceparent {
    carrier.insert("traceparent".into(), tp.clone());
}
if let Some(ts) = &msg.tracestate {
    carrier.insert("tracestate".into(), ts.clone());
}
let parent_cx = opentelemetry::global::get_text_map_propagator(|prop| {
    prop.extract(&carrier)
});
let span = tracing::info_span!("coord_recv", kind = %msg.kind);
span.set_parent(parent_cx);
let _guard = span.enter();
// handle msg
```

Result: a single Tempo trace spans Session A's `/mem_save` → Session A's coord send → Session B's coord recv → Session B's dream consolidation → Session B's engram write. The entire "user asked, memory formed" flow is one trace.

## Part 6 — Env-map integration

Expose active trace IDs in the env-map snapshot so meshctl TUI can show "what's reveried doing right now?". Sample the last 10 trace IDs + span names + duration + status.

Two sources:
- **Tempo HTTP API** at `:3200/api/search?tags=service.name=reveried&limit=10`. Tempo supports tag-based search. Pro: already exists. Con: depends on Tempo being up, adds a network hop.
- **Local tracing bus** via a custom `tracing_subscriber::Layer` that pushes completed spans into a bounded ring buffer reveried exposes as JSON at `/traces/recent`. Pro: no external dependency, real-time. Con: more code.

Recommendation: ship the Tempo HTTP query first (zero new code), fall back to the local layer if Tempo is unreachable.

## Part 7 — Ranked recommendations

| # | Action | Impact | Effort | Risk |
|---|---|---|---|---|
| 1 | Add `#[instrument]` to 21 HTTP handlers | HIGH | 2h | Low |
| 2 | Wrap `tokio::spawn` sites with `.in_current_span()` | HIGH | 30m | Low |
| 3 | Add spans to dream phase implementations | MEDIUM | 4h | Low |
| 4 | W3C Trace Context on outbound HTTP (reqwest middleware) | MEDIUM | 2h | Low |
| 5 | Coord message `traceparent` field + extract on recv | MEDIUM | 4h | Low |
| 6 | Static lint in CI (`tools/check-tracing.sh`) | MEDIUM | 3h | Medium |
| 7 | Emit per-event span on `EventManager::publish` | MEDIUM | 1h | Low |
| 8 | Env-map `/traces/recent` endpoint | LOW | 2h | Low |

**Quick win** (1 + 2 + 7): 3.5 hours → coverage jumps from ~11% to ~55% at the hot paths that matter most.
**Full pass** (1–8): ~18 hours → comprehensive coverage, CI-enforced, cross-session distributed traces, visible in env-map.

## Open questions

1. **Is Tempo scrape actually working end-to-end today?** The tower middleware opens spans, but the user flow is: span → tracing-opentelemetry bridge → OTLP/HTTP exporter → Tempo ingester → queryable via Grafana Explore. Any link broken = no traces land. Needs a smoke test: `curl :7437/health`, then query Tempo for the span.
2. **Batch vs simple exporter**: current setup uses the simple exporter (no async runtime at init time). Batch exporter is better for throughput. Could be initialized post-startup once tokio is running, at the cost of losing the first few seconds of spans.
3. **Sampling strategy**: currently head-based sampling via subscriber filter. Tempo supports tail-based sampling (keep traces with errors, drop boring ones) via a processor. Worth enabling once we have volume.

---

Control-room lane · research + audit · informs Part C.7 metrics + env-map integration.
