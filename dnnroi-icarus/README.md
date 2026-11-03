# dnnroi-icarus perf_analyzer study (SUF-D3)

Measures latency and throughput of `dnnroi-icarus-plane0` (input 3x1056x1024 fp32 = 13.0 MB, output 4.3 MB)
and `dnnroi-icarus-plane1` (3x1400x1024 = 17.2 MB, output 5.7 MB) on `triton-cluster-svc.ml4phys.com:443` (gRPC+TLS).

| file | what |
|---|---|
| `Dockerfile` | Ubuntu 24.04 + `perf-analyzer` wheel (needs glibc >= 2.38; zeus/EL9 has 2.34) |
| `run_perf.sh` | concurrency sweep, repeated `REPEATS` times (pass 1 warms the autoscaler) |
| `net_latency.py` | TCP connect / TLS handshake / tiny gRPC RPC latency (no tensor payload) |
| `submit_perf.slurm` | Perlmutter multi-node version (shifter, Triton SDK image) |
| `summarize.py` | table from the `--verbose-csv` outputs; sums throughput over nodes |

```bash
docker build -t perf-analyzer:2.60.0 .
./run_perf.sh                                   # zeus
docker run --rm --network host -v $PWD:/w -w /w perf-analyzer:2.60.0 python3 -I net_latency.py
python3 summarize.py results/zeus_*
sbatch -N 8 submit_perf.slurm                   # NERSC, 8 nodes x CONCURRENCY clients
```

## Results from zeus (2026-11-03), `results/zeus_20261103_120527`, summary in `results/zeus_summary.txt`

Network only (zeus -> SPIN): ping RTT 0.3 ms, TCP connect 1.3 ms, TLS handshake 8.4 ms, warm gRPC RPC 1.6 ms (p50).

Median over the 3 passes (pass 1 = cold):

| clients | plane0 inf/s | plane0 p50 [ms] | plane1 inf/s | plane1 p50 [ms] |
|---:|---:|---:|---:|---:|
| 1  | 4.3 | 210  | 3.3 | 269  |
| 2  | 5.8 | 329  | 4.3 | 444  |
| 4  | 6.1 | 628  | 4.7 | 826  |
| 8  | 8.0 | 972  | 5.9 | 1451 |
| 16 | 8.5 | 1843 | 6.4 | 2423 |
| 32 | 8.9 | 3659 | 6.7 | 4760 |
| 64 | 9.1 | 7045 | -   | -    |

Server side at every concurrency: queue ~0 ms, GPU compute 15-16 ms (plane0) / 20-22 ms (plane1).

- The server is not the bottleneck. GPU compute is ~16-21 ms per request, not 0.48 s, and no request waits in the queue.
- The client link is. zeus has a 1 Gb/s NIC: 9 inf/s x 13 MB = 117 MB/s for plane0 and 6.7 x 17.2 MB = 115 MB/s for plane1,
  i.e. line rate. Beyond ~8 clients latency grows linearly with clients (latency ~ clients / 9 s), which is pure queuing on the wire.
- Even with one client, ~185 ms of the 210 ms is moving the tensors (~70 MB/s through the TLS ingress), not round-trip latency.
- So "NERSC to SPIN 5.3 s" and "FG to SPIN 274.7 s" are consistent with many jobs sharing a limited path: each request
  ships 17-23 MB, and latency = (concurrent jobs x payload) / bandwidth. From FG the WAN path is far thinner.
- Server-side errors seen during the sweep while replicas scaled: `GOAWAY received`, `Connection reset by peer`,
  `failed to find the requested model version` (plane1 c=16/32/64). Those steps have no CSV.

To actually load the server, run from many NERSC nodes with `submit_perf.slurm`; one 1 Gb/s host saturates at ~9 inf/s.

## Retries and the 50 req/s target (`load_retry.py`, `submit_retry.slurm`)

perf_analyzer has no retry option, and failed requests (`GOAWAY`, `Connection reset`) become errors. `load_retry.py` is a
`tritonclient.grpc` load generator with application-level retries (`--tries`, `--retry-delay`, `--timeout`),
closed-loop or paced (`--rate`), one process per client. Latency includes all attempts; it also counts retried and failed requests.

```bash
python3 load_retry.py run -m dnnroi-icarus-plane1 --clients 16 --duration 60 --out results/x/p1.csv   # closed loop
python3 load_retry.py summary results/x
sbatch -N 4 submit_retry.slurm   # plane1 50 req/s + plane0 25 req/s (friend's peak), 3 tries, 10 min
```

Cross-check on zeus: 16 closed-loop plane1 clients give 6.6 req/s and 2.4 s p50, the same as perf_analyzer (6.4 req/s, 2.4 s).
The 50 + 25 req/s target is ~1.2 GB/s (~9.5 Gb/s) of input, so it can only be driven from NERSC nodes, not from zeus's 1 Gb/s link.
