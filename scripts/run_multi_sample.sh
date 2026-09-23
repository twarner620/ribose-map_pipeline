#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/run_multi_sample.sh -s <samples.tsv> -b <base.config> [-m <modules>] [-j <jobs>] [-o <generated_config_dir>] [--dry-run]

Run Ribose-Map modules for multiple samples.

Required:
  -s  Tab-delimited sample sheet with header: sample<TAB>barcode<TAB>read1
  -b  Base config containing shared settings (technique, repository, genome paths, etc.)

Optional:
  -m  Comma-separated module list
      (default: trimming,alignment,coordinate,re_correct,mismatch,removeMXY,composition,sequence,distribution,hotspot)
  -j  Number of samples to run in parallel (default: 1)
  -o  Directory to write generated per-sample configs (default: config/generated)
      --coordinate-quality Override the coordinate MAPQ threshold for this invocation
      --run-id             Append this identifier to the base repository path
      --dry-run Generate configs and print planned commands without running modules
      --keep-mismatch-fastq Keep temporary mismatch FASTQ under results/<sample>/mismatch/input_fastq

Recognized optional sample-sheet columns:
  read2        Paired-end mate or read2-only input
  technique    Per-sample technique override; use '-' to keep base config value
  pattern      Per-sample UMI pattern override; use '-' or empty to disable extraction
  frag_method  Per-sample fragmentation / enzyme mix; used only by re_correct

Input behavior is inferred per sample row:
  read1 only    -> single-end input using read1
  read2 only    -> single-end input using read2 (legacy AVITI path)
  read1 + read2 -> paired-end input
USAGE
}

SAMPLES_TSV=""
BASE_CONFIG=""
MODULES="trimming,alignment,coordinate,re_correct,mismatch,removeMXY,composition,sequence,distribution,hotspot"
JOBS=1
GENERATED_DIR="config/generated"
COORDINATE_QUALITY=""
RUN_ID="${RUN_ID:-}"
ALIGNMENT_MAX_ATTEMPTS=""
DRY_RUN=0
CLEANUP_MISMATCH_FASTQ=1
UNSET_SENTINEL="__RIBOSEMAP_UNSET__"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --keep-mismatch-fastq) CLEANUP_MISMATCH_FASTQ=0; shift ;;
    --coordinate-quality)
      if [[ $# -lt 2 ]]; then
        echo "Option $1 requires an argument." >&2
        usage
        exit 1
      fi
      COORDINATE_QUALITY="$2"
      shift 2
      ;;
    --run-id)
      if [[ $# -lt 2 ]]; then
        echo "Option $1 requires an argument." >&2
        usage
        exit 1
      fi
      RUN_ID="$2"
      shift 2
      ;;
    -h) usage; exit 0 ;;
    -s|-b|-m|-j|-o)
      if [[ $# -lt 2 ]]; then
        echo "Option $1 requires an argument." >&2
        usage
        exit 1
      fi
      case "$1" in
        -s) SAMPLES_TSV="$2" ;;
        -b) BASE_CONFIG="$2" ;;
        -m) MODULES="$2" ;;
        -j) JOBS="$2" ;;
        -o) GENERATED_DIR="$2" ;;
      esac
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${SAMPLES_TSV}" || -z "${BASE_CONFIG}" ]]; then
  echo "Both -s and -b are required." >&2
  usage
  exit 1
fi

if [[ -z "${RUN_ID}" ]]; then
  RUN_ID="$(date +%Y%m%d_%H%M%S)"
fi
if ! [[ "${RUN_ID}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "--run-id may contain only letters, numbers, dots, underscores, and hyphens." >&2
  exit 1
fi

if [[ ! -f "${SAMPLES_TSV}" ]]; then
  echo "Sample sheet not found: ${SAMPLES_TSV}" >&2
  exit 1
fi

if [[ ! -f "${BASE_CONFIG}" ]]; then
  echo "Base config not found: ${BASE_CONFIG}" >&2
  exit 1
fi

if ! [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "-j must be a positive integer." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIBOSEMAP_BIN="${ROOT_DIR}/modules/ribosemap"
REMOVE_MXY_BIN="${ROOT_DIR}/scripts/removeMXY.sh"
RE_CORRECT_ROOT="${ROOT_DIR}/submodules/ArtificialRiboseDetection"
RE_CORRECT_BIN="${RE_CORRECT_ROOT}/subtraction.py"
RE_CORRECT_LIST="${RE_CORRECT_ROOT}/res_all.list"

if [[ "${DRY_RUN}" -eq 0 && ! -x "${RIBOSEMAP_BIN}" ]]; then
  echo "Missing executable: ${RIBOSEMAP_BIN}" >&2
  exit 1
fi
if [[ "${DRY_RUN}" -eq 0 && ! -x "${REMOVE_MXY_BIN}" ]]; then
  echo "Missing executable: ${REMOVE_MXY_BIN}" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${BASE_CONFIG}"

if [[ -z "${repository:-}" ]]; then
  echo "repository is not set in ${BASE_CONFIG}" >&2
  exit 1
fi
repository="${repository}_${RUN_ID}"
if [[ -z "${fasta:-}" ]]; then
  echo "fasta is not set in ${BASE_CONFIG}" >&2
  exit 1
fi
if [[ -z "${quality:-}" ]]; then
  echo "quality is not set in ${BASE_CONFIG}" >&2
  exit 1
fi

# A vanished node-local alignment workdir is retryable; other failures are not.
ALIGNMENT_MAX_ATTEMPTS="${alignment_max_attempts:-2}"
if ! [[ "${ALIGNMENT_MAX_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "alignment_max_attempts must be a positive integer." >&2
  exit 1
fi

if [[ -n "${COORDINATE_QUALITY}" ]]; then
  if ! [[ "${COORDINATE_QUALITY}" =~ ^[0-9]+$ ]]; then
    echo "--coordinate-quality must be a non-negative integer." >&2
    exit 1
  fi
  quality="${COORDINATE_QUALITY}"
fi

DEFAULT_MM_REPO_ILLUMINA="/storage/home/hcoda1/8/twarner31/r-fstorici3-0/mismatch/rNMP_match_analysis_illumina"
DEFAULT_MM_REPO_AVITI="/storage/home/hcoda1/8/twarner31/r-fstorici3-0/mismatch/rNMP_match_analysis_Aviti"
LEGACY_MISMATCH_REPO="${mismatch_repo:-}"
MISMATCH_REPO_ILLUMINA="${mismatch_repo_illumina:-${LEGACY_MISMATCH_REPO:-$DEFAULT_MM_REPO_ILLUMINA}}"
MISMATCH_REPO_AVITI="${mismatch_repo_aviti:-${LEGACY_MISMATCH_REPO:-$DEFAULT_MM_REPO_AVITI}}"
MISMATCH_POLYN="${mismatch_polyN:-5}"
MISMATCH_NTAIL="${mismatch_ntail:-A}"

if ! [[ "${MISMATCH_POLYN}" =~ ^[1-9][0-9]*$ ]]; then
  echo "mismatch_polyN must be a positive integer." >&2
  exit 1
fi

mkdir -p "${GENERATED_DIR}"

IFS=',' read -r -a MODULE_ARRAY <<< "${MODULES}"
RUN_TRIMMING=0
RUN_MISMATCH=0
RUN_RE_CORRECT=0
for mod in "${MODULE_ARRAY[@]}"; do
  case "${mod}" in
    trimming)
      RUN_TRIMMING=1
      ;;
    re_correct)
      RUN_RE_CORRECT=1
      ;;
    mismatch)
      RUN_MISMATCH=1
      ;;
    alignment|coordinate|removeMXY|composition|sequence|distribution|hotspot)
      ;;
    *)
      echo "Unsupported module: ${mod}" >&2
      exit 1
      ;;
  esac
