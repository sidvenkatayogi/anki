#!/usr/bin/env bash
# Build Anki.xcframework from the anki-ios staticlib for iOS.
#
# Packages BOTH slices so the app runs in the Simulator AND on a physical
# device — the memory-palace AR features (ARKit world tracking) only run on real
# hardware, so a device slice is required to try them:
#   - aarch64-apple-ios-sim   (Apple-Silicon Simulator)
#   - aarch64-apple-ios       (device)
#
# Pass SIM_ONLY=1 to build just the Simulator slice (faster iteration when you
# don't need a device build).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADERS="${REPO_ROOT}/ios/include"
OUT="${REPO_ROOT}/out/ios/Anki.xcframework"

SIM_TARGET="aarch64-apple-ios-sim"
DEV_TARGET="aarch64-apple-ios"
SIM_LIB="${REPO_ROOT}/target/${SIM_TARGET}/debug/libanki_ios.a"
DEV_LIB="${REPO_ROOT}/target/${DEV_TARGET}/debug/libanki_ios.a"

echo ">> building staticlib for ${SIM_TARGET}"
cargo build -p anki-ios --target "${SIM_TARGET}" --manifest-path "${REPO_ROOT}/Cargo.toml"

CREATE_ARGS=(-library "${SIM_LIB}" -headers "${HEADERS}")
if [ "${SIM_ONLY:-0}" != "1" ]; then
    echo ">> building staticlib for ${DEV_TARGET}"
    cargo build -p anki-ios --target "${DEV_TARGET}" --manifest-path "${REPO_ROOT}/Cargo.toml"
    CREATE_ARGS+=(-library "${DEV_LIB}" -headers "${HEADERS}")
fi

# Build into a temp location first and swap in only on success, so a failed
# rebuild never leaves the tree without a working framework.
echo ">> (re)creating xcframework at ${OUT}"
TMP_PARENT="$(mktemp -d)"
TMP_OUT="${TMP_PARENT}/Anki.xcframework"
xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "${TMP_OUT}"
rm -rf "${OUT}"
mkdir -p "$(dirname "${OUT}")"
mv "${TMP_OUT}" "${OUT}"
rm -rf "${TMP_PARENT}"

echo ">> done: ${OUT}"
ls -1 "${OUT}"
