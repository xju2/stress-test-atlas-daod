"""Summarise perf_analyzer --verbose-csv files written by run_perf.sh.
Usage: python3 summarize.py results/<dir> [results/<dir> ...]
For multi-node NERSC runs pass the job dir; throughput is summed over nodes per (model, c, rep)."""
import csv, glob, os, re, sys
from collections import defaultdict

rows = defaultdict(list)  # (model, conc, rep) -> list of per-node dicts
for d in sys.argv[1:]:
    for f in glob.glob(os.path.join(d, "**", "*.csv"), recursive=True):
        m = re.match(r"(.+)_c(\d+)_r(\d+)\.csv", os.path.basename(f))
        with open(f) as fh:
            for r in csv.DictReader(fh):
                rows[(m[1], int(m[2]), int(m[3]))].append(r)

us = lambda r, k: float(r.get(k) or 0) / 1e3  # usec -> ms
print(f"{'model':22s} {'conc':>4s} {'rep':>3s} {'nodes':>5s} {'inf/s':>8s} {'p50ms':>8s} {'p95ms':>8s} "
      f"{'send':>7s} {'net+srv':>8s} {'recv':>6s} {'srv_q':>7s} {'srv_inf':>7s}")
for (model, c, rep), rs in sorted(rows.items()):
    r0 = rs[0]
    thr = sum(float(r["Inferences/Second"]) for r in rs)
    print(f"{model:22s} {c:4d} {rep:3d} {len(rs):5d} {thr:8.2f} {us(r0,'p50 latency'):8.1f} "
          f"{us(r0,'p95 latency'):8.1f} {us(r0,'Client Send'):7.1f} {us(r0,'Network+Server Send/Recv'):8.1f} "
          f"{us(r0,'Client Recv'):6.1f} {us(r0,'Server Queue'):7.1f} {us(r0,'Server Compute Infer'):7.1f}")
