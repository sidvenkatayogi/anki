# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

"""Tests for the local, per-device Practice-tab history store in aqt.mediasrv.

Covers the contract in contracts/data-model.md's "Local practice-history store" section:
- append-if-absent dedupe by client_answer_id (a retried/double-submitted save never duplicates)
- append-only semantics (re-answering the same question_id is intentional, not a duplicate)
- tolerant load (missing file / corrupt JSON / malformed entries never raise, and corrupt entries
  are silently skipped rather than failing the whole load)

This store never touches the network or the synced Anki collection (plain JSON-on-disk, gated only
by aqt.mw.pm.profileFolder() for the path and Flask's `request` global for the POST body), so these
tests double as the local-storage-layer proof for AC21 ("Practice tab continues to work fully
offline").
"""

from __future__ import annotations

import json
import os
import tempfile
import types
import uuid
from collections.abc import Iterator

import pytest

import aqt
from aqt.mediasrv import (
    _load_practice_history,
    _practice_history_path,
    _save_practice_history,
    app,
    append_practice_answer,
)


@pytest.fixture(autouse=True)
def fake_profile_folder() -> Iterator[str]:
    """Point aqt.mw.pm.profileFolder() at a fresh tmpdir, and restore aqt.mw afterwards."""
    tmpdir = tempfile.mkdtemp()
    original_mw = getattr(aqt, "mw", None)
    aqt.mw = types.SimpleNamespace(
        pm=types.SimpleNamespace(profileFolder=lambda: tmpdir)
    )
    try:
        yield tmpdir
    finally:
        aqt.mw = original_mw


def make_record(**overrides: object) -> dict:
    record = {
        "client_answer_id": str(uuid.uuid4()),
        "question_id": "seed-001",
        "category": "bio_biochem",
        "correct": True,
        "difficulty_b": 0.0,
        "answered_at": 1_700_000_000,
    }
    record.update(overrides)
    return record


def post_answer(record: dict) -> bytes:
    with app.test_request_context(
        "/append_practice_answer",
        method="POST",
        data=json.dumps(record).encode("utf-8"),
    ):
        return append_practice_answer()


class TestAppendAndLoad:
    def test_append_one_record(self) -> None:
        record = make_record()
        post_answer(record)

        data = _load_practice_history()
        assert len(data["records"]) == 1
        stored = data["records"][0]
        assert stored["client_answer_id"] == record["client_answer_id"]
        assert stored["question_id"] == record["question_id"]
        assert stored["category"] == record["category"]
        assert stored["correct"] == record["correct"]
        assert stored["difficulty_b"] == record["difficulty_b"]
        assert stored["answered_at"] == record["answered_at"]

    def test_double_submit_same_client_answer_id_dedupes(self) -> None:
        """Retried/double-submitted save with the same client_answer_id never duplicates."""
        record = make_record()

        post_answer(record)
        post_answer(record)  # simulate a rapid double-submit / retried write

        data = _load_practice_history()
        assert len(data["records"]) == 1

    def test_different_client_answer_ids_same_question_are_both_kept(self) -> None:
        """Practice history is append-only: re-answering the same question is not a duplicate."""
        first = make_record(question_id="seed-007", correct=True)
        second = make_record(question_id="seed-007", correct=False)
        assert first["client_answer_id"] != second["client_answer_id"]

        post_answer(first)
        post_answer(second)

        data = _load_practice_history()
        assert len(data["records"]) == 2
        question_ids = {r["question_id"] for r in data["records"]}
        assert question_ids == {"seed-007"}
        correctness = {r["client_answer_id"]: r["correct"] for r in data["records"]}
        assert correctness[first["client_answer_id"]] is True
        assert correctness[second["client_answer_id"]] is False


class TestTolerantLoad:
    def test_missing_file_returns_empty_records(self) -> None:
        # No file has been written yet in the fresh tmpdir.
        assert not os.path.exists(_practice_history_path())
        assert _load_practice_history() == {"records": []}

    def test_corrupt_json_file_returns_empty_records(self) -> None:
        path = _practice_history_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as file:
            file.write("{not valid json!!")

        assert _load_practice_history() == {"records": []}

    def test_entry_missing_required_key_is_skipped(self) -> None:
        good = make_record()
        bad = make_record()
        del bad["answered_at"]  # malformed: missing a required key

        _save_practice_history({"records": [good, bad]})

        data = _load_practice_history()
        assert len(data["records"]) == 1
        assert data["records"][0]["client_answer_id"] == good["client_answer_id"]
