# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Edge-case tests for `mcat_tools.sources` not already covered by test_app.py:

1. Passage-length clamping/rejection: does `fetch_wikipedia`/`fetch_gutenberg`
   actually produce text in [MIN_WORDS, MAX_WORDS] when the raw upstream
   response is much longer or much shorter than that range?
2. Source-variety / fallback order (AC5): does `fetch_passage(None, None)`
   walk Wikipedia -> news -> Gutenberg in order when earlier tiers fail?

All network calls are mocked at the `httpx.Client` boundary (an explicit
`client=` object is injected into each fetcher, which is a real parameter
these functions already accept) -- no real Wikipedia/News/Gutenberg traffic.
Run with:
    python3 -m pytest tools/syncserver/mcat_tools/tests/test_read_passage_edge_cases.py -v
(from `tools/syncserver/`, or with that dir on PYTHONPATH).
"""

from __future__ import annotations

from unittest import mock

import pytest

from mcat_tools import sources
from mcat_tools.sources import (
    MAX_WORDS,
    MIN_WORDS,
    SourceError,
    fetch_gutenberg,
    fetch_passage,
    fetch_wikipedia,
)


def _fake_response(json_data=None, text=None, status_code=200):
    """A minimal stand-in for httpx.Response covering the surface these
    fetchers use: .status_code, .raise_for_status(), .json(), .text"""
    resp = mock.Mock()
    resp.status_code = status_code
    resp.text = text if text is not None else ""
    if json_data is not None:
        resp.json.return_value = json_data
    if status_code >= 400:
        resp.raise_for_status.side_effect = sources.httpx.HTTPStatusError(
            "boom", request=mock.Mock(), response=resp
        )
    else:
        resp.raise_for_status.return_value = None
    return resp


class _FakeClient:
    """Stand-in for httpx.Client whose `.get()` is driven by a callable so
    each test can script per-URL responses without touching real network."""

    def __init__(self, get_fn):
        self._get_fn = get_fn
        self.closed = False

    def get(self, url, **kwargs):
        return self._get_fn(url, **kwargs)

    def close(self):
        self.closed = True


# ---------------------------------------------------------------------------
# 1. Passage-length clamping: raw content much longer than MAX_WORDS
# ---------------------------------------------------------------------------


def test_fetch_wikipedia_clips_long_extract_into_word_range():
    """A raw Wikipedia extract far longer than MAX_WORDS must be clipped so
    the final `text` lands within [MIN_WORDS, MAX_WORDS] (contract: 300-600
    words), never returned raw/unclipped."""
    long_extract = " ".join(f"word{i}" for i in range(2000))  # way over MAX_WORDS

    def _get(url, **kwargs):
        # No `topic` passed -> only the random-summary endpoint is hit.
        assert "random/summary" in url
        return _fake_response(
            json_data={
                "title": "Long Article",
                "extract": long_extract,
                "content_urls": {
                    "desktop": {"page": "https://en.wikipedia.org/wiki/Long_Article"}
                },
            }
        )

    client = _FakeClient(_get)
    result = fetch_wikipedia(topic=None, client=client)

    word_count = len(result["text"].split())
    assert MIN_WORDS <= word_count <= MAX_WORDS, (
        f"expected clipped text within [{MIN_WORDS}, {MAX_WORDS}] words, got {word_count}"
    )
    # It really was truncated, not just coincidentally in range.
    assert word_count < 2000


# ---------------------------------------------------------------------------
# 2. Passage-length rejection: raw content much shorter than MIN_WORDS
# ---------------------------------------------------------------------------


def test_fetch_wikipedia_rejects_too_short_extract_with_clear_error():
    """A raw extract (and its full-extract fallback) far shorter than
    MIN_WORDS must raise SourceError with a clear diagnostic, never be
    silently padded or returned under-length."""
    short_extract = " ".join(
        f"word{i}" for i in range(20)
    )  # well under 50 and MIN_WORDS

    def _get(url, **kwargs):
        if "random/summary" in url:
            return _fake_response(
                json_data={
                    "title": "Short Article",
                    "extract": short_extract,
                    "content_urls": {
                        "desktop": {
                            "page": "https://en.wikipedia.org/wiki/Short_Article"
                        }
                    },
                }
            )
        if (
            "action" in kwargs.get("params", {})
            and kwargs["params"]["action"] == "query"
        ):
            # Full-extract fallback triggered because the summary was < 50
            # words; simulate it returning something equally short.
            return _fake_response(
                json_data={
                    "query": {
                        "pages": {
                            "1": {"extract": short_extract},
                        }
                    }
                }
            )
        raise AssertionError(f"unexpected URL requested: {url}")

    client = _FakeClient(_get)
    with pytest.raises(SourceError) as excinfo:
        fetch_wikipedia(topic=None, client=client)

    # Clear, diagnosable reason -- names the source and mentions "short".
    assert "wikipedia" in str(excinfo.value)
    assert "short" in str(excinfo.value)


def test_fetch_gutenberg_clips_long_book_into_word_range(monkeypatch):
    """A very long raw Gutenberg book text, once boilerplate-stripped, should
    yield a chunk within [MIN_WORDS, MAX_WORDS], not an oversized excerpt."""
    monkeypatch.setattr(sources.random, "choice", lambda seq: seq[0])
    monkeypatch.setattr(sources.random, "randint", lambda a, b: a)

    body_words = 5000
    raw = (
        "*** START OF THE PROJECT GUTENBERG EBOOK TEST ***\n"
        + " ".join(f"word{i}" for i in range(body_words))
        + "\n*** END OF THE PROJECT GUTENBERG EBOOK TEST ***"
    )

    def _get(url, **kwargs):
        return _fake_response(text=raw, status_code=200)

    client = _FakeClient(_get)
    result = fetch_gutenberg(topic=None, client=client)

    word_count = len(result["text"].split())
    assert MIN_WORDS <= word_count <= MAX_WORDS, (
        f"expected clipped text within [{MIN_WORDS}, {MAX_WORDS}] words, got {word_count}"
    )


def test_fetch_gutenberg_rejects_too_short_book(monkeypatch):
    """A raw book that is short even after boilerplate stripping (well under
    MIN_WORDS + 200) must raise SourceError, not return an under-length
    passage."""
    monkeypatch.setattr(sources.random, "choice", lambda seq: seq[0])

    raw = (
        "*** START OF THE PROJECT GUTENBERG EBOOK TEST ***\n"
        + " ".join(f"word{i}" for i in range(50))
        + "\n*** END OF THE PROJECT GUTENBERG EBOOK TEST ***"
    )

    def _get(url, **kwargs):
        return _fake_response(text=raw, status_code=200)

    client = _FakeClient(_get)
    with pytest.raises(SourceError) as excinfo:
        fetch_gutenberg(topic=None, client=client)
    assert "gutenberg" in str(excinfo.value)


# ---------------------------------------------------------------------------
# FIXED (round 2): fetch_news now enforces the same MIN_WORDS floor as
# fetch_wikipedia/fetch_gutenberg. An article whose combined content+
# description is still under MIN_WORDS (300) is skipped rather than
# returned, so the fallback chain moves on to the next tier -- matching the
# 300-600 word contract in contracts/api.md.
# ---------------------------------------------------------------------------


def test_fetch_news_rejects_article_under_min_words(monkeypatch):
    """A single too-short article (content + description both short) must not
    be returned -- fetch_news should raise SourceError so the fallback chain
    treats this tier as unavailable, same as wikipedia/gutenberg do."""
    monkeypatch.setenv("NEWS_API_KEY", "fake-key")

    short_content = " ".join(
        f"word{i}" for i in range(80)
    )  # >= 50, well under MIN_WORDS (300)

    def _get(url, **kwargs):
        return _fake_response(
            json_data={
                "articles": [
                    {
                        "title": "Short News Item",
                        "content": short_content,
                        "url": "https://example.com/short",
                        "description": "",
                    }
                ]
            }
        )

    client = _FakeClient(_get)
    with pytest.raises(SourceError) as excinfo:
        sources.fetch_news(topic=None, client=client)
    assert "news" in str(excinfo.value)


def test_fetch_news_accepts_article_meeting_min_words(monkeypatch):
    """An article whose content meets MIN_WORDS is still returned normally,
    clipped to MAX_WORDS like the other sources."""
    monkeypatch.setenv("NEWS_API_KEY", "fake-key")

    long_content = " ".join(
        f"word{i}" for i in range(400)
    )  # within [MIN_WORDS, MAX_WORDS]

    def _get(url, **kwargs):
        return _fake_response(
            json_data={
                "articles": [
                    {
                        "title": "Long News Item",
                        "content": long_content,
                        "url": "https://example.com/long",
                        "description": "",
                    }
                ]
            }
        )

    client = _FakeClient(_get)
    result = sources.fetch_news(topic=None, client=client)
    word_count = len(result["text"].split())
    assert MIN_WORDS <= word_count <= MAX_WORDS


def test_fetch_news_falls_through_short_article_to_a_longer_one(monkeypatch):
    """If the first article is too short but a later one meets MIN_WORDS,
    fetch_news should skip the short one and return the usable article."""
    monkeypatch.setenv("NEWS_API_KEY", "fake-key")

    short_content = " ".join(f"word{i}" for i in range(80))
    long_content = " ".join(f"word{i}" for i in range(350))

    def _get(url, **kwargs):
        return _fake_response(
            json_data={
                "articles": [
                    {
                        "title": "Short",
                        "content": short_content,
                        "url": "https://example.com/short",
                        "description": "",
                    },
                    {
                        "title": "Long Enough",
                        "content": long_content,
                        "url": "https://example.com/long",
                        "description": "",
                    },
                ]
            }
        )

    client = _FakeClient(_get)
    result = sources.fetch_news(topic=None, client=client)
    assert result["title"] == "Long Enough"
    word_count = len(result["text"].split())
    assert MIN_WORDS <= word_count <= MAX_WORDS


def test_fetch_news_all_articles_too_short_raises(monkeypatch):
    """If every returned article is under MIN_WORDS, fetch_news must raise
    SourceError (tier unavailable), matching the fallback chain's contract
    that all-sources-too-short still yields 502 upstream_unavailable end to
    end (see test_read_passage_all_sources_down / test_app.py)."""
    monkeypatch.setenv("NEWS_API_KEY", "fake-key")

    short_content = " ".join(f"word{i}" for i in range(40))

    def _get(url, **kwargs):
        return _fake_response(
            json_data={
                "articles": [
                    {
                        "title": "A",
                        "content": short_content,
                        "url": "https://example.com/a",
                        "description": "",
                    },
                    {
                        "title": "B",
                        "content": short_content,
                        "url": "https://example.com/b",
                        "description": "",
                    },
                ]
            }
        )

    client = _FakeClient(_get)
    with pytest.raises(SourceError) as excinfo:
        sources.fetch_news(topic=None, client=client)
    assert "news" in str(excinfo.value)


# ---------------------------------------------------------------------------
# 3. Source variety / fallback order (AC5): Wikipedia -> news -> Gutenberg
# ---------------------------------------------------------------------------


def test_fetch_passage_falls_back_through_documented_order(monkeypatch):
    """When source=None and Wikipedia + news both fail, fetch_passage must
    fall through to Gutenberg and report source="gutenberg" -- proving the
    fallback chain actually walks tiers in the documented order rather than
    stopping early or picking a random tier."""

    def _wiki_fails(topic):
        raise SourceError("wikipedia: request failed (simulated)")

    def _news_fails(topic):
        raise SourceError("news: NEWS_API_KEY not configured")

    def _gutenberg_succeeds(topic):
        return {
            "title": "Project Gutenberg #1342",
            "text": " ".join(["word"] * 400),
            "url": "https://www.gutenberg.org/files/1342/1342-0.txt",
        }

    monkeypatch.setitem(sources._FETCHERS, "wikipedia", _wiki_fails)
    monkeypatch.setitem(sources._FETCHERS, "news", _news_fails)
    monkeypatch.setitem(sources._FETCHERS, "gutenberg", _gutenberg_succeeds)

    result = fetch_passage(None, None)
    assert result["source"] == "gutenberg"
    assert result["title"] == "Project Gutenberg #1342"


def test_fetch_passage_stops_at_first_successful_tier(monkeypatch):
    """If Wikipedia succeeds, fetch_passage must not fall through to news or
    Gutenberg at all (proves ordering AND short-circuiting, not just that
    Gutenberg is reachable)."""
    calls = {"news": 0, "gutenberg": 0}

    def _wiki_succeeds(topic):
        return {
            "title": "Wiki Title",
            "text": " ".join(["word"] * 350),
            "url": "https://en.wikipedia.org/wiki/X",
        }

    def _news_should_not_be_called(topic):
        calls["news"] += 1
        raise SourceError("should not be reached")

    def _gutenberg_should_not_be_called(topic):
        calls["gutenberg"] += 1
        raise SourceError("should not be reached")

    monkeypatch.setitem(sources._FETCHERS, "wikipedia", _wiki_succeeds)
    monkeypatch.setitem(sources._FETCHERS, "news", _news_should_not_be_called)
    monkeypatch.setitem(sources._FETCHERS, "gutenberg", _gutenberg_should_not_be_called)

    result = fetch_passage(None, None)
    assert result["source"] == "wikipedia"
    assert calls == {"news": 0, "gutenberg": 0}


def test_fetch_passage_all_tiers_down_raises_naming_last_tried(monkeypatch):
    """All three tiers failing should raise SourceError naming gutenberg (the
    last-tried tier) -- already implicitly covered by test_app.py's
    all-sources-down test via a mocked `fetch_passage`, but this exercises
    the real fallback loop in sources.py directly."""

    def _fail(name):
        def _inner(topic):
            raise SourceError(f"{name}: simulated failure")

        return _inner

    monkeypatch.setitem(sources._FETCHERS, "wikipedia", _fail("wikipedia"))
    monkeypatch.setitem(sources._FETCHERS, "news", _fail("news"))
    monkeypatch.setitem(sources._FETCHERS, "gutenberg", _fail("gutenberg"))

    with pytest.raises(SourceError) as excinfo:
        fetch_passage(None, None)
    assert "gutenberg" in str(excinfo.value)
