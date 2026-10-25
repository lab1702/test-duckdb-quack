#!/usr/bin/env Rscript
# Summarize and visualize results from ./run_tpch.sh.
#
# Usage: Rscript summarize_tpch.R [OUT_DIR]   (default: out)
# Reads OUT_DIR/runs.csv and OUT_DIR/queries.csv (and, if present,
# OUT_DIR/system.csv and OUT_DIR/check.csv), prints summary tables, and
# writes OUT_DIR/summary.png and OUT_DIR/summary.pdf.
#
# With several repeats per combination, times (run totals and per-query
# latencies alike) are medians over the repeats that every combination
# completed, counting only repeats in which no query failed (all of them for a
# combination where every repeat had a failure). A run that is left out (see
# the messages below) costs its repeat for every combination. Combinations are
# ranked on their total time without client startup (see replay below) when
# the sweep recorded query_s and start_s, else on measured wall time.
# Query latency is the client's .timer for the query (query_s), which excludes
# client startup and connecting but includes result transfer and CSV output.
# Sweeps without query_s fall back to client wall time for every query; the
# per-query latencies never mix the two. In the ranking replay, a failed or
# untimed query keeps its client wall time.

# Rscript evaluates this file one expression at a time, so this check runs
# before R < 4.1 would fail to parse the |> and \(x) syntax below.
if (getRversion() < "4.1.0") stop("R 4.1.0 or newer is required", call. = FALSE)
pkgs <- c("dplyr", "tidyr", "ggplot2", "patchwork")
missing_pkgs <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  stop(sprintf("Missing R packages: %s\nInstall with: install.packages(c(%s))",
               paste(missing_pkgs, collapse = ", "),
               paste0('"', missing_pkgs, '"', collapse = ", ")), call. = FALSE)
}

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
out_dir <- if (length(args) >= 1) args[[1]] else "out"

for (f in file.path(out_dir, c("runs.csv", "queries.csv"))) {
  if (!file.exists(f)) stop(sprintf("%s not found; run ./run_tpch.sh first", f), call. = FALSE)
}

# read_rows FILE: read a CSV that run_tpch.sh writes one line at a time. A
# line it didn't finish (disk full, a kill) is the last one and has no
# newline, and a line with the wrong number of fields (an edit) would read as
# a row with missing or shifted values; both are dropped with a message. A
# file with no complete line (truncated before the header) is an error, or
# NULL with optional = TRUE. Further arguments go to read.csv.
read_rows <- function(f, optional = FALSE, ...) {
  # The bytes are read once, so the newline test and the lines can't disagree
  # when the file is being appended to.
  bytes <- readBin(f, "raw", file.size(f))
  lines <- if (length(bytes) > 0) strsplit(rawToChar(bytes), "\n", fixed = TRUE)[[1]] else character()
  if (length(bytes) > 0 && bytes[length(bytes)] != as.raw(10L)) {
    message(sprintf("Ignoring the incomplete last line of %s", f))
    lines <- lines[-length(lines)]
  }
  lines <- sub("\r$", "", lines)
  lines <- lines[nzchar(lines)]
  if (length(lines) == 0) {
    if (optional) return(NULL)
    stop(sprintf("%s is empty; run ./run_tpch.sh first", f), call. = FALSE)
  }
  n_fields <- lengths(regmatches(lines, gregexpr(",", lines, fixed = TRUE))) + 1
  bad <- n_fields != n_fields[1]
  if (any(bad)) {
    message(sprintf("Ignoring %d line(s) of %s with %s fields instead of %d",
                    sum(bad), f, paste(sort(unique(n_fields[bad])), collapse = " or "), n_fields[1]))
    lines <- lines[!bad]
  }
  read.csv(text = lines, ...)
}
runs <- read_rows(file.path(out_dir, "runs.csv"))
queries <- read_rows(file.path(out_dir, "queries.csv"))
if (nrow(runs) == 0) {
  stop(sprintf("No completed runs in %s (was the sweep interrupted?)",
               file.path(out_dir, "runs.csv")), call. = FALSE)
}
# Machine the sweep ran on, from run_tpch.sh (older sweeps have no system.csv).
system_file <- file.path(out_dir, "system.csv")
spec_line <- NULL
if (file.exists(system_file)) {
  # Split each key,value line on its first comma only, so an unquoted value
  # containing commas (older system.csv files) is kept whole.
  lines <- readLines(system_file, warn = FALSE)[-1]
  vals <- sub("^[^,]*,", "", lines)
  quoted <- grepl('^".*"$', vals)
  vals[quoted] <- gsub('""', '"', substr(vals[quoted], 2, nchar(vals[quoted]) - 1))
  specs <- setNames(as.list(vals), sub(",.*", "", lines))
  spec <- function(key) {
    v <- specs[[key]]
    if (is.null(v) || !nzchar(v) || v == "0") "?" else v
  }
  spec_line <- sprintf("%s (%s cores / %s threads), %s GiB RAM, DuckDB %s",
                       spec("cpu"), spec("cores"), spec("logical_cpus"), spec("memory_gib"), spec("duckdb"))
  cat("Machine: ", spec_line, "\n\n", sep = "")
}

