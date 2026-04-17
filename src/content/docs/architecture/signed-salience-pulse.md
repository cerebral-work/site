# Signed Salience Pulse — dream-cycle protocol

**Status**: draft, 2026-04-08
**Author**: hypervisor pid-2338 (Claude) from design discussion with Christian
**Depends on**: reverie-dream DreamPhase trait, fastembed cosine index, zeitgeist
blob (future work)
**Supersedes**: none (new protocol)

## 1. Motivation

The mesh is an orchestration substrate, not a memory library. The payoff is
**context → outcome attribution** fed back into salience so future recalls
surface context that empirically moved decisions in the right direction.

Three requirements drove the design:

1. **Cheap recall** for hot-path orchestration (<5 ms p99, local FTS + vec index).
2. **Cheap forget** at two granularities — hard tombstone for epistemic retraction,
   soft decay for salience erosion.
3. **Trigger forget in others** — a peer on one machine must be able to weaken a
   memory on every other peer without synchronous coordination.

Empirical grounding: engram observation #276 (2026-04-07) showed that pruning
59% of observations improved retrieval quality — forgetting is a feature, not a
failure, and it should be aggressive and percentile-based rather than conservative
and threshold-based.

## 2. Primitives

### 2.1 Zeitgeist entry kinds

A zeitgeist is an append-only log (S3 blob today, Redis stream later) shared by
all mesh peers. Every peer's dream cycle polls the log, applies unseen entries
to local state, and emits its own additions.

```
kind ∈ { assert | supersede | reconsolidate | tombstone | salience_pulse }
```

* `assert` — new observation
* `supersede` — old chunk superseded by new one, preserves epistemic chain
* `reconsolidate` — recall-triggered rewrite (Nader analog)
* `tombstone` — hard forget: content purged, only `(hash, ts, reason)` retained
* `salience_pulse` — signed, propagating credit-assignment wave

### 2.2 Unit separation

```
recall unit   = topic_key + FTS + vec k-NN     (coarse, indexed)
storage unit  = content-addressed chunk         (immutable, dedupe-by-hash)
forget unit   = facet-level tombstone or pulse  (finer than recall)
```

These three must be separable — otherwise you can't forget a facet of a chunk
without losing its ticket number.

## 3. Cosine distance and the kernel

