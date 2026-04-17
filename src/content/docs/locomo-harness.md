# Reverie — LoCoMo Testing Harness & Agents

**Purpose**: Reproducible benchmark suite to measure Reverie's memory quality across development phases. Every architectural change (hybrid search, dream consolidation, entity resolution, placement framework) must show measurable improvement on LoCoMo-derived tasks.

---

## 1. Benchmark Adaptation

LoCoMo is designed for conversational agents. Reverie operates on a coding harness. We need both:
- **LoCoMo-native**: run the original benchmark against engram's retrieval to get a comparable score
- **LoCoMo-adapted**: coding-harness-specific variant testing memory across simulated coding sessions

### 1.1 LoCoMo-Native Harness

Use the published LoCoMo dataset (50 conversations, ~305 turns each, 5 question types, 7,512 questions total) against engram's retrieval pipeline. GitHub: https://github.com/snap-research/locomo

```
locomodata/
├── conversations/       # 50 multi-session dialogues (19.3 sessions avg, 9.2K tokens avg)
├── questions/           # 7,512 questions with ground-truth answers
│   ├── single_hop/      # direct recall from one turn
│   ├── multi_hop/       # requires connecting info across turns/sessions
│   ├── temporal/        # requires reasoning about time/sequence
│   ├── commonsense/     # requires world knowledge + conversation
│   └── adversarial/     # tests for hallucination/false recall
└── event_graphs/        # ground-truth temporal event graphs per speaker
```

**Pipeline**:
1. Ingest each conversation into engram as observations (one per session or one per turn — test both granularities)
2. For each question, query engram (FTS5 today, hybrid search after Phase 1)
3. Feed retrieved observations + question to Claude, get answer
4. Score against ground truth using GPT-4o-mini as judge (LoCoMo standard)
5. Report: overall accuracy, per-type breakdown, tokens consumed per query

### 1.2 LoCoMo-Coding: Adapted Benchmark

10 synthetic multi-session coding scenarios that test memory across the same 5 question types:

| # | Scenario | Sessions | Question types stressed |
|---|----------|----------|----------------------|
| 1 | Debug a flaky test across 3 sessions | 5 | multi-hop, temporal |
| 2 | Evolve API design with breaking changes | 8 | temporal, adversarial |
| 3 | Onboard to unfamiliar codebase | 6 | single-hop, commonsense |
| 4 | Refactor with changing requirements | 10 | multi-hop, temporal |
| 5 | Security audit across multiple services | 7 | multi-hop, commonsense |
| 6 | User preferences learned over time | 12 | single-hop, adversarial |
| 7 | Project decisions with reversals | 8 | temporal, adversarial |
| 8 | Cross-project knowledge transfer | 6 | multi-hop, commonsense |
| 9 | Dependency upgrade chain | 5 | temporal, multi-hop |
| 10 | Architecture evolution from monolith to services | 15 | all types |

Each scenario generates:
- Session transcripts (simulated Claude Code interactions)
- Ground-truth observations (what SHOULD be stored)
- Ground-truth placement (which layer each observation belongs in)
- Test questions (15-20 per scenario, typed)
- Expected answers with source observations

---

## 2. Agent Architecture

Four specialized agents form the testing pipeline:

### 2.1 Scenario Generator Agent

**Role**: Creates realistic multi-session coding scenarios with ground truth.

```
Input:  scenario template (from table above)
Output: {
  sessions: [{
    id: string,
    project: string,
    turns: [{ role: user|assistant, content: string, tools_used: string[] }],
    outcome: string,  // what was accomplished
    importance_events: string[],  // bug fixed, PR merged, decision made
  }],
  ground_truth: {
    observations: [{ content, kind, topic_key, canonical_layer, related_to[] }],
    entities: [{ name, aliases[], type: person|project|tool|concept }],
    temporal_facts: [{ fact, valid_from, valid_until, source_session }],
  },
  questions: [{
    text: string,
    type: single_hop | multi_hop | temporal | commonsense | adversarial,
    answer: string,
    source_observations: string[],  // which ground-truth obs are needed
    source_sessions: string[],      // which sessions contain the evidence
  }]
}
```

**Model**: claude-sonnet-4-6 (good enough for generation, save opus for judging)

### 2.2 Memory Ingest Agent

**Role**: Processes scenario sessions through the memory system under test, simulating real Claude Code usage.

```
Input:  scenario sessions + memory system config
Output: {
  observations_created: [{ id, content, layer, topic_key }],
  placement_decisions: [{ observation, classified_as, placed_in, correct: bool }],
  dream_cycles_run: int,
  tokens_consumed: int,
}
```

**Configurations tested** (one run per config):
- `baseline`: engram FTS5 only, no dream cycles, no placement framework
- `hybrid`: engram FTS5 + vector search (Phase 1)
- `smart_context`: hybrid + tiered boot context (Phase 2)
- `reverie_v1`: hybrid + dream cycles (scan + classify + place + prune)
- `reverie_v2`: v1 + consolidation (merge related observations)
- `reverie_full`: v2 + entity resolution + behavioral tagging + session-spread scoring

