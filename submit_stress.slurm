#!/bin/bash
#SBATCH -A m3443
#SBATCH -C cpu
#SBATCH -q regular
#SBATCH -J triton-athena
#SBATCH -N 1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH -t 02:00:00
#SBATCH --array=0-0
#SBATCH -o %x-%A_%a.out
#SBATCH -e %x-%A_%a.err

set -euo pipefail

## Override the array size at submit time, for example:
##   sbatch --array=0-7 submit_stress.slurm
##
## Useful knobs:
##   NUM_INSTANCES=16          Athena jobs per CPU node
##   FILES_PER_INSTANCE=1      AOD files per Athena job
##   ATHENA_PROC_NUMBER=8      cores per Athena job
##   GLOBAL_START_INDEX=0      first file-list index used by array task 0
##   BASE_RUN_DIR=$SCRATCH/... output root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export NUM_INSTANCES="${NUM_INSTANCES:-16}"
export FILES_PER_INSTANCE="${FILES_PER_INSTANCE:-1}"
export ATHENA_PROC_NUMBER="${ATHENA_PROC_NUMBER:-8}"
export ATHENA_CORE_NUMBER="${ATHENA_CORE_NUMBER:-${ATHENA_PROC_NUMBER}}"
export TRITON_URL="${TRITON_URL:-triton-cluster-svc.ml4phys.com}"
export TRITON_PORT="${TRITON_PORT:-443}"

ulimit -n 4096

srun --cpu-bind=cores "${SCRIPT_DIR}/run_stress_node.sh"
