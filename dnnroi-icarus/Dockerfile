# perf_analyzer pip wheels need glibc >= 2.38; zeus (EL9) has 2.34, so run it in Ubuntu 24.04.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip iputils-ping curl ca-certificates \
 && pip install --no-cache-dir --break-system-packages perf-analyzer==2.60.0 "tritonclient[grpc]" numpy \
 && rm -rf /var/lib/apt/lists/*
