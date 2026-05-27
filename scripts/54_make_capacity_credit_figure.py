#!/usr/bin/env python3
"""
54_make_capacity_credit_figure.py

Storage capacity-credit / accreditation diagnostic (two-panel figure).

Left panel:  PJM-style storage reliability value — ratio of storage EUE
             improvement to the improvement from 100 MW of perfect capacity.
Right panel: Equivalent firm capacity (EFC) in MW — the firm capacity that
             gives the same EUE as the storage case in a no-storage baseline.

Methods that recover full-year ED EUE (M1c, M2, M3) produce identical ratios
and EFC.  Naive heuristics (M1, M1b) have near-zero values because they waste
stored energy before scarcity events.

Source: results/paper_tables/storage_capacity_credit_comparison.csv
Output: figures/storage_capacity_credit_comparison.pdf/.png
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
                    "storage_capacity_credit_comparison.csv")
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

C_BASE = "#1565C0"   # balanced VRE — blue
C_WIND = "#2E7D32"   # wind-heavy VRE — green

# ─────────────────────────────────────────────────────────────────────────────
# Data
# ─────────────────────────────────────────────────────────────────────────────

df = pd.read_csv(DATA)

METHOD_ORDER  = ["M1", "M1b", "M1c", "M2", "M3"]
METHOD_LABELS = [
    "Naive\nMCS",
    "SOC-floor\nMCS",
    "Emergency-\nonly MCS",
    "Event-\nwindow MCS",
    "Full-year\nED",
]

df_base = df[df["case"] == "VRE120_base"].set_index("method")
df_wind = df[df["case"] == "VRE120_wind_hvy"].set_index("method")

ratio_base = [df_base.loc[m, "pjm_ratio_100mw"] if m in df_base.index else np.nan
              for m in METHOD_ORDER]
ratio_wind = [df_wind.loc[m, "pjm_ratio_100mw"] if m in df_wind.index else np.nan
              for m in METHOD_ORDER]

efc_base = [df_base.loc[m, "efc_mw"] if m in df_base.index else np.nan
            for m in METHOD_ORDER]
efc_wind = [df_wind.loc[m, "efc_mw"] if m in df_wind.index else np.nan
            for m in METHOD_ORDER]

m3_ratio_base = df_base.loc["M3", "pjm_ratio_100mw"]
m3_ratio_wind = df_wind.loc["M3", "pjm_ratio_100mw"]
m3_efc_base   = df_base.loc["M3", "efc_mw"]
m3_efc_wind   = df_wind.loc["M3", "efc_mw"]

print("Balanced VRE  — PJM ratio (100 MW ref):", [f"{v:.3f}" for v in ratio_base])
print("Wind-heavy VRE — PJM ratio (100 MW ref):", [f"{v:.3f}" for v in ratio_wind])
print("Balanced VRE  — EFC (MW):", [f"{v:.1f}" for v in efc_base])
print("Wind-heavy VRE — EFC (MW):", [f"{v:.1f}" for v in efc_wind])
print(f"Balanced VRE  — EUE_base={df_base['eue_base_mwh'].iloc[0]:.0f} MWh, "
      f"EUE_perfect_100MW={df_base['eue_perfect_100mw_mwh'].iloc[0]:.0f} MWh")
print(f"Wind-heavy VRE — EUE_base={df_wind['eue_base_mwh'].iloc[0]:.0f} MWh, "
      f"EUE_perfect_100MW={df_wind['eue_perfect_100mw_mwh'].iloc[0]:.0f} MWh")

# ─────────────────────────────────────────────────────────────────────────────
# Figure
# ─────────────────────────────────────────────────────────────────────────────

fig, (ax_ratio, ax_efc) = plt.subplots(1, 2, figsize=(7.5, 3.2))

x      = np.arange(len(METHOD_ORDER))
width  = 0.34
offset = width / 2 + 0.02

# ── Panel (a): PJM-style ratio ───────────────────────────────────────────────

ax_ratio.bar(x - offset, ratio_base, width, color=C_BASE, alpha=0.88,
             label="Balanced VRE", zorder=3)
ax_ratio.bar(x + offset, ratio_wind, width, color=C_WIND, alpha=0.88,
             label="Wind-heavy VRE", zorder=3)

ax_ratio.axhline(m3_ratio_base, color=C_BASE, lw=0.9, ls="--", zorder=2, alpha=0.65)
ax_ratio.axhline(m3_ratio_wind, color=C_WIND, lw=0.9, ls="--", zorder=2, alpha=0.65)

ax_ratio.set_xticks(x)
ax_ratio.set_xticklabels(METHOD_LABELS, fontsize=7.0)
ax_ratio.set_ylabel("PJM-style reliability value\n(100 MW perfect resource = 1.0 unit)")
ax_ratio.set_ylim(bottom=0)
ax_ratio.yaxis.set_major_locator(mticker.MaxNLocator(nbins=5, integer=False))
ax_ratio.grid(axis="y", alpha=0.18, linewidth=0.5)
ax_ratio.set_axisbelow(True)
ax_ratio.set_title("(a) Storage reliability value ratio", fontsize=8.0, pad=4)

ax_ratio.legend(loc="upper left", fontsize=7.0, borderpad=0.4,
                labelspacing=0.3, handlelength=1.4)

# ── Panel (b): Equivalent firm capacity (EFC) ────────────────────────────────

ax_efc.bar(x - offset, efc_base, width, color=C_BASE, alpha=0.88, zorder=3)
ax_efc.bar(x + offset, efc_wind, width, color=C_WIND, alpha=0.88, zorder=3)

ax_efc.axhline(m3_efc_base, color=C_BASE, lw=0.9, ls="--", zorder=2, alpha=0.65)
ax_efc.axhline(m3_efc_wind, color=C_WIND, lw=0.9, ls="--", zorder=2, alpha=0.65)

# Annotate M3 EFC values
ax_efc.annotate(f"{m3_efc_base:.0f} MW",
                xy=(x[-1] - offset, m3_efc_base),
                xytext=(x[-1] - offset - 0.6, m3_efc_base + 40),
                fontsize=6.5, color=C_BASE, ha="center",
                arrowprops=dict(arrowstyle="-", color="#AAAAAA", lw=0.5))
ax_efc.annotate(f"{m3_efc_wind:.0f} MW",
                xy=(x[-1] + offset, m3_efc_wind),
                xytext=(x[-1] + offset + 0.6, m3_efc_wind + 40),
                fontsize=6.5, color=C_WIND, ha="center",
                arrowprops=dict(arrowstyle="-", color="#AAAAAA", lw=0.5))

ax_efc.set_xticks(x)
ax_efc.set_xticklabels(METHOD_LABELS, fontsize=7.0)
ax_efc.set_ylabel("Equivalent firm capacity (MW)")
ax_efc.set_ylim(bottom=0)
ax_efc.yaxis.set_major_locator(mticker.MaxNLocator(nbins=5, integer=False))
ax_efc.grid(axis="y", alpha=0.18, linewidth=0.5)
ax_efc.set_axisbelow(True)
ax_efc.set_title("(b) Equivalent firm capacity", fontsize=8.0, pad=4)

plt.tight_layout(w_pad=1.5)

for ext in ("pdf", "png"):
    out = os.path.join(FIG, f"storage_capacity_credit_comparison.{ext}")
    fig.savefig(out, format=ext)
    print(f"  storage_capacity_credit_comparison.{ext}")
plt.close(fig)

print("\nDone.")
