#!/bin/bash
# Builds dist/utilBox.dmg. Run this on a Mac with Xcode Command Line Tools.
# No Apple Developer account and no Xcode app are required.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "utilBox's app and DMG have to be built on a Mac."
  echo "On this computer you can still run: make test"
  exit 1
fi

mkdir -p build dist

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"

echo "Running tests..."
"$SWIFTC" -swift-version 5 -sdk "$SDK" -Onone -g -o build/utilbox-tests \
  Sources/ClipDropCore/*.swift Tests/RunTests.swift
./build/utilbox-tests

build_arch() {
  local arch="$1"
  "$SWIFTC" -swift-version 5 -O -whole-module-optimization -parse-as-library \
    -sdk "$SDK" \
    -target "${arch}-apple-macosx13.0" \
    -framework AppKit \
    -framework QuartzCore \
    -framework ServiceManagement \
    -o "build/utilBox-${arch}" \
    Sources/ClipDropCore/*.swift Sources/ClipDrop/*.swift
}

ok=()
for arch in arm64 x86_64; do
  echo "Compiling ${arch}..."
  if build_arch "$arch"; then
    ok+=("build/utilBox-${arch}")
  else
    echo "Skipped ${arch}."
  fi
done

if [[ ${#ok[@]} -eq 0 ]]; then
  echo "The compiler did not produce a binary."
  exit 1
fi

if [[ ${#ok[@]} -eq 1 ]]; then
  cp "${ok[0]}" build/utilBox
else
  lipo -create "${ok[@]}" -output build/utilBox
fi

APP="dist/utilBox.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/utilBox "$APP/Contents/MacOS/utilBox"
chmod +x "$APP/Contents/MacOS/utilBox"
cp Info.plist "$APP/Contents/Info.plist"

ICONSET="$ROOT/resources/AppIcon.iconset"
if [[ -d "$ICONSET" ]] && command -v iconutil >/dev/null; then
  if iconutil -c icns "$ICONSET" -o "$ROOT/build/utilBox.icns"; then
    cp "$ROOT/build/utilBox.icns" "$APP/Contents/Resources/utilBox.icns"
  else
    echo "Continuing without a custom icon."
  fi
fi

# Left unsigned on purpose. An ad-hoc signature made on one Mac is often
# reported as "damaged" on another. An unsigned app can be opened once with
# Right-click → Open, and macOS does not ask on later launches.

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/utilBox.app"
ln -s /Applications "$STAGE/Applications"
cp packaging/READ-ME.txt "$STAGE/READ ME.txt"
cp "packaging/Install utilBox.command" "$STAGE/Install utilBox.command"
chmod +x "$STAGE/Install utilBox.command"

rm -f dist/utilBox.dmg
hdiutil create \
  -volname "utilBox" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$ROOT/dist/utilBox.dmg"

echo "Built $ROOT/dist/utilBox.dmg"
