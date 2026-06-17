#!/usr/bin/env python3
"""
46_make_mp_cc_convergence.py

Market-pattern capacity-credit convergence figure.

Two horizontal panels:
  (a) Balanced VRE portfolio
  (b) Wind-heavy VRE portfolio

Each panel:
  x-axis: N = 20, 50, 100, 200, 500, 1000  (log-scaled, all N labeled)
  y-axis: normalized marginal storage capacity credit (δ=1 MW point estimates)
  line 1: Market-pattern storage MCS (MP_pure_cur)
  line 2: Market-pattern + emergency MCS (MP_emergency_cur)
  error bands: paired-bootstrap 95% confidence intervals

Source:
  results/paper_tables/market_pattern_capacity_credit.csv
    calibration_version = pattern_energy_balanced
    delta_mw = 1.0
    N = 20, 50, 100, 200, 500, 1000

Outputs (figures/):
  figures/mp_cc_convergence.pdf
  figures/mp_cc_convergence.png

Usage:
  python scripts/46_make_mp_cc_convergence.py
"""

import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RES  = os.path.join(REPO, "results")
FIG  = os.path.join(REPO, "figures")
os.makedirs(FIG, exist_ok=True)

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
    "font.size":          9,
    "axes.labelsize":     9,
    "axes.titlesize":     9,
    "xtick.labelsize":    8,
    "ytick.labelsize":    8,
    "legend.fontsize":    7.5,
    "legend.framealpha":  0.92,
    "legend.edgecolor":   "#cccccc",
    "lines.linewidth":    1.5,
    "axes.grid":          True,
    "grid.alpha":         0.28,
    "grid.linewidth":     0.5,
    "savefig.dpi":        300,
    "savefig.bbox":       "tight",
    "savefig.pad_inches": 0.05,
    "pdf.fonttype":       42,
    "ps.fonttype":        42,
})

MP_PURE_COLOR = "#795548"    # sienna brown — market-pattern pure
MP_EMG_COLOR  = "#1565C0"    # blue — market-pattern + emergency (distinct)
MP_PURE_MARKER = "v"
MP_EMG_MARKER  = "o"

# ─────────────────────────────────────────────────────────────────────────────
# Load data
# ─────────────────────────────────────────────────────────────────────────────

df = pd.read_csv(os.path.join(RES, "paper_tables", "market_pattern_capacity_credit.csv"))

# Filter: energy-balanced calibration, δ=1 MW, target N values
TARGET_N = [20, 50, 100, 200, 500, 1000]
DELTA    = 1.0
CALIB    = "pattern_energy_balanced"

df = df[
    (df["delta_mw"]            == DELTA) &
    (df["calibration_version"] == CALIB) &
    (df["N"].isin(TARGET_N))
].copy()

# Only use rows with identified denominators and at least 1 valid bootstrap draw
df = df[df["denominator_status"] == "identified"].copy()

METHODS = {
    "MP_pure_cur":      ("Market-pattern",             MP_PURE_COLOR, MP_PURE_MARKER, "-"),
    "MP_emergency_cur": ("Market-pattern + emergency", MP_EMG_COLOR,  MP_EMG_MARKER,  "--"),
}

PORTFOLIOS = [
    ("VRE120_base",    "Balanced VRE",  "(a)"),
    ("VRE120_wind_hvy","Wind-heavy VRE","(b)"),
]

# ─────────────────────────────────────────────────────────────────────────────
# Build figure
# ─────────────────────────────────────────────────────────────────────────────

# Shared y-axis test (documented decision):
# MP_pure CC range is approximately 0.11–0.15 (span ≈ 0.04).
# MP_emergency CC range is approximately 0.33–0.72 (span ≈ 0.39).
# A shared axis spanning ~0.05–0.78 compresses MP_pure into <6% of y-range
# (~0.2 inches on a 3-inch panel), making its convergence pattern illegible.
# Separate y-limits are retained; each panel is independently scaled.

fig, axes = plt.subplots(1, 2, figsize=(6.8, 3.0), sharey=False)

for ax, (portfolio, port_label, panel_tag) in zip(axes, PORTFOLIOS):
    df_p = df[df["portfolio"] == portfolio].copy()

    all_lo, all_hi = [], []
    for method_id, (method_label, color, marker, ls) in METHODS.items():
        df_m = df_p[df_p["method"] == method_id].sort_values("N")

        if df_m.empty:
            continue

        n_vals  = df_m["N"].values
        cc_vals = df_m["cc"].values
        ci_lo   = df_m["cc_ci_lo"].values
        ci_hi   = df_m["cc_ci_hi"].values
        all_lo.extend(ci_lo.tolist())
        all_hi.extend(ci_hi.tolist())

        # Plot point estimates
        ax.plot(n_vals, cc_vals,
                color=color, marker=marker, markersize=5,
                linestyle=ls, linewidth=1.4,
                label=method_label, zorder=5, clip_on=False)

        # Bootstrap 95% CI band
        ax.fill_between(n_vals, ci_lo, ci_hi,
                         color=color, alpha=0.12, linewidth=0,
                         label="_ci_" + method_id)

        # If any N values are missing from identified set, note gap in panel
        missing = [n for n in TARGET_N
                   if n not in df_m["N"].values]
        if missing:
            ax.text(0.97, 0.03,
                    f"Gap at N={missing}: unidentified",
                    transform=ax.transAxes, fontsize=5.5,
                    ha="right", va="bottom", color="#999999", style="italic")

    # Set per-panel ylim with 10% headroom so CI bands are not clipped
    if all_lo and all_hi:
        ymin = max(0.0, min(all_lo) - 0.05 * (max(all_hi) - min(all_lo)))
        ymax = max(all_hi) + 0.10 * (max(all_hi) - min(all_lo))
        ax.set_ylim(ymin, ymax)

    ax.set_xscale("log")
    ax.set_xticks(TARGET_N)
    ax.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax.set_xlabel("Number of scenarios ($N$)")
    ax.set_ylabel("Normalized marginal CC ($\\delta$=1 MW)")
    ax.set_title(f"{panel_tag} {port_label}", fontsize=9, fontweight="bold")
    ax.legend(loc="upper right", fontsize=7, framealpha=0.9)
    ax.grid(True, which="major", alpha=0.28)
    ax.set_axisbelow(True)

fig.tight_layout(w_pad=2.0)

for ext in ("pdf", "png"):
    out = os.path.join(FIG, f"mp_cc_convergence.{ext}")
    fig.savefig(out, format=ext)
    print(f"  mp_cc_convergence.{ext}")
plt.close(fig)

print("Done.")
