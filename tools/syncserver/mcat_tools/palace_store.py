# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""File-based store for Palace desktop-sync (see `contracts/data-model.md`'s
"Server on-disk layout" in the 2026-07-02-palace-desktop-sync factory run).

Layout:
    <root>/<userKey>/<palaceId>/palace.json
    <root>/<userKey>/<palaceId>/photo.jpg

`<root>` defaults to `mcat_tools/data/palaces/` (mirrors `practice_seed.py`'s
`Path(__file__).resolve().parent / "data"` pattern) but is re-read from the
`MCAT_TOOLS_PALACE_DIR` env var on every call (not cached at import time) so
tests can monkeypatch it per-test.

The server is a dumb blob store -- it never interprets `Palace`/`Locus`
fields beyond `id` and `updatedAt`.
"""

from __future__ import annotations

import json
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

_DEFAULT_ROOT = Path(__file__).resolve().parent / "data" / "palaces"

_USER_KEY_RE = re.compile(r"[^A-Za-z0-9_-]")
_MAX_USER_KEY_LEN = 64


def _root() -> Path:
    override = os.environ.get("MCAT_TOOLS_PALACE_DIR")
    if override:
        return Path(override)
    return _DEFAULT_ROOT


def sanitize_user_key(raw: Optional[str]) -> str:
    """Strips any character outside `[A-Za-z0-9_-]`, caps length at 64, and
    falls back to `"default"` if the result is empty. Traversal-safe: `.`
    and `/` are always stripped, so the result can never escape the user's
    namespace directory."""
    if not raw:
        return "default"
    cleaned = _USER_KEY_RE.sub("", raw)[:_MAX_USER_KEY_LEN]
    return cleaned or "default"


def is_valid_palace_id(value: object) -> bool:
    """True iff `value` is a syntactically valid UUID (any case/format
    variant Python's stdlib `uuid.UUID` accepts). iOS always sends
    uppercase-hyphenated `UUID().uuidString`, but we're liberal in what we
    accept here rather than enforcing a specific casing.

    This is what makes `palace_id` traversal-safe before it ever reaches
    `_palace_dir`/`_palace_json_path`/`_photo_path`: `../`, `/`, absolute
    paths, and the empty string are not valid UUIDs, so none of them parse
    -- the same role `sanitize_user_key` plays for `user_key`, just via
    rejection instead of stripping (an `id` is a value, not a namespace
    caller-chosen for stability, so there is nothing sane to normalize it
    to)."""
    if not isinstance(value, str) or not value:
        return False
    try:
        uuid.UUID(value)
    except (ValueError, AttributeError, TypeError):
        return False
    return True


def _user_dir(user_key: str) -> Path:
    return _root() / sanitize_user_key(user_key)


def _palace_dir(user_key: str, palace_id: str) -> Path:
    return _user_dir(user_key) / palace_id


def _palace_json_path(user_key: str, palace_id: str) -> Path:
    return _palace_dir(user_key, palace_id) / "palace.json"


def _photo_path(user_key: str, palace_id: str) -> Path:
    return _palace_dir(user_key, palace_id) / "photo.jpg"


def _parse_updated_at(value: object) -> datetime:
    if not isinstance(value, str) or not value:
        raise ValueError("missing or empty updatedAt")
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"malformed updatedAt: {value!r}") from exc
    if dt.tzinfo is None:
        # Legacy/degenerate input with no `Z` suffix and no other offset.
        # Contract-conformant inputs always carry `Z`, but coerce naive
        # datetimes to UTC so `upsert_palace`'s `>=` comparison never
        # raises `TypeError: can't compare offset-naive and offset-aware
        # datetimes` when comparing against an aware stored/incoming value.
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def list_summaries(user_key: str) -> list:
    """Returns `[{id, name, updatedAt, lociCount, hasPhoto, photoVersion}]`
    for every palace under this user's namespace. Empty/missing dir -> []."""
    user_dir = _user_dir(user_key)
    if not user_dir.exists():
        return []

    summaries = []
    for entry in sorted(user_dir.iterdir()):
        if not entry.is_dir():
            continue
        palace_json = entry / "palace.json"
        if not palace_json.exists():
            continue
        try:
            with palace_json.open("r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        summaries.append(
            {
                "id": data.get("id", entry.name),
                "name": data.get("name", ""),
                "updatedAt": data.get("updatedAt", ""),
                "lociCount": len(data.get("loci") or []),
                "hasPhoto": (entry / "photo.jpg").exists(),
                "photoVersion": data.get("photoVersion"),
            }
        )
    return summaries


def get_palace(user_key: str, palace_id: str) -> Optional[dict]:
    """Returns the parsed palace.json dict, or None if missing."""
    path = _palace_json_path(user_key, palace_id)
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def upsert_palace(user_key: str, palace_id: str, incoming: dict) -> dict:
    """Last-write-wins by `updatedAt` (UTC-aware datetime compare). If a
    stored copy exists and its `updatedAt` is >= incoming's, returns the
    stored dict unchanged (no disk write). Otherwise writes incoming to disk
    and returns it. Raises ValueError on malformed/missing `updatedAt`
    (caller should map to 400)."""
    incoming_ts = _parse_updated_at(incoming.get("updatedAt"))

    existing = get_palace(user_key, palace_id)
    if existing is not None:
        existing_ts = _parse_updated_at(existing.get("updatedAt"))
        if existing_ts >= incoming_ts:
            return existing

    path = _palace_json_path(user_key, palace_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(incoming, f)
    return incoming


def get_photo(user_key: str, palace_id: str) -> Optional[bytes]:
    """Returns the raw JPEG bytes, or None if missing/no palace."""
    path = _photo_path(user_key, palace_id)
    if not path.exists():
        return None
    with path.open("rb") as f:
        return f.read()


def put_photo(user_key: str, palace_id: str, data: bytes) -> Optional[int]:
    """Writes photo.jpg and returns the new server-authoritative
    photoVersion (bumped from the palace.json `photoVersion` field, default
    0), persisting the bump back into palace.json. Returns None (route
    should 404) if the palace doesn't exist yet."""
    palace = get_palace(user_key, palace_id)
    if palace is None:
        return None

    new_version = (palace.get("photoVersion") or 0) + 1

    photo_path = _photo_path(user_key, palace_id)
    photo_path.parent.mkdir(parents=True, exist_ok=True)
    with photo_path.open("wb") as f:
        f.write(data)

    palace["photoVersion"] = new_version
    palace_path = _palace_json_path(user_key, palace_id)
    with palace_path.open("w", encoding="utf-8") as f:
        json.dump(palace, f)

    return new_version
