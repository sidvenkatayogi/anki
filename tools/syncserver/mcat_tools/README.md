# mcat_tools

A small FastAPI sidecar HTTP service implementing the Practice-tab and Palace
endpoints from `contracts/api.md` (run `2026-07-02-read-practice-tabs`). It
runs as a **separate process/container** alongside the existing Rust
`anki-sync-server` binary in this folder — it does not modify that binary.

## Endpoints

- `GET /health` — no auth
- `GET /version` — no auth
- `GET /practice/questions` — auth required
- `POST /metrics/compute` — auth required

Auth: every route except `/health` and `/version` requires header
`X-Mcat-Token: <token>` matching the `MCAT_TOOLS_TOKEN` env var exactly.

## Running standalone

From `tools/syncserver/`:

```bash
pip install -r requirements-mcat-tools.txt
MCAT_TOOLS_TOKEN=devtoken uvicorn mcat_tools.app:app --host 0.0.0.0 --port 8081
```

(Run from the `tools/syncserver/` directory so `mcat_tools` is importable as
a top-level package — no `__init__.py`-based install step required.)

## Environment variables

| Var                | Required | Notes                                                                                                                                                      |
| ------------------ | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MCAT_TOOLS_TOKEN` | Yes      | Shared secret for `X-Mcat-Token` auth. If unset, all authed routes are effectively locked (401 on every request) rather than auth being silently disabled. |

## Notes for devops/testing

- Suggested port: **8081** (separate from the Rust sync-server's port, e.g.
  8080). Not baked into the app itself — pass `--port` to uvicorn / set it in
  the Dockerfile CMD.
- New pip deps live in `tools/syncserver/requirements-mcat-tools.txt`:
  `fastapi`, `uvicorn[standard]`, `pydantic`, `httpx`.
- CORS: this app sets `Access-Control-Allow-Origin: *` on all routes (via
  `CORSMiddleware`) rather than relying on a `mediasrv` proxy — no frontend
  coordination needed this round.
- `/practice/questions` reads the committed seed file at
  `mcat_tools/data/practice-seed.json` (shipped inside this package, so the
  Dockerfile's `COPY mcat_tools/` picks it up automatically). This is a
  byte-identical copy of the database domain's contract artifact at
  `.factory/runs/2026-07-02-read-practice-tabs/contracts/practice-seed.json`
  — that `.factory/` path is git-ignored run-scratch and is never read at
  runtime. If the committed file is absent it returns a graceful
  `404 not_found` rather than crashing.

## Tests

From `tools/syncserver/`:

```bash
python3 -m pytest mcat_tools/tests/test_app.py -v
```

The tests exercise the app in-process via FastAPI's `TestClient` — no real
network access is required or performed.
