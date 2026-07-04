# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

"""Two-way sync integration test (Friday deliverable + challenge 7b).

Proves the phone<->desktop sync guarantee WITHOUT any phone: both the desktop
app and the iOS companion embed the *same* Rust core and sync the whole
collection over Anki's native sync, so exercising two headless `Collection`
clients against a real in-process sync server is exactly the desktop<->iOS
path (same code, same protocol).

What it proves (challenge 7b):

1.  Seed a server from client A, adopt it on client B (first-login download).
2.  Go "offline" and review 10 DISTINCT cards on A and 10 DIFFERENT cards on B.
3.  Reconnect and sync. All 20 reviews land in one place with **none lost and
    none double-counted** (revlog has exactly 20 rows, one per reviewed card,
    on both clients).
4.  Conflict: review the SAME card on both clients while offline, then sync.
    The append-only review log keeps **both** reviews (nothing is lost), and the
    card's *scheduling state* is resolved by Anki's rule:

        **Conflict rule (last-writer-wins by modification time).** A card is a
        single row; on merge the client whose card was modified later wins. The
        review log is append-only, so no review is dropped or double-counted.
        We make client B review last (later mtime), so B deterministically wins.

The in-process server is `python -m anki.syncserver` (the same server shipped
by `just sync-server` / `tools/syncserver`), started on a random free port with
`SYNC_USER1=mcat:mcat`.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

from anki import sync_pb2
from anki.collection import Collection
from tests.shared import getEmptyCol

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_CR = sync_pb2.SyncCollectionResponse  # ChangesRequired enum lives here
USER = "mcat"
PASS = "mcat"


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _wait_healthy(port: int, proc: subprocess.Popen, timeout: float = 40.0) -> None:
    url = f"http://127.0.0.1:{port}/health"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(
                f"sync server exited early (code {proc.returncode}). See stderr above."
            )
        try:
            with urllib.request.urlopen(url, timeout=1) as resp:
                if resp.status == 200:
                    return
        except (urllib.error.URLError, ConnectionError, OSError):
            time.sleep(0.25)
    raise RuntimeError("sync server did not become healthy in time")


@pytest.fixture
def sync_endpoint(tmp_path):
    """Start the fork's real sync server in-process on a random port."""
    port = _free_port()
    env = os.environ.copy()
    # Absolute PYTHONPATH so the child finds `anki` regardless of cwd.
    pp = os.path.join(REPO_ROOT, "out", "pylib")
    env["PYTHONPATH"] = pp + os.pathsep + env.get("PYTHONPATH", "")
    env["SYNC_USER1"] = f"{USER}:{PASS}"
    env["SYNC_HOST"] = "127.0.0.1"
    env["SYNC_PORT"] = str(port)
    env["SYNC_BASE"] = str(tmp_path / "server")
    env["RUST_LOG"] = "anki=error"
    os.makedirs(env["SYNC_BASE"], exist_ok=True)

    proc = subprocess.Popen(
        [sys.executable, "-m", "anki.syncserver"],
        env=env,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        _wait_healthy(port, proc)
        yield f"http://127.0.0.1:{port}/"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


# --- helpers ---------------------------------------------------------------


def _add_cards(col: Collection, n: int) -> None:
    for i in range(n):
        note = col.newNote()
        note["Front"] = f"Q{i}: what is fact #{i}?"
        note["Back"] = f"A{i}: the answer to fact #{i}"
        col.addNote(note)


def _card_ids(col: Collection) -> list[int]:
    return col.db.list("select id from cards order by id")


def _revlog_count(col: Collection) -> int:
    return col.db.scalar("select count() from revlog")


def _revlog_by_card(col: Collection) -> dict[int, int]:
    return dict(col.db.all("select cid, count() from revlog group by cid"))


def _login(col: Collection, endpoint: str):
    return col.sync_login(USER, PASS, endpoint)


def _full_upload(col: Collection, auth) -> None:
    col.close_for_full_sync()
    col.full_upload_or_download(auth=auth, server_usn=None, upload=True)
    col.reopen(after_full_sync=True)


def _full_download(col: Collection, auth) -> None:
    col.close_for_full_sync()
    col.full_upload_or_download(auth=auth, server_usn=None, upload=False)
    col.reopen(after_full_sync=True)


def _normal_sync(col: Collection, auth) -> None:
    """Run a normal (incremental) sync to completion.

    `sync_collection` performs the incremental round-trip and reports whether a
    full sync is still required. After the initial seed/adopt there should never
    be a full sync here, but we guard anyway and cap the loop.
    """
    for _ in range(5):
        out = col.sync_collection(auth, False)
        req = out.required
        if req in (_CR.NO_CHANGES, _CR.NORMAL_SYNC):
            return
        if req == _CR.FULL_DOWNLOAD:
            _full_download(col, auth)
        else:  # FULL_UPLOAD / FULL_SYNC
            _full_upload(col, auth)
    raise RuntimeError("normal sync did not converge")


def _review_specific(col: Collection, cids: list[int], ease: int) -> None:
    """Review each given card (by id) with `ease`, regardless of queue order."""
    for cid in cids:
        card = col.get_card(cid)
        card.start_timer()
        col.sched.answerCard(card, ease)


def _sched_fingerprint(col: Collection, cid: int) -> tuple:
    """Scheduling-relevant fields of a card (excludes usn, which sync bumps)."""
    c = col.get_card(cid)
    return (c.type, c.queue, c.due, c.ivl, c.factor, c.reps, c.lapses, c.mod)


# --- the test --------------------------------------------------------------


def test_two_way_sync_no_loss_no_double_count_and_conflict_rule(sync_endpoint):
    endpoint = sync_endpoint
    colA = getEmptyCol()
    colB = getEmptyCol()
    try:
        # Phase 1 -- seed the server from A (server starts empty -> full upload).
        _add_cards(colA, 25)
        authA = _login(colA, endpoint)
        _full_upload(colA, authA)

        # Phase 2 -- B adopts the server's collection (first-login download).
        authB = _login(colB, endpoint)
        _full_download(colB, authB)

        cids_a = _card_ids(colA)
        cids_b = _card_ids(colB)
        assert cids_a == cids_b, "clients must share identical card ids after sync"
        assert len(cids_a) == 25
        cids = cids_a

        # settle both clients to a clean, in-sync baseline
        _normal_sync(colA, authA)
        _normal_sync(colB, authB)
        assert _revlog_count(colA) == 0
        assert _revlog_count(colB) == 0

        # Phase 3 -- OFFLINE: 10 distinct cards on A, 10 DIFFERENT cards on B.
        # revlog ids are millisecond timestamps; two clients reviewing within
        # the same ms would mint colliding ids that merge would de-duplicate.
        # Real phone/desktop reviews are seconds apart, so we separate the two
        # batches in time to model that (and keep ids globally unique).
        a_set = cids[0:10]
        b_set = cids[10:20]
        assert not (set(a_set) & set(b_set))
        _review_specific(colA, a_set, 3)  # Good
        time.sleep(0.5)
        _review_specific(colB, b_set, 3)  # Good
        assert _revlog_count(colA) == 10
        assert _revlog_count(colB) == 10

        # Phase 4 -- reconnect and sync both ways (A -> server -> B -> server -> A)
        _normal_sync(colA, authA)
        _normal_sync(colB, authB)
        _normal_sync(colA, authA)

        # Phase 5 -- nothing lost, nothing double-counted.
        assert _revlog_count(colA) == 20, "all 20 reviews must be present on A"
        assert _revlog_count(colB) == 20, "all 20 reviews must be present on B"
        reviewed = set(a_set) | set(b_set)
        per_card_a = _revlog_by_card(colA)
        per_card_b = _revlog_by_card(colB)
        assert set(per_card_a) == reviewed
        assert set(per_card_b) == reviewed
        # exactly one review per card => none double-counted
        assert all(v == 1 for v in per_card_a.values())
        assert all(v == 1 for v in per_card_b.values())

        # Phase 6 -- CONFLICT: same card reviewed on both clients while offline.
        conflict_cid = cids[20]

        # A reviews it "Again" (ease 1). B reviews it "Easy" (ease 4) slightly
        # later, so B has the later modification time and must win the merge.
        _review_specific(colA, [conflict_cid], 1)
        a_fp = _sched_fingerprint(colA, conflict_cid)
        time.sleep(1.1)  # ensure B's card.mod (second resolution) is strictly later
        _review_specific(colB, [conflict_cid], 4)
        b_fp = _sched_fingerprint(colB, conflict_cid)
        assert a_fp != b_fp, "Again vs Easy must produce different card states"

        # Sync A first (pushes A's state), then B last (B wins), then A pulls B.
        _normal_sync(colA, authA)
        _normal_sync(colB, authB)
        _normal_sync(colA, authA)

        # Review log is append-only: BOTH reviews of the conflict card survive.
        assert _revlog_count(colA) == 22
        assert _revlog_count(colB) == 22
        assert _revlog_by_card(colA)[conflict_cid] == 2
        assert _revlog_by_card(colB)[conflict_cid] == 2

        # Conflict rule: last writer (B, "Easy") wins; both clients converge to
        # B's card state and NOT A's.
        final_a = _sched_fingerprint(colA, conflict_cid)
        final_b = _sched_fingerprint(colB, conflict_cid)
        assert final_a == final_b, "clients must converge to one winning state"
        assert final_a == b_fp, "the later writer (B, Easy) must win the merge"
        assert final_a != a_fp, "the earlier writer (A, Again) must not win"
    finally:
        colA.close()
        colB.close()
