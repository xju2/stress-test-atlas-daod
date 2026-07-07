# stress-test-atlas-daod
Scripts for stress testing ATLAS DAOD production with IaaS.

## Scripts

- `run.sh`: launches multiple local Athena instances against a Triton endpoint.
- `run_stress_node.sh`: computes the per-node file offset for a Slurm array task and runs `run.sh`.
- `submit_stress.slurm`: NERSC Perlmutter CPU-node Slurm array submit script.

## Single-node test

```bash
NUM_INSTANCES=16 FILES_PER_INSTANCE=1 ./run.sh
```

By default, the scripts target:

```text
triton-cluster-svc.ml4phys.com:443
```

Useful overrides:

```bash
ATHENA_PROC_NUMBER=4 ATHENA_CORE_NUMBER=4 NUM_INSTANCES=32 ./run.sh
TRITON_URL=other-host.example.org TRITON_PORT=443 ./run.sh
```

## NERSC large-scale test

Submit one Perlmutter CPU node:

```bash
sbatch submit_stress.slurm
```

Submit eight CPU nodes:

```bash
sbatch --array=0-7 submit_stress.slurm
```

Each array task uses one CPU node and defaults to 16 Athena instances per node:

```text
16 Athena instances/node * 8 Athena cores/instance = 128 cores/node
```

Override the scaling knobs at submit time:

```bash
sbatch --array=0-15 \
  --export=ALL,NUM_INSTANCES=16,FILES_PER_INSTANCE=1,ATHENA_PROC_NUMBER=8 \
  submit_stress.slurm
```

Outputs are written under:

```text
$SCRATCH/triton_stress_<jobid>/node_<array_task>/athena_<instance>/athena.log
```
