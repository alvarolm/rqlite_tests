# rqlite queued-vs-normal write benchmarks

## Environment

- rqlited 10, SQLite 3.51.2, Go 1.25.6
- Linux 6.1 (Debian), amd64, all nodes on localhost
- Client: Go program `bench.go` (parallel workers via `-c`, total inserts via `-n`)

## Modes tested

| label | endpoint | semantics |
|---|---|---|
| `normal` | `POST /db/execute` | returns after Raft commit (durable) |
| `queued` | `POST /db/execute?queue` | returns after in-memory enqueue (not durable; server batches + commits later) |
| `queued+wait` | `POST /db/execute?queue&wait&timeout=30s` | queued, but each request blocks until its batch is committed |

All runs: `N=10000` inserts, `C=64` concurrent workers. One table per mode (`bench_normal`, `bench_queued`, `bench_queued_wait`).

## 1) Single node

Script: `run_bench.sh`

| mode | total | per-op | ops/s |
|---|---|---|---|
| normal      | 641 ms | 64 µs  | **15,581** |
| queued      | 363 ms | 36 µs  | **27,512** |
| queued+wait | 9.05 s | 905 µs | **1,105**  |

Notes
- `queued` ≈ 1.77× `normal`: a single node amortizes Raft commits across concurrent clients, so the gap is modest.
- `queued+wait` is *much* slower than `normal` because each client call serializes on the next batch flush (default batch interval).
- All three tables end up with 10,000 rows; `db.sqlite` ≈ 484 KB after WAL checkpoint on shutdown.

## 2) 3-node cluster, no added latency

Script: `run_cluster_bench.sh` (ports 4001/4002, 4003/4004, 4005/4006; nodes 2 and 3 join node 1).

| mode | ops/s | Δ vs single-node |
|---|---|---|
| normal      | **7,690**  | 0.49× |
| queued      | **15,691** | 0.57× |
| queued+wait | **1,053**  | 0.95× |

Notes
- `normal` drops ~2× — the leader now waits for a follower ACK (quorum = 2/3) before responding.
- `queued` also drops but stays ~2× faster than `normal`; the batch flushes still pay the quorum cost, but per-request latency doesn't.
- `queued+wait` barely changes — already dominated by serial batch-flush waits.
- Replication verified: `bench_normal`, `bench_queued`, `bench_queued_wait` each contain 10,000 rows on all three nodes; each `db.sqlite` is 484 KB.

## 3) 3-node cluster with injected inter-node latency

Injected via `latproxy.go` (TCP proxy in front of each node's Raft port, delay applied per forwarded chunk in both directions). rqlited advertises the proxy port via `-raft-adv-addr`, so peer traffic traverses it.

`LATENCY=20ms ./run_cluster_bench.sh`

| mode | 3-node / 0ms | 3-node / 20ms | slowdown |
|---|---|---|---|
| normal      | 7,690  | **1,059** | 7.3× |
| queued      | 15,691 | **2,981** | 5.3× |
| queued+wait | 1,053  | **633**   | 1.7× |

Notes
- Every Raft round-trip now takes ≥ 2×20ms; batches of many writes still amortize well, but synchronous per-request paths feel every round-trip.
- `queued` retains the biggest advantage under latency (≈ 2.8× `normal`): batches get committed once per interval regardless of payload size.
- `queued+wait` degrades *less* in relative terms because it was already paying per-request flush cost; the added 20ms is a smaller fraction of its baseline.
- The proxy applies delay per `Read` chunk (32 KB), not per TCP packet. It's a lightweight approximation — for exact packet-level emulation use `tc netem` (needs root).

## Cross-scenario summary (ops/s)

| scenario                 | normal | queued | queued+wait |
|--------------------------|-------:|-------:|------------:|
| 1 node                   | 15,581 | 27,512 |       1,105 |
| 3 nodes, 0 ms            |  7,690 | 15,691 |       1,053 |
| 3 nodes, 20 ms per-hop   |  1,059 |  2,981 |         633 |

## Durability caveat

`queued` is **not** durable: rqlite returns HTTP 200 as soon as the request is enqueued in memory, *before* the Raft commit. If the node crashes between enqueue and flush, those writes are lost. Even the HTTP 200 only confirms "queued", not that the SQL executed without error. Use `queued+wait` (or plain `normal`) when durability matters.

## Reproducing

```bash
# Single node, all three modes
./run_bench.sh

# Single node, normal only
./run_bench_normal.sh

# 3-node cluster
./run_cluster_bench.sh

# 3-node cluster with simulated latency
LATENCY=20ms ./run_cluster_bench.sh

# Override defaults
N=50000 C=128 LATENCY=5ms ./run_cluster_bench.sh
```

Files
- `bench.go` — parallel Go load generator (`-n`, `-c`, `-mode`)
- `latproxy.go` — TCP latency-injecting proxy
- `run_bench.sh` / `run_bench_normal.sh` / `run_cluster_bench.sh` — harnesses
