"""Drives the *real* shipping grader (``qt/aqt/llm_grade.py``).

Two modes:

* **Real** (``OPENAI_API_KEY`` set): every record is graded by the actual
  ``grade_answer`` function over the network. Errors are surfaced (re-raised),
  not swallowed — in an eval we want to *measure the model*, so a broken grader
  must fail loudly rather than silently score everything "incorrect".

* **Simulated** (no key): a DETERMINISTIC, clearly-labeled illustrative error
  profile so the harness always runs end-to-end. This is **NOT a measurement**;
  every simulated result is tagged ``simulated: true`` and the note contains the
  word ``SIMULATED``. Set ``OPENAI_API_KEY`` and re-run for real numbers.

Loading note: we import ``llm_grade.py`` *in isolation* via importlib from its
file path. Importing ``aqt.llm_grade`` normally would trigger ``aqt/__init__``
(PyQt) and fail headless. ``llm_grade.py`` only imports ``json`` and
``requests``, so isolated loading is safe.
"""

from __future__ import annotations

import importlib.util
import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
# mcat_eval -> tests -> qt -> <repo root>
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(_HERE)))
_LLM_GRADE_PATH = os.path.join(REPO_ROOT, "qt", "aqt", "llm_grade.py")

_llm_grade_module = None


def load_llm_grade():
    """Load and cache the isolated ``llm_grade`` module from its file path."""
    global _llm_grade_module
    if _llm_grade_module is None:
        spec = importlib.util.spec_from_file_location(
            "mcat_llm_grade", _LLM_GRADE_PATH
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _llm_grade_module = module
    return _llm_grade_module


def grade_record_real(record: dict, api_key: str) -> tuple[bool, str]:
    """Grade a single record with the real model.

    Returns ``(correct, feedback)``. Any error (missing key / network / bad
    response) propagates so ``run_eval`` can report that the grader failed —
    we do NOT fail-closed to "incorrect", which would corrupt the measurement.
    """
    llm_grade = load_llm_grade()
    return llm_grade.grade_answer(
        question=record["question"],
        expected=record["expected"],
        provided=record["student_answer"],
        api_key=api_key,
    )


# --- Deterministic simulation --------------------------------------------------
#
# Policy (fixed and transparent — see README's honesty framing):
#   1. Start from a perfect oracle: pred = record["gold_correct"] for all.
#   2. Inject a small, fixed error profile modelling a strong-but-imperfect LLM:
#      * FALSE ACCEPTS: among gold-INCORRECT records whose answer_kind is a
#        near-miss ({"misconception","wrong_opposite"}), sorted by id, flip the
#        records at 0-based positions [3, 9] to correct. (2 false accepts.)
#      * FALSE REJECTS: among gold-CORRECT records whose answer_kind is
#        forgiving-recall ({"partial","paraphrase","spelling"}), sorted by id,
#        flip the records at 0-based positions [1, 6, 11, 18, 24] to incorrect.
#        (Up to 5 false rejects; positions that don't exist are skipped.)
# The flips are chosen to look like plausible LLM mistakes; they are illustrative
# ONLY and are not derived from any real model output.

_FALSE_ACCEPT_KINDS = {"misconception", "wrong_opposite"}
_FALSE_ACCEPT_POSITIONS = (3, 9)

_FALSE_REJECT_KINDS = {"partial", "paraphrase", "spelling"}
_FALSE_REJECT_POSITIONS = (1, 6, 11, 18, 24)

_SIMULATION_NOTE = (
    "SIMULATED (no OPENAI_API_KEY): deterministic illustrative error profile, "
    "NOT a real measurement. Set OPENAI_API_KEY and re-run for real numbers."
)


def _simulate(records: list[dict]) -> dict:
    # Start from the oracle, keyed by id so flips are unambiguous.
    verdict = {rec["id"]: bool(rec["gold_correct"]) for rec in records}

    false_accept_candidates = sorted(
        (
            rec
            for rec in records
            if not rec["gold_correct"] and rec["answer_kind"] in _FALSE_ACCEPT_KINDS
        ),
        key=lambda rec: rec["id"],
    )
    for pos in _FALSE_ACCEPT_POSITIONS:
        if pos < len(false_accept_candidates):
            verdict[false_accept_candidates[pos]["id"]] = True

    false_reject_candidates = sorted(
        (
            rec
            for rec in records
            if rec["gold_correct"] and rec["answer_kind"] in _FALSE_REJECT_KINDS
        ),
        key=lambda rec: rec["id"],
    )
    for pos in _FALSE_REJECT_POSITIONS:
        if pos < len(false_reject_candidates):
            verdict[false_reject_candidates[pos]["id"]] = False

    predictions = [verdict[rec["id"]] for rec in records]
    return {"simulated": True, "predictions": predictions, "note": _SIMULATION_NOTE}


def load_agent_verdicts(records: list[dict], path: str) -> dict:
    """Load real LLM verdicts produced by a grading *agent* (a stand-in for
    ``gpt-5-nano`` when no ``OPENAI_API_KEY`` is available).

    The agent graded a BLIND copy of the set (``grader_blind.json`` — gold labels
    removed) using the exact ``llm_grade`` rubric, so this is a **real
    measurement of LLM grading**, not a simulation. The file maps each record id
    to either a bool or ``{"correct": bool, "feedback": str}``.
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    # Allow either a flat {id: ...} map or {"verdicts": {id: ...}}.
    verdicts = data.get("verdicts", data) if isinstance(data, dict) else {}

    predictions: list[bool] = []
    missing: list[str] = []
    for rec in records:
        entry = verdicts.get(rec["id"])
        if entry is None:
            missing.append(rec["id"])
            predictions.append(False)
        elif isinstance(entry, dict):
            predictions.append(bool(entry.get("correct")))
        else:
            predictions.append(bool(entry))
    if missing:
        raise ValueError(
            f"agent verdicts missing {len(missing)} record id(s): {missing[:8]}"
        )
    return {
        "simulated": False,
        "source": "agent",
        "predictions": predictions,
        "note": (
            "graded by an LLM agent (Claude) as a stand-in for gpt-5-nano; the "
            "agent judged a blind copy of the set (gold labels withheld) using "
            "the exact llm_grade rubric — a real measurement, not a simulation."
        ),
    }


def grade_all(records: list[dict], api_key: str | None) -> dict:
    """Grade every record.

    Returns ``{"simulated": bool, "predictions": list[bool], "note": str}`` with
    ``predictions`` aligned to ``records`` order. Real when ``api_key`` is a
    non-empty string, otherwise the labeled deterministic simulation.
    """
    if isinstance(api_key, str) and api_key.strip():
        predictions = []
        for rec in records:
            correct, _feedback = grade_record_real(rec, api_key)
            predictions.append(bool(correct))
        return {
            "simulated": False,
            "source": "openai",
            "predictions": predictions,
            "note": "graded by real model (gpt-5-nano) via OPENAI_API_KEY",
        }
    return _simulate(records)
