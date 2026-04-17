#!/usr/bin/env bash
# Benchmark rqlite NORMAL writes only (parallel) using bench.go,
# then show the resulting SQLite DB.
set -euo pipefail

cd "$(dirname "$0")"

N="${N:-10000}"
C="${C:-64}"
HTTP_ADDR="${HTTP_ADDR:-localhost:4001}"
RAFT_ADDR="${RAFT_ADDR:-localhost:4002}"
DATA_DIR="${DATA_DIR:-./node}"
LOG="${LOG:-./rqlite.log}"

for bin in rqlited go sqlite3 curl; do
  command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }
done

cleanup() {
  [[ -n "${RPID:-}" ]] && kill "$RPID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo ">> building bench.go"
go build -o bench ./bench.go

echo ">> resetting $DATA_DIR"
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

echo ">> starting rqlited (http=$HTTP_ADDR raft=$RAFT_ADDR)"
rqlited -node-id 1 -http-addr "$HTTP_ADDR" -raft-addr "$RAFT_ADDR" "$DATA_DIR" > "$LOG" 2>&1 &
RPID=$!

for _ in $(seq 1 50); do
  sleep 0.2
  curl -fsS "http://$HTTP_ADDR/readyz" >/dev/null 2>&1 && break
done
curl -fsS "http://$HTTP_ADDR/readyz" >/dev/null || { echo "rqlited not ready; see $LOG"; exit 1; }
echo ">> rqlited up (pid $RPID)"

echo
echo ">> bench: N=$N C=$C  (normal only)"
./bench -mode normal -n "$N" -c "$C"

echo
echo ">> stopping rqlited so SQLite WAL is checkpointed"
kill "$RPID"
wait "$RPID" 2>/dev/null || true
RPID=""

DB="$DATA_DIR/db.sqlite"
echo
echo ">> DB file"
ls -lh "$DB" "$DB-wal" "$DB-shm" 2>/dev/null || true

echo
echo ">> schema"
sqlite3 "$DB" '.schema'

echo
echo ">> row count"
sqlite3 -header -column "$DB" \
  'SELECT COUNT(*) AS rows, MIN(id) AS min_id, MAX(id) AS max_id FROM bench_normal;'

echo
echo ">> first 3 / last 3"
sqlite3 -header -column "$DB" \
  'SELECT * FROM bench_normal ORDER BY id LIMIT 3;
   SELECT * FROM bench_normal ORDER BY id DESC LIMIT 3;'
