#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d "utilBox.app" ]]; then
  echo "Couldn't find utilBox.app next to this installer."
  exit 1
fi

echo "Copying utilBox to /Applications."
echo "This also clears the download quarantine flag on utilBox."
echo "The app is unsigned, so Apple still may ask once about this installer."
rm -rf "/Applications/utilBox.app"
cp -R "utilBox.app" "/Applications/utilBox.app"
xattr -dr com.apple.quarantine "/Applications/utilBox.app" || true
open "/Applications/utilBox.app"
echo "utilBox is open. The mailbox icon is at the top right of the screen."
