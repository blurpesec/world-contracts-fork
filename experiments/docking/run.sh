#!/usr/bin/env bash
# Localnet harness for ADR-0004 interaction proofs vs a docked session.
#
# Needs a running localnet (`sui start --with-faucet --force-regenesis`) with the
# active sui client env pointed at it and a funded active address (the deployer,
# which becomes the AdminACL admin).
#
#   ./experiments/docking/run.sh                      # publish adr_core + adr_inventory, bench
#   SKIP_DEPLOY=1 ./experiments/docking/run.sh
#   SKIP_DEPLOY=1 ONLY=session SESSION_SIZES=5 ./experiments/docking/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

DEPLOY_DIR=deployments/localnet-adr
if [[ -z "${SKIP_DEPLOY:-}" ]]; then
    mkdir -p "$DEPLOY_DIR"
    rm -f "$DEPLOY_DIR/Pub.localnet.toml"
    for pkg in core inventory; do
        (cd "experiments/docking/adr/$pkg" && sui client test-publish --build-env testnet \
            --pubfile-path "../../../../$DEPLOY_DIR/Pub.localnet.toml" --json) \
            > "$DEPLOY_DIR/adr_$pkg.publish.json"
        echo "published adr_$pkg"
    done
    pnpm exec tsx ts-scripts/build-manifest.ts "$DEPLOY_DIR" localnet \
        "$(sui client chain-identifier)" adr_core adr_inventory
fi

SUI_PRIVATE_KEY=$(sui keytool export --key-identity "$(sui client active-address)" --json \
    | jq -r .exportedPrivateKey) \
    pnpm exec tsx experiments/docking/harness/bench.ts
