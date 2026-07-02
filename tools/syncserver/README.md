# MCAT sync server (desktop ↔ iOS)

A self-hosted Anki sync server that keeps flashcard progress in sync between the
desktop app and the iOS app (`ios/AnkiMCAT`). It reuses Anki's native sync, so a
sync transfers the **whole collection** — cards **including FSRS memory state**
(stability, difficulty, desired retention, decay), the **review log**, notes,
decks, and **deck config / FSRS params** — plus **media**. Both apps embed the
same Rust core, so the FSRS algorithm is identical on each end; syncing the FSRS
_state_ is what makes scheduling consistent across devices.

This image is built from **this fork's source** (not the published PyPI package),
so the sync protocol always matches the desktop + iOS clients.

## 1. Start the server

```bash
just sync-server
# equivalently:
# docker compose -f tools/syncserver/docker-compose.yml up --build
```

The first build compiles the Rust sync server and takes a while; later runs are
cached. Default credentials are `mcat` / `mcat`. Override:

```bash
SYNC_USER1=me:secret just sync-server
```

Check health:

```bash
curl http://localhost:8080/health
```

Data persists in the `mcat-sync-data` Docker volume, one collection per user at
`<volume>/<username>/collection.anki2`.

Stop it (data is kept):

```bash
just sync-server-down
```

### No-Docker alternative (fast iteration)

If you already run the desktop app from source, you can run the fork's server
in-process without Docker (data goes to `~/.syncserver`):

```bash
SYNC_USER1=mcat:mcat just sync-server-dev
```

## 2. Point the desktop app at it

1. **Preferences → Network → Self-hosted sync server**: set
   `http://localhost:8080/`.
2. Click **Sync** (toolbar) and sign in with the `SYNC_USER1` credentials
   (`mcat` / `mcat`). The first sync **uploads** your desktop collection to the
   server, seeding it.

The endpoint is stored per-profile (`customSyncUrl`) and used for both
collection and media sync.

## 3. Sign in on iOS

Open the app → **Account** tab → sign in:

- **Username / Password**: the `SYNC_USER1` credentials.
- **Sync server**:
  - iOS **Simulator** on this Mac → `http://localhost:8080/`.
  - Physical **device** on the same network → `http://<your-Mac-LAN-IP>:8080/`
    (e.g. `http://192.168.1.20:8080/`). No App Transport Security exception is
    needed: the sync HTTP is performed by the Rust core, not URLSession.

The first sign-in **downloads** the collection from the server (replacing the
bundled demo deck). After that, tap **Sync Now** (or relaunch) to sync
incrementally. Study on either device, sync, and the FSRS due dates / review
history stay in step.

## Notes & limits

- **One collection per user account** (`<SYNC_BASE>/<user>/`). Use the _same_
  account on desktop and iOS to share a collection.
- If the two sides diverge at the schema level, Anki does a one-way full
  upload/download; the iOS app asks which side to keep (except on first login,
  which adopts the server's collection).
- Review-log / note-type / deck-config **deletions** don't sync (a native Anki
  limitation); regular edits and new reviews do.
- Self-hosted auth is `sha1(user:pass)` — fine for a private server, not a
  public multi-tenant deployment.

See also `docs/syncserver/` for the upstream (PyPI-based) Docker example and the
official env-var reference at <https://docs.ankiweb.net/sync-server.html>.

## Read & Practice tab env vars (mcat-tools)

The Read and Practice tabs call new HTTP endpoints (`/read/passage`,
`/practice/questions`, `/metrics/compute`, `/health`, `/version`) hosted by a
separate `mcat-tools` sidecar (see `contracts/api.md` in the
`2026-07-02-read-practice-tabs` factory run). They need three env vars:

- `OPENAI_API_KEY` — **required**. Used server-side for the Read tab's LLM
  quiz generation; never shipped to clients.
- `NEWS_API_KEY` — optional. Only used if the news-API passage-source tier is
  reached (Wikipedia is tried first). Leave blank to disable that tier.
- `MCAT_TOOLS_TOKEN` — **required**. A shared bearer secret; clients send it
  as the `X-Mcat-Token` header. This is a **separate secret from
  `SYNC_USER1`** — generate a distinct random value.

Set these either by copying `tools/syncserver/env.example` to
`tools/syncserver/.env` (git-ignored) and filling in real values, or by
exporting them in your shell before running `just sync-server` /
`just sync-server-dev`.

The sidecar is built from `tools/syncserver/mcat-tools.Dockerfile`, running
the real `mcat_tools.app:app` FastAPI app via uvicorn on port 8081, with
dependencies installed from `tools/syncserver/requirements-mcat-tools.txt`.

Check health:

```bash
curl http://localhost:8081/health
```

### Run mcat-tools without Docker

For fast iteration without Docker (e.g. alongside `just sync-server-dev`,
which only starts the Rust sync server and does **not** start mcat-tools):

```bash
cd tools/syncserver
pip install -r requirements-mcat-tools.txt
OPENAI_API_KEY=... MCAT_TOOLS_TOKEN=... uvicorn mcat_tools.app:app --host 0.0.0.0 --port 8081
```

The working directory must be `tools/syncserver/` so `mcat_tools` is
importable as a top-level package.
