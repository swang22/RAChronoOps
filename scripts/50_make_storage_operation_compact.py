#!/usr/bin/env python3
"""
50_make_storage_operation_compact.py

Compact main-text figure: storage operation during a representative
shortage event (balanced VRE, Scenario 15, rel hours -8 to +10).

Four methods are shown:
  Emergency-only storage MCS, Event-window storage MCS,
  Full-year ED, and PCM-UCED.

Three stacked panels:
  (a) Load shedding (MW)
  (b) Aggregate storage discharge (MW)
  (c) Aggregate state of charge (MWh)

Source data:
  results/storage_operation_comparison/event_window.csv
    — M1c, M2, M3 hourly dispatch (from script 48)
  exports/hope_model_cases/RAChronoOps_VRE120_base_s015_UC/output/
    — PCM-UCED hourly storage and load-shedding dispatch (HOPE framework)

Outputs (figures/):
  storage_operation_comparison_compact.pdf
  storage_operation_comparison_compact.png
"""

import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

REPO      = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DATA      = os.path.join(REPO, "results", "storage_operation_comparison",
                          "event_window.csv")
HOPE_DIR  = os.path.join(REPO, "exports", "hope_model_cases",
                          "RAChronoOps_VRE120_base_s015_UC", "output")
FIG       = os.path.join(REPO, "figures")
os.makedirs(FIG, exist_ok=True)

# ─────────────────────────────────────────────────────────────────────────────
# Style
# ─────────────────────────────────────────────────────────────────────────────

plt.rcParams.update({
    "figure.facecolor":    "white",
    "axes.facecolor":      "white",
    "axes.edgecolor":      "#333333",
    "axes.linewidth":      0.7,
    "font.family":         "sans-serif",
    "font.sans-serif":     ["Arial", "Helvetica", "DejaVu Sans"],
    "font.size":           7.5,
    "axes.labelsize":      7.5,
    "xtick.labelsize":     7.0,
    "ytick.labelsize":     7.0,
    "legend.fontsize":     6.0,
    "legend.framealpha":   0.92,
    "legend.edgecolor":    "#cccccc",
    "legend.handlelength": 2.2,
    "savefig.dpi":         300,
    "savefig.bbox":        "tight",
    "savefig.pad_inches":  0.04,
    "pdf.fonttype":        42,
    "ps.fonttype":         42,
})

C_M1C = "#1565C0"   # solid blue   — Emergency-only storage MCS
C_M2  = "#2E7D32"   # solid green  — Event-window storage MCS
C_M3  = "#E65100"   # dashed       — Full-year ED
C_PCM = "#6A1B9A"   # dash-dot     — PCM-UCED

LW     = 1.5    # primary linewidth
LW_SEC = 1.0    # secondary (Full-year ED, PCM-UCED) linewidth

STORAGE_CAPACITY_MWH = 3932.0   # VRE120_base: 983 MW × 4 h

# ─────────────────────────────────────────────────────────────────────────────
# Load MCS / ED data
# ─────────────────────────────────────────────────────────────────────────────

df_all = pd.read_csv(DATA).sort_values("rel_hour").reset_index(drop=True)

REL_LO, REL_HI = -8, 10
mask = (df_all["rel_hour"] >= REL_LO) & (df_all["rel_hour"] <= REL_HI)
df   = df_all[mask].copy()

rel    = df["rel_hour"].values
hours  = df["hour"].values          # absolute hour index (1-indexed, matches HOPE)

ls_m1c  = df["m1c_load_shed_mw"].values
ls_m2   = df["m2_load_shed_mw"].values
ls_m3   = df["m3_load_shed_mw"].values

dc_m1c  = df["m1c_storage_discharge_mw"].values
dc_m2   = df["m2_storage_discharge_mw"].values
dc_m3   = df["m3_storage_discharge_mw"].values

soc_m1c = df["m1c_soc_mwh"].values
soc_m2  = df["m2_soc_mwh"].values
soc_m3  = df["m3_soc_mwh"].values

# ─────────────────────────────────────────────────────────────────────────────
# Load PCM-UCED data from HOPE exports
# ─────────────────────────────────────────────────────────────────────────────

