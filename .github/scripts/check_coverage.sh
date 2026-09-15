#!/usr/bin/env bash
set -euo pipefail

input_dir=${1:?coverage artifact directory required}
output_file=${2:?merged lcov output required}
mkdir -p "$(dirname "$output_file")"

awk '
  /^SF:/ { file = substr($0, 4); files[file] = 1; next }
  /^DA:/ { split(substr($0, 4), fields, ","); key = file SUBSEP fields[1]; hits[key] += fields[2]; lines[key] = fields[1]; next }
  END {
    for (key in hits) {
      split(key, parts, SUBSEP)
      print "SF:" parts[1]
      print "DA:" lines[key] "," hits[key]
      print "end_of_record"
    }
  }
' "$input_dir"/*.lcov > "$output_file"

read -r overall_hit overall_total core_hit core_total < <(
  awk '
    /^SF:/ { file = substr($0, 4); next }
    /^DA:/ {
      split(substr($0, 4), fields, ",")
      total++
      if (fields[2] > 0) hit++
      if (file ~ /(^|[\\/])core[\\/]lib[\\/]/) {
        core_total++
        if (fields[2] > 0) core_hit++
      }
    }
    END { print hit, total, core_hit, core_total }
  ' "$output_file"
)

overall_percent=$(( overall_hit * 100 / overall_total ))
core_percent=100
if (( core_total > 0 )); then
  core_percent=$(( core_hit * 100 / core_total ))
fi

echo "Overall line coverage: ${overall_percent}% (${overall_hit}/${overall_total})"
echo "core/lib line coverage: ${core_percent}% (${core_hit}/${core_total})"

if (( overall_percent < 90 )); then
  echo "Overall coverage is below 90%." >&2
  exit 1
fi
if (( core_percent < 100 )); then
  echo "core/lib coverage is below 100%." >&2
  exit 1
fi