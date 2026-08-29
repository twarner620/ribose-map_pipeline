# ribose-map_pipeline

Multi-sample wrapper around the Ribose-Map module scripts.

## What this adds
- Runs many samples from one sample sheet instead of one config at a time.
- Treats each run as fresh (no implicit skip-if-complete behavior for trimming/mismatch fastq prep).
- Cleans up temporary mismatch FASTQ copies after mismatch completes/fails (can be disabled with `--keep-mismatch-fastq`).
- Supports per-sample platform inference and trimming:
  - illumina: use `read1` and `trim_galore <read1> -a AGTTGCGACACGGATCTATCA -q 15 --length 62`
  - aviti: use `read2` and `trim_galore <read2> -a AGTTGACAAGCGGTAGCCTGCACACCTTCCGACAT -q 15 --length 50`
- Adds a platform-aware `mismatch` module (using your Illumina vs AVITI mismatch-analysis repos).
- Keeps shared settings in one base config.
- Generates one per-sample config automatically (`config/generated/<sample>.config`).
- Supports per-sample `barcode` and `read1` (and optional `read2`).

## Repo layout
- `modules/`: Ribose-Map scripts copied from `ribose-map/modules`.
- `scripts/run_multi_sample.sh`: multi-sample runner.
- `scripts/slurm_array_task.sh`: one-sample task entrypoint for Slurm arrays.
- `scripts/submit_slurm_array.sh`: submits one Slurm array task per sample.
- `scripts/submit_slurm_single.sh`: submits one Slurm task from a legacy single-sample config.
- `config/legacy_single_sample.template.config`: template for original single-config style runs.
- `config/base.config`: shared settings for all samples.
- `config/samples.tsv`: sample sheet template.

## Sample sheet format
Tab-delimited file with header:

`sample<TAB>barcode<TAB>read1[<TAB>read2]`

Notes:
- Enter the observed/original barcode sequence in `barcode`; the pipeline reverse-complements it automatically before alignment.
- Use `-` in `barcode` if no barcode is used for that sample.
- Platform is inferred per row:
  - illumina if only `read1` is provided
  - aviti if only `read2` is provided
- Exactly one of `read1` or `read2` must be provided for each sample.
- `mismatch` requires coordinate output (`coordinate` should run before `mismatch`).

## Run
1. Edit `config/base.config` with real paths and settings.
2. Edit `config/samples.tsv` with your samples.
3. Ensure `trim_galore` is available in your environment.
4. Run:

```bash
scripts/run_multi_sample.sh \
  -s config/samples.tsv \
  -b config/base.config \
  -m trimming,alignment,coordinate,mismatch,composition,sequence,distribution,hotspot \
  -j 1
```

## Run On Different Nodes (Slurm Array)
Use the Slurm submit helper to run one sample per array task so samples can be scheduled across different nodes.

```bash
scripts/submit_slurm_array.sh \
  -s config/Run22026.samples.tsv \
  -b config/Run22026.config \
  -m trimming,alignment,coordinate,mismatch \
  -A gts-fstorici3 \
  -p batch \
  -q embers \
  --cpus-per-task 16 \
  --mem 100G \
  --sample-log-dir logs/samples \
  --run-date 20260220 \
  --array-parallel 8
```

Notes:
- `--array-parallel` caps concurrent samples.
- `--cpus-per-task` should usually match `threads` in your base config.
- `--sample-log-dir` writes per-sample combined stdout/stderr logs as `<sample>_<run-date>.log`.
- `-q/--qos` chooses the Slurm QoS (for example `embers` or `inferno`).
- You do not need multi-node directives in `ribosemap.sbatch` for this mode; submit from login node.

## Run One Sample From Legacy Single Config (Slurm)
If you already have a single-sample config (with `sample`, `barcode`, and exactly one of `read1`/`read2`),
you can submit one task directly without a samples manifest:

```bash
scripts/submit_slurm_single.sh \
  -c config/generated/FS498.config \
  -m mismatch \
  -A gts-fstorici3 \
  -p cpu-small \
  -q embers \
  --cpus-per-task 16 \
  --mem 100G
```

## Options

```text
-s  sample sheet (required)
-b  base config (required)
-m  comma-separated modules (default: trimming,alignment,coordinate,mismatch,removeMXY,composition,sequence,distribution,hotspot)
    Use/omit `trimming` to control whether trim_galore runs in this invocation.
-j  number of samples to run in parallel (default: 1)
-o  generated config output directory (default: config/generated)
    --keep-mismatch-fastq keep temporary mismatch FASTQ under results/<sample>/mismatch/input_fastq
```

## Example: only alignment + coordinate

```bash
scripts/run_multi_sample.sh \
  -s config/samples.tsv \
  -b config/base.config \
  -m trimming,alignment,coordinate,mismatch \
  -j 2
```
