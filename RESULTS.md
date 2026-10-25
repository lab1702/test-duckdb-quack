# Results: TPC-H concurrency sweep on a DuckDB quack server

Sweep run on 2026-10-24 with `run_tpch.sh` at its defaults, summarised with
`summarize_tpch.R`. The figure the script produced is `out/summary.png`
(`out/` is not committed).

## Setup

| | |
| --- | --- |
| Machine | AMD Ryzen AI 9 HX 370, 12 cores / 24 logical CPUs, 83.8 GiB RAM |
| DuckDB | v2.0.0, `-serve` (quack) server, `-readonly` |
| Database | TPC-H scale factor 100 |
| Workload | all 22 TPC-H queries per run, started longest first, N in flight at once |
| Configurations | 24, every N x THREADS pair with N + THREADS - 1 = 24 (N = 1..22; plus 22 x 1 and 22 x 2) |
| Repeats | 3 recorded passes after one warm-up pass; 72 runs, 1,584 query executions |
| Timing | per-query latency is the client's `.timer` time (`query_s`), which excludes client startup; run totals are the recorded schedule replayed with `query_s`, median of 3 repeats |

"N x T" below means N concurrent queries against a server with
`SET threads = T`.

## Correctness

Every one of the 1,584 query executions succeeded (exit 0, nothing on
stderr). The result check found that all 22 queries returned identical rows
across every run. The only exception is Q11, where the same rows came back in
different orders because its `ORDER BY` value ties at SF100; this is expected
and documented in the README.

## Throughput: total time for all 22 queries

Fastest to slowest, median of 3 repeats. `time_s` excludes client startup;
`wall_s` is the measured wall time including it.

| Config (N x T) | time_s | min–max | vs best | wall_s | avg in flight |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2 x 23 | 13.65 | 13.58–13.66 | 1.00x | 15.71 | 2.0 |
| 3 x 22 | 14.12 | 14.05–14.29 | 1.03x | 15.81 | 3.0 |
| 4 x 21 | 14.41 | 14.33–15.12 | 1.06x | 15.64 | 4.0 |
| 5 x 20 | 14.78 | 14.60–15.11 | 1.08x | 15.63 | 4.9 |
| 6 x 19 | 15.04 | 14.74–15.28 | 1.10x | 15.80 | 5.9 |
| 7 x 18 | 15.14 | 15.05–15.81 | 1.11x | 15.89 | 6.9 |
| 8 x 17 | 15.62 | 15.34–15.81 | 1.14x | 16.07 | 7.8 |
| 1 x 24 | 15.68 | 15.68–15.81 | 1.15x | 17.64 | 1.0 |
| 10 x 15 | 16.00 | 15.98–16.80 | 1.17x | 16.35 | 9.6 |
| 9 x 16 | 16.39 | 15.95–23.03 | 1.20x | 16.70 | 8.7 |
| 15 x 10 | 16.70 | 16.63–17.94 | 1.22x | 17.04 | 12.5 |
| 14 x 11 | 17.01 | 16.89–24.91 | 1.25x | 17.45 | 11.8 |
| 13 x 12 | 17.09 | 16.49–24.86 | 1.25x | 17.44 | 11.1 |
| 16 x 9 | 17.58 | 17.32–17.82 | 1.29x | 17.99 | 12.1 |
| 12 x 13 | 17.59 | 16.86–18.44 | 1.29x | 17.89 | 11.0 |
| 17 x 8 | 17.86 | 17.38–18.27 | 1.31x | 18.27 | 12.7 |
| 18 x 7 | 17.91 | 17.13–18.16 | 1.31x | 18.32 | 13.1 |
| 20 x 5 | 18.24 | 18.00–18.43 | 1.34x | 18.77 | 13.1 |
| 19 x 6 | 18.25 | 17.67–18.47 | 1.34x | 18.58 | 14.3 |
| 11 x 14 | 18.79 | 16.93–60.83 | 1.38x | 19.11 | 10.0 |
| 21 x 4 | 20.21 | 19.65–20.43 | 1.48x | 20.71 | 11.5 |
| 22 x 3 | 21.30 | 20.51–21.38 | 1.56x | 21.67 | 12.1 |
| 22 x 1 | 26.96 | 26.14–27.00 | 1.98x | 27.30 | 10.3 |
| 22 x 2 | 28.07 | 26.24–28.72 | 2.06x | 28.63 | 9.2 |

Findings:

1. **Concurrency buys almost no throughput.** Running the queries one at a
   time with all 24 threads (1 x 24) takes 15.7 s. The best configuration,
   2 x 23, takes 13.7 s, a 13% gain. Everything from 2 to 8 concurrent
   queries lands within 15% of the best. DuckDB's intra-query parallelism
   already keeps the 24 logical CPUs busy on a single query, so there is
   little idle capacity for a second query to fill.