# Older sweeps had no repeats and no query_s column.
if (!"rep" %in% names(runs)) runs$rep <- 1L
if (!"rep" %in% names(queries)) queries$rep <- 1L
has_query_s <- "query_s" %in% names(queries)
if (!has_query_s) queries$query_s <- NA_real_
run_key <- c("jobs", "threads", "rep")

# read.csv types an all-empty column as logical, and one non-numeric cell (an
# edit) types its whole column as character, which would fail deep inside the
# dplyr code below. Make every numeric column numeric, with such a cell NA, so
# that drop_na_rows reports and drops its row instead.
to_numeric <- function(d, cols) {
  for (c in intersect(cols, names(d))) d[[c]] <- suppressWarnings(as.numeric(d[[c]]))
  d
}
runs <- to_numeric(runs, c(run_key, "seconds", "failed"))
queries <- to_numeric(queries, c(run_key, "query", "exit", "start_s", "seconds", "query_s"))

# A row with an empty or non-numeric field (an edit) would count toward a
# run's 22 rows and turn the checks below into NA. Drop such rows (the run
# then fails the 22-row check, or is a partial run).
drop_na_rows <- function(d, cols, what) {
  bad <- Reduce(`|`, lapply(intersect(cols, names(d)), \(c) is.na(d[[c]])))
  if (any(bad)) {
    message(sprintf("Ignoring %d incomplete row(s) in %s", sum(bad), what))
    d <- d[!bad, , drop = FALSE]
  }
  d
}
runs <- drop_na_rows(runs, c(run_key, "seconds", "failed"), "runs.csv")
queries <- drop_na_rows(queries, c(run_key, "query", "exit", "start_s", "seconds"), "queries.csv")
if (nrow(runs) == 0) stop("No complete run rows in runs.csv", call. = FALSE)
# run_tpch.sh starts runs.csv afresh each sweep, so a repeated run can only
# come from an edit or two sweeps' files joined; the joins below would
# multiply such rows, so stop instead.
dup <- runs[duplicated(runs[run_key]), run_key]
if (nrow(dup) > 0) {
  stop(sprintf("Duplicate run rows in runs.csv for %s (was the file edited?)",
               paste(sprintf("%d x %d (repeat %d)", dup$jobs, dup$threads, dup$rep), collapse = ", ")),
       call. = FALSE)
}

# A run with query rows but no runs.csv row was interrupted mid-run; it is
# left out below, so say so.
partial <- queries |> anti_join(runs, by = run_key) |> distinct(jobs, threads, rep)
if (nrow(partial) > 0) {
  message(sprintf("Ignoring unfinished run(s): %s",
                  paste(sprintf("%d x %d (repeat %d)", partial$jobs, partial$threads, partial$rep),
                        collapse = ", ")))
}

# run_tpch.sh writes a run's 22 query rows (one per query 1-22) before its
# runs.csv row, so a finished run with anything else means queries.csv was
# edited or lost writes; its times and concurrency would be wrong, so leave
# it out.
# Its failure count is checked against the rows' exit codes too (below, once
# the set of runs is final), since the tables use one and the per-query plots
# the other.
row_check <- runs |>
  left_join(queries |>
              group_by(jobs, threads, rep) |>
              summarise(n_rows = n(), n_queries = n_distinct(query[query %in% 1:22]),
                        n_failed = sum(exit != 0), .groups = "drop"),
            by = run_key) |>
  mutate(n_rows = coalesce(n_rows, 0L), n_queries = coalesce(n_queries, 0L),
         complete = n_rows == 22 & n_queries == 22)
