#!/usr/bin/env bash
set -euo pipefail

# Official libtailscale C runtime. The Swift feature is gated to iOS 18.1;
# the static archive retains the host app's iOS 16 deployment compatibility.
revision=d1dc45d039edb7759ecbee6ba2aea0c4bca884b8
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="$root/.build/tailscale"
output="$root/ios/AonsokuKit/Vendor/CTailscale.xcframework"
go_bin="${TAILSCALE_GO:-go}"
source_dir="${TAILSCALE_SOURCE_DIR:-$cache/source}"

if [[ -f "$output/source-revision" ]] && [[ "$(cat "$output/source-revision")" == "$revision" ]]; then
  echo "Tailscale runtime is already prepared ($revision)."
  exit 0
fi
if ! command -v "$go_bin" >/dev/null; then
  echo "Go 1.27.1 is required. Install Go or set TAILSCALE_GO to its executable." >&2
  exit 1
fi
export GOTOOLCHAIN=go1.27.1
mkdir -p "$cache" "$(dirname "$output")"
if [[ ! -d "$source_dir/.git" ]]; then
  git init "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/tailscale/libtailscale.git
  git -C "$source_dir" fetch --depth 1 origin "$revision"
  git -C "$source_dir" checkout --detach FETCH_HEAD
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$revision" ]]; then
  echo "Unexpected libtailscale revision in $source_dir; expected $revision." >&2
  exit 1
fi

mkdir -p "$cache/headers"
cp "$source_dir/tailscale.h" "$cache/headers/tailscale.h"
cat > "$cache/headers/module.modulemap" <<'MODULE'
module CTailscale {
  header "tailscale.h"
  export *
}
MODULE

build_slice() {
  local name="$1" sdk="$2" arch="$3" goarch="$4" minimum="$5"
  local directory="$cache/$name"
  mkdir -p "$directory"
  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cat > "$directory/clang.sh" <<CLANG
#!/bin/sh
exec /usr/bin/xcrun --sdk "$sdk" clang -arch "$arch" -isysroot "$sdk_path" "$minimum" "\$@"
CLANG
  chmod +x "$directory/clang.sh"
  (
    cd "$source_dir"
    CGO_ENABLED=1 GOOS=ios GOARCH="$goarch" CC="$directory/clang.sh" \
      "$go_bin" build -trimpath -ldflags='-s -w' -tags ios -buildmode=c-archive \
      -o "$directory/libCTailscale.a" .
  )
}

build_slice device iphoneos arm64 arm64 -mios-version-min=16.0
build_slice simulator-arm64 iphonesimulator arm64 arm64 -mios-simulator-version-min=16.0
build_slice simulator-x86_64 iphonesimulator x86_64 amd64 -mios-simulator-version-min=16.0
mkdir -p "$cache/simulator"
xcrun lipo -create "$cache/simulator-arm64/libCTailscale.a" \
  "$cache/simulator-x86_64/libCTailscale.a" -output "$cache/simulator/libCTailscale.a"
staging="$cache/CTailscale.xcframework"
rm -rf "$staging"
xcodebuild -create-xcframework \
  -library "$cache/device/libCTailscale.a" -headers "$cache/headers" \
  -library "$cache/simulator/libCTailscale.a" -headers "$cache/headers" \
  -output "$staging"
printf '%s\n' "$revision" > "$staging/source-revision"
rm -rf "$output"
mv "$staging" "$output"
echo "Prepared $output"