2. **Starving the server of threads is what hurts.** Once THREADS drops below
   about 8 (N above ~16), total time climbs steadily, and at 1 or 2 server
   threads the sweep takes twice as long. Having 22 clients in flight does not
   compensate for a server that can only run 1 or 2 pipeline threads.
3. **On wall time the plateau is even flatter.** Measured wall time, which
   includes the ~0.1 s per client to start and connect (more when the CPUs are contended), is 15.6–16.1 s for
   every configuration from 1 x 24 to 8 x 17. The replayed `time_s` ranking
   favours 2 x 23 mainly because client startup overlaps less at low
   concurrency (12% of client time at 2 x 23 versus 4% at 8 x 17).
4. **22 x 2 is no better than 22 x 1.** Giving the server a second thread did
   not help when 22 queries compete for it; both are ~27–28 s. Three repeats
   is too few to say whether 22 x 2 is genuinely slower.

## Latency

Median and slowest per-query latency within a run (median over repeats):

| Config (N x T) | median query (s) | slowest query (s) |
| --- | ---: | ---: |
| 1 x 24 | 0.45 | 2.4 (Q09) |
| 2 x 23 | 0.76 | 4.4 (Q09) |
| 4 x 21 | 1.73 | 7.2 (Q18) |
| 8 x 17 | 4.24 | 13.1 (Q21) |
| 12 x 13 | 8.25 | 17.1 (Q21) |
| 16 x 9 | 9.46 | 17.5 (Q21) |
| 22 x 3 | 11.59 | 20.5 (Q18) |
| 22 x 1 | 10.47 | 27.0 (Q18) |

Findings:

1. **Latency scales roughly with the number of queries in flight.** Because
   throughput is flat, each extra concurrent query mostly just shares the
   same CPU: the median query takes 0.45 s alone, 0.76 s with one neighbour,
   ~4 s with seven, and ~10 s with 12 or more.
2. **The heavy queries are the same everywhere.** Q09, Q18, Q21, Q13 and Q05
   are the slowest at every concurrency level (2.4 s, 2.2 s, 1.2 s, 1.8 s and
   0.8 s when run alone). Q02, Q06, Q11 and Q15 are the lightest (under 0.3 s
   alone).
3. **Light queries suffer most under load.** Q02 goes from 0.08 s alone to
   ~1 s at 16 or more in flight (12x); Q06 from 0.14 s to 3–4 s (25x). The
   heavy queries slow down ~8–10x. A single busy server does not prioritise
   short queries.

## Run-to-run variance

Most configurations repeated within a few percent (see the min–max column).
Four runs out of 72 were clear outliers, all at mid-range concurrency:

| Run | Total (s) | What happened |
| --- | ---: | --- |
| 11 x 14, repeat 1 | 61.1 | Q10 and Q09 each took 60 s (normally ~18 s); Q21, Q13, Q17, Q08 took 30–35 s |
| 14 x 11, repeat 2 | 25.3 | Q09 took 25 s (normally ~17 s) |
| 13 x 12, repeat 1 | 25.2 | Q09 took 25 s, Q13 22 s |
| 9 x 16, repeat 3 | 23.3 | Q09 took 23 s (normally ~12 s) |

The other two repeats of each of these configurations were normal, and no
query failed or wrote to stderr, so these look like transient stalls on the
machine (another process, memory pressure, or thermal/frequency behaviour on
a laptop-class CPU) rather than a property of the configuration. Q09, the
heaviest join, is in every outlier. The medians in the tables above are not
affected, but the 11 x 14 row in particular should not be read as a real
dip. Configurations with 1–8 or 19–22 in flight were stable across all three
repeats.

## Conclusions

- The server is correct under concurrency: no failures and identical results
  across 72 runs, with only Q11's documented tie-order difference.
- For this machine and workload, keep concurrency low (2–8 queries in flight)
  and leave the server with most of the CPUs (threads = 16–23). That region
  gives the best throughput and much lower per-query latency than high
  concurrency, for about the same wall time.
- Do not reduce server threads to make room for clients: the configurations
  with 1–4 server threads are 1.5–2x slower in total and have the worst tail
  latencies.
- A queue in front of the server (admission control at ~2–8 queries) would
  deliver the same throughput as unbounded concurrency with far better
  latency, especially for short queries.

## Caveats

- Three repeats per configuration; differences under ~5% between neighbouring
  configurations are within noise.
- The CPU has 12 physical cores and 24 SMT threads, so "24 threads" is 12
  cores' worth of execution units; results on a machine without SMT may
  differ.
- All clients ran on the same machine as the server, so client CPU use
  competed with the server's. The `client_pct` column in the R output
  quantifies client startup, which matters most at low concurrency.
- Only one scale factor and one query order (longest first) were tested.
