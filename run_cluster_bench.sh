#!/usr/bin/env bash
# Benchmark rqlite writes against a 3-node cluster using bench.go.
# Node 1 bootstraps; nodes 2 and 3 join it.
#
# Optional:  LATENCY=20ms ONELATENCY=2ms ./run_cluster_bench.sh
# Adds one-way per-packet delay via `tc netem` on `lo`, filtered by each
# node's Raft destination port. Requires sudo for `tc`.
set -euo pipefail

cd "$(dirname "$0")"

N="${N:-350}"
C="${C:-35}"
LATENCY="${LATENCY:-6ms}"
ONELATENCY="${ONELATENCY:-0.5ms}"
DATA_ROOT="${DATA_ROOT:-./cluster}"
LOG_DIR="${LOG_DIR:-./cluster-logs}"

TC=/sbin/tc

# id : http_port : raft_port
NODES=(
  "1:4001:4002"
  "2:4003:4004"
  "3:4005:4006"
)
LEADER_HTTP="localhost:4001"
LEADER_RAFT="localhost:4002"

for bin in rqlited go sqlite3 curl "$TC"; do
  command -v "$bin" >/dev/null || [[ -x "$bin" ]] || { echo "missing: $bin"; exit 1; }
done

use_netem=0
if [[ "$LATENCY" != "0" && -n "$LATENCY" ]]; then
  use_netem=1
fi

PIDS=()
netem_active=0
teardown_netem() {
  [[ "$netem_active" == "1" ]] || return 0
  sudo "$TC" qdisc del dev lo root 2>/dev/null || true
  netem_active=0
}
cleanup() {
  for p in "${PIDS[@]:-}"; do
    [[ -n "${p:-}" ]] && kill "$p" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  teardown_netem
}
trap cleanup EXIT

echo ">> building bench.go"
go build -o bench ./bench.go

echo ">> resetting $DATA_ROOT $LOG_DIR"
rm -rf "$DATA_ROOT" "$LOG_DIR"
mkdir -p "$DATA_ROOT" "$LOG_DIR"

setup_netem() {
  echo ">> requesting sudo for tc netem setup"
  sudo -v
  # Clean any leftover qdisc from a previous aborted run.
  sudo "$TC" qdisc del dev lo root 2>/dev/null || true
  sudo "$TC" qdisc add dev lo root handle 1: prio bands 3 \
    priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  sudo "$TC" qdisc add dev lo parent 1:2 handle 20: netem delay "$LATENCY"
  sudo "$TC" qdisc add dev lo parent 1:3 handle 30: netem delay "$ONELATENCY"
  for entry in "${NODES[@]}"; do
    IFS=: read -r id _ raft <<< "$entry"
    local band=2
    [[ "$id" == "3" ]] && band=3
    sudo "$TC" filter add dev lo protocol ip parent 1:0 prio 1 \
      u32 match ip dport "$raft" 0xffff flowid "1:$band"
  done
  netem_active=1
  echo ">> netem active: nodes 1,2 delay=$LATENCY  node3 delay=$ONELATENCY"
}

start_node() {
  local id=$1 http=$2 raft=$3 join=${4:-}
  local dir="$DATA_ROOT/node$id"
  local log="$LOG_DIR/node$id.log"
  mkdir -p "$dir"
  local args=(-node-id "$id" -http-addr "localhost:$http" -raft-addr "localhost:$raft")
  [[ -n "$join" ]] && args+=(-join "$join")
  rqlited "${args[@]}" "$dir" > "$log" 2>&1 &
  PIDS+=($!)
  echo ">> node$id started (pid ${PIDS[-1]}, http=$http raft=$raft${join:+ join=$join})"
}

wait_ready() {
  local addr=$1
  for _ in $(seq 1 200); do
    sleep 0.2
    curl -fsS "http://$addr/readyz" >/dev/null 2>&1 && return 0
  done
  echo "node $addr not ready; see $LOG_DIR"; return 1
}

if [[ "$use_netem" == "1" ]]; then
  echo ">> LATENCY=$LATENCY ONELATENCY=$ONELATENCY  (tc netem on lo; node3 uses ONELATENCY)"
  setup_netem
else
  echo ">> LATENCY=0  (direct node-to-node, no delay)"
fi

# Bootstrap node1, then join node2 and node3 to node1.
IFS=: read -r id http raft <<< "${NODES[0]}"
start_node "$id" "$http" "$raft"
wait_ready "localhost:$http"

for entry in "${NODES[@]:1}"; do
  IFS=: read -r id http raft <<< "$entry"
  start_node "$id" "$http" "$raft" "$LEADER_RAFT"
  wait_ready "localhost:$http"
done

echo
echo ">> cluster nodes (from $LEADER_HTTP):"
curl -fsS "http://$LEADER_HTTP/nodes" | sed 's/,/,\n  /g'
echo

echo ">> bench against leader: N=$N C=$C LATENCY=$LATENCY ONELATENCY=$ONELATENCY  (normal / queued / queued+wait)"
./bench -n "$N" -c "$C"

echo
echo ">> stopping all nodes so SQLite WAL is checkpointed"
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
wait 2>/dev/null || true
PIDS=()

echo
echo ">> per-node DB sizes"
for entry in "${NODES[@]}"; do
  IFS=: read -r id _ _ <<< "$entry"
  ls -lh "$DATA_ROOT/node$id/db.sqlite" 2>/dev/null || true
done

echo
echo ">> per-node row counts (proves replication)"
for entry in "${NODES[@]}"; do
  IFS=: read -r id _ _ <<< "$entry"
  db="$DATA_ROOT/node$id/db.sqlite"
  printf "node%s: " "$id"
  sqlite3 "$db" "
    SELECT printf('normal=%d queued=%d queued_wait=%d',
      (SELECT COUNT(*) FROM bench_normal),
      (SELECT COUNT(*) FROM bench_queued),
      (SELECT COUNT(*) FROM bench_queued_wait));"
done
