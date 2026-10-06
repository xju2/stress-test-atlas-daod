#!/bin/bash
# Standalone: sparse-checkout the gn3large-in-athena Athena branch, build it,
# and run an FTAG1 derivation with the local GN3Large ONNX model.
#
# Usage:
#   ./build_and_run.sh                   # default work dir = ~/gn3large-athena
#   WORK_DIR=/tmp/foo ./build_and_run.sh
#   STAGE=checkout ./build_and_run.sh    # or build / run / all (default)
#   MAX_EVENTS=5 ./build_and_run.sh
#   AOD_INPUT=/path/to/AOD.pool.root ./build_and_run.sh
#
# Requires an interactive shell where `setupATLAS` is defined (i.e. ~/.bashrc
# sourced). If your shell is non-interactive, the script sources
# atlasLocalSetup.sh directly from CVMFS instead.

set -euo pipefail

# ---- Configuration ----------------------------------------------------------

FORK_URL="${FORK_URL:-ssh://git@gitlab.cern.ch:7999/npond/athena.git}"
BRANCH="${BRANCH:-gn3large-in-athena}"
ATHENA_RELEASE="${ATHENA_RELEASE:-Athena,main,latest}"

WORK_DIR="${WORK_DIR:-${HOME}/gn3large-athena}"
SOURCE_DIR="${WORK_DIR}/source"
BUILD_DIR="${WORK_DIR}/build"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Model should be stored in $CALIB_DIR/BTagging/20260320/GN3Large/antikt4empflow/network.onnx
# which is $SCRIPT_DIR/calibration/
CALIB_DIR="${CALIB_DIR:-${SCRIPT_DIR}/calibration}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/outputs}"

AOD_INPUT="${AOD_INPUT:-/data/atlas_samples/AOD/mc23_13p6TeV.601589.PhPy8EG_A14_ttbar_hdamp258p75_nonallhadron.recon.AOD.e8549_s4159_r15530/AOD.42006316._000370.pool.root}"
MAX_EVENTS="${MAX_EVENTS:-50}"

STAGE="${STAGE:-all}"
NPROC="$(nproc 2>/dev/null || echo 4)"

SPARSE_PATHS=(
    "Projects/WorkDir"
    "PhysicsAnalysis/JetTagging/JetTagConfig"
    "PhysicsAnalysis/JetTagging/FlavorTagInference"
    "PhysicsAnalysis/DerivationFramework/DerivationFrameworkFlavourTag"
)

# ---- Helpers ----------------------------------------------------------------

setup_atlas() {
    set +eu
    export ATLAS_LOCAL_ROOT_BASE=/cvmfs/atlas.cern.ch/repo/ATLASLocalRootBase
    echo "[setup_atlas] sourcing atlasLocalSetup.sh (CVMFS, may pause if cache is cold)..."
    source "${ATLAS_LOCAL_ROOT_BASE}/user/atlasLocalSetup.sh"
    echo "[setup_atlas] running asetup ${ATHENA_RELEASE} (can take 1-2 min cold)..."
    asetup "${ATHENA_RELEASE}"
    echo "[setup_atlas] done. AtlasProject=${AtlasProject:-?} AtlasVersion=${AtlasVersion:-?}"
    set -eu
}

# ---- Stages -----------------------------------------------------------------

do_checkout() {
    echo "=== Sparse-checkout ${BRANCH} into ${SOURCE_DIR} ==="
    mkdir -p "${WORK_DIR}"
    if [[ -d "${SOURCE_DIR}/.git" ]]; then
        echo "Source already exists, fetching latest..."
        git -C "${SOURCE_DIR}" fetch origin "${BRANCH}"
        git -C "${SOURCE_DIR}" checkout "${BRANCH}"
        git -C "${SOURCE_DIR}" reset --hard "origin/${BRANCH}"
    else
        git clone --no-checkout "${FORK_URL}" "${SOURCE_DIR}"
        git -C "${SOURCE_DIR}" sparse-checkout init --cone
        git -C "${SOURCE_DIR}" sparse-checkout set "${SPARSE_PATHS[@]}"
        git -C "${SOURCE_DIR}" checkout "${BRANCH}"
    fi
    echo "HEAD: $(git -C "${SOURCE_DIR}" rev-parse --short HEAD)"
}

do_build() {
    echo "=== Building Athena WorkDir into ${BUILD_DIR} ==="
    setup_atlas
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    local cmake_log="${BUILD_DIR}/cmake.log"
    local make_log="${BUILD_DIR}/make.log"
    echo "--- cmake (log: ${cmake_log}) ---"
    # stdbuf -> line-buffered output so progress appears live, not in bursts
    stdbuf -oL -eL cmake "${SOURCE_DIR}/Projects/WorkDir" 2>&1 | tee "${cmake_log}"

    echo "--- make -j${NPROC} (log: ${make_log}) ---"
    # -Otarget keeps each target's output grouped; piping forces non-tty so make
    # would normally hide progress. -Otarget + tee gives readable interleaved logs.
    stdbuf -oL -eL make -j"${NPROC}" -Otarget 2>&1 | tee "${make_log}"

    # tee swallows the real exit code; recover it from PIPESTATUS
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
        echo "make failed with exit code $rc (see ${make_log})" >&2
        return $rc
    fi
}

do_run() {
    echo "=== Running FTAG1 derivation ==="
    setup_atlas
    # Overlay our modified packages on top of the base release
    set +eu
    source "${BUILD_DIR}"/*/setup.sh 2>/dev/null || source "${BUILD_DIR}/setup.sh"
    set -eu

    export CALIBPATH="${CALIB_DIR}:${CALIBPATH:-}"
    echo "CALIBPATH prepended with: ${CALIB_DIR}"
    echo "AOD input: ${AOD_INPUT}"
    echo "Max events: ${MAX_EVENTS}"

    mkdir -p "${OUTPUT_DIR}"
    cd "${OUTPUT_DIR}"
    Derivation_tf.py \
        --inputAODFile "${AOD_INPUT}" \
        --outputDAODFile DAOD_FTAG1.pool.root \
        --formats FTAG1 \
        --maxEvents "${MAX_EVENTS}" \
        2>&1 | tee "${OUTPUT_DIR}/derivation.log"
}

# ---- Dispatch ---------------------------------------------------------------

case "${STAGE}" in
    checkout) do_checkout ;;
    build)    do_build ;;
    run)      do_run ;;
    all)      do_checkout; do_build; do_run ;;
    *) echo "Unknown STAGE: ${STAGE} (expected: checkout|build|run|all)" >&2; exit 1 ;;
esac

echo "=== Done (stage: ${STAGE}) ==="
