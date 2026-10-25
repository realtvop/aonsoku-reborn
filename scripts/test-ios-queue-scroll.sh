#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aonsoku-queue-scroll.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/ModuleCache" \
  "$project_root/ios/Aonsoku/Features/Player/QueueScrollAnchors.swift" \
  "$project_root/scripts/tests/ios-queue-scroll.swift" \
  -o "$test_dir/queue-scroll-tests"
"$test_dir/queue-scroll-tests"
