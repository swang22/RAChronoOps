#!/usr/bin/env python3
"""
52_make_recharge_window_figure.py

Recharge-window availability diagnostic (bar chart).

For each lookback window (6–168 h), shows the share of M3 residual shortage
events and their EUE for which full-year ED accumulated comparable pre-event
storage charge within that window.  This is a recharge-window availability
proxy, not a physical feasibility proof.

Two series: balanced VRE (VRE120_base) and wind-heavy VRE (VRE120_wind_hvy).

Source: results/paper_tables/recharge_window_diagnostic.csv
Output: figures/recharge_window_diagnostic.pdf/.png
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
DATA = os.path.join(REPO, "results", "paper_tables", "recharge_window_diagnostic.csv")
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

C_BASE  = "#1565C0"   # balanced VRE — blue
C_WIND  = "#2E7D32"   # wind-heavy VRE — green

# ─────────────────────────────────────────────────────────────────────────────
# Data
# ─────────────────────────────────────────────────────────────────────────────

df = pd.read_csv(DATA)

LOOKBACKS = [6, 12, 24, 48, 72, 168]
LABELS    = ["6 h", "12 h", "24 h", "48 h", "72 h", "168 h"]

row_base = df[df["case"] == "VRE120_base"].iloc[0]
row_wind = df[df["case"] == "VRE120_wind_hvy"].iloc[0]

eue_base = [row_base[f"share_eue_covered_{L}h"] * 100 for L in LOOKBACKS]
eue_wind = [row_wind[f"share_eue_covered_{L}h"] * 100 for L in LOOKBACKS]

ev_base  = [row_base[f"share_events_covered_{L}h"] * 100 for L in LOOKBACKS]
ev_wind  = [row_wind[f"share_events_covered_{L}h"] * 100 for L in LOOKBACKS]

print("Balanced VRE  — share with comparable pre-event charge (%): ", [f"{v:.1f}" for v in eue_base])
print("Wind-heavy VRE — share with comparable pre-event charge (%): ", [f"{v:.1f}" for v in eue_wind])
print(f"Balanced VRE  — n_events={int(row_base['n_events'])}, "
      f"total_EUE={row_base['total_eue_mwh']:.0f} MWh (20 scenarios)")
print(f"Wind-heavy VRE — n_events={int(row_wind['n_events'])}, "
      f"total_EUE={row_wind['total_eue_mwh']:.0f} MWh (20 scenarios)")

# ─────────────────────────────────────────────────────────────────────────────
# Figure
# ─────────────────────────────────────────────────────────────────────────────

fig, ax = plt.subplots(figsize=(4.5, 3.2))

x      = np.arange(len(LOOKBACKS))
width  = 0.34
offset = width / 2 + 0.02

bars_base = ax.bar(x - offset, eue_base, width, color=C_BASE,  alpha=0.88,
                   label="Balanced VRE", zorder=3)
bars_wind = ax.bar(x + offset, eue_wind, width, color=C_WIND,  alpha=0.88,
                   label="Wind-heavy VRE", zorder=3)

# Event-coverage markers as small diamonds on top of EUE bars
for i, (yb, yw) in enumerate(zip(ev_base, ev_wind)):
    ax.plot(x[i] - offset, yb, marker="D", ms=3.5, color=C_BASE,  zorder=5,
            markeredgewidth=0.5, markeredgecolor="white")
    ax.plot(x[i] + offset, yw, marker="D", ms=3.5, color=C_WIND,  zorder=5,
            markeredgewidth=0.5, markeredgecolor="white")

# Reference line at 100%
ax.axhline(100, color="#AAAAAA", lw=0.6, ls=":", zorder=2)

ax.set_xticks(x)
ax.set_xticklabels(LABELS)
ax.set_xlabel("Lookback window before event start")
ax.set_ylabel("Share with comparable pre-event charge (%)")
ax.set_ylim(0, 110)
ax.yaxis.set_major_locator(mticker.MultipleLocator(20))
ax.grid(axis="y", alpha=0.18, linewidth=0.5)
ax.set_axisbelow(True)

# Legend — include diamond marker explanation
from matplotlib.lines import Line2D
legend_handles = [
    plt.Rectangle((0, 0), 1, 1, color=C_BASE,  alpha=0.88),
    plt.Rectangle((0, 0), 1, 1, color=C_WIND,  alpha=0.88),
    Line2D([0], [0], marker="D", ms=4, color="#555555", lw=0,
           markeredgewidth=0.5, markeredgecolor="white"),
]
legend_labels = [
    "Balanced VRE (event EUE)",
    "Wind-heavy VRE (event EUE)",
    "Events (diamonds)",
]
ax.legend(legend_handles, legend_labels,
          loc="lower right", fontsize=7.0,
          framealpha=0.90, edgecolor="#cccccc",
          borderpad=0.4, labelspacing=0.3, handlelength=1.4)

# Annotate the one balanced-VRE event with no comparable pre-event charge at 168 h
ax.annotate("1 event\n> 168 h",
            xy=(x[-1] - offset, eue_base[-1]),
            xytext=(x[-1] - offset - 0.55, eue_base[-1] - 16),
            fontsize=5.8, color="#555555", ha="center",
            arrowprops=dict(arrowstyle="-", color="#AAAAAA",
                            lw=0.5, shrinkA=1, shrinkB=2))

for ext in ("pdf", "png"):
    out = os.path.join(FIG, f"recharge_window_diagnostic.{ext}")
    fig.savefig(out, format=ext)
    print(f"  recharge_window_diagnostic.{ext}")
plt.close(fig)

print("\nDone.")