def _hope_vals(fname, col_fmt, hours):
    """Read a HOPE wide-format CSV and return an array for the given hours."""
    df_h = pd.read_csv(os.path.join(HOPE_DIR, fname))
    row  = df_h.iloc[0]
    return np.array([row[col_fmt.format(h)] for h in hours])

ls_pcm  = _hope_vals("power_loadshedding.csv", "h{}",      hours)
dc_pcm  = _hope_vals("es_power_discharge.csv", "dc_h{}",   hours)
soc_pcm = _hope_vals("es_power_soc.csv",       "soc_h{}",  hours)

# ─────────────────────────────────────────────────────────────────────────────
# Window EUE
# ─────────────────────────────────────────────────────────────────────────────

eue_m1c = ls_m1c.sum()
eue_m2  = ls_m2.sum()
eue_m3  = ls_m3.sum()
eue_pcm = ls_pcm.sum()
print(f"Local-window EUE (MWh):\n"
      f"  Emergency-only MCS: {eue_m1c:.1f}\n"
      f"  Event-window MCS:   {eue_m2:.1f}\n"
      f"  Full-year ED:       {eue_m3:.1f}\n"
      f"  PCM-UCED:           {eue_pcm:.1f}")

# ─────────────────────────────────────────────────────────────────────────────
# Figure layout
# ─────────────────────────────────────────────────────────────────────────────

fig, axes = plt.subplots(
    3, 1,
    figsize=(3.5, 5.2),
    sharex=True,
    gridspec_kw={"hspace": 0.08, "top": 0.97, "bottom": 0.10,
                 "left": 0.17, "right": 0.97},
)
ax_ls, ax_dc, ax_soc = axes

x_lo = REL_LO - 0.5
x_hi = REL_HI + 0.5

for ax in axes:
    ax.axvline(0, color="#999999", lw=0.7, ls="--", zorder=1, label="_zero")
    ax.grid(axis="y", alpha=0.18, linewidth=0.5)
    ax.set_axisbelow(True)
    ax.set_xlim(x_lo, x_hi)

# ─────────────────────────────────────────────────────────────────────────────
# (a) Load shedding
# ─────────────────────────────────────────────────────────────────────────────

# Draw order: M3 (bottom, dashed), M1c, M2, PCM-UCED (top, most distinct)
ax_ls.step(rel, ls_m3,  where="post", color=C_M3,  lw=LW_SEC, ls="--",          zorder=3)
ax_ls.step(rel, ls_m1c, where="post", color=C_M1C, lw=LW,                        zorder=4)
ax_ls.step(rel, ls_m2,  where="post", color=C_M2,  lw=LW,                        zorder=5)
ax_ls.step(rel, ls_pcm, where="post", color=C_PCM, lw=LW_SEC, ls=(0,(4,1,1,1)), zorder=6)

ax_ls.set_ylabel("Load shedding (MW)")
ymax_ls = max(ls_m1c.max(), ls_m2.max(), ls_m3.max(), ls_pcm.max())
ax_ls.set_ylim(-20, ymax_ls * 1.52)
ax_ls.yaxis.set_major_formatter(
    matplotlib.ticker.FuncFormatter(lambda x, _: f"{int(x):,}" if x >= 0 else "")
)

legend_handles = [
    Line2D([0], [0], color=C_M1C, lw=LW,     ls="-",          label="Emergency-only MCS"),
    Line2D([0], [0], color=C_M2,  lw=LW,     ls="-",          label="Event-window MCS"),
    Line2D([0], [0], color=C_M3,  lw=LW_SEC, ls="--",         label="Full-year ED"),
    Line2D([0], [0], color=C_PCM, lw=LW_SEC, ls=(0,(4,1,1,1)),label="PCM-UCED"),
]
ax_ls.legend(handles=legend_handles, loc="upper right",
             fontsize=5.8, framealpha=0.92, edgecolor="#cccccc",
             handlelength=2.2, handleheight=0.9,
             borderpad=0.35, labelspacing=0.25)

ax_ls.text(0.014, 0.96, "(a)", transform=ax_ls.transAxes,
           fontsize=7.5, fontweight="bold", va="top")

