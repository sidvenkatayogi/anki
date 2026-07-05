# Ankinetic — AI answer-grader evaluation

_Generated: 2026-07-05T20:12:18.306136+00:00_

**Dataset:** 125 records (gold-correct: 70, gold-incorrect: 55) — `grader_eval_set.json`, hand-curated, held-out.

> *** LLM grader row is a Claude AGENT STAND-IN for the shipping gpt-5-nano (no OPENAI_API_KEY set). It is a real LLM grading measurement on a blind copy of the set, but NOT the shipping model. The authoritative shipping gpt-5-nano number is 99.2% accuracy / 0.0% false-accept — see BASELINE_COMPARISON.md. Set OPENAI_API_KEY and re-run for live numbers. ***
>
> graded by an LLM agent (Claude) as a stand-in for gpt-5-nano; the agent judged a blind copy of the set (gold labels withheld) using the exact llm_grade rubric — a real measurement, not a simulation.

## Leakage check

- exact substring overlaps: **0**
- near-duplicate overlaps: **0** (max Jaccard 0.1500, threshold 0.6)
- **CLEAN** — no held-out item leaked into the grader.

## Results

| Metric | Keyword baseline (REAL) | LLM grader (Claude stand-in) |
| --- | ---: | ---: |
| Accuracy | 0.752 | 1.000 |
| False-accept rate | 0.273 | 0.000 |
| False-reject rate | 0.229 | 0.000 |
| Macro-F1 | 0.749 | 1.000 |

_LLM grader: graded by an LLM agent (Claude) as a stand-in for gpt-5-nano; the agent judged a blind copy of the set (gold labels withheld) using the exact llm_grade rubric — a real measurement, not a simulation._

> *** LLM grader row is a Claude AGENT STAND-IN for the shipping gpt-5-nano (no OPENAI_API_KEY set). It is a real LLM grading measurement on a blind copy of the set, but NOT the shipping model. The authoritative shipping gpt-5-nano number is 99.2% accuracy / 0.0% false-accept — see BASELINE_COMPARISON.md. Set OPENAI_API_KEY and re-run for live numbers. ***

## Verdict

Pre-registered cutoff: **accuracy ≥ 0.88** and **false-accept rate ≤ 0.08**.

- **Keyword baseline (REAL): FAIL** (accuracy 0.752, false-accept 0.273)
- **LLM grader (Claude stand-in): PASS** (accuracy 1.000, false-accept 0.000) _(Claude stand-in, not the shipping gpt-5-nano)_
