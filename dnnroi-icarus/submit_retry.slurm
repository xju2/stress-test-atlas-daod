#!/bin/bash
#SBATCH -A m3443
#SBATCH -C cpu
#SBATCH -q regular
#SBATCH -J dnnroi-retry
#SBATCH -N 4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=128
#SBATCH -t 00:30:00
#SBATCH --image=nvcr.io/nvidia/tritonserver:25.10-py3-sdk
#SBATCH -o %x-%j.out

## Paced load with retries at the friend's peak: plane1 50 req/s + plane0 25 req/s (~1.2 GB/s, ~9.5 Gb/s in).
## Rates and clients are totals, split evenly over the nodes. All nodes start at the same epoch second.
##   sbatch -N 8 --export=ALL,P1_RATE=50,P0_RATE=25,TRIES=3 submit_retry.slurm
##   P1_RATE=0 P0_RATE=0 -> closed loop (back-to-back requests) with P1_CLIENTS / P0_CLIENTS jobs
set -euo pipefail
cd "${SLURM_SUBMIT_DIR}"

N=${SLURM_JOB_NUM_NODES}
export P1_RATE="${P1_RATE:-50}" P0_RATE="${P0_RATE:-25}"
export P1_CLIENTS="${P1_CLIENTS:-64}" P0_CLIENTS="${P0_CLIENTS:-32}"
export TRIES="${TRIES:-3}" RETRY_DELAY="${RETRY_DELAY:-0}" TIMEOUT="${TIMEOUT:-0}"
export WARMUP="${WARMUP:-60}" DURATION="${DURATION:-600}"
export START_AT=$(( $(date +%s) + 60 ))
export OUT="results/retry_nersc_${SLURM_JOB_ID}_N${N}"
export P1_R=$(python3 -c "print(${P1_RATE}/${N})") P0_R=$(python3 -c "print(${P0_RATE}/${N})")
export P1_C=$(( (P1_CLIENTS + N - 1) / N )) P0_C=$(( (P0_CLIENTS + N - 1) / N ))
mkdir -p "${OUT}"
echo "nodes=${N} plane1=${P1_RATE}req/s,${P1_CLIENTS}jobs plane0=${P0_RATE}req/s,${P0_CLIENTS}jobs tries=${TRIES} out=${OUT}"

shifter python3 -I net_latency.py > "${OUT}/net_latency.txt" 2>&1 || true

srun --cpu-bind=none shifter bash -c '
  common="--tries ${TRIES} --retry-delay ${RETRY_DELAY} --timeout ${TIMEOUT} --warmup ${WARMUP} --duration ${DURATION} --start-at ${START_AT}"
  h=$(hostname -s)
  python3 -I load_retry.py run -m dnnroi-icarus-plane1 --clients ${P1_C} --rate ${P1_R} ${common} --out ${OUT}/plane1_${h}.csv > ${OUT}/plane1_${h}.log 2>&1 &
  python3 -I load_retry.py run -m dnnroi-icarus-plane0 --clients ${P0_C} --rate ${P0_R} ${common} --out ${OUT}/plane0_${h}.csv > ${OUT}/plane0_${h}.log 2>&1 &
  wait'

shifter python3 -I load_retry.py summary "${OUT}" --skip "${WARMUP}" | tee "${OUT}/summary.txt"
