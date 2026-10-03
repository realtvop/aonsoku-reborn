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

cd "$PACKAGE_ROOT"
exec xcodebuild -quiet test \
  -scheme AonsokuCapacitorNative \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  CODE_SIGNING_ALLOWED=NO
