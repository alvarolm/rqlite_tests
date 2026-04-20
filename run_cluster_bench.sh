#!/usr/bin/env bash
# Benchmark rqlite writes against a 3-node cluster using bench.go.
# Node 1 bootstraps; nodes 2 and 3 join it.
#
# Optional:  LATENCY=20ms ./run_cluster_bench.sh
# Injects one-way per-chunk delay between nodes via a local TCP proxy
# (latproxy.go) placed in front of every node's Raft port.
set -euo pipefail

cd "$(dirname "$0")"

N="${N:-10}"
C="${C:-500}"
LATENCY="${LATENCY:-0}"
DATA_ROOT="${DATA_ROOT:-./cluster}"
LOG_DIR="${LOG_DIR:-./cluster-logs}"

# id : http_port : external_raft_port : internal_raft_port
# When LATENCY!=0, peers connect to external (proxy) port; rqlited binds internal.
NODES=(
  "1:4001:4002:14002"
  "2:4003:4004:14004"
  "3:4005:4006:14006"
)
LEADER_HTTP="localhost:4001"
LEADER_RAFT_EXT="localhost:4002"

for bin in rqlited go sqlite3 curl; do
  command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }
done

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do
    [[ -n "${p:-}" ]] && kill "$p" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo ">> building bench.go and latproxy.go"
go build -o bench ./bench.go
go build -o latproxy ./latproxy.go

echo ">> resetting $DATA_ROOT $LOG_DIR"
rm -rf "$DATA_ROOT" "$LOG_DIR"
mkdir -p "$DATA_ROOT" "$LOG_DIR"

use_proxy=0
if [[ "$LATENCY" != "0" && -n "$LATENCY" ]]; then
  use_proxy=1
  echo ">> LATENCY=$LATENCY  (inter-node proxies enabled)"
else
  echo ">> LATENCY=0  (direct node-to-node, no proxy)"
fi

start_proxy() {
  local ext=$1 internal=$2
  ./latproxy -listen ":$ext" -target "localhost:$internal" -delay "$LATENCY" \
    > "$LOG_DIR/proxy-$ext.log" 2>&1 &
  PIDS+=($!)
  echo ">> proxy :$ext -> :$internal delay=$LATENCY (pid ${PIDS[-1]})"
  # wait briefly for listen
  for _ in $(seq 1 25); do
    sleep 0.05
    (echo > "/dev/tcp/localhost/$ext") >/dev/null 2>&1 && return 0
  done
}

start_node() {
  local id=$1 http=$2 ext_raft=$3 int_raft=$4 join=${5:-}
  local dir="$DATA_ROOT/node$id"
  local log="$LOG_DIR/node$id.log"
  mkdir -p "$dir"
  local bind_raft
  if [[ "$use_proxy" == "1" ]]; then
    bind_raft="$int_raft"
  else
    bind_raft="$ext_raft"
  fi
  local args=(-node-id "$id" -http-addr "localhost:$http" -raft-addr "localhost:$bind_raft")
  if [[ "$use_proxy" == "1" ]]; then
    args+=(-raft-adv-addr "localhost:$ext_raft")
  fi
  [[ -n "$join" ]] && args+=(-join "$join")
  rqlited "${args[@]}" "$dir" > "$log" 2>&1 &
  PIDS+=($!)
  echo ">> node$id started (pid ${PIDS[-1]}, http=$http raft-bind=$bind_raft raft-adv=$ext_raft${join:+ join=$join})"
}

wait_ready() {
  local addr=$1
  for _ in $(seq 1 200); do
    sleep 0.2
    curl -fsS "http://$addr/readyz" >/dev/null 2>&1 && return 0
  done
  echo "node $addr not ready; see $LOG_DIR"; return 1
}

# Start proxies first (if enabled) so Raft traffic has something to dial.
if [[ "$use_proxy" == "1" ]]; then
  for entry in "${NODES[@]}"; do
    IFS=: read -r _ _ ext_raft int_raft <<< "$entry"
    start_proxy "$ext_raft" "$int_raft"
  done
fi

# Bootstrap node1, then join node2 and node3 to node1's external Raft addr.
IFS=: read -r id http ext_raft int_raft <<< "${NODES[0]}"
start_node "$id" "$http" "$ext_raft" "$int_raft"
wait_ready "localhost:$http"

for entry in "${NODES[@]:1}"; do
  IFS=: read -r id http ext_raft int_raft <<< "$entry"
  start_node "$id" "$http" "$ext_raft" "$int_raft" "$LEADER_RAFT_EXT"
  wait_ready "localhost:$http"
done

echo
echo ">> cluster nodes (from $LEADER_HTTP):"
curl -fsS "http://$LEADER_HTTP/nodes" | sed 's/,/,\n  /g'
echo

echo ">> bench against leader: N=$N C=$C LATENCY=$LATENCY  (normal / queued / queued+wait)"
./bench -n "$N" -c "$C"

echo
echo ">> stopping all nodes so SQLite WAL is checkpointed"
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
wait 2>/dev/null || true
PIDS=()

echo
echo ">> per-node DB sizes"
for entry in "${NODES[@]}"; do
  IFS=: read -r id _ _ _ <<< "$entry"
  ls -lh "$DATA_ROOT/node$id/db.sqlite" 2>/dev/null || true
done

echo
echo ">> per-node row counts (proves replication)"
for entry in "${NODES[@]}"; do
  IFS=: read -r id _ _ _ <<< "$entry"
  db="$DATA_ROOT/node$id/db.sqlite"
  printf "node%s: " "$id"
  sqlite3 "$db" "
    SELECT printf('normal=%d queued=%d queued_wait=%d',
      (SELECT COUNT(*) FROM bench_normal),
      (SELECT COUNT(*) FROM bench_queued),
      (SELECT COUNT(*) FROM bench_queued_wait));"
done
