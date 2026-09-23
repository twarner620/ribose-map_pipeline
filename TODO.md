# TODO

## Make UMI deduplication reproducible

### Problem

Ribose-seq libraries use `umi_tools dedup` after the first coordinate sort in
`modules/alignment.sh`. UMI-tools retains one representative read per duplicate
group. When reads tie on multimapping status and MAPQ, the representative is
otherwise selected randomly.

The existing `ribose-map` environment contains UMI-tools 1.0.0. Although that
version accepts `--random-seed`, deterministic seeded output is only guaranteed
by UMI-tools 1.1.6 and later. Older versions can still depend on Python hash
ordering.

This matters because the newer Yeast T/NT alignment run changed the first
`samtools sort` from the prior implicit single-threaded/default-memory behavior
to parallel sorting. Comparing the old and newer coordinate30 outputs found
small differences among ribose-seq samples, while non-ribose-seq outputs and
per-reference alignment totals were unchanged. Changing sort threads or
per-thread memory changes the ordering of records tied on coordinate; it does
not change the underlying reads.

Temporary-file spilling is not inherently a reproducibility failure. The risk
is the unspecified order of tied records combined with random UMI-dedup
representative selection.

### Intended behavior

Production runs should have reproducible results for identical inputs,
reference files, tool versions, and configuration. A fixed seed does not make
an arbitrary tie biologically meaningful; it makes the unavoidable choice
traceable and repeatable.

### Proposed work

1. Upgrade the `ribose-map` Conda environment to UMI-tools >=1.1.6.
2. Add a separate base-config parameter such as `umi_dedup_seed='123456789'`.
   Do not reuse the Bowtie2 `seed` parameter: Bowtie2 and UMI-tools control
   different tie-breaking stages.
3. Pass `--random-seed "${umi_dedup_seed}"` to every `umi_tools dedup` call in
   `modules/alignment.sh`.
4. Record the UMI-tools version and dedup seed in each sample's alignment log.
5. Keep the current parallel `samtools sort` resources unless validation shows
   a separate performance or correctness problem. A fixed sort-memory setting
   alone is not a durable reproducibility strategy.

### Required validation

1. Select one large enzyme-fragmented ribose-seq library and one `dsF` library.
2. Run each with two intentionally different pre-dedup sort configurations
   (for example, 1 vs 16 threads and 1G vs 2G per sort thread), keeping all
   other inputs fixed.
3. With the same UMI-dedup seed, compare final BAMs and coordinate BEDs.
4. Repeat one configuration with a different UMI-dedup seed to quantify the
   inherent tied-read sensitivity.
5. If coordinate-level results still differ with UMI-tools >=1.1.6 and a fixed
   seed, investigate a canonical secondary sort key before deduplication rather
   than relying on RAM limits.

### References

- [UMI-tools dedup representative-read selection](https://github.com/CGATOxford/UMI-tools/blob/master/umi_tools/dedup.py)
- [UMI-tools 1.1.6 deterministic `--random-seed` release note](https://github.com/CGATOxford/UMI-tools/releases)
