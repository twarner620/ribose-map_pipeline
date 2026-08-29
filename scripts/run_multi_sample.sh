#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/run_multi_sample.sh -s <samples.tsv> -b <base.config> [-m <modules>] [-j <jobs>] [-o <generated_config_dir>] [--dry-run]

Run Ribose-Map modules for multiple samples.

Required:
  -s  Tab-delimited sample sheet with header: sample<TAB>barcode<TAB>read1[<TAB>read2]
  -b  Base config containing shared settings (technique, repository, genome paths, etc.)

Optional:
  -m  Comma-separated module list
      (default: trimming,alignment,coordinate,mismatch,removeMXY,composition,sequence,distribution,hotspot)
  -j  Number of samples to run in parallel (default: 1)
  -o  Directory to write generated per-sample configs (default: config/generated)
      --dry-run Generate configs and print planned commands without running modules
      --keep-mismatch-fastq Keep temporary mismatch FASTQ under results/<sample>/mismatch/input_fastq

Platform behavior is inferred per sample row:
  illumina: read1 is set and read2 is '-' or empty
  aviti:    read2 is set and read1 is '-' or empty

If both read1/read2 are set (or both missing), the sample row is rejected.
USAGE
}

SAMPLES_TSV=""
BASE_CONFIG=""
MODULES="trimming,alignment,coordinate,mismatch,removeMXY,composition,sequence,distribution,hotspot"
JOBS=1
GENERATED_DIR="config/generated"
DRY_RUN=0
CLEANUP_MISMATCH_FASTQ=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --keep-mismatch-fastq) CLEANUP_MISMATCH_FASTQ=0; shift ;;
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
if [[ -z "${fasta:-}" ]]; then
  echo "fasta is not set in ${BASE_CONFIG}" >&2
  exit 1
fi
if [[ -z "${quality:-}" ]]; then
  echo "quality is not set in ${BASE_CONFIG}" >&2
  exit 1
fi

DEFAULT_MM_REPO_ILLUMINA="/storage/home/hcoda1/8/twarner31/r-fstorici3-0/mismatch/rNMP_match_analysis_illumina"
DEFAULT_MM_REPO_AVITI="/storage/home/hcoda1/8/twarner31/r-fstorici3-0/mismatch/rNMP_match_analysis_Aviti"
LEGACY_MISMATCH_REPO="${mismatch_repo:-}"
MISMATCH_REPO_ILLUMINA="${mismatch_repo_illumina:-${LEGACY_MISMATCH_REPO:-$DEFAULT_MM_REPO_ILLUMINA}}"
MISMATCH_REPO_AVITI="${mismatch_repo_aviti:-${LEGACY_MISMATCH_REPO:-$DEFAULT_MM_REPO_AVITI}}"
MISMATCH_POLYN="${mismatch_polyN:-5}"
MISMATCH_NTAIL="${mismatch_ntail:-A}"

mkdir -p "${GENERATED_DIR}"

IFS=',' read -r -a MODULE_ARRAY <<< "${MODULES}"
RUN_TRIMMING=0
RUN_MISMATCH=0
for mod in "${MODULE_ARRAY[@]}"; do
  case "${mod}" in
    trimming)
      RUN_TRIMMING=1
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

resolve_analysis_fastq() {
  local sample="$1"
  local platform="$2"
  local platform_read="$3"
  local trim_dir trimmed

  if [[ "${RUN_TRIMMING}" -eq 1 ]]; then
    prepare_trimmed_fastq "${sample}" "${platform}" "${platform_read}"
    return $?
  fi

  trim_dir="${repository}/results/${sample}/trim_galore"
  if trimmed="$(trimmed_fastq_path "${platform_read}" "${trim_dir}")"; then
    echo "[RUN] ${sample} -> reusing trimmed FASTQ ${trimmed}" >&2
    echo "${trimmed}"
    return 0
  fi

  echo "${platform_read}"
}

infer_platform_and_read() {
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
    printf "illumina\t%s\n" "${read1}"
    return 0
  fi
  if [[ "${has_r1}" -eq 0 && "${has_r2}" -eq 1 ]]; then
    printf "aviti\t%s\n" "${read2}"
    return 0
  fi

  echo "Exactly one of read1/read2 must be provided per sample row." >&2
  return 1
}

