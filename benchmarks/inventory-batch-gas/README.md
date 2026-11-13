# inventory batch gas bench

Compares `inventory::withdraw_batch` / `deposit_batch` against the same number
of single `withdraw` / `deposit` calls sharing one request in a PTB.

```sh
./run.sh            # both tables (~3 min)
./run.sh unit       # unit-test computation only (~5 s)
./run.sh localnet   # full gas summary only
```

Env overrides: `SUI` (default `~/.local/bin/sui`, 1.81), `NS` (default
`1,2,3,4,5,7,10,100`), `RPC_PORT` / `FAUCET_PORT` (default 9500 / 9523).

## Unit tests

`tests/batch_gas.move`. Each `bench_<N>_<mode>` test bridges in N item types,
then in one transaction withdraws one unit of each and deposits it back. The
table subtracts a baseline with identical setup and no moves:

- **Shared PTB**: `shared` − `baseline_shared` (N single calls per request, each
  followed by `grid_load::assert_online`)
- **Batch**: `batch` − `baseline`

Figures are test-runner computation units, unbucketed and without storage. Only
the deltas mean anything; the raw figures carry an offset tied to the gas limit.

## Localnet

`localnet.ts`, driven by `run.sh`. It starts a throwaway `sui start
--force-regenesis` network with its own client config, then publishes
core/power/inventory from a temp copy, so the repo and `~/.sui` aren't touched.
It then sets up two entities that each hold 5 of every type.

The measured transaction moves one unit of each of N types from A to B. A
second, unmeasured transaction moves them back so each mode starts from the
same state. Docking is attested by the admin sender.

The table reports each transaction's `gasUsed` in MIST: computation, storage
cost, storage rebate, and the non-refundable storage fee.

A round trip within one entity would show no inventory storage at all. The
balances end with the same bytes, so Sui doesn't write them. That's why this
version moves the items between two entities.
