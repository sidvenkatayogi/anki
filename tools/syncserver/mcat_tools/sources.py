# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""Passage source fetchers: Wikipedia REST, NewsAPI, Project Gutenberg.

Each fetcher returns a dict `{"title": str, "text": str, "url": str}` with
`text` trimmed/expanded to roughly 300-600 words, or raises `SourceError` on
failure. `fetch_passage(source, topic)` implements the fallback chain when
`source` is None.
"""

from __future__ import annotations

import os
import random
import re
from typing import Optional

import httpx

MIN_WORDS = 300
MAX_WORDS = 600

FALLBACK_ORDER = ("wikipedia", "news", "gutenberg")

# A small set of classic, public-domain Project Gutenberg texts to sample
# from when no topic-specific search is available/needed.
_GUTENBERG_BOOK_IDS = [1342, 11, 84, 1661, 76, 2701, 174, 98]


class SourceError(Exception):
    """Raised when a given source fails to produce a usable passage."""


def _clip_to_word_range(
    text: str, min_words: int = MIN_WORDS, max_words: int = MAX_WORDS
) -> str:
    words = text.split()
    if len(words) > max_words:
        words = words[:max_words]
    return " ".join(words)


def _word_count(text: str) -> int:
    return len(text.split())


def fetch_wikipedia(
    topic: Optional[str] = None, client: Optional[httpx.Client] = None
) -> dict:
    """Fetch a passage from Wikipedia's REST API. If `topic` is given, search
    for a matching article; otherwise use the random-article endpoint."""
    owns_client = client is None
    client = client or httpx.Client(timeout=10.0)
    try:
        title = topic
        if topic:
            search_resp = client.get(
                "https://en.wikipedia.org/w/api.php",
                params={
                    "action": "query",
                    "list": "search",
                    "srsearch": topic,
                    "format": "json",
                    "srlimit": 1,
                },
                headers={"User-Agent": "mcat-tools/1.0"},
            )
            search_resp.raise_for_status()
            results = search_resp.json().get("query", {}).get("search", [])
            if not results:
                raise SourceError(f"wikipedia: no search results for topic {topic!r}")
            title = results[0]["title"]

        if title:
            summary_resp = client.get(
                f"https://en.wikipedia.org/api/rest_v1/page/summary/{title}",
                headers={"User-Agent": "mcat-tools/1.0"},
            )
        else:
            summary_resp = client.get(
                "https://en.wikipedia.org/api/rest_v1/page/random/summary",
                headers={"User-Agent": "mcat-tools/1.0"},
            )
        summary_resp.raise_for_status()
        data = summary_resp.json()

        page_title = data.get("title", "")
        extract = data.get("extract", "")
        url = (
            data.get("content_urls", {})
            .get("desktop", {})
            .get("page", f"https://en.wikipedia.org/wiki/{page_title}")
        )

        if _word_count(extract) < 50:
            # Summary extracts are often short; fall through to full extract
            # if available via the plain-text extract endpoint.
            full_resp = client.get(
                "https://en.wikipedia.org/w/api.php",
                params={
                    "action": "query",
                    "prop": "extracts",
                    "explaintext": 1,
                    "titles": page_title,
                    "format": "json",
                },
                headers={"User-Agent": "mcat-tools/1.0"},
            )
            full_resp.raise_for_status()
            pages = full_resp.json().get("query", {}).get("pages", {})
            for page in pages.values():
                candidate = page.get("extract", "")
                if _word_count(candidate) > _word_count(extract):
                    extract = candidate

        if _word_count(extract) < MIN_WORDS:
            raise SourceError(
                f"wikipedia: passage too short ({_word_count(extract)} words) for {page_title!r}"
            )

        text = _clip_to_word_range(extract)
        return {"title": page_title, "text": text, "url": url}
    except httpx.HTTPError as exc:
        raise SourceError(f"wikipedia: request failed ({exc})") from exc
    finally:
        if owns_client:
            client.close()


def fetch_news(
    topic: Optional[str] = None, client: Optional[httpx.Client] = None
) -> dict:
    """Fetch a passage from NewsAPI. Requires NEWS_API_KEY env var."""
    api_key = os.environ.get("NEWS_API_KEY")
    if not api_key:
        raise SourceError("news: NEWS_API_KEY not configured")

    owns_client = client is None
    client = client or httpx.Client(timeout=10.0)
    try:
        params = {
            "apiKey": api_key,
            "language": "en",
            "pageSize": 5,
        }
        if topic:
            params["q"] = topic
            url = "https://newsapi.org/v2/everything"
        else:
            params["category"] = "science"
            params["country"] = "us"
            url = "https://newsapi.org/v2/top-headlines"

        resp = client.get(url, params=params)
        resp.raise_for_status()
        data = resp.json()
        articles = data.get("articles", [])
        if not articles:
            raise SourceError("news: no articles returned")

        for article in articles:
            content = article.get("content") or article.get("description") or ""
            content = re.sub(r"\[\+\d+ chars\]$", "", content).strip()
            if _word_count(content) == 0:
                continue
            # NewsAPI content is often truncated; pad with description if
            # needed. Same 300-word floor as the other sources (wikipedia/
            # gutenberg) — an article that can't meet it is treated as
            # unavailable, not returned, so the fallback chain moves on.
            combined = content
            if _word_count(combined) < MIN_WORDS and article.get("description"):
                combined = f"{article['description']} {content}".strip()
            if _word_count(combined) >= MIN_WORDS:
                return {
                    "title": article.get("title", "Untitled"),
                    "text": _clip_to_word_range(combined),
                    "url": article.get("url", ""),
                }
        raise SourceError("news: no article met minimum content length")
    except httpx.HTTPError as exc:
        raise SourceError(f"news: request failed ({exc})") from exc
    finally:
        if owns_client:
            client.close()


def fetch_gutenberg(
    topic: Optional[str] = None, client: Optional[httpx.Client] = None
) -> dict:
    """Fetch a passage excerpt from Project Gutenberg (plain text mirror)."""
    owns_client = client is None
    client = client or httpx.Client(timeout=15.0, follow_redirects=True)
    try:
        book_id = random.choice(_GUTENBERG_BOOK_IDS)
        url = f"https://www.gutenberg.org/files/{book_id}/{book_id}-0.txt"
        resp = client.get(url)
        if resp.status_code != 200:
            url = f"https://www.gutenberg.org/cache/epub/{book_id}/pg{book_id}.txt"
            resp = client.get(url)
        resp.raise_for_status()
        raw = resp.text

        # Strip Gutenberg header/footer boilerplate.
        start_marker = re.search(
            r"\*\*\*\s*START OF (THE|THIS) PROJECT GUTENBERG.*?\*\*\*", raw
        )
        end_marker = re.search(
            r"\*\*\*\s*END OF (THE|THIS) PROJECT GUTENBERG.*?\*\*\*", raw
        )
        body = raw[
            start_marker.end() if start_marker else 0 : end_marker.start()
            if end_marker
            else None
        ]
        body = re.sub(r"\s+", " ", body).strip()

        words = body.split()
        if len(words) < MIN_WORDS + 200:
            raise SourceError(f"gutenberg: book {book_id} too short after trimming")

        # Pick a chunk somewhere in the middle of the book to avoid
        # front-matter/table-of-contents noise.
        start_idx = random.randint(len(words) // 4, (3 * len(words)) // 4)
        chunk = words[start_idx : start_idx + MAX_WORDS]
        text = " ".join(chunk)
        if _word_count(text) < MIN_WORDS:
            raise SourceError("gutenberg: extracted chunk too short")

        return {
            "title": f"Project Gutenberg #{book_id}",
            "text": text,
            "url": url,
        }
    except httpx.HTTPError as exc:
        raise SourceError(f"gutenberg: request failed ({exc})") from exc
    finally:
        if owns_client:
            client.close()


_FETCHERS = {
    "wikipedia": fetch_wikipedia,
    "news": fetch_news,
    "gutenberg": fetch_gutenberg,
}


def fetch_passage(source: Optional[str], topic: Optional[str]) -> dict:
    """Resolve a passage using `source` (forced tier) or the fallback chain
    wikipedia -> news -> gutenberg. Returns
    `{"source": name, "title", "text", "url"}`.

    Raises SourceError naming the last-tried source if all attempted
    sources fail.
    """
    if source:
        fetcher = _FETCHERS[source]
        result = fetcher(topic)
        return {"source": source, **result}

    last_error: Optional[Exception] = None
    last_source = FALLBACK_ORDER[-1]
    for name in FALLBACK_ORDER:
        last_source = name
        try:
            result = _FETCHERS[name](topic)
            return {"source": name, **result}
        except SourceError as exc:
            last_error = exc
            continue

    raise SourceError(f"all sources failed, last tried: {last_source} ({last_error})")
