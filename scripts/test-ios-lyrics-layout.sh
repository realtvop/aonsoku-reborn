#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
simulator_id="${IOS_SIMULATOR_ID:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; print(next((d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["state"] == "Booted" and "iPhone" in d["name"]), ""))')}"
if [[ -z "$simulator_id" ]]; then
  echo "Boot an iPhone Simulator or set IOS_SIMULATOR_ID first" >&2
  exit 1
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/aonsoku-lyrics-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
app_dir="$test_dir/LyricsLayout.app"
mkdir -p "$app_dir"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
architecture="$(uname -m)"
xcrun swiftc -parse-as-library -sdk "$sdk_path" -target "$architecture-apple-ios16.0-simulator" \
  "$project_root/ios/Aonsoku/Features/Player/LyricsText.swift" \
  "$project_root/scripts/tests/ios-lyrics-layout.swift" -o "$app_dir/LyricsLayout"
cat > "$app_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>github.realtvop.aonsoku.lyrics-layout-tests</string>
<key>CFBundleExecutable</key><string>LyricsLayout</string>
<key>CFBundleName</key><string>Lyrics Layout Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict/>
</dict>
<key>LSRequiresIPhoneOS</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
xcrun simctl install "$simulator_id" "$app_dir"
container="$(xcrun simctl get_app_container "$simulator_id" github.realtvop.aonsoku.lyrics-layout-tests data)"
rm -f "$container/Documents/results.json"
xcrun simctl launch "$simulator_id" github.realtvop.aonsoku.lyrics-layout-tests
for attempt in {1..45}; do
  if [[ -f "$container/Documents/results.json" ]]; then
    cp "$container/Documents/lyrics.png" /tmp/aonsoku-lyrics-layout.png
    python3 - "$container/Documents/results.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print(json.dumps(result, ensure_ascii=False, indent=2))
if result['failures']: sys.exit(1)
PY
    exit 0
  fi
  sleep 1
done
echo "Simulator lyrics layout tests timed out" >&2
exit 1
