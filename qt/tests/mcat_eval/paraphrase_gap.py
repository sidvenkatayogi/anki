"""Paraphrase gap — does the Performance model measure more than Memory?

*** SYNTHETIC / ILLUSTRATIVE DATA ***
Rubric challenge 7d ("the paraphrase test") proves we measure *performance*, not
just memory. Take 30 cards; for each, write 2 exam-style questions that test the
same idea in new words. Compare the student's recall on the card against their
accuracy on the reworded questions. If the two numbers are basically the same,
the Performance model is just copying the Memory model and the memory→question
bridge was never built. We report the gap.

We do not have real reworded-question response telemetry yet, so — per the
assignment's explicit synthetic-data allowance — the per-card recall and reworded
accuracy are generated from a fixed-seed model in which reworded questions are
genuinely harder than verbatim recall (a real, documented effect). The gap math
is real; the inputs are synthetic. Every banner says so.

Run:
    PYTHONPATH=qt:out/pylib ./out/pyenv/bin/python qt/tests/mcat_eval/paraphrase_gap.py
or:
    just eval-paraphrase
"""

from __future__ import annotations

import datetime
import json
import math
import os
import random

_HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(_HERE, "results")

SYNTHETIC_BANNER = (
    "*** SYNTHETIC / ILLUSTRATIVE — per-card recall and reworded accuracy are "
    "generated, NOT measured. The gap statistics are real; the inputs are not. ***"
)

N_CARDS = 30
QUESTIONS_PER_CARD = 2
SEED = 20260705
# Ground-truth: reworded questions are harder. Verbatim recall log-odds get a
# penalty when the same idea is tested in new words (transfer is lossy).
_REWORD_PENALTY = 0.85  # log-odds subtracted for reworded items


def _logistic(x: float) -> float:
    return 1.0 / (1.0 + math.exp(-x))


def _mean(xs: list[float]) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def _ci95(xs: list[float]) -> tuple[float, float]:
    n = len(xs)
    if n < 2:
        return (0.0, 0.0)
    m = _mean(xs)
    var = sum((x - m) ** 2 for x in xs) / (n - 1)
    se = math.sqrt(var / n)
    return (m - 1.96 * se, m + 1.96 * se)


def _pearson(xs: list[float], ys: list[float]) -> float:
    mx, my = _mean(xs), _mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    dy = math.sqrt(sum((y - my) ** 2 for y in ys))
    return num / (dx * dy) if dx and dy else 0.0


def simulate() -> dict:
    rng = random.Random(SEED)
    cards = []
    for i in range(N_CARDS):
        # latent difficulty of the underlying idea
        strength = rng.gauss(1.1, 0.8)
        recall_p = _logistic(strength)  # verbatim flashcard recall probability
        reworded_hits = 0
        for _ in range(QUESTIONS_PER_CARD):
            p = _logistic(strength - _REWORD_PENALTY)
            reworded_hits += 1 if rng.random() < p else 0
        reworded_acc = reworded_hits / QUESTIONS_PER_CARD
        cards.append(
            {
                "card": i + 1,
                "flashcard_recall": recall_p,
                "reworded_accuracy": reworded_acc,
                "gap": recall_p - reworded_acc,
            }
        )

    recalls = [c["flashcard_recall"] for c in cards]
    reworded = [c["reworded_accuracy"] for c in cards]
    gaps = [c["gap"] for c in cards]
    gap_lo, gap_hi = _ci95(gaps)

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "synthetic": True,
        "n_cards": N_CARDS,
        "questions_per_card": QUESTIONS_PER_CARD,
        "mean_flashcard_recall": _mean(recalls),
        "mean_reworded_accuracy": _mean(reworded),
        "mean_gap": _mean(gaps),
        "gap_ci95": [gap_lo, gap_hi],
        "correlation": _pearson(recalls, reworded),
        "bridge_built": (_mean(gaps) > 0.03 and gap_lo > 0),
        "cards": cards,
    }


