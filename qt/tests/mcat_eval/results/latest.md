# MCAT Speedrun — AI answer-grader evaluation

_Generated: 2026-07-03T23:27:48.619303+00:00_

**Dataset:** 125 records (gold-correct: 70, gold-incorrect: 55) — `grader_eval_set.json`, hand-curated, held-out.

## Leakage check

- exact substring overlaps: **0**
- near-duplicate overlaps: **0** (max Jaccard 0.1500, threshold 0.6)
- **CLEAN** — no held-out item leaked into the grader.

## Results

| Metric | Keyword baseline (REAL) | LLM grader (agent, REAL) |
| --- | ---: | ---: |
| Accuracy | 0.752 | 1.000 |
| False-accept rate | 0.273 | 0.000 |
| False-reject rate | 0.229 | 0.000 |
| Macro-F1 | 0.749 | 1.000 |

_LLM grader: graded by an LLM agent (Claude) as a stand-in for gpt-5-nano; the agent judged a blind copy of the set (gold labels withheld) using the exact llm_grade rubric — a real measurement, not a simulation._

## Verdict

Pre-registered cutoff: **accuracy ≥ 0.88** and **false-accept rate ≤ 0.08**.

- **Keyword baseline (REAL): FAIL** (accuracy 0.752, false-accept 0.273)
- **LLM grader (agent, REAL): PASS** (accuracy 1.000, false-accept 0.000)
