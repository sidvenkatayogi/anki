# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Loads the canonical practice-seed question bank.

Loads the committed seed file at `mcat_tools/data/practice-seed.json`
(shipped inside this package -- the Dockerfile's `COPY mcat_tools/` picks it
up automatically, no separate build step needed). This is a byte-identical
copy of the database-domain-authored contract artifact at
`.factory/runs/2026-07-02-read-practice-tabs/contracts/practice-seed.json`;
that `.factory/` path is git-ignored/run-scratch and is NEVER read at
runtime -- production code must not depend on it. If the committed file is
missing, `load_seed_questions()` returns None so the route can degrade
gracefully to a 404 rather than crashing.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

SEED_PATH = Path(__file__).resolve().parent / "data" / "practice-seed.json"


def load_seed_questions(seed_path: Optional[Path] = None) -> Optional[list]:
    """Returns the parsed list of seed questions, or None if the seed file
    does not exist. Raises no exception on missing file (caller 404s)."""
    path = seed_path or SEED_PATH
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)
