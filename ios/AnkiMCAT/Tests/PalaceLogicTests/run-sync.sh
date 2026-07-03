#!/usr/bin/env bash
# Compile the memory palace's pure data model (Palace/PalaceModels.swift)
# together with the sync-contract assertions in PalaceSyncLogicTests.swift
# using the host Swift toolchain, then run them. No Simulator or Xcode
# target required.
#
# Deliberately compiles ONLY PalaceModels.swift (pure Codable structs,
# Foundation-only, zero I/O) -- NOT PalaceSyncModel.swift or SyncStore.swift.
# See PalaceSyncLogicTests.swift's header comment for why: those two files
# are hard-coupled to URLSession.shared and to a real-device Keychain item
# shared across every MCAT feature, with no dependency-injection seam, so
# they must never be exercised by a committed automated test.
#
# Sibling to ./run.sh -- compiled SEPARATELY (own binary, own @main) since
# both *Tests.swift files declare `@main` and can't be compiled together in
# the same swiftc invocation.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/../../Sources/AnkiMCAT/Palace"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O \
    "$SRC/PalaceModels.swift" \
    "$DIR/PalaceSyncLogicTests.swift" \
    -o "$TMP/palacesynclogictests"

"$TMP/palacesynclogictests"
