#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/submit_slurm_single.sh -c <single.config> [options]

Submit one Slurm task for a single sample using a legacy single-sample config.
The config is used as both:
  1) source of sample/barcode/read1/read2, and
  2) base config for shared settings.

Required:
  -c  Single-sample config (must define sample, and exactly one of read1/read2)

Optional:
  -m  Comma-separated module list (default: trimming,alignment,coordinate,mismatch,removeMXY,composition,sequence,distribution,hotspot)
  -o  Generated config output directory (default: config/generated)
      --sample-log-dir Directory for per-sample combined stdout/stderr logs (default: logs/samples)
      --run-date       Date tag for per-sample logs, e.g. 20260220 (default: today YYYYMMDD)

Slurm options:
  -A  Account
  -p  Partition
  -q  QoS (e.g. embers, inferno)
  -t, --time  Time limit (default: 08:00:00)
      --mem Memory per task (default: 64G)
      --cpus-per-task CPUs per task (default: threads from config, else 8)
      --job-name Job name (default: ribose-map-single)
      --log-dir  Log directory (default: logs)
USAGE
}

CONFIG=""
MODULES="trimming,alignment,coordinate,mismatch,removeMXY,composition,sequence,distribution,hotspot"
GENERATED_DIR="config/generated"

ACCOUNT=""
PARTITION=""
QOS=""
TIME_LIMIT="08:00:00"
MEMORY="64G"
CPUS_PER_TASK=""
JOB_NAME="ribose-map-single"
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
    -c) CONFIG="$2"; shift 2 ;;
    -m) MODULES="$2"; shift 2 ;;
    -o) GENERATED_DIR="$2"; shift 2 ;;
    -A) ACCOUNT="$2"; shift 2 ;;
    -p) PARTITION="$2"; shift 2 ;;
    -q) QOS="$2"; shift 2 ;;
    --qos) QOS="$2"; shift 2 ;;
    -q*) QOS="${1#-q}"; shift ;;
    -t|--time) TIME_LIMIT="$2"; shift 2 ;;
    --mem) MEMORY="$2"; shift 2 ;;
    --cpus-per-task) CPUS_PER_TASK="$2"; shift 2 ;;
    --job-name) JOB_NAME="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --sample-log-dir) SAMPLE_LOG_DIR="$2"; shift 2 ;;
    --run-date) RUN_DATE="$2"; shift 2 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${CONFIG}" ]]; then
  echo "-c is required." >&2
  usage
  exit 1
fi

CONFIG="$(abspath "${CONFIG}")"
GENERATED_DIR="$(abspath "${GENERATED_DIR}")"
LOG_DIR="$(abspath "${LOG_DIR}")"
SAMPLE_LOG_DIR="$(abspath "${SAMPLE_LOG_DIR}")"

if [[ ! -f "${CONFIG}" ]]; then
  echo "Config not found: ${CONFIG}" >&2
  exit 1
fi

read -r sample barcode read1 read2 < <(
  set +u
  . "${CONFIG}"
  printf '%s\t%s\t%s\t%s\n' "${sample:-}" "${barcode:-}" "${read1:-}" "${read2:-}"
)

if [[ -z "${sample}" ]]; then
  echo "sample is not set in ${CONFIG}" >&2
  exit 1
fi

has_r1=0
has_r2=0
if [[ -n "${read1}" && "${read1}" != "-" ]]; then
  has_r1=1
fi
if [[ -n "${read2}" && "${read2}" != "-" ]]; then
  has_r2=1
fi
if [[ "${has_r1}" -eq 1 && "${has_r2}" -eq 1 ]]; then
  echo "Legacy config has both read1 and read2 set; this wrapper expects exactly one read for platform inference." >&2
  exit 1
fi
if [[ "${has_r1}" -eq 0 && "${has_r2}" -eq 0 ]]; then
  echo "Legacy config must define exactly one of read1/read2." >&2
  exit 1
fi

mkdir -p "${GENERATED_DIR}/single"
single_samples_tsv="${GENERATED_DIR}/single/${sample}.${RUN_DATE}.samples.tsv"

{
  printf 'sample\tbarcode\tread1\tread2\n'
  printf '%s\t%s\t%s\t%s\n' "${sample}" "${barcode}" "${read1}" "${read2}"
} > "${single_samples_tsv}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARRAY_SUBMIT="${ROOT_DIR}/scripts/submit_slurm_array.sh"
if [[ ! -x "${ARRAY_SUBMIT}" ]]; then
  echo "Missing executable: ${ARRAY_SUBMIT}" >&2
  exit 1
fi

args=(
  -s "${single_samples_tsv}"
  -b "${CONFIG}"
  -m "${MODULES}"
  -o "${GENERATED_DIR}"
  -t "${TIME_LIMIT}"
  --mem "${MEMORY}"
  --job-name "${JOB_NAME}"
  --log-dir "${LOG_DIR}"
  --sample-log-dir "${SAMPLE_LOG_DIR}"
  --run-date "${RUN_DATE}"
  --array-parallel 1
)

if [[ -n "${ACCOUNT}" ]]; then
  args+=(-A "${ACCOUNT}")
fi
if [[ -n "${PARTITION}" ]]; then
  args+=(-p "${PARTITION}")
fi
if [[ -n "${QOS}" ]]; then
  args+=(--qos "${QOS}")
fi
if [[ -n "${CPUS_PER_TASK}" ]]; then
  args+=(--cpus-per-task "${CPUS_PER_TASK}")
fi

echo "Submitting single-sample job for ${sample} using ${CONFIG}"
bash "${ARRAY_SUBMIT}" "${args[@]}"
