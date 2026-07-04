# AI answer-grader evaluation (Friday deliverable)

This package is the **re-runnable evaluation harness** for the one AI feature in the
fork: the optional LLM **answer-grader** (`qt/aqt/llm_grade.py`). It exists to satisfy
the Friday requirements:

- an eval that runs **before** the student sees anything (accuracy + wrong-answer rate
  on a **held-out** set, with a pre-registered cutoff),
- a **side-by-side** showing the AI beats a simpler method (keyword overlap),
- a **leakage check** proving no test item leaked into the grader's prompt/examples.

## One command

```
just eval-ai            # runs the full eval + leakage check, prints the table,
                        # writes qt/tests/mcat_eval/results/latest.{json,md}
```

or directly:

```
PYTHONPATH=qt:out/pylib ./out/pyenv/bin/python -m tests.mcat_eval.run_eval
```

Set `OPENAI_API_KEY` to grade with the real model. **Without a key the LLM row is
produced by a clearly-labeled deterministic *simulation* (`simulated: true`)** so the
harness always runs end-to-end; the keyword baseline and the leakage check are always
**real** (no network, fully local).

## The held-out set — `grader_eval_set.json`

- **What it is:** 125 `(question, expected, student_answer, gold_correct)` records for
  MCAT-style flashcards. `expected` is the card's *own stored correct answer* — the
  grader's only ground truth — so every judgement traces back to a card (the "named
  source" honesty rule). `answer_kind` records how each student answer was constructed.
- **Provenance (stated honestly):** the student answers are **hand-curated** to mirror
  the ways real free-recall answers land — clean paraphrases, partial-but-acceptable
  recall, spelling slips, blanks, unrelated guesses, and the dangerous *near-misses*
  (stated-opposite facts and common misconceptions). They are **not** harvested from
  real user telemetry (we don't have a week of real study logs), and the labels are
  unambiguous human gold. This is the honest version of "a held-out set."
- **Held out / no tuning:** none of these strings appears in the grader prompt or its
  (zero) few-shot examples; `leakage.py` proves this mechanically.
- **Label balance:** 70 gold-correct / 55 gold-incorrect (see `metrics.py` output).

## Pre-registered cutoff (set before looking at any result)

Ship the grader only if, on the held-out set:

- **accuracy ≥ 88%**, **and**
- **false-accept rate ≤ 8%** (marking a *wrong* answer correct — the dangerous error,
  since it silently inflates the memory signal downstream).

The **baseline** to beat is a keyword-overlap grader (mark correct iff the student
answer shares ≥ 50% of the expected answer's content keywords, stopwords removed,
light stemming).

## Files

| File | Real or simulated | Purpose |
| --- | --- | --- |
| `grader_eval_set.json` | data (real, curated) | the held-out set |
| `baseline.py` | **real** (local) | keyword-overlap "simpler method" |
| `llm_driver.py` | real w/ key, else **labeled simulation** | drives `llm_grade.grade_answer` |
| `metrics.py` | **real** | accuracy / false-accept / false-reject / macro-F1 |
| `leakage.py` | **real** (local) | exact + near-duplicate leakage scan (challenge 7e) |
| `run_eval.py` | — | one-command entrypoint; writes `results/` |