bad_rows <- row_check |> filter(!complete)
if (nrow(bad_rows) > 0) {
  message(sprintf("Ignoring run(s) without one row per query 1-22 in queries.csv: %s",
                  paste(sprintf("%d x %d (repeat %d: %d rows, %d of the queries)", bad_rows$jobs,
                                bad_rows$threads, bad_rows$rep, bad_rows$n_rows, bad_rows$n_queries),
                        collapse = ", ")))
  runs <- runs |> semi_join(row_check |> filter(complete), by = run_key)
  if (nrow(runs) == 0) stop("No run has one row per query 1-22 in queries.csv", call. = FALSE)
}
# From here on a run's failure count is its rows' exit codes.
runs <- runs |>
  select(-failed) |>
  inner_join(row_check |> select(all_of(run_key), failed = n_failed), by = run_key)

# An interrupted sweep leaves the configs it reached in the last repeat with
# one more repeat than the rest, and a run left out above leaves its config
# one short. Compare all configs on the same repeats, so the medians aren't
# skewed by a repeat only some configs have. (Repeats with a failed query are
# still left out per config below, so a config's medians can rest on fewer
# samples than another's; clean_reps shows how many.)
common_reps <- Reduce(intersect, split(runs$rep, paste(runs$jobs, runs$threads)))
extra <- runs |> filter(!rep %in% common_reps)
if (length(common_reps) == 0) {
  stop("No repeat has a usable run for every configuration", call. = FALSE)
}
if (nrow(extra) > 0) {
  message(sprintf("Ignoring repeats without a usable run for every configuration%s: %s",
                  if (nrow(bad_rows) > 0 || nrow(partial) > 0)
                    " (a run left out above costs its repeat for every configuration)" else "",
                  paste(sprintf("%d x %d (repeat %d)", extra$jobs, extra$threads, extra$rep),
                        collapse = ", ")))
  runs <- runs |> filter(rep %in% common_reps)
}
# Only for the runs kept above, so this doesn't name runs that aren't used.
mismatch <- row_check |>
  filter(complete, failed != n_failed) |>
  semi_join(runs, by = run_key)
if (nrow(mismatch) > 0) {
  message(sprintf("runs.csv and queries.csv disagree on failed queries for %s; using queries.csv",
                  paste(sprintf("%d x %d (repeat %d: %d vs %d)", mismatch$jobs, mismatch$threads,
                                mismatch$rep, mismatch$failed, mismatch$n_failed),
                        collapse = ", ")))
}

# One label per (jobs, threads) combination, ordered by threads then jobs.
configs <- runs |>
  distinct(jobs, threads) |>
  arrange(threads, jobs) |>
  mutate(config = factor(sprintf("%d x %d", jobs, threads),
                         levels = sprintf("%d x %d", jobs, threads)))
config_axis <- "concurrent queries x server threads"

runs <- runs |> inner_join(configs, by = c("jobs", "threads"))
queries <- queries |>
  semi_join(runs, by = run_key) |>
  inner_join(configs, by = c("jobs", "threads")) |>
  mutate(query = factor(sprintf("Q%02d", query), levels = sprintf("Q%02d", 1:22)),
         ok = exit == 0)

# Use query_s if the sweep recorded it, else client wall time throughout.
# Successful queries missing query_s are left out of the medians. When no
# query succeeded there is nothing to time, so just go by the column.
use_query_s <- if (any(queries$ok)) any(!is.na(queries$query_s[queries$ok])) else has_query_s
latency_desc <- if (use_query_s) "client .timer for the query (no client startup)" else
  "client wall time (includes client startup; no query_s recorded)"
queries$latency <- if (use_query_s) queries$query_s else queries$seconds
n_untimed <- sum(queries$ok & is.na(queries$latency))
if (n_untimed > 0) {
  message(sprintf(paste("%d successful queries have no query_s: they are left out of the latency",
                        "medians and keep their client wall time in time_s"), n_untimed))
}