done

if [[ "${DRY_RUN}" -eq 0 ]]; then
  if [[ "${RUN_TRIMMING}" -eq 1 ]] && ! command -v trim_galore >/dev/null 2>&1; then
    echo "trim_galore is required but not found in PATH." >&2
    exit 1
  fi
  if [[ "${RUN_MISMATCH}" -eq 1 ]] && ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required but not found in PATH." >&2
    exit 1
  fi
  if [[ "${RUN_MISMATCH}" -eq 1 ]] && ! command -v Rscript >/dev/null 2>&1; then
    echo "Rscript is required but not found in PATH." >&2
    exit 1
  fi
  if [[ "${RUN_RE_CORRECT}" -eq 1 ]]; then
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 is required but not found in PATH." >&2
      exit 1
    fi
    if [[ ! -f "${RE_CORRECT_BIN}" ]]; then
      echo "Missing re_correct helper: ${RE_CORRECT_BIN}" >&2
      exit 1
    fi
    if [[ ! -f "${RE_CORRECT_LIST}" ]]; then
      echo "Missing re_correct restriction-enzyme list: ${RE_CORRECT_LIST}" >&2
      exit 1
    fi
  fi
fi

sq() {
  local s="${1:-}"
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "${s}"
}

reverse_complement_barcode() {
  local barcode="${1:-}"

  if [[ -z "${barcode}" || "${barcode}" == "-" ]]; then
    echo ""
    return 0
  fi

  barcode="${barcode^^}"
  if [[ ! "${barcode}" =~ ^[ACGTRYKMSWBDHVNU]+$ ]]; then
    echo "Invalid barcode sequence: ${barcode}" >&2
    return 1
  fi

  barcode="${barcode//U/T}"
  echo "${barcode}" | tr 'ACGTRYKMSWBDHVN' 'TGCAYRMKSWVHDBN' | rev
}

normalize_config_override() {
  local value="${1:-}"

  if [[ -z "${value}" || "${value}" == "${UNSET_SENTINEL}" ]]; then
    return 1
  fi

  if [[ "${value}" == "-" ]]; then
    printf '%s\n' ""
    return 0
  fi

  printf '%s\n' "${value}"
}

normalize_frag_method() {
  local value="${1:-}"

  if [[ -z "${value}" || "${value}" == "${UNSET_SENTINEL}" ]]; then
    return 1
  fi

  if [[ "${value}" == "-" ]]; then
    printf '%s\n' ""
    return 0
  fi

  printf '%s\n' "${value}"
}

re_correct_should_run() {
  local technique_value="${1:-}"
  local frag_method_value="${2:-}"

  if [[ "${technique_value}" != "ribose-seq" ]]; then
    return 1
  fi

  case "${frag_method_value,,}" in
    ""|na|dsf|mech)
      return 1
      ;;
  esac

  return 0
}

pattern_length() {
  local value="${1:-}"

  if [[ -z "${value}" ]]; then
    return 1
  fi

  printf '%s\n' "${#value}"
}

normalize_re_enzymes() {
  local value="${1:-}"

  if [[ -z "${value}" ]]; then
    return 1
  fi

  value="${value//[/}"
  value="${value//]/}"
  value="${value//+/\,}"
  value="${value// /}"
  value="${value,,}"
  value="${value#,}"
  value="${value%,}"
  value="$(printf '%s' "${value}" | tr -s ',')"

  if [[ -z "${value}" ]]; then
    return 1
  fi

  printf '%s\n' "${value}"
}

trimmed_fastq_path() {
  local input_fastq="$1"
  local trim_dir="$2"
  local name stem

  name="$(basename "${input_fastq}")"
  stem="${name}"
  stem="${stem%.fastq.gz}"
  stem="${stem%.fq.gz}"
  stem="${stem%.fastq}"
  stem="${stem%.fq}"

  if [[ -f "${trim_dir}/${stem}_trimmed.fq.gz" ]]; then
    echo "${trim_dir}/${stem}_trimmed.fq.gz"
    return 0
  fi
  if [[ -f "${trim_dir}/${stem}_trimmed.fastq.gz" ]]; then
    echo "${trim_dir}/${stem}_trimmed.fastq.gz"
    return 0
  fi
  if [[ -f "${trim_dir}/${stem}_trimmed.fq" ]]; then
    echo "${trim_dir}/${stem}_trimmed.fq"
    return 0
  fi
  if [[ -f "${trim_dir}/${stem}_trimmed.fastq" ]]; then
    echo "${trim_dir}/${stem}_trimmed.fastq"
    return 0
  fi

  return 1
}

predicted_trimmed_fastq_path() {
  local input_fastq="$1"
  local trim_dir="$2"
  local name stem

  name="$(basename "${input_fastq}")"
  stem="${name}"
  stem="${stem%.fastq.gz}"
  stem="${stem%.fq.gz}"
  stem="${stem%.fastq}"
  stem="${stem%.fq}"

  printf '%s/%s_trimmed.fq.gz\n' "${trim_dir}" "${stem}"
}

predicted_trimmed_paired_fastq_paths() {
  local read1="$1"
  local read2="$2"
  local trim_dir="$3"
  local name1 stem1 name2 stem2

  name1="$(basename "${read1}")"
  stem1="${name1%.fastq.gz}"
  stem1="${stem1%.fq.gz}"
  stem1="${stem1%.fastq}"
  stem1="${stem1%.fq}"

  name2="$(basename "${read2}")"
  stem2="${name2%.fastq.gz}"
  stem2="${stem2%.fq.gz}"
  stem2="${stem2%.fastq}"
  stem2="${stem2%.fq}"

  printf '%s/%s_val_1.fq.gz\n%s/%s_val_2.fq.gz\n' "${trim_dir}" "${stem1}" "${trim_dir}" "${stem2}"
}

