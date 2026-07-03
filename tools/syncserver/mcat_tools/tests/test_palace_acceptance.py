# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Acceptance-level tests for the Palace desktop-sync server endpoints, one
suite entry per acceptance criterion from `02-story.md` in the
2026-07-02-palace-desktop-sync factory run (see `contracts/api.md` /
`contracts/data-model.md` for the authoritative shapes this exercises).

This file is deliberately self-contained (it does not import fixtures/
helpers from `test_palace.py`, even though the two files overlap in setup
style) so it stands alone as the AC-level proof bundle. `test_palace.py`
already carries thorough endpoint-level smoke coverage (round-trips,
id-validation, one auth check, photo size/type limits, etc.) -- this file
instead frames its tests by acceptance criterion and fills the specific
gaps that suite doesn't cover: `X-Mcat-User` namespace isolation (AC4/AC5),
auth-401 enforcement across *all* 5 routes (AC11), and the PUT 400
contract's "schema-invalid fields" clause specifically. Some overlap with
`test_palace.py` (e.g. a basic PUT/GET round-trip, the tz-naive
last-write-wins regression) is intentional: those scenarios map directly
onto AC1/AC2/AC6 and belong in an AC-framed acceptance suite even though
the underlying behavior is already smoke-tested elsewhere.

Run with:
    python3 -m pytest tools/syncserver/mcat_tools/tests/test_palace_acceptance.py -v
(from `tools/syncserver/`, or with that dir on PYTHONPATH; requires the
mcat_tools sidecar deps from `requirements-mcat-tools.txt`, which are NOT
part of the main `out/pyenv`.)
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from mcat_tools import palace_store

TOKEN = "test-token-123"


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


def user_headers(user: str | None = None, token: str = TOKEN) -> dict:
    """Auth headers plus an optional `X-Mcat-User` namespace header (AC4/AC5)."""
    headers = {"X-Mcat-Token": token}
    if user is not None:
        headers["X-Mcat-User"] = user
    return headers


def _palace(
    palace_id: str = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
    updated_at: str = "2026-07-02T14:03:11Z",
    name: str = "My Kitchen",
) -> dict:
    """A minimal-but-complete valid `Palace` body per `contracts/data-model.md`."""
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
# AC1 / AC2 -- iOS pushes palace metadata+loci; reconciliation re-push of an
# already-synced palace is idempotent (no duplication/corruption).
# ---------------------------------------------------------------------------


def test_ac1_ac2_push_round_trip_and_idempotent_repeat_push(client):
    """AC1: pushing a palace's metadata+loci stores it and it reads back
    identically. AC2: iOS also re-pushes every local palace at launch
    (reconciliation) -- pushing the *identical* body again must still
    succeed and must not create a second/duplicate record for the same id."""
    palace = _palace()

    put_resp = client.put(
        f"/palaces/{palace['id']}", headers=auth_headers(), json=palace
    )
    assert put_resp.status_code == 200, put_resp.text
    assert put_resp.json() == palace

    get_resp = client.get(f"/palaces/{palace['id']}", headers=auth_headers())
    assert get_resp.status_code == 200
    assert get_resp.json() == palace

    # Reconciliation replay: identical body, same id, pushed again.
    repeat_resp = client.put(
        f"/palaces/{palace['id']}", headers=auth_headers(), json=palace
    )
    assert repeat_resp.status_code == 200, repeat_resp.text
    assert repeat_resp.json() == palace

    list_resp = client.get("/palaces", headers=auth_headers())
    assert list_resp.status_code == 200
    matching = [p for p in list_resp.json()["palaces"] if p["id"] == palace["id"]]
    assert len(matching) == 1, f"expected exactly one entry, got {matching}"


# ---------------------------------------------------------------------------
# AC1 -- the reference photo is also pushed and round-trips.
# ---------------------------------------------------------------------------


def test_ac1_photo_push_round_trip(client):
    """AC1: the palace push includes the reference photo, not just
    metadata/loci -- PUT then GET must return byte-identical JPEG content
    with the correct content-type."""
    palace = _palace()
    put_palace_resp = client.put(
        f"/palaces/{palace['id']}", headers=auth_headers(), json=palace
    )
    assert put_palace_resp.status_code == 200, put_palace_resp.text

    fake_jpeg = b"\xff\xd8\xff\xe0" + b"jpegdata" * 20
    put_photo_resp = client.put(
        f"/palaces/{palace['id']}/photo",
        headers={**auth_headers(), "Content-Type": "image/jpeg"},
        content=fake_jpeg,
    )
    assert put_photo_resp.status_code == 200, put_photo_resp.text
    assert put_photo_resp.json() == {"photoVersion": 1}

    get_photo_resp = client.get(
        f"/palaces/{palace['id']}/photo", headers=auth_headers()
    )
    assert get_photo_resp.status_code == 200
    assert get_photo_resp.content == fake_jpeg
    assert get_photo_resp.headers["content-type"] == "image/jpeg"


