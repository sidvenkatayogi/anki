#!/usr/bin/env bash
# Compile the Practice tab's pure metric core (Practice/MCATMetrics.swift)
# together with the assertions in PracticeLogicTests.swift using the host
# Swift toolchain, then run them. No Simulator or Xcode target required — this
# covers the networking/SwiftUI-free logic (mirrors Tests/PalaceLogicTests/run.sh).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/../../Sources/AnkiMCAT/Practice"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O \
    "$SRC/MCATMetrics.swift" \
    "$DIR/PracticeLogicTests.swift" \
    -o "$TMP/practicelogictests"

"$TMP/practicelogictests"
