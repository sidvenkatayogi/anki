# syntax=docker/dockerfile:1
#
# Self-hosted Anki sync server, built from THIS fork's source so the sync
# protocol matches the desktop + iOS clients exactly. A collection sync carries
# the whole collection — cards + FSRS memory state (stability/difficulty/
# desired-retention/decay), the review log, notes, decks, and deck config (FSRS
# params) — plus media.
#
# Build context is the repo root (see docker-compose.yml). out/, target/ and
# node_modules/ are excluded by the repo's .dockerignore.

FROM rust:1.92.0-bookworm AS builder

# The `anki` crate's build scripts generate protobuf/backend code at compile
# time via protoc; that is the only extra build tool needed (matches upstream's
# clean-checkout build in docs/syncserver/Dockerfile).
RUN apt-get update \
    && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# The repo's .cargo/config.toml points PROTOC (and some codegen paths) at ninja
# build outputs under out/ that don't exist here. We deliberately do NOT copy
# .cargo/, and point cargo at the system protoc instead; the build scripts fall
# back to cargo's OUT_DIR for everything else.
ENV PROTOC=/usr/bin/protoc

WORKDIR /src

# Copy only the Rust workspace inputs. Every workspace member must be present for
# cargo to load the workspace, even members anki-sync-server does not compile.
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY build ./build
COPY ftl ./ftl
COPY proto ./proto
COPY rslib ./rslib
COPY pylib/rsbridge ./pylib/rsbridge
COPY tools/minilints ./tools/minilints

RUN cargo build --release --locked -p anki-sync-server

# --- Runtime image -----------------------------------------------------------
FROM debian:bookworm-slim

# TLS roots for the (rustls) sync client/server.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/anki-sync-server /usr/local/bin/anki-sync-server

EXPOSE 8080
VOLUME /anki_data

# `--healthcheck` exits 0 when the server is configured/running (checks SYNC_*),
# with no stdout — keeps container logs clean.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD ["anki-sync-server", "--healthcheck"]

ENTRYPOINT ["anki-sync-server"]