### 2.3 Retrieval & Answer Agent

**Role**: For each test question, queries the memory system and produces an answer.

```
Input:  question + memory system state (post-ingest)
Output: {
  retrieved_observations: [{ id, content, score }],
  answer: string,
  retrieval_tokens: int,
  reasoning: string,  // chain of thought for debugging
}
```

**Retrieval strategies tested**:
- `fts5_only`: keyword search
- `hybrid_rrf`: FTS5 + vector with reciprocal rank fusion
- `hybrid_graph`: hybrid + entity graph traversal (future)
- `smart_inject`: auto-loaded context (CLAUDE.md + auto-memory) + on-demand search

### 2.4 Judge Agent

**Role**: Scores answers against ground truth. Uses LoCoMo's evaluation protocol for comparability.

```
Input:  question + predicted_answer + ground_truth_answer
Output: {
  correct: bool,
  score: float,  // 0.0-1.0 partial credit
  error_type: null | "hallucination" | "incomplete" | "wrong_entity" | "wrong_time" | "missed_update",
  explanation: string,
}
```

**Model**: claude-opus-4-6 (highest accuracy for judging) or gpt-4o-mini (LoCoMo standard, for comparability)

---

## 3. Metrics

### 3.1 Accuracy Metrics (LoCoMo-compatible)

| Metric | What it measures |
|--------|-----------------|
| Overall accuracy | % of questions answered correctly |
| Single-hop accuracy | Direct recall from one observation |
| Multi-hop accuracy | Connecting info across multiple observations |
| Temporal accuracy | Reasoning about time/sequence/validity |
| Commonsense accuracy | World knowledge + stored context |
| Adversarial accuracy | Resistance to hallucination/false recall |

### 3.2 Reverie-Specific Metrics

| Metric | What it measures |
|--------|-----------------|
| Placement accuracy | % of observations placed in correct layer (vs ground truth) |
| Duplication rate | # of duplicate observations across layers |
| Consolidation quality | Are merged observations semantically complete? |
| Prune precision | Were pruned observations truly low-value? |
| Prune recall | Were all low-value observations pruned? |
| Entity resolution F1 | Precision/recall on entity coreference |
| Temporal validity | Are facts with expired validity correctly handled? |
| Tokens per query | Context efficiency (lower = better) |
| Tokens per dream cycle | Consolidation cost |
| Signal-to-noise ratio | Retrieved relevant / total retrieved |

### 3.3 Regression Metrics (per phase)

Track delta from previous phase:

```
Phase 0 (baseline):      LoCoMo XX%, placement N/A, duplication N
Phase 1 (hybrid search): LoCoMo +Y%, placement N/A, duplication N
Phase 2 (smart context): LoCoMo +Y%, placement N/A, tokens -Z%
Phase 3 (reverie v1):    LoCoMo +Y%, placement XX%, duplication -N
Phase 4 (rust rewrite):  LoCoMo ±0% (parity), latency -Xms
Phase 5 (auto-capture):  LoCoMo +Y%, placement XX%, churn -Z%
```

---

## 4. Harness Implementation

### 4.1 CLI

```bash
reverie-bench run                      # run all scenarios, all configs
reverie-bench run --scenario 1         # single scenario
reverie-bench run --config baseline    # single config
reverie-bench run --type temporal      # single question type
reverie-bench compare baseline hybrid  # diff two configs
reverie-bench report                   # generate full report
reverie-bench generate --scenario 11   # generate new scenario
```

### 4.2 Project Structure

```
reverie-bench/
├── Cargo.toml
├── src/
│   ├── main.rs                 # CLI entry point
│   ├── scenario.rs             # Scenario data model
│   ├── agents/
│   │   ├── generator.rs        # Scenario generator agent
│   │   ├── ingest.rs           # Memory ingest agent
│   │   ├── retrieval.rs        # Retrieval & answer agent
│   │   └── judge.rs            # Judge agent
│   ├── configs/
│   │   ├── baseline.rs         # FTS5-only config
│   │   ├── hybrid.rs           # FTS5 + vector
│   │   ├── smart_context.rs    # Tiered boot
│   │   └── reverie_full.rs     # Full dream cycle config
│   ├── metrics.rs              # Scoring and aggregation
│   └── report.rs               # Markdown/JSON report generation
├── scenarios/
│   ├── locomo_native/          # Original LoCoMo dataset
│   └── locomo_coding/          # Adapted coding scenarios
│       ├── 01_flaky_test.json
│       ├── 02_api_evolution.json
│       └── ...
├── results/                    # Benchmark outputs (gitignored)
└── reports/                    # Generated reports (committed)
```

### 4.3 Tech Stack

- **Language**: Rust (consistent with engram-rs, reverie daemon)
- **LLM calls**: Anthropic SDK via `claude_agent_sdk` or direct `httpx`/`reqwest`
- **Engram interface**: HTTP API (mem raw) for reads, MCP for writes
- **Scenario storage**: JSON files (versionable, diffable)
- **Reports**: Markdown tables + JSON for programmatic consumption

