#!/usr/bin/env python3
"""
47_make_event_shape_dashboard.py

Redesigned event-shape dashboard: Cleveland dot plot on a logarithmic ratio axis,
six methods (four core + two market-pattern variants), balanced VRE portfolio N=20.

Original authoritative generator: scripts/62_build_main_comparison_and_dashboard.py
This script replaces the dashboard panel of that script with a log-x design that
accommodates the market-pattern pure variant (ratio ≈ 4.5× PCM-UCED events/year).

Sources:
  results/paper_tables/event_shape_summary.csv
    — Emergency-only storage MCS, Full-year ED, PCM-UCED (reference)
  results/paper_tables/m2_gurobi_event_shape.csv
    — Event-window storage MCS (Gurobi production solver)
  results/paper_tables/market_pattern_revalidated_metrics.csv
    — MP_pure_cur, MP_emergency_cur
      (case_name=VRE120_base, calibration=energy_balanced,
       soc_init=cyclic 23.1%, N=20, seed=42)

Outputs:
  figures/event_shape_dashboard.pdf
  figures/event_shape_dashboard.png
"""

import os
import sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

sys.path.insert(0, os.path.dirname(__file__))
from mp_figure_style import MP_STYLE

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

REPO    = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TAB     = os.path.join(REPO, "results", "paper_tables")
FIG_DIR = os.path.join(REPO, "figures")
os.makedirs(FIG_DIR, exist_ok=True)

# ─────────────────────────────────────────────────────────────────────────────
# Style
# ─────────────────────────────────────────────────────────────────────────────

plt.rcParams.update({
    "figure.facecolor":   "white",
    "axes.facecolor":     "white",
    "axes.edgecolor":     "#333333",
    "axes.linewidth":     0.8,
    "font.family":        "sans-serif",
    "font.sans-serif":    ["Arial", "Helvetica", "DejaVu Sans"],
    "font.size":          8.5,
    "axes.labelsize":     8.5,
    "xtick.labelsize":    7.5,
    "ytick.labelsize":    8.0,
    "legend.fontsize":    6.8,
    "legend.framealpha":  0.90,
    "legend.edgecolor":   "#cccccc",
    "savefig.dpi":        300,
    "savefig.bbox":       "tight",
    "savefig.pad_inches": 0.05,
    "pdf.fonttype":       42,
    "ps.fonttype":        42,
})

# Core method colours — consistent with METHOD_STYLE in script 45
C_M1c = "#388E3C"   # green  — Emergency-only
C_M2  = "#1565C0"   # blue   — Event-window
C_M3  = "#555555"   # dgray  — Full-year ED
C_PCM = "#6A1B9A"   # purple — PCM-UCED

# ─────────────────────────────────────────────────────────────────────────────
# Load data
# ─────────────────────────────────────────────────────────────────────────────

df_es  = pd.read_csv(os.path.join(TAB, "event_shape_summary.csv"))
df_m2g = pd.read_csv(os.path.join(TAB, "m2_gurobi_event_shape.csv"))
df_mp  = pd.read_csv(os.path.join(TAB, "market_pattern_revalidated_metrics.csv"))

# Balanced VRE slices
es_b  = df_es[df_es["case"].str.contains("Balanced")].copy()
m2g_b = df_m2g[df_m2g["portfolio"] == "VRE120_base"].iloc[0]
mp_b  = df_mp[(df_mp["case_name"] == "VRE120_base") &
              (df_mp["method"].isin(["MP_pure_cur", "MP_emergency_cur"]))].copy()

# PCM-UCED reference row
ref = es_b[es_b["method"] == "PCM-UCED"].iloc[0]
PCM_EVENTS    = float(ref["events_per_yr"])
PCM_MEAN_DUR  = float(ref["mean_event_duration_h"])
PCM_MAX_DUR   = float(ref["max_event_duration_h"])
PCM_SHORTFALL = float(ref["max_hourly_shortfall_mw"])

print(f"PCM-UCED reference: events={PCM_EVENTS}, mean_dur={PCM_MEAN_DUR},"
      f" max_dur={PCM_MAX_DUR}, max_shortfall={PCM_SHORTFALL}")

# ─────────────────────────────────────────────────────────────────────────────
# Assemble normalized metric table
# ─────────────────────────────────────────────────────────────────────────────

# Each entry: (method_key, events_per_yr, mean_dur_h, max_dur_h, max_shortfall_mw)
raw = {}

for method_name, key in [
    ("Emergency-only storage MCS", "M1c"),
    ("Full-year ED",               "M3"),
    ("PCM-UCED",                   "PCM-UCED"),
]:
    r = es_b[es_b["method"] == method_name].iloc[0]
    raw[key] = (
        float(r["events_per_yr"]),
        float(r["mean_event_duration_h"]),
        float(r["max_event_duration_h"]),
        float(r["max_hourly_shortfall_mw"]),
    )