ax_ls.annotate("first\nshedding\nhour",
               xy=(0, -20), xytext=(-3.5, ymax_ls * 0.60),
               fontsize=5.5, color="#777777", ha="center",
               arrowprops=dict(arrowstyle="-", color="#AAAAAA",
                               lw=0.6, shrinkA=0, shrinkB=2))

# ─────────────────────────────────────────────────────────────────────────────
# (b) Storage discharge
# ─────────────────────────────────────────────────────────────────────────────

ax_dc.step(rel, dc_m3,  where="post", color=C_M3,  lw=LW_SEC, ls="--",          zorder=3)
ax_dc.step(rel, dc_m1c, where="post", color=C_M1C, lw=LW,                        zorder=4)
ax_dc.step(rel, dc_m2,  where="post", color=C_M2,  lw=LW,                        zorder=5)
ax_dc.step(rel, dc_pcm, where="post", color=C_PCM, lw=LW_SEC, ls=(0,(4,1,1,1)), zorder=6)

ax_dc.axhline(983.0, color="#BBBBBB", lw=0.6, ls=":", zorder=2)
ax_dc.text(x_hi - 0.2, 983.0 + 30, "983 MW",
           fontsize=5.8, color="#888888", ha="right", va="bottom")

ax_dc.set_ylabel("Storage discharge (MW)")
ymax_dc = max(dc_m1c.max(), dc_m2.max(), dc_m3.max(), dc_pcm.max())
ax_dc.set_ylim(-20, ymax_dc * 1.18)

ax_dc.text(0.014, 0.96, "(b)", transform=ax_dc.transAxes,
           fontsize=7.5, fontweight="bold", va="top")

# ─────────────────────────────────────────────────────────────────────────────
# (c) State of charge
# ─────────────────────────────────────────────────────────────────────────────

ax_soc.plot(rel, soc_m3,  color=C_M3,  lw=LW_SEC, ls="--",          zorder=3)
ax_soc.plot(rel, soc_m1c, color=C_M1C, lw=LW,                        zorder=4)
ax_soc.plot(rel, soc_m2,  color=C_M2,  lw=LW,                        zorder=5)
ax_soc.plot(rel, soc_pcm, color=C_PCM, lw=LW_SEC, ls=(0,(4,1,1,1)), zorder=6)

ax_soc.axhline(STORAGE_CAPACITY_MWH, color="#BBBBBB", lw=0.6, ls=":", zorder=2)
ax_soc.text(x_hi - 0.2, STORAGE_CAPACITY_MWH + 90,
            f"{STORAGE_CAPACITY_MWH/1000:.1f} GWh",
            fontsize=5.8, color="#888888", ha="right", va="bottom")

ax_soc.set_ylabel("State of charge (MWh)")
ax_soc.set_ylim(-100, STORAGE_CAPACITY_MWH * 1.13)
ax_soc.yaxis.set_major_locator(matplotlib.ticker.MultipleLocator(1000))

ax_soc.text(0.014, 0.96, "(c)", transform=ax_soc.transAxes,
            fontsize=7.5, fontweight="bold", va="top")

# ─────────────────────────────────────────────────────────────────────────────
# Shared x-axis
# ─────────────────────────────────────────────────────────────────────────────

ticks = np.arange(REL_LO, REL_HI + 1, 2)
ax_soc.set_xticks(ticks)
ax_soc.set_xticklabels([f"{t:+d}" if t != 0 else "0" for t in ticks])
ax_soc.set_xlabel("Hour relative to first shedding hour")

# ─────────────────────────────────────────────────────────────────────────────
# Save
# ─────────────────────────────────────────────────────────────────────────────

for ext in ("pdf", "png"):
    out = os.path.join(FIG, f"storage_operation_comparison_compact.{ext}")
    fig.savefig(out, format=ext)
    print(f"  storage_operation_comparison_compact.{ext}")
plt.close(fig)

print(f"\nDone.  Window rel {REL_LO}–{REL_HI} "
      f"(h{df['hour'].iloc[0]}–h{df['hour'].iloc[-1]}).")
print(f"All four methods EUE in window: "
      f"M1c={eue_m1c:.0f}  M2={eue_m2:.0f}  M3={eue_m3:.0f}  "
      f"PCM-UCED={eue_pcm:.0f} MWh")