# Configs are ranked on query_wall_s: the run's total time replayed with each
# query's query_s instead of its client wall time, so client startup (about
# the same per query, but serial at 1 concurrent query and overlapped at 22)
# doesn't penalise low concurrency. Failed or untimed queries keep their wall
# time. Without query_s (or start_s), or when no query succeeded so nothing
# was timed, rank on the measured wall time instead.
use_replay <- use_query_s && any(queries$ok) && "start_s" %in% names(queries)
rank_desc <- if (use_replay) {
  "time_s = total time for all 22 queries without client startup (the run's\nschedule replayed with query_s)"
} else {
  "time_s = total time for all 22 queries (client wall time)"
}

# replay(DURATIONS, JOBS): when the last query finishes if the queries, in
# start order, each take the next free one of JOBS slots, as run_tpch.sh does.
replay <- function(durations, jobs) {
  slots <- numeric(jobs)
  for (d in durations) {
    i <- which.min(slots)
    slots[i] <- slots[i] + d
  }
  max(slots)
}

# ---- Summary tables --------------------------------------------------------

# Per run: how many queries were in flight on average. This uses client wall
# time, since that is how long each query held one of the `jobs` slots.
# client_pct is the share of that slot time spent outside the query (client
# startup, connecting, exit), which wall_s includes, over the timed queries
# only; NA without query_s or when no query was timed.
per_run <- queries |>
  arrange(config, rep, if (use_replay) start_s else 0) |>
  group_by(config, rep) |>
  summarise(slot_s = sum(seconds),
            client_s = sum((seconds - latency)[ok & !is.na(latency)]),
            timed_slot_s = sum(seconds[ok & !is.na(latency)]),
            query_wall_s = if (use_replay) replay(ifelse(ok & !is.na(latency), latency, seconds), first(jobs)) else NA_real_,
            .groups = "drop") |>
  inner_join(runs |> select(config, rep, wall_s = seconds, failed), by = c("config", "rep")) |>
  mutate(concurrency = slot_s / wall_s,
         client_pct = if (use_query_s) ifelse(timed_slot_s > 0, 100 * client_s / timed_slot_s, NA_real_) else NA_real_,
         time_s = if (use_replay) query_wall_s else wall_s)

# Times are over the clean repeats (no failed query), since a run whose
# queries crash immediately would otherwise look fast (and the other queries
# in it run with less contention). A config with no clean repeat keeps the
# times of all its repeats, but can't be the baseline and is listed last.
per_run <- per_run |>
  group_by(config) |>
  mutate(use = if (any(failed == 0)) failed == 0 else TRUE) |>
  ungroup()

# Per query and config: median latency over the same repeats, where the query
# succeeded. n and n_failed count all repeats.
per_query <- queries |>
  inner_join(per_run |> select(config, rep, use), by = c("config", "rep")) |>
  group_by(query, config) |>
  summarise(n = n(),
            n_failed = sum(!ok),
            latency = if (any(use & ok & !is.na(latency))) median(latency[use & ok & !is.na(latency)]) else NA_real_,
            .groups = "drop")

run_summary <- per_run |>
  group_by(config) |>
  summarise(reps = n(),
            clean_reps = sum(failed == 0),
            time_min = min(time_s[use]),
            time_max = max(time_s[use]),
            time_s = median(time_s[use]),
            wall_s = median(wall_s[use]),
            failed_reps = sum(failed > 0),
            failed = sum(failed),
            avg_concurrency = median(concurrency[use]),
            # NA for a repeat with no timed query; NA overall only if all are.
            client_pct = median(client_pct[use], na.rm = TRUE),
            .groups = "drop") |>
  inner_join(configs, by = "config") |>
  inner_join(per_query |>
               group_by(config) |>
               summarise(median_query_s = median(latency, na.rm = TRUE),
                         max_query_s = if (any(!is.na(latency))) max(latency, na.rm = TRUE) else NA_real_,
                         .groups = "drop"),
             by = "config")