# ---------------------------------------------------------------------------
# AC4 / AC5 -- server persists + serves palaces namespaced by X-Mcat-User.
# This is the highest-value gap: no test anywhere else exercises
# X-Mcat-User at all. Proves the on-disk/storage key is (user_key,
# palace_id), not just palace_id.
# ---------------------------------------------------------------------------

PALACE_X_ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
PALACE_Y_ID = "11111111-1111-1111-1111-111111111111"


def test_ac4_ac5_namespace_isolation_by_x_mcat_user(client):
    """AC4: the server persists each palace namespaced by the syncing
    user's `X-Mcat-User` value. AC5: list/detail endpoints only ever
    surface the caller's own namespace. Uses the SAME palace id (`X`) under
    two different `X-Mcat-User` values to prove the storage key is
    `(user_key, palace_id)`, not `palace_id` alone -- a collision here
    would silently corrupt one user's data with another's."""
    palace_x_alice = _palace(PALACE_X_ID, name="Alice's Kitchen")
    palace_y_bob = _palace(PALACE_Y_ID, name="Bob's Office")
    palace_x_bob = _palace(PALACE_X_ID, name="Bob's X")

    put_x_alice = client.put(
        f"/palaces/{PALACE_X_ID}",
        headers=user_headers("alice"),
        json=palace_x_alice,
    )
    assert put_x_alice.status_code == 200, put_x_alice.text

    put_y_bob = client.put(
        f"/palaces/{PALACE_Y_ID}", headers=user_headers("bob"), json=palace_y_bob
    )
    assert put_y_bob.status_code == 200, put_y_bob.text

    # Same id (X) as alice's, but under bob's namespace with a different
    # name -- must land as a wholly independent record, not overwrite (or
    # be rejected as a conflict with) alice's copy.
    put_x_bob = client.put(
        f"/palaces/{PALACE_X_ID}", headers=user_headers("bob"), json=palace_x_bob
    )
    assert put_x_bob.status_code == 200, put_x_bob.text

    # alice's list: only her own X, unaffected by bob's later write to the
    # same id under his own namespace.
    list_alice = client.get("/palaces", headers=user_headers("alice"))
    assert list_alice.status_code == 200
    alice_palaces = list_alice.json()["palaces"]
    assert {p["id"] for p in alice_palaces} == {PALACE_X_ID}
    assert alice_palaces[0]["name"] == "Alice's Kitchen"

    # bob's list: both of his palaces (X and Y, order-independent), with
    # HIS OWN copy of X's name -- neither clobbered by, nor leaking, alice's.
    list_bob = client.get("/palaces", headers=user_headers("bob"))
    assert list_bob.status_code == 200
    bob_palaces = list_bob.json()["palaces"]
    assert {p["id"] for p in bob_palaces} == {PALACE_X_ID, PALACE_Y_ID}
    bob_x_summary = next(p for p in bob_palaces if p["id"] == PALACE_X_ID)
    assert bob_x_summary["name"] == "Bob's X"

    # Detail-fetch isolation mirrors the list isolation.
    get_x_as_alice = client.get(
        f"/palaces/{PALACE_X_ID}", headers=user_headers("alice")
    )
    assert get_x_as_alice.status_code == 200
    assert get_x_as_alice.json()["name"] == "Alice's Kitchen"

    get_x_as_bob = client.get(f"/palaces/{PALACE_X_ID}", headers=user_headers("bob"))
    assert get_x_as_bob.status_code == 200
    assert get_x_as_bob.json()["name"] == "Bob's X"

    # bob's palace Y is completely invisible to alice, even though they
    # share the same X-Mcat-Token -- namespace isolation holds even though
    # the underlying auth boundary (the token) is shared between them.
    get_y_as_alice = client.get(
        f"/palaces/{PALACE_Y_ID}", headers=user_headers("alice")
    )
    assert get_y_as_alice.status_code == 404

    # A namespace that never pushed anything gets a clean empty list, not
    # an error (list-endpoint contract / AC7 edge case).
    list_charlie = client.get("/palaces", headers=user_headers("charlie"))
    assert list_charlie.status_code == 200
    assert list_charlie.json() == {"palaces": []}


