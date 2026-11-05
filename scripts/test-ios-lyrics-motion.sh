#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aonsoku-lyrics-motion.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/ModuleCache" \
  "$project_root/ios/Aonsoku/Features/Player/LyricsMotion.swift" \
  "$project_root/scripts/tests/ios-lyrics-motion.swift" \
  -o "$test_dir/lyrics-motion-tests"
"$test_dir/lyrics-motion-tests"