clean_s <- run_summary$time_s[run_summary$clean_reps > 0]
best <- if (length(clean_s) > 0) min(clean_s) else NA_real_
run_summary <- run_summary |>
  mutate(vs_best = ifelse(clean_reps > 0, time_s / best, NA_real_),
         is_best = clean_reps > 0 & time_s == best & !is.na(best)) |>
  arrange(clean_reps == 0, time_s) |>
  # On a tie, only the first (top) config is marked best; vs_best shows the
  # others at 1.00x.
  mutate(is_best = is_best & !duplicated(is_best))
# Every config has the same repeats (see common_reps above).
n_reps <- max(run_summary$reps)
any_partial <- any(run_summary$failed > 0 & run_summary$clean_reps > 0)
any_unclean <- any(run_summary$clean_reps == 0)

cat("Runs, fastest first\n(", rank_desc, ",\n",
    "median over the clean_reps repeats with no failed query, with min-max in\n",
    "time_range; wall_s = measured wall time including client startup, median\n",
    "over the same repeats; failed = failed queries summed over all repeats, in\n",
    "failed_reps of them; configs with no clean repeat use all their repeats,\n",
    "have no vs_best and come last; avg_concurrency = queries in flight on average;\n",
    "client_pct = % of the queries' client wall time spent starting, connecting\n",
    "and exiting the client, which wall_s includes but which overlaps less at\n",
    "fewer concurrent queries;\n",
    "query_s = ", latency_desc, ", median over the same repeats)\n\n", sep = "")
print(as.data.frame(run_summary |>
  transmute(config, reps, clean_reps, time_s = sprintf("%.2f", time_s),
            time_range = sprintf("%.2f-%.2f", time_min, time_max),
            vs_best = ifelse(is.na(vs_best), "-", sprintf("%.2fx", vs_best)),
            wall_s = sprintf("%.2f", wall_s),
            failed, failed_reps, avg_concurrency = round(avg_concurrency, 2),
            client_pct = ifelse(is.na(client_pct), "-", sprintf("%.1f", client_pct)),
            median_query_s = round(median_query_s, 2), max_query_s = round(max_query_s, 2))),
  row.names = FALSE)

cat("\nPer-query latency in seconds (median over the same repeats as time_s;",
    "NA = failed every time, or no timing recorded)\n\n")
print(as.data.frame(per_query |>
  select(query, config, latency) |>
  arrange(config) |>
  pivot_wider(names_from = config, values_from = latency) |>
  arrange(query) |>
  mutate(across(-query, \(x) round(x, 2)))),
  row.names = FALSE)

if (any(!queries$ok)) {
  cat("\nFailed queries (error messages, if the client printed any, in\n",
      file.path(out_dir, "jNN_tNN/rN/qNN.err"), "; tNNN or tNNNN for 100 or more threads)\n\n", sep = "")
  print(as.data.frame(queries |> filter(!ok) |> select(config, rep, query, exit)), row.names = FALSE)
}