# ---------------------------------------------------------------------------
# AC6 -- last-write-wins by updatedAt.
# ---------------------------------------------------------------------------


def test_ac6_last_write_wins_newer_then_older_stale_put_discarded(client):
    """AC6: when a palace with the same id already exists, the server keeps
    whichever version has the newer `updatedAt` and discards the older one.
    Covers the story's own edge case of two rapid iOS saves racing to push
    (the stale one must be discarded cleanly, not error, not overwrite)."""
    palace_id = "9B2D0000-0000-0000-0000-0000000000AA"
    newer = _palace(palace_id, updated_at="2026-07-02T14:03:11Z", name="Newer")
    older = _palace(palace_id, updated_at="2026-06-01T09:00:00Z", name="Older")

    put_newer = client.put(f"/palaces/{palace_id}", headers=auth_headers(), json=newer)
    assert put_newer.status_code == 200, put_newer.text
    assert put_newer.json()["name"] == "Newer"

    # The stale PUT must not error, and must hand back the STORED (newer)
    # palace rather than the older one just sent -- callers use the
    # returned updatedAt to detect who won.
    put_older = client.put(f"/palaces/{palace_id}", headers=auth_headers(), json=older)
    assert put_older.status_code == 200, put_older.text
    assert put_older.json()["name"] == "Newer"
    assert put_older.json() == put_newer.json()

    get_resp = client.get(f"/palaces/{palace_id}", headers=auth_headers())
    assert get_resp.status_code == 200
    assert get_resp.json()["name"] == "Newer"


def test_ac6_last_write_wins_naive_vs_aware_updated_at_never_500(client):
    """AC6 tz-handling regression (fixed by backend in round 2): a tz-naive
    `updatedAt` (no `Z`/offset -- legacy/hand-rolled data) compared against
    a tz-aware one must never 500 the request in EITHER arrival order, and
    the tz-aware/newer value must always be the one that survives."""
    naive_then_aware_id = "C0FFEE00-0000-0000-0000-000000000001"
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

    resp2 = client.put(
        f"/palaces/{naive_then_aware_id}", headers=auth_headers(), json=aware_later
    )
    assert resp2.status_code == 200, resp2.text
    assert resp2.json()["name"] == "AwareLater"

    get_resp = client.get(f"/palaces/{naive_then_aware_id}", headers=auth_headers())
    assert get_resp.status_code == 200
    assert get_resp.json()["name"] == "AwareLater"

    # Reverse order: aware/newer arrives first, then a stale naive PUT.
    aware_then_naive_id = "C0FFEE00-0000-0000-0000-000000000002"
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

    get_resp2 = client.get(f"/palaces/{aware_then_naive_id}", headers=auth_headers())
    assert get_resp2.status_code == 200
    assert get_resp2.json()["name"] == "AwareFirst"


# ---------------------------------------------------------------------------
# AC11 (server side) -- every palace route requires a valid X-Mcat-Token.
# test_palace.py only checks this for GET /palaces; this covers all 5.
# ---------------------------------------------------------------------------

AUTH_TEST_ID = "DEADBEEF-0000-0000-0000-000000000001"

ALL_PALACE_ROUTES = [
    ("GET", "/palaces"),
    ("GET", f"/palaces/{AUTH_TEST_ID}"),
    ("PUT", f"/palaces/{AUTH_TEST_ID}"),
    ("GET", f"/palaces/{AUTH_TEST_ID}/photo"),
    ("PUT", f"/palaces/{AUTH_TEST_ID}/photo"),
]

_UNAUTHORIZED_BODY = {
    "error": {
        "code": "unauthorized",
        "message": "missing or invalid X-Mcat-Token",
    }
}


def _hit_route(client, method: str, path: str, headers: dict):
    """Performs `method path` with the given headers. PUT routes get a
    minimal well-formed payload, but its validity is irrelevant to these
    auth tests: `require_token` is a FastAPI `Depends` that runs (and, in
    these tests, fails) before the route body ever parses the request."""
    if method == "GET":
        return client.get(path, headers=headers)
    if path.endswith("/photo"):
        return client.put(
            path,
            headers={**headers, "Content-Type": "image/jpeg"},
            content=b"jpegbytes",
        )
    return client.put(path, headers=headers, json=_palace(AUTH_TEST_ID))


