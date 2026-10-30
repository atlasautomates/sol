#!/bin/sh
# Acceptance runner for the file index. Exit non-zero when the seam fails.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}file-index-acceptance"
swiftc \
  -framework Foundation \
  -framework CoreServices \
  -framework ImageIO \
  -framework CoreGraphics \
  -framework UniformTypeIdentifiers \
  -lsqlite3 \
  -import-objc-header "$ROOT/macos/file-index-tests/Bridging.h" \
  -I "$ROOT/macos/sol-macOS/lib" \
  "$ROOT/macos/sol-macOS/lib/NSString+Score.m" \
  "$ROOT/macos/sol-macOS/lib/FileIndex.swift" \
  "$ROOT/macos/file-index-tests/FileIndexAcceptance.swift" \
  -o "$OUT"
"$OUT"
rm -f "$OUT"
