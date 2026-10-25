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

## Requirements

- DuckDB CLI 2.0 or newer with the `tpch` extension (loaded on demand), and a
  TPC-H database file. Both the server and the clients connect through the
  default quack secret stored in the user's DuckDB home, so run everything on
  the same machine as the same user.
- bash 5.1 or newer, plus `setsid`, `pgrep`, `timeout`, `lscpu`, `md5sum`,
  `awk` and `sed -i` (Linux; util-linux, procps and coreutils or uutils).
- For the plots: R 4.1 or newer with the `dplyr`, `tidyr`, `ggplot2` and
  `patchwork` packages.

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
