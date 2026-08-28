#!/bin/zsh
# Registers the native-messaging helper with Chrome for the current user.
#
# Usage:  scripts/install-host.sh [extension-id]
#
# With no argument the extension ID is looked up from Chrome's own profile data,
# so load extension/ via "Load unpacked" at chrome://extensions first. Pass an ID
# explicitly to skip the lookup.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="$REPO/extension"
BIN="$REPO/host/.build/release/BoxRevealHost"
CHROME="$HOME/Library/Application Support/Google/Chrome"
MANIFEST_DIR="$CHROME/NativeMessagingHosts"
MANIFEST="$MANIFEST_DIR/com.hexany.boxreveal.json"

EXT_ID="${1:-}"

if [[ -z "$EXT_ID" ]]; then
  # Chrome records unpacked extensions, keyed by ID, with their source path.
  EXT_ID=$(python3 - "$CHROME" "$EXT_DIR" <<'PY'
import json, sys, glob, os
base, target = sys.argv[1], os.path.realpath(sys.argv[2])
hits = set()
for pref in glob.glob(os.path.join(base, "*", "Preferences")):
    try:
        data = json.load(open(pref, encoding="utf-8"))
    except Exception:
        continue
    for eid, meta in (data.get("extensions", {}).get("settings", {}) or {}).items():
        if os.path.realpath(meta.get("path", "")) == target:
            hits.add(eid)
print("\n".join(sorted(hits)))
PY
  )
  count=$(print -r -- "$EXT_ID" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    print -u2 "Could not find the extension in Chrome."
    print -u2 "Load it first: chrome://extensions → Developer mode → Load unpacked →"
    print -u2 "  $EXT_DIR"
    exit 66
  elif [[ "$count" -gt 1 ]]; then
    print -u2 "Multiple IDs matched; pass the right one explicitly:"
    print -u2 "$EXT_ID"
    exit 65
  fi
  print "found extension: $EXT_ID"
fi

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

print ""
print "installed: $MANIFEST"
print "  helper:    $BIN"
print "  extension: $EXT_ID"
print ""
print "Now quit Chrome completely (⌘Q) and reopen it."
