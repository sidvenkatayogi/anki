# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Smoke tests for the Palace desktop-sync endpoints (see `contracts/api.md`
in the 2026-07-02-palace-desktop-sync factory run). Not the full acceptance
matrix (AC1-AC12) -- testing-domain owns that separately. Run with:
    python3 -m pytest tools/syncserver/mcat_tools/tests/test_palace.py -v
(from `tools/syncserver/`, or with that dir on PYTHONPATH).
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from mcat_tools import palace_store

TOKEN = "test-token-123"

# A syntactically-valid UUID that is never PUT in these tests -- used
# wherever a test wants a well-formed-but-nonexistent (or deliberately
# mismatched) palace id, as distinct from an id that isn't UUID-shaped at
# all (see the "palace_id validation" section below for that case).
OTHER_PALACE_ID = "11111111-1111-1111-1111-111111111111"


@pytest.fixture(autouse=True)
def _set_token(monkeypatch, tmp_path):
    monkeypatch.setenv("MCAT_TOOLS_TOKEN", TOKEN)
    # Isolate each test's palace data under its own tmp_path so tests never
    # pollute the real data dir or each other. palace_store re-reads this
    # env var per-call (not cached at import time), so this works even
    # though the app module is imported once per test via the `client`
    # fixture below.
    monkeypatch.setenv("MCAT_TOOLS_PALACE_DIR", str(tmp_path / "palaces"))
    yield


@pytest.fixture()
def client():
    from mcat_tools.app import app

    return TestClient(app)


def auth_headers(token: str = TOKEN) -> dict:
    return {"X-Mcat-Token": token}


def _palace(
    palace_id: str = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
    updated_at: str = "2026-07-02T14:03:11Z",
    name: str = "My Kitchen",
) -> dict:
    return {
        "id": palace_id,
        "name": name,
        "createdAt": "2026-06-01T09:00:00Z",
        "updatedAt": updated_at,
        "capacity": 7,
        "hasPhoto": False,
        "hasWorldMap": False,
        "photoVersion": None,
        "loci": [
            {
                "id": "9B2D0000-0000-0000-0000-000000000001",
                "cardID": 1687200000001,
                "label": "The mitochondria is the...",
                "mnemonic": "power plant on the stove",
                "point": {"x": 0.42, "y": 0.61},
                "learned": True,
                "transform": None,
                "anchorID": None,
            }
        ],
    }


# ---------------------------------------------------------------------------
# PUT/GET round-trip
# ---------------------------------------------------------------------------


def test_put_then_get_palace_round_trip(client):
    palace = _palace()
    put_resp = client.put(
        f"/palaces/{palace['id']}", headers=auth_headers(), json=palace
    )
    assert put_resp.status_code == 200, put_resp.text
    assert put_resp.json() == palace

    get_resp = client.get(f"/palaces/{palace['id']}", headers=auth_headers())
    assert get_resp.status_code == 200
    assert get_resp.json() == palace


def test_get_unknown_palace_404(client):
    # Well-formed UUID that was simply never PUT -- "missing" semantics,
    # as distinct from "invalid id" semantics (covered separately below).
    resp = client.get(f"/palaces/{OTHER_PALACE_ID}", headers=auth_headers())
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


def test_put_palace_id_mismatch_400(client):
    # Path id and body id are both well-formed UUIDs, just different from
    # each other -- exercises the mismatch check specifically, as distinct
    # from the id-format check (covered separately below).
    palace = _palace()
    resp = client.put(
        f"/palaces/{OTHER_PALACE_ID}", headers=auth_headers(), json=palace
    )
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"


def test_put_palace_missing_updated_at_400(client):
    palace = _palace()
    del palace["updatedAt"]
    resp = client.put(
        f"/palaces/{palace['id']}", headers=auth_headers(), json=palace
    )
    assert resp.status_code == 400
    assert resp.json()["error"]["code"] == "bad_request"


# ---------------------------------------------------------------------------
# palace_id validation (path-traversal hardening)
#
# HTTP-level cases below use "not-a-uuid" (a single path segment with no
# `.`/`/`) rather than a literal `../../etc/passwd`: httpx/Starlette's own
# URL normalization collapses dot-segments (and even percent-encoded
# slashes) before/while routing, so a traversal-shaped string never
# actually reaches our `{palace_id}` route as a value at all via this test
# client -- it 404s for an unrelated reason (no matching route, generic
# Starlette body) rather than exercising our validator. The unit tests
# just below call `palace_store.is_valid_palace_id` directly to prove the
# actual security property (rejecting `..`, `/etc/passwd`, etc.) without
# depending on any HTTP client's URL-normalization quirks.
# ---------------------------------------------------------------------------


