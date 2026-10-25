#!/usr/bin/env Rscript
# Social-media card (1200 x 1200 PNG) for the quack server TPC-H results.
# Usage: Rscript social_card.R [OUTPUT.png]   (default: social_card.png)
# The numbers are typed in below, not read from a sweep: they are the medians
# summarize_tpch.R reported for the two one-factor sweeps in RESULTS.md
# ("Separating concurrency from server threads"), so re-running a sweep does
# not change the card until the tables here are updated.
# Needs ggplot2, patchwork and ragg, and the Inter font (falls back to the
# default sans font if Inter is not installed).
suppressPackageStartupMessages({ library(ggplot2); library(patchwork); library(ragg) })

out <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(out)) out <- "social_card.png"

# Reference palette (light): surface, inks, blue ramp.
surface <- "#fcfcfb"; ink <- "#0b0b0b"; ink2 <- "#52514e"; ink3 <- "#8a8984"
blue <- "#2a78d6"; blue_dark <- "#104281"; blue_light <- "#9ec5f4"; grid <- "#e6e5e1"
fam <- if ("Inter" %in% systemfonts::system_fonts()$family) "Inter" else "sans"

base <- function(size = 13) theme_minimal(base_size = size, base_family = fam) +
  theme(plot.background = element_rect(fill = surface, colour = NA),
        panel.background = element_rect(fill = surface, colour = NA),
        panel.grid.minor = element_blank(), panel.grid.major.x = element_blank(),
        panel.grid.major.y = element_line(colour = grid, linewidth = 0.4),
        axis.title = element_text(colour = ink2, size = size * 0.85),
        axis.text = element_text(colour = ink2, size = size * 0.85),
        plot.title = element_text(colour = ink, face = "bold", size = size * 1.15, margin = margin(b = 2)),
        plot.subtitle = element_text(colour = ink2, size = size * 0.85, margin = margin(b = 8)),
        plot.margin = margin(10, 14, 6, 10))

# ---- Panel A/B: concurrency alone, server at 24 threads ---------------------
conc <- data.frame(
  n = c(1, 2, 4, 8, 16, 22),
  time = c(16.19, 13.80, 14.38, 16.15, 22.70, 18.29),
  lo = c(16.12, 13.76, 14.21, 15.89, 16.19, 18.25),
  hi = c(16.74, 14.05, 14.64, 17.28, 54.15, 25.05),
  lat = c(0.47, 0.65, 1.62, 5.12, 10.95, 10.85))
conc$x <- factor(conc$n, levels = conc$n)
conc$fill <- ifelse(conc$n == 2, blue_dark, ifelse(conc$n == 16, blue_light, blue))

p_a <- ggplot(conc, aes(x, time)) +
  geom_col(aes(fill = fill), width = 0.62) +
  scale_fill_identity() +
  geom_linerange(aes(ymin = lo, ymax = pmin(hi, 30)), colour = ink2, linewidth = 0.5) +
  geom_label(aes(label = sprintf("%.1f s", time), y = time + 1.1), family = fam,
             colour = ink, fill = surface, linewidth = 0, label.padding = unit(0.12, "lines"),
             size = 3.4, vjust = 0) +
  scale_y_continuous(limits = c(0, 31), expand = expansion(0), breaks = seq(0, 30, 10)) +
  labs(title = "Total time for all 22 queries",
       subtitle = "server at 24 threads · whisker = min–max of 3 repeats\n(16 in flight was erratic: 16–54 s)",
       x = "queries in flight at once", y = "seconds") +
  base()

p_b <- ggplot(conc, aes(x, lat)) +
  geom_col(fill = blue, width = 0.62) +
  geom_text(aes(label = ifelse(lat < 1, sprintf("%.2f s", lat), sprintf("%.1f s", lat)), y = lat + 0.4),
            family = fam, colour = ink, size = 3.4, vjust = 0) +
  scale_y_continuous(limits = c(0, 12.8), expand = expansion(0), breaks = seq(0, 12, 4)) +
  labs(title = "Median query latency",
       subtitle = "server at 24 threads · same runs as on the left\n ",
       x = "queries in flight at once", y = "seconds") +
  base()

# ---- Panel C: server threads alone, 4 queries in flight ---------------------
thr <- data.frame(
  t = c(1, 2, 3, 4, 6, 8, 12, 16, 20, 24),
  time = c(45.04, 38.54, 29.59, 25.87, 21.13, 18.52, 16.42, 15.67, 14.91, 14.72))
thr$x <- factor(thr$t, levels = thr$t)
thr$fill <- ifelse(thr$t == 24, blue_dark, blue)

p_c <- ggplot(thr, aes(x, time)) +
  geom_col(aes(fill = fill), width = 0.66) +
  scale_fill_identity() +
  geom_text(aes(label = sprintf("%.0f", time), y = time + 1.2), family = fam, colour = ink, size = 3.4, vjust = 0) +
  scale_y_continuous(limits = c(0, 50), expand = expansion(0), breaks = seq(0, 50, 10)) +
  labs(title = "Total time for all 22 queries vs server threads",
       subtitle = "4 queries in flight throughout · 3.1x faster from 1 to 24 threads, knee at 12–16",
       x = "server threads (SET threads)", y = "seconds") +
  base()

# ---- Hero tiles --------------------------------------------------------------
tiles <- data.frame(
  x = c(1, 2, 3),
  big = c("15% faster", "11x latency", "3.1x faster"),
  small = c("with 2 queries in flight\ninstead of one at a time",
            "with 8 in flight, for the\nsame total time as one",
            "from 1 to 24 server threads,\n4 queries in flight"))
p_tiles <- ggplot(tiles) +
  geom_text(aes(x, 1, label = big), family = fam, fontface = "bold", colour = blue_dark, size = 10.5, vjust = 0) +
  geom_text(aes(x, 0.78, label = small), family = fam, colour = ink2, size = 3.7, lineheight = 0.95, vjust = 1) +
  scale_x_continuous(limits = c(0.5, 3.5), expand = expansion(0)) +
  scale_y_continuous(limits = c(0.2, 1.5), expand = expansion(0)) +
  theme_void() + theme(plot.background = element_rect(fill = surface, colour = NA),
                       plot.margin = margin(0, 10, 0, 10))

# ---- Assemble ----------------------------------------------------------------
card <- p_tiles / (p_a | p_b) / p_c +
  plot_layout(heights = c(0.55, 1, 0.95)) +
  plot_annotation(
    title = "DuckDB 2.0 quack server under concurrent TPC-H load",
    subtitle = "Concurrency adds latency, not throughput. Server threads are what matter.",
    caption = paste0("22 TPC-H queries at scale factor 100 · AMD Ryzen AI 9 HX 370, 12 cores / 24 threads · DuckDB v2.0.0\n",
                     "medians of 3 repeats · 2,640 query executions, 0 failures, identical results · github.com/lab1702/test-duckdb-quack"),
    theme = theme(plot.background = element_rect(fill = surface, colour = NA),
                  plot.title = element_text(family = fam, face = "bold", colour = ink, size = 24, margin = margin(b = 4)),
                  plot.subtitle = element_text(family = fam, colour = ink2, size = 15, margin = margin(b = 6)),
                  plot.caption = element_text(family = fam, colour = ink2, size = 10.5, hjust = 0, lineheight = 1.15,
                                              margin = margin(t = 6)),
                  plot.margin = margin(26, 26, 20, 26)))

agg_png(out, width = 1200, height = 1200, units = "px", res = 120, background = surface)
print(card)
invisible(dev.off())
cat("Wrote", out, "\n")
