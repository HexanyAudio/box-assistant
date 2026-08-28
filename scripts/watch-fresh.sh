#!/bin/zsh
# Detects new Box items appearing in Box Drive's local index and measures how long
# they took to get there, by comparing Box's own creation timestamp against the
# moment the item became visible locally. Read-only throughout.

D="$HOME/Library/Application Support/Box/Box/data"
HOST="$(cd "$(dirname "$0")/.." && pwd)/host/.build/release/BoxRevealHost"
WORK="${TMPDIR:-/tmp}/boxreveal-watch"
DEADLINE=$(( $(date +%s) + ${1:-900} ))

rm -rf "$WORK"; mkdir -p "$WORK"

snapshot() {
  cp "$D/sync.db" "$WORK/s.db" 2>/dev/null
  cp "$D/sync.db-wal" "$WORK/s.db-wal" 2>/dev/null
  cp "$D/sync.db-shm" "$WORK/s.db-shm" 2>/dev/null
}

snapshot
sqlite3 "$WORK/s.db" "select box_id||':'||item_type from box_item;" | sort > "$WORK/base.txt"
echo "baseline: $(wc -l < "$WORK/base.txt" | tr -d ' ') items   watching for new ones…"
echo "(create a folder on box.com now)"
echo

lastwal=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  # Only re-snapshot when Box has actually written something.
  wal=$(stat -f '%m:%z' "$D/sync.db-wal" 2>/dev/null)
  if [ "$wal" = "$lastwal" ]; then sleep 1; continue; fi
  lastwal="$wal"
  now=$(date +%s)

  snapshot
  sqlite3 "$WORK/s.db" "select box_id||':'||item_type from box_item;" 2>/dev/null | sort > "$WORK/cur.txt"
  new=$(comm -13 "$WORK/base.txt" "$WORK/cur.txt")

  if [ -n "$new" ]; then
    echo "$new" | while read -r entry; do
      [ -z "$entry" ] && continue
      id=${entry%:*}; t=${entry#*:}
      [ "$t" = "1" ] && ty=folder || ty=file
      created=$(sqlite3 "$WORK/s.db" "select content_created_at from box_item where box_id='$id' and item_type=$t;" 2>/dev/null)
      res=$(printf '{"type":"%s","id":"%s"}' "$ty" "$id" | "$HOST" --debug --dry-run 2>&1)
      state=$(echo "$res" | grep -q '"ok":true' && echo "RESOLVES + on disk" || echo "$res" | sed -n 's/.*"error":"\([a-z_]*\)".*/\1/p')
      echo "[$(date '+%H:%M:%S')] new $ty $id"
      echo "    box created at : $(date -r ${created:-0} '+%H:%M:%S' 2>/dev/null)"
      echo "    visible locally: $(date -r $now '+%H:%M:%S')"
      [ -n "$created" ] && [ "$created" -gt 0 ] && echo "    lag            : $(( now - created ))s"
      echo "    host says      : $state"
      echo
    done
    cp "$WORK/cur.txt" "$WORK/base.txt"
  fi
  sleep 1
done
echo "watch window ended"