def test_get_palace_invalid_id_404(client):
    resp = client.get("/palaces/not-a-uuid", headers=auth_headers())
    assert resp.status_code == 404
    assert resp.json()["error"] == {
        "code": "not_found",
        "message": "palace not found",
    }


def test_get_palace_photo_invalid_id_404(client):
    resp = client.get("/palaces/not-a-uuid/photo", headers=auth_headers())
    assert resp.status_code == 404
    assert resp.json()["error"] == {
        "code": "not_found",
        "message": "no photo for this palace",
    }


def test_put_palace_invalid_id_400(client):
    palace = _palace(palace_id="not-a-uuid")
    resp = client.put(
        "/palaces/not-a-uuid", headers=auth_headers(), json=palace
    )
    assert resp.status_code == 400
    assert resp.json()["error"] == {
        "code": "bad_request",
        "message": "malformed palace body",
    }


def test_put_palace_photo_invalid_id_400(client):
    resp = client.put(
        "/palaces/not-a-uuid/photo",
        headers={**auth_headers(), "Content-Type": "image/jpeg"},
        content=b"jpegbytes",
    )
    assert resp.status_code == 400
    assert resp.json()["error"] == {
        "code": "bad_request",
        "message": "malformed palace body",
    }


@pytest.mark.parametrize(
    "bad_id",
    [
        "",
        "not-a-uuid",
        "..",
        "../../etc/passwd",
        "/etc/passwd",
        "3F2504E0-4F89-11D3-9A0C-0305E82C330",  # one hex digit short
        "3F2504E0-4F89-11D3-9A0C-0305E82C33012",  # one hex digit long
    ],
)
def test_is_valid_palace_id_rejects_non_uuid(bad_id):
    assert palace_store.is_valid_palace_id(bad_id) is False


@pytest.mark.parametrize(
    "good_id",
    [
        "3F2504E0-4F89-11D3-9A0C-0305E82C3301",  # iOS uppercase-hyphenated
        "3f2504e0-4f89-11d3-9a0c-0305e82c3301",  # lowercase also accepted
    ],
)
def test_is_valid_palace_id_accepts_uuid(good_id):
    assert palace_store.is_valid_palace_id(good_id) is True


# ---------------------------------------------------------------------------
# Last-write-wins
# ---------------------------------------------------------------------------


def test_last_write_wins_stale_put_returns_stored(client):
    palace_id = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    newer = _palace(palace_id, updated_at="2026-07-02T14:03:11Z", name="Newer")
    older = _palace(palace_id, updated_at="2026-06-01T09:00:00Z", name="Older")

    resp1 = client.put(f"/palaces/{palace_id}", headers=auth_headers(), json=newer)
    assert resp1.status_code == 200
    assert resp1.json()["name"] == "Newer"

    resp2 = client.put(f"/palaces/{palace_id}", headers=auth_headers(), json=older)
    assert resp2.status_code == 200
    assert resp2.json()["name"] == "Newer"

    get_resp = client.get(f"/palaces/{palace_id}", headers=auth_headers())
    assert get_resp.json()["name"] == "Newer"


def test_last_write_wins_naive_updated_at_does_not_500(client):
    """A legacy/degenerate `updatedAt` with no `Z`/offset (e.g. hand-rolled
    or pre-contract data) must not 500 -- `_parse_updated_at` coerces naive
    input to UTC so `upsert_palace`'s comparison never raises `TypeError:
    can't compare offset-naive and offset-aware datetimes`. Covers both
    comparison directions: naive-then-aware and aware-then-naive."""
    naive_then_aware_id = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    naive_first = _palace(
        naive_then_aware_id, updated_at="2026-07-02T14:03:11", name="Naive"
    )
    aware_later = _palace(
        naive_then_aware_id, updated_at="2026-07-02T15:00:00Z", name="AwareLater"
    )
    resp1 = client.put(
        f"/palaces/{naive_then_aware_id}", headers=auth_headers(), json=naive_first
    )
    assert resp1.status_code == 200, resp1.text
    assert resp1.json()["name"] == "Naive"

    resp2 = client.put(
        f"/palaces/{naive_then_aware_id}", headers=auth_headers(), json=aware_later
    )
    assert resp2.status_code == 200, resp2.text
    assert resp2.json()["name"] == "AwareLater"

    get_resp = client.get(
        f"/palaces/{naive_then_aware_id}", headers=auth_headers()
    )
    assert get_resp.status_code == 200
    assert get_resp.json()["name"] == "AwareLater"

    aware_then_naive_id = OTHER_PALACE_ID
    aware_first = _palace(
        aware_then_naive_id, updated_at="2026-07-02T15:00:00Z", name="AwareFirst"
    )
    naive_stale = _palace(
        aware_then_naive_id, updated_at="2026-07-02T14:03:11", name="NaiveStale"
    )
    resp3 = client.put(
        f"/palaces/{aware_then_naive_id}", headers=auth_headers(), json=aware_first
    )
    assert resp3.status_code == 200, resp3.text

    resp4 = client.put(
        f"/palaces/{aware_then_naive_id}", headers=auth_headers(), json=naive_stale
    )
    assert resp4.status_code == 200, resp4.text
    assert resp4.json()["name"] == "AwareFirst"  # stale naive PUT discarded


