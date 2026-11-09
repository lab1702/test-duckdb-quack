# TPC-H on a DuckDB quack server

Scripts to measure how a DuckDB `-serve` (quack) server handles concurrent
TPC-H queries. The sweep runs all 22 TPC-H queries with N queries in flight at
once against a server set to THREADS worker threads, over every combination
that fits the machine's CPU budget, repeats each one, checks that every run
returned the same rows, and plots the results.

| Script | Purpose |
| --- | --- |
| `start_server.sh` | Starts a read-only quack server on a TPC-H database file. |
| `run_tpch.sh` | Runs the sweep and writes timings and a result check as CSV. |
| `summarize_tpch.R` | Prints summary tables and writes `summary.png` / `summary.pdf`. |
| `run_mixed.sh` | Admission-control test: light queries arriving into a heavy load, with a gate capping how many queries execute at once. |
| `summarize_mixed.R` | Summary tables and `summary.png` / `summary.pdf` for a `run_mixed.sh` run. |
| `social_card.R` | Renders `social_card.png`, a 1200 x 1200 summary card of the findings in `RESULTS.md` (numbers typed in, not read from a sweep). |

## Requirements

- DuckDB CLI 2.0 or newer with the `tpch` extension (loaded on demand), and a
  TPC-H database file. Both the server and the clients connect through the
  default quack secret stored in the user's DuckDB home, so run everything on
  the same machine as the same user.
- bash 5.1 or newer, plus `setsid`, `pgrep`, `timeout`, `lscpu`, `md5sum`,
  `awk` and `sed -i` (Linux; util-linux, procps and coreutils or uutils).
- For the plots: R 4.1 or newer with the `dplyr`, `tidyr`, `ggplot2` and
  `patchwork` packages. `social_card.R` also needs `ragg` and `systemfonts`,
  and uses the Inter font when it is installed.

## Usage

1. Start the server in a terminal of its own and leave it running:

   ```bash
   ./start_server.sh tpch-sf100.duckdb
   ```

   It stops when its stdin ends (Ctrl-D or `.quit` at the prompt) or when it is
   killed. To run it in the background, redirect stdin and keep the token that
   it prints on its first line out of any log:

   ```bash
   nohup ./start_server.sh tpch-sf100.duckdb < /dev/null > /dev/null 2> server.log &
   ```

