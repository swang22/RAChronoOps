#!/usr/bin/env python3
"""
56_make_marginal_cc_figure.py

Normalized marginal storage capacity-credit figure.

Left panel:  δ = 1 MW  — primary normalized marginal capacity credit
             (marginal reliability contribution relative to 1 MW perfect
             firm capacity)
Right panel: δ = 10 MW — finite-difference approximation (sensitivity check)

Grouped bars: Balanced VRE (blue), Wind-heavy VRE (green).
Methods on x-axis: M1c, M2, M3.
Dashed reference lines at Full-year ED (M3) value for each case.

Source: results/paper_tables/storage_marginal_capacity_credit.csv
Output: figures/storage_marginal_capacity_credit.pdf/.png
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
                    "storage_marginal_capacity_credit.csv")
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

C_BASE = "#1565C0"   # balanced VRE  — blue
C_WIND = "#2E7D32"   # wind-heavy VRE — green

# ─────────────────────────────────────────────────────────────────────────────
# Data
# ─────────────────────────────────────────────────────────────────────────────

df = pd.read_csv(DATA)

METHOD_ORDER  = ["M1c", "M2", "M3"]
METHOD_LABELS = [
    "Emergency-\nonly MCS",
    "Event-\nwindow MCS",
    "Full-year\nED",
]

CASES = {
    "VRE120_base":      ("Balanced VRE",    C_BASE),
    "VRE120_wind_hvy":  ("Wind-heavy VRE",  C_WIND),
}

DELTA_PRIMARY = 1.0
DELTA_SENS    = 10.0


def get_cc(delta_mw, case, method):
    row = df[(df["delta_mw"] == delta_mw) &
             (df["case"] == case) &
             (df["method"] == method)]
    if row.empty:
        return np.nan
    return float(row["normalized_marginal_cc"].iloc[0])


# ─────────────────────────────────────────────────────────────────────────────
# Print diagnostics
# ─────────────────────────────────────────────────────────────────────────────

print("Normalized marginal capacity credit (CC):")
for delta_mw in [DELTA_PRIMARY, DELTA_SENS]:
    label = "primary (1 MW)" if delta_mw == 1.0 else f"sensitivity ({delta_mw:.0f} MW)"
    print(f"\n  δ = {delta_mw:.0f} MW  [{label}]")
    for case, (case_label, _) in CASES.items():
        vals = [get_cc(delta_mw, case, m) for m in METHOD_ORDER]
        print(f"    {case_label:20s}: " +
              ", ".join(f"{m}={v:.4f}" if not np.isnan(v) else f"{m}=NaN"
                        for m, v in zip(METHOD_ORDER, vals)))

# ─────────────────────────────────────────────────────────────────────────────
# Figure — two panels
# ─────────────────────────────────────────────────────────────────────────────

fig, axes = plt.subplots(1, 2, figsize=(7.5, 3.2))

PANEL_SPECS = [
    (DELTA_PRIMARY, axes[0],
     "(a) Marginal CC — δ = 1 MW (primary)",
     "Normalized marginal capacity credit\n(1 MW storage / 1 MW perfect firm)"),
    (DELTA_SENS, axes[1],
     f"(b) Finite-difference check — δ = {DELTA_SENS:.0f} MW",
     f"Normalized marginal capacity credit\n({DELTA_SENS:.0f} MW storage / {DELTA_SENS:.0f} MW perfect firm)"),
]

x      = np.arange(len(METHOD_ORDER))
width  = 0.34
offset = width / 2 + 0.02

for delta_mw, ax, title, ylabel in PANEL_SPECS:

    cc_base = [get_cc(delta_mw, "VRE120_base",     m) for m in METHOD_ORDER]
    cc_wind = [get_cc(delta_mw, "VRE120_wind_hvy", m) for m in METHOD_ORDER]

    ax.bar(x - offset, cc_base, width, color=C_BASE, alpha=0.88,
           label="Balanced VRE", zorder=3)
    ax.bar(x + offset, cc_wind, width, color=C_WIND, alpha=0.88,
           label="Wind-heavy VRE", zorder=3)

    # Reference lines at M3 value
    m3_base = get_cc(delta_mw, "VRE120_base",     "M3")
    m3_wind = get_cc(delta_mw, "VRE120_wind_hvy", "M3")
    if not np.isnan(m3_base):
        ax.axhline(m3_base, color=C_BASE, lw=0.9, ls="--", zorder=2, alpha=0.65)
    if not np.isnan(m3_wind):
        ax.axhline(m3_wind, color=C_WIND, lw=0.9, ls="--", zorder=2, alpha=0.65)

    ax.set_xticks(x)
    ax.set_xticklabels(METHOD_LABELS, fontsize=7.0)
    ax.set_ylabel(ylabel)
    ax.set_ylim(bottom=0)
    ax.yaxis.set_major_locator(mticker.MaxNLocator(nbins=5, integer=False))
    ax.grid(axis="y", alpha=0.18, linewidth=0.5)
    ax.set_axisbelow(True)
    ax.set_title(title, fontsize=8.0, pad=4)

axes[0].legend(loc="upper left", fontsize=7.0, borderpad=0.4,
               labelspacing=0.3, handlelength=1.4)

plt.tight_layout(w_pad=1.5)

for ext in ("pdf", "png"):
    out = os.path.join(FIG, f"storage_marginal_capacity_credit.{ext}")
    fig.savefig(out, format=ext)
    print(f"  storage_marginal_capacity_credit.{ext}")
plt.close(fig)

print("\nDone.")
