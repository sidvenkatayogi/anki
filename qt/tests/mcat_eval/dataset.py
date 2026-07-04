"""Loader for the held-out grader evaluation set.

The dataset (``grader_eval_set.json``) is the *real*, hand-curated held-out set
described in README.md. This module only reads it; it performs no grading and
has no network or third-party dependencies (stdlib only).
"""

from __future__ import annotations

import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_DATASET_PATH = os.path.join(_HERE, "grader_eval_set.json")


def _load_json() -> dict:
    with open(_DATASET_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def load_records() -> list[dict]:
    """Return the list of evaluation records (each a dict, see README)."""
    return _load_json()["records"]


def load_meta() -> dict:
    """Return the dataset's ``_provenance`` block (honest provenance notes)."""
    return _load_json()["_provenance"]
