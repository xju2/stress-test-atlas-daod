#!/bin/bash
# Closed-loop client sweep with load_retry.py (retries on), the counterpart of run_perf.sh.
#   ./run_retry.sh                          # on zeus (docker image from ./Dockerfile)
#   PY="python3 -I" ./run_retry.sh          # if tritonclient is installed locally / inside shifter
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MODELS="${MODELS:-dnnroi-icarus-plane0 dnnroi-icarus-plane1}"
CLIENTS="${CLIENTS:-1 2 4 8 16 32 64}"
REPEATS="${REPEATS:-2}"
TRIES="${TRIES:-3}"
WARMUP="${WARMUP:-15}"
DURATION="${DURATION:-60}"
OUT="${OUT:-results/retry_$(hostname -s)_$(date +%Y%m%d_%H%M%S)}"
PY="${PY:-docker run --rm --network host -u $(id -u):$(id -g) -e HOME=/tmp -v ${PWD}:${PWD} -w ${PWD} perf-analyzer:2.60.0 python3 -I}"

mkdir -p "${OUT}"
echo "models=${MODELS} clients=${CLIENTS} repeats=${REPEATS} tries=${TRIES} out=${OUT}"
for rep in $(seq 1 "${REPEATS}"); do
  for m in ${MODELS}; do
    for c in ${CLIENTS}; do
      f="${OUT}/${m}_c${c}_r${rep}"
      echo "$(date +%T) rep=${rep} model=${m} clients=${c}"
      ${PY} load_retry.py run -m "${m}" --clients "${c}" --tries "${TRIES}" \
        --warmup "${WARMUP}" --duration "${DURATION}" --out "${f}.csv" > "${f}.log" 2>&1 \
        || echo "  failed: $(tail -1 "${f}.log")"
    done
  done
done
echo "done: ${OUT}"
