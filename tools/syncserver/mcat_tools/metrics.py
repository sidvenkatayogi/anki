# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Pure-Python Performance (Rasch/1-PL MAP ability estimate) and Readiness
(MCAT scaled-score projection) formulas.

Implements EXACTLY the formulas documented in
`.factory/runs/2026-07-02-read-practice-tabs/contracts/data-model.md`
("Performance formula" and "Readiness formula" sections). Do not improvise
or approximate differently -- those docs are the authoritative contract.

Stdlib only (no numpy/scipy).
"""

from __future__ import annotations

import math

# The 4 canonical MCAT categories, 1:1 with the 4 MCAT sections.
CANONICAL_CATEGORIES = ("bio_biochem", "chem_phys", "psych_soc", "cars")

MIN_N_PERFORMANCE = 5


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def estimate_theta(records: list[tuple[int, float]]) -> float:
    """MAP Newton-Raphson estimate of theta (Rasch / 1-PL ability), N(0,1)
    prior on theta. `records` is a list of (correct 0/1, difficulty_b).

    theta_0 = 0
    p_i(theta) = 1 / (1 + exp(-(theta - b_i)))
    theta_{k+1} = theta_k + [ sum_i (r_i - p_i(theta_k)) - theta_k ]
                            / [ sum_i p_i(theta_k)*(1 - p_i(theta_k)) + 1 ]

    Iterate up to 25x or until |delta theta| < 1e-4; clamp final theta to
    [-4, 4]. Empty records -> theta = 0.0.
    """
    if not records:
        return 0.0

    theta = 0.0
    for _ in range(25):
        numerator = 0.0
        denominator = 0.0
        for r_i, b_i in records:
            p_i = 1.0 / (1.0 + math.exp(-(theta - b_i)))
            numerator += r_i - p_i
            denominator += p_i * (1.0 - p_i)
        numerator -= theta
        denominator += 1.0
        delta = numerator / denominator
        theta += delta
        if abs(delta) < 1e-4:
            break

    return _clamp(theta, -4.0, 4.0)


def performance_bucket(records: list[tuple[int, float]]) -> dict:
    """records: list of (correct 0/1, difficulty_b).

    Returns {"p": float, "enough_data": bool, "n": int}.
    p = 1 / (1 + exp(-theta)) using theta from estimate_theta(records).
    enough_data requires N >= 5 -- p is still computed (for internal use)
    even when N < 5, but enough_data is reported False.
    """
    n = len(records)
    theta = estimate_theta(records)
    p = 1.0 / (1.0 + math.exp(-theta))
    return {"p": p, "enough_data": n >= MIN_N_PERFORMANCE, "n": n}


def compute_performance(practice_history: list[dict]) -> dict:
    """practice_history items:
    {"question_id": str, "category": str, "correct": bool, "difficulty_b": float}.

    Returns {"overall": {...}, "per_category": [{"category": ..., ...}, ...]}.
    per_category includes an entry for every category present in the input
    (only categories that actually appear -- the 4 canonical categories are
    not invented if absent). overall uses the full history.
    """
    overall_records: list[tuple[int, float]] = [
        (1 if item["correct"] else 0, float(item["difficulty_b"]))
        for item in practice_history
    ]
    overall = performance_bucket(overall_records)

    by_category: dict[str, list[tuple[int, float]]] = {}
    order: list[str] = []
    for item in practice_history:
        category = item["category"]
        if category not in by_category:
            by_category[category] = []
            order.append(category)
        by_category[category].append(
            (1 if item["correct"] else 0, float(item["difficulty_b"]))
        )

    per_category = []
    for category in order:
        bucket = performance_bucket(by_category[category])
        per_category.append({"category": category, **bucket})

    return {"overall": overall, "per_category": per_category}


def _performance_lookup(performance: dict) -> dict[str, dict]:
    lookup: dict[str, dict] = {}
    for entry in performance.get("per_category", []):
        lookup[entry["category"]] = entry
    return lookup


def _fsrs_lookup(fsrs: dict) -> dict[str, dict]:
    lookup: dict[str, dict] = {}
    for entry in fsrs.get("per_category", []):
        lookup[entry["category"]] = entry
    return lookup


def compute_readiness(performance: dict, fsrs: dict) -> dict:
    """Implements Steps 1-5 + confidence label + overall enough_data
    give-up rule from the Readiness formula section of data-model.md.

    performance: output of compute_performance (or equivalent shape).
    fsrs: {"per_category": [{"category", "average_recall", "mastered_fraction",
    "enough_data", "graded_reviews"}], "overall_mean_recall": float}.
    """
    perf_lookup = _performance_lookup(performance)
    fsrs_lookup = _fsrs_lookup(fsrs)

    total_point = 0.0
    total_low = 0.0
    total_high = 0.0
    halfwidths: list[float] = []
    sections_with_data = 0
    missing_categories: list[str] = []

    for category in CANONICAL_CATEGORIES:
        perf_entry = perf_lookup.get(category)
        fsrs_entry = fsrs_lookup.get(category)

        perf_enough = bool(perf_entry and perf_entry.get("enough_data"))
        fsrs_enough = bool(fsrs_entry and fsrs_entry.get("enough_data"))

        p_cat = perf_entry["p"] if perf_entry else None
        n_practice_cat = perf_entry["n"] if perf_entry else 0
        graded_reviews_cat = fsrs_entry["graded_reviews"] if fsrs_entry else 0

        # Step 1 -- per-category mastery signal (defined only if fsrs.enough_data)
        m_cat = None
        if fsrs_enough:
            average_recall = fsrs_entry["average_recall"]
            mastered_fraction = fsrs_entry["mastered_fraction"]
            m_cat = _clamp(0.6 * average_recall + 0.4 * mastered_fraction, 0.0, 1.0)

        # Step 2 -- proficiency
        has_data = perf_enough or fsrs_enough
        if perf_enough and fsrs_enough:
            proficiency_cat = 0.5 * p_cat + 0.5 * m_cat
        elif perf_enough:
            proficiency_cat = p_cat
        elif fsrs_enough:
            proficiency_cat = m_cat
        else:
            proficiency_cat = 0.5  # no data -> excluded, treated as neutral

        if has_data:
            sections_with_data += 1
        else:
            missing_categories.append(category)

        # Step 3 -- section scaled score
        score_section = round(118 + 14 * proficiency_cat)
        score_section = int(_clamp(score_section, 118, 132))

        # Step 4 -- CI per section
        n_eff_section = n_practice_cat + 0.2 * graded_reviews_cat
        halfwidth_section = _clamp(14 / math.sqrt(1 + n_eff_section), 1.0, 7.0)
        score_low_section = _clamp(score_section - halfwidth_section, 118, 132)
        score_high_section = _clamp(score_section + halfwidth_section, 118, 132)

        total_point += score_section
        total_low += score_low_section
        total_high += score_high_section
        halfwidths.append(halfwidth_section)

    score_point = int(round(total_point))
    score_low = int(round(total_low))
    score_high = int(round(total_high))

    avg_halfwidth = sum(halfwidths) / len(halfwidths)
    if avg_halfwidth <= 2:
        confidence = "high"
    elif avg_halfwidth <= 4:
        confidence = "medium"
    else:
        confidence = "low"

    enough_data = sections_with_data >= 2
    if enough_data:
        note = ""
    else:
        note = (
            "not enough data yet -- need at least 2 of 4 sections with "
            "sufficient practice or review history "
            f"(missing: {', '.join(missing_categories)})"
        )

    return {
        "score_point": score_point,
        "score_low": score_low,
        "score_high": score_high,
        "confidence": confidence,
        "note": note,
        "enough_data": enough_data,
    }
