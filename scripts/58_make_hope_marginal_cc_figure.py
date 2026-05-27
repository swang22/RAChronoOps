#!/usr/bin/env python3
"""
58_make_hope_marginal_cc_figure.py

HOPE-PCM-ED vs Full-year ED (M3) normalized marginal capacity-credit comparison.

Two-panel grouped bar chart:
  Left panel:  Balanced VRE (VRE120_base, N=20)
  Right panel: Wind-heavy VRE (VRE120_wind_hvy, N=5)

For each panel:
  - x-axis: model (Full-year ED, HOPE-PCM-ED)
  - y-axis: normalized marginal CC (primary delta = 1 MW)
  - horizontal dashed line at 1.0
  - small scatter markers for delta = 5 and 10 MW sensitivities

Source: results/paper_tables/hope_pcm_ed_marginal_cc_validation.csv
Output: figures/hope_pcm_ed_marginal_cc_validation.pdf/.png
"""

import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DATA = os.path.join(REPO, "results", "paper_tables",
                    "hope_pcm_ed_marginal_cc_validation.csv")
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
    "font.size":          8.5,
    "axes.labelsize":     8.5,
    "xtick.labelsize":    7.5,
    "ytick.labelsize":    7.5,
    "legend.fontsize":    7.5,
    "legend.framealpha":  0.90,
    "legend.edgecolor":   "#cccccc",
    "savefig.dpi":        300,
    "savefig.bbox":       "tight",
    "savefig.pad_inches": 0.05,
    "pdf.fonttype":       42,
    "ps.fonttype":        42,
})

C_HOPE = "#1565C0"   # HOPE-PCM-ED  — blue
C_M3   = "#2E7D32"   # Full-year ED — green
ALPHA  = 0.88

MODEL_ORDER  = ["Full-year ED (M3)", "HOPE-PCM-ED"]
MODEL_LABELS = ["Full-year\nED (M3)", "HOPE-\nPCM-ED"]
MODEL_COLORS = [C_M3, C_HOPE]

PANEL_SPECS = [
    ("VRE120_base",     "(a) Balanced VRE (N=20)"),
    ("VRE120_wind_hvy", "(b) Wind-heavy VRE (N=5)"),
]

# ─────────────────────────────────────────────────────────────────────────────
# Data
# ─────────────────────────────────────────────────────────────────────────────

df = pd.read_csv(DATA)

def get_cc(case, model, delta_mw):
    row = df[(df["case"] == case) & (df["model"] == model) &
             (df["delta_mw"] == delta_mw)]
    if row.empty:
        return np.nan
    return float(row["normalized_marginal_cc"].iloc[0])

# ─────────────────────────────────────────────────────────────────────────────
# Print diagnostics
# ─────────────────────────────────────────────────────────────────────────────

print("HOPE-PCM-ED vs Full-year ED (M3) — normalized marginal CC:")
for case, title in PANEL_SPECS:
    print(f"\n  {title}")
    for model in MODEL_ORDER:
        vals = {d: get_cc(case, model, d) for d in [1.0, 5.0, 10.0]}
        print(f"    {model:25s}: "
              + ", ".join(f"d={d:.0f}MW CC={v:.4f}" if not np.isnan(v) else f"d={d:.0f}MW CC=NaN"
                          for d, v in vals.items()))
        err = get_cc(case, model, 1.0) - get_cc(case, "Full-year ED (M3)", 1.0)
        if not np.isnan(err):
            print(f"      Error vs M3 (d=1MW): {err:+.5f}")

# ─────────────────────────────────────────────────────────────────────────────
# Figure
# ─────────────────────────────────────────────────────────────────────────────

fig, axes = plt.subplots(1, 2, figsize=(7.0, 3.2))

x      = np.arange(len(MODEL_ORDER))
width  = 0.55

for ax, (case, title) in zip(axes, PANEL_SPECS):
    # Primary bars: delta = 1 MW
    for xi, (model, color) in enumerate(zip(MODEL_ORDER, MODEL_COLORS)):
        cc = get_cc(case, model, 1.0)
        ax.bar(xi, cc, width, color=color, alpha=ALPHA, zorder=3,
               label=MODEL_LABELS[xi])

    # Sensitivity markers: delta = 5 and 10 MW
    for xi, model in enumerate(MODEL_ORDER):
        for delta_mw, marker, msize in [(5.0, "D", 4.5), (10.0, "s", 4.5)]:
            cc = get_cc(case, model, delta_mw)
            if not np.isnan(cc):
                ax.scatter(xi, cc, marker=marker, s=msize**2, zorder=5,
                           color="white", edgecolors="#333333", linewidths=0.8)

    # Reference line at 1.0
    ax.axhline(1.0, color="#888888", lw=0.9, ls="--", zorder=2, alpha=0.8)

    ax.set_xticks(x)
    ax.set_xticklabels(MODEL_LABELS, fontsize=7.5)
    ax.set_ylabel("Normalized marginal capacity credit\n(1 MW storage / 1 MW perfect firm)")
    ax.set_ylim(bottom=0)
    ax.yaxis.set_major_locator(mticker.MaxNLocator(nbins=5, integer=False))
    ax.grid(axis="y", alpha=0.18, linewidth=0.5)
    ax.set_axisbelow(True)
    ax.set_title(title, fontsize=8.0, pad=4)

    # Annotate bar tops with CC values
    for xi, model in enumerate(MODEL_ORDER):
        cc = get_cc(case, model, 1.0)
        if not np.isnan(cc):
            ax.text(xi, cc + 0.003, f"{cc:.3f}", ha="center", va="bottom",
                    fontsize=6.5, color="#222222")

# Sensitivity legend
from matplotlib.lines import Line2D
sens_legend = [
    Line2D([0], [0], marker="D", color="w", markeredgecolor="#333333",
           markeredgewidth=0.8, markersize=4.5, label="delta=5 MW"),
    Line2D([0], [0], marker="s", color="w", markeredgecolor="#333333",
           markeredgewidth=0.8, markersize=4.5, label="delta=10 MW"),
]
axes[1].legend(handles=sens_legend, loc="upper right", fontsize=6.5,
               title="Sensitivity", title_fontsize=6.5,
               borderpad=0.4, labelspacing=0.3, handlelength=1.2)

plt.tight_layout(w_pad=1.5)

for ext in ("pdf", "png"):
    out = os.path.join(FIG, f"hope_pcm_ed_marginal_cc_validation.{ext}")
    fig.savefig(out, format=ext)
    print(f"  hope_pcm_ed_marginal_cc_validation.{ext}")
plt.close(fig)

print("\nDone.")
