# Ebbinghaus Stability Updates — FSRS vs SM-2 Research

**Status**: research complete, 2026-04-16
**Covers**: T50 (Implement Ebbinghaus stability updates)
**Conclusion**: stick with simplified implicit-access formula; FSRS requires grade input reverie doesn't have

## Background

The backlog (T50) proposes this stability update formula on each access:

```
S_new = S_old * (1 + a * exp(-S_old * interval))
```

This is an ad-hoc SM-2-inspired formula. FSRS v4 (2023, integrated into Anki Nov 2023) is the state-of-the-art SRS algorithm. This doc evaluates whether reverie should adopt FSRS formulas instead.

---

## FSRS v4 — Full Mathematical Spec

### Types
- **R** ∈ [0, 1] — retrievability: probability of successful recall
- **S** ∈ (0, ∞) — stability: days for R to decay from 1.0 → 0.9
- **D** ∈ [1, 10] — difficulty: inherent complexity (1=easy, 10=hard)

### Retrievability (forgetting curve)

```
R(t, S) = (1 + F · t/S)^C

where:
  F = 19/81 ≈ 0.2346
  C = -0.5
  t = days since last access
```

Reverie equivalent: this is what `stability` + time-decay factor represent in ADR-006.

### Stability update — successful recall

```
S'_r = S · (1 + t_d · t_s · t_r · h · b · e^W[8])

where:
  t_d = 11 − D                          (difficulty effect, linear)
  t_s = S^(−W[9])                       (large S → smaller increment)
  t_r = e^(W[10] · (1 − R)) − 1        (low R → larger increment)
  h   = W[15] if grade=Hard else 1.0    (Hard penalty)
  b   = W[16] if grade=Easy else 1.0    (Easy bonus)
```

### Stability update — after forgetting (missed recall)

```
S'_f = min(S_f, S)

where S_f = D^(−W[12]) · (S+1)^W[13] · e^(W[14]·(1−R)) · W[11]
```

### Initial stability (first access, by grade)

```
S_0(G) = W[G-1]

Defaults (W[0]-W[3]): [0.40255, 1.18385, 3.173, 15.69105]
```
→ Grade 1 (Again): S=0.40, Grade 4 (Easy): S=15.69

### Difficulty update

```
D_0(G) = W[4] − e^(W[5]·(G−1)) + 1   (initial, clamped [1,10])
D'    = D + ΔD · (10−D)/9             (linear damping toward neutral)
D''   = W[7]·D_0(4) + (1−W[7])·D'    (mean reversion)

ΔD = −W[6]·(G − 3)
```

### Default weights (19 parameters)

```rust
const W: [f64; 19] = [
    0.40255, 1.18385, 3.173,  15.69105,  // W[0-3]: initial stability by grade
    7.1949,  0.5345,  1.4604, 0.0046,    // W[4-7]: difficulty
    1.54575, 0.1192,  1.01925,1.9395,    // W[8-11]: recall stability
    0.11,    0.29605, 2.2698, 0.2315,    // W[12-15]: forget stability
    2.9898,  0.51655, 0.6621,            // W[16-18]: bonuses + decay
];
```

---

## Why FSRS Does NOT Fit Reverie

FSRS is designed for **explicit grade input** (Again/Hard/Good/Easy per review). Reverie has only **implicit access signals**: chunk was retrieved or not. No grade is collected.

| Requirement | FSRS | Reverie |
|-------------|------|---------|
| Grade per access | Required | Not available |
| Difficulty tracking | Per-item D [1-10] | Not tracked |
| User calibration | 19 learnable weights | No training loop |
| Interval scheduling | Outputs next-review date | Not scheduling reviews |

FSRS would require inventing proxy grades (e.g., "how many results returned for this chunk?") and a weight-tuning loop — complexity not justified at this stage.

---

## Recommended Formula for T50

The backlog formula is close but should use FSRS's retrievability term for biological plausibility:

```rust
/// Update stability after implicit access.
/// Uses retrievability-based increment: higher recency bonus when chunk was "at risk".
pub fn update_stability(s_old: f32, age_days: f32) -> f32 {
    // Compute current retrievability at time of access
    let r = (1.0 + (19.0 / 81.0) * age_days / s_old).powf(-0.5);

    // Stability increment: larger when retrieved despite low retrievability (spaced effect)
    let learning_rate = 0.1_f32;
    let increment = learning_rate * (1.0 - r).max(0.0);

    (s_old * (1.0 + increment)).min(365.0) // cap at 1-year stability
}
```

This borrows the FSRS retrievability curve (R(t,S) power function) as the input to the increment,
without requiring grades or difficulty tracking.

### SHY interaction (T49 downscale)

Dream downscale should multiply stability by the global scale factor only if chunk wasn't accessed
since the last cycle — mimicking SHY's observation that consolidation occurs for memories NOT
reactivated during NREM (they get re-normalized):

```rust
// In downscale phase: apply to non-accessed chunks only
if chunk.last_seen_at < cycle_start {
    chunk.stability = (chunk.stability * 0.95).max(MIN_STABILITY_FLOOR);
}
// Accessed chunks: stability was already updated at access time (above formula)
```

---

## Prior Art / References

- FSRS mathematical spec: borretti.me/article/implementing-fsrs-in-100-lines
- FSRS benchmark vs SM-2: expertium.github.io/Benchmark.html
- FSRS in Anki (Nov 2023): faqs.ankiweb.net/what-spaced-repetition-algorithm
- Rust implementation: github.com/open-spaced-repetition/fsrs-rs

---

## Ticket Recommendation

**T50**: Implement the revised formula above (retrievability-aware increment). Do NOT adopt full FSRS — grade input is unavailable. Tag: `stability/ebbinghaus`, not `SM-2`.

Surface to release as a research-finding: FSRS is worth revisiting if reverie ever adds explicit user feedback on chunk quality.
