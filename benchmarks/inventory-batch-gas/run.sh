#!/usr/bin/env bash
# Batch vs shared-PTB gas bench.
#
# Usage: ./run.sh [all|unit|localnet]     (default: all)
#   unit      Move unit tests: computation units, unbucketed.
#   localnet  Real transactions on a throwaway localnet: computation, storage
#             cost, storage rebate and non-refundable storage fee, in MIST.
#
# Env: SUI (default ~/.local/bin/sui), NS (default 1,2,3,4,5,7,10,100),
#      RPC_PORT (default 9500), FAUCET_PORT (default 9523).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
REPO="$(cd ../.. && pwd)"
SUI="${SUI:-$HOME/.local/bin/sui}"
NS="${NS:-1,2,3,4,5,7,10,100}"
RPC_PORT="${RPC_PORT:-9500}"
FAUCET_PORT="${FAUCET_PORT:-9523}"
MODE="${1:-all}"

run_unit() {
  # The reported gas includes an offset tied to the limit; deltas against the
  # baseline tests cancel it.
  local limit=1000000000000 raw
  raw="$("$SUI" move test --build-env test bench_ --statistics -i "$limit" 2>&1)" || {
    echo "$raw" | grep -v "^INCLUDING\|^BUILDING\|^UPDATING\|^FETCHING" >&2
    exit 1
  }
  echo "## Unit tests (computation units)"
  echo
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
}

run_localnet() {
  local tmp node_pid cfg client rpc="http://127.0.0.1:$RPC_PORT" addr
  tmp="$(mktemp -d)"
  "$SUI" start --force-regenesis --with-faucet="$FAUCET_PORT" --fullnode-rpc-port "$RPC_PORT" \
    >"$tmp/node.log" 2>&1 &
  node_pid=$!
  trap "kill $node_pid 2>/dev/null; wait $node_pid 2>/dev/null; rm -rf '$tmp'" EXIT

  echo "Starting localnet (rpc :$RPC_PORT, faucet :$FAUCET_PORT) ..." >&2
  for _ in $(seq 1 120); do
    curl -sf -o /dev/null "http://127.0.0.1:$FAUCET_PORT/" && break
    kill -0 "$node_pid" 2>/dev/null || { tail -20 "$tmp/node.log" >&2; exit 1; }
    sleep 1
  done

  # Isolated client config and key; the user's ~/.sui is untouched.
  cfg="$tmp/client.yaml"
  client() { "$SUI" client --client.config "$cfg" "$@"; }
  client --yes envs >/dev/null 2>&1
  client new-env --alias bench --rpc "$rpc" >/dev/null
  client switch --env bench >/dev/null
  addr="$(client active-address)"
  curl -sf -o /dev/null -H 'content-type: application/json' \
    -d "{\"FixedAmountRequest\":{\"recipient\":\"$addr\"}}" "http://127.0.0.1:$FAUCET_PORT/v2/gas"
  until client gas --json 2>/dev/null | grep -q gasCoinId; do sleep 1; done

  # Publish from a copy so builds don't touch the repo's Move.lock files.
  echo "Publishing core, power, inventory ..." >&2
  mkdir -p "$tmp/contracts"
  for pkg in core power inventory; do
    rsync -a --exclude build --exclude Move.lock "$REPO/contracts/$pkg" "$tmp/contracts/"
  done
  for pkg in core power inventory; do
    (cd "$tmp/contracts/$pkg" &&
      client test-publish --build-env testnet --pubfile-path "$tmp/Pub.toml" --json \
        >"$tmp/$pkg.json" 2>"$tmp/$pkg.err") || { cat "$tmp/$pkg.err" >&2; exit 1; }
  done

  echo "Measuring N=$NS ..." >&2
  echo "## Localnet"
  echo
  "$REPO/node_modules/.bin/tsx" "$HERE/localnet.ts" "$rpc" "$tmp/sui.keystore" "$tmp" "$NS"
}

case "$MODE" in
  all) run_unit; echo; run_localnet ;;
  unit) run_unit ;;
  localnet) run_localnet ;;
  *) echo "Usage: $0 [all|unit|localnet]" >&2; exit 1 ;;
esac
