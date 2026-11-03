#!/bin/bash
# Sweep perf_analyzer client concurrency for the dnnroi-icarus models on SUF-D3.
# Repeats the sweep REPEATS times: pass 1 also acts as warm-up for the autoscaler.
#   ./run_perf.sh                       # on zeus (docker image built from ./Dockerfile)
#   PA="perf_analyzer" ./run_perf.sh    # if perf_analyzer is on PATH (e.g. inside shifter/SDK image)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

URL="${TRITON_URL:-triton-cluster-svc.ml4phys.com}:${TRITON_PORT:-443}"
MODELS="${MODELS:-dnnroi-icarus-plane0 dnnroi-icarus-plane1}"
CONCURRENCY="${CONCURRENCY:-1 2 4 8 16 32 64}"
REPEATS="${REPEATS:-3}"
WINDOW_MS="${WINDOW_MS:-10000}"
TAG="${TAG:-$(hostname -s)}"
OUT="${OUT:-results/${TAG}_$(date +%Y%m%d_%H%M%S)}"
PA="${PA:-docker run --rm --network host -u $(id -u):$(id -g) -v ${PWD}:${PWD} -w ${PWD} perf-analyzer:2.60.0 perf_analyzer}"

mkdir -p "${OUT}"
echo "url=${URL} models=${MODELS} concurrency=${CONCURRENCY} repeats=${REPEATS} out=${OUT}"

for rep in $(seq 1 "${REPEATS}"); do
  for m in ${MODELS}; do
    for c in ${CONCURRENCY}; do
      f="${OUT}/${m}_c${c}_r${rep}"
      echo "$(date +%T) rep=${rep} model=${m} concurrency=${c}"
      # -f/--verbose-csv split client latency into send / network+server / recv / server queue+compute.
      ${PA} -m "${m}" -u "${URL}" -i grpc --ssl-grpc-use-ssl \
        --concurrency-range "${c}" --measurement-interval "${WINDOW_MS}" \
        --percentile 95 --max-trials 10 \
        -f "${f}.csv" --verbose-csv > "${f}.log" 2>&1 \
        || true
      # perf_analyzer can exit 0 without a CSV (unstable measurement), so check the output instead.
      [ -s "${f}.csv" ] || echo "  no result: $(grep -m1 -E 'error|Failed|failed' "${f}.log")"
    done
  done
done
echo "done: ${OUT}"