# Result comparison across runs, from run_tpch.sh (older sweeps and
# interrupted ones have no check.csv).
check_file <- file.path(out_dir, "check.csv")
check_line <- NULL
check <- NULL
# A 0-byte check.csv (the sweep died as it was created) counts as none, and so
# does one with no complete line. Through read_rows, so a last line the sweep
# didn't finish is dropped and the check then reads as incomplete.
if (file.exists(check_file) && file.size(check_file) > 0) {
  # Both columns as character: read.csv types an all-empty column as logical
  # NA, which would make the status tests below NA and stop the script, and
  # reading query as integer would stop it on a non-integer value (an edit)
  # although check.csv is optional. Such rows are dropped here instead, which
  # makes the check incomplete below.
  check <- read_rows(check_file, optional = TRUE, colClasses = "character")
  if (!is.null(check)) {
    q <- suppressWarnings(as.integer(check$query))
    if (anyNA(q)) {
      message(sprintf("Ignoring %d row(s) of %s without a query number: %s", sum(is.na(q)), check_file,
                      paste(check$query[is.na(q)], collapse = ", ")))
      check <- check[!is.na(q), , drop = FALSE]
      q <- q[!is.na(q)]
    }
    check$query <- q
  }
}
if (!is.null(check)) {
  qs <- function(status) {
    q <- check$query[check$status == status]
    if (length(q) == 22) "all 22 queries" else paste(sprintf("Q%02d", q), collapse = ", ")
  }
  known <- c("same", "reordered", "misordered", "single", "differ", "no_results")
  unknown <- check[!check$status %in% known, ]
  # A check interrupted part-way has only some queries' rows.
  complete <- setequal(check$query, 1:22) && nrow(check) == 22
  check_line <- paste(c(
    if (!complete) sprintf("INCOMPLETE, only %d of 22 queries checked", length(intersect(check$query, 1:22))),
    if (any(check$status == "differ")) sprintf("RESULTS DIFFER between runs for %s", qs("differ")),
    if (any(check$status == "misordered")) sprintf("ROWS IN DIFFERENT ORDERS for %s (ORDER BY has no ties)", qs("misordered")),
    if (nrow(unknown) > 0) sprintf("unknown status for %s",
                                   paste(sprintf("Q%02d (%s)", unknown$query, unknown$status), collapse = ", ")),
    if (any(check$status == "no_results")) sprintf("no successful run to compare for %s", qs("no_results")),
    if (any(check$status == "single")) sprintf("only one successful run, nothing compared, for %s", qs("single")),
    if (any(check$status == "reordered")) sprintf("%s: same rows, tied rows in different orders", qs("reordered")),
    if (complete && all(check$status %in% c("same", "reordered"))) "no query returned different rows between runs"),
    collapse = "; ")
  check_line <- paste("Result check:", check_line)
  cat("\n", check_line, "\n", sep = "")
} else if (nrow(runs) > 1) {
  how <- if (file.exists(check_file)) "empty" else "no"
  check_line <- sprintf("Result check: not available (%s check.csv)", how)
  message(sprintf("%s check.csv in %s, so results were not compared across runs (was the sweep interrupted?)",
                  if (how == "empty") "Empty" else "No", out_dir))
}

# ---- Plots -----------------------------------------------------------------

theme_set(theme_minimal(base_size = 11) +
            theme(panel.grid.minor = element_blank(),
                  plot.title = element_text(face = "bold")))

wall_subtitle <- c(if (use_replay) "without client startup (schedule replayed with query_s)",
                   if (n_reps > 1) sprintf("median of up to %d repeats; whiskers = min-max", n_reps),
                   if (any_partial) "repeats where a query failed are left out",
                   if (any_unclean) "red = a query failed in every repeat (not eligible for best)")
p_wall <- ggplot(run_summary, aes(config, time_s)) +
  geom_col(aes(fill = ifelse(is_best, "best", ifelse(clean_reps == 0, "failed", "other"))),
           width = 0.7, show.legend = FALSE) +
  geom_errorbar(aes(ymin = time_min, ymax = time_max), width = 0.25, colour = "grey25",
                data = filter(run_summary, pmax(clean_reps, ifelse(clean_reps == 0, reps, 0)) > 1)) +
  geom_text(aes(y = time_max, label = ifelse(failed > 0,
                                             sprintf("%.1fs\n%d failed\nin %d/%d reps", time_s, failed,
                                                     failed_reps, reps),
                                             sprintf("%.1fs", time_s))),
            vjust = -0.4, size = 2.9, lineheight = 0.9) +
  scale_fill_manual(values = c(best = "#2a7ab9", failed = "#d1495b", other = "grey65")) +
  scale_y_continuous(expand = expansion(mult = c(0, if (any(run_summary$failed > 0)) 0.3 else 0.18))) +
  labs(title = "Total time for all 22 queries",
       # NULL, not "", when nothing applies, so no empty line is reserved.
       subtitle = if (length(wall_subtitle) > 0) paste(wall_subtitle, collapse = "\n"),
       x = config_axis, y = "seconds")

p_conc <- ggplot(run_summary, aes(config, avg_concurrency)) +
  geom_col(width = 0.7, fill = "grey65") +
  geom_point(aes(y = jobs), shape = 95, size = 10, colour = "#d1495b") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
  labs(title = "Average queries in flight",
       subtitle = "bar = sum of client wall times / total time\nred tick = configured limit",
       x = config_axis, y = "queries")

