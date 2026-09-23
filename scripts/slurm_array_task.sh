#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  echo "SLURM_ARRAY_TASK_ID is not set." >&2
  exit 1
fi

if [[ -z "${SAMPLES_TSV:-}" || -z "${BASE_CONFIG:-}" ]]; then
  echo "SAMPLES_TSV and BASE_CONFIG must be exported to the Slurm task." >&2
  exit 1
fi

MODULES="${MODULES:-trimming,alignment,coordinate,re_correct,mismatch,removeMXY,composition,sequence,distribution,hotspot}"
if [[ -n "${MODULES_B64:-}" ]]; then
  MODULES="$(printf '%s' "${MODULES_B64}" | base64 -d)"
fi
GENERATED_DIR="${GENERATED_DIR:-config/generated}"
RESULTS_ROOT="${RESULTS_ROOT:-}"
DRY_RUN="${DRY_RUN:-0}"
SAMPLE_LOG_DIR="${SAMPLE_LOG_DIR:-logs/samples}"
RUN_ID="${RUN_ID:-${RUN_DATE:-$(date +%Y%m%d_%H%M%S)}}"
COORDINATE_QUALITY="${COORDINATE_QUALITY:-}"

if [[ -n "${PROJECT_ROOT:-}" ]]; then
  ROOT_DIR="${PROJECT_ROOT}"
elif [[ -n "${SLURM_SUBMIT_DIR:-}" ]]; then
  ROOT_DIR="${SLURM_SUBMIT_DIR}"
else
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
MULTI_RUNNER="${ROOT_DIR}/scripts/run_multi_sample.sh"

if [[ ! -x "${MULTI_RUNNER}" ]]; then
  echo "Missing executable: ${MULTI_RUNNER}" >&2
  exit 1
fi

sample_row="$({
  awk -F '\t' '
    NR==1 { next }
    NF==0 { next }
    /^#/ { next }
    { print }
  ' "${SAMPLES_TSV}" | sed -n "${SLURM_ARRAY_TASK_ID}p"
} || true)"

sample_header="$(awk 'NR==1 { print; exit }' "${SAMPLES_TSV}")"

if [[ -z "${sample_header}" ]]; then
  echo "Sample sheet header is missing: ${SAMPLES_TSV}" >&2
  exit 1
fi

if [[ -z "${sample_row}" ]]; then
  echo "No sample row found for SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID}" >&2
  exit 1
fi

sample_name="$(printf '%s\n' "${sample_row}" | awk -F '\t' '{print $1}')"
if [[ -z "${sample_name}" ]]; then
  echo "Unable to parse sample name from row: ${sample_row}" >&2
  exit 1
fi

mkdir -p "${SAMPLE_LOG_DIR}"
# Include the Slurm IDs so retries do not overwrite the evidence from an
# earlier attempt on the same day.
sample_log="${SAMPLE_LOG_DIR}/${sample_name}_${RUN_ID}_${SLURM_JOB_ID:-unknown}_${SLURM_ARRAY_TASK_ID}.log"
exec > "${sample_log}" 2>&1

start_ts="$(date '+%F %T')"
echo "========== SLURM TASK START =========="
echo "start_time: ${start_ts}"
echo "job_id: ${SLURM_JOB_ID:-unknown}"
echo "array_task_id: ${SLURM_ARRAY_TASK_ID}"
echo "job_name: ${SLURM_JOB_NAME:-unknown}"
echo "node: ${SLURMD_NODENAME:-${HOSTNAME:-unknown}}"
echo "sample: ${sample_name}"
echo "sample_row: ${sample_row}"
echo "project_root: ${ROOT_DIR}"
echo "working_dir: $(pwd)"
echo "run_id: ${RUN_ID}"
echo "TMPDIR: ${TMPDIR:-/tmp}"
echo "tmp_filesystem:"
df -h "${TMPDIR:-/tmp}" || true
echo "tmp_inodes:"
df -i "${TMPDIR:-/tmp}" || true
echo "======================================"

task_epilogue() {
  local rc="${1:-$?}"
  local end_ts
  end_ts="$(date '+%F %T')"
  echo "========== SLURM TASK END =========="
  echo "end_time: ${end_ts}"
  echo "sample: ${sample_name}"
  echo "exit_code: ${rc}"
  if [[ "${rc}" -eq 0 ]]; then
    echo "status: SUCCESS"
  else
    echo "status: FAILED"
  fi
  echo "===================================="
}

handle_signal() {
  local signal="$1"
  local signal_exit_code="$2"

  # Preserve scheduler cancellation/preemption in the task log. Without this
  # handler, the EXIT trap can misleadingly report a successful shell status.
  echo "Received ${signal}; terminating task."
  exit "${signal_exit_code}"
}

tmp_tsv="$(mktemp "${TMPDIR:-/tmp}/ribose-map-array-task.XXXXXX.tsv")"
cleanup_and_epilogue() {
  local rc="$?"
  rm -f "${tmp_tsv}"
  task_epilogue "${rc}"
  exit "${rc}"
}
trap cleanup_and_epilogue EXIT
trap 'handle_signal TERM 143' TERM
trap 'handle_signal INT 130' INT
trap 'handle_signal HUP 129' HUP

set +u
if ! command -v module >/dev/null 2>&1; then
  if [[ -f /etc/profile.d/modules.sh ]]; then
    # Initialize the environment-modules command in non-interactive Slurm shells.
    source /etc/profile.d/modules.sh
  elif [[ -f /usr/share/Modules/init/bash ]]; then
    source /usr/share/Modules/init/bash
  fi
fi

module load anaconda3

if ! command -v conda >/dev/null 2>&1; then
  echo "conda not found after loading anaconda3 module" >&2
  exit 1
fi

eval "$(conda shell.bash hook)"
conda activate ribose-map
set -u

{
  printf '%s\n' "${sample_header}"
  printf '%s\n' "${sample_row}"
} > "${tmp_tsv}"

args=(
  -s "${tmp_tsv}"
  -b "${BASE_CONFIG}"
  -m "${MODULES}"
  -j 1
  -o "${GENERATED_DIR}"
  --run-id "${RUN_ID}"
)

if [[ -n "${COORDINATE_QUALITY}" ]]; then
  args+=(--coordinate-quality "${COORDINATE_QUALITY}")
fi

if [[ -n "${RESULTS_ROOT}" ]]; then
  args+=(--results-root "${RESULTS_ROOT}")
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  args+=(--dry-run)
fi

bash "${MULTI_RUNNER}" "${args[@]}"
