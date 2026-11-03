#!/bin/bash
#SBATCH -A m3443
#SBATCH -C cpu
#SBATCH -q regular
#SBATCH -J dnnroi-perf
#SBATCH -N 4
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=128
#SBATCH -t 01:00:00
#SBATCH --image=nvcr.io/nvidia/tritonserver:25.10-py3-sdk
#SBATCH -o %x-%j.out

## NERSC -> SPIN perf_analyzer test. All nodes run the same sweep at the same time, so the
## total number of client jobs at each step is (#nodes x concurrency); sum per-node throughput.
## Pull the image once:  shifterimg pull nvcr.io/nvidia/tritonserver:25.10-py3-sdk
##   sbatch -N 8 --export=ALL,CONCURRENCY="4 8 16",REPEATS=2 submit_perf.slurm
## A single node also runs net_latency.py to get the network-only latency from NERSC.
set -euo pipefail
cd "${SLURM_SUBMIT_DIR}"

export CONCURRENCY="${CONCURRENCY:-1 4 16}"
export REPEATS="${REPEATS:-2}"
export PA="perf_analyzer"
OUT_ROOT="results/nersc_${SLURM_JOB_ID}_N${SLURM_JOB_NUM_NODES}"
mkdir -p "${OUT_ROOT}"

shifter python3 -I net_latency.py > "${OUT_ROOT}/net_latency.txt" 2>&1 || true

# shortcut: nodes are not barrier-synchronised between sweep steps, only started together; fine while
# every node uses identical settings. Upgrade to one concurrency per job if steps drift apart.
srun --cpu-bind=none bash -c \
  'TAG=$(hostname -s) OUT='"${OUT_ROOT}"'/$(hostname -s) shifter ./run_perf.sh'
