# GN3Large Model

Model checkpoint: `/eos/atlas/atlascerngroupdisk/perf-flavtag/algs/models/TN25_86M/`
is copied to NERSC: `/global/cfs/cdirs/m3443/usr/xju/data/GN3Large`.

```
/global/cfs/cdirs/m3443/usr/xju/data/GN3Large
├── class_dict.yaml
├── config.yaml
├── epoch=007-val_loss=0.30648.ckpt
├── GN3Large.onnx
├── metadata.yaml
├── norm_dict.yaml
└── to_onnx_GN3Large.log
```

## Studies

### One GPU
1. Throughput as a function of batch size (to find the maximum batch size that can saturate the GPU utilization / memory)
2. Throughput as a funciton of model instance
3. Throughput as a function of concurrent requests

### More than one GPUs
1. Total throughput as a funciton of concurrent requests