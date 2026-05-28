#!/usr/bin/env python3
"""
60_make_model_rerun_figure.py

Model-rerun vs analytical perfect-resource denominator diagnostic figure.

Two-panel grouped bar chart (one panel per VRE scenario):
  - Two bar groups per panel:
      LEFT  (solid):   CC using model-rerun denominator  (main result)
      RIGHT (hatched): CC using analytical denominator   (diagnostic comparison)
  - Within each group: Full-year ED (M3) bar + HOPE-PCM-ED bar
  - Horizontal dashed reference line at CC = 1.0
  - Scatter markers for delta = 5 and 10 MW sensitivities (rerun group only)

Key message: model-rerun denominator eliminates LP-degeneracy-induced spread
between M3 and HOPE; analytical denominator shows non-trivial model-specific bias.

Source: results/paper_tables/marginal_cc_model_rerun_validation.csv
Output: figures/marginal_cc_model_rerun_validation.pdf/.png
"""

import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
from matplotlib.patches import Patch
from matplotlib.lines import Line2D

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DATA = os.path.join(REPO, "results", "paper_tables",
                    "marginal_cc_model_rerun_validation.csv")
FIG  = os.path.join(REPO, "figures")
os.makedirs(FIG, exist_ok=True)

if not os.path.exists(DATA):
    raise FileNotFoundError(
        f"Results CSV not found: {DATA}\n"
        "Run scripts/59_marginal_cc_model_rerun.jl first."
    )

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
    "legend.fontsize":    7.0,
    "legend.framealpha":  0.90,
    "legend.edgecolor":   "#cccccc",
    "savefig.dpi":        300,
    "savefig.bbox":       "tight",
    "savefig.pad_inches": 0.05,
    "pdf.fonttype":       42,
    "ps.fonttype":        42,
})

C_M3   = "#2E7D32"   # Full-year ED — green
C_HOPE = "#1565C0"   # HOPE-PCM-ED  — blue
ALPHA  = 0.88

MODEL_ORDER  = ["Full-year ED (M3)", "HOPE-PCM-ED"]
MODEL_LABELS = ["M3", "HOPE"]
MODEL_COLORS = [C_M3, C_HOPE]

PANEL_SPECS = [
    ("VRE120_base",     "(a) Balanced VRE (N=20)"),
    ("VRE120_wind_hvy", "(b) Wind-heavy VRE (N=5)"),
]

# ─────────────────────────────────────────────────────────────────────────────
# Data
# ─────────────────────────────────────────────────────────────────────────────

df = pd.read_csv(DATA)

def get(case, model, delta_mw, col):
    row = df[(df["case"] == case) & (df["model"] == model) &
             (df["delta_mw"] == delta_mw)]
    if row.empty:
        return np.nan
    return float(row[col].iloc[0])

def cc_rerun(case, model, delta_mw=1.0):
    return get(case, model, delta_mw, "normalized_marginal_cc_rerun")

def cc_anal(case, model, delta_mw=1.0):
    return get(case, model, delta_mw, "normalized_marginal_cc_analytical")

# ─────────────────────────────────────────────────────────────────────────────
# Diagnostics
# ─────────────────────────────────────────────────────────────────────────────

print("Normalized marginal CC — model rerun vs analytical denominator")
print("=" * 65)
for case, title in PANEL_SPECS:
    print(f"\n{title}")
    print(f"  {'Model':25s}  {'CC_rerun':>10}  {'CC_anal':>10}  {'diff':>8}")
    print("  " + "-" * 58)
    for model in MODEL_ORDER:
        cr = cc_rerun(case, model)
        ca = cc_anal(case, model)
        diff = (cr - ca) if not (np.isnan(cr) or np.isnan(ca)) else np.nan
        print(f"  {model:25s}  {cr:10.5f}  {ca:10.5f}  {diff:+8.5f}")
    # M3-HOPE agreement under rerun vs analytical
    cr_m3   = cc_rerun(case, "Full-year ED (M3)")
    cr_hope = cc_rerun(case, "HOPE-PCM-ED")
    ca_m3   = cc_anal(case, "Full-year ED (M3)")
    ca_hope = cc_anal(case, "HOPE-PCM-ED")
    print(f"\n  HOPE - M3  (rerun):     {cr_hope - cr_m3:+.5f}")
    print(f"  HOPE - M3  (analytical):{ca_hope - ca_m3:+.5f}")

# ─────────────────────────────────────────────────────────────────────────────
# Figure layout
# ─────────────────────────────────────────────────────────────────────────────
# Within each panel there are 2 bar groups separated by a gap:
#   Group A (model rerun)  — solid bars
#   Group B (analytical)   — hatched bars
# Each group has 2 bars: M3 (green) and HOPE (blue).
#
# x positions (width = 0.35 each, gap_within = 0.04, gap_between = 0.45):
#   M3_rerun   at 0.00
#   HOPE_rerun at 0.39
#   M3_anal    at 1.05
#   HOPE_anal  at 1.44

W        = 0.35          # bar width
GAP_IN   = 0.04          # within-group gap
GAP_BTW  = 0.45          # between-group gap
X_M3_R   = 0.0
X_HP_R   = X_M3_R + W + GAP_IN
X_M3_A   = X_HP_R + W + GAP_BTW
X_HP_A   = X_M3_A + W + GAP_IN

