# inventory batch gas bench

Compares `inventory::withdraw_batch` / `deposit_batch` against the same number
of single `withdraw` / `deposit` calls sharing one request in a PTB.

```sh
./run.sh                       # uses ~/.local/bin/sui (1.81); SUI=... to override
```

Each `bench_<N>_<mode>` test bridges in N item types, then in one transaction
withdraws one unit of each and deposits it back. The table subtracts a baseline
with identical setup and no moves:

- **Shared PTB**: `shared` − `baseline_shared` (N single calls per request, each
  followed by `grid_load::assert_online`)
- **Batch**: `batch` − `baseline`

Numbers are test-runner computation units: no storage cost, no per-command PTB
overhead, no gas bucketing. Only the deltas are meaningful; the raw figures
carry an offset tied to the gas limit.