classify_input_layout() {
  local read1="$1"
  local read2="$2"
  local has_r1=0
  local has_r2=0

  if [[ -n "${read1}" && "${read1}" != "-" ]]; then
    has_r1=1
  fi
  if [[ -n "${read2}" && "${read2}" != "-" ]]; then
    has_r2=1
  fi

  if [[ "${has_r1}" -eq 1 && "${has_r2}" -eq 0 ]]; then
    printf "single_r1\n%s\n\n" "${read1}"
    return 0
  fi
  if [[ "${has_r1}" -eq 0 && "${has_r2}" -eq 1 ]]; then
    printf "single_r2\n\n%s\n" "${read2}"
    return 0
  fi
  if [[ "${has_r1}" -eq 1 && "${has_r2}" -eq 1 ]]; then
    printf "paired\n%s\n%s\n" "${read1}" "${read2}"
    return 0
  fi

  echo "At least one of read1/read2 must be provided per sample row." >&2
  return 1
}

trimmed_paired_fastq_paths() {
  local read1="$1"
  local read2="$2"
  local trim_dir="$3"
  local name1 stem1 name2 stem2 out1="" out2=""

  name1="$(basename "${read1}")"
  stem1="${name1%.fastq.gz}"
  stem1="${stem1%.fq.gz}"
  stem1="${stem1%.fastq}"
  stem1="${stem1%.fq}"

  name2="$(basename "${read2}")"
  stem2="${name2%.fastq.gz}"
  stem2="${stem2%.fq.gz}"
  stem2="${stem2%.fastq}"
  stem2="${stem2%.fq}"

  for candidate in \
    "${trim_dir}/${stem1}_val_1.fq.gz" \
    "${trim_dir}/${stem1}_val_1.fastq.gz" \
    "${trim_dir}/${stem1}_val_1.fq" \
    "${trim_dir}/${stem1}_val_1.fastq"
  do
    if [[ -f "${candidate}" ]]; then
      out1="${candidate}"
      break
    fi
  done

  for candidate in \
    "${trim_dir}/${stem2}_val_2.fq.gz" \
    "${trim_dir}/${stem2}_val_2.fastq.gz" \
    "${trim_dir}/${stem2}_val_2.fq" \
    "${trim_dir}/${stem2}_val_2.fastq"
  do
    if [[ -f "${candidate}" ]]; then
      out2="${candidate}"
      break
    fi
  done

  if [[ -n "${out1}" && -n "${out2}" ]]; then
    printf "%s\n%s\n" "${out1}" "${out2}"
    return 0
  fi

  return 1
}

prepare_trimmed_inputs() {
  local sample="$1"
  local trim_profile="$2"
  local read1="$3"
  local read2="$4"
  local trim_dir trimmed trimmed_pair_output
  local trim_length trim_q trim_adapter="" trim_flag=""
  local paired=0
  local -a trimmed_pair

  case "${trim_profile}" in
    ribose-seq)
      trim_adapter="AGTTGCGACACGGATCTATCA"
      trim_length="62"
      trim_q="15"
      ;;
    emRiboSeq)
      trim_flag="--illumina"
      trim_length="50"
      trim_q="15"
      ;;
    RHII-HydEn-seq|Alk-HydEn-seq)
      trim_flag="--illumina"
      trim_length="30"
      trim_q="15"
      paired=1
      ;;
    aviti)
      trim_adapter="AGTTGACAAGCGGTAGCCTGCACACCTTCCGACAT"
      trim_length="50"
      trim_q="15"
      ;;
    *)
      echo "Unsupported trim profile: ${trim_profile}" >&2
      return 1
      ;;
  esac

  trim_dir="${repository}/results/${sample}/trim_galore"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    if [[ "${paired}" -eq 1 ]]; then
      echo "[DRY-RUN] ${sample} -> trim_galore --gzip --paired ${trim_flag} -q ${trim_q} --length ${trim_length} ${read1} ${read2} -o ${trim_dir}" >&2
      predicted_trimmed_paired_fastq_paths "${read1}" "${read2}" "${trim_dir}"
      return 0
    fi
    if [[ -n "${trim_adapter}" ]]; then
      echo "[DRY-RUN] ${sample} -> trim_galore --gzip -a ${trim_adapter} -q ${trim_q} --length ${trim_length} ${read1} -o ${trim_dir}" >&2
    else
      echo "[DRY-RUN] ${sample} -> trim_galore --gzip ${trim_flag} -q ${trim_q} --length ${trim_length} ${read1} -o ${trim_dir}" >&2
    fi
    printf "%s\n\n" "$(predicted_trimmed_fastq_path "${read1}" "${trim_dir}")"
    return 0
  fi

  rm -rf "${trim_dir}"
  mkdir -p "${trim_dir}"

  echo "[RUN] ${sample} -> trim_galore (${trim_profile})" >&2
  if [[ "${paired}" -eq 1 ]]; then
    trim_galore --gzip --paired ${trim_flag} -q "${trim_q}" --length "${trim_length}" "${read1}" "${read2}" -o "${trim_dir}" >&2
    if ! trimmed_pair_output="$(trimmed_paired_fastq_paths "${read1}" "${read2}" "${trim_dir}")"; then
      echo "trim_galore finished but paired trimmed outputs were not found for ${sample} in ${trim_dir}" >&2
      return 1
    fi
    mapfile -t trimmed_pair <<< "${trimmed_pair_output}"
    if [[ ! -s "${trimmed_pair[0]}" || ! -s "${trimmed_pair[1]}" ]]; then
      echo "Trim Galore did not produce nonempty paired FASTQs for ${sample}: ${trim_dir}" >&2
      return 1
    fi
    validate_trimmed_output "${sample}" "${trim_dir}" "${trimmed_pair[0]}" || return 1
    printf "%s\n%s\n" "${trimmed_pair[0]}" "${trimmed_pair[1]}"
    return 0
  fi

  if [[ -n "${trim_adapter}" ]]; then
    trim_galore --gzip "${read1}" -a "${trim_adapter}" -q "${trim_q}" --length "${trim_length}" --output_dir "${trim_dir}" >&2
  else
    trim_galore --gzip ${trim_flag} -q "${trim_q}" --length "${trim_length}" "${read1}" -o "${trim_dir}" >&2
  fi

  if trimmed="$(trimmed_fastq_path "${read1}" "${trim_dir}")"; then
    validate_trimmed_output "${sample}" "${trim_dir}" "${trimmed}" || return 1
    printf "%s\n\n" "${trimmed}"
    return 0
  fi

  echo "trim_galore finished but trimmed output not found for ${sample} in ${trim_dir}" >&2
  return 1
}

