#!/usr/bin/env python3
"""
62_build_main_comparison_and_dashboard.py

Build comprehensive method-comparison CSV and event-shape dashboard figure.

Inputs (from results/paper_tables/):
  paper_storage_method_comparison.csv  — LOLH, EUE, CVaR-EUE, runtime (N=20 all methods)
  paper_hope_validation.csv            — M1c/M2/M3/PCM-UCED at N=5 for wind-heavy
  marginal_cc_all_methods_rerun.csv    — CC for M1/M1b/M1c/M2 (from script 61)
  marginal_cc_model_rerun_validation.csv — CC for M3 / HOPE-PCM-ED (from script 59)
  event_shape_summary.csv              — event-shape metrics

Outputs:
  results/paper_tables/main_method_comparison_with_runtime_cc.csv
  figures/event_shape_dashboard.pdf / .png
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

# ─────────────────────────────────────────────────────────────────────────────
# Load source CSVs
# ─────────────────────────────────────────────────────────────────────────────

def load(fname):
    p = os.path.join(TAB, fname)
    if not os.path.exists(p):
        print(f"  [MISSING] {fname} — skipping")
        return None
    return pd.read_csv(p)

df_mcs  = load("paper_storage_method_comparison.csv")    # N=20 all methods
df_hope = load("paper_hope_validation.csv")              # N=20 wind-heavy + N=20 balanced
df_cc61 = load("marginal_cc_all_methods_rerun.csv")      # script 61 (M1/M1b/M1c/M2)
df_cc59 = load("marginal_cc_model_rerun_validation.csv") # script 59 (M3/HOPE)
df_es   = load("event_shape_summary.csv")                # event shape

# NEUE: Balanced VRE peak=9830 MW, annual_load=2479/0.0000549≈45.16e6 MWh
# Easier: compute from known M1c EUE and NEUE ppm: NEUE=EUE/annual_load*1e6
# From main CSV: M1c balanced EUE=2479.17, NEUE=55 ppm → annual_load=2479.17/55*1e6=45,076,727 MWh
ANNUAL_LOAD_BASE   = 2479.17 / 55.0 * 1e6    # ~45.1 million MWh (balanced VRE, scaled load)
ANNUAL_LOAD_WIND   = ANNUAL_LOAD_BASE             # same load profile; N=20 M1c: 648.24/14.38=45.08e6

# ─────────────────────────────────────────────────────────────────────────────
# Part 1: Build comprehensive CSV
# ─────────────────────────────────────────────────────────────────────────────

print("=" * 70)
print("Part 1: Building main_method_comparison_with_runtime_cc.csv")
print("=" * 70)

# --- CC lookup from scripts 59 + 61 ---
cc_lookup = {}   # (case_key, model_internal) -> cc_rerun

if df_cc61 is not None:
    for _, r in df_cc61[df_cc61["delta_mw"] == 1.0].iterrows():
        key = (r["case"], r["model_internal"])
        cc_lookup[key] = r["normalized_marginal_cc_rerun"]

if df_cc59 is not None:
    for _, r in df_cc59[df_cc59["delta_mw"] == 1.0].iterrows():
        key_m3 = (r["case"], "M3") if r["model"] == "Full-year ED (M3)" else None
        if key_m3:
            cc_lookup[key_m3] = r["normalized_marginal_cc_rerun"]

def get_cc(case, model_int):
    return cc_lookup.get((case, model_int), float("nan"))

# --- Helper: round for display ---
def fmt_lolh(v):   return round(float(v), 2) if not pd.isna(v) else float("nan")
def fmt_eue(v):    return int(round(float(v))) if not pd.isna(v) else float("nan")
def fmt_neue(v):   return int(round(float(v))) if not pd.isna(v) else float("nan")
def fmt_rt(v):     return round(float(v), 2)   if not pd.isna(v) else float("nan")
def fmt_cc(v):     return round(float(v), 3)   if not pd.isna(v) else float("nan")

rows = []

# ------ Balanced VRE (N=20) — all MCS/ED methods ------
case_b = "VRE120_base"
label_b = "Balanced VRE (N=20)"

if df_mcs is not None:
    mcs_b = df_mcs[df_mcs["case"] == case_b].copy()
    for _, r in mcs_b.iterrows():
        mint  = r["model_internal"]
        eue   = r["eue_mwh"]
        neue  = eue / ANNUAL_LOAD_BASE * 1e6
        rows.append({
            "portfolio":       label_b,
            "method_label":    r["model_paper_name"],
            "model_internal":  mint,
            "n_scenarios":     int(r["n_scenarios"]),
            "lolh_h":          fmt_lolh(r["lolh"]),
            "eue_mwh":         fmt_eue(eue),
            "neue_ppm":        fmt_neue(neue),
            "cvar_eue_mwh":    fmt_eue(r["cvar_eue_mwh"]),
            "runtime_s":       fmt_rt(r["mean_runtime_s"]),
            "marginal_cc":     fmt_cc(get_cc(case_b, mint)),
        })

# PCM-UCED balanced (N=20 from paper_hope_validation.csv)
if df_hope is not None:
    uc_b = df_hope[(df_hope["case"] == case_b) &
                   (df_hope["model_internal"] == "HOPE-UC")].copy()
    for _, r in uc_b.iterrows():
        eue  = r["eue_mwh"]
        neue = eue / ANNUAL_LOAD_BASE * 1e6
        rows.append({
            "portfolio":       label_b,
            "method_label":    "PCM-UCED",
            "model_internal":  "HOPE-UC",
            "n_scenarios":     int(r["n_scenarios"]),
            "lolh_h":          fmt_lolh(r["lolh"]),
            "eue_mwh":         fmt_eue(eue),
            "neue_ppm":        fmt_neue(neue),
            "cvar_eue_mwh":    fmt_eue(r["cvar_eue_mwh"]),
            "runtime_s":       fmt_rt(r["mean_runtime_s"]),
            "marginal_cc":     float("nan"),   # not computed
        })

# ------ Wind-heavy VRE (N=20) — methods from paper_hope_validation.csv ------
case_w = "VRE120_wind_hvy"
label_w = "Wind-heavy VRE (N=20)"

if df_hope is not None:
    hope_w = df_hope[df_hope["case"] == case_w].copy()
    for _, r in hope_w.iterrows():
        mint = r["model_internal"]
        eue  = r["eue_mwh"]
        neue = eue / ANNUAL_LOAD_WIND * 1e6

        # Map HOPE internal name to paper label
        label_map = {
            "M1c":     "Emergency-only storage MCS",
            "M2":      "Event-window storage MCS",
            "M3":      "Full-year ED",
            "HOPE-ED": "PCM-ED (cross-check)",
            "HOPE-UC": "PCM-UCED",
        }
        paper_label = label_map.get(mint, mint)

        # Get CC from script 61 (N=5 wind-heavy) or script 59 (M3)
        cc_key = (case_w, mint)
        cc = get_cc(case_w, "M3") if mint == "M3" else get_cc(case_w, mint)
        if mint in ("HOPE-ED", "HOPE-UC"):
            cc = float("nan")

        rows.append({
            "portfolio":       label_w,
            "method_label":    paper_label,
            "model_internal":  mint,
            "n_scenarios":     int(r["n_scenarios"]),
            "lolh_h":          fmt_lolh(r["lolh"]),
            "eue_mwh":         fmt_eue(eue),
            "neue_ppm":        fmt_neue(neue),
            "cvar_eue_mwh":    fmt_eue(r["cvar_eue_mwh"]),
            "runtime_s":       fmt_rt(r["mean_runtime_s"]),
            "marginal_cc":     fmt_cc(cc),
        })

df_out = pd.DataFrame(rows)
out_csv = os.path.join(TAB, "main_method_comparison_with_runtime_cc.csv")
df_out.to_csv(out_csv, index=False)
print(f"Saved: {out_csv}")
print(df_out.to_string(index=False))

# ─────────────────────────────────────────────────────────────────────────────
# Part 2: Event-shape dashboard figure
# ─────────────────────────────────────────────────────────────────────────────

print("\n" + "=" * 70)
print("Part 2: Event-shape dashboard figure")
print("=" * 70)

if df_es is None:
    print("event_shape_summary.csv not found — skipping figure")
else:
    # Balanced VRE (N=20), normalize to Full-year ED
    es_b = df_es[df_es["case"].str.contains("Balanced")].copy()
    print(es_b.to_string(index=False))

    # Reference: Full-year ED row
    ref = es_b[es_b["method"] == "Full-year ED"].iloc[0]

    # Methods and their display order
    METHOD_ORDER = [
        ("Emergency-only storage MCS", "Emergency-only\nMCS"),
        ("Event-window storage MCS",   "Event-window\nMCS"),
        ("Full-year ED",               "Full-year ED\n(reference)"),
        ("PCM-UCED",                   "PCM-UCED"),
    ]

    METRICS = [
        ("events_per_yr",          "Events per year"),
        ("mean_event_duration_h",  "Mean event duration (h)"),
        ("max_hourly_shortfall_mw","Max hourly shortfall (MW)"),
        ("max_event_duration_h",   "Max event duration (h)"),
    ]

    # Collect normalized values
    method_labels = [m[1] for m in METHOD_ORDER]
    data = {}   # metric_key -> array indexed by method
    for mk, _ in METRICS:
        ref_val = float(ref[mk])
        vals = []
        for mname, _ in METHOD_ORDER:
            row_m = es_b[es_b["method"] == mname]
            if row_m.empty:
                vals.append(float("nan"))
            else:
                v = float(row_m.iloc[0][mk])
                vals.append(v / ref_val if ref_val > 0 else float("nan"))
        data[mk] = np.array(vals)

    # Colours per method
    C_M1c  = "#2E7D32"   # green
    C_M2   = "#1565C0"   # blue
    C_M3   = "#555555"   # grey (reference)
    C_PCM  = "#C62828"   # red

    METHOD_COLORS = [C_M1c, C_M2, C_M3, C_PCM]
    N_METHODS = len(METHOD_ORDER)
    N_METRICS = len(METRICS)

    # Layout: one panel per metric, methods on x-axis
    fig, axes = plt.subplots(1, N_METRICS, figsize=(7.5, 2.6), sharey=False)

    BAR_W = 0.55
    x     = np.array([0])   # single group per panel

    for ax, (mk, mlabel) in zip(axes, METRICS):
        vals = data[mk]
        for i, (color, val) in enumerate(zip(METHOD_COLORS, vals)):
            if np.isnan(val):
                continue
            xpos = i * 0.8
            bar = ax.bar(xpos, val, BAR_W, color=color, alpha=0.85,
                         edgecolor="#333333", linewidth=0.5, zorder=3)
            ax.text(xpos, val + 0.02, f"{val:.2f}", ha="center", va="bottom",
                    fontsize=5.8, color="#222222")

        ax.axhline(1.0, color="#888888", lw=0.9, ls="--", zorder=2, alpha=0.8)
        ax.set_xticks([i * 0.8 for i in range(N_METHODS)])
        ax.set_xticklabels(method_labels, fontsize=6.0)
        ax.set_ylabel("Ratio relative to Full-year ED", fontsize=7.0)
        ax.set_title(mlabel, fontsize=7.5, pad=3)
        ax.set_ylim(bottom=0)
        ax.grid(axis="y", alpha=0.18, linewidth=0.5)
        ax.set_axisbelow(True)
        ax.tick_params(axis="x", length=0, pad=2)
        ax.yaxis.set_major_locator(mticker.MaxNLocator(nbins=4))

    # Legend
    handles = [
        Patch(facecolor=C_M1c, alpha=0.85, edgecolor="#333333", lw=0.5,
              label="Emergency-only storage MCS"),
        Patch(facecolor=C_M2,  alpha=0.85, edgecolor="#333333", lw=0.5,
              label="Event-window storage MCS"),
        Patch(facecolor=C_M3,  alpha=0.85, edgecolor="#333333", lw=0.5,
              label="Full-year ED (reference)"),
        Patch(facecolor=C_PCM, alpha=0.85, edgecolor="#333333", lw=0.5,
              label="PCM-UCED"),
    ]
    fig.legend(handles=handles, loc="lower center", ncol=4, fontsize=6.5,
               borderpad=0.4, labelspacing=0.3, handlelength=1.2,
               handletextpad=0.3, framealpha=0.92,
               bbox_to_anchor=(0.5, -0.04))

    plt.tight_layout(rect=[0, 0.09, 1, 1], w_pad=1.4)

    for ext in ("pdf", "png"):
        out = os.path.join(FIG_DIR, f"event_shape_dashboard.{ext}")
        fig.savefig(out, format=ext)
        print(f"Saved: {out}")
    plt.close(fig)

print("\nDone.")
