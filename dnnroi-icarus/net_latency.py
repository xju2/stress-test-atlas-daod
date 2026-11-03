"""Network-only latency to the Triton endpoint: TCP connect, TLS handshake, and a tiny gRPC RPC
(is_server_live, no tensor payload) on a warm channel. Run on the client host you want to probe."""
import socket, ssl, statistics, sys, time

import tritonclient.grpc as grpcclient

host = sys.argv[1] if len(sys.argv) > 1 else "triton-cluster-svc.ml4phys.com"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 443
N = 50


def stats(name, xs):
    xs = sorted(x * 1e3 for x in xs)
    print(f"{name:28s} n={len(xs):3d} min={xs[0]:8.3f} p50={statistics.median(xs):8.3f} "
          f"p95={xs[int(0.95 * (len(xs) - 1))]:8.3f} max={xs[-1]:8.3f} ms")


tcp, tls = [], []
ctx = ssl.create_default_context()
for _ in range(N):
    t0 = time.perf_counter()
    s = socket.create_connection((host, port), timeout=10)
    t1 = time.perf_counter()
    ss = ctx.wrap_socket(s, server_hostname=host)
    t2 = time.perf_counter()
    ss.close()
    tcp.append(t1 - t0)
    tls.append(t2 - t1)

c = grpcclient.InferenceServerClient(f"{host}:{port}", ssl=True)
assert c.is_server_live()  # warm up the channel
rpc = []
for _ in range(N):
    t0 = time.perf_counter()
    c.is_server_live()
    rpc.append(time.perf_counter() - t0)

print(f"target {host}:{port} from {socket.gethostname()}")
stats("TCP connect", tcp)
stats("TLS handshake", tls)
stats("gRPC is_server_live (warm)", rpc)
