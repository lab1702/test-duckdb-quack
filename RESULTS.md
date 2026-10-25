# Results: TPC-H concurrency sweep on a DuckDB quack server

Sweep run on 2026-10-24 with `run_tpch.sh` at its defaults, summarised with
`summarize_tpch.R`. The figure the script produced is `out/summary.png`
(`out/` is not committed). Two follow-up sweeps the same evening, each varying
one factor with the other held fixed, are in
[Separating concurrency from server threads](#separating-concurrency-from-server-threads).

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
3. **On wall time the plateau is even flatter.** Measured wall time (`wall_s`)
   is the end-to-end figure: how long the 22 clients actually took, including
   the ~0.1 s per client to start and connect (more when the CPUs are
   contended). It is 15.6–16.1 s for every configuration from 2 x 23 to
   8 x 17, and 17.6 s for 1 x 24, where none of that startup overlaps. The
   replayed `time_s` is a derived estimate, not a second measurement: the
   recorded schedule re-run with each query's `.timer` time, so it says what
   the workload would cost without client startup, using durations measured
   under the original contention. Its ranking favours 2 x 23 mainly because
   client startup overlaps less at low concurrency (12% of client time at
   2 x 23 versus 4% at 8 x 17). Read `wall_s` as the throughput result and
   `time_s` as the server-side view.
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

## Separating concurrency from server threads

The main sweep changes N and THREADS together (N + THREADS - 1 = 24), so it
cannot say whether a slower configuration is slower because more queries
compete or because the server has fewer workers. Two further sweeps, run with
`COMBOS` the same evening (2026-10-24, same server, 3 repeats after a
warm-up, 48 runs, 1,056 query executions, no failures, identical rows apart
from Q11's tie order), hold one factor fixed:

- `out_threads24/`: THREADS = 24 throughout, N = 1, 2, 4, 8, 16, 22. These
  configurations exceed the CPU budget: 22 x 24 runs ~45 working threads on
  24 logical CPUs.
- `out_jobs4/`: N = 4 throughout, THREADS = 1, 2, 3, 4, 6, 8, 12, 16, 20, 24.

The 1 x 24 baseline came out ~3% slower than in the main sweep (16.2 s
against 15.7 s replayed), so comparisons across the three sweeps carry that
much noise. 4 x 24 appears in both follow-up sweeps and agreed within 2%.

### Concurrency alone (THREADS = 24)

| Config (N x T) | time_s | min–max | wall_s | median query (s) | slowest query (s) |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 x 24 | 16.19 | 16.12–16.74 | 18.11 | 0.47 | 2.6 (Q09) |
| 2 x 24 | 13.80 | 13.76–14.05 | 16.34 | 0.65 | 4.6 (Q09) |
| 4 x 24 | 14.38 | 14.21–14.64 | 16.21 | 1.62 | 7.2 (Q09) |
| 8 x 24 | 16.15 | 15.89–17.28 | 16.82 | 5.12 | 14.3 (Q09) |
| 16 x 24 | 22.70 | 16.19–54.15 | 23.15 | 10.95 | 22.7 (Q05) |
| 22 x 24 | 18.29 | 18.25–25.05 | 18.83 | 10.85 | 22.7 (Q18) |

Findings:

1. **With the server at full threads, concurrency still buys nothing beyond
   2.** The shape is the same as in the main sweep: 2 x 24 is the best, 4 x 24
   is within 4%, and 8 x 24 is back to the single-query time. On measured wall
   time, 2 to 8 in flight are all within 16.2–16.8 s.
2. **Latency grows with N just as before.** The median query goes
   0.47 → 0.65 → 1.62 → 5.12 → ~11 s for N = 1, 2, 4, 8, 16+. So the latency
   growth in the main sweep was caused by the queries competing, not by the
   shrinking worker pool.
3. **Oversubscription hurts at 16 and 22 in flight, and makes runs erratic.**
   16 x 24 took 16.7 s once, 23.1 s once and 54.7 s once (Q05, Q18, Q21 and
   Q10 each stalled at 20–23 s in the 23 s run, and six queries took 48–54 s
   in the slow one); 22 x 24 took 18.8, 25.6 and 18.8 s. These are the same
   kind of stalls as the four outliers in the main sweep, and they only appear
   at high N. Even its best repeat leaves 16 x 24 at 1.17x the best
   configuration, and 22 x 24 at 1.33x.
4. **Matched against the main sweep at the same N**, giving the server its
   full 24 threads changes little at low N and helps at high N:

   | N | main sweep | fixed T = 24 |
   | ---: | ---: | ---: |
   | 2 | 2 x 23: 13.65 | 2 x 24: 13.80 |
   | 4 | 4 x 21: 14.41 | 4 x 24: 14.38 |
   | 8 | 8 x 17: 15.62 | 8 x 24: 16.15 |
   | 16 | 16 x 9: 17.58 | 16 x 24: 22.70 (best repeat 16.19) |
   | 22 | 22 x 3: 21.30 | 22 x 24: 18.29 |

   At N = 22, 24 server threads instead of 3 recovers 14%, but the result is
   still 1.33x the best, so both factors contribute at high concurrency: the
   oversubscribed scheduler and the starved worker pool each cost roughly
   15–30%. At N ≤ 8 the budget rule's "N + T - 1 = 24" was as good as giving
   the server everything.

### Server threads alone (N = 4)

| Config (N x T) | time_s | min–max | vs best | wall_s | median query (s) | slowest query (s) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 x 24 | 14.72 | 14.15–15.09 | 1.00x | 16.15 | 1.68 | 7.7 (Q09) |
| 4 x 20 | 14.91 | 14.69–15.14 | 1.01x | 16.11 | 1.66 | 7.6 (Q09) |
| 4 x 16 | 15.67 | 15.56–15.70 | 1.06x | 16.65 | 2.07 | 7.8 (Q09) |
| 4 x 12 | 16.42 | 16.35–16.76 | 1.11x | 17.31 | 2.10 | 8.1 (Q09) |
| 4 x 8 | 18.52 | 18.25–18.55 | 1.26x | 19.05 | 2.21 | 8.4 (Q21) |
| 4 x 6 | 21.13 | 21.12–21.53 | 1.43x | 21.80 | 2.56 | 10.0 (Q21) |
| 4 x 4 | 25.87 | 25.72–26.12 | 1.76x | 26.52 | 3.28 | 12.4 (Q21) |
| 4 x 3 | 29.59 | 29.53–30.25 | 2.01x | 30.21 | 3.99 | 15.7 (Q18) |
| 4 x 2 | 38.54 | 38.36–38.71 | 2.62x | 39.16 | 4.55 | 28.1 (Q18) |
| 4 x 1 | 45.04 | 44.70–46.13 | 3.06x | 45.74 | 5.56 | 24.1 (Q18) |

Findings:

1. **Server threads matter all the way up, with diminishing returns.** With
   4 queries in flight, going from 1 to 24 server threads makes the workload
   3.1x faster. Each doubling of threads buys less: 1 → 2 is 1.17x, 2 → 4
   1.49x, 4 → 8 1.40x, 8 → 16 1.18x, 16 → 24 1.06x. The knee is around 12–16
   threads; 20 and 24 are indistinguishable. These runs were the steadiest in
   all three sweeps (every configuration repeated within 1–3%).
2. **This answers the question the main sweep could not.** In the main sweep,
   8 x 17 was 14% slower than 2 x 23. Holding threads at 24, 8 x 24 is 17%
   slower than 2 x 24, so the whole gap is the extra concurrency; cutting
   threads from 24 to 17 at fixed N costs only ~5% (4 x 16 vs 4 x 24 is 6%).
   And on measured wall time the gap is 3% either way: it is mostly client
   startup overlapping less at low N.
3. **The heavy queries are what the threads are for.** Q09 goes from 21.0 s
   at 1 thread to 7.7 s at 24, Q18 from 24.1 to 5.7 s, Q13 from 20.1 to
   5.6 s. The light queries barely move until the pool is nearly full: Q02 sits
   at 0.43–0.51 s for every THREADS from 1 to 16 and only drops to its
   uncontended 0.14–0.19 s at 20 and 24. With 4 queries in flight and fewer
   than ~20 workers, a short query waits for workers its heavy neighbours
   hold.
4. **Effective server parallelism is high.** Four queries still gain from
   16 to 24 threads, and 4 x 1 at 45 s versus 1 x 24 at 16 s says the
   24-thread run gets about 2.8x the work per second of a 4-thread run. That
   is far from linear (24 logical CPUs are 12 cores with SMT), but well above
   an effective 2–4 threads; whatever limited parallelism elsewhere was not
   the server's execution pool on this workload.

## Conclusions

- The server is correct under concurrency: no failures and identical results
  across 120 runs over the three sweeps, with only Q11's documented tie-order
  difference.
- For this machine and workload, keep concurrency low (2–8 queries in flight)
  and leave the server with most of the CPUs (threads = 16–24). That region
  gives the best throughput and much lower per-query latency than high
  concurrency, for about the same wall time.
- The two effects are separable, and both are real. Concurrency by itself
  (server at 24 threads) adds no throughput past 2 in flight, multiplies
  per-query latency roughly by N, and above ~16 in flight oversubscribes the
  CPUs and makes run times erratic. Server threads by themselves (4 in flight)
  are worth 3x between 1 and 24, with the knee at 12–16.
- Do not reduce server threads to make room for clients: the configurations
  with 1–4 server threads are 1.5–3x slower in total and have the worst tail
  latencies, whether 4 or 22 queries are in flight.
- A queue in front of the server (admission control at ~2–8 queries) would
  deliver the same throughput as unbounded concurrency with far better
  latency, especially for short queries, which otherwise wait behind heavy
  ones for workers.

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
