"""Scoring for the grader eval — real, stdlib only, deterministic.

Convention: the *positive* class is "answer is correct". So a **false accept**
is a gold-incorrect answer predicted correct (the dangerous error), and a
**false reject** is a gold-correct answer predicted incorrect.
"""

from __future__ import annotations

# Pre-registered cutoff (fixed BEFORE looking at any result — see README).
CUTOFF = {"accuracy": 0.88, "false_accept_rate": 0.08}


def _safe_div(numerator: float, denominator: float) -> float:
    return numerator / denominator if denominator else 0.0


def _f1(tp: int, fp: int, fn: int) -> float:
    """F1 for one class: 2*tp / (2*tp + fp + fn)."""
    return _safe_div(2 * tp, 2 * tp + fp + fn)


def score(gold: list[bool], pred: list[bool]) -> dict:
    """Compute accuracy / error rates / precision / recall / macro-F1.

    ``gold`` and ``pred`` are aligned lists of bools (True == correct).
    """
    tp = tn = fp = fn = 0
    for g, p in zip(gold, pred):
        if g and p:
            tp += 1
        elif g and not p:
            fn += 1
        elif (not g) and p:
            fp += 1
        else:
            tn += 1

    n_pos = tp + fn  # gold correct
    n_neg = tn + fp  # gold incorrect
    n = n_pos + n_neg

    # Macro-F1 averages the F1 of the "correct" class and the "incorrect" class.
    # For the negative (incorrect) class the roles swap: tp->tn, fp->fn, fn->fp.
    f1_correct = _f1(tp, fp, fn)
    f1_incorrect = _f1(tn, fn, fp)

    return {
        "accuracy": _safe_div(tp + tn, n),
        "false_accept_rate": _safe_div(fp, n_neg),
        "false_reject_rate": _safe_div(fn, n_pos),
        "precision": _safe_div(tp, tp + fp),
        "recall": _safe_div(tp, tp + fn),
        "macro_f1": (f1_correct + f1_incorrect) / 2,
        "tp": tp,
        "tn": tn,
        "fp": fp,
        "fn": fn,
        "n_pos": n_pos,
        "n_neg": n_neg,
    }


def passes_cutoff(m: dict) -> bool:
    """True iff metrics clear the pre-registered ship bar."""
    return m["accuracy"] >= CUTOFF["accuracy"] and (
        m["false_accept_rate"] <= CUTOFF["false_accept_rate"]
    )
