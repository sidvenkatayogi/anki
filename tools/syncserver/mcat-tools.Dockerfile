# syntax=docker/dockerfile:1
#
# "mcat-tools" sidecar: FastAPI/uvicorn service hosting the Read/Practice tab
# HTTP endpoints (/read/passage, /practice/questions, /metrics/compute,
# /health, /version — see contracts/api.md in the 2026-07-02-read-practice-tabs
# factory run). Runs standalone alongside the Rust anki-sync-server, not
# proxied through mediasrv.
#
# Build context is the repo root (see docker-compose.yml's mcat-tools
# service), so all COPY paths below are relative to the repo root.

FROM python:3.12-slim

WORKDIR /app

COPY tools/syncserver/requirements-mcat-tools.txt ./requirements-mcat-tools.txt
RUN pip install --no-cache-dir -r requirements-mcat-tools.txt

# mcat_tools/ is copied so it's importable as a top-level package
# (`mcat_tools.app:app`) from /app, matching the CMD below.
COPY tools/syncserver/mcat_tools/ ./mcat_tools/

EXPOSE 8081

CMD ["uvicorn", "mcat_tools.app:app", "--host", "0.0.0.0", "--port", "8081"]
