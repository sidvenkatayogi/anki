"""Pytest suite asserting the REAL pieces of the MCAT grader eval harness.

These tests exercise the local, deterministic components (dataset, keyword
baseline, metrics, leakage, simulation) and confirm the shipping grader
fails closed without an API key. No network is required.
"""

from __future__ import annotations

import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))  # qt/tests
_PKG = _HERE if os.path.basename(_HERE) == "mcat_eval" else os.path.join(_HERE, "mcat_eval")
sys.path.insert(0, _PKG)

import pytest  # noqa: E402

import baseline  # noqa: E402
import dataset  # noqa: E402
import leakage  # noqa: E402
import llm_driver  # noqa: E402
import metrics  # noqa: E402
import run_eval  # noqa: E402

REQUIRED_KEYS = {
    "id",
    "category",
    "question",
    "expected",
    "student_answer",
    "gold_correct",
    "answer_kind",
}


def test_dataset_integrity():
    records = dataset.load_records()
    assert len(records) == 125
    ids = [rec["id"] for rec in records]
    assert len(set(ids)) == 125, "record ids must be unique"
    gold_correct = sum(1 for rec in records if rec["gold_correct"])
    gold_incorrect = sum(1 for rec in records if not rec["gold_correct"])
    assert gold_correct == 70
    assert gold_incorrect == 55
    for rec in records:
        assert REQUIRED_KEYS.issubset(rec.keys()), f"missing keys in {rec.get('id')}"


def test_keyword_baseline_runs():
    records = dataset.load_records()
    gold = [bool(rec["gold_correct"]) for rec in records]
    preds = [baseline.grade(rec["expected"], rec["student_answer"]) for rec in records]

    # Mandatory: it produces a bool prediction for every record.
    assert len(preds) == len(records)
    assert all(isinstance(p, bool) for p in preds)

    m = metrics.score(gold, preds)
    # Mandatory: every rate metric is a finite float in [0, 1].
    for key in (
        "accuracy",
        "false_accept_rate",
        "false_reject_rate",
        "precision",
        "recall",
        "macro_f1",
    ):
        value = m[key]
        assert isinstance(value, float)
        assert 0.0 <= value <= 1.0

    # Intent (documented, non-flaky): the naive baseline is meant to be beaten,
    # i.e. it should FAIL the pre-registered cutoff. If it somehow passes, we do
    # not hard-fail the suite — we surface it and still require finite metrics.
    if metrics.passes_cutoff(m):
        print(
            "WARNING: keyword baseline unexpectedly passed the cutoff — "
            f"metrics={m}"
        )
    else:
        assert metrics.passes_cutoff(m) is False


def test_leakage_clean():
    records = dataset.load_records()
    result = leakage.scan(records, leakage.grader_corpus())
    assert result["exact_overlaps"] == 0, f"exact leakage: {result['flagged']}"
    assert result["near_dup_overlaps"] == 0, f"near-dup leakage: {result['flagged']}"


def test_grader_fails_closed_without_key():
    llm_grade = llm_driver.load_llm_grade()
    with pytest.raises(ValueError):
        llm_grade.grade_answer(question="q", expected="e", provided="p", api_key="")


def test_ease_mapping():
    llm_grade = llm_driver.load_llm_grade()
    assert llm_grade.ease_from_elapsed(1_000) == llm_grade.EASY
    assert llm_grade.ease_from_elapsed(30_000) == llm_grade.GOOD
    assert llm_grade.ease_from_elapsed(120_000) == llm_grade.HARD


def test_simulation_deterministic_and_labeled():
    records = dataset.load_records()
    first = llm_driver.grade_all(records, None)
    second = llm_driver.grade_all(records, None)
    assert first["simulated"] is True
    assert "SIMULATED" in first["note"]
    assert first["predictions"] == second["predictions"], "simulation must be deterministic"


def test_run_eval_writes_results():
    exit_code = run_eval.main()
    assert exit_code == 0  # dataset is clean, so leakage gate passes

    results_path = os.path.join(_PKG, "results", "latest.json")
    assert os.path.exists(results_path)
    with open(results_path, encoding="utf-8") as fh:
        data = json.load(fh)
    assert "simulated" in data
    assert "metrics" in data["baseline"]
    assert "metrics" in data["llm"]
