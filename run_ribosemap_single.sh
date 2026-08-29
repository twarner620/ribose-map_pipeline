#!/usr/bin/env bash
TIME_LIMIT="08:00:00"

scripts/submit_slurm_single.sh \
  -c config/FS185.config \
  -m trimming,alignment,coordinate,mismatch \
  -A gts-fstorici3 \
  -p cpu-small \
  -q embers \
  -t "${TIME_LIMIT}" \
  --cpus-per-task 16 \
  --mem 100G \
  --sample-log-dir logs/samples \
  --run-date "$(date +%Y%m%d)"
