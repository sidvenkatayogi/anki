# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""FastAPI app exposing the Read/Practice-tab HTTP endpoints.

Routes (see `contracts/api.md` in the 2026-07-02-read-practice-tabs factory
run for the authoritative shapes):
    GET  /health
    GET  /version
    GET  /read/passage
    GET  /practice/questions
    POST /metrics/compute

Run standalone (from `tools/syncserver/`):
    MCAT_TOOLS_TOKEN=... OPENAI_API_KEY=... uvicorn mcat_tools.app:app --host 0.0.0.0 --port 8081

See `mcat_tools/README.md` for full env var docs.
"""

from __future__ import annotations

import logging
import subprocess
import uuid
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from mcat_tools import metrics
from mcat_tools.auth import require_token
from mcat_tools.llm import LlmConfigError, LlmError, generate_quiz
from mcat_tools.practice_seed import load_seed_questions
from mcat_tools.schemas import MetricsComputeRequest
from mcat_tools.sources import SourceError, fetch_passage

logger = logging.getLogger("mcat_tools")

app = FastAPI(title="mcat-tools")

# CORS approach: bare `Access-Control-Allow-Origin: *` on these routes
# (simplest, no mediasrv-proxy frontend coordination needed this round --
# see api.md "CORS" section, both options are contract-acceptable).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


def _error(code: str, message: str) -> dict:
    return {"error": {"code": code, "message": message}}


@app.exception_handler(HTTPException)
async def http_exception_handler(_: Request, exc: HTTPException) -> JSONResponse:
    """Ensures the response body is exactly the error envelope
    `{"error": {"code", "message"}}` -- not FastAPI's default
    `{"detail": ...}` wrapper -- for any HTTPException whose `detail` is
    already in that shape. Falls back to wrapping plain string details."""
    detail = exc.detail
    if isinstance(detail, dict) and "error" in detail:
        content = detail
    else:
        content = _error("internal", str(detail))
    return JSONResponse(status_code=exc.status_code, content=content)


@app.exception_handler(Exception)
async def unhandled_exception_handler(_: Request, exc: Exception) -> JSONResponse:
    # Log the real exception server-side only -- never echo raw exception
    # text into the client-visible error envelope (could leak internals).
    logger.exception("unhandled exception in mcat-tools request")
    return JSONResponse(status_code=500, content=_error("internal", "internal error"))


def _resolve_build() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            check=False,
            cwd=Path(__file__).resolve().parent,
            capture_output=True,
            text=True,
            timeout=3,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass
    return "unknown-build"


_BUILD = _resolve_build()


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/version")
async def version() -> dict:
    return {"version": "1.0.0", "build": _BUILD}


VALID_SOURCES = ("wikipedia", "news", "gutenberg")


@app.get("/read/passage", dependencies=[Depends(require_token)])
async def read_passage(
    source: Optional[str] = None, topic: Optional[str] = None
) -> dict:
    if source is not None and source not in VALID_SOURCES:
        raise HTTPException(
            status_code=400,
            detail=_error(
                "bad_request",
                f"invalid source {source!r}, expected one of {VALID_SOURCES}",
            ),
        )

    try:
        passage = fetch_passage(source, topic)
    except SourceError as exc:
        raise HTTPException(
            status_code=502, detail=_error("upstream_unavailable", str(exc))
        ) from exc

    try:
        quiz = generate_quiz(passage["text"], passage["title"])
    except LlmConfigError as exc:
        raise HTTPException(
            status_code=502,
            detail=_error("upstream_unavailable", f"llm not configured: {exc}"),
        ) from exc
    except LlmError as exc:
        raise HTTPException(
            status_code=502, detail=_error("llm_malformed", str(exc))
        ) from exc

    return {
        "passage_id": str(uuid.uuid4()),
        "source": passage["source"],
        "title": passage["title"],
        "text": passage["text"],
        "url": passage["url"],
        "quiz": quiz,
    }


@app.get("/practice/questions", dependencies=[Depends(require_token)])
async def practice_questions() -> dict:
    questions = load_seed_questions()
    if questions is None:
        raise HTTPException(
            status_code=404,
            detail=_error("not_found", "seed bank not yet available"),
        )
    return {"questions": questions}


@app.post("/metrics/compute", dependencies=[Depends(require_token)])
async def metrics_compute(request: Request) -> dict:
    try:
        body = await request.json()
        parsed = MetricsComputeRequest.model_validate(body)
    except Exception as exc:
        # Log the real validation error server-side; never echo raw
        # exception text (e.g. pydantic internals) into the client envelope.
        logger.info("malformed /metrics/compute body: %s", exc)
        raise HTTPException(
            status_code=400, detail=_error("bad_request", "malformed request body")
        ) from exc

    practice_history = [item.model_dump() for item in parsed.practice_history]
    fsrs = parsed.fsrs.model_dump()

    performance = metrics.compute_performance(practice_history)
    readiness = metrics.compute_readiness(performance, fsrs)

    return {"performance": performance, "readiness": readiness}
