# Docking harness (experiment)

Measures ship ↔ storage unit item transfers against a prototype of
[ADR-0004](../../docs/adr/0004-interaction-proofs.md), and compares the ADR's
per-transfer proofs with alternatives, including a docked session. This is not
production code, and it is outside the `contracts/*` build and test globs.

## The ADR prototype (`adr/`)

`adr/core` and `adr/inventory` are copies of `contracts/core` and
`contracts/inventory`, renamed to the packages `adr_core` and `adr_inventory`,
with the ADR applied. The repo's contracts are unchanged. To see exactly what
differs:

```bash
diff -r contracts/core/sources experiments/docking/adr/core/sources
diff -r contracts/inventory/sources experiments/docking/adr/inventory/sources
```

| ADR point | Where |
| --- | --- |
| Proofs replace `interact`'s location-hash Proximity (`location_service` removed) | `adr/core/sources/entity.move` |
| One proof per relationship; `DockingProof` payload; `Proof<K>`; `verify_docking`, `verify_interaction` | `adr/core/sources/services/interaction_service.move` |
| Handlers push `Interaction<Docked>`: `withdraw`/`deposit` add it through their `Frame` | `adr/inventory/sources/inventory.move` |
| One `Proof` shared by the requests on both entities | harness `transferTx` |
| Per-kind `ProofConfig<K>` with mode, key and nonces; Attested (`verify_interaction_attested`: admin sender or allowlisted sponsor) and Signed modes; admin `set_mode` | `interaction_service.move` |

Experiment additions, not in the ADR:

- `verify_docking_reusable`: a Signed proof without a nonce.
- `prune_nonces`: nonces are stored with their deadline, and expired ones can be deleted.
- `dock_session`: a shared `DockSession`.

## Variants

Every variant satisfies the same `Interaction<Docked>` requirement that the
handlers push. Every player transaction is sponsored (the player sends, a
sponsor on the `AdminACL` pays gas).

| Variant | How each transfer PTB is docked | Server signatures |
| --- | --- | --- |
| **T** Attested | `verify_interaction_attested`; the sponsor backend checks docking off-chain | 0 |
| **A** Signed, ADR | a new proof per PTB; the nonce is kept forever | 1 per PTB |
| **A+prune** | as A, plus one transaction that deletes the expired nonces | 1 per PTB |
| **A′** Signed, reused | one proof, sender- and deadline-bound, no nonce | 1 per session |
| **B2** session | `dock` + transfers reading a shared `DockSession` + `undock` | 1 per session |

In an earlier round, an *owned* `DockSession` was dropped. Sui rewrites every
owned input on each use, so it paid more non-refundable storage per transfer
than even A.

## Run

```bash
# separate terminal; long epochs avoid transactions being dropped at reconfiguration
sui start --with-faucet --force-regenesis --epoch-duration-ms 3600000

./experiments/docking/run.sh                                        # publish + all phases
SKIP_DEPLOY=1 ONLY=session SESSION_SIZES=5 ./experiments/docking/run.sh
sui move test --build-env testnet --path experiments/docking/adr/core
sui move test --build-env testnet --path experiments/docking/adr/inventory
```

Results are written to `deployments/localnet-adr/docking-bench.json`.

Phases:

1. **Sessions.** N items (`SESSION_SIZES`) are moved ship → storage unit per
   scenario, each on a fresh pair. The totals are measured, overhead included.
2. **Sequential.** Per-transfer means, and the break-even for B2.
3. **Microbenchmark.** K signature verifies in one PTB.
4. **Correctness checks**, all expected to be rejected.
5. **Concurrent.** All pairs at once (single-validator localnet, so indicative only).

## Reading the results

- **Compute:** each transaction pays at least 1000 gas units × the reference
  gas price (localnet/testnet 1000 MIST, so 1,000,000; mainnet 100 MIST, so
  100,000). One ed25519 verify is about 2 units, well under that floor.
- **Storage:** priced separately (76 per unit, 99% rebate) and independent of
  the gas price, so it dominates more on mainnet.
- **"C+NR"** = compute + non-refundable storage fee. **"C+net"** also counts
  storage never rebated, such as unpruned nonces.
- **Not modeled:**
  - Server round-trip latency. Under A, each transfer needs a server call before
    the player can sign.
  - Session staleness after an in-game undock.
  - Ship caps parked on a Character.
  - Mainnet congestion on the single `ProofConfig` that every A transfer writes.
