#!/usr/bin/env bash
set -euo pipefail

#Author: Alli L. Gombolay
#Processes UMI and/or barcode if necessary, aligns reads to reference genome, and de-duplicates aligned reads

###################################################################################################################################################################

#Load config file
. "$1"

# Persistent outputs are intentionally limited to the final deduplicated BAM,
# its index, and the alignment log. Coordinate and all later modules consume
# the final BAM; they do not require the SAM or intermediate FASTQs.
output=$repository/results/$sample/alignment
rm -rf "$output"; mkdir -p "$output"

# Bowtie2 SAMs, UMI-extracted/demultiplexed FASTQs, and pre-dedup BAMs can be
# hundreds of GB for a single library. Keep those disposable files on the
# compute node's local temporary filesystem instead of project storage.
tmp_root="${TMPDIR:-/tmp}"
workdir=$(mktemp -d "${tmp_root}/ribose-map-alignment.${sample}.XXXXXX")
workdir_monitor_pid=""
workdir_monitor_seconds="${ALIGNMENT_TMP_MONITOR_SECONDS:-30}"
sort_threads="${SLURM_CPUS_PER_TASK:-${threads:-1}}"
# With 16 allocated CPUs this reserves approximately 32G for sort buffers,
# leaving headroom within the standard 48G Slurm task allocation.
sort_memory_per_thread="${SAMTOOLS_SORT_MEMORY_PER_THREAD:-2G}"

