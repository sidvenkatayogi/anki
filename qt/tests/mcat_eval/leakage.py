"""Leakage check (challenge 7e) — real, stdlib only, no network.

Proves mechanically that no held-out item leaked into the grader's prompt or
its (zero) few-shot examples. We build the "grader corpus" from
``qt/aqt/llm_grade.py`` — its ``_SYSTEM_PROMPT`` plus every string literal in
the source (belt-and-suspenders in case examples are added later) — and check
each record's ``student_answer`` and ``question`` against it two ways:

* **exact**: normalized substring containment, and
* **near-duplicate**: max Jaccard over 5-gram character shingles >= 0.6.

A clean dataset yields ``exact_overlaps == 0`` and ``near_dup_overlaps == 0``.
"""

from __future__ import annotations

import ast
import importlib.util
import os
import re
import string

_HERE = os.path.dirname(os.path.abspath(__file__))
# mcat_eval -> tests -> qt -> <repo root>
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(_HERE)))
_LLM_GRADE_PATH = os.path.join(REPO_ROOT, "qt", "aqt", "llm_grade.py")

_WHITESPACE_RE = re.compile(r"\s+")
# Map punctuation to spaces (rather than deleting) so token boundaries survive.
_PUNCT_TO_SPACE = {ord(ch): " " for ch in string.punctuation}

NEAR_DUP_THRESHOLD = 0.6
NGRAM_SIZE = 5


def _load_llm_grade_module():
    spec = importlib.util.spec_from_file_location("mcat_llm_grade_leak", _LLM_GRADE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _string_literals_from_source(path: str) -> list[str]:
    """Return every string-constant literal in the given Python source file."""
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read())
    literals: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            literals.append(node.value)
    return literals


def grader_corpus() -> list[str]:
    """Build the grader corpus: the system prompt + all source string literals."""
    module = _load_llm_grade_module()
    texts: list[str] = []
    system_prompt = getattr(module, "_SYSTEM_PROMPT", None)
    if isinstance(system_prompt, str):
        texts.append(system_prompt)
    texts.extend(_string_literals_from_source(_LLM_GRADE_PATH))
    return texts


def normalize(s: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace."""
    s = (s or "").lower()
    s = s.translate(_PUNCT_TO_SPACE)
    return _WHITESPACE_RE.sub(" ", s).strip()


def char_ngrams(s: str, n: int = NGRAM_SIZE) -> set[str]:
    """Set of character n-gram shingles over the normalized string."""
    s = normalize(s)
    if not s:
        return set()
    if len(s) < n:
        return {s}
    return {s[i : i + n] for i in range(len(s) - n + 1)}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    union = len(a | b)
    return len(a & b) / union if union else 0.0


def scan(records: list[dict], corpus_texts: list[str]) -> dict:
    """Scan every record against the corpus for exact + near-duplicate overlap."""
    normalized_corpus = [normalize(text) for text in corpus_texts]
    corpus_ngrams = [char_ngrams(text) for text in corpus_texts]

    exact_overlaps = 0
    near_dup_overlaps = 0
    max_jaccard = 0.0
    flagged: list[str] = []

    for rec in records:
        fields = [rec.get("student_answer", ""), rec.get("question", "")]
        rec_exact = False
        rec_near = False
        for field in fields:
            normalized_field = normalize(field)
            if normalized_field:
                for normalized_text in normalized_corpus:
                    if normalized_text and normalized_field in normalized_text:
                        rec_exact = True
                        break
            field_ngrams = char_ngrams(field)
            for text_ngrams in corpus_ngrams:
                similarity = jaccard(field_ngrams, text_ngrams)
                if similarity > max_jaccard:
                    max_jaccard = similarity
                if similarity >= NEAR_DUP_THRESHOLD:
                    rec_near = True
        if rec_exact:
            exact_overlaps += 1
        if rec_near:
            near_dup_overlaps += 1
        if rec_exact or rec_near:
            flagged.append(rec["id"])

    return {
        "exact_overlaps": exact_overlaps,
        "near_dup_overlaps": near_dup_overlaps,
        "max_jaccard": max_jaccard,
        "flagged": flagged,
    }
