#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NODE_INDEX="${NODE_INDEX:-${SLURM_ARRAY_TASK_ID:-0}}"
NUM_INSTANCES="${NUM_INSTANCES:-16}"
FILES_PER_INSTANCE="${FILES_PER_INSTANCE:-1}"
GLOBAL_START_INDEX="${GLOBAL_START_INDEX:-0}"
BASE_RUN_DIR="${BASE_RUN_DIR:-${SCRATCH:-${PWD}}/triton_stress_${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-manual}}}"

START_INDEX=$((GLOBAL_START_INDEX + NODE_INDEX * NUM_INSTANCES * FILES_PER_INSTANCE))
RUN_DIR="${BASE_RUN_DIR}/node_${NODE_INDEX}"

mkdir -p "${RUN_DIR}"

export NUM_INSTANCES FILES_PER_INSTANCE START_INDEX RUN_DIR
export TRITON_URL="${TRITON_URL:-triton-cluster-svc.ml4phys.com}"
export TRITON_PORT="${TRITON_PORT:-443}"
export ATHENA_PROC_NUMBER="${ATHENA_PROC_NUMBER:-8}"
export ATHENA_CORE_NUMBER="${ATHENA_CORE_NUMBER:-8}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

echo "node_index=${NODE_INDEX}"
echo "hostname=$(hostname)"
echo "run_dir=${RUN_DIR}"
echo "start_index=${START_INDEX}"
echo "num_instances=${NUM_INSTANCES}"
echo "files_per_instance=${FILES_PER_INSTANCE}"
echo "athena_proc_number=${ATHENA_PROC_NUMBER}"
echo "triton=${TRITON_URL}:${TRITON_PORT}"

exec "${SCRIPT_DIR}/run.sh"