prepare_trimmed_fastq() {
  local sample="$1"
  local platform="$2"
  local platform_read="$3"
  local trim_dir trimmed
  local trim_adapter
  local trim_length
  local trim_q

  case "${platform}" in
    illumina)
      trim_adapter="AGTTGCGACACGGATCTATCA"
      trim_length="62"
      trim_q="15"
      ;;
    aviti)
      trim_adapter="AGTTGACAAGCGGTAGCCTGCACACCTTCCGACAT"
      trim_length="50"
      trim_q="15"
      ;;
    *)
      echo "Unsupported inferred platform: ${platform}" >&2
      return 1
      ;;
  esac

  trim_dir="${repository}/results/${sample}/trim_galore"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    if [[ -n "${trim_q}" ]]; then
      echo "[DRY-RUN] ${sample} -> trim_galore ${platform_read} -a ${trim_adapter} -q ${trim_q} --length ${trim_length}" >&2
    else
      echo "[DRY-RUN] ${sample} -> trim_galore ${platform_read} -a ${trim_adapter} --length ${trim_length}" >&2
    fi
    echo "${platform_read}"
    return 0
  fi

  # Always rerun trimming to keep runs fresh.
  rm -rf "${trim_dir}"
  mkdir -p "${trim_dir}"

  echo "[RUN] ${sample} -> trim_galore (${platform})" >&2
  if [[ -n "${trim_q}" ]]; then
    trim_galore "${platform_read}" -a "${trim_adapter}" -q "${trim_q}" --length "${trim_length}" --output_dir "${trim_dir}" >&2
  else
    trim_galore "${platform_read}" -a "${trim_adapter}" --length "${trim_length}" --output_dir "${trim_dir}" >&2
  fi

  if trimmed="$(trimmed_fastq_path "${platform_read}" "${trim_dir}")"; then
    echo "${trimmed}"
    return 0
  fi

  echo "trim_galore finished but trimmed output not found for ${sample} in ${trim_dir}" >&2
  return 1
}

generate_config() {
  local sample="$1"
  local barcode="$2"
  local read1="$3"
  local cfg="${GENERATED_DIR}/${sample}.config"
  local abs_base

  abs_base="$(cd "$(dirname "${BASE_CONFIG}")" && pwd)/$(basename "${BASE_CONFIG}")"

  {
    echo "# Auto-generated by scripts/run_multi_sample.sh"
    echo ". $(sq "${abs_base}")"
    echo "sample=$(sq "${sample}")"

    if [[ -n "${barcode}" ]]; then
      echo "barcode=$(sq "${barcode}")"
    else
      echo "barcode=''"
    fi

    echo "read1=$(sq "${read1}")"
    echo "read2=''"
  } > "${cfg}"

  echo "${cfg}"
}

materialize_mismatch_fastq() {
  local sample="$1"
  local input_fastq="$2"
  local out_dir out_fastq

  out_dir="${repository}/results/${sample}/mismatch/input_fastq"
  out_fastq="${out_dir}/${sample}.fq"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[DRY-RUN] ${sample} -> prepare mismatch fastq ${out_fastq} from ${input_fastq}" >&2
    echo "${out_fastq}"
    return 0
  fi

  mkdir -p "${out_dir}"

  # Always regenerate mismatch fastq input for a fresh run.
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

  local coord_dir sample_bed mm_out mm_fastq
  local pymatch rrmpolyn mm_analysis poly_file matches_file mismatch_repo
  local mm_fastq_cleanup_path=""

  # shellcheck disable=SC1090
  . "${cfg}"

  coord_dir="${repository}/results/${sample}/coordinate${quality}"
  sample_bed="${coord_dir}/${sample}.bed"
  mm_out="${repository}/results/${sample}/mismatch"

  if [[ "${platform}" == "illumina" ]]; then
    mismatch_repo="${MISMATCH_REPO_ILLUMINA}"
  elif [[ "${platform}" == "aviti" ]]; then
    mismatch_repo="${MISMATCH_REPO_AVITI}"
  else
    echo "Unsupported inferred platform for mismatch: ${platform}" >&2
    return 1
  fi

  pymatch="${mismatch_repo}/match_analysis.py"
  rrmpolyn="${mismatch_repo}/removepolyN.R"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if [[ ! -f "${sample_bed}" ]]; then
      echo "Mismatch module needs coordinate output: missing ${sample_bed}" >&2
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

  awk 'BEGIN{FS=OFS="\t"}{print $1,$2,$3,$4,$5,$6,substr($4,length($4),1),substr($5,length($5),1),$7}' \
    "${mm_analysis}" > "${poly_file}"

  awk 'BEGIN{FS=OFS="\t"}{if($7==$8) print $0}' "${poly_file}" > "${matches_file}"

  Rscript "${rrmpolyn}" -f "${matches_file}" -c 4 -t "${MISMATCH_NTAIL}" -n "${MISMATCH_POLYN}" -o "${mm_out}"
}

