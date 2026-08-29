#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/submit_slurm_array.sh -s <samples.tsv> -b <base.config> [options]

Submit one Slurm array task per sample so samples can run on different nodes.
Each array task runs exactly one sample using scripts/slurm_array_task.sh.

Required:
  -s  Sample sheet (header: sample<TAB>barcode<TAB>read1[<TAB>read2])
  -b  Base config

Optional:
  -m  Comma-separated module list (default: trimming,alignment,coordinate,mismatch,removeMXY,composition,sequence,distribution,hotspot)
  -o  Generated config output directory (default: config/generated)
      --sample-log-dir Directory for per-sample combined stdout/stderr logs (default: logs/samples)
      --run-date       Date tag for per-sample logs, e.g. 20260220 (default: today YYYYMMDD)

Slurm options:
  -A  Account
  -p  Partition
  -q  QoS (e.g. embers, inferno)
  -t  Time limit (default: 10:00:00)
      --mem Memory per task (default: 64G)
      --cpus-per-task CPUs per task (default: threads from base config, else 8)
      --array-parallel Max concurrent array tasks (default: all)
      --job-name Job name (default: ribose-map-array)
      --log-dir  Log directory (default: logs)

Example:
  scripts/submit_slurm_array.sh \
    -s config/Run22026.samples.tsv \
    -b config/Run22026.config \
    -m trimming,alignment,coordinate,mismatch \
    -A gts-fstorici3 \
    -p batch \
    --cpus-per-task 16 \
    --mem 100G \
    --sample-log-dir logs/samples \
    --run-date 20260220 \
    --array-parallel 8
USAGE
}

SAMPLES_TSV=""
BASE_CONFIG=""
MODULES="trimming,alignment,coordinate,mismatch,removeMXY,composition,sequence,distribution,hotspot"
GENERATED_DIR="config/generated"

ACCOUNT=""
PARTITION=""
QOS=""
TIME_LIMIT="10:00:00"
MEMORY="64G"
CPUS_PER_TASK=""
ARRAY_PARALLEL=""
JOB_NAME="ribose-map-array"
LOG_DIR="logs"
SAMPLE_LOG_DIR="logs/samples"
RUN_DATE="$(date +%Y%m%d)"

abspath() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    printf '%s\n' "$p"
  else
    printf '%s/%s\n' "$PWD" "$p"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -s) SAMPLES_TSV="$2"; shift 2 ;;
    -b) BASE_CONFIG="$2"; shift 2 ;;
    -m) MODULES="$2"; shift 2 ;;
    -o) GENERATED_DIR="$2"; shift 2 ;;
    -A) ACCOUNT="$2"; shift 2 ;;
    -p) PARTITION="$2"; shift 2 ;;
    -q) QOS="$2"; shift 2 ;;
    --qos) QOS="$2"; shift 2 ;;
    -q*) QOS="${1#-q}"; shift ;;
    -t) TIME_LIMIT="$2"; shift 2 ;;
    --mem) MEMORY="$2"; shift 2 ;;
    --cpus-per-task) CPUS_PER_TASK="$2"; shift 2 ;;
    --array-parallel) ARRAY_PARALLEL="$2"; shift 2 ;;
    --job-name) JOB_NAME="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --sample-log-dir) SAMPLE_LOG_DIR="$2"; shift 2 ;;
    --run-date) RUN_DATE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${SAMPLES_TSV}" || -z "${BASE_CONFIG}" ]]; then
  echo "Both -s and -b are required." >&2
  usage
  exit 1
fi

SAMPLES_TSV="$(abspath "${SAMPLES_TSV}")"
BASE_CONFIG="$(abspath "${BASE_CONFIG}")"
GENERATED_DIR="$(abspath "${GENERATED_DIR}")"
LOG_DIR="$(abspath "${LOG_DIR}")"
SAMPLE_LOG_DIR="$(abspath "${SAMPLE_LOG_DIR}")"

if [[ ! -f "${SAMPLES_TSV}" ]]; then
  echo "Sample sheet not found: ${SAMPLES_TSV}" >&2
  exit 1
fi

if [[ ! -f "${BASE_CONFIG}" ]]; then
  echo "Base config not found: ${BASE_CONFIG}" >&2
  exit 1
fi

sample_count="$(awk -F '\t' '
  NR==1 { next }
  NF==0 { next }
  /^#/ { next }
  { n++ }
  END { print n+0 }
' "${SAMPLES_TSV}")"

if [[ "${sample_count}" -le 0 ]]; then
  echo "No samples found in ${SAMPLES_TSV}" >&2
  exit 1
fi

if [[ -z "${CPUS_PER_TASK}" ]]; then
  # shellcheck disable=SC1090
  . "${BASE_CONFIG}"
  CPUS_PER_TASK="${threads:-8}"
fi

if ! [[ "${CPUS_PER_TASK}" =~ ^[1-9][0-9]*$ ]]; then
  echo "--cpus-per-task must be a positive integer." >&2
  exit 1
fi

if [[ -n "${ARRAY_PARALLEL}" ]] && ! [[ "${ARRAY_PARALLEL}" =~ ^[1-9][0-9]*$ ]]; then
  echo "--array-parallel must be a positive integer." >&2
  exit 1
fi

if ! command -v base64 >/dev/null 2>&1; then
  echo "base64 is required but not found in PATH." >&2
  exit 1
fi
MODULES_B64="$(printf '%s' "${MODULES}" | base64 | tr -d '\n')"

mkdir -p "${LOG_DIR}" "${GENERATED_DIR}" "${SAMPLE_LOG_DIR}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_SCRIPT="${ROOT_DIR}/scripts/slurm_array_task.sh"

if [[ ! -x "${TASK_SCRIPT}" ]]; then
  echo "Missing executable: ${TASK_SCRIPT}" >&2
  exit 1
fi

array_spec="1-${sample_count}"
if [[ -n "${ARRAY_PARALLEL}" ]]; then
  array_spec="${array_spec}%${ARRAY_PARALLEL}"
fi

SBATCH_ARGS=(
  --job-name "${JOB_NAME}"
  --time "${TIME_LIMIT}"
  --cpus-per-task "${CPUS_PER_TASK}"
  --mem "${MEMORY}"
  --array "${array_spec}"
  --output "/dev/null"
  --error "/dev/null"
  --export "ALL,PROJECT_ROOT=${ROOT_DIR},SAMPLES_TSV=${SAMPLES_TSV},BASE_CONFIG=${BASE_CONFIG},MODULES_B64=${MODULES_B64},GENERATED_DIR=${GENERATED_DIR},SAMPLE_LOG_DIR=${SAMPLE_LOG_DIR},RUN_DATE=${RUN_DATE}"
)

if [[ -n "${ACCOUNT}" ]]; then
  SBATCH_ARGS+=(--account "${ACCOUNT}")
fi
if [[ -n "${PARTITION}" ]]; then
  SBATCH_ARGS+=(--partition "${PARTITION}")
fi
if [[ -n "${QOS}" ]]; then
  SBATCH_ARGS+=(--qos "${QOS}")
fi

echo "Submitting array job with ${sample_count} samples (array=${array_spec})"
printf 'sbatch %q ' "${SBATCH_ARGS[@]}"
printf '%q\n' "${TASK_SCRIPT}"

sbatch "${SBATCH_ARGS[@]}" "${TASK_SCRIPT}"
