# llm-offload — local LLM dispatch helpers

Two binaries that implement anchor's local-LLM offload path per
**policy/offload-to-llm v1** (engram topic_key `policy/offload-to-llm`).

| Binary | Purpose |
|---|---|
| `llm-offload` | raw helper — routes by category to an Ollama model, validates output, emits telemetry |
| `anchor-offload` | policy-gated wrapper — applies hard disqualifiers from the policy before calling `llm-offload`; escalates to a Claude worker on disqualifier hit |

Source: `/tmp/llm-offload.sh`, `/tmp/anchor-offload.sh`. Installed to `~/.local/bin`.

## Models routed

| Category | Model |
|---|---|
| summarize, classify, extract, naming, commit-msg, translate, rewrite | gemma3:4b |
| code, refactor, test-scaffold, comment, explain | qwen2.5-coder:7b |
| reason, plan, design | gemma4:26b |
| embed | bge-m3 |

Available models on this host (from ollama 127.0.0.1:11434):
gemma3:4b · qwen2.5-coder:7b · gemma4:26b · gemma4:31b · qwen3-coder:30b · bge-m3 · nomic-embed-text

## llm-offload usage

```
llm-offload --health
llm-offload <category> <prompt>
llm-offload --json <category> <prompt>      # ollama format=json + temp 0
```

Exit codes:
- 0 — ok, output on stdout
- 2 — usage error
- 3 — JSON validation failed (`--json` mode)

Telemetry on stderr:
```
[offload] model=gemma3:4b category=classify tokens=5 duration_ms=395 validated=true
```

## anchor-offload usage

```
anchor-offload <category> <prompt> [--touches f1 f2 ...] [--for <audience>] [--security] [--json]
```

Hard disqualifiers (escalate, exit 10):
- `--touches` more than one file
- `--touches` matches `*auth*`, `*security*`, `*crypto*`, `*secret*`, `*.env`, `*/.ssh/*`, `*/jwt*`, etc.
- `--for human`, `--for main`, `--for escalation`, `--for production`, `--for user-facing`
- `--security` flag
- category in `{merge, migrate, schema-change, deploy, release}`
- prompt > 16 KiB

Other escalation paths:
- exit 11 — JSON validation failed
- exit 12 — llm-offload returned non-zero
- exit 13 — ollama unhealthy (10s health-probe cache at `/tmp/anchor-offload-health`)

Telemetry: every call appends a JSON line to `/tmp/anchor-offload.log`:
```json
{"ts":"2026-04-08T02:43:34Z","category":"classify","decision":"offload","reason":"none","duration_ms":476,"exit_code":0}
```

## Examples

```bash
# Plain offload
llm-offload summarize "Reverie is a Rust local-first memory layer."

# Code generation
llm-offload code "write a Rust one-liner that returns the second element of a Vec<String> or empty"

# JSON extract
llm-offload --json extract "Return JSON with field 'crates': reverie-store, reverie-bench"

# Policy-gated (will escalate)
anchor-offload code "implement auth" --touches src/auth/jwt.rs
# stderr: ESCALATE: security path

# Policy-gated (will offload)
anchor-offload classify "this PR adds a new schema field"
# stdout: pr-schema
```

## Hourly telemetry rollup

A cron job (`5 * * * *`) runs `/tmp/offload-rollup.sh` which aggregates `/tmp/anchor-offload.log` and writes a per-hour summary to engram under `metrics/offload/hourly/<hour>`.

Ad-hoc inspection: `/tmp/offload-stats.sh` prints the same rollup to stdout.

## Cross-references

- **Policy:** engram topic_key `policy/offload-to-llm` (v1, local-first bias)
- **Anchor role:** engram topic_key `role/anchor` (v2, batch-dispatch)
- **Telemetry:** engram topic_key `metrics/offload/hourly/*`

## Caveats

- `date +%s%3N` is GNU-coreutils-only. On macOS/BSD, install coreutils or replace with `python3 -c 'import time;print(int(time.time()*1000))'`.
- Health probe cache (`/tmp/anchor-offload-health`) has a 10s TTL; first call after Ollama restart may take ~12s for cold model load.
- The wrapper does NOT enforce the sample-audit (1/100) path from the policy — that lives in the runner pool, future Phase 4 work.
