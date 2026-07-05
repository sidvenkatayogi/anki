# AI CARD-CHECK — checking LLM-generated flashcards (rubric challenge 7f)

This package answers one question honestly: **if an LLM writes flashcards from a
real source, how many are good enough to ship, and can we mechanically block the
bad ones before a student ever sees them?**

Run it:

```
PYTHONPATH=out/pylib ./out/pyenv/bin/python qt/tests/mcat_eval/card_check.py
```

It prints the three counts, writes `results/card_check.{md,json}`, and exits
non-zero only if a wrong card slips through the block gate (the safety invariant).

## The named source (one, open-licensed)

Every gold fact and every generated card is drawn from **one** source:

> **OpenStax Biology 2e, Chapter 3 — Biological Macromolecules**
> (CC BY 4.0) — https://openstax.org/books/biology-2e/pages/3-introduction
> Sections 3.1 synthesis (dehydration/hydrolysis), 3.2 carbohydrates,
> 3.3 lipids, 3.4 proteins, 3.5 nucleic acids.

This is the same open-licensed publisher used elsewhere in the fork. Naming the
exact chapter is the honesty rule: the checker's ground truth traces back to a
citable, correct source, not to a model's memory.

## The gold set — `card_gold_set.json`

**50 MCAT-relevant Q&A pairs with known-correct answers**, each tagged with a
`content_area` (macromolecule_synthesis · carbohydrates · lipids · proteins ·
nucleic_acids). The `correct_answer` field is the only ground truth the checker
judges a generated card against. Facts were hand-transcribed from the named
chapter and cross-checked; they are genuinely, unambiguously correct and are
**not** tuned against any generated card.

## The generated cards — `generated_cards.json`

**50 "generated" flashcards** (front/back) standing in for the output of an LLM
card-generator pointed at that chapter. They carry a **deliberate, realistic
quality mix** so the checker has something to catch:

| Seeded class | n | Examples |
| --- | ---: | --- |
| correct_useful | 40 | right fact, taught clearly (e.g. "hydrolysis adds water to split a polymer") |
| **wrong** (a wrong fact — worst) | 5 | glucose = C5H10O5; glycogen stores glucose in plants; 22 amino acids; peptide→glycosidic; DNA has ribose |
| correct_bad_teaching (vague/trivial/duplicate) | 5 | "denaturation is when a protein changes"; "are carbs a macromolecule? yes"; circular monomer card; a duplicate hydrolysis card |

**Honesty label.** The file's top-level `_note` states loudly that these are a
**captured / stand-in generation set** — hand-authored, not the live output of a
model call — so the mix is known and the checker's verdict can be validated
against `intended_class`. Each card also carries a pre-recorded
`captured_verdict` used only when no API key is present.

## The pre-registered cutoff (fixed BEFORE looking at results)

Defined as constants at the top of `card_check.py`, chosen before any card was
classified:

- **Block policy** (`is_blocked`): a card ships **only** if it is
  `correct_useful`. Anything `wrong` **or** `correct_bad_teaching` is BLOCKED —
  a wrong fact is worse than no card, and a vague/trivial/duplicate card wastes
  retrieval effort.
- **Batch pass bar:** `PASS_MIN_CORRECT_USEFUL_FRAC = 0.80` (≥ 80% of cards must
  be correct_useful) **AND** `MAX_WRONG_ALLOWED_THROUGH = 0` (zero wrong cards
  may escape the block gate — a hard safety invariant).

## The three counts (challenge requirement)

The checker classifies each card into exactly one of `{correct_useful, wrong,
correct_bad_teaching}` and reports all three counts plus how many were blocked.
Latest stand-in run:

- correct & useful: **40**
- wrong (wrong fact): **5** — all blocked
- correct-but-bad-teaching: **5** — all blocked
- **blocked: 10 / 50**, allowed through: 40, wrong-through: **0** → **PASS**

## Two checking paths (honesty framing)

Mirrors the rest of `mcat_eval`:

- **Real** (`OPENAI_API_KEY` set): every card is classified by a live
  `gpt-5-nano` call. The model id / URL / timeout are borrowed from the shipping
  grader (`qt/aqt/llm_grade.py`) via the same isolated-import trick as
  `llm_driver.py`, so we never pull PyQt into a headless run. Errors propagate —
  an eval must fail loudly, not silently score everything "blocked".
- **Captured stand-in** (no key): classifications come from the pre-recorded
  `captured_verdict` blocks. This is **never presented as a live measurement** —
  stdout, `card_check.md`, and the JSON field `live_model: false` all carry a
  loud STAND-IN banner. A transparency line reports checker-vs-seeded agreement
  (50/50 in the stand-in, by construction) so the reader knows exactly what the
  captured path is.