raw["M2"] = (
    float(m2g_b["events_per_year"]),
    float(m2g_b["mean_duration_h"]),
    float(m2g_b["max_duration_h"]),
    float(m2g_b["max_shortfall_mw"]),
)

for mp_key in ["MP_pure_cur", "MP_emergency_cur"]:
    r = mp_b[mp_b["method"] == mp_key].iloc[0]
    raw[mp_key] = (
        float(r["n_shortage_events"]),
        float(r["mean_shortage_duration_h"]),
        float(r["max_shortage_duration_h"]),
        float(r["max_shortfall_mw"]),
    )

# Normalize to PCM-UCED
ref_vals = (PCM_EVENTS, PCM_MEAN_DUR, PCM_MAX_DUR, PCM_SHORTFALL)
ratios = {}
for key, vals in raw.items():
    ratios[key] = tuple(v / r for v, r in zip(vals, ref_vals))

print("\nNormalized ratios (events, mean_dur, max_dur, max_shortfall):")
for key, r in ratios.items():
    print(f"  {key:30s}: {r[0]:.4f}  {r[1]:.4f}  {r[2]:.4f}  {r[3]:.4f}")

# ─────────────────────────────────────────────────────────────────────────────
# Build figure
# ─────────────────────────────────────────────────────────────────────────────

# Metric rows: y=0 (bottom) to y=3 (top).
# raw/ratio tuple order: (events=0, mean_dur=1, max_dur=2, max_shortfall=3)
# METRIC_IDX maps y-row → tuple index so labels and data align correctly:
#   y=0 Events/year → tuple[0]   y=1 Mean dur. → tuple[1]
#   y=2 Max shortfall → tuple[3]  y=3 Max dur. (top) → tuple[2]
METRIC_IDX    = [0, 1, 3, 2]
METRIC_LABELS = ["Events/year", "Mean dur.", "Max shortfall", "Max dur."]

# Methods in legend order, with y-jitter staggered to avoid overlap
# y_jitter: top method (+0.25) to bottom (-0.25)
METHOD_PLOT = [
    ("M1c",             "Emergency-only",             C_M1c, "o", 42, +0.25),
    ("M2",              "Event-window",               C_M2,  "D", 42, +0.15),
    ("M3",              "Full-year ED",               C_M3,  "^", 46, +0.05),
    ("PCM-UCED",        "PCM-UCED",                   C_PCM, "P", 50, -0.05),
    ("MP_pure_cur",     MP_STYLE["MP_pure_cur"]["label"],
                        MP_STYLE["MP_pure_cur"]["color"],
                        MP_STYLE["MP_pure_cur"]["marker"], 44, -0.15),
    ("MP_emergency_cur",MP_STYLE["MP_emergency_cur"]["label"],
                        MP_STYLE["MP_emergency_cur"]["color"],
                        MP_STYLE["MP_emergency_cur"]["marker"], 50, -0.25),
]

n_metrics = len(METRIC_LABELS)
y_base    = np.arange(n_metrics, dtype=float)

fig, ax = plt.subplots(figsize=(4.2, 2.8))

# Reference line at ratio = 1
ax.axvline(1.0, color="#888888", lw=0.9, ls="--", zorder=1, alpha=0.7)

for method_key, label, color, marker, ms, y_jitter in METHOD_PLOT:
    if method_key not in ratios:
        continue
    r = ratios[method_key]
    xs = [r[i] for i in METRIC_IDX]
    ys = [yi + y_jitter for yi in y_base]
    ax.scatter(xs, ys, color=color, marker=marker, s=ms, zorder=5,
               label=label, edgecolors="white", linewidths=0.5,
               alpha=MP_STYLE[method_key]["alpha"] if method_key in MP_STYLE else 0.90,
               clip_on=False)

# Log x-axis with labeled ticks in plain ratio format
ax.set_xscale("log")
ax.set_xlim(0.40, 5.20)
tick_vals = [0.5, 1.0, 2.0, 4.0]
ax.set_xticks(tick_vals)
ax.xaxis.set_major_formatter(
    mticker.FuncFormatter(lambda v, _: f"{v:g}")
)
ax.xaxis.set_minor_locator(mticker.NullLocator())

ax.set_yticks(y_base)
ax.set_yticklabels(METRIC_LABELS, fontsize=8.0)
ax.set_ylim(-0.5, n_metrics - 0.5)
ax.set_xlabel("Ratio relative to PCM-UCED", fontsize=8.5)
ax.grid(axis="x", which="major", alpha=0.20, linewidth=0.5)
ax.set_axisbelow(True)

# Compact two-column legend below the plot
ax.legend(
    loc="upper right",
    fontsize=6.5,
    markerscale=0.85,
    handlelength=0.8,
    handletextpad=0.35,
    framealpha=0.92,
    borderpad=0.35,
    ncol=2,
)

fig.tight_layout()

for ext in ("pdf", "png"):
    out = os.path.join(FIG_DIR, f"event_shape_dashboard.{ext}")
    fig.savefig(out, format=ext)
    print(f"Saved: {out}")
plt.close(fig)

print("\nDone.")
