"""Load generator with application-level retries (like SONIC's allowedTries), since perf_analyzer has none.

Each client is a process with its own gRPC channel that sends one request at a time. It either paces itself so
that all clients together hit --rate req/s, or with --rate 0 sends back-to-back.
A failed request is resent up to --tries times in total; the recorded latency includes every attempt.

  python3 load_retry.py run -m dnnroi-icarus-plane1 --clients 32 --rate 50 --duration 300 --out res/p1_host.csv
  python3 load_retry.py summary res/          # combine the per-request CSVs of all nodes/processes
  python3 load_retry.py selftest
"""
import argparse, csv, glob, multiprocessing as mp, os, socket, sys, time

FIELDS = ["model", "host", "client", "t_send", "latency", "tries", "ok", "error"]


def call_with_retry(fn, tries, delay=0.0):
    """Returns (tries_used, last_error or None)."""
    err = None
    for n in range(1, tries + 1):
        try:
            fn()
            return n, None
        except Exception as e:  # tritonclient raises InferenceServerException for any gRPC error
            err = e
            if n < tries and delay:
                time.sleep(delay)
    return tries, err


def worker(i, a):
    import numpy as np
    import tritonclient.grpc as grpcclient

    c = grpcclient.InferenceServerClient(a.url, ssl=a.ssl)
    md = c.get_model_metadata(a.model)
    inp = md.inputs[0]
    shape = [1 if d < 0 else int(d) for d in inp.shape]
    x = grpcclient.InferInput(inp.name, shape, inp.datatype)
    x.set_data_from_numpy(np.random.rand(*shape).astype(np.float32))  # serialised once, reused
    timeout = a.timeout or None
    infer = lambda: c.infer(a.model, [x], client_timeout=timeout)

    host, rows = socket.gethostname(), []
    interval = a.clients / a.rate if a.rate else 0.0
    nxt = a.start_at + i * interval / max(a.clients, 1)  # spread the clients' phases evenly
    end = a.start_at + a.warmup + a.duration
    while True:
        now = time.time()
        if nxt > now:
            time.sleep(nxt - now)
        t0 = time.time()
        if t0 >= end:
            break
        tries, err = call_with_retry(infer, a.tries, a.retry_delay)
        rows.append([a.model, host, i, f"{t0:.6f}", f"{time.time() - t0:.6f}", tries, int(err is None),
                     "" if err is None else str(err).splitlines()[0][:200]])
        nxt = max(nxt + interval, time.time())  # a late client skips missed slots instead of bursting
    return rows


def run(a):
    if a.start_at == 0:
        a.start_at = time.time() + 2
    with mp.get_context("spawn").Pool(a.clients) as pool:  # spawn: no gRPC state crosses a fork
        rows = [r for rs in pool.starmap(worker, [(i, a) for i in range(a.clients)]) for r in rs]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(FIELDS)
        w.writerows(rows)
    print(f"wrote {len(rows)} requests to {a.out}")
    summarize([dict(zip(FIELDS, map(str, r))) for r in rows], a.start_at + a.warmup, a.start_at + a.warmup + a.duration)


def pct(xs, q):
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else float("nan")


