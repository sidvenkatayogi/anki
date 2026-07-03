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

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response

from mcat_tools import metrics, palace_store
from mcat_tools.auth import require_token
from mcat_tools.llm import LlmConfigError, LlmError, generate_quiz
from mcat_tools.practice_seed import load_seed_questions
from mcat_tools.schemas import MetricsComputeRequest, Palace
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
    allow_methods=["GET", "POST", "PUT", "OPTIONS"],
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


# ---------------------------------------------------------------------------
# Palace desktop-sync (2026-07-02-palace-desktop-sync factory run).
# See `contracts/api.md` / `contracts/data-model.md` in that run for the
# authoritative shapes. Server is a dumb blob store keyed by
# `X-Mcat-User` (optional, defaults to "default", sanitized).
# ---------------------------------------------------------------------------

_MAX_PHOTO_BYTES = 5 * 1024 * 1024


def _resolve_user_key(x_mcat_user: Optional[str]) -> str:
    return palace_store.sanitize_user_key(x_mcat_user)


def _require_valid_palace_id_or_404(palace_id: str, message: str) -> None:
    """`palace_id` is guaranteed (per `contracts/data-model.md`) to be a
    UUID string. Reject anything else with the same 404 body the route
    already raises for a legitimately-missing-but-valid id, so a caller
    can't distinguish "invalid id" from "missing palace" -- and, more
    importantly, so a malformed id (e.g. `../../etc/passwd`) never reaches
    `palace_store`'s filesystem-path helpers."""
    if not palace_store.is_valid_palace_id(palace_id):
        raise HTTPException(status_code=404, detail=_error("not_found", message))


def _require_valid_palace_id_or_400(palace_id: str) -> None:
    """Same validation as `_require_valid_palace_id_or_404`, but for the PUT
    routes, where `id` is part of the request's body contract -- an invalid
    path id is reported the same way as any other malformed-body 400."""
    if not palace_store.is_valid_palace_id(palace_id):
        raise HTTPException(
            status_code=400, detail=_error("bad_request", "malformed palace body")
        )


@app.get("/palaces", dependencies=[Depends(require_token)])
async def list_palaces(x_mcat_user: Optional[str] = Header(default=None)) -> dict:
    user_key = _resolve_user_key(x_mcat_user)
    return {"palaces": palace_store.list_summaries(user_key)}


@app.get("/palaces/{palace_id}", dependencies=[Depends(require_token)])
async def get_palace(
    palace_id: str, x_mcat_user: Optional[str] = Header(default=None)
) -> dict:
    _require_valid_palace_id_or_404(palace_id, "palace not found")
    user_key = _resolve_user_key(x_mcat_user)
    palace = palace_store.get_palace(user_key, palace_id)
    if palace is None:
        raise HTTPException(
            status_code=404, detail=_error("not_found", "palace not found")
        )
    return palace


@app.put("/palaces/{palace_id}", dependencies=[Depends(require_token)])
async def put_palace(
    palace_id: str,
    request: Request,
    x_mcat_user: Optional[str] = Header(default=None),
) -> dict:
    _require_valid_palace_id_or_400(palace_id)
    user_key = _resolve_user_key(x_mcat_user)
    try:
        body = await request.json()
        Palace.model_validate(body)
    except Exception as exc:
        logger.info("malformed PUT /palaces/%s body: %s", palace_id, exc)
        raise HTTPException(
            status_code=400, detail=_error("bad_request", "malformed palace body")
        ) from exc

    if not isinstance(body, dict) or body.get("id") != palace_id:
        raise HTTPException(
            status_code=400, detail=_error("bad_request", "malformed palace body")
        )
    if not body.get("updatedAt"):
        raise HTTPException(
            status_code=400, detail=_error("bad_request", "malformed palace body")
        )

    try:
        winner = palace_store.upsert_palace(user_key, palace_id, body)
    except ValueError as exc:
        logger.info("malformed updatedAt for palace %s: %s", palace_id, exc)
        raise HTTPException(
            status_code=400, detail=_error("bad_request", "malformed palace body")
        ) from exc

    return winner


@app.get("/palaces/{palace_id}/photo", dependencies=[Depends(require_token)])
async def get_palace_photo(
    palace_id: str, x_mcat_user: Optional[str] = Header(default=None)
) -> Response:
    _require_valid_palace_id_or_404(palace_id, "no photo for this palace")
    user_key = _resolve_user_key(x_mcat_user)
    data = palace_store.get_photo(user_key, palace_id)
    if data is None:
        raise HTTPException(
            status_code=404,
            detail=_error("not_found", "no photo for this palace"),
        )
    return Response(content=data, media_type="image/jpeg")


@app.put("/palaces/{palace_id}/photo", dependencies=[Depends(require_token)])
async def put_palace_photo(
    palace_id: str,
    request: Request,
    x_mcat_user: Optional[str] = Header(default=None),
) -> dict:
    _require_valid_palace_id_or_400(palace_id)
    user_key = _resolve_user_key(x_mcat_user)

    content_type = request.headers.get("content-type", "")
    if not content_type.startswith("image/jpeg"):
        raise HTTPException(
            status_code=415,
            detail=_error("unsupported_media_type", "expected image/jpeg"),
        )

    # Reject via the declared Content-Length before buffering the full body
    # (contract requirement). A missing/non-numeric/within-cap header falls
    # through to the post-read check below, which also covers chunked
    # transfer or a lying Content-Length.
    declared_length = request.headers.get("content-length")
    if declared_length is not None:
        try:
            declared_bytes = int(declared_length)
        except ValueError:
            declared_bytes = None
        if declared_bytes is not None and declared_bytes > _MAX_PHOTO_BYTES:
            raise HTTPException(
                status_code=413,
                detail=_error("payload_too_large", "photo exceeds 5MB limit"),
            )

    body = await request.body()
    if len(body) > _MAX_PHOTO_BYTES:
        raise HTTPException(
            status_code=413,
            detail=_error("payload_too_large", "photo exceeds 5MB limit"),
        )

    new_version = palace_store.put_photo(user_key, palace_id, body)
    if new_version is None:
        raise HTTPException(
            status_code=404, detail=_error("not_found", "palace not found")
        )

    return {"photoVersion": new_version}
