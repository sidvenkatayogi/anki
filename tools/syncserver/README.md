# MCAT sync server (desktop ↔ iOS)

A self-hosted Anki sync server that keeps flashcard progress in sync between the
desktop app and the iOS app (`ios/AnkiMCAT`). It reuses Anki's native sync, so a
sync transfers the **whole collection** — cards **including FSRS memory state**
(stability, difficulty, desired retention, decay), the **review log**, notes,
decks, and **deck config / FSRS params** — plus **media**. Both apps embed the
same Rust core, so the FSRS algorithm is identical on each end; syncing the FSRS
_state_ is what makes scheduling consistent across devices.

**All** MCAT data now lives in the collection — the practice question bank and
answer history (stored as notes + their review log) and the memory palaces
(stored as notes + media). There is **no separate `mcat-tools` service** to run;
everything syncs through this one server.

**You don't have to self-host.** Because the clients use standard Anki sync,
they can sync to **AnkiWeb** (free web signup at <https://ankiweb.net>) instead
— leave the sync-server field blank on both desktop and iOS to use it. Self-host
with the steps below when you want to run your own server.

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

- **Username / Password**: your AnkiWeb login, or the `SYNC_USER1` credentials
  for a self-hosted server.
- **Sync server** (optional):
  - Leave **blank** to use **AnkiWeb** (the default).
  - Self-hosted, iOS **Simulator** on this Mac → `http://localhost:8080/`.
  - Self-hosted, physical **device** on the same network →
    `http://<your-Mac-LAN-IP>:8080/` (e.g. `http://192.168.1.20:8080/`). No App
    Transport Security exception is needed: the sync HTTP is performed by the
    Rust core, not URLSession.

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

- The practice bank is **seeded once** into the collection (guarded by a synced
  `mcat.practiceSeedVersion` config marker) from the bundled `practice-seed.json`,
  then syncs like any other notes. Memory palaces are an **iOS-only** feature —
  the iOS app stores them as notes + media so they sync across iOS devices, but
  there is no desktop viewer.

See also `docs/syncserver/` for the upstream (PyPI-based) Docker example and the
official env-var reference at <https://docs.ankiweb.net/sync-server.html>.
