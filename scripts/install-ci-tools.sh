#!/bin/bash
# Installs the pinned CI toolchain with sha256 verification.
# Bump a version and its digest together; digests are of the release zips.
set -euo pipefail

XCODEGEN_VERSION=2.45.4
XCODEGEN_SHA256=090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef
SWIFTLINT_VERSION=0.63.3
SWIFTLINT_SHA256=fb045e85e7cb3374f42a4840b6b85a0106302afa69035c0c6f29af4a44c810b6
SWIFTFORMAT_VERSION=0.61.1
SWIFTFORMAT_SHA256=b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584
# Keep in sync with the SPM pin in project.yml.
SPARKLE_VERSION=2.9.2
SPARKLE_SHA256=1cb340cbbef04c6c0d162078610c25e2221031d794a3449d89f2f56f4df77c95

# A project.yml-only Sparkle bump would ship a framework newer than the
# sign_update CLI with no error anywhere — refuse to drift.
PROJECT_YML="$(cd "$(dirname "$0")/.." && pwd)/project.yml"
PROJECT_SPARKLE=$(awk '$1 == "exactVersion:" {print $2; exit}' "$PROJECT_YML")
if [[ "$PROJECT_SPARKLE" != "$SPARKLE_VERSION" ]]; then
    echo "Sparkle pin mismatch: project.yml has ${PROJECT_SPARKLE:-none}, install-ci-tools.sh has $SPARKLE_VERSION" >&2
    exit 1
fi

DEST="${RUNNER_TEMP:-/tmp}/ci-tools"
WORK=$(mktemp -d)
mkdir -p "$DEST/bin"
cd "$WORK"

fetch() { # name url sha256
    curl -sSfLo "$1.zip" "$2"
    echo "$3  $1.zip" | shasum -a 256 -c - > /dev/null
    unzip -qo "$1.zip" -d "$1"
}

fetch xcodegen "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" "$XCODEGEN_SHA256"
fetch swiftlint "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip" "$SWIFTLINT_SHA256"
fetch swiftformat "https://github.com/nicklockwood/SwiftFormat/releases/download/$SWIFTFORMAT_VERSION/swiftformat.zip" "$SWIFTFORMAT_SHA256"

# Sparkle ships a tar.xz, not a zip; only sign_update is needed (appcast
# signing in release.yml).
curl -sSfLo sparkle.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  sparkle.tar.xz" | shasum -a 256 -c - > /dev/null
mkdir sparkle && tar -xJf sparkle.tar.xz -C sparkle bin/sign_update

# XcodeGen resolves its share/ directory relative to the binary — keep the tree.
cp -R xcodegen/xcodegen "$DEST/xcodegen"
install -m 755 swiftlint/swiftlint swiftformat/swiftformat sparkle/bin/sign_update "$DEST/bin/"

if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$DEST/bin" >> "$GITHUB_PATH"
    echo "$DEST/xcodegen/bin" >> "$GITHUB_PATH"
fi
echo "Installed xcodegen $XCODEGEN_VERSION, swiftlint $SWIFTLINT_VERSION, swiftformat $SWIFTFORMAT_VERSION, sparkle $SPARKLE_VERSION to $DEST"
