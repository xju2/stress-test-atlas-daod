#!/bin/bash
#SBATCH -A m3443
#SBATCH -C cpu
#SBATCH -q interactive
#SBATCH -J gnn4itk-singlemu
#SBATCH -N 4
#SBATCH -t 4:00:00
#SBATCH -o %x-%j.out
#SBATCH --mail-user=xju@lbl.gov
#SBATCH --mail-type=ALL

## GNN4ITK single-muon reconstruction spread over many CPU nodes.
##
## srun starts one task per node inside the Shifter container. Each task sets up
## Athena once, then (as in run.sh) launches NUM_INSTANCES independent
## multi-threaded Reco_tf.py jobs in the background, waits for them and reports
## failures. Every instance on every node processes its own contiguous slice of
## the input events (400 files x 500 events).
##
## Each Athena thread runs one event, so events in flight (~ concurrent Triton
## requests) = nodes x NUM_INSTANCES x ATHENA_CORE_NUMBER.
## Default: 4 nodes x 4 instances x 64 threads = 1024.
##
## Interactive QOS (salloc only, up to 4 nodes):
##   salloc -N 4 -C cpu -q interactive -t 4:00:00 -A m3443
##   ./run_gnn4itk_singlemu.sh
## Fewer, bigger instances (128 threads each):
##   NUM_INSTANCES=2 ./run_gnn4itk_singlemu.sh
## Threads mostly wait on Triton, so they can oversubscribe the 256 CPUs:
##   ATHENA_CORE_NUMBER=128 ./run_gnn4itk_singlemu.sh   # 2048 events in flight
## ttbar events:
##   RDO_DIR=/global/cfs/cdirs/m3443/data/GNN4ITK/RDOFiles/mc21_14TeV.601229.PhPy8EG_A14_ttbar_hdamp258p75_SingleLep.recon.RDO.e8481_s4149_r15238 ATHENA_CORE_NUMBER=128 EVENTS_PER_FILE=50 ./run_gnn4itk_singlemu.sh
## Batch submission scales to more nodes:
##   sbatch -N 64 -q regular -t 2:00:00 run_gnn4itk_singlemu.sh
##
## Useful knobs (environment variables):
##   NUM_INSTANCES=4        Athena jobs per node
##   ATHENA_CORE_NUMBER=N   threads per Athena job (default 256 / NUM_INSTANCES)
##   FILE_LIST=/path.txt    input RDO files, one per line (default: RDO_DIR/*.root.1)
##   RDO_DIR=/path/to/RDOs
##   EVENTS_PER_FILE=500    events in each RDO file
##   RUN_DIR=$SCRATCH/...   output root: $RUN_DIR/node_<n>/athena_<i>/athena.log
##   TRITON_URL / TRITON_PORT / TRITON_MODEL_NAME
##   CONTAINER_IMAGE=docker:beojan/mpialma9:latest   (Shifter image)
##
## The same file is the per-node payload: srun runs it again with --worker
## inside the Shifter container (which inherits the host environment and mounts
## /global and $SCRATCH; cvmfs comes from --module=cvmfs).

SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
# sbatch runs a copy from the spool directory; use the submitted file instead.
if [[ "$(basename "${SCRIPT}")" == slurm_script && "${1:-}" != "--worker" ]]; then
  SCRIPT="$(scontrol show job "${SLURM_JOB_ID}" | sed -n 's/^ *Command=\([^ ]*\).*/\1/p')"
fi

export RDO_DIR="${RDO_DIR:-/global/cfs/cdirs/m3443/data/GNN4ITK/RDOFiles/mc21_14TeV.900495.PG_single_muonpm_Pt10_etaFlatnp0_43.recon.RDO.e8557_s4422_r16128}"
export TRITON_MODEL_NAME="${TRITON_MODEL_NAME:-DoubleMetricLearning}"
export TRITON_URL="${TRITON_URL:-triton-cluster-svc.ml4phys.com}"
export TRITON_PORT="${TRITON_PORT:-443}"
export EVENTS_PER_FILE="${EVENTS_PER_FILE:-500}"
export NUM_INSTANCES="${NUM_INSTANCES:-4}"
export ATHENA_CORE_NUMBER="${ATHENA_CORE_NUMBER:-$((256 / NUM_INSTANCES))}"

if [[ "${1:-}" != "--worker" ]]; then
  ## ---- Launcher: runs once in the batch step / salloc shell ----
  set -euo pipefail
  if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    echo "Run inside 'salloc -N <nodes> -C cpu -q interactive ...' or submit with 'sbatch ${SCRIPT}'" >&2
    exit 1
  fi
  if ((NUM_INSTANCES <= 0 || ATHENA_CORE_NUMBER <= 0)); then
    echo "NUM_INSTANCES and ATHENA_CORE_NUMBER must be positive" >&2
    exit 1
  fi

  # One fresh directory per job on a filesystem shared by all nodes.
  export RUN_DIR="${RUN_DIR:-${SCRATCH}/gnn4itk_singlemu_${SLURM_JOB_ID}}"
  mkdir -p "${RUN_DIR}"
  CONTAINER_IMAGE="${CONTAINER_IMAGE:-docker:beojan/mpialma9:latest}"

  echo "Running ${SLURM_JOB_NUM_NODES} nodes x ${NUM_INSTANCES} Athena instances/node x ${ATHENA_CORE_NUMBER} threads/instance"
  echo "Events in flight: $((SLURM_JOB_NUM_NODES * NUM_INSTANCES * ATHENA_CORE_NUMBER))"
  echo "Run directory: ${RUN_DIR}"
  ulimit -n 4096

  srun -N "${SLURM_JOB_NUM_NODES}" --ntasks-per-node=1 -c 256 --cpu-bind=none \
    shifter --image="${CONTAINER_IMAGE}" --module=cvmfs "${SCRIPT}" --worker \
    2>&1 | tee "${RUN_DIR}/log.reco.txt"
  exit "${PIPESTATUS[0]}"
