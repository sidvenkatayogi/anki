#!/usr/bin/env bash
# Compile the memory palace's pure core (Palace/PalaceModels.swift,
# PalaceLogic.swift, PalaceStore.swift) together with the assertions in
# PalaceLogicTests.swift using the host Swift toolchain, then run them. No
# Simulator or Xcode target required — this covers the ARKit/SwiftUI-free logic.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/../../Sources/AnkiMCAT/Palace"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O \
    "$SRC/PalaceModels.swift" \
    "$SRC/PalaceLogic.swift" \
    "$SRC/PalaceStore.swift" \
    "$DIR/PalaceLogicTests.swift" \
    -o "$TMP/palacelogictests"

"$TMP/palacelogictests"