validate_trimmed_output() {
  local sample="$1"
  local trim_dir="$2"
  local trimmed_fastq="$3"
  local report

  if [[ ! -s "${trimmed_fastq}" ]]; then
    echo "Trim Galore did not produce a nonempty FASTQ for ${sample}: ${trimmed_fastq}" >&2
    return 1
  fi

  report="$(find "${trim_dir}" -maxdepth 1 -type f -name '*_trimming_report.txt' -print -quit)"
  if [[ -z "${report}" ]] || ! grep -q '^RUN STATISTICS FOR INPUT FILE:' "${report}"; then
    echo "Trim Galore did not write a complete report for ${sample}: ${trim_dir}" >&2
    return 1
  fi
}

validate_alignment_output() {
  local sample="$1"
  local bam="${repository}/results/${sample}/alignment/${sample}.bam"
  local bai="${bam}.bai"

  if [[ ! -s "${bam}" || ! -s "${bai}" ]]; then
    echo "Alignment did not produce final BAM and BAI for ${sample}: ${bam}" >&2
    return 1
  fi

  if ! samtools quickcheck -v "${bam}"; then
    echo "Alignment produced an invalid BAM for ${sample}: ${bam}" >&2
    return 1
  fi
}

alignment_retry_marker_path() {
  local sample="$1"
  printf '%s\n' "${repository}/results/${sample}/alignment/.retryable_tmp_workdir_missing"
}

run_alignment_module() {
  local sample="$1"
  local cfg="$2"
  local attempt marker

  for ((attempt = 1; attempt <= ALIGNMENT_MAX_ATTEMPTS; attempt++)); do
    echo "[RUN] ${sample} -> alignment (attempt ${attempt}/${ALIGNMENT_MAX_ATTEMPTS})"
    marker="$(alignment_retry_marker_path "${sample}")"

    if "${RIBOSEMAP_BIN}" alignment "${cfg}" && validate_alignment_output "${sample}"; then
      return 0
    fi

    if [[ ! -f "${marker}" || "${attempt}" -eq "${ALIGNMENT_MAX_ATTEMPTS}" ]]; then
      echo "[FAIL] ${sample} -> alignment failed without a retryable temporary-workdir loss." >&2
      return 1
    fi

    echo "[RETRY] ${sample} -> local alignment workdir disappeared; retrying alignment with a fresh workdir." >&2
  done
}

validate_coordinate_output() {
  local sample="$1"
  local bed

  bed="$(coordinate_bed_path "${sample}")"
  if [[ ! -f "${bed}" ]]; then
    echo "Coordinate module did not produce BED for ${sample}: ${bed}" >&2
    return 1
  fi
}

resolve_analysis_inputs() {
  local sample="$1"
  local input_mode="$2"
  local read1="$3"
  local read2="$4"
  local technique="$5"
  local pattern="$6"
  local trim_dir trimmed
  local analysis_read1="${read1}"
  local analysis_read2="${read2}"
  local mismatch_fastq=""
  local trim_profile=""
  local mismatch_platform=""
  local do_trim=0
  local trimmed_inputs_output
  local -a trimmed_inputs

  case "${input_mode}" in
    single_r1)
      mismatch_fastq="${read1}"
      mismatch_platform="illumina"
      ;;
    single_r2)
      mismatch_fastq="${read2}"
      mismatch_platform="aviti"
      ;;
    paired)
      ;;
    *)
      echo "Unsupported input mode: ${input_mode}" >&2
      return 1
      ;;
  esac

  case "${technique}" in
    ribose-seq)
      if [[ "${input_mode}" == "single_r1" && -n "${pattern}" ]]; then
        trim_profile="ribose-seq"
        do_trim=1
      fi
      ;;
    emRiboSeq)
      if [[ "${input_mode}" == "single_r1" ]]; then
        trim_profile="emRiboSeq"
        do_trim=1
      fi
      ;;
    RHII-HydEn-seq|Alk-HydEn-seq)
      if [[ "${input_mode}" == "paired" ]]; then
        trim_profile="${technique}"
        do_trim=1
      fi
      ;;
    Pu-seq)
      do_trim=0
      ;;
    "")
      if [[ "${input_mode}" == "single_r1" ]]; then
        trim_profile="ribose-seq"
        do_trim=1
      elif [[ "${input_mode}" == "single_r2" ]]; then
        trim_profile="aviti"
        do_trim=1
      fi
      ;;
    *)
      if [[ "${input_mode}" == "single_r2" ]]; then
        trim_profile="aviti"
        do_trim=1
      elif [[ "${input_mode}" == "single_r1" ]]; then
        trim_profile="ribose-seq"
        do_trim=1
      fi
      ;;
  esac

  if [[ "${RUN_TRIMMING}" -eq 1 && "${do_trim}" -eq 1 ]]; then
    # Command substitution preserves a trimming failure; process substitution
    # would let mapfile succeed even when prepare_trimmed_inputs fails.
    if ! trimmed_inputs_output="$(prepare_trimmed_inputs "${sample}" "${trim_profile}" "${read1}" "${read2}")"; then
      return 1
    fi
    mapfile -t trimmed_inputs <<< "${trimmed_inputs_output}"
    analysis_read1="${trimmed_inputs[0]:-}"
    analysis_read2="${trimmed_inputs[1]:-}"
    if [[ "${input_mode}" == "single_r1" ]]; then
      mismatch_fastq="${analysis_read1}"
    elif [[ "${input_mode}" == "single_r2" ]]; then
      mismatch_fastq="${analysis_read2}"
    fi
    printf "%s\n%s\n%s\n%s\n" "${analysis_read1}" "${analysis_read2}" "${mismatch_fastq}" "${mismatch_platform}"
    return 0
  fi

  if [[ "${RUN_TRIMMING}" -eq 1 && "${do_trim}" -eq 0 ]]; then
    echo "[RUN] ${sample} -> trimming skipped (technique=${technique:-base-default})" >&2
  fi

  if [[ "${input_mode}" != "paired" ]]; then
    trim_dir="${repository}/results/${sample}/trim_galore"
    if trimmed="$(trimmed_fastq_path "${mismatch_fastq}" "${trim_dir}")"; then
      echo "[RUN] ${sample} -> reusing trimmed FASTQ ${trimmed}" >&2
      if [[ "${input_mode}" == "single_r1" ]]; then
        analysis_read1="${trimmed}"
      else
        analysis_read1=""
        analysis_read2="${trimmed}"
      fi
      mismatch_fastq="${trimmed}"
    fi
  fi

  printf "%s\n%s\n%s\n%s\n" "${analysis_read1}" "${analysis_read2}" "${mismatch_fastq}" "${mismatch_platform}"
}

