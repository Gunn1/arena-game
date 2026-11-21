#!/usr/bin/env bash
# Online test: a headless dedicated server and two bot clients as separate processes.
# Every second each prints a hash of its map; the clients' must match the server's.
#   usage: tests/net_test.sh [path-to-godot]
set -u
GODOT=${1:-godot}
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
PORT=$((20000 + RANDOM % 20000))
"$GODOT" --headless --path . -- --server --port $PORT --autostart 2 --print-hash --quit-after 14 > "$OUT/server.txt" 2>&1 &
sleep 2
"$GODOT" --headless --path . -- --join 127.0.0.1:$PORT --bot --print-hash --quit-after 12 > "$OUT/c1.txt" 2>&1 &
"$GODOT" --headless --path . -- --join 127.0.0.1:$PORT --bot --print-hash --quit-after 12 > "$OUT/c2.txt" 2>&1 &
wait
fail=0
for c in c1 c2; do
  n=$(grep -c HASH "$OUT/$c.txt")
  bad=$(join <(grep HASH "$OUT/server.txt" | awk '{print $2, $3}' | sort) <(grep HASH "$OUT/$c.txt" | awk '{print $2, $3}' | sort) | awk '$2 != $3' | wc -l)
  echo "$c: $n map checks, $bad mismatches"
  if [ "$n" -lt 5 ] || [ "$bad" -ne 0 ]; then fail=1; fi
done
if [ "$(grep HASH "$OUT/server.txt" | awk '{print $3}' | sort -u | wc -l)" -lt 2 ]; then
  echo "map never changed: remote input or crumbling isn't reaching the server"; fail=1
fi
[ $fail -eq 0 ] && echo "online test passed" || { echo "online test FAILED (logs in $OUT)"; exit 1; }
