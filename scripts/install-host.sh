#!/bin/zsh
# Registers the native-messaging helper with Chrome for the current user.
#
# Usage:  scripts/install-host.sh [extension-id ...]
#
# With no arguments every plausible ID is allowed, so the same helper works
# whether the extension is loaded unpacked for development or force-installed
# from the signed CRX:
#
#   * the ID derived from the signing key   (.secrets/boxreveal.pem → the CRX)
#   * the ID derived from the folder path   (Load unpacked)
#   * anything Chrome currently reports as loaded from extension/
#
# These are three different IDs for the same code; listing all of them avoids a
# reinstall every time the delivery method changes.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="$REPO/extension"
KEY="$REPO/.secrets/boxreveal.pem"
BIN="$REPO/host/.build/release/BoxRevealHost"
CHROME="$HOME/Library/Application Support/Google/Chrome"
MANIFEST_DIR="$CHROME/NativeMessagingHosts"
MANIFEST="$MANIFEST_DIR/com.hexany.boxreveal.json"

typeset -a IDS
IDS=("$@")

nibble_id() {  # 16 bytes on stdin -> Chrome's a-p encoded ID
  python3 -c "
import hashlib,sys
h=hashlib.sha256(sys.stdin.buffer.read()).digest()[:16]
print(''.join(chr(97+(b>>4))+chr(97+(b&15)) for b in h))"
}

if (( ${#IDS} == 0 )); then
  # 1. Signed CRX identity, if the key exists.
  if [[ -f "$KEY" ]]; then
    IDS+=("$(openssl rsa -in "$KEY" -pubout -outform DER 2>/dev/null | nibble_id)")
  fi

  # 2. Unpacked identity: Chrome hashes the extension's absolute path.
  IDS+=("$(printf '%s' "$EXT_DIR" | nibble_id)")

  # 3. Whatever Chrome actually has loaded from that folder, across all profiles.
  while read -r found; do
    [[ -n "$found" ]] && IDS+=("$found")
  done < <(python3 - "$CHROME" "$EXT_DIR" <<'PY'
import json, glob, os, sys
base, target = sys.argv[1], os.path.realpath(sys.argv[2])
for pref in glob.glob(os.path.join(base, "*", "Preferences")):
    try:
        data = json.load(open(pref, encoding="utf-8"))
    except Exception:
        continue
    for eid, meta in (data.get("extensions", {}).get("settings", {}) or {}).items():
        if os.path.realpath(meta.get("path", "")) == target:
            print(eid)
PY
  )
fi

# Deduplicate while preserving order.
typeset -aU UNIQ
UNIQ=("${IDS[@]}")

if [[ ! -x "$BIN" ]]; then
  print "building helper…"
  (cd "$REPO/host" && swift build -c release)
fi

ORIGINS=$(printf '    "chrome-extension://%s/",\n' "${UNIQ[@]}" | sed '$ s/,$//')

mkdir -p "$MANIFEST_DIR"
cat > "$MANIFEST" <<JSON
{
  "name": "com.hexany.boxreveal",
  "description": "Reveals Box items in Finder via Box Drive",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": [
$ORIGINS
  ]
}
JSON

python3 -c "import json;json.load(open('$MANIFEST'))" || { print -u2 "generated invalid JSON"; exit 1; }

print ""
print "installed: $MANIFEST"
print "  helper:  $BIN"
print "  allowed extension IDs:"
printf '    %s\n' "${UNIQ[@]}"
print ""
print "Now quit Chrome completely (⌘Q) and reopen it."