def summarize(rows, t_lo=None, t_hi=None):
    """Stats per model over requests sent in [t_lo, t_hi) (defaults: the full span of the data)."""
    ts = [float(r["t_send"]) for r in rows]
    if not ts:
        print("no requests")
        return {}
    t_lo = min(ts) if t_lo is None else t_lo
    t_hi = max(ts) if t_hi is None else t_hi
    span = max(t_hi - t_lo, 1e-9)
    out = {}
    print(f"{'model':22s} {'hosts':>5s} {'sent/s':>7s} {'ok/s':>7s} {'failed':>6s} {'retried':>7s} "
          f"{'p50ms':>8s} {'p90ms':>8s} {'p95ms':>8s} {'p99ms':>8s} {'maxms':>9s}")
    for m in sorted({r["model"] for r in rows}):
        rs = [r for r in rows if r["model"] == m and t_lo <= float(r["t_send"]) < t_hi]
        ok = sorted(float(r["latency"]) * 1e3 for r in rs if r["ok"] == "1")
        s = dict(hosts=len({r["host"] for r in rs}), sent=len(rs) / span, ok=len(ok) / span,
                 failed=sum(r["ok"] != "1" for r in rs), retried=sum(int(r["tries"]) > 1 for r in rs),
                 p50=pct(ok, .5), p90=pct(ok, .9), p95=pct(ok, .95), p99=pct(ok, .99), max=ok[-1] if ok else float("nan"))
        out[m] = s
        print(f"{m:22s} {s['hosts']:5d} {s['sent']:7.2f} {s['ok']:7.2f} {s['failed']:6d} {s['retried']:7d} "
              f"{s['p50']:8.1f} {s['p90']:8.1f} {s['p95']:8.1f} {s['p99']:8.1f} {s['max']:9.1f}")
    errs = {}
    for r in rows:
        if r["error"]:
            errs[r["error"]] = errs.get(r["error"], 0) + 1
    for e, n in sorted(errs.items(), key=lambda kv: -kv[1])[:5]:
        print(f"  last-try error x{n}: {e}")
    return out


def summary_cmd(a):
    rows = []
    for d in a.paths:
        for f in glob.glob(os.path.join(d, "**", "*.csv"), recursive=True) if os.path.isdir(d) else [d]:
            with open(f) as fh:
                rows += list(csv.DictReader(fh))
    # Per model, keep the window where every host was sending (latest first send + skip .. earliest last send).
    for m in sorted({r["model"] for r in rows}):
        rs = [r for r in rows if r["model"] == m]
        by_host = {}
        for r in rs:
            by_host.setdefault(r["host"], []).append(float(r["t_send"]))
        summarize(rs, max(min(v) for v in by_host.values()) + a.skip, min(max(v) for v in by_host.values()))


def selftest():
    calls = {"n": 0}

    def flaky():
        calls["n"] += 1
        if calls["n"] < 3:
            raise RuntimeError("GOAWAY received")

    assert call_with_retry(flaky, 3) == (3, None)
    calls["n"] = 0
    n, err = call_with_retry(flaky, 2)
    assert n == 2 and isinstance(err, RuntimeError)
    rows = [dict(model="m", host="h", client="0", t_send=str(t), latency="0.1", tries=str(1 + (t == 3)),
                 ok=str(int(t != 4)), error="" if t != 4 else "boom") for t in range(10)]
    s = summarize(rows, 0, 10)["m"]
    assert s["failed"] == 1 and s["retried"] == 1 and abs(s["sent"] - 1.0) < 1e-9 and abs(s["p50"] - 100) < 1e-9
    print("selftest ok")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("run")
    r.add_argument("-m", "--model", required=True)
    r.add_argument("-u", "--url", default="triton-cluster-svc.ml4phys.com:443")
    r.add_argument("--no-ssl", dest="ssl", action="store_false")
    r.add_argument("--clients", type=int, default=8, help="concurrent client processes (jobs)")
    r.add_argument("--rate", type=float, default=0, help="target req/s for this process in total; 0 = closed loop")
    r.add_argument("--tries", type=int, default=3, help="total attempts per request (1 = no retry)")
    r.add_argument("--retry-delay", type=float, default=0.0, help="seconds between attempts")
    r.add_argument("--timeout", type=float, default=0, help="per-attempt client timeout in s; 0 = none")
    r.add_argument("--warmup", type=float, default=30)
    r.add_argument("--duration", type=float, default=120)
    r.add_argument("--start-at", type=float, default=0, help="epoch seconds; lets several nodes start together")
    r.add_argument("--out", required=True)
    s = sp.add_parser("summary")
    s.add_argument("paths", nargs="+")
    s.add_argument("--skip", type=float, default=30, help="seconds of warm-up to drop after all hosts started")
    sp.add_parser("selftest")
    a = p.parse_args()
    {"run": run, "summary": summary_cmd, "selftest": lambda a: selftest()}[a.cmd](a)
