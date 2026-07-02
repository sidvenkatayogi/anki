#!/usr/bin/env bash
# Compile the Practice tab's pure core (Practice/MCATMetrics.swift) together
# with the cross-implementation parity assertions in
# ParityFixtureTests.swift using the host Swift toolchain, then run them. No
# Simulator or Xcode target required. Sibling to ./run.sh -- compiled
# SEPARATELY because both files declare `@main` and can't be compiled in the
# same swiftc invocation.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/../../Sources/AnkiMCAT/Practice"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O \
    "$SRC/MCATMetrics.swift" \
    "$DIR/ParityFixtureTests.swift" \
    -o "$TMP/parityfixturetests"

"$TMP/parityfixturetests"
