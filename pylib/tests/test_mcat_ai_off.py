# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

"""The app still gives a score with AI switched off (Friday deliverable).

The only AI feature in the fork is the optional LLM answer-grader
(`qt/aqt/llm_grade.py`). This test proves two things:

1.  With **no API key** the grader refuses to run (fails closed), so review
    falls back to the manual ease buttons -- i.e. AI is genuinely optional.
2.  With AI off, the **Memory score still computes locally** from FSRS review
    history via the `tag_mastery` engine RPC -- no network, no model. (The
    Performance/Readiness scores are likewise pure-local math; see
    `ts/routes/practice/mcatMetrics.test.ts`, and the per-topic memory maths is
    covered by the Rust `tag_mastery` unit tests.)
"""

from __future__ import annotations

import importlib.util
import os

import pytest

from tests.shared import getEmptyCol

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load_llm_grade():
    """Load the real grader module in isolation (no `aqt`/Qt import)."""
    path = os.path.join(REPO_ROOT, "qt", "aqt", "llm_grade.py")
    spec = importlib.util.spec_from_file_location("mcat_llm_grade_aioff", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_grader_fails_closed_without_api_key():
    llm = _load_llm_grade()
    with pytest.raises(Exception):
        llm.grade_answer(question="q", expected="e", provided="p", api_key="")
    with pytest.raises(Exception):
        llm.grade_answer(question="q", expected="e", provided="p", api_key="   ")


def test_ease_mapping_is_pure_and_local():
    llm = _load_llm_grade()
    assert llm.ease_from_elapsed(1_000) == llm.EASY
    assert llm.ease_from_elapsed(30_000) == llm.GOOD
    assert llm.ease_from_elapsed(120_000) == llm.HARD


def test_memory_score_computes_with_ai_off():
    col = getEmptyCol()
    # AI is off: no key is set anywhere and no network call is made below.
    col.set_config("fsrs", True)

    # Lift the default 20-new-cards/day cap so a single session can span all
    # topics and cross the give-up thresholds.
    did = col.decks.id("Default")
    conf = col.decks.config_dict_for_deck_id(did)
    conf["new"]["perDay"] = 1000
    conf["rev"]["perDay"] = 1000
    col.decks.save(conf)

    tags = ["bio::a", "bio::b", "chem::c", "chem::d", "psy::e", "psy::f"]
    per_tag = 16
    for t in tags:
        for i in range(per_tag):
            note = col.newNote()
            note["Front"] = f"{t} q{i}"
            note["Back"] = f"{t} a{i}"
            note.tags = [t]
            col.addNote(note)

    # Build local review history (a few passes through the learning steps).
    for _ in range(6):
        while True:
            card = col.sched.getCard()
            if not card:
                break
            card.start_timer()
            col.sched.answerCard(card, 3)  # Good -- no AI involved

    resp = col._backend.tag_mastery(group_depth=2, mastered_threshold=0.0, search="")

    # A real, local Memory number is produced with zero AI / zero network.
    assert resp.overall_n > 0
    assert 0.0 < resp.overall_mean_recall <= 1.0
    # ...reported honestly as a range (90% CI brackets the point estimate).
    assert resp.overall_ci_low <= resp.overall_mean_recall <= resp.overall_ci_high

    # ...with the give-up-rule inputs present and satisfied (>=150 graded
    # reviews across >=5 topics), so the dashboard shows a number rather than
    # abstaining -- all with AI off.
    assert resp.total_graded_reviews >= 150
    assert resp.topics_with_reviews >= 5