if ! [[ "${workdir_monitor_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ALIGNMENT_TMP_MONITOR_SECONDS must be a positive integer." >&2
  exit 1
fi
if ! [[ "${sort_threads}" =~ ^[1-9][0-9]*$ ]]; then
  echo "samtools sort thread count must be a positive integer." >&2
  exit 1
fi

log_tmp_diagnostics() {
  local event="$1"

  echo "========== ALIGNMENT TMP DIAGNOSTIC ==========" >&2
  echo "event: ${event}" >&2
  echo "time: $(date '+%F %T %Z')" >&2
  echo "host: $(hostname)" >&2
  echo "slurm_job_id: ${SLURM_JOB_ID:-unknown}" >&2
  echo "slurm_array_task_id: ${SLURM_ARRAY_TASK_ID:-unknown}" >&2
  echo "tmp_root: ${tmp_root}" >&2
  echo "workdir: ${workdir}" >&2
  echo "workdir_exists: $([[ -d "${workdir}" ]] && echo yes || echo no)" >&2
  ls -ld "${tmp_root}" "${workdir}" >&2 || true
  stat -c 'path=%n inode=%i mode=%A uid=%u gid=%g mtime=%y ctime=%z' "${tmp_root}" "${workdir}" >&2 || true
  echo "tmp_mount:" >&2
  findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS -T "${tmp_root}" >&2 || true
  echo "tmp_capacity:" >&2
  df -h "${tmp_root}" >&2 || true
  echo "tmp_inodes:" >&2
  df -i "${tmp_root}" >&2 || true
  echo "tmp_cleaner_processes:" >&2
  ps -ef | grep -E '[t]mpwatch|[t]mpreaper|[s]ystemd-tmpfiles|[c]leanup' >&2 || true
  echo "==============================================" >&2
}

monitor_workdir() {
  while sleep "${workdir_monitor_seconds}"; do
    if [[ -d "${workdir}" ]]; then
      echo "alignment_workdir_monitor: $(date '+%F %T %Z') exists=yes" >&2
    else
      log_tmp_diagnostics "workdir_missing_during_alignment"
      return 0
    fi
  done
}

stop_workdir_monitor() {
  if [[ -n "${workdir_monitor_pid}" ]]; then
    kill "${workdir_monitor_pid}" 2>/dev/null || true
    wait "${workdir_monitor_pid}" 2>/dev/null || true
    workdir_monitor_pid=""
  fi
}

sort_bam() {
  local temp_prefix="$1"
  local sorted_bam="$2"

  samtools sort \
    -@ "${sort_threads}" \
    -m "${sort_memory_per_thread}" \
    -T "${temp_prefix}" \
    -o "${sorted_bam}" \
    -
}

log_tmp_diagnostics "workdir_created"
monitor_workdir &
workdir_monitor_pid="$!"

# Remove local intermediates on normal completion and on failure. Exporting
# TMPDIR also directs umi_tools/pysam temporary sort files into this directory.
cleanup_workdir() {
  local rc="$?"

  stop_workdir_monitor

  if [[ "${rc}" -ne 0 ]]; then
    # A missing work directory is distinct from a full filesystem. Capture the
    # node-local state before cleanup so failed Slurm logs identify the cause.
    echo "Alignment failed; inspecting local work directory: ${workdir}" >&2
    if [[ -d "${workdir}" ]]; then
      log_tmp_diagnostics "alignment_failed_workdir_present"
    else
      log_tmp_diagnostics "alignment_failed_workdir_missing"
      # The multi-sample wrapper retries only this externally induced failure.
      # Other alignment errors remain immediate failures for diagnosis.
      : > "${output}/.retryable_tmp_workdir_missing"
    fi
  fi

  trap - EXIT
  rm -rf "${workdir}" || true
  exit "${rc}"
}
trap cleanup_workdir EXIT
export TMPDIR="$workdir"

echo "samtools_sort_threads: ${sort_threads}" >> "$output/alignment.log"
echo "samtools_sort_memory_per_thread: ${sort_memory_per_thread}" >> "$output/alignment.log"

###################################################################################################################################################################

if [[ ! $read2 ]]; then
	
	if [[ ! $pattern ]]; then
	
		bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -U $read1 -S $workdir/aligned.sam 2>> $output/alignment.log
		samtools view -bS $workdir/aligned.sam | sort_bam "$workdir/sort" "$output/$sample.bam"
		samtools index $output/$sample.bam
		
	elif [[ $pattern ]]; then
		
		umi_tools extract -v 0 -I $read1 -p $pattern -S $workdir/extracted1.fq
		
		if [[ ! $barcode ]]; then
		
			bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -U $workdir/extracted1.fq -S $workdir/aligned.sam 2>> $output/alignment.log
			samtools view -bS $workdir/aligned.sam | sort_bam "$workdir/sort" "$workdir/sorted.bam"
			samtools index $workdir/sorted.bam
	
			umi_tools dedup -v 0 -I $workdir/sorted.bam | sort_bam "$workdir/dedup-sort" "$output/$sample.bam"
			samtools index $output/$sample.bam
		
		elif [[ $barcode ]]; then
			
			grep -B 1 -A 2 ^$barcode $workdir/extracted1.fq | sed '/^--$/d' | seqtk trimfq -b ${#barcode} - > $workdir/demultiplexed1.fq
  
			bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -U $workdir/demultiplexed1.fq -S $workdir/aligned.sam 2>> $output/alignment.log
			samtools view -bS $workdir/aligned.sam | sort_bam "$workdir/sort" "$workdir/sorted.bam"
			samtools index $workdir/sorted.bam
	
			umi_tools dedup -v 0 -I $workdir/sorted.bam | sort_bam "$workdir/dedup-sort" "$output/$sample.bam"
			samtools index $output/$sample.bam
		fi
	fi

###################################################################################################################################################################

elif [[ $read2 ]]; then
	
	if [[ ! $pattern ]]; then

		bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -1 $read1 -2 $read2 -S $workdir/aligned.sam 2>> $output/alignment.log
		samtools view -bS $workdir/aligned.sam | sort_bam "$workdir/sort" "$output/$sample.bam"
		samtools index $output/$sample.bam
		
	elif [[ $pattern ]]; then
		
		umi_tools extract -v 0 -I $read1 -p $pattern -S $workdir/extracted1.fq --read2-in=$read2 --read2-out=$workdir/extracted2.fq
  
		if [[ ! $barcode ]]; then
		
			bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -1 $workdir/extracted1.fq -2 $workdir/extracted2.fq -S $workdir/aligned.sam 2>> $output/alignment.log
			samtools view -bS $workdir/aligned.sam | sort_bam "$workdir/sort" "$workdir/sorted.bam"
			samtools index $workdir/sorted.bam
	
			umi_tools dedup -v 0 --paired -I $workdir/sorted.bam | sort_bam "$workdir/dedup-sort" "$output/$sample.bam"
			samtools index $output/$sample.bam
		
		elif [[ $barcode ]]; then
		
			grep -B 1 -A 2 ^$barcode $workdir/extracted1.fq | sed '/^--$/d' | seqtk trimfq -b ${#barcode} - > $workdir/demultiplexed1.fq
			
			bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -1 $workdir/demultiplexed1.fq -2 $workdir/extracted2.fq -S $workdir/aligned.sam 2>> $output/alignment.log
			samtools view -bS $workdir/aligned.sam | sort_bam "$workdir/sort" "$workdir/sorted.bam"
			samtools index $workdir/sorted.bam
	
			umi_tools dedup -v 0 --paired -I $workdir/sorted.bam | sort_bam "$workdir/dedup-sort" "$output/$sample.bam"
			samtools index $output/$sample.bam
		fi
	fi
fi

###################################################################################################################################################################

if [[ $pattern ]]; then

	if [[ ! $barcode ]]; then
	
		#Reads after de-duplication (%)
		duplication_statistics=$( bc -l <<< $(samtools view -c -F 4 $output/$sample.bam)/$(samtools view -c -F 4 $workdir/sorted.bam)*100 | xargs printf "%.*f\n" 2)
		echo "Reads after de-duplication (%)": $duplication_statistics >> $output/alignment.log
	
	elif [[ $barcode ]]; then
	
		#Reads after de-duplication (%)
		duplication_statistics=$( bc -l <<< $(samtools view -c -F 4 $output/$sample.bam)/$(samtools view -c -F 4 $workdir/sorted.bam)*100 | xargs printf "%.*f\n" 2)
		echo "Reads after de-duplication (%)": $duplication_statistics >> $output/alignment.log
		
		#Reads containing barcode (%)
		barcode_statistics=$( bc -l <<< $(wc -l $workdir/demultiplexed1.fq | awk '{print $1 / 4}')/$(wc -l $read1 | awk '{print $1 / 4}')*100 | xargs printf "%.*f\n" 2 )
		echo "Reads containing barcode (%)": $barcode_statistics >> $output/alignment.log
	fi
fi

###################################################################################################################################################################

#Print status
echo "Status: Alignment Module for $sample is complete"