generate_config() {
  local sample="$1"
  local barcode="$2"
  local read1="$3"
  local read2="$4"
  local technique_field="$5"
  local pattern_field="$6"
  local frag_method_field="$7"
  local cfg="${GENERATED_DIR}/${sample}.config"
  local abs_base
  local technique_override=""
  local pattern_override=""
  local frag_method_override=""

  abs_base="$(cd "$(dirname "${BASE_CONFIG}")" && pwd)/$(basename "${BASE_CONFIG}")"
  technique_override="$(normalize_config_override "${technique_field}" || true)"
  pattern_override="$(normalize_config_override "${pattern_field}" || true)"
  frag_method_override="$(normalize_frag_method "${frag_method_field}" || true)"

  {
    echo "# Auto-generated by scripts/run_multi_sample.sh"
    echo ". $(sq "${abs_base}")"
    # This must follow the base config source so every module uses the
    # timestamped repository rather than the reusable base repository.
    echo "repository=$(sq "${repository}")"
    echo "sample=$(sq "${sample}")"
    # Keep the base config immutable while making the requested MAPQ threshold
    # explicit in each generated config and therefore its coordinate directory.
    echo "quality=$(sq "${quality}")"

    if [[ -n "${barcode}" ]]; then
      echo "barcode=$(sq "${barcode}")"
    else
      echo "barcode=''"
    fi

    if [[ "${technique_field}" != "${UNSET_SENTINEL}" ]]; then
      echo "technique=$(sq "${technique_override}")"
    fi
    if [[ "${pattern_field}" != "${UNSET_SENTINEL}" ]]; then
      echo "pattern=$(sq "${pattern_override}")"
    fi
    if [[ "${frag_method_field}" != "${UNSET_SENTINEL}" ]]; then
      echo "frag_method=$(sq "${frag_method_override}")"
    fi

    echo "read1=$(sq "${read1}")"
    echo "read2=$(sq "${read2}")"
  } > "${cfg}"

  echo "${cfg}"
}

coordinate_bed_dir() {
  local sample="$1"
  printf '%s\n' "${repository}/results/${sample}/coordinate${quality}"
}

coordinate_bed_path() {
  local sample="$1"
  printf '%s\n' "$(coordinate_bed_dir "${sample}")/${sample}.bed"
}

coordinate_bed_backup_path() {
  local sample="$1"
  printf '%s\n' "$(coordinate_bed_dir "${sample}")/${sample}.coordinate.bed"
}

source_coordinate_bed_for_recorrect() {
  local sample="$1"
  local backup_bed coord_bed

  backup_bed="$(coordinate_bed_backup_path "${sample}")"
  coord_bed="$(coordinate_bed_path "${sample}")"

  if [[ -f "${backup_bed}" ]]; then
    printf '%s\n' "${backup_bed}"
    return 0
  fi

  printf '%s\n' "${coord_bed}"
}

active_sample_bed_path() {
  local sample="$1"
  local technique_value="$2"
  local frag_method_value="$3"
  local corrected_bed

  # Keep coordinate##/<sample>.bed immutable after coordinate.  Only eligible
  # ribose-seq samples consume the separate restriction-corrected BED.
  if re_correct_should_run "${technique_value}" "${frag_method_value}"; then
    corrected_bed="$(coordinate_bed_dir "${sample}")/re_correct/${sample}.bed"
    printf '%s\n' "${corrected_bed}"
  else
    source_coordinate_bed_for_recorrect "${sample}"
  fi
}

materialize_recorrect_fastq() {
  local sample="$1"
  local input_fastq="$2"
  local out_dir="$3"
  local out_fastq="${out_dir}/${sample}.fq"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[DRY-RUN] ${sample} -> prepare re_correct fastq ${out_fastq} from ${input_fastq}" >&2
    echo "${out_fastq}"
    return 0
  fi

  mkdir -p "${out_dir}"
  if [[ "${input_fastq}" == *.gz ]]; then
    gzip -dc "${input_fastq}" > "${out_fastq}"
  else
    cp -f "${input_fastq}" "${out_fastq}"
  fi

  echo "${out_fastq}"
}

run_recorrect_module() {
  local sample="$1"
  local re_fastq="$2"
  local technique_value="$3"
  local pattern_value="$4"
  local frag_method_value="$5"
  local re_out coord_input_bed coord_input_dir workbook genome_dir sample_genome re_tmp raw_dir list_file normalized_enzymes d_value corrected_bed

  if ! re_correct_should_run "${technique_value}" "${frag_method_value}"; then
    echo "[RUN] ${sample} -> re_correct skipped (technique=${technique_value:-unset}, frag_method=${frag_method_value:-unset})" >&2
    return 0
  fi

  if [[ "${re_fastq}" == "-" || -z "${re_fastq}" ]]; then
    echo "re_correct requires a single-end FASTQ input for ${sample}." >&2
    return 1
  fi
  if [[ -z "${pattern_value}" ]]; then
    echo "re_correct requires a non-empty pattern for eligible ribose-seq samples (${sample})." >&2
    return 1
  fi
  if ! d_value="$(pattern_length "${pattern_value}")"; then
    echo "Unable to derive re_correct -d from pattern for ${sample}." >&2
    return 1
  fi
  if ! normalized_enzymes="$(normalize_re_enzymes "${frag_method_value}")"; then
    echo "Unable to normalize frag_method for ${sample}: ${frag_method_value}" >&2
    return 1
  fi

  coord_input_bed="$(source_coordinate_bed_for_recorrect "${sample}")"
  coord_input_dir="$(dirname "${coord_input_bed}")"
  re_out="$(coordinate_bed_dir "${sample}")/re_correct"
  corrected_bed="${re_out}/${sample}.bed"
  workbook="${re_out}/${sample}.re_correct.xlsx"
  genome_dir="$(dirname "${fasta}")"
  sample_genome="$(basename "${fasta}")"
  sample_genome="${sample_genome%.fa}"
  sample_genome="${sample_genome%.fasta}"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if [[ ! -f "${coord_input_bed}" ]]; then
      echo "re_correct needs coordinate output: missing ${coord_input_bed}" >&2
      return 1
    fi
    mkdir -p "${re_out}"
  fi

  re_tmp="$(mktemp -d "${TMP_DIR}/re_correct.${sample}.XXXXXX")"
  raw_dir="${re_tmp}/raw_reads"
  list_file="${re_tmp}/${sample}.list"

  printf '%s\t%s\t%s\n' "${sample}" "${sample_genome}" "${normalized_enzymes}" > "${list_file}"
  materialize_recorrect_fastq "${sample}" "${re_fastq}" "${raw_dir}" >/dev/null

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[DRY-RUN] ${sample} -> python3 ${RE_CORRECT_BIN} ${list_file} ${raw_dir} -o ${workbook} -d ${d_value} --subtracted_output ${re_out} --bed ${coord_input_dir} --genome ${genome_dir} --RElist ${RE_CORRECT_LIST}" >&2
    return 0
  fi

  echo "[RUN] ${sample} -> re_correct"
  python3 "${RE_CORRECT_BIN}" \
    "${list_file}" \
    "${raw_dir}" \
    -o "${workbook}" \
    -d "${d_value}" \
    --subtracted_output "${re_out}" \
    --bed "${coord_input_dir}" \
    --genome "${genome_dir}" \
    --RElist "${RE_CORRECT_LIST}"

  if [[ ! -f "${corrected_bed}" ]]; then
    echo "re_correct finished but corrected BED not found for ${sample}: ${corrected_bed}" >&2
    return 1
  fi

}