We use the formal cosine similarity from
[Algebrica](https://algebrica.org/cosine-similarity/?v=2):

$$C_s(V_x, V_y) = \frac{V_x \cdot V_y}{\|V_x\| \cdot \|V_y\|}, \quad C_s \in [-1, 1]$$

For text embeddings produced by fastembed / bge / ada, components are
non-negative, so $C_s \in [0, 1]$. Define distance as:

$$d_{cos}(a, b) = 1 - C_s(a, b), \quad d_{cos} \in [0, 1]$$

Gaussian kernel over cosine distance:

$$K(a, b; \sigma) = \exp\left(-\frac{d_{cos}(a, b)^2}{2 \sigma^2}\right)$$

`sigma` is the neighborhood width in distance units. Typical values:

| sigma | effective radius | use case                                    |
|-------|------------------|---------------------------------------------|
| 0.05  | very tight       | per-facet credit assignment                 |
| 0.15  | tight            | topic-family decay                          |
| 0.30  | medium           | cross-topic ripple (default)                |
| 0.50  | wide             | global downscaling (rare, use percentile sweep instead) |

## 4. The salience_pulse primitive

A single wire format for both positive (reward) and negative (decay) salience
propagation through the implicit k-NN graph.

```rust
pub struct SalientPulse {
    pub pulse_id: u128,              // content-hash of the pulse itself
    pub seed_embedding: Vec<f32>,    // carry the vector, peers may not hold seed
    pub seed_hash: Option<Blake3>,   // optional, for audit
    pub kind: PulseKind,             // Reward | Decay | Forget
    pub strength: f32,               // magnitude; sign set by kind
    pub sigma: f32,                  // kernel width in d_cos units
    pub max_hops: u8,                // BFS depth, typically 2-3
    pub k: u8,                       // neighbors per node in BFS frontier
    pub decay_per_hop: f32,          // attenuation per BFS level
    pub ts: LamportTs,
    pub origin_peer: PeerId,
    pub reason: TopicKey,            // for audit + filtering
    pub ttl: Duration,               // after this, pulse is collectable
}

pub enum PulseKind {
    Reward,     // strength applied positively
    Decay,      // strength applied negatively
    Forget,     // strength = +infinity, max_hops = 0, always paired with Tombstone
}
```

### 4.1 Propagation (local execution per peer)

Each peer runs BFS over its own k-NN index, attenuating per hop:

```python
def propagate(pulse: SalientPulse, local_vec_index, local_store):
    if local_store.already_applied(pulse.pulse_id):
        return

    sign = +1.0 if pulse.kind == Reward else -1.0
    frontier = {(pulse.seed_embedding, 0.0)}  # (embedding, cumulative_distance)

    for hop in range(1, pulse.max_hops + 1):
        next_frontier = set()
        attenuation = pulse.decay_per_hop ** hop

        for emb, _ in frontier:
            neighbors = local_vec_index.knn(emb, k=pulse.k)
            for n in neighbors:
                d = cosine_distance(emb, n.embedding)
                w = gaussian_kernel(d, pulse.sigma)
                delta = sign * pulse.strength * attenuation * w

                # Pinned chunks can't go below their floor
                new_salience = max(
                    n.salience + delta,
                    n.pin_floor
                )
                local_store.update_salience(n.hash, new_salience)
                next_frontier.add((n.embedding, d))

        frontier = next_frontier

    local_store.mark_applied(pulse.pulse_id)
```

Crucially: peers that **don't hold the seed chunk** still participate, because
BFS starts from the pulse's embedding, not from a local reference. A forget
of X can weaken X-adjacent memories on peers who never held X.

### 4.2 Convergence invariant

Hard-enforce at pulse-emit time:

$$\text{decay\_per\_hop} \times k < 1$$

Otherwise BFS amplifies instead of attenuating and you get unbounded salience
loss. Typical safe values: `decay_per_hop = 0.5, k = 1`; or
`decay_per_hop = 0.3, k = 3`.

Also: couple `sigma` and `max_hops`:

$$\text{max\_hops} \leq \left\lfloor \frac{-\log \epsilon}{\sigma} \right\rfloor$$

where `epsilon` is the smallest salience delta you care about (default 1e-3).
Prevents O(k^h) exploration when sigma is wide.

## 5. Percentile sweep — the #276 operationalization

At the end of each dream cycle, after all pulses have propagated, compute the
60th-percentile salience threshold over all chunks and tombstone everything
below it *except* pinned chunks. Biologically calibrated (Ebbinghaus 56%),
empirically validated on live engram workload (obs #276, 59% pruning improved
retrieval).

```python
def percentile_sweep(local_store, pct=60):
    all_salience = [c.salience for c in local_store.live_chunks() if not c.pinned]
    if len(all_salience) < 100:  # don't sweep on a cold DB
        return
    threshold = numpy.percentile(all_salience, pct)
    for c in local_store.live_chunks():
        if c.pinned:
            continue
        if c.salience < threshold:
            local_store.tombstone(c.hash, reason="percentile_sweep")
```

This is the curation loop. Every dream cycle, the bottom 60% by salience
becomes tombstones — epistemic scars, not actual deletions of the hash.

## 6. Dream cycle phase order

```
scan → classify → interleave → reconsolidate → salience_pulse_propagate → downscale → percentile_sweep → promote
                                                 ^^^^^^^^^^^^^^^^^^^^^^^                ^^^^^^^^^^^^^^^^^
                                                 §4                                     §5
```

* `scan, classify, interleave, reconsolidate` — existing phases, unchanged.
* `salience_pulse_propagate` — **NEW**: drain unseen zeitgeist pulses, apply via §4.
* `downscale` — uniform attenuation (SHY analog), unchanged.
* `percentile_sweep` — **NEW**: §5, drops bottom 60% by salience to tombstones.
* `promote` — existing, unchanged.

## 7. Attribution log (the rapid-orchestration loop)

For the mesh to learn from outcomes, every decision needs to record which
chunks were in its context so outcome signals can credit them later.

```rust
pub struct Attribution {
    pub decision_hash: Blake3,     // hash of (peer, ts, sorted_chunk_hashes, decision_text)
    pub chunk_hashes: Vec<Blake3>,
    pub peer: PeerId,
    pub ts: LamportTs,
}

pub struct Outcome {
    pub decision_hash: Blake3,     // references the attribution
    pub reward: f32,               // [-1, +1] typical range
    pub observer_peer: PeerId,     // the peer emitting the outcome, may differ from decider
    pub ts: LamportTs,
    pub reason: TopicKey,
}
```

Content-addressing the decision (hash of its inputs) makes attribution work
across peers: peer A decides, peer B observes outcome, peer B publishes an
`Outcome` tied to the decision hash, peer A's next dream cycle converts the
outcome to a `Reward` pulse seeded at the embedding of each attributed chunk.

### 7.1 Outcome → Pulse conversion

```python
def outcome_to_pulses(outcome: Outcome, attribution_log) -> List[SalientPulse]:
    attr = attribution_log.lookup(outcome.decision_hash)
    if attr is None:
        return []  # no attribution recorded — outcome is lost
    return [
        SalientPulse(
            seed_embedding=chunk_embedding(h),
            kind=Reward if outcome.reward > 0 else Decay,
            strength=abs(outcome.reward),
            sigma=0.15,        # tight credit assignment
            max_hops=2,
            k=3,
            decay_per_hop=0.3,
            reason=outcome.reason,
            ...
        )
        for h in attr.chunk_hashes
    ]
```

Pulses from positive outcomes reinforce their seed chunks and k-NN neighbors.
Pulses from negative outcomes decay them. Over many decisions, the mesh
converges on a salience landscape where high-signal chunks for past wins are
preferentially surfaced.

## 8. Tombstones always win over learned salience

A subtle but load-bearing rule: explicit `Tombstone` entries from a human or a
hypervisor always override any subsequent `Reward` pulses that would revive
the chunk. Check happens in `propagate`:

```python
if local_store.is_tombstoned(n.hash):
    continue  # tombstones are permanent; no pulse can resurrect
```

Preserves human override over any emergent credit assignment.

## 9. Schema deltas

Additive only, no migrations of existing columns:

```sql
ALTER TABLE observations ADD COLUMN salience REAL NOT NULL DEFAULT 1.0;
ALTER TABLE observations ADD COLUMN pin_floor REAL NOT NULL DEFAULT 0.0;
ALTER TABLE observations ADD COLUMN last_decay_ts TEXT;

CREATE TABLE IF NOT EXISTS applied_pulses (
  pulse_id TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tombstones (
  hash TEXT PRIMARY KEY,
  reason TEXT,
  origin_peer TEXT,
  ts TEXT NOT NULL,
  collectable_after TEXT
);

CREATE TABLE IF NOT EXISTS attributions (
  decision_hash TEXT PRIMARY KEY,
  chunk_hashes_json TEXT NOT NULL,   -- JSON array of blake3 hex
  peer TEXT NOT NULL,
  ts TEXT NOT NULL
);
```

## 10. Efficacy tests

All three run as offline jobs during dream cycles, write observations with
`topic_key=efficacy/<metric>/<window>`:

1. **Recall hit-rate** — for each decision, how many of its context chunks had
   `salience > median`? Are high-salience chunks actually the useful ones?
2. **Attribution ↔ salience correlation** — over time, does cumulative
   positive-attribution weight correlate with current salience? Is the
   learning signal coherent?
3. **Counterfactual replay** — replay past decisions with post-sweep salience
   state, check if recall would surface the same chunks. Is decay removing
   the right stuff?

These are A/B-able: run two salience-update rules in parallel on the same
attribution log, compare all three metrics.

## 11. Open questions

1. **Distance metric ambiguity** — this spec assumes cosine. If Christian
   later wants a learned metric (e.g. from a dual-encoder trained on
   click-through data), swap in `distance_fn` as a trait method on the
   `VecIndex` type. Current spec: fixed cosine.
2. **Pulse compaction** — `applied_pulses` grows unbounded. Solution: TTL on
   pulses + lowest-observed-lamport cursor per peer published to zeitgeist,
   compact pulses older than the min cursor across all live peers.
3. **Graph-walk forget** (orthogonal) — a second traversal kind over
   `supersede` + `related_to` edges rather than k-NN, for "forget everything
   causally downstream of X". Not in this spec; layer on top if needed.
4. **Per-embedding-model index versioning** — if fastembed updates and
   re-embeds, old pulses stop hitting new vectors correctly. Need an
   `index_version` field on pulses and on chunks, skip pulses older than the
   current index version.

## 12. Related work

* Engram obs #276 — empirical validation of 59% pruning improving retrieval
* Engram obs #345 — `coord/bugs/role-flag-drop` (unrelated but in same area)
* Nader (2000) — memory reconsolidation and the vulnerability of recalled
  traces. Inspires the `reconsolidate` kind.
* Tononi & Cirelli (2014) — synaptic homeostasis hypothesis (SHY). Inspires
  the uniform `downscale` phase sitting between pulse propagation and
  percentile sweep.
* Ebbinghaus (1885) — forgetting curve. 56% decay in 1 hour is the biological
  calibration for the 60th-percentile sweep target.

## 13. Implementation order

If someone wants to ship this incrementally:

1. Schema deltas (§9) — pure additive SQLite migration.
2. Local-only salience update (no zeitgeist yet) — attribution log + reward
   pulses generated inline per peer. Lets the efficacy tests (§10) start
   running immediately on one peer.
3. Percentile sweep (§5) — runs in dream cycle against local salience only.
   Validates the 60% number on production data.
4. Zeitgeist entry format + S3 append logic.
5. Cross-peer pulse propagation — BFS + cosine kernel + convergence invariant.
6. Tombstone compaction (§11.2).
7. Graph-walk variant (§11.3) if still wanted.

Steps 1-3 can ship without any of the distributed machinery. The whole point
of §2's unit separation is that you can get 80% of the value from local
percentile sweeps alone, before touching the zeitgeist.