GRP_R_CTR = (X_M3_R + X_HP_R + W) / 2 - W / 2  # center of rerun group
GRP_A_CTR = (X_M3_A + X_HP_A + W) / 2 - W / 2  # center of analytical group

fig, axes = plt.subplots(1, 2, figsize=(7.5, 3.4))

for ax, (case, title) in zip(axes, PANEL_SPECS):

    # ── Bars (delta = 1 MW) ───────────────────────────────────────────────
    for x_pos, model, color, hatch in [
        (X_M3_R, "Full-year ED (M3)", C_M3,   None),
        (X_HP_R, "HOPE-PCM-ED",       C_HOPE, None),
        (X_M3_A, "Full-year ED (M3)", C_M3,   "//"),
        (X_HP_A, "HOPE-PCM-ED",       C_HOPE, "//"),
    ]:
        cc_val = (cc_rerun(case, model) if hatch is None
                  else cc_anal(case, model))
        ax.bar(x_pos, cc_val, W,
               color=color, alpha=ALPHA, hatch=hatch, zorder=3,
               edgecolor="#333333", linewidth=0.5)

    # ── Sensitivity scatter (rerun group only, delta = 5 and 10 MW) ──────
    for x_pos, model in [(X_M3_R, "Full-year ED (M3)"), (X_HP_R, "HOPE-PCM-ED")]:
        x_ctr = x_pos + W / 2
        for delta_mw, marker in [(5.0, "D"), (10.0, "s")]:
            cc_val = cc_rerun(case, model, delta_mw)
            if not np.isnan(cc_val):
                ax.scatter(x_ctr, cc_val, marker=marker, s=4.5**2, zorder=5,
                           color="white", edgecolors="#333333", linewidths=0.8)

    # ── Bar-top annotations (delta = 1 MW) ───────────────────────────────
    for x_pos, model, is_rerun in [
        (X_M3_R, "Full-year ED (M3)", True),
        (X_HP_R, "HOPE-PCM-ED",       True),
        (X_M3_A, "Full-year ED (M3)", False),
        (X_HP_A, "HOPE-PCM-ED",       False),
    ]:
        cc_val = (cc_rerun(case, model) if is_rerun else cc_anal(case, model))
        if not np.isnan(cc_val):
            ax.text(x_pos + W / 2, cc_val + 0.005, f"{cc_val:.3f}",
                    ha="center", va="bottom", fontsize=6.0, color="#222222")

    # ── Group labels (x-axis labels) ─────────────────────────────────────
    ax.set_xticks([X_M3_R + W/2, X_HP_R + W/2, X_M3_A + W/2, X_HP_A + W/2])
    ax.set_xticklabels(["M3", "HOPE", "M3", "HOPE"], fontsize=7.0)

    # Bracket labels under groups
    grp_r_x = (X_M3_R + X_HP_R + W) / 2
    grp_a_x = (X_M3_A + X_HP_A + W) / 2
    ax.text(grp_r_x, -0.075, "Model rerun", ha="center", va="top",
            fontsize=7.5, transform=ax.get_xaxis_transform(), style="normal")
    ax.text(grp_a_x, -0.075, "Analytical\n(legacy)", ha="center", va="top",
            fontsize=7.5, transform=ax.get_xaxis_transform())

    # ── Reference line ────────────────────────────────────────────────────
    ax.axhline(1.0, color="#888888", lw=0.9, ls="--", zorder=2, alpha=0.8)

    # ── Axes formatting ───────────────────────────────────────────────────
    ax.set_ylabel("Normalized marginal CC\n(storage / perfect firm)")
    ax.set_ylim(bottom=0)
    ax.set_xlim(-0.15, X_HP_A + W + 0.15)
    ax.yaxis.set_major_locator(mticker.MaxNLocator(nbins=5, integer=False))
    ax.grid(axis="y", alpha=0.18, linewidth=0.5)
    ax.set_axisbelow(True)
    ax.tick_params(axis="x", length=0, pad=3)
    ax.set_title(title, fontsize=8.0, pad=4)

# ─────────────────────────────────────────────────────────────────────────────
# Legend
# ─────────────────────────────────────────────────────────────────────────────

legend_handles = [
    Patch(facecolor=C_M3,   alpha=ALPHA, edgecolor="#333333", lw=0.5,
          label="Full-year ED (M3)"),
    Patch(facecolor=C_HOPE, alpha=ALPHA, edgecolor="#333333", lw=0.5,
          label="HOPE-PCM-ED"),
    Patch(facecolor="white", hatch="//", edgecolor="#888888", lw=0.5,
          label="Analytical denom."),
    Line2D([0], [0], marker="D", color="w", markeredgecolor="#333333",
           markeredgewidth=0.8, markersize=4.5, label="δ=5 MW"),
    Line2D([0], [0], marker="s", color="w", markeredgecolor="#333333",
           markeredgewidth=0.8, markersize=4.5, label="δ=10 MW"),
]
axes[0].legend(handles=legend_handles, loc="upper left", fontsize=6.5,
               borderpad=0.5, labelspacing=0.3, handlelength=1.5,
               handletextpad=0.4, framealpha=0.92)

plt.tight_layout(w_pad=1.8)

for ext in ("pdf", "png"):
    out = os.path.join(FIG, f"marginal_cc_model_rerun_validation.{ext}")
    fig.savefig(out, format=ext)
    print(f"Saved: marginal_cc_model_rerun_validation.{ext}")
plt.close(fig)

print("\nDone.")