materialize_mismatch_fastq() {
  local sample="$1"
  local input_fastq="$2"
  local out_dir out_fastq

  out_dir="$(coordinate_bed_dir "${sample}")/mismatch/input_fastq"
  out_fastq="${out_dir}/${sample}.fq"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[DRY-RUN] ${sample} -> prepare mismatch fastq ${out_fastq} from ${input_fastq}" >&2
    echo "${out_fastq}"
    return 0
  fi

  mkdir -p "${out_dir}"

  if [[ "${input_fastq}" == *.gz ]]; then
    gzip -dc "${input_fastq}" > "${out_fastq}"
  else
    cp -f "${input_fastq}" "${out_fastq}"
  fi

  echo "${out_fastq}"
}

run_mismatch_module() {
  local sample="$1"
  local cfg="$2"
  local analysis_fastq="$3"
  local platform="$4"

  local sample_bed mm_out mm_fastq
  local pymatch rrmpolyn mm_analysis poly_file matches_file mismatch_repo
  local mm_fastq_cleanup_path=""

  # shellcheck disable=SC1090
  . "${cfg}"

  sample_bed="$(active_sample_bed_path "${sample}" "${technique:-}" "${frag_method:-}")"
  mm_out="$(coordinate_bed_dir "${sample}")/mismatch"

  if [[ "${platform}" == "illumina" ]]; then
    mismatch_repo="${MISMATCH_REPO_ILLUMINA}"
  elif [[ "${platform}" == "aviti" ]]; then
    mismatch_repo="${MISMATCH_REPO_AVITI}"
  else
    echo "Unsupported mismatch platform: ${platform}" >&2
    return 1
  fi

  pymatch="${mismatch_repo}/match_analysis.py"
  rrmpolyn="${mismatch_repo}/removepolyN.R"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if [[ ! -f "${sample_bed}" ]]; then
      echo "Mismatch module needs coordinate/re_correct output: missing ${sample_bed}" >&2
      return 1
    fi
    if [[ ! -f "${pymatch}" || ! -f "${rrmpolyn}" ]]; then
      echo "Mismatch repo missing required files under ${mismatch_repo}" >&2
      return 1
    fi
    mkdir -p "${mm_out}"
  fi

  cleanup_mismatch_fastq() {
    local mm_cleanup_rc="$?"
    if [[ -n "${mm_fastq_cleanup_path:-}" && "${CLEANUP_MISMATCH_FASTQ}" -eq 1 ]]; then
      rm -f "${mm_fastq_cleanup_path}"
      rmdir "$(dirname "${mm_fastq_cleanup_path}")" 2>/dev/null || true
    fi
    return "${mm_cleanup_rc}"
  }
  trap cleanup_mismatch_fastq RETURN

  mm_fastq="$(materialize_mismatch_fastq "${sample}" "${analysis_fastq}")"
  mm_fastq_cleanup_path="${mm_fastq}"
  mm_analysis="${mm_out}/MManalysis_${sample}.bed"
  poly_file="${mm_out}/poly_MManalysis_${sample}.bed"
  matches_file="${mm_out}/matches_MManalysis_${sample}.bed"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[DRY-RUN] ${sample} -> python3 ${pymatch} ${sample_bed} ${fasta} ${mm_fastq} -n ${MISMATCH_POLYN} -o ${mm_out}/MManalysis"
    echo "[DRY-RUN] ${sample} -> awk filter to ${poly_file} and ${matches_file}"
    echo "[DRY-RUN] ${sample} -> Rscript ${rrmpolyn} -f ${matches_file} -c 4 -t ${MISMATCH_NTAIL} -n ${MISMATCH_POLYN} -o ${mm_out}"
    return 0
  fi

  echo "[RUN] ${sample} -> mismatch analysis (${platform})"
  python3 "${pymatch}" "${sample_bed}" "${fasta}" "${mm_fastq}" -n "${MISMATCH_POLYN}" -o "${mm_out}/MManalysis"

  if [[ ! -f "${mm_analysis}" ]]; then
    echo "Mismatch analysis did not produce its annotated BED for ${sample}: ${mm_analysis}" >&2
    return 1
  fi

  awk 'BEGIN{FS=OFS="\t"}{print $1,$2,$3,$4,$5,$6,substr($4,length($4),1),substr($5,length($5),1),$7}' \
    "${mm_analysis}" > "${poly_file}"

  awk 'BEGIN{FS=OFS="\t"}{if($7==$8) print $0}' "${poly_file}" > "${matches_file}"

  # removepolyN.R cannot read an empty table.  No matching calls is a valid
  # result, so materialize the same empty final BED that the R script would use.
  if [[ ! -s "${matches_file}" ]]; then
    local empty_final
    empty_final="$(predicted_mismatch_final_bed_path "${sample}")"
    : > "${empty_final}"
    echo "[RUN] ${sample} -> mismatch produced no matching calls; wrote empty final BED" >&2
    return 0
  fi

  Rscript "${rrmpolyn}" -f "${matches_file}" -c 4 -t "${MISMATCH_NTAIL}" -n "${MISMATCH_POLYN}" -o "${mm_out}"

  local final_bed
  final_bed="$(predicted_mismatch_final_bed_path "${sample}")"
  if [[ ! -f "${final_bed}" ]]; then
    echo "Mismatch filtering did not produce final BED for ${sample}: ${final_bed}" >&2
    return 1
  fi
}

mismatch_final_suffix_index() {
  # removepolyN.R names its final file using the loop index minus one.
  printf '%d\n' "$((MISMATCH_POLYN - 1))"
}