run_remove_mxy_module() {
  local sample="$1"
  local mm_out filtered_dir final_bed out_bed ntail_kmer

  mm_out="${repository}/results/${sample}/mismatch"
  filtered_dir="${repository}/results/${sample}/filtered_bed"
  ntail_kmer=""
  if [[ -n "${MISMATCH_NTAIL}" ]]; then
    ntail_kmer="$(printf "%${MISMATCH_POLYN}s" "" | tr " " "${MISMATCH_NTAIL}")"
  fi

  final_bed=""
  if [[ -n "${ntail_kmer}" ]]; then
    final_bed="${mm_out}/matches_MManalysis_${sample}_${ntail_kmer}_${MISMATCH_POLYN}_final.bed"
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

  local inferred platform platform_read processed_barcode analysis_fastq cfg
  local mod
  local sample_modules

  inferred="$(infer_platform_and_read "${read1}" "${read2}")"
  platform="${inferred%%$'\t'*}"
  platform_read="${inferred#*$'\t'}"

  processed_barcode="$(reverse_complement_barcode "${raw_barcode}")"
  if ! analysis_fastq="$(resolve_analysis_fastq "${sample}" "${platform}" "${platform_read}")"; then
    echo "[FAIL] ${sample} -> trimming/input preparation failed" >&2
    return 1
  fi

  cfg="$(generate_config "${sample}" "${processed_barcode}" "${analysis_fastq}")"

  echo "[START] ${sample} (platform=${platform}, config=${cfg})"

  IFS=',' read -r -a sample_modules <<< "${MODULES}"
  for mod in "${sample_modules[@]}"; do
    case "${mod}" in
      trimming)
        if [[ "${RUN_TRIMMING}" -eq 1 ]]; then
          echo "[RUN] ${sample} -> trimming complete"
        fi
        ;;
      mismatch)
        run_mismatch_module "${sample}" "${cfg}" "${analysis_fastq}" "${platform}"
        ;;
      removeMXY)
        run_remove_mxy_module "${sample}"
        ;;
      *)
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          echo "[DRY-RUN] ${sample} -> ${RIBOSEMAP_BIN} ${mod} ${cfg}"
        else
          echo "[RUN] ${sample} -> ${mod}"
          "${RIBOSEMAP_BIN}" "${mod}" "${cfg}"
        fi
        ;;
    esac
  done

  echo "[DONE] ${sample}"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ribose-map-multi.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
TASKS_FILE="${TMP_DIR}/tasks.tsv"

awk -F '\t' '
  NR==1 {
    if ($1 != "sample" || $2 != "barcode" || $3 != "read1") {
      print "Header must start with: sample<TAB>barcode<TAB>read1" > "/dev/stderr"
      exit 2
    }
    next
  }
  NF==0 { next }
  /^#/ { next }
  {
    sample=$1
    barcode=$2
    read1=$3
    read2=(NF>=4 ? $4 : "")

    if (sample == "") {
      print "Invalid row (sample required): " $0 > "/dev/stderr"
      exit 3
    }

    print sample "\t" barcode "\t" read1 "\t" read2
  }
' "${SAMPLES_TSV}" > "${TASKS_FILE}"

if [[ ! -s "${TASKS_FILE}" ]]; then
  echo "No samples found in ${SAMPLES_TSV}" >&2
  exit 1
fi

export ROOT_DIR RIBOSEMAP_BIN REMOVE_MXY_BIN BASE_CONFIG GENERATED_DIR MODULES DRY_RUN repository fasta quality
export RUN_TRIMMING RUN_MISMATCH MISMATCH_REPO_ILLUMINA MISMATCH_REPO_AVITI MISMATCH_POLYN MISMATCH_NTAIL CLEANUP_MISMATCH_FASTQ
export -f sq reverse_complement_barcode trimmed_fastq_path resolve_analysis_fastq infer_platform_and_read prepare_trimmed_fastq
export -f generate_config materialize_mismatch_fastq run_mismatch_module run_remove_mxy_module run_one_sample

if [[ "${JOBS}" -eq 1 ]]; then
  while IFS=$'\t' read -r sample barcode read1 read2; do
    run_one_sample "${sample}" "${barcode}" "${read1}" "${read2}"
  done < "${TASKS_FILE}"
else
  xargs -a "${TASKS_FILE}" -d $'\n' -P "${JOBS}" -I '{}' bash -lc '
    IFS=$'\''\t'\'' read -r sample barcode read1 read2 <<< "{}"
    run_one_sample "$sample" "$barcode" "$read1" "$read2"
  '
fi

echo "All requested samples completed."
