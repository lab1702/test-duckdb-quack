# Results: TPC-H concurrency sweep on a DuckDB quack server

Sweep run on 2026-10-24 with `run_tpch.sh` at its defaults, summarised with
`summarize_tpch.R`. The figure the script produced is `out/summary.png`
(`out/` is not committed). Two follow-up sweeps the same evening, each varying
one factor with the other held fixed, are in
[Separating concurrency from server threads](#separating-concurrency-from-server-threads),
and a later test of admission control with short queries mixed into a heavy
load (2026-11-08, `run_mixed.sh`) is in
[Admission control](#admission-control-light-queries-mixed-into-a-heavy-load).

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

## Admission control: light queries mixed into a heavy load

The conclusions below originally proposed "a queue in front of the server
(admission control at ~2–8 queries)" so that short queries would stop waiting
behind heavy ones. A reader asked whether that setup had been run with the
80 ms queries mixed in, to see whether they drop back from ~1 s. It had not;
`run_mixed.sh` was written to test it, and it was run on 2026-11-08 against the
same server (DuckDB v2.0.0, SF100, 24 threads), summarised with
`summarize_mixed.R`. The figure is `out_mixed/summary.png` (not committed).

The sweep above is a closed batch: 22 queries, N at a time, light queries
last. That measures how long a light query *executes* next to its
neighbours, but not how long it waits for a slot, and at low N its
neighbours were light too. This test is an open-loop mix instead:

| | |
| --- | --- |
| Heavy load | 16 clients running Q18, Q09, Q13, Q21, Q10, Q05, Q03, Q04 back to back for the whole run (each starts its next query as soon as the previous one returns) |
| Light queries | Q02, Q11, Q06 in turn (0.08–0.14 s alone), one arriving every 0.5 s for 90 s, whether or not the previous one has finished |
| Gate | `none`: no cap. `shared/CAP`: at most CAP queries execute at once, light or heavy, one queue. `bypass/CAP`: at most CAP *heavy* queries execute at once, light queries skip the queue. `alone`: light queries only, as the reference |
| Runs | 8 settings x 3 repeats, 90 s each plus the drain; 4,320 light and 1,303 heavy queries, 0 failures, identical results (Q11 tie order aside). `bypass/1` was run afterwards on its own, the same way |
| Latency | queue wait + the client's `.timer` time (`query_s`), i.e. what a persistent client would see; medians over all 540 light queries per setting unless stated |

The gate never exceeded its cap (checked from the admission and completion
times of every query).

### Light-query latency

All three light queries pooled:

| Setting | median | p90 | max | median wait | median exec | over 1 s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| alone | 0.12 | 0.16 | 0.59 | 0.00 | 0.11 | 0% |
| none | 3.08 | 8.90 | 16.68 | 0.00 | 3.07 | 96% |
| shared/8 | 21.80 | 24.36 | 43.76 | 20.22 | 1.22 | 100% |
| shared/4 | 24.27 | 26.30 | 28.50 | 23.52 | 0.69 | 100% |
| shared/2 | 27.21 | 28.84 | 29.85 | 26.89 | 0.21 | 100% |
| bypass/8 | 2.21 | 6.43 | 10.90 | 0.00 | 2.21 | 91% |
| bypass/4 | 1.41 | 3.09 | 7.71 | 0.00 | 1.41 | 73% |
| bypass/2 | 0.80 | 1.56 | 4.14 | 0.00 | 0.80 | 37% |
| bypass/1 (separate run) | 0.36 | 1.01 | 2.03 | 0.00 | 0.35 | 11% |

Q02, the 80 ms query the question was about (180 samples per setting):

| Setting | median | p90 | max | vs alone |
| --- | ---: | ---: | ---: | ---: |
| alone | 0.10 | 0.11 | 0.41 | 1x |
| none | 2.01 | 3.07 | 5.56 | 21x |
| shared/8 | 21.46 | 23.87 | 25.47 | 225x |
| shared/4 | 24.23 | 26.24 | 27.80 | 255x |
| shared/2 | 27.21 | 28.85 | 29.85 | 286x |
| bypass/8 | 1.63 | 2.17 | 2.69 | 17x |
| bypass/4 | 1.17 | 1.82 | 2.31 | 12x |
| bypass/2 | 0.80 | 1.38 | 1.79 | 8x |
| bypass/1 (separate run) | 0.35 | 0.96 | 1.37 | 3.5x |

Q11 behaves like Q02 (1.03 s at bypass/2). Q06, a full scan of `lineitem`,
suffers most without a gate (7.3 s median at `none`) and recovers furthest
with one (0.68 s at bypass/2).

### Heavy throughput

Heavy queries completed per minute inside the 90 s window (a query still
running when the window closed counts for the fraction of its run time that
fell inside), with the average number of queries in flight:

| Setting | heavy/min | in flight (heavy) | in flight (all) | median heavy exec |
| --- | ---: | ---: | ---: | ---: |
| none | 24.5 | 16.0 | 25.0 | 33.1 |
| shared/8 | 35.4 | 5.2 | 8.0 | 7.4 |
| shared/4 | 37.3 | 2.4 | 4.0 | 3.5 |
| shared/2 | 36.0 | 1.3 | 2.0 | 1.6 |
| bypass/8 | 29.9 | 8.0 | 14.7 | 11.0 |
| bypass/4 | 34.4 | 4.0 | 8.0 | 6.2 |
| bypass/2 | 35.2 | 2.0 | 4.4 | 2.9 |
| bypass/1 (separate run) | 33.7 | 1.0 | 2.5 | 1.4 |

The three repeats of every setting agreed to within 0.1 heavy queries per
minute.

### Findings

1. **Without a gate, the light queries are far worse than the sweep's ~1 s.**
   Sixteen heavy queries running at once (25 in flight with the light ones)
   put the median light query at 3.1 s, the 90th percentile at 8.9 s and the
   worst at 16.7 s. The sweep's ~1 s came from runs where most of the 16+ in
   flight were themselves light; here all 16 neighbours are heavy. This
   setting also has the worst heavy throughput (24.5/min against 35–37 with
   a cap): the oversubscription the sweep saw above 16 in flight.
2. **A shared queue is the wrong admission control for short queries.** With
   one queue and a cap, the light queries execute fast once admitted (0.21 s
   at cap 2) but first wait 20–27 s for a slot, because the 16 heavy clients
   keep the queue 8–14 deep and a newcomer waits behind all of them. This is
   not an implementation detail: any first-come queue does this whenever heavy
   demand exceeds the cap. A cap alone makes short queries slower, not faster.
3. **Letting short queries bypass the gate removes the wait but not the
   contention.** With the cap on heavy queries only, the light queries start
   at once and their latency is purely execution next to CAP heavy queries:
   Q02 at 1.63, 1.17 and 0.80 s for a cap of 8, 4 and 2, i.e. 17x, 12x and 8x
   its time alone, with 91%, 73% and 37% of all light queries still over 1 s.
   A further run of `bypass/1`, one heavy query at a time (`out_mixed_b1/`,
   3 repeats, 540 light and 197 heavy queries, no failures), gets Q02 to
   0.35 s median, 3.5x its time alone, with a 90th percentile of 0.96 s and
   11% of all light queries still over 1 s.
   DuckDB gives every running query the whole 24-thread pool and does not
   prioritise between queries, so a short query's few pipeline tasks queue
   behind the heavy queries' many, however few heavy queries there are.
4. **So, to the question: no, they do not drop back.** Admission control
   with priority for short queries takes an 80–140 ms query from 2–7 s to
   roughly 0.7–1.0 s under this load with two heavy queries running, which
   is where the sweep's ~1 s was, and to 0.35 s with a single heavy query
   running; it does not bring it back to its uncontended 0.1 s. The only setting
   that did was `alone`. Getting short queries back to ~0.1 s would need
   either idle capacity (a heavy load that is not continuous) or isolation
   the server does not offer, such as a separate server process, or separate
   machine, for short queries; neither was tested here.
5. **The sweep's low-N latency numbers were optimistic for light queries.**
   The sweep reported Q02 at 0.14 s with 2 in flight and 0.24 s with 4,
   because in a longest-first batch the queries still running when Q02 starts
   are light. Next to two heavy queries Q02 takes 0.80 s, next to four 1.17 s.
   The write-up's "2–8 in flight" recommendation therefore says nothing about
   short-query latency unless the heavy queries are also limited to about 2.
6. **A cap costs the heavy queries nothing; it helps them.** Heavy throughput
   is 35–37 per minute at every cap from 2 to 8 with a shared queue, 44–52%
   more than with no gate, and the same flat plateau the sweep found between
   2 and 8 in flight. Letting the light queries bypass the cap costs 2%
   (cap 2) to 16% (cap 8) of heavy throughput, the CPU the light queries
   take.

Caveats specific to this test: the heavy demand is unbounded (16 clients
that never pause), which is the worst case for a shared queue; with heavy
queries arriving slower than the cap drains them, the queue would often be
empty and a shared gate would behave like `bypass`. The gate is a counting
semaphore, so waiters are admitted in roughly, not strictly, arrival order.
Light queries that take longer than 0.5 s overlap the next arrival, so under
load they also contend with each other (1.6 light queries in flight on
average at bypass/2, 0.4 at `alone`). All clients ran on the server's
machine.

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
- A queue in front of the server helps the heavy queries (a cap of 2–8
  delivers 44–52% more heavy throughput than 16 at once) but does not, by
  itself, help short queries: with one queue they wait behind the heavy
  backlog (20–27 s here), and even when they are let past the gate they run
  8–17x slower than alone next to 2–8 heavy queries, 3.5x next to one (see
  [Admission control](#admission-control-light-queries-mixed-into-a-heavy-load)).
  Short-query latency needs idle capacity or isolation, not just a cap.

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