mismatch_final_bed_path() {
  local sample="$1"
  local mm_out="$(coordinate_bed_dir "${sample}")/mismatch"
  local ntail_kmer="" suffix_index=""
  local expected_bed=""
  local discovered_bed=""

  if [[ -n "${MISMATCH_NTAIL}" ]]; then
    ntail_kmer="$(printf "%${MISMATCH_POLYN}s" "" | tr " " "${MISMATCH_NTAIL}")"
    suffix_index="$(mismatch_final_suffix_index)"
    expected_bed="${mm_out}/matches_MManalysis_${sample}_${ntail_kmer}_${suffix_index}_final.bed"
    if [[ -f "${expected_bed}" ]]; then
      printf '%s\n' "${expected_bed}"
      return 0
    fi
  fi

  discovered_bed="$(find "${mm_out}" -maxdepth 1 -type f -name "matches_MManalysis_${sample}*_final.bed" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)"
  if [[ -n "${discovered_bed}" && -f "${discovered_bed}" ]]; then
    printf '%s\n' "${discovered_bed}"
    return 0
  fi

  return 1
}

predicted_mismatch_final_bed_path() {
  local sample="$1"
  local ntail_kmer="" suffix_index=""

  if [[ -n "${MISMATCH_NTAIL}" ]]; then
    ntail_kmer="$(printf "%${MISMATCH_POLYN}s" "" | tr " " "${MISMATCH_NTAIL}")"
  fi
  suffix_index="$(mismatch_final_suffix_index)"
  printf '%s\n' "$(coordinate_bed_dir "${sample}")/mismatch/matches_MManalysis_${sample}_${ntail_kmer}_${suffix_index}_final.bed"
}

materialize_final_bed() {
  local sample="$1"
  local technique_value="$2"
  local final_dir final_bed source_bed

  final_dir="$(coordinate_bed_dir "${sample}")/final"
  final_bed="${final_dir}/${sample}.bed"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    case "${technique_value}" in
      ribose-seq)
        source_bed="$(predicted_mismatch_final_bed_path "${sample}")"
        ;;
      emRiboSeq|RHII-HydEn-seq|Alk-HydEn-seq|Pu-seq)
        source_bed="$(source_coordinate_bed_for_recorrect "${sample}")"
        ;;
      *)
        echo "Cannot determine final BED workflow for ${sample}: unsupported technique '${technique_value:-unset}'." >&2
        return 1
        ;;
    esac
    echo "[DRY-RUN] ${sample} -> copy ${source_bed} to ${final_bed}" >&2
    return 0
  fi

  case "${technique_value}" in
    ribose-seq)
      if ! source_bed="$(mismatch_final_bed_path "${sample}")"; then
        echo "Final BED for ribose-seq sample ${sample} requires mismatch output: $(coordinate_bed_dir "${sample}")/mismatch/matches_MManalysis_${sample}*_final.bed" >&2
        return 1
      fi
      ;;
    emRiboSeq|RHII-HydEn-seq|Alk-HydEn-seq|Pu-seq)
      source_bed="$(source_coordinate_bed_for_recorrect "${sample}")"
      ;;
    *)
      echo "Cannot determine final BED workflow for ${sample}: unsupported technique '${technique_value:-unset}'." >&2
      return 1
      ;;
  esac

  if [[ ! -f "${source_bed}" ]]; then
    echo "Final BED source missing for ${sample}: ${source_bed}" >&2
    return 1
  fi

  mkdir -p "${final_dir}"
  cp -f "${source_bed}" "${final_bed}"
  echo "[RUN] ${sample} -> final BED ${final_bed}" >&2
}

run_remove_mxy_module() {
  local sample="$1"
  local mm_out filtered_dir final_bed out_bed ntail_kmer suffix_index

  mm_out="$(coordinate_bed_dir "${sample}")/mismatch"
  filtered_dir="$(coordinate_bed_dir "${sample}")/filtered_bed"
  ntail_kmer=""
  if [[ -n "${MISMATCH_NTAIL}" ]]; then
    ntail_kmer="$(printf "%${MISMATCH_POLYN}s" "" | tr " " "${MISMATCH_NTAIL}")"
  fi
  suffix_index="$(mismatch_final_suffix_index)"

  final_bed=""
  if [[ -n "${ntail_kmer}" ]]; then
    final_bed="${mm_out}/matches_MManalysis_${sample}_${ntail_kmer}_${suffix_index}_final.bed"
    if [[ ! -f "${final_bed}" ]]; then
      final_bed=""
    fi
  fi
  if [[ -z "${final_bed}" ]]; then
    final_bed="$(ls -1t "${mm_out}/matches_MManalysis_${sample}"*_final.bed 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "${final_bed}" ]]; then
    echo "removeMXY needs mismatch final bed: missing ${mm_out}/matches_MManalysis_${sample}*_final.bed" >&2
    return 1
  fi

  out_bed="${filtered_dir}/${sample}_no_chrMXY.bed"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[DRY-RUN] ${sample} -> ${REMOVE_MXY_BIN} ${final_bed} ${out_bed}"
    return 0
  fi

  mkdir -p "${filtered_dir}"
  echo "[RUN] ${sample} -> removeMXY (${out_bed})"
  "${REMOVE_MXY_BIN}" "${final_bed}" "${out_bed}"
}