2. Run the sweep from another terminal:

   ```bash
   ./run_tpch.sh
   ```

   With the defaults, N = 1..min(22, CPUs) and THREADS = 1..CPUs are swept over
   every pair where N + THREADS - 1 equals the CPU count (roughly the threads a
   run uses, since `SET threads` starts THREADS - 1 shared workers and each
   query's own thread works too), three repeats each, after one unrecorded
   warm-up pass.

   To vary one factor while holding the other fixed, list the exact N x THREADS
   pairs in `COMBOS` instead, each to its own output folder:

   ```bash
   COMBOS="1x24 2x24 4x24 8x24 16x24 22x24" OUT_DIR=out_threads24 ./run_tpch.sh
   ```

   ```bash
   COMBOS="4x1 4x2 4x3 4x4 4x6 4x8 4x12 4x16 4x20 4x24" OUT_DIR=out_jobs4 ./run_tpch.sh
   ```

3. Summarise (the argument is the output folder; default `out`):

   ```bash
   Rscript summarize_tpch.R
   ```

4. To test admission control, run the mixed workload (see
   [Admission control](#admission-control)) and summarise it:

   ```bash
   ./run_mixed.sh
   Rscript summarize_mixed.R
   ```

## Settings

`run_tpch.sh` takes no arguments; everything comes from the environment.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CPUS` | `nproc` | CPU budget the combinations are chosen for. |
| `MARGIN` | `0` | Accept N + THREADS - 1 within this many of `CPUS`. |
| `MAX_JOBS` | min(22, CPUs) | Largest N. |
| `MAX_THREADS` | `CPUS` | Largest THREADS. |
| `COMBOS` | unset | Exact `NxT` pairs to run (space-separated, N at most 22), in the order given. Replaces the four settings above, which are then ignored, and does not keep the CPU budget. |
| `REPEATS` | `3` | Passes over all combinations (even passes run in reverse order). |
| `OUT_DIR` | `out` | Output folder; should be a folder of its own. |
| `WARMUP` | `1` | `0` skips the warm-up pass. |
| `QUERY_ORDER` | longest first | Order the 22 queries are started in within a run. |
| `QUERY_TIMEOUT` | `0` (none) | Seconds after which a query is killed and counted as failed. |

Each of `CPUS`, `MAX_JOBS`, `MAX_THREADS`, `MARGIN` and `REPEATS` is capped at
9999. The headers of the scripts describe the behaviour in full.

## Admission control

`run_mixed.sh` answers a different question from the sweep: what a short
query's latency looks like when it arrives, unannounced, into a server that
is already busy, with and without a cap on how many queries may execute at
once. Several heavy clients (default 16) run the slowest TPC-H queries back
to back for the whole run, a light query (Q02, Q11 or Q06 in turn) arrives
every 0.5 s whether or not the previous one has finished, and every query
passes through a gate first:

| Setting | Meaning |
| --- | --- |
| `alone` | No heavy load; the light queries by themselves, as the reference. |
| `none` | No gate; everything runs at once. |
| `shared/CAP` | At most CAP queries execute at once, light or heavy. A light query waits for a slot like any other (one queue). |
| `bypass/CAP` | At most CAP heavy queries execute at once; light queries skip the gate and start immediately. |

The gate is a counting semaphore (CAP tokens in a pipe), so waiters are
admitted in roughly, not strictly, arrival order. Each query's queue wait and
execution time are recorded separately; the latency a user would see is their
sum. The default run covers `alone none shared/8 shared/4 shared/2 bypass/8
bypass/4 bypass/2`, 90 s each, three repeats, after a 20 s warm-up. The
server's threads setting is left as it is.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CONFIGS` | the eight settings above | Space-separated gate settings, in the order to run them. |
| `REPEATS` | `3` | Passes over `CONFIGS` (even passes run in reverse order). |
| `DURATION` | `90` | Seconds that light queries keep arriving. Heavy queries still running then are left to finish. |
| `LIGHT_INTERVAL` | `0.5` | Seconds between light arrivals (up to 3 decimals). |
| `LIGHT_QUERIES` | `2 11 6` | Light queries, used in turn. |
| `HEAVY_QUERIES` | `18 9 13 21 10 5 3 4` | Heavy queries; client w starts at the w-th and cycles. |
| `HEAVY_CLIENTS` | `16` | Heavy clients running back to back. |
| `OUT_DIR` | `out_mixed` | Output folder; should be a folder of its own. |
| `WARMUP` | `1` | `0` skips the unrecorded 20 s warm-up. |
| `QUERY_TIMEOUT` | `0` (none) | Seconds after which a query is killed and counted as failed. |

Output goes under `OUT_DIR`: `queries.csv` has one row per query with its
kind (light or heavy), arrival, admission, queue wait, client wall time and
`query_s`; `runs.csv` one row per setting and repeat; `system.csv` and
`check.csv` as for the sweep; and each query's result under
`SETTING/rN/`. `summarize_mixed.R` prints light-query latency (median, p90,
max, share over 0.5 s and 1 s) per setting and per light query, heavy
throughput and average queries in flight per setting, and writes
`summary.png` / `summary.pdf`.

## Output

Everything goes under `OUT_DIR` (ignored by git):

- `runs.csv`: one row per combination and repeat with the wall time for all 22
  queries and the number of failed queries.
- `queries.csv`: one row per query with its start offset, client wall time and
  the client's `.timer` time (`query_s`, which excludes client startup).
- `check.csv`: per query, whether every successful run returned the same rows
  (`same`, `reordered`, `misordered`, `single`, `differ` or `no_results`).
- `system.csv`: CPU, memory, DuckDB version and the sweep's settings.
- `jNN_tNN/rN/qNN.csv`: each query's result, with `qNN.err` next to it when
  the client wrote to stderr.
- `summary.png` and `summary.pdf` from `summarize_tpch.R`: total time per
  combination (ranked on the run replayed with `query_s`, so client startup
  doesn't penalise low concurrency), average queries in flight, per-query
  latency distributions and a latency heat map.

`run_tpch.sh` exits 1 if any query failed, any query's results differed or
were misordered between runs, or the server's original `threads` setting could
not be restored. Ctrl-C, TERM or HUP stops the sweep cleanly: the running
clients are killed and `threads` is restored.

## Caveats

- `-readonly` protects the database file only. Any local client that can reach
  the server can still read and write files as the server's user, load
  extensions and change its settings (the sweep relies on `SET threads`).
- Q11's threshold fraction is scaled to the database's scale factor, as the
  TPC-H specification requires; DuckDB's built-in Q11 is only right at SF1.
- Q11 orders by a value that can tie at SF100, so its rows may legitimately
  come back in different orders between runs (`reordered` in `check.csv`).

## License

MIT, see [LICENSE](LICENSE).
