#!/usr/bin/env Rscript
# Social-media card (1200 x 1200 PNG) for the quack server TPC-H results.
# Usage: Rscript social_card.R [OUTPUT.png]   (default: social_card.png)
# The numbers are typed in below, not read from a sweep: they are the medians
# summarize_tpch.R reported for the two one-factor sweeps in RESULTS.md
# ("Separating concurrency from server threads") and the Q02 medians
# summarize_mixed.R reported for the admission-control test ("Admission
# control: light queries mixed into a heavy load"), so re-running a sweep does
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
  labs(title = "Total time vs server threads",
       subtitle = "4 queries in flight throughout · 3.1x faster from\n1 to 24 threads, knee at 12–16",
       x = "server threads (SET threads)", y = "seconds") +
  base()

# ---- Panel D: admission control, an 80 ms query mixed into a heavy load ------
# Q02 medians: queue wait and execution next to 16 heavy clients running back
# to back, with a gate capping queries in flight. The shared-queue bar (27 s,
# almost all queue wait) is clipped to the axis and labelled.
gate <- data.frame(
  x = c("alone", "no gate", "shared\nqueue\ncap 2", "bypass\ncap 8", "bypass\ncap 4", "bypass\ncap 2", "bypass\ncap 1"),
  wait = c(0, 0, 26.78, 0, 0, 0, 0),
  exec = c(0.10, 2.01, 0.23, 1.63, 1.17, 0.80, 0.35),
  label = c("0.10 s", "2.0 s", "27 s", "1.6 s", "1.2 s", "0.8 s", "0.35 s"))
gate$x <- factor(gate$x, levels = gate$x)
gate_top <- 3.0
gate$wait_shown <- pmin(gate$wait, gate_top - gate$exec)
gate_long <- rbind(data.frame(x = gate$x, part = "queue wait", s = gate$wait_shown),
                   data.frame(x = gate$x, part = "execution", s = gate$exec))
gate_long$part <- factor(gate_long$part, levels = c("queue wait", "execution"))

p_d <- ggplot(gate_long, aes(x, s)) +
  geom_col(aes(fill = part), width = 0.66) +
  scale_fill_manual(values = c(`queue wait` = blue_light, execution = blue), name = NULL) +
  geom_text(aes(x, pmin(wait + exec, gate_top) + 0.08, label = label), data = gate, family = fam,
            colour = ink, size = 3.4, vjust = 0) +
  scale_y_continuous(limits = c(0, gate_top + 0.45), expand = expansion(0), breaks = 0:3) +
  labs(title = "An 80 ms query under admission control",
       subtitle = "Q02 arriving every 0.5 s into 16 heavy clients · 24 threads\nbar = median queue wait + median execution\nshared: cap on all queries · bypass: cap on heavy ones only",
       x = NULL, y = "seconds") +
  base() +
  theme(legend.position = c(0.84, 0.86), legend.text = element_text(colour = ink2, size = 9),
        legend.key.size = unit(0.8, "lines"), legend.background = element_rect(fill = surface, colour = NA),
        axis.text.x = element_text(size = 9, lineheight = 0.9))

# ---- Hero tiles --------------------------------------------------------------
tiles <- data.frame(
  x = c(1, 2, 3, 4),
  big = c("15% faster", "11x latency", "3.1x faster", "0.8 s"),
  small = c("with 2 queries in flight\ninstead of one at a time",
            "with 8 in flight, for the\nsame total time as one",
            "from 1 to 24 server threads,\n4 queries in flight",
            "for an 80 ms query with a cap\nof just 2 heavy queries"))
p_tiles <- ggplot(tiles) +
  geom_text(aes(x, 1, label = big), family = fam, fontface = "bold", colour = blue_dark, size = 9, vjust = 0) +
  geom_text(aes(x, 0.78, label = small), family = fam, colour = ink2, size = 3.4, lineheight = 0.95, vjust = 1) +
  scale_x_continuous(limits = c(0.5, 4.5), expand = expansion(0)) +
  scale_y_continuous(limits = c(0.2, 1.5), expand = expansion(0)) +
  theme_void() + theme(plot.background = element_rect(fill = surface, colour = NA),
                       plot.margin = margin(0, 10, 0, 10))

# ---- Assemble ----------------------------------------------------------------
card <- p_tiles / (p_a | p_b) / (p_c | p_d) +
  plot_layout(heights = c(0.5, 1, 1.05)) +
  plot_annotation(
    title = "DuckDB 2.0 quack server under concurrent TPC-H load",
    subtitle = "Concurrency adds latency, not throughput. Server threads are what matter.\nA cap in front of the server helps the heavy queries, not the short ones.",
    caption = paste0("22 TPC-H queries at scale factor 100 · AMD Ryzen AI 9 HX 370, 12 cores / 24 threads · DuckDB v2.0.0\n",
                     "medians of 3 repeats · 9,000 query executions, 0 failures, identical results · github.com/lab1702/test-duckdb-quack"),
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