run_one_sample() {
  local sample="$1"
  local raw_barcode="$2"
  local read1="$3"
  local read2="$4"
  local technique_field="$5"
  local pattern_field="$6"
  local frag_method_field="$7"

  local inferred input_mode input_read1 input_read2 processed_barcode analysis_fastq cfg inferred_output resolved_output
  local analysis_read1 analysis_read2 mismatch_platform technique_override pattern_override frag_method_override effective_technique effective_pattern effective_frag_method
  local mod
  local sample_modules
  local -a inferred_fields resolved_fields

  if ! inferred_output="$(classify_input_layout "${read1}" "${read2}")"; then
    return 1
  fi
  mapfile -t inferred_fields <<< "${inferred_output}"
  input_mode="${inferred_fields[0]:-}"
  input_read1="${inferred_fields[1]:-}"
  input_read2="${inferred_fields[2]:-}"
  technique_override="$(normalize_config_override "${technique_field}" || true)"
  pattern_override="$(normalize_config_override "${pattern_field}" || true)"
  frag_method_override="$(normalize_frag_method "${frag_method_field}" || true)"

  if [[ "${technique_field}" == "${UNSET_SENTINEL}" ]]; then
    effective_technique="${technique:-}"
  else
    effective_technique="${technique_override}"
  fi

  if [[ "${pattern_field}" == "${UNSET_SENTINEL}" ]]; then
    effective_pattern="${pattern:-}"
  else
    effective_pattern="${pattern_override}"
  fi

  if [[ "${frag_method_field}" == "${UNSET_SENTINEL}" ]]; then
    effective_frag_method="${frag_method:-}"
  else
    effective_frag_method="${frag_method_override}"
  fi

  processed_barcode="$(reverse_complement_barcode "${raw_barcode}")"
  if ! resolved_output="$(resolve_analysis_inputs "${sample}" "${input_mode}" "${input_read1}" "${input_read2}" "${effective_technique}" "${effective_pattern}")"; then
    echo "[FAIL] ${sample} -> trimming/input preparation failed" >&2
    return 1
  fi
  mapfile -t resolved_fields <<< "${resolved_output}"
  analysis_read1="${resolved_fields[0]:-}"
  analysis_read2="${resolved_fields[1]:-}"
  analysis_fastq="${resolved_fields[2]:-}"
  mismatch_platform="${resolved_fields[3]:-}"

  cfg="$(generate_config "${sample}" "${processed_barcode}" "${analysis_read1}" "${analysis_read2}" "${technique_field}" "${pattern_field}" "${frag_method_field}")"

  echo "[START] ${sample} (input_mode=${input_mode}, technique=${effective_technique:-${technique:-unset}}, config=${cfg})"

  IFS=',' read -r -a sample_modules <<< "${MODULES}"
  for mod in "${sample_modules[@]}"; do
    case "${mod}" in
      trimming)
        :
        ;;
      re_correct)
        run_recorrect_module "${sample}" "${analysis_fastq}" "${effective_technique}" "${effective_pattern}" "${effective_frag_method}"
        ;;
      mismatch)
        if [[ "${effective_technique}" != "ribose-seq" ]]; then
          echo "[RUN] ${sample} -> mismatch skipped (technique=${effective_technique:-unset})" >&2
          continue
        fi
        if [[ -z "${analysis_fastq}" ]]; then
          echo "Mismatch module is only supported for single-end inputs in this wrapper." >&2
          return 1
        fi
        run_mismatch_module "${sample}" "${cfg}" "${analysis_fastq}" "${mismatch_platform}"
        ;;
      removeMXY)
        run_remove_mxy_module "${sample}"
        ;;
      coordinate)
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          echo "[DRY-RUN] ${sample} -> ${RIBOSEMAP_BIN} coordinate ${cfg} (output=$(coordinate_bed_dir "${sample}"))"
        else
          echo "[RUN] ${sample} -> coordinate"
          "${RIBOSEMAP_BIN}" coordinate "${cfg}"
          validate_coordinate_output "${sample}"
        fi
        ;;
      *)
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          echo "[DRY-RUN] ${sample} -> ${RIBOSEMAP_BIN} ${mod} ${cfg}"
        else
          if [[ "${mod}" == "alignment" ]]; then
            run_alignment_module "${sample}" "${cfg}"
          else
            echo "[RUN] ${sample} -> ${mod}"
            "${RIBOSEMAP_BIN}" "${mod}" "${cfg}"
          fi
        fi
        ;;
    esac
  done

  if [[ "${effective_technique}" == "ribose-seq" && "${RUN_MISMATCH}" -eq 0 ]]; then
    echo "[RUN] ${sample} -> final BED pending (ribose-seq requires mismatch)" >&2
  else
    materialize_final_bed "${sample}" "${effective_technique}"
  fi

  echo "[DONE] ${sample}"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ribose-map-multi.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
TASKS_FILE="${TMP_DIR}/tasks.tsv"

awk -F '\t' '
  NR==1 {
    for (i = 1; i <= NF; i++) {
      idx[$i] = i
    }
    if (idx["sample"] != 1 || idx["barcode"] != 2 || idx["read1"] != 3) {
      print "Header must start with: sample<TAB>barcode<TAB>read1" > "/dev/stderr"
      exit 2
    }
    next
  }
  NF==0 { next }
  /^#/ { next }
  {
    sample=$idx["sample"]
    barcode=$idx["barcode"]
    read1=$idx["read1"]
    read2=(("read2" in idx) ? $(idx["read2"]) : "")
    technique=(("technique" in idx) ? $(idx["technique"]) : "'"${UNSET_SENTINEL}"'")
    pattern=(("pattern" in idx) ? $(idx["pattern"]) : "'"${UNSET_SENTINEL}"'")
    frag_method=(("frag_method" in idx) ? $(idx["frag_method"]) : "'"${UNSET_SENTINEL}"'")

    if (sample == "") {
      print "Invalid row (sample required): " $0 > "/dev/stderr"
      exit 3
    }

    print sample "\t" barcode "\t" read1 "\t" read2 "\t" technique "\t" pattern "\t" frag_method
  }
' "${SAMPLES_TSV}" > "${TASKS_FILE}"

if [[ ! -s "${TASKS_FILE}" ]]; then
  echo "No samples found in ${SAMPLES_TSV}" >&2
  exit 1
fi

export ROOT_DIR RIBOSEMAP_BIN REMOVE_MXY_BIN RE_CORRECT_BIN RE_CORRECT_LIST BASE_CONFIG GENERATED_DIR MODULES DRY_RUN RUN_ID ALIGNMENT_MAX_ATTEMPTS repository fasta quality UNSET_SENTINEL TMP_DIR
export RUN_TRIMMING RUN_MISMATCH RUN_RE_CORRECT MISMATCH_REPO_ILLUMINA MISMATCH_REPO_AVITI MISMATCH_POLYN MISMATCH_NTAIL CLEANUP_MISMATCH_FASTQ
export -f sq reverse_complement_barcode normalize_config_override normalize_frag_method re_correct_should_run pattern_length normalize_re_enzymes
export -f trimmed_fastq_path predicted_trimmed_fastq_path predicted_trimmed_paired_fastq_paths trimmed_paired_fastq_paths classify_input_layout prepare_trimmed_inputs resolve_analysis_inputs validate_trimmed_output validate_alignment_output validate_coordinate_output alignment_retry_marker_path run_alignment_module
export -f generate_config coordinate_bed_dir coordinate_bed_path coordinate_bed_backup_path source_coordinate_bed_for_recorrect active_sample_bed_path
export -f materialize_recorrect_fastq run_recorrect_module materialize_mismatch_fastq run_mismatch_module mismatch_final_suffix_index mismatch_final_bed_path predicted_mismatch_final_bed_path materialize_final_bed run_remove_mxy_module run_one_sample

if [[ "${JOBS}" -eq 1 ]]; then
  while IFS=$'\t' read -r sample barcode read1 read2 technique pattern frag_method; do
    run_one_sample "${sample}" "${barcode}" "${read1}" "${read2}" "${technique}" "${pattern}" "${frag_method}"
  done < "${TASKS_FILE}"
else
  xargs -a "${TASKS_FILE}" -d $'\n' -P "${JOBS}" -I '{}' bash -lc '
    IFS=$'\''\t'\'' read -r sample barcode read1 read2 technique pattern frag_method <<< "{}"
    run_one_sample "$sample" "$barcode" "$read1" "$read2" "$technique" "$pattern" "$frag_method"
  '
fi

echo "All requested samples completed."