# ---------------------------------------------------------------------------
# GET /palaces
# ---------------------------------------------------------------------------


def test_list_palaces_empty_namespace(client):
    resp = client.get("/palaces", headers=auth_headers())
    assert resp.status_code == 200
    assert resp.json() == {"palaces": []}


def test_list_palaces_summary_shape(client):
    palace = _palace()
    client.put(f"/palaces/{palace['id']}", headers=auth_headers(), json=palace)

    resp = client.get("/palaces", headers=auth_headers())
    assert resp.status_code == 200
    palaces = resp.json()["palaces"]
    assert len(palaces) == 1
    summary = palaces[0]
    assert summary["id"] == palace["id"]
    assert summary["name"] == palace["name"]
    assert summary["updatedAt"] == palace["updatedAt"]
    assert summary["lociCount"] == 1
    assert summary["hasPhoto"] is False
    assert summary["photoVersion"] is None


# ---------------------------------------------------------------------------
# Photo
# ---------------------------------------------------------------------------


def test_get_photo_404_before_any_palace_exists(client):
    # Well-formed UUID that was simply never PUT -- "missing" semantics.
    resp = client.get(f"/palaces/{OTHER_PALACE_ID}/photo", headers=auth_headers())
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


def test_photo_put_get_round_trip(client):
    palace = _palace()
    client.put(f"/palaces/{palace['id']}", headers=auth_headers(), json=palace)

    fake_jpeg = b"\xff\xd8\xff\xe0" + b"jpegdata" * 10
    put_resp = client.put(
        f"/palaces/{palace['id']}/photo",
        headers={**auth_headers(), "Content-Type": "image/jpeg"},
        content=fake_jpeg,
    )
    assert put_resp.status_code == 200, put_resp.text
    assert put_resp.json() == {"photoVersion": 1}

    get_resp = client.get(f"/palaces/{palace['id']}/photo", headers=auth_headers())
    assert get_resp.status_code == 200
    assert get_resp.content == fake_jpeg
    assert get_resp.headers["content-type"] == "image/jpeg"

    # Second upload bumps the version again.
    put_resp2 = client.put(
        f"/palaces/{palace['id']}/photo",
        headers={**auth_headers(), "Content-Type": "image/jpeg"},
        content=fake_jpeg,
    )
    assert put_resp2.json() == {"photoVersion": 2}


def test_photo_put_oversized_413(client):
    palace = _palace()
    client.put(f"/palaces/{palace['id']}", headers=auth_headers(), json=palace)

    oversized = b"x" * (5 * 1024 * 1024 + 1)
    resp = client.put(
        f"/palaces/{palace['id']}/photo",
        headers={**auth_headers(), "Content-Type": "image/jpeg"},
        content=oversized,
    )
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "payload_too_large"


def test_photo_put_oversized_content_length_413_before_buffering(client):
    """Contract requires rejecting via `Content-Length` *before* buffering
    the full body. Send a small real body with a spoofed large
    `Content-Length` header: a correct pre-check implementation 413s off
    the declared length alone; a buggy implementation that only checks
    `len(body)` post-read would see just 5 bytes and wrongly return 200."""
    palace = _palace()
    client.put(f"/palaces/{palace['id']}", headers=auth_headers(), json=palace)

    resp = client.put(
        f"/palaces/{palace['id']}/photo",
        headers={
            **auth_headers(),
            "Content-Type": "image/jpeg",
            "content-length": str(6 * 1024 * 1024),
        },
        content=b"small",
    )
    assert resp.status_code == 413, resp.text
    assert resp.json()["error"]["code"] == "payload_too_large"


def test_photo_put_wrong_content_type_415(client):
    palace = _palace()
    client.put(f"/palaces/{palace['id']}", headers=auth_headers(), json=palace)

    resp = client.put(
        f"/palaces/{palace['id']}/photo",
        headers={**auth_headers(), "Content-Type": "image/png"},
        content=b"not-a-jpeg",
    )
    assert resp.status_code == 415
    assert resp.json()["error"]["code"] == "unsupported_media_type"


def test_photo_put_unknown_palace_404(client):
    # Well-formed UUID that was simply never PUT via PUT /palaces/{id}.
    resp = client.put(
        f"/palaces/{OTHER_PALACE_ID}/photo",
        headers={**auth_headers(), "Content-Type": "image/jpeg"},
        content=b"jpegbytes",
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


def test_list_palaces_requires_auth(client):
    resp = client.get("/palaces")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"