---

## 5. Test Matrix

Each benchmark run produces a matrix:

```
                    │ single │ multi │ temporal │ common │ adversarial │ TOTAL │ tokens
────────────────────┼────────┼───────┼──────────┼────────┼─────────────┼───────┼────────
baseline (fts5)     │   XX%  │  XX%  │   XX%    │  XX%   │    XX%      │  80%  │  XXXX
hybrid (fts5+vec)   │   XX%  │  XX%  │   XX%    │  XX%   │    XX%      │  ??%  │  XXXX
smart_context       │   XX%  │  XX%  │   XX%    │  XX%   │    XX%      │  ??%  │  XXXX
reverie_v1 (dream)  │   XX%  │  XX%  │   XX%    │  XX%   │    XX%      │  ??%  │  XXXX
reverie_v2 (console) │   XX%  │  XX%  │   XX%    │  XX%   │    XX%      │  ??%  │  XXXX
reverie_full        │   XX%  │  XX%  │   XX%    │  XX%   │    XX%      │  ??%  │  XXXX
────────────────────┼────────┼───────┼──────────┼────────┼─────────────┼───────┼────────
human ceiling       │  95.1% │ 85.8% │  92.6%   │ 75.4%  │   89.4%     │ 87.9% │  N/A
```

**Hypothesis**: Each phase should show measurable improvement in specific question types:
- Phase 1 (hybrid): multi-hop + commonsense improve (semantic similarity catches what FTS5 keyword misses)
- Phase 2 (smart context): single-hop improves (better boot context = direct recall)
- Phase 3 (reverie v1): temporal improves (dream cycles with validity tracking)
- Phase 5 (auto-capture): adversarial improves (write-gate prevents storing bad observations)

---

## 6. LoCoMo-Specific Question Type Analysis

### What each type reveals about memory architecture:

**Single-hop**: Tests basic storage + retrieval. If this is low, the store is broken. FTS5 should handle this well. Hybrid adds minor improvement via synonym matching.

**Multi-hop**: Tests ability to connect information across observations. Requires either: (a) graph traversal between linked observations, (b) vector similarity pulling in related but differently-worded content, or (c) consolidation that pre-merges related observations. This is where dream cycles should shine — consolidated observations encode multi-hop connections as single retrievable units.

**Temporal**: Tests reasoning about when things happened and what's currently true. Hardest for all systems (73% below human per LoCoMo). Requires: validity intervals (Zep's 4-timestamp), temporal ordering in retrieval, and awareness of superseded facts. Dream cycles with reconsolidation should help — they mark old facts as superseded when new ones arrive.

**Commonsense**: Tests integration of stored context with world knowledge. The LLM provides world knowledge; the memory system provides context. Good placement (relevant context in the right layer at the right time) is the differentiator.

**Adversarial**: Tests resistance to hallucination. The system must know what it DOESN'T know. Write-gate (preventing bad observations from entering the store) and pruning (removing outdated/contradicted facts) directly improve adversarial resistance. A system that aggressively stores everything will hallucinate more than one that stores selectively.

---

## 7. Integration with Reverie Development

### Phase gate: no phase ships without benchmark improvement

```
Phase 1 (Hybrid Search):
  GATE: LoCoMo overall >= 85% (up from 80%)
  EXPECT: multi-hop +5%, commonsense +3%

Phase 2 (Smart Context):
  GATE: Boot tokens <= 60% of Phase 0 baseline
  EXPECT: single-hop +2%, tokens/query -30%

Phase 3 (Layer Validation):
  GATE: Placement accuracy >= 90% on LoCoMo-coding
  EXPECT: duplication rate < 5%

Phase 4 (Rust Rewrite):
  GATE: LoCoMo parity with Phase 3 (no regression)
  EXPECT: latency p99 < 10ms

Phase 5 (Auto-Capture + Write-Gate):
  GATE: LoCoMo overall >= 88%
  EXPECT: adversarial +5%, churn rate < 20%

Stretch (entity resolution):
  GATE: LoCoMo overall >= 92%
  EXPECT: multi-hop +5%, temporal +8%
```

---

## 8. Open Questions

1. **LoCoMo dataset access**: Is the full dataset publicly available or do we need to request it? Check the GitHub repo.

2. **Judge model**: LoCoMo uses GPT-4 as judge. For comparability we should too, but for development iteration haiku is 100x cheaper. Use haiku for dev, GPT-4o-mini for official runs.

3. **Coding adaptation fidelity**: How close do synthetic coding scenarios need to be to real Claude Code sessions? Should we record real sessions and use those instead?

4. **Granularity of ingestion**: LoCoMo ingests per-turn. Engram ingests per-observation (user-triggered). Testing both granularities reveals whether observation-level storage is actually better than turn-level (LoCoMo's own finding says yes — observation-based RAG outperforms turn-based).

5. **Cost**: Full benchmark run with opus judge = ~$5-10 per run. With haiku judge = ~$0.10-0.20 per run. Budget for ~100 development runs + 10 official runs per phase.