fi

## ---- Worker: one per node, inside the container ----
NODE_INDEX=$SLURM_PROCID
NUM_NODES=$SLURM_NTASKS
NODE_DIR="${RUN_DIR}/node_${NODE_INDEX}"
mkdir -p "${NODE_DIR}"
cd "${NODE_DIR}"

export PATH=/cvmfs/sft.cern.ch/lcg/contrib/ninja/1.11.1/Linux-x86_64/bin:$PATH
source /global/cfs/cdirs/atlas/scripts/setupATLAS.sh
setupATLAS

# asetup Athena,25.0.67,here
asetup Athena,25.0.75,here

if [[ -n "${FILE_LIST:-}" ]]; then
  mapfile -t RDO_FILES < "${FILE_LIST}"
else
  RDO_FILES=( "${RDO_DIR}"/*.root.1 )
fi
if ((${#RDO_FILES[@]} == 0)); then
  echo "No input files found" >&2
  exit 1
fi

# Instance -> global event range [first, last) over all files; only the files
# that range touches are passed in, with the skip relative to the first of them.
TOTAL_INSTANCES=$((NUM_NODES * NUM_INSTANCES))
TOTAL_EVENTS=$((${#RDO_FILES[@]} * EVENTS_PER_FILE))
EVENTS_PER_INSTANCE=$(((TOTAL_EVENTS + TOTAL_INSTANCES - 1) / TOTAL_INSTANCES))


# Run-4 defaults to CREST, which lacks OFLCOND-MC15c-SDR-14-05.
# Set UseCREST=False below to keep this COOL tag and use Frontier access.
function gnn4itk_cmd() {
  local RDO_FILENAME="$1"
  local SKIP_EVENTS="$2"
  local MAX_EVENTS="$3"

  Reco_tf.py --CA 'all:True' \
  --autoConfiguration 'everything' \
  --conditionsTag 'all:OFLCOND-MC15c-SDR-14-05' \
  --geometryVersion 'all:ATLAS-P2-RUN4-03-00-00' \
  --multithreaded \
  --steering 'doRAWtoALL' \
  --digiSteeringConf 'StandardInTimeOnlyTruth' \
  --postInclude 'all:PyJobTransforms.UseFrontier' \
  --preExec "all:flags.IOVDb.UseCREST=False; all:flags.ITk.doEndcapEtaNeighbour=True; flags.Tracking.ITkGNNPass.minClusters = [7,7,7]; flags.Tracking.ITkGNNPass.maxHoles = [4,4,2]; flags.Tracking.GNN.Triton.model = \"$TRITON_MODEL_NAME\"; flags.Tracking.GNN.Triton.url = \"$TRITON_URL\"; flags.Tracking.GNN.Triton.port = ${TRITON_PORT}" \
  --preInclude 'all:Campaigns.MC23PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' 'InDetGNNTracking.InDetGNNTrackingFlags.gnnTritonValidation' \
  --inputRDOFile="${RDO_FILENAME}" \
  --skipEvents="${SKIP_EVENTS}" --maxEvents="${MAX_EVENTS}" \
  --outputAODFile="OUTFILE.AOD.pool.root" --athenaopts='--loglevel=INFO'
}

pids=()
instances=()

for ((instance = 0; instance < NUM_INSTANCES; instance++)); do
  global=$((NODE_INDEX * NUM_INSTANCES + instance))
  first=$((global * EVENTS_PER_INSTANCE))
  if ((first >= TOTAL_EVENTS)); then
    break
  fi
  last=$((first + EVENTS_PER_INSTANCE < TOTAL_EVENTS ? first + EVENTS_PER_INSTANCE : TOTAL_EVENTS))
  first_file=$((first / EVENTS_PER_FILE))
  last_file=$(((last - 1) / EVENTS_PER_FILE))
  batch=("${RDO_FILES[@]:first_file:last_file - first_file + 1}")

  workdir="${NODE_DIR}/athena_${instance}"
  mkdir -p "${workdir}"
  printf '%s\n' "${batch[@]}" > "${workdir}/input_files.txt"

  (
    cd "${workdir}"
    gnn4itk_cmd "$(IFS=,; echo "${batch[*]}")" $((first - first_file * EVENTS_PER_FILE)) $((last - first))
  ) > "${workdir}/athena.log" 2>&1 &

  pids+=("$!")
  instances+=("${instance}")
  echo "Node ${NODE_INDEX} ($(hostname)): started instance ${instance} with ${ATHENA_CORE_NUMBER} threads, events [${first}, ${last}) from files ${first_file}-${last_file}; log: ${workdir}/athena.log"
done

if ((${#pids[@]} == 0)); then
  echo "Node ${NODE_INDEX}: no events left, nothing to do"
  exit 0
fi

status=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    echo "Node ${NODE_INDEX}: Athena instance ${instances[$i]} finished successfully"
  else
    echo "Node ${NODE_INDEX}: Athena instance ${instances[$i]} failed; see ${NODE_DIR}/athena_${instances[$i]}/athena.log" >&2
    status=1
  fi
done

exit "${status}"
