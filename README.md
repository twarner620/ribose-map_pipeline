# ribose-map_pipeline

Multi-sample wrapper around the Ribose-Map module scripts.

## What this adds
- Runs many samples from one sample sheet instead of one config at a time.
- Treats each run as fresh (no implicit skip-if-complete behavior for trimming/mismatch fastq prep).
- Cleans up temporary mismatch FASTQ copies after mismatch completes/fails (can be disabled with `--keep-mismatch-fastq`).
- Supports per-sample input layouts and technique-aware trimming:
  - `read1` only: single-end input using `read1`
  - `read2` only: single-end input using `read2` with the AVITI trim profile
  - `read1` + `read2`: paired-end input
  - `ribose-seq` uses `trim_galore -a AGTTGCGACACGGATCTATCA -q 15 --length 62`
  - `emRiboSeq` uses `trim_galore --illumina -q 15 --length 50`
  - paired `RHII-HydEn-seq` uses `trim_galore --paired --illumina -q 15 --length 30`
  - `Alk-HydEn-seq` and `Pu-seq` bypass wrapper trimming
- Adds a wrapper-managed `re_correct` module backed by `ArtificialRiboseDetection`.
- Adds a platform-aware `mismatch` module (using your Illumina vs AVITI mismatch-analysis repos).
- Keeps shared settings in one base config.
- Generates one per-sample config automatically (`config/generated/<sample>.config`).
- Supports per-sample `barcode`, `technique`, `pattern`, `frag_method`, `read1`, and `read2`.

## Repo layout
- `modules/`: Ribose-Map scripts copied from `ribose-map/modules`.
- `submodules/ArtificialRiboseDetection`: external restriction-enzyme correction helper.
- `scripts/run_multi_sample.sh`: multi-sample runner.
- `scripts/slurm_array_task.sh`: one-sample task entrypoint for Slurm arrays.
- `scripts/submit_slurm_array.sh`: submits one Slurm array task per sample.
- `scripts/submit_slurm_single.sh`: submits one Slurm task from a legacy single-sample config.
- `config/legacy_single_sample.template.config`: template for original single-config style runs.
- `config/base.config`: shared settings for all samples.
- `config/samples.tsv`: sample sheet template.

## Sample sheet format
Tab-delimited file with header:

`sample<TAB>barcode<TAB>read1[<TAB>read2<TAB>technique<TAB>pattern<TAB>frag_method]`

Notes:
- Enter the observed/original barcode sequence in `barcode`; the pipeline reverse-complements it automatically before alignment.
- Use `-` in `barcode` if no barcode is used for that sample.
- Input layout is inferred per row:
  - `read1` only -> single-end input using `read1`
  - `read2` only -> single-end input using `read2`
  - `read1` + `read2` -> paired-end input
- `technique` overrides the base-config `technique` for that sample. Use `-` or omit the column to keep the base-config value.
- `pattern` overrides the base-config `pattern` for that sample. Use `-` or leave it empty to disable UMI extraction.
- `frag_method` is only used by `re_correct`. For non-`ribose-seq` rows use `NA`.
- `re_correct` skips `ribose-seq` rows whose `frag_method` is `NA`, `dsF`, or `mech`.
- Trimming is inferred from `technique` and `pattern`.
- For `ribose-seq`, wrapper trimming is only applied when `pattern` is non-empty.
- For `emRiboSeq`, wrapper trimming uses the paper-style `--illumina -q 15 --length 50` command.
- For paired `RHII-HydEn-seq`, wrapper trimming uses `--paired --illumina -q 15 --length 30`.
- For `Alk-HydEn-seq` and `Pu-seq`, wrapper trimming is skipped.
- `re_correct` derives the external tool's `-d` offset from the length of `pattern`.
- `re_correct` uses the trimmed single-end FASTQ when trimming is available for the sample; otherwise it falls back to the original single-end input FASTQ.
- `coordinate##/<sample>.bed` is always the unmodified coordinate-module BED. Post-coordinate outputs are isolated beneath that same directory: `coordinate##/re_correct/`, `coordinate##/mismatch/`, and `coordinate##/final/`. For an eligible restriction-digested `ribose-seq` sample, `mismatch` reads `coordinate##/re_correct/<sample>.bed`; otherwise it reads the coordinate BED directly.
- Each completed sample workflow writes a copy of its terminal BED to `coordinate##/final/<sample>.bed`:
  - restriction-digested `ribose-seq`: coordinate -> `re_correct` -> mismatch
  - `ribose-seq` with `frag_method=dsF` or `mech`: coordinate -> mismatch
  - `emRiboSeq`, `RHII-HydEn-seq`, `Alk-HydEn-seq`, and `Pu-seq`: coordinate only
- A `ribose-seq` run that does not include `mismatch` leaves `final/` pending rather than labelling an intermediate BED as final.
- At least one of `read1` or `read2` must be provided for each sample.
- `mismatch` requires coordinate output (`coordinate` should run before `mismatch`) and runs only for `ribose-seq` rows. It is skipped for the other techniques, whose final BED is the coordinate result.

## Setup
Clone the repository:

```bash
git clone https://github.com/twarner620/ribose-map_pipeline.git
cd ribose-map_pipeline
```

Initialize the external helper submodule:

```bash
git submodule update --init --recursive
```

If you cloned without `--recursive`, the command above is required before running the wrapper. If you want the submodule on first clone, use:

```bash
git clone --recursive https://github.com/twarner620/ribose-map_pipeline.git
cd ribose-map_pipeline
```

