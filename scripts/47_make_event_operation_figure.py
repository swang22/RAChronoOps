#!/usr/bin/env python3
"""
47_make_event_operation_figure.py

Appendix figure: representative shortage-event operation comparison.

Source data:
  results/hope_n20_pilot/hope_load_shed_hourly.csv
  (ED mode = Full-year ED / Emergency-only Storage MCS after alignment;
   UC mode = PCM-UCED)

Selected event:
  Scenario 15, balanced VRE portfolio.  Full-year ED (ED mode) sheds over five
  consecutive hours (4984-4988, 4313 MWh).  PCM-UCED (UC mode) redistributes
  the same total EUE (4572 MWh including surrounding h4990) by shifting some
  deficit one hour earlier (h4983 = 235 MW) and reducing intensity at the end
  of the main event (h4988: 535 MW vs 770 MW ED).  Both modes produce
  identical total EUE over the displayed window.

Notes:
  - Emergency-only storage MCS produces an identical load-shedding profile to
    Full-year ED per scenario (confirmed in paper); both are represented by
    the ED-mode bars.
  - Event-window storage MCS hourly dispatch is not available in committed
    result CSVs; it is therefore not shown.
  - Storage SOC and discharge are not output by the PCM model; only load
    shedding is shown.

Outputs (figures/):
  event_operation_comparison.pdf
  event_operation_comparison.png
"""

import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RES  = os.path.join(REPO, "results")
FIG  = os.path.join(REPO, "figures")
os.makedirs(FIG, exist_ok=True)

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
    "savefig.dpi":        300,
    "savefig.bbox":       "tight",
    "savefig.pad_inches": 0.05,
    "pdf.fonttype":       42,
    "ps.fonttype":        42,
})

C_ED = "#1565C0"    # Full-year ED / Emergency-only MCS
C_UC = "#6A1B9A"    # PCM-UCED

# ─────────────────────────────────────────────────────────────────────────────
# Load data
# ─────────────────────────────────────────────────────────────────────────────

df = pd.read_csv(os.path.join(RES, "hope_n20_pilot", "hope_load_shed_hourly.csv"))
df["scen"] = df["case_folder"].str.extract(r"_s(\d+)_")[0].astype(int)

# Selected scenario and event window
SCEN      = 15
H_EVT_START = 4984   # start of main ED event
H_EVT_END   = 4988   # end of main ED event
PAD_BEFORE  = 8      # display hours before event start
PAD_AFTER   = 8      # display hours after event end

h_window = list(range(H_EVT_START - PAD_BEFORE, H_EVT_END + PAD_AFTER + 1))

ed_raw = (df[(df["scen"] == SCEN) & (df["mode"] == "ED")]
          .set_index("hour")["load_shed_mw"]
          .reindex(h_window, fill_value=0.0))

uc_raw = (df[(df["scen"] == SCEN) & (df["mode"] == "UC")]
          .set_index("hour")["load_shed_mw"]
          .reindex(h_window, fill_value=0.0))

# Relative hours (0 = event start)
rel_hours = [h - H_EVT_START for h in h_window]

# ─────────────────────────────────────────────────────────────────────────────
# Verify EUE balance
# ─────────────────────────────────────────────────────────────────────────────

ed_eue = ed_raw.sum()
uc_eue = uc_raw.sum()
print(f"Window EUE — ED: {ed_eue:.1f} MWh,  UC: {uc_eue:.1f} MWh")
assert abs(ed_eue - uc_eue) < 1.0, "EUE mismatch in selected window"

# ─────────────────────────────────────────────────────────────────────────────
# Figure
# ─────────────────────────────────────────────────────────────────────────────

fig, ax = plt.subplots(figsize=(6.0, 3.2))

x = np.arange(len(h_window))
width = 0.38

bars_ed = ax.bar(x - width / 2, ed_raw.values, width,
                 color=C_ED, alpha=0.82, edgecolor="white", linewidth=0.4,
                 label="Full-year ED / Emergency-only storage MCS")
bars_uc = ax.bar(x + width / 2, uc_raw.values, width,
                 color=C_UC, alpha=0.82, edgecolor="white", linewidth=0.4,
                 label="PCM-UCED")

# Shade the main event window (rel_hours 0 to 4, i.e. index PAD_BEFORE to PAD_BEFORE+4)
evt_start_idx = PAD_BEFORE - 0.5
evt_end_idx   = PAD_BEFORE + (H_EVT_END - H_EVT_START) + 0.5
ax.axvspan(evt_start_idx, evt_end_idx,
           color="#EEEEEE", zorder=0, label="_event window")
ax.text((evt_start_idx + evt_end_idx) / 2,
        max(ed_raw.max(), uc_raw.max()) * 0.96,
        "Main event window\n(Full-year ED / M1c)",
        ha="center", va="top", fontsize=6.5, color="#555555",
        style="italic")

# Mark the UC-only hour (h4983, rel=-1) with an annotation
uc_extra_idx = PAD_BEFORE - 1  # rel hour -1
ax.annotate(
    "UC sheds here;\nED = 0",
    xy=(uc_extra_idx + width / 2, uc_raw.values[uc_extra_idx]),
    xytext=(uc_extra_idx - 1.2, uc_raw.values[uc_extra_idx] + 180),
    fontsize=6.0, color=C_UC,
    ha="center", va="bottom",
    arrowprops=dict(arrowstyle="->", color=C_UC, lw=0.7),
)

# X-axis: relative hours, label every 2nd tick
ax.set_xticks(x)
ax.set_xticklabels(
    [f"{r:+d}" if r != 0 else "0\n(event\nstart)" for r in rel_hours],
    fontsize=6.5
)
ax.set_xlabel("Hour (relative to event start)")
ax.set_ylabel("Load shedding (MW)")
ax.set_title("Representative shortage-event operation — Balanced VRE portfolio",
             fontsize=8.8, fontweight="bold")
ax.set_ylim(0, max(ed_raw.max(), uc_raw.max()) * 1.28)

# EUE annotation (total EUE is identical)
ax.text(0.99, 0.98,
        f"Total EUE in window:\n{ed_eue:,.0f} MWh (identical for both methods)",
        transform=ax.transAxes, fontsize=6.0, color="#333333",
        ha="right", va="top",
        bbox=dict(boxstyle="round,pad=0.22", facecolor="#F5F5F5",
                  edgecolor="#cccccc", lw=0.7))

ax.legend(loc="upper left", fontsize=7.0)
ax.grid(axis="y", alpha=0.20)
ax.set_axisbelow(True)
fig.tight_layout()

for ext in ("pdf", "png"):
    out = os.path.join(FIG, f"event_operation_comparison.{ext}")
    fig.savefig(out, format=ext)
    print(f"  event_operation_comparison.{ext}")
plt.close(fig)

print("\nDone.  Scenario 15, main event hours 4984-4988.")
print(f"ED EUE in window: {ed_eue:.1f} MWh  |  UC EUE in window: {uc_eue:.1f} MWh")