@pytest.mark.parametrize("method,path", ALL_PALACE_ROUTES)
def test_ac11_missing_token_401_on_every_palace_route(client, method, path):
    resp = _hit_route(client, method, path, headers={})
    assert resp.status_code == 401, resp.text
    assert resp.json() == _UNAUTHORIZED_BODY


@pytest.mark.parametrize("method,path", ALL_PALACE_ROUTES)
def test_ac11_wrong_token_401_on_every_palace_route(client, method, path):
    resp = _hit_route(client, method, path, headers=auth_headers("wrong-token"))
    assert resp.status_code == 401, resp.text
    assert resp.json() == _UNAUTHORIZED_BODY


# ---------------------------------------------------------------------------
# Contract gap -- PUT /palaces/{id}'s 400 clause covers "missing/mismatched
# id, missing updatedAt, OR schema-invalid fields" (contracts/api.md). The
# existing suite covers the first two; this covers the third distinctly.
# ---------------------------------------------------------------------------


def test_put_palace_schema_invalid_locus_missing_point_400(client):
    """A locus missing its required `point` field ENTIRELY (the key is
    absent, not merely null/empty) is schema-invalid per
    `contracts/data-model.md` (`point` is a required, non-optional field on
    `Locus`) and must be rejected with 400 bad_request -- not 500, and not
    silently accepted and stored in a shape desktop can't render pins from."""
    palace = _palace()
    del palace["loci"][0]["point"]

    resp = client.put(f"/palaces/{palace['id']}", headers=auth_headers(), json=palace)
    assert resp.status_code == 400, resp.text
    body = resp.json()
    assert body["error"]["code"] == "bad_request"
    assert isinstance(body["error"]["message"], str) and body["error"]["message"]


# ---------------------------------------------------------------------------
# Security regression, consolidated at the acceptance level: a
# `../../etc/passwd`-shaped id must never 500 any of the 4 id-taking routes.
# ---------------------------------------------------------------------------

TRAVERSAL_ID = "../../etc/passwd"


@pytest.mark.parametrize(
    "method,path",
    [
        ("GET", f"/palaces/{TRAVERSAL_ID}"),
        ("GET", f"/palaces/{TRAVERSAL_ID}/photo"),
        ("PUT", f"/palaces/{TRAVERSAL_ID}"),
        ("PUT", f"/palaces/{TRAVERSAL_ID}/photo"),
    ],
)
def test_security_traversal_shaped_id_never_500s(client, method, path):
    """A `../../etc/passwd`-shaped id must never crash the server (500) or
    succeed (200) on any of the 4 id-taking routes.

    Empirically verified against this exact FastAPI/Starlette/httpx
    TestClient stack (see worker progress log): httpx's URL class resolves
    `..` segments client-side before the request is ever sent, so the
    traversal string never survives as a literal single `{palace_id}` path
    segment at all -- the resolved request targets a path entirely outside
    `/palaces/*`, and Starlette's router returns its own generic 404 for
    every method here (GET *and* PUT alike), without our route function --
    and therefore without our own `is_valid_palace_id` guard -- ever
    running. This test locks in that observed-safe outcome (never 500,
    never 200) at the HTTP boundary. `test_is_valid_palace_id_rejects_
    traversal_string_directly` below is what actually proves OUR validator
    rejects this exact string, independent of any HTTP client's
    URL-normalization behavior -- matching the precedent `test_palace.py`
    already established for `not-a-uuid`."""
    if method == "GET":
        resp = client.get(path, headers=auth_headers())
    elif path.endswith("/photo"):
        resp = client.put(
            path,
            headers={**auth_headers(), "Content-Type": "image/jpeg"},
            content=b"jpegbytes",
        )
    else:
        resp = client.put(path, headers=auth_headers(), json=_palace())

    assert resp.status_code != 500, resp.text
    assert resp.status_code == 404, (
        f"expected the traversal-shaped id to miss routing entirely "
        f"(generic 404) for {method} {path}, got {resp.status_code}: "
        f"{resp.text}"
    )


def test_is_valid_palace_id_rejects_traversal_string_directly():
    """The decisive security-property proof, independent of any HTTP
    client's URL-normalization quirks: `is_valid_palace_id` rejects the raw
    traversal string itself. (`test_palace.py`'s own
    `test_is_valid_palace_id_rejects_non_uuid` already parametrizes over
    this exact string too; this acceptance-level copy exists so this file
    stands on its own as the AC/security proof bundle without depending on
    that one.)"""
    assert palace_store.is_valid_palace_id("../../etc/passwd") is False