## Run
1. Edit `config/base.config` with real paths and settings.
2. Edit `config/samples.tsv` with your samples.
3. Ensure `trim_galore` is available in your environment.
4. Run:

```bash
scripts/run_multi_sample.sh \
  -s config/samples.tsv \
  -b config/base.config \
  -m trimming,alignment,coordinate,re_correct,mismatch,composition,sequence,distribution,hotspot \
  -j 1
```

## Run On Different Nodes (Slurm Array)
Use the Slurm submit helper to run one sample per array task so samples can be scheduled across different nodes.

```bash
scripts/submit_slurm_array.sh \
  -s config/Run22026.samples.tsv \
  -b config/Run22026.config \
  -m trimming,alignment,coordinate,re_correct,mismatch \
  -A gts-fstorici3 \
  -p batch \
  -q embers \
  --cpus-per-task 16 \
  --mem 100G \
  --sample-log-dir logs/samples \
  --run-id 20260220_143000 \
  --array-parallel 8
```

Notes:
- `--array-parallel` caps concurrent samples.
- `--cpus-per-task` should usually match `threads` in your base config.
- Every run receives a `YYYYMMDD_HHMMSS` ID by default. The runner appends it to the base config's `repository` value, preserving prior outputs rather than overwriting them.
- `--run-id` sets that ID explicitly when related submissions must share one output directory. `--run-date` remains a legacy alias.
- `--sample-log-dir` writes per-sample combined stdout/stderr logs as `<sample>_<run-id>_<job-id>_<task-id>.log`.
- Alignment retries once by default only when its node-local work directory disappears. Set optional base-config `alignment_max_attempts` to change the total attempts.
- `samtools sort` uses `SLURM_CPUS_PER_TASK` when available (otherwise `threads`) and `2G` per sort thread. Set `SAMTOOLS_SORT_MEMORY_PER_THREAD` in the job environment to override the memory value.
- `-q/--qos` chooses the Slurm QoS (for example `embers` or `inferno`).
- You do not need multi-node directives in `ribosemap.sbatch` for this mode; submit from login node.

## Run One Sample From Legacy Single Config (Slurm)
If you already have a single-sample config (with `sample`, `barcode`, and exactly one of `read1`/`read2`),
you can submit one task directly without a samples manifest:

```bash
scripts/submit_slurm_single.sh \
  -c config/generated/FS498.config \
  -m re_correct,mismatch \
  -A gts-fstorici3 \
  -p cpu-small \
  -q embers \
  --cpus-per-task 16 \
  --mem 100G
```

## Coordinate0 For rDNA-Associated Reads

`quality` is the coordinate module's MAPQ threshold, not an alignment
parameter. Existing final BAMs can therefore be reprocessed without rerunning
trimming or alignment. Use the standalone helper to submit a coordinate-only
array at MAPQ 0:

```bash
RUN_ID="$(date +%Y%m%d_%H%M%S)"

scripts/run_ribosomal.sh -Q 0 \
  -s config/Mo_libraries.ribose-seq.samples.tsv \
  -b config/Mo_libraries.base.config \
  -A gts-fstorici3 -p batch -q embers -t 06:00:00 \
  --cpus-per-task 8 --mem 48G \
  -o "config/generated/Mo_libraries_${RUN_ID}/coordinate0" \
  --job-name mo-libraries-coordinate0 \
  --log-dir "logs/Mo_libraries_${RUN_ID}/coordinate0" \
  --sample-log-dir "logs/Mo_libraries_${RUN_ID}/coordinate0/samples" \
  --run-id "${RUN_ID}" \
  --array-parallel 8
```

The helper sets `-m coordinate` and `--coordinate-quality 0`; it does not
rerun trimming or alignment. It creates `results/<sample>/coordinate0/`
alongside the existing `coordinate30/` directories and never replaces them.
Pass `--postprocess` to run `coordinate,re_correct,mismatch` in the isolated
`coordinate0/` tree.
`run_ribosemap_multi.sh` submits a small `afterok:<primary-job-id>` relay,
which submits the coordinate0 array only after the full primary array succeeds
and releases its array job slots. This avoids Slurm QoS limits that count every
pending array element. For a manual rerun, add `--dependency afterok:<job-id>`
as needed.

Pass the same `--run-id` to the primary trimming/alignment submission and a
coordinate-only submission so the latter reuses the matching timestamped BAMs.

`coordinate0` retains all genome-wide reads with MAPQ >= 0, including
ambiguous reads that may derive from rDNA. It does not define an rDNA interval,
filter `chrXII`, or provide quantitative assignment across the tandem rDNA
array. A quantitative rDNA analysis needs a dedicated rDNA reference/index.

## Options

```text
-s  sample sheet (required)
-b  base config (required)
-m  comma-separated modules (default: trimming,alignment,coordinate,re_correct,mismatch,removeMXY,composition,sequence,distribution,hotspot)
    Use/omit `trimming` to control whether trim_galore runs in this invocation.
-j  number of samples to run in parallel (default: 1)
-o  generated config output directory (default: config/generated)
    --coordinate-quality override the coordinate MAPQ threshold for this invocation
    --keep-mismatch-fastq keep temporary mismatch FASTQ under results/<sample>/mismatch/input_fastq
```

## Example: only alignment + coordinate

```bash
scripts/run_multi_sample.sh \
  -s config/samples.tsv \
  -b config/base.config \
  -m trimming,alignment,coordinate,re_correct,mismatch \
  -j 2
```
