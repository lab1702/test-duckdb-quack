#!/usr/bin/env Rscript
# Summarize and visualize results from ./run_mixed.sh (the admission-control
# test: light queries arriving into a heavy load, with a gate in front of the
# server).
#
# Usage: Rscript summarize_mixed.R [OUT_DIR]   (default: out_mixed)
# Reads OUT_DIR/runs.csv and OUT_DIR/queries.csv (and, if present,
# OUT_DIR/system.csv and OUT_DIR/check.csv), prints summary tables and writes
# OUT_DIR/summary.png and OUT_DIR/summary.pdf.
#
# Light-query latency is wait_s + query_s: the time in the queue before the
# gate plus the client's .timer time for the query, i.e. what a user with a
# persistent connection would see. The client's own startup (~0.1 s, in
# `seconds` but not in query_s) is left out, as in summarize_tpch.R; the
# tables also show it as e2e (wait_s + seconds). Failed queries have no
# query_s and are left out of the latencies but counted.
# Heavy throughput is a work rate over the arrival window [0, DURATION):
# each heavy query counts for the fraction of its run time that fell inside
# the window, so queries still running when the window closed (the drain)
# count only for the part they ran inside it. The average in flight is
# computed from the same intervals.

if (getRversion() < "4.1.0") stop("R 4.1.0 or newer is required", call. = FALSE)
pkgs <- c("dplyr", "tidyr", "ggplot2", "patchwork")
missing_pkgs <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  stop(sprintf("Missing R packages: %s\nInstall with: install.packages(c(%s))",
               paste(missing_pkgs, collapse = ", "),
               paste0('"', missing_pkgs, '"', collapse = ", ")), call. = FALSE)
}
suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(ggplot2); library(patchwork)
})

args <- commandArgs(trailingOnly = TRUE)
out_dir <- if (length(args) >= 1) args[[1]] else "out_mixed"
for (f in file.path(out_dir, c("runs.csv", "queries.csv"))) {
  if (!file.exists(f)) stop(sprintf("%s not found; run ./run_mixed.sh first", f), call. = FALSE)
}

