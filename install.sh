#!/bin/bash
# Install the local utilBox disk image into /Applications and ad-hoc sign it.
# Does not notarize, does not use a Developer ID, and does not launch the app.
#
#   ./install.sh
#   ./install.sh /path/to/utilBox.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -gt 1 ]]; then
  echo "Usage: ./install.sh [path/to/disk-image.dmg]" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  DMG="$1"
else
  DMG="$ROOT/dist/utilBox.dmg"
fi

if [[ ! -f "$DMG" ]]; then
  echo "Couldn't find a disk image at $DMG" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This install has to be run on a Mac." >&2
  exit 1
fi

MOUNT=""
detach() {
  if [[ -n "$MOUNT" ]]; then
    local volume="$MOUNT"
    MOUNT=""
    hdiutil detach "$volume" -quiet || hdiutil detach "$volume" -force || true
  fi
}
trap detach EXIT

ATTACH="$(hdiutil attach "$DMG" -nobrowse -noautoopen)"
MOUNT="$(printf '%s\n' "$ATTACH" | sed -n 's#.*\(/Volumes/.*\)#\1#p' | head -1)"
if [[ -z "$MOUNT" || ! -d "$MOUNT" ]]; then
  echo "The disk image did not mount." >&2
  exit 1
fi

shopt -s nullglob
APPS=("$MOUNT"/*.app)
shopt -u nullglob
if [[ ${#APPS[@]} -ne 1 ]]; then
  echo "Expected one app at the top of the disk image, found ${#APPS[@]}." >&2
  exit 1
fi

SRC="${APPS[0]}"
APP_NAME="$(basename "$SRC")"
DEST="/Applications/$APP_NAME"
EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SRC/Contents/Info.plist" 2>/dev/null || basename "$SRC" .app)"

if pgrep -xq "$EXEC"; then
  killall "$EXEC" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xq "$EXEC" || break
    sleep 0.2
  done
fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"
detach

xattr -dr com.apple.quarantine "$DEST"
codesign --force --deep --sign - "$DEST"

if xattr -l "$DEST" | grep -q 'com.apple.quarantine'; then
  echo "Quarantine is still set on $DEST" >&2
  exit 1
fi

SIGN="$(codesign -dv "$DEST" 2>&1)"
printf '%s\n' "$SIGN"
if ! printf '%s\n' "$SIGN" | grep -q 'Signature=adhoc'; then
  echo "The installed app does not have an ad-hoc signature." >&2
  exit 1
fi

echo "Installed $DEST"
