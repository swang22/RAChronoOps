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

df_mcs       = load("paper_storage_method_comparison.csv")    # N=20 all methods
df_hope      = load("paper_hope_validation.csv")              # N=20 wind-heavy + N=20 balanced
df_cc61      = load("marginal_cc_all_methods_rerun.csv")      # script 61 (M1/M1b/M1c/M2, wind-heavy N=5)
df_cc59      = load("marginal_cc_model_rerun_validation.csv") # script 59 (M3/HOPE, wind-heavy N=5)
df_cc64      = load("marginal_cc_all_methods_n20.csv")        # script 64 (all methods, wind-heavy N=20)
df_pcm_uced  = load("pcm_uced_marginal_cc.csv")               # scripts 63/64 (PCM-UCED fixed-UC)
df_es        = load("event_shape_summary.csv")                # event shape

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

# --- CC lookup from scripts 59 + 61 (N=5 wind-heavy baseline) ---
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

# Override wind-heavy entries with N=20 values from script 64 (if available)
if df_cc64 is not None:
    for _, r in df_cc64[df_cc64["delta_mw"] == 1.0].iterrows():
        key = (r["case"], r["model_internal"])
        cc_lookup[key] = r["normalized_marginal_cc_rerun"]

# --- PCM-UCED CC from fixed-UC LP (scripts 63/64) ---
# For each case, prefer the highest-N row (N=20 over N=5).
pcm_uced_cc = {}   # case_key -> normalized_marginal_cc
if df_pcm_uced is not None:
    df1mw = df_pcm_uced[df_pcm_uced["delta_mw"] == 1.0].copy()
    for case_k, grp in df1mw.groupby("case"):
        best = grp.sort_values("n_scen", ascending=False).iloc[0]
        pcm_uced_cc[case_k] = best["normalized_marginal_cc"]

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
            "marginal_cc":     fmt_cc(pcm_uced_cc.get(case_b, float("nan"))),
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

        # Get CC from cc_lookup (N=20 wind-heavy from script 64, or N=5 fallback)
        cc = get_cc(case_w, "M3") if mint == "M3" else get_cc(case_w, mint)
        if mint == "HOPE-ED":
            cc = float("nan")   # not computed
        elif mint == "HOPE-UC":
            cc = pcm_uced_cc.get(case_w, float("nan"))

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
    # Balanced VRE (N=20), normalize to PCM-UCED
    es_b = df_es[df_es["case"].str.contains("Balanced")].copy()
    print(es_b.to_string(index=False))

    # Reference: PCM-UCED (operational benchmark)
    ref = es_b[es_b["method"] == "PCM-UCED"].iloc[0]

    # Methods and their display order
    METHOD_ORDER = [
        ("Emergency-only storage MCS", "Emergency-only\nMCS"),
        ("Event-window storage MCS",   "Event-window\nMCS"),
        ("Full-year ED",               "Full-year ED"),
        ("PCM-UCED",                   "PCM-UCED\n(benchmark)"),
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

    # Colours and markers per method — consistent with METHOD_STYLE in script 45
    C_M1c  = "#388E3C"   # green
    C_M2   = "#1565C0"   # blue
    C_M3   = "#555555"   # dark gray
    C_PCM  = "#6A1B9A"   # purple

    METRIC_LABELS = ["Events/yr", "Mean dur.", "Max shortfall", "Max dur."]
    METRIC_KEYS   = [
        "events_per_yr",
        "mean_event_duration_h",
        "max_hourly_shortfall_mw",
        "max_event_duration_h",
    ]
    # (method_csv_name, legend_label, color, marker, markersize, y_jitter)
    METHOD_PLOT = [
        ("Emergency-only storage MCS", "Emergency",    C_M1c, "o",  42, +0.15),
        ("Event-window storage MCS",   "Event-window", C_M2,  "D",  42, +0.05),
        ("Full-year ED",               "Full-year ED", C_M3,  "^",  46, -0.05),
        ("PCM-UCED",                   "PCM-UCED",     C_PCM, "P",  50, -0.15),
    ]

    n_metrics = len(METRIC_KEYS)
    y_base    = np.arange(n_metrics)   # 0=Events/yr, 1=Mean dur., etc.

    fig, ax = plt.subplots(figsize=(4.2, 2.6))

    # Vertical dashed reference at ratio=1
    ax.axvline(1.0, color="#888888", lw=0.9, ls="--", zorder=1, alpha=0.7)

    for method_name, label, color, marker, ms, y_jitter in METHOD_PLOT:
        row_m = es_b[es_b["method"] == method_name]
        if row_m.empty:
            continue
        row_data = row_m.iloc[0]
        xs, ys = [], []
        for yi, mk in enumerate(METRIC_KEYS):
            ref_val = float(ref[mk])
            v = float(row_data[mk])
            xs.append(v / ref_val if ref_val > 0 else float("nan"))
            ys.append(yi + y_jitter)
        ax.scatter(xs, ys, color=color, marker=marker, s=ms, zorder=5,
                   label=label, edgecolors="white", linewidths=0.5)

    ax.set_yticks(y_base)
    ax.set_yticklabels(METRIC_LABELS, fontsize=7.5)
    ax.set_xlabel("Ratio relative to PCM-UCED", fontsize=8)
    ax.set_xlim(0, 2.0)
    ax.set_ylim(-0.5, n_metrics - 0.5)
    ax.legend(loc="lower right", fontsize=6.5, markerscale=0.85,
              handlelength=0.9, handletextpad=0.4, framealpha=0.9, borderpad=0.4)
    ax.grid(axis="x", alpha=0.20, linewidth=0.5)
    ax.set_axisbelow(True)
    fig.tight_layout()

    for ext in ("pdf", "png"):
        out = os.path.join(FIG_DIR, f"event_shape_dashboard.{ext}")
        fig.savefig(out, format=ext)
        print(f"Saved: {out}")
    plt.close(fig)

print("\nDone.")
