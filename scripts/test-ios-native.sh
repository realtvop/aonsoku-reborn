#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_ROOT="$REPOSITORY_ROOT/capacitor-plugins/capacitor-native"

simulator_id="${IOS_SIMULATOR_ID:-}"
if [[ -z "$simulator_id" ]]; then
  simulator_id="$({
    xcrun simctl list devices available
  } | sed -nE 's/^[[:space:]]*iPhone[^()]*\(([0-9A-F-]{36})\)[[:space:]]*\((Booted|Shutdown)\).*$/\1/p' | head -n 1)"
fi

if [[ -z "$simulator_id" ]]; then
  echo "No available iPhone Simulator was found." >&2
  exit 1
fi

if ! xcrun simctl list devices available | grep -Fq "$simulator_id"; then
  echo "The requested iPhone Simulator is not available: $simulator_id" >&2
  exit 1
fi

result_bundle="${IOS_TEST_RESULT_BUNDLE:-}"
temporary_result_root=""
if [[ -z "$result_bundle" ]]; then
  temporary_result_root="$(mktemp -d "${TMPDIR:-/tmp}/aonsoku-ios-tests.XXXXXX")"
  result_bundle="$temporary_result_root/AonsokuNativeTests.xcresult"
  cleanup() {
    if [[ -n "$temporary_result_root" && -d "$temporary_result_root" ]]; then
      rm -rf -- "$temporary_result_root"
    fi
  }
  trap cleanup EXIT
else
  if [[ -e "$result_bundle" ]]; then
    echo "iOS test result bundle already exists: $result_bundle" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$result_bundle")"
fi

cd "$PACKAGE_ROOT"
set +e
xcodebuild -quiet test \
  -scheme AonsokuCapacitorNative \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO
xcode_status=$?
set -e

if [[ ! -d "$result_bundle" ]]; then
  echo "xcodebuild did not produce an XCTest result bundle." >&2
  if [[ "$xcode_status" -ne 0 ]]; then
    exit "$xcode_status"
  fi
  exit 1
fi

summary="$(xcrun xcresulttool get test-results summary \
  --path "$result_bundle" \
  --compact)"
total_tests="$(printf '%s' "$summary" | plutil -extract totalTestCount raw -o - -)"
passed_tests="$(printf '%s' "$summary" | plutil -extract passedTests raw -o - -)"
failed_tests="$(printf '%s' "$summary" | plutil -extract failedTests raw -o - -)"
skipped_tests="$(printf '%s' "$summary" | plutil -extract skippedTests raw -o - -)"

echo "XCTest summary: total=$total_tests passed=$passed_tests failed=$failed_tests skipped=$skipped_tests"

if [[ "$total_tests" -le 0 ]]; then
  echo "xcodebuild completed without executing any XCTest cases." >&2
  exit 1
fi

if [[ "$xcode_status" -ne 0 || "$failed_tests" -ne 0 ]]; then
  echo "$summary" >&2
  if [[ "$xcode_status" -ne 0 ]]; then
    exit "$xcode_status"
  fi
  exit 1
fi
