# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Tests for the mcat_tools FastAPI app.

Run with:
    python3 -m pytest tools/syncserver/mcat_tools/tests/test_app.py -v
(from `tools/syncserver/`, or with that dir on PYTHONPATH).
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

TOKEN = "test-token-123"


@pytest.fixture(autouse=True)
def _set_token(monkeypatch):
    monkeypatch.setenv("MCAT_TOOLS_TOKEN", TOKEN)
    yield


@pytest.fixture()
def client():
    # Import inside the fixture so the MCAT_TOOLS_TOKEN env var (set by the
    # autouse fixture) is present before any module-level state is read.
    from mcat_tools.app import app

    return TestClient(app)


def auth_headers(token: str = TOKEN) -> dict:
    return {"X-Mcat-Token": token}


# ---------------------------------------------------------------------------
# /health, /version -- no auth
# ---------------------------------------------------------------------------


def test_health_no_auth(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_version_no_auth(client):
    resp = client.get("/version")
    assert resp.status_code == 200
    body = resp.json()
    assert body["version"] == "1.0.0"
    assert isinstance(body["build"], str) and body["build"]


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


def test_missing_token_rejected(client):
    resp = client.get("/practice/questions")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


def test_wrong_token_rejected(client):
    resp = client.get("/practice/questions", headers=auth_headers("wrong"))
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


def test_no_token_configured_locks_route(monkeypatch, client):
    monkeypatch.delenv("MCAT_TOOLS_TOKEN", raising=False)
    resp = client.get("/practice/questions", headers=auth_headers(TOKEN))
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# /metrics/compute
# ---------------------------------------------------------------------------


def _fsrs_category(category: str, enough: bool = True) -> dict:
    return {
        "category": category,
        "average_recall": 0.8,
        "mastered_fraction": 0.7,
        "enough_data": enough,
        "graded_reviews": 50,
    }


def test_metrics_compute_happy_path(client):
    body = {
        "practice_history": [
            {
                "question_id": "q1",
                "category": "bio_biochem",
                "correct": True,
                "difficulty_b": 0.0,
            },
            {
                "question_id": "q2",
                "category": "bio_biochem",
                "correct": False,
                "difficulty_b": 0.5,
            },
            {
                "question_id": "q3",
                "category": "bio_biochem",
                "correct": True,
                "difficulty_b": -0.5,
            },
            {
                "question_id": "q4",
                "category": "bio_biochem",
                "correct": True,
                "difficulty_b": 0.0,
            },
            {
                "question_id": "q5",
                "category": "bio_biochem",
                "correct": True,
                "difficulty_b": 0.2,
            },
        ],
        "fsrs": {
            "per_category": [_fsrs_category("bio_biochem")],
            "overall_mean_recall": 0.8,
        },
    }
    resp = client.post("/metrics/compute", headers=auth_headers(), json=body)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert "performance" in data and "readiness" in data
    assert data["performance"]["overall"]["n"] == 5
    assert data["performance"]["overall"]["enough_data"] is True
    assert isinstance(data["readiness"]["score_point"], int)
    assert data["readiness"]["confidence"] in ("high", "medium", "low")


def test_metrics_compute_malformed_body(client):
    resp = client.post(
        "/metrics/compute",
        headers=auth_headers(),
        json={"practice_history": "not-a-list", "fsrs": {}},
    )
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"


def test_metrics_compute_requires_auth(client):
    resp = client.post("/metrics/compute", json={"practice_history": [], "fsrs": {}})
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# /practice/questions
# ---------------------------------------------------------------------------


def test_practice_questions_404_when_seed_missing(client, monkeypatch):
    monkeypatch.setattr("mcat_tools.app.load_seed_questions", lambda: None)
    resp = client.get("/practice/questions", headers=auth_headers())
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


def test_practice_questions_returns_seed_when_present(client, monkeypatch):
    fake_questions = [
        {
            "id": "seed-001",
            "category": "bio_biochem",
            "stem": "stem",
            "options": ["a", "b", "c", "d"],
            "answer_index": 0,
            "explanation": "exp",
            "difficulty_b": 0.0,
        }
    ]
    monkeypatch.setattr("mcat_tools.app.load_seed_questions", lambda: fake_questions)
    resp = client.get("/practice/questions", headers=auth_headers())
    assert resp.status_code == 200
    assert resp.json() == {"questions": fake_questions}


def test_practice_questions_resolves_the_real_committed_seed_file(client):
    """No monkeypatching of load_seed_questions here -- this proves the
    ACTUAL committed file at mcat_tools/data/practice-seed.json resolves at
    runtime (regression lock for the fixed .factory/-scratch-dir defect:
    production must never depend on the git-ignored .factory/ tree)."""
    from mcat_tools.practice_seed import SEED_PATH

    assert ".factory" not in str(SEED_PATH)
    assert SEED_PATH.exists(), f"committed seed file missing at {SEED_PATH}"

    with SEED_PATH.open("r", encoding="utf-8") as f:
        on_disk_questions = json.load(f)

    resp = client.get("/practice/questions", headers=auth_headers())
    assert resp.status_code == 200
    assert resp.json() == {"questions": on_disk_questions}
    assert len(on_disk_questions) > 0
