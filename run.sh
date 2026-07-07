#!/bin/bash
set -euo pipefail

## shifter --image=beojan/mpicuda9-2:latest --module cvmfs,gpu
## source /global/cfs/cdirs/atlas/scripts/setupATLAS.sh
## setupATLAS
## Example: NUM_INSTANCES=8 FILES_PER_INSTANCE=2 ./run.sh

FILE_LIST="${FILE_LIST:-/global/cfs/cdirs/m3443/data/AOD/mc23_aod_files.txt}"
NUM_INSTANCES="${NUM_INSTANCES:-4}"
FILES_PER_INSTANCE="${FILES_PER_INSTANCE:-1}"
START_INDEX="${START_INDEX:-0}"
RUN_DIR="${RUN_DIR:-triton_stress_$(date +%Y%m%d_%H%M%S)}"
TRITON_URL="${TRITON_URL:-triton-cluster-svc.ml4phys.com}"
TRITON_PORT="${TRITON_PORT:-443}"

export ATHENA_PROC_NUMBER="${ATHENA_PROC_NUMBER:-8}"
export ATHENA_CORE_NUMBER="${ATHENA_CORE_NUMBER:-8}"

if ((NUM_INSTANCES <= 0 || FILES_PER_INSTANCE <= 0 || START_INDEX < 0)); then
  echo "NUM_INSTANCES and FILES_PER_INSTANCE must be positive; START_INDEX must be non-negative" >&2
  exit 1
fi

mapfile -t FILES < "${FILE_LIST}"

if ((${#FILES[@]} == 0)); then
  echo "No input files found in ${FILE_LIST}" >&2
  exit 1
fi

mkdir -p "${RUN_DIR}"

pids=()
instances=()

for ((instance = 0; instance < NUM_INSTANCES; instance++)); do
  start=$((START_INDEX + instance * FILES_PER_INSTANCE))
  if ((start >= ${#FILES[@]})); then
    break
  fi

  batch=("${FILES[@]:start:FILES_PER_INSTANCE}")
  workdir="${RUN_DIR}/athena_${instance}"
  mkdir -p "${workdir}"
  printf '%s\n' "${batch[@]}" > "${workdir}/input_files.txt"

  (
    cd "${workdir}"
    Derivation_tf.py \
      --CA "all:True" \
      --inputAODFile "${batch[@]}" \
      --athenaMPMergeTargetSize "DAOD_*:0" \
      --multiprocess True --sharedWriter True \
      --formats PHYS \
      --outputDAODFile "DAOD_PHYS_${instance}.pool.root" \
      --multithreadedFileValidation True \
      --postInclude 'default:AthenaServices.TransformUtils.ExecCondAlgsAtPreFork' \
      --parallelCompression False \
      --perfmon fullmonmt \
      --preExec "flags.Output.TreeAutoFlush={\"DAOD_PHYS\": 80};flags.BTagging.UseTriton=True;" \
      --postExec "NNSharingSvcTriton=cfg.getService(\"FTagNNSharingTritonSvc\");NNSharingSvcTriton.TritonUrl=\"${TRITON_URL}\";NNSharingSvcTriton.TritonPort=${TRITON_PORT}"
  ) > "${workdir}/athena.log" 2>&1 &

  pids+=("$!")
  instances+=("${instance}")
  echo "Started Athena instance ${instance} with ${#batch[@]} file(s); log: ${workdir}/athena.log"
done

if ((${#pids[@]} == 0)); then
  echo "No Athena instances started; START_INDEX=${START_INDEX} is past the end of ${FILE_LIST}" >&2
  exit 1
fi

status=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    echo "Athena instance ${instances[$i]} finished successfully"
  else
    echo "Athena instance ${instances[$i]} failed; see ${RUN_DIR}/athena_${instances[$i]}/athena.log" >&2
    status=1
  fi
done

exit "${status}"
