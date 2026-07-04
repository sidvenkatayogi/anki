"""Keyword-overlap baseline grader — the "simpler method" the AI must beat.

This is a **real**, fully local, deterministic grader (stdlib only, no network,
no randomness). It marks a student answer correct iff it shares at least half of
the expected answer's *content* keywords (stopwords removed, light stemming).

It exists so the eval can show the LLM grader beats a cheap heuristic. It is
deliberately naive — it has no notion of meaning, opposites, or misconceptions —
so it should FAIL the pre-registered cutoff (that is the whole point).
"""

from __future__ import annotations

import re

# A reasonable set of English stopwords. Kept intentionally middle-of-the-road:
# broad enough to strip filler, narrow enough to leave real content words.
STOPWORDS: set[str] = {
    "a", "an", "the", "and", "or", "but", "if", "then", "than", "so", "such",
    "of", "to", "in", "on", "at", "by", "for", "with", "from", "into", "onto",
    "as", "is", "are", "was", "were", "be", "been", "being", "am",
    "it", "its", "that", "this", "these", "those", "there", "here",
    "they", "them", "their", "he", "she", "him", "her", "his", "we", "us", "our",
    "i", "you", "your", "me", "my", "mine",
    "what", "which", "who", "whom", "whose", "when", "where", "why", "how",
    "does", "do", "did", "done", "doing",
    "has", "have", "had", "having",
    "not", "no", "nor", "only", "just", "also",
    "can", "could", "will", "would", "shall", "should", "may", "might", "must",
    "about", "over", "under", "between", "through", "during", "per", "via",
    "some", "any", "each", "both", "either", "neither", "other", "another",
    "up", "down", "out", "off", "again",
}

# Suffixes stripped by the light stemmer, longest-first so "es" beats "s" and
# "ing" beats "ed" on ambiguous endings.
_SUFFIXES = ("ing", "ed", "es", "s")

# Everything that is NOT a latin letter, digit, or apostrophe is a separator.
# We deliberately keep apostrophes so the "'s" possessive strip in the stemmer
# is meaningful (per the documented algorithm); the stemmer removes them after.
_TOKEN_SPLIT_RE = re.compile(r"[^a-z0-9']+")


def _stem(token: str) -> str:
    """Light, deterministic stemmer (no external stemming libraries)."""
    if token.endswith("'s"):
        token = token[:-2]
    token = token.replace("'", "")
    for suffix in _SUFFIXES:
        if token.endswith(suffix) and len(token) - len(suffix) >= 3:
            return token[: -len(suffix)]
    return token


def content_keywords(text: str) -> set[str]:
    """Lowercase, de-punctuate, drop stopwords/short tokens, light-stem.

    Returns the set of content keywords. Order-independent and deterministic.
    """
    text = (text or "").lower()
    keywords: set[str] = set()
    for token in _TOKEN_SPLIT_RE.split(text):
        if len(token) < 2:
            continue
        if token in STOPWORDS:
            continue
        stem = _stem(token)
        if len(stem) < 2:
            continue
        keywords.add(stem)
    return keywords


def grade(expected: str, provided: str) -> bool:
    """Return True iff ``provided`` covers >= 50% of ``expected``'s keywords."""
    expected_kw = content_keywords(expected)
    provided_stripped = (provided or "").strip()

    # Edge case: the expected answer has no content keywords at all. There is
    # nothing to overlap against, so fall back to "did the student write
    # anything?" — empty -> False, otherwise -> True.
    if not expected_kw:
        return bool(provided_stripped)

    # A blank/whitespace answer can never satisfy a non-empty expected answer.
    if not provided_stripped:
        return False

    overlap = expected_kw & content_keywords(provided)
    return (len(overlap) / len(expected_kw)) >= 0.5
