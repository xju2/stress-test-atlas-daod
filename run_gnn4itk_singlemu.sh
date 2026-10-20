#!/bin/bash

export RANK=$SLURM_PROCID
export NCPU=$SLURM_CPUS_ON_NODE
export ATHENA_CORE_NUMBER=$SLURM_CPUS_PER_TASK
export PATH=/cvmfs/sft.cern.ch/lcg/contrib/ninja/1.11.1/Linux-x86_64/bin:$PATH
echo ON RANK $SLURM_PROCID OF $SLURM_NTASKS ON $SLURM_NNODES NODES. USING $ATHENA_CORE_NUMBER CORES.
source /global/cfs/cdirs/atlas/scripts/setupATLAS.sh
setupATLAS

asetup Athena,25.0.47,here

mkdir testarea 
cd testarea
rm -rf rank-$RANK; mkdir rank-$RANK; cd rank-$RANK

RDO_FILES=( /global/cfs/cdirs/m3443/data/GNN4ITK/RDOFiles/mc21_14TeV.601190.PhPy8EG_AZNLO_Zmumu.recon.RDO.e8481_s4203_r14701/*.root.1 )
RDO_FILENAME=$(IFS=,; echo "${RDO_FILES[*]}")

TRITON_MODEL_NAME='DoubleMetricLearning'
TRITON_URL=triton-cluster-svc.ml4phys.com
TRITON_PORT=443

Reco_tf.py --CA 'all:True' \
  --autoConfiguration 'everything' \
  --conditionsTag 'all:OFLCOND-MC15c-SDR-14-05' \
  --geometryVersion 'all:ATLAS-P2-RUN4-03-00-00' \
  --mpi --multithreaded \
  --steering 'doRAWtoALL' \
  --digiSteeringConf 'StandardInTimeOnlyTruth' \
  --postInclude 'all:PyJobTransforms.UseFrontier' \
  --preExec "all:flags.ITk.doEndcapEtaNeighbour=True; flags.Tracking.ITkGNNPass.minClusters = [7,7,7]; flags.Tracking.ITkGNNPass.maxHoles = [4,4,2]; flags.Tracking.GNN.Triton.model = \"$TRITON_MODEL_NAME\"; flags.Tracking.GNN.Triton.url = \"$TRITON_URL\"; flags.Tracking.GNN.Triton.port = ${TRITON_PORT}" \
  --preInclude 'all:Campaigns.MC23PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' 'InDetGNNTracking.InDetGNNTrackingFlags.gnnTritonValidation' \
  --inputRDOFile="${RDO_FILENAME}" \
  --outputAODFile="OUTFILE.[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23].AOD.pool.root" --athenaopts='--loglevel=INFO'
  # --outputAODFile="OUTFILE.A.AOD.pool.root" --athenaopts='--loglevel=INFO --concurrent-events=1'