# .timer has millisecond resolution, so a very fast query can record 0, which
# the log scales below can't show; plot those at 1 ms.
per_query$plot_latency <- pmax(per_query$latency, 0.001)

# geom_blank keeps the config axis when no query succeeded anywhere; the
# fixed jitter seed keeps the output the same for the same data.
p_box <- ggplot(filter(per_query, !is.na(latency)), aes(config, plot_latency)) +
  (if (all(is.na(per_query$latency))) geom_blank(aes(config, 1), data = per_query)) +
  geom_boxplot(outlier.shape = NA, fill = "grey90", colour = "grey50") +
  geom_jitter(colour = "#2a7ab9", size = 1.3, alpha = 0.7,
              position = position_jitter(width = 0.15, height = 0, seed = 1)) +
  scale_x_discrete(drop = FALSE) +
  scale_y_log10() +
  labs(title = "Per-query latency",
       subtitle = sprintf("log scale; one point per query: %s, median over repeats; failures omitted", latency_desc),
       x = config_axis, y = "seconds")

# Tiles where every repeat failed are grey and labelled FAIL (n/a if some
# succeeded but none has a timing); a * marks a query that failed in some
# repeats, so its median is over the others. White labels on the darker
# (slower) half of the log colour scale.
log_mid <- if (any(!is.na(per_query$latency))) mean(range(log10(per_query$plot_latency), na.rm = TRUE)) else 0
# The scale's `trans` argument became `transform` in ggplot2 3.5.0.
log10_arg <- if (packageVersion("ggplot2") >= "3.5.0") list(transform = "log10") else list(trans = "log10")
p_heat <- ggplot(per_query, aes(config, query, fill = plot_latency)) +
  geom_tile(colour = "white") +
  geom_text(aes(label = ifelse(is.na(latency), ifelse(n_failed == n, "FAIL", "n/a"),
                               sprintf(ifelse(latency < 1, "%.2f%s", "%.1f%s"), latency,
                                       ifelse(n_failed > 0, "*", ""))),
                colour = !is.na(latency) & log10(plot_latency) > log_mid),
            size = 2.6, show.legend = FALSE) +
  scale_colour_manual(values = c(`TRUE` = "white", `FALSE` = "black")) +
  do.call(scale_fill_viridis_c, c(log10_arg, list(option = "magma", direction = -1,
                                                  begin = 0.15, end = 0.95, na.value = "grey85"))) +
  scale_y_discrete(limits = rev) +
  labs(title = "Latency by query (seconds)",
       subtitle = if (any(per_query$n_failed > 0 & !is.na(per_query$latency))) "* = failed in some repeats",
       x = config_axis, y = NULL, fill = "seconds")

# limitsize = FALSE: ggsave refuses widths over 50 inches by default, which a
# sweep with 45 or more configurations (a 45-CPU machine at MARGIN=0) reaches.
width <- max(10, 1 + 1.1 * nrow(configs))

# plot_annotation doesn't wrap, and the result-check line can list many
# queries, so wrap it to the figure (about 12 characters per inch at this size).
wrap_line <- function(s) if (is.null(s)) NULL else paste(strwrap(s, width = floor(12 * width)), collapse = "\n")
summary_plot <- (p_wall + p_conc) / p_box / p_heat +
  plot_layout(heights = c(1, 1, 2.2)) +
  plot_annotation(
    title = "TPC-H on DuckDB quack server",
    subtitle = paste(c(wrap_line(spec_line),
                       sprintf(paste0("%d configurations x %d repeats; server threads = SET threads ",
                                      "(shared workers), and each in-flight query adds its own thread"),
                               nrow(configs), n_reps),
                       wrap_line(check_line)),
                     collapse = "\n"),
    theme = theme(plot.title = element_text(face = "bold", size = 16)))

ggsave(file.path(out_dir, "summary.png"), summary_plot, width = width, height = 15, dpi = 150, bg = "white",
       limitsize = FALSE)
ggsave(file.path(out_dir, "summary.pdf"), summary_plot, width = width, height = 15, limitsize = FALSE)
cat(sprintf("\nWrote %s and %s\n", file.path(out_dir, "summary.png"), file.path(out_dir, "summary.pdf")))
