#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <input> <output>" >&2
  exit 1
fi

in_file="$1"
out_file="$2"

if [[ ! -f "$in_file" ]]; then
  echo "Input file not found: $in_file" >&2
  exit 1
fi

# Keep only canonical autosomes chr1-chr22.
canonical_re='^chr([1-9]|1[0-9]|2[0-2])$'

# If FASTA (header starts with '>'), keep only chr1-chr22 sequence blocks.
if head -n 1 "$in_file" | grep -q '^>'; then
  awk -v re="$canonical_re" '
  /^>/ {
    split(substr($0, 2), f, /[ \t]/)
    chrom = f[1]
    keep = (chrom ~ re)
  }
  keep { print }
  ' "$in_file" > "$out_file"
else
  # For tabular files, keep rows containing canonical chr1-chr22 in any field.
  # Preserve the first row if it looks like a header.
  first_line="$(head -n 1 "$in_file" || true)"
  has_header=0
  if [[ "$first_line" =~ [A-Za-z] ]] && [[ ! "$first_line" =~ ^chr[^[:space:]]*([[:space:]]|$) ]]; then
    has_header=1
  fi

  if [[ $has_header -eq 1 ]]; then
    {
      head -n 1 "$in_file"
      tail -n +2 "$in_file" | awk -F'[[:space:],;|]+' -v re="$canonical_re" '
      {
        keep = 0
        for (i = 1; i <= NF; i++) {
          if ($i ~ re) {
            keep = 1
            break
          }
        }
        if (keep) {
          print
        }
      }'
    } > "$out_file"
  else
    awk -F'[[:space:],;|]+' -v re="$canonical_re" '
    {
      keep = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ re) {
          keep = 1
          break
        }
      }
      if (keep) {
        print
      }
    }' "$in_file" > "$out_file"
  fi
fi
