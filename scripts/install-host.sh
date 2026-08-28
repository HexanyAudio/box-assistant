#!/bin/zsh
# Registers the native-messaging helper with Chrome for the current user.
#
# Usage:  scripts/install-host.sh <extension-id>
#
# The extension ID comes from chrome://extensions with Developer mode on, after
# loading extension/ with "Load unpacked". Chrome derives that ID from the folder
# path, so it stays stable as long as the folder doesn't move.

set -euo pipefail

EXT_ID="${1:-}"
if [[ -z "$EXT_ID" ]]; then
  print -u2 "usage: $0 <extension-id>"
  print -u2 "find it at chrome://extensions (Developer mode) after Load unpacked"
  exit 64
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/host/.build/release/BoxRevealHost"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST="$MANIFEST_DIR/com.hexany.boxreveal.json"

if [[ ! -x "$BIN" ]]; then
  print "building helper…"
  (cd "$REPO/host" && swift build -c release)
fi

mkdir -p "$MANIFEST_DIR"
cat > "$MANIFEST" <<JSON
{
  "name": "com.hexany.boxreveal",
  "description": "Reveals Box items in Finder via Box Drive",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON

print "installed: $MANIFEST"
print "  helper:    $BIN"
print "  extension: $EXT_ID"
print ""
print "Quit and reopen Chrome for it to pick this up."
