# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
"""X-Mcat-Token auth dependency.

Checks the `X-Mcat-Token` request header against the `MCAT_TOOLS_TOKEN`
env var. If the env var is unset, auth is still enforced (nothing will
ever match a missing token) -- we never silently disable auth.
"""

from __future__ import annotations

import os

from fastapi import Header, HTTPException

TOKEN_HEADER = "X-Mcat-Token"


def _expected_token() -> str | None:
    return os.environ.get("MCAT_TOOLS_TOKEN")


def unauthorized_exc() -> HTTPException:
    return HTTPException(
        status_code=401,
        detail={
            "error": {
                "code": "unauthorized",
                "message": "missing or invalid X-Mcat-Token",
            }
        },
    )


async def require_token(x_mcat_token: str | None = Header(default=None)) -> None:
    """FastAPI dependency: raises 401 unless the header matches the
    configured token. If MCAT_TOOLS_TOKEN is unset, no token can match,
    so authed routes are effectively locked (intentional, per contract)."""
    expected = _expected_token()
    if not expected or not x_mcat_token or x_mcat_token != expected:
        raise unauthorized_exc()
