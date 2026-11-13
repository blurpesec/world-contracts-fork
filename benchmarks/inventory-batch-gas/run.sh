#!/usr/bin/env bash
# Run the batch-vs-PTB gas bench and print the comparison table.
# Usage: ./run.sh            (SUI=/path/to/sui to override the binary)
set -euo pipefail
cd "$(dirname "$0")"
SUI="${SUI:-$HOME/.local/bin/sui}"
# The reported gas includes an offset tied to the limit; deltas against the
# baseline tests cancel it.
LIMIT=1000000000000

raw="$("$SUI" move test --build-env test bench_ --statistics -i "$LIMIT" 2>&1)" || {
  echo "$raw" | grep -v "^INCLUDING\|^BUILDING\|^UPDATING\|^FETCHING" >&2
  exit 1
}

echo "$raw" | awk -F'│' '/^│.*batch_gas::bench_/ {
  name = $2; gas = $4
  gsub(/ /, "", name); gsub(/ /, "", gas)
  sub(/.*bench_/, "", name)
  print name, gas
}' | python3 -c '
import sys
d = {}
for line in sys.stdin:
    name, gas = line.split()
    n, mode = name.split("_", 1)
    d.setdefault(int(n), {})[mode] = int(gas)
print("| N | Shared PTB | Batch | Ratio |")
print("|---|---|---|---|")
for n in sorted(d):
    r = d[n]
    shared = r["shared"] - r["baseline_shared"]
    batch = r["batch"] - r["baseline"]
    print(f"| {n} | {shared:,} | {batch:,} | {shared / batch:.1f}x |")
'
