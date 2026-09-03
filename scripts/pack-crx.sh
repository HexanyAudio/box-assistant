#!/bin/zsh
# Packs the extension into a signed .crx and writes the Omaha update manifest
# used by ExtensionInstallForcelist for self-hosted extensions.
#
# Usage:  scripts/pack-crx.sh [https://host/path]
#
# The trailing path is where update.xml and the .crx will be served from; pass it
# once you know the hosting location. Without it a placeholder is written and the
# script can simply be re-run.
#
# The signing key determines the extension ID permanently. It is created on first
# run and must be kept — losing it means a new ID and a policy change on every
# machine.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="$REPO/extension"
DIST="$REPO/docs"
KEY="$REPO/.secrets/boxreveal.pem"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BASE_URL="${1:-https://REPLACE-ME.hexanyaudio.com/boxreveal}"
BASE_URL="${BASE_URL%/}"

[[ -x "$CHROME" ]] || { print -u2 "Chrome not found at $CHROME"; exit 69; }

VERSION=$(python3 -c "import json;print(json.load(open('$EXT_DIR/manifest.json'))['version'])")

if [[ ! -f "$KEY" ]]; then
  mkdir -p "$(dirname "$KEY")"
  print "generating signing key (keep this safe — it fixes the extension ID)…"
  # Chrome requires PKCS#8; `openssl genrsa` emits PKCS#1 and is rejected.
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY" 2>/dev/null
  chmod 600 "$KEY"
elif grep -q "BEGIN RSA PRIVATE KEY" "$KEY"; then
  print "converting existing key to PKCS#8 (same key, same extension ID)…"
  openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$KEY.pk8" 2>/dev/null
  mv "$KEY.pk8" "$KEY"
  chmod 600 "$KEY"
fi

# Chrome's ID is the first 16 bytes of the SHA-256 of the DER public key, with
# each nibble mapped 0-15 onto a-p.
EXT_ID=$(openssl rsa -in "$KEY" -pubout -outform DER 2>/dev/null | python3 -c "
import hashlib,sys
h=hashlib.sha256(sys.stdin.buffer.read()).digest()[:16]
print(''.join(chr(97+(b>>4))+chr(97+(b&15)) for b in h))
")

mkdir -p "$DIST"
rm -f "$DIST/boxreveal.crx"

# Chrome refuses to install an off-store extension whose manifest has no
# update_url: it assumes the Web Store, fails to find the ID there, and gives up
# without reporting anything. The value must match where update.xml is actually
# served, so inject it at pack time from BASE_URL instead of hardcoding it in
# the source manifest — that keeps the two in step when the host changes, and
# leaves `Load unpacked` working, which needs no update_url.
STAGE_DIR=$(mktemp -d)
STAGE="$STAGE_DIR/boxreveal"
cp -R "$EXT_DIR" "$STAGE"
python3 - "$STAGE/manifest.json" "$BASE_URL/update.xml" <<'MANIFEST_PY'
import json, sys
path, url = sys.argv[1], sys.argv[2]
m = json.load(open(path))
m["update_url"] = url
json.dump(m, open(path, "w"), indent=2)
MANIFEST_PY

"$CHROME" --pack-extension="$STAGE" --pack-extension-key="$KEY" \
  --no-message-box >/dev/null 2>&1 || true

if [[ ! -f "$STAGE.crx" ]]; then
  rm -rf "$STAGE_DIR"
  print -u2 "packing failed — is Chrome running?"
  exit 70
fi
mv "$STAGE.crx" "$DIST/boxreveal.crx"
rm -rf "$STAGE_DIR"

cat > "$DIST/update.xml" <<XML
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$EXT_ID'>
    <updatecheck codebase='$BASE_URL/boxreveal.crx' version='$VERSION' />
  </app>
</gupdate>
XML

print ""
print "packed  : $DIST/boxreveal.crx  ($(du -h "$DIST/boxreveal.crx" | cut -f1 | tr -d ' '))"
print "manifest: $DIST/update.xml"
print "version : $VERSION"
print ""
print "extension ID : $EXT_ID"
print "update URL   : $BASE_URL/update.xml"
print ""
print "Force-install policy value (ExtensionInstallForcelist):"
print "  $EXT_ID;$BASE_URL/update.xml"