# read_rows FILE: as in summarize_tpch.R; drops an unfinished last line and
# lines with the wrong number of fields.
read_rows <- function(f, optional = FALSE, ...) {
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
    stop(sprintf("%s is empty; run ./run_mixed.sh first", f), call. = FALSE)
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

runs <- read_rows(file.path(out_dir, "runs.csv"), colClasses = c(config = "character", gate = "character"))
queries <- read_rows(file.path(out_dir, "queries.csv"),
                     colClasses = c(config = "character", gate = "character", kind = "character"))
if (nrow(runs) == 0) stop("No completed runs in runs.csv", call. = FALSE)

system_file <- file.path(out_dir, "system.csv")
sysinfo <- if (file.exists(system_file)) read_rows(system_file, optional = TRUE, colClasses = "character") else NULL
setting <- function(key) {
  v <- if (!is.null(sysinfo)) sysinfo$value[sysinfo$key == key] else character()
  if (length(v) == 1 && nzchar(v)) v else NA_character_
}

# Settings in the order the first repeat ran them.
config_levels <- runs |> arrange(rep, match(config, unique(runs$config[runs$rep == min(runs$rep)]))) |>
  pull(config) |> unique()
runs$config <- factor(runs$config, levels = config_levels)
# Only queries from runs that finished (have a runs.csv row).
queries <- queries |> semi_join(runs, by = c("config", "rep"))
queries$config <- factor(queries$config, levels = config_levels)
duration <- runs |> distinct(config, rep, duration_s)

light <- queries |> filter(kind == "light")
heavy <- queries |> filter(kind == "heavy")
light_ok <- light |> filter(exit == 0, !is.na(query_s)) |>
  mutate(latency = wait_s + query_s, e2e = wait_s + seconds)

cat("Admission-control test (run_mixed.sh)\n")
if (!is.null(sysinfo)) {
  cat(sprintf("%s, %s logical CPUs, DuckDB %s, server threads = %s\n",
              setting("cpu"), setting("logical_cpus"), setting("duckdb"), setting("threads")))
  cat(sprintf("%s s per run, a light query (Q%s) every %s s, %s heavy clients cycling Q%s, %s repeats\n",
              setting("duration_s"), gsub(" ", "/Q", setting("light_queries")), setting("light_interval_s"),
              setting("heavy_clients"), gsub(" ", "/Q", setting("heavy_queries")), setting("repeats")))
}
cat(sprintf("%d runs, %d light and %d heavy queries, %d failed\n\n",
            nrow(runs), nrow(light), nrow(heavy), sum(queries$exit != 0)))
if (any(queries$exit != 0)) {
  cat("Failed queries:\n")
  queries |> filter(exit != 0) |> count(config, kind, query, name = "failed") |>
    as.data.frame() |> print(row.names = FALSE)
  cat("\n")
}

p90 <- function(x) unname(quantile(x, 0.9, type = 7))
fmt <- function(x, d = 2) ifelse(is.na(x), "", formatC(x, format = "f", digits = d))

# ---- Light latency per setting, all light queries pooled ---------------------
alone_med <- light_ok |> filter(gate == "alone") |> group_by(query) |> summarise(alone = median(latency), .groups = "drop")
per_config <- light_ok |> group_by(config, gate, cap) |>
  summarise(n = n(), median = median(latency), p90 = p90(latency), max = max(latency),
            wait = median(wait_s), exec = median(query_s), e2e = median(e2e),
            over_0.5s = mean(latency > 0.5), over_1s = mean(latency > 1), .groups = "drop")
cat("Light-query latency (wait + query_s, seconds), all light queries pooled:\n")
per_config |> transmute(config, n, median = fmt(median), p90 = fmt(p90), max = fmt(max),
                        `median wait` = fmt(wait), `median exec` = fmt(exec), `median e2e` = fmt(e2e),
                        `>0.5s` = sprintf("%.0f%%", 100 * over_0.5s), `>1s` = sprintf("%.0f%%", 100 * over_1s)) |>
  as.data.frame() |> print(row.names = FALSE)

# ---- Light latency per setting and query --------------------------------------
per_query <- light_ok |> group_by(config, gate, cap, query) |>
  summarise(n = n(), median = median(latency), p90 = p90(latency), max = max(latency),
            wait = median(wait_s), exec = median(query_s), .groups = "drop") |>
  left_join(alone_med, by = "query") |> mutate(vs_alone = median / alone)
cat("\nPer light query (median latency, p90, max; median wait and exec; median vs the same query alone):\n")
per_query |> arrange(query, config) |>
  transmute(query = sprintf("Q%02d", query), config, n, median = fmt(median), p90 = fmt(p90), max = fmt(max),
            wait = fmt(wait), exec = fmt(exec), `vs alone` = ifelse(is.na(vs_alone), "", sprintf("%.1fx", vs_alone))) |>
  as.data.frame() |> print(row.names = FALSE)

# ---- Heavy throughput and queries in flight -----------------------------------
# Fraction of each query's run that fell inside the arrival window.
inside <- queries |> filter(exit == 0) |> inner_join(duration, by = c("config", "rep")) |>
  mutate(end = admitted_s + seconds,
         overlap = pmax(0, pmin(end, duration_s) - pmax(admitted_s, 0)),
         frac = ifelse(seconds > 0, overlap / seconds, 0))
per_run <- inside |> group_by(config, rep, duration_s) |>
  summarise(heavy_per_min = 60 * sum(frac[kind == "heavy"]) / duration_s[1],
            heavy_in_flight = sum(overlap[kind == "heavy"]) / duration_s[1],
            all_in_flight = sum(overlap) / duration_s[1],
            heavy_exec = median(query_s[kind == "heavy"]),
            heavy_wait = median(wait_s[kind == "heavy"]), .groups = "drop")
per_cfg_heavy <- per_run |> group_by(config) |>
  summarise(reps = n(), heavy_per_min = median(heavy_per_min), hpm_min = min(heavy_per_min), hpm_max = max(heavy_per_min),
            heavy_in_flight = median(heavy_in_flight), all_in_flight = median(all_in_flight),
            heavy_exec = median(heavy_exec), heavy_wait = median(heavy_wait), .groups = "drop")
cat("\nHeavy load (medians over repeats): heavy queries completed per minute inside the arrival window,\n")
cat("average queries in flight (heavy, and all), median heavy execution and gate wait (seconds):\n")
per_cfg_heavy |> transmute(config, reps, `heavy/min` = fmt(heavy_per_min, 1),
                           `min-max` = paste0(fmt(hpm_min, 1), "-", fmt(hpm_max, 1)),
                           `heavy in flight` = fmt(heavy_in_flight, 1), `all in flight` = fmt(all_in_flight, 1),
                           `heavy exec` = fmt(heavy_exec), `heavy wait` = fmt(heavy_wait)) |>
  as.data.frame() |> print(row.names = FALSE)

# ---- Result check -------------------------------------------------------------
check_file <- file.path(out_dir, "check.csv")
if (file.exists(check_file)) {
  check <- read_rows(check_file, optional = TRUE, colClasses = "character")
  if (!is.null(check) && nrow(check) > 0) {
    cat("\nResult check: ", paste(sprintf("Q%s %s", check$query, check$status), collapse = ", "), "\n", sep = "")
  }
} else {
  cat("\nNo check.csv (the run did not finish), so results were not compared between runs\n")
}

# ---- Figure --------------------------------------------------------------------
theme_set(theme_minimal(base_size = 11) +
            theme(panel.grid.minor = element_blank(), panel.grid.major.x = element_blank(),
                  plot.title = element_text(face = "bold"), strip.text = element_text(face = "bold")))
blue <- "#2a7ab9"; blue_light <- "#a9c9e8"; red <- "#d1495b"

stack <- per_query |> select(config, query, wait, exec, p90) |>
  pivot_longer(c(wait, exec), names_to = "part", values_to = "s") |>
  mutate(part = factor(part, levels = c("wait", "exec"), labels = c("queue wait (median)", "execution (median)")),
         query = sprintf("Q%02d", query))
p_latency <- ggplot(stack, aes(config, s)) +
  geom_col(aes(fill = part), width = 0.7) +
  geom_point(aes(y = p90), data = distinct(stack, config, query, p90), shape = 95, size = 8, colour = red) +
  scale_fill_manual(values = c(`queue wait (median)` = blue_light, `execution (median)` = blue), name = NULL) +
  facet_wrap(~query, nrow = 1) +
  labs(title = "Light-query latency by gate setting",
       subtitle = "bars: median queue wait + median execution; red dash: 90th percentile of wait + execution",
       x = NULL, y = "seconds") +
  theme(legend.position = "top", axis.text.x = element_text(angle = 45, hjust = 1))

p_dist <- ggplot(light_ok, aes(config, latency)) +
  geom_boxplot(outlier.shape = NA, fill = "grey90", colour = "grey50", width = 0.6) +
  geom_jitter(colour = blue, size = 0.8, alpha = 0.35, width = 0.2, height = 0) +
  scale_y_log10() +
  labs(title = "Light-query latency, every query",
       subtitle = "wait + execution for each light query that ran (log scale)",
       x = NULL, y = "seconds") +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

p_heavy <- ggplot(per_cfg_heavy, aes(config, heavy_per_min)) +
  geom_col(width = 0.7, fill = "grey65") +
  geom_errorbar(aes(ymin = hpm_min, ymax = hpm_max), width = 0.25, colour = "grey25") +
  geom_text(aes(y = hpm_max, label = sprintf("%.1f in flight", all_in_flight)), vjust = -0.5, size = 3, colour = "grey25") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(title = "Heavy throughput by gate setting",
       subtitle = "heavy queries completed per minute (median of repeats, whisker min-max)\nlabel: average queries in flight, light and heavy",
       x = NULL, y = "heavy queries / min") +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

summary_plot <- p_latency / (p_dist | p_heavy) +
  plot_layout(heights = c(1, 1)) +
  plot_annotation(
    title = "Admission control in front of a DuckDB quack server",
    subtitle = sprintf("light queries arriving every %s s into %s heavy clients running back to back\nshared/N: one queue, at most N queries execute at once; bypass/N: cap N on heavy queries only, light queries skip the queue",
                       setting("light_interval_s"), setting("heavy_clients")),
    theme = theme(plot.title = element_text(face = "bold", size = 16)))
width <- max(10, 1.6 * length(config_levels) + 3)
ggsave(file.path(out_dir, "summary.png"), summary_plot, width = width, height = 11, dpi = 150, bg = "white", limitsize = FALSE)
ggsave(file.path(out_dir, "summary.pdf"), summary_plot, width = width, height = 11, limitsize = FALSE)
cat(sprintf("\nWrote %s and %s\n", file.path(out_dir, "summary.png"), file.path(out_dir, "summary.pdf")))
