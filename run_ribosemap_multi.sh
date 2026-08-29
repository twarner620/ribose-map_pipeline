#!/usr/bin/env bash
TIME_LIMIT="${1:-08:00:00}"

scripts/submit_slurm_array.sh \
  -s config/Run080626.samples.tsv \
  -b config/Run080626.config \
  -m trimming, alignment, coordinate, mismatch \
  -A gts-fstorici3 \
  -p batch \
  -q embers \
  -t "${TIME_LIMIT}" \
  --cpus-per-task 16 \
  --mem 100G \
  --sample-log-dir logs/samples \
  --run-date "$(date +%Y%m%d)" \
  --array-parallel 8

# -m trimming,alignment,coordinate,mismatch
