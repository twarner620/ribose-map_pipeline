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
workdir=$(mktemp -d "${TMPDIR:-/tmp}/ribose-map-alignment.${sample}.XXXXXX")

# Remove local intermediates on normal completion and on failure. Exporting
# TMPDIR also directs umi_tools/pysam temporary sort files into this directory.
trap 'rm -rf "$workdir"' EXIT
export TMPDIR="$workdir"

###################################################################################################################################################################

if [[ ! $read2 ]]; then
	
	if [[ ! $pattern ]]; then
	
		bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -U $read1 -S $workdir/aligned.sam 2> $output/alignment.log
		samtools view -bS $workdir/aligned.sam | samtools sort -T $workdir/sort - -o $output/$sample.bam
		samtools index $output/$sample.bam
		
	elif [[ $pattern ]]; then
		
		umi_tools extract -v 0 -I $read1 -p $pattern -S $workdir/extracted1.fq
		
		if [[ ! $barcode ]]; then
		
			bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -U $workdir/extracted1.fq -S $workdir/aligned.sam 2> $output/alignment.log
			samtools view -bS $workdir/aligned.sam | samtools sort -T $workdir/sort - -o $workdir/sorted.bam
			samtools index $workdir/sorted.bam
	
			umi_tools dedup -v 0 -I $workdir/sorted.bam | samtools sort -T $workdir/dedup-sort - -o $output/$sample.bam
			samtools index $output/$sample.bam
		
		elif [[ $barcode ]]; then
			
			grep -B 1 -A 2 ^$barcode $workdir/extracted1.fq | sed '/^--$/d' | seqtk trimfq -b ${#barcode} - > $workdir/demultiplexed1.fq
  
			bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -U $workdir/demultiplexed1.fq -S $workdir/aligned.sam 2> $output/alignment.log
			samtools view -bS $workdir/aligned.sam | samtools sort -T $workdir/sort - -o $workdir/sorted.bam
			samtools index $workdir/sorted.bam
	
			umi_tools dedup -v 0 -I $workdir/sorted.bam | samtools sort -T $workdir/dedup-sort - -o $output/$sample.bam
			samtools index $output/$sample.bam
		fi
	fi

###################################################################################################################################################################

elif [[ $read2 ]]; then
	
	if [[ ! $pattern ]]; then

		bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -1 $read1 -2 $read2 -S $workdir/aligned.sam 2> $output/alignment.log
		samtools view -bS $workdir/aligned.sam | samtools sort -T $workdir/sort - -o $output/$sample.bam
		samtools index $output/$sample.bam
		
	elif [[ $pattern ]]; then
		
		umi_tools extract -v 0 -I $read1 -p $pattern -S $workdir/extracted1.fq --read2-in=$read2 --read2-out=$workdir/extracted2.fq
  
		if [[ ! $barcode ]]; then
		
			bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -1 $workdir/extracted1.fq -2 $workdir/extracted2.fq -S $workdir/aligned.sam 2> $output/alignment.log
			samtools view -bS $workdir/aligned.sam | samtools sort -T $workdir/sort - -o $workdir/sorted.bam
			samtools index $workdir/sorted.bam
	
			umi_tools dedup -v 0 --paired -I $workdir/sorted.bam | samtools sort -T $workdir/dedup-sort - -o $output/$sample.bam
			samtools index $output/$sample.bam
		
		elif [[ $barcode ]]; then
		
			grep -B 1 -A 2 ^$barcode $workdir/extracted1.fq | sed '/^--$/d' | seqtk trimfq -b ${#barcode} - > $workdir/demultiplexed1.fq
			
			bowtie2 --threads $threads --seed $seed -N $mismatches -x $basename -1 $workdir/demultiplexed1.fq -2 $workdir/extracted2.fq -S $workdir/aligned.sam 2> $output/alignment.log
			samtools view -bS $workdir/aligned.sam | samtools sort -T $workdir/sort - -o $workdir/sorted.bam
			samtools index $workdir/sorted.bam
	
			umi_tools dedup -v 0 --paired -I $workdir/sorted.bam | samtools sort -T $workdir/dedup-sort - -o $output/$sample.bam
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