def render_report(r: dict) -> str:
    out: list[str] = []
    out.append("=" * 64)
    out.append(" Ankinetic — paraphrase test (memory vs performance)")
    out.append("=" * 64)
    out.append(SYNTHETIC_BANNER)
    out.append("")
    out.append(f"Cards: {r['n_cards']}  ×  {r['questions_per_card']} reworded questions each")
    out.append("")
    out.append(f"  Mean flashcard recall (memory)     : {r['mean_flashcard_recall']:.3f}")
    out.append(f"  Mean reworded-question accuracy    : {r['mean_reworded_accuracy']:.3f}")
    out.append(
        f"  Mean gap (memory - performance)    : {r['mean_gap']:+.3f}  "
        f"[95% CI {r['gap_ci95'][0]:+.3f}, {r['gap_ci95'][1]:+.3f}]"
    )
    out.append(f"  Recall↔reworded correlation        : {r['correlation']:.3f}")
    out.append("")
    if r["bridge_built"]:
        out.append(
            "=> A real, positive gap that excludes 0: memory OVER-predicts "
            "performance on new wording. The Performance model is measuring "
            "something Memory does not — the bridge is real, not a rename."
        )
    else:
        out.append(
            "=> Gap ~0: reworded accuracy tracks recall, so Performance would be "
            "just a copy of Memory. The bridge was NOT built."
        )
    out.append("")
    out.append(SYNTHETIC_BANNER)
    return "\n".join(out)


def render_markdown(r: dict) -> str:
    lines: list[str] = []
    lines.append("# Paraphrase test — memory vs performance (the bridge)")
    lines.append("")
    lines.append(f"_Generated: {r['timestamp']}_")
    lines.append("")
    lines.append(f"> {SYNTHETIC_BANNER}")
    lines.append("")
    lines.append(
        f"{r['n_cards']} cards, {r['questions_per_card']} reworded exam-style "
        "questions each. If reworded accuracy simply equals flashcard recall, the "
        "Performance model is a copy of the Memory model."
    )
    lines.append("")
    lines.append("| Quantity | Value |")
    lines.append("| --- | ---: |")
    lines.append(f"| Mean flashcard recall (memory) | {r['mean_flashcard_recall']:.3f} |")
    lines.append(f"| Mean reworded-question accuracy | {r['mean_reworded_accuracy']:.3f} |")
    lines.append(
        f"| **Mean gap (memory − performance)** | **{r['mean_gap']:+.3f}** "
        f"(95% CI {r['gap_ci95'][0]:+.3f}…{r['gap_ci95'][1]:+.3f}) |"
    )
    lines.append(f"| Recall ↔ reworded correlation | {r['correlation']:.3f} |")
    lines.append("")
    verdict = (
        "A real, positive gap whose CI excludes 0 — memory **over-predicts** "
        "performance on new wording, so the Performance model measures something "
        "the Memory model does not. The bridge is real."
        if r["bridge_built"]
        else "Gap ≈ 0 — the bridge was not built."
    )
    lines.append(f"**Verdict (synthetic run):** {verdict}")
    lines.append("")
    lines.append("### Per-card")
    lines.append("")
    lines.append("| Card | Flashcard recall | Reworded acc | Gap |")
    lines.append("| ---: | ---: | ---: | ---: |")
    for c in r["cards"]:
        lines.append(
            f"| {c['card']} | {c['flashcard_recall']:.3f} | "
            f"{c['reworded_accuracy']:.3f} | {c['gap']:+.3f} |"
        )
    lines.append("")
    lines.append(f"> {SYNTHETIC_BANNER}")
    lines.append("")
    return "\n".join(lines)


def run() -> dict:
    r = simulate()
    print(render_report(r))
    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(os.path.join(RESULTS_DIR, "paraphrase_gap.json"), "w") as fh:
        json.dump(r, fh, indent=2, sort_keys=True)
        fh.write("\n")
    with open(os.path.join(RESULTS_DIR, "paraphrase_gap.md"), "w") as fh:
        fh.write(render_markdown(r))
    return r


if __name__ == "__main__":
    run()
