#!/usr/bin/env python3
"""
45_make_paper_figures.py

Paper-ready figures for the storage-aware sequential MCS manuscript.

Reads committed result CSVs only.  Does not re-run experiments.

Outputs (figures/):
  method_hierarchy.pdf/.png           — Figure 1: method flow diagram
  eue_by_method.pdf/.png              — Figure 2: EUE by dispatch method (two panels)
  runtime_accuracy_frontier.pdf/.png  — Figure 3: accuracy-runtime frontier
  event_shape_comparison.pdf/.png     — Figure 4: event-shape comparison (new, main text)
  sampling_convergence.pdf/.png       — Appendix: MC sampling convergence
  robustness_eue_error.pdf/.png       — Appendix: robustness sweep EUE
  figure_captions.md                  — LaTeX-ready captions

Usage:
  python scripts/45_make_paper_figures.py
"""

import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.ticker as ticker
from matplotlib.patches import FancyBboxPatch

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RES  = os.path.join(REPO, "results")
FIG  = os.path.join(REPO, "figures")
os.makedirs(FIG, exist_ok=True)

# ─────────────────────────────────────────────────────────────────────────────
# Global style
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

# Colour palette
C = {
    "gray":    "#9E9E9E",
    "dgray":   "#555555",   # dark gray — Full-year ED
    "red":     "#C62828",
    "orange":  "#EF6C00",
    "green":   "#388E3C",
    "blue":    "#1565C0",
    "sky":     "#1E88E5",
    "purple":  "#6A1B9A",
    "lgray":   "#EEEEEE",
    "lgreen":  "#E8F5E9",
    "lblue":   "#E3F2FD",
    "lred":    "#FFEBEE",
}

# Per-method marker/colour — consistent across all figures
# Naive: red X | SOC-floor: orange sq | Emergency: green circle
# Event-window: blue diamond | Full-year ED: dark-gray triangle | PCM-UCED: purple +
METHOD_STYLE = {
    "M1":      dict(color=C["red"],    marker="X",  ms=7),
    "M1b":     dict(color=C["orange"], marker="s",  ms=6),
    "M1c":     dict(color=C["green"],  marker="o",  ms=6),
    "M2":      dict(color=C["blue"],   marker="D",  ms=6),
    "M3":      dict(color=C["dgray"],  marker="^",  ms=7),
    "HOPE-ED": dict(color="#7B1FA2",   marker="v",  ms=6),
    "HOPE-UC": dict(color=C["purple"], marker="P",  ms=7),
}

def save_fig(fig, stem):
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(FIG, f"{stem}.{ext}"), format=ext)
    print(f"    {stem}.pdf / .png")
    plt.close(fig)


# ─────────────────────────────────────────────────────────────────────────────
# Figure 1 — Method hierarchy diagram  (unchanged)
# ─────────────────────────────────────────────────────────────────────────────

def make_fig1():
    """Vertical flow diagram of the methodological ladder."""
    fig = plt.figure(figsize=(4.2, 6.8), facecolor="white")
    ax  = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    rows = [
        (0.935, "Capacity-Balance MCS",
                "Classical hourly capacity check · no storage",
                C["gray"],   "#F5F5F5", "Baseline"),
        (0.795, "Naive Storage MCS",
                "Naive peak-shaving heuristic · proactive discharge",
                C["red"],    "#FFEBEE", "[FAIL] Biased high"),
        (0.655, "SOC-Floor Storage MCS",
                "Reserve-aware heuristic · SOC floor on proactive P",
                C["orange"], "#FFF3E0", "[FAIL] Partially corrected"),
        (0.515, "Emergency-Only Storage MCS",
                "Surplus charging · discharge only at shortfall",
                C["green"],  "#E8F5E9", "[PASS] Matches EUE"),
        (0.375, "Event-Window Storage MCS",
                "LP solved around screened scarcity windows",
                C["sky"],    "#E3F2FD", "[PASS] Matches EUE & LOLH"),
        (0.235, "Full-Year ED",
                "Full-year economic dispatch LP · Gurobi · benchmark",
                C["blue"],   "#E8EAF6", "LP reference"),
        (0.095, "PCM-UCED",
                "Full-year unit commitment MILP · validation only",
                C["purple"], "#F3E5F5", "PCM validation"),
    ]

    BOX_H  = 0.098
    BOX_X0 = 0.05
    BOX_W  = 0.82

    for i, (yc, title, sub, ecol, fcol, badge) in enumerate(rows):
        y0 = yc - BOX_H / 2
        rect = FancyBboxPatch(
            (BOX_X0, y0), BOX_W, BOX_H,
            boxstyle="round,pad=0.012",
            linewidth=1.1,
            edgecolor=ecol,
            facecolor=fcol,
            zorder=2,
            transform=ax.transAxes,
            clip_on=False,
        )
        ax.add_patch(rect)
        ax.text(BOX_X0 + 0.018, yc + 0.016, title,
                transform=ax.transAxes,
                fontsize=8.2, fontweight="bold", color="#1a1a1a",
                ha="left", va="center", zorder=3)
        ax.text(BOX_X0 + 0.018, yc - 0.020, sub,
                transform=ax.transAxes,
                fontsize=6.8, color="#555555",
                ha="left", va="center", zorder=3)
        ax.text(BOX_X0 + BOX_W - 0.012, yc, badge,
                transform=ax.transAxes,
                fontsize=7.0, fontweight="bold", color=ecol,
                ha="right", va="center", zorder=3)
        if i < len(rows) - 1:
            next_yc = rows[i + 1][0]
            y_top = yc - BOX_H / 2 - 0.005
            y_bot = next_yc + BOX_H / 2 + 0.005
            ax.annotate(
                "", xytext=(0.46, y_top), xy=(0.46, y_bot),
                xycoords="axes fraction",
                arrowprops=dict(arrowstyle="->,head_width=0.018,head_length=0.010",
                                color="#888888", lw=0.9),
                zorder=1,
            )

    ax.annotate(
        "", xytext=(0.94, 0.88), xy=(0.94, 0.14),
        xycoords="axes fraction",
        arrowprops=dict(arrowstyle="->,head_width=0.014,head_length=0.008",
                        color="#bbbbbb", lw=1.0),
    )
    ax.text(0.975, 0.51, "Increasing computational cost",
            transform=ax.transAxes,
            fontsize=6.2, color="#aaaaaa", rotation=270,
            ha="center", va="center")
    ax.set_title("Method hierarchy", fontsize=9.5, fontweight="bold",
                 pad=4, y=1.005, transform=ax.transAxes, ha="center")
    save_fig(fig, "method_hierarchy")


# ─────────────────────────────────────────────────────────────────────────────
# Figure 2 — EUE by method  (revised: two panels, emphasis on accuracy)
# ─────────────────────────────────────────────────────────────────────────────

def make_fig2():
    """Two-panel bar chart: EUE by dispatch method, one panel per VRE portfolio."""
    df = pd.read_csv(os.path.join(RES, "paper_tables",
                                   "paper_storage_method_comparison.csv"))

    order_int = ["M1", "M1b", "M1c", "M2", "M3"]
    x_labels  = {
        "M1":  "Naive\nStorage MCS",
        "M1b": "SOC-Floor\nStorage MCS",
        "M1c": "Emergency-Only\nStorage MCS",
        "M2":  "Event-Window\nStorage MCS",
        "M3":  "Full-Year ED",
    }
    bar_colors = {
        "M1":  C["red"],
        "M1b": C["orange"],
        "M1c": C["green"],
        "M2":  C["sky"],
        "M3":  C["blue"],
    }

    panels = [
        ("VRE120_base",     "(a) Balanced VRE"),
        ("VRE120_wind_hvy", "(b) Wind-Heavy VRE"),
    ]

    df = df[df["model_internal"].isin(order_int)].copy()
    x = np.arange(len(order_int))

    fig, axes = plt.subplots(1, 2, figsize=(6.8, 3.4))

    for ax, (case_key, panel_title) in zip(axes, panels):
        sub = df[df["case"] == case_key].set_index("model_internal")
        vals   = [sub.loc[m, "eue_mwh"] if m in sub.index else np.nan
                  for m in order_int]
        colors = [bar_colors[m] for m in order_int]

        ax.bar(x, vals, 0.60, color=colors, alpha=0.82,
               edgecolor="white", linewidth=0.5)

        # Full-Year ED reference dashed line
        m3_val = sub.loc["M3", "eue_mwh"] if "M3" in sub.index else None
        if m3_val is not None:
            ax.axhline(m3_val, color=C["blue"], ls="--", lw=1.1,
                       alpha=0.70, zorder=3)
            # Label at right edge, just above the reference line
            ax.text(len(order_int) - 0.30, m3_val * 1.35,
                    "Full-Year ED", fontsize=6.0, color=C["blue"],
                    ha="right", va="bottom", style="italic")

        ax.set_xticks(x)
        ax.set_xticklabels([x_labels[m] for m in order_int], fontsize=6.3)
        ax.set_ylabel("EUE (MWh/yr)" if ax is axes[0] else "")
        ax.set_yscale("log")
        ax.yaxis.set_major_formatter(
            ticker.FuncFormatter(lambda v, _: f"{v:,.0f}"))
        ax.set_title(panel_title, fontsize=8.8, fontweight="bold")
        ax.grid(axis="y", alpha=0.22)
        ax.set_axisbelow(True)

    fig.suptitle("EUE by storage dispatch method ($N = 20$, common random numbers)",
                 fontsize=8.8, fontweight="bold", y=1.01)
    fig.tight_layout(w_pad=2.0)
    save_fig(fig, "eue_by_method")


# ─────────────────────────────────────────────────────────────────────────────
# Figure 3 — Runtime vs EUE error frontier  (revised: legend upper-right)
# ─────────────────────────────────────────────────────────────────────────────

def make_fig3():
    """Log-log scatter: per-scenario runtime vs absolute EUE error vs PCM-UCED."""
    df   = pd.read_csv(os.path.join(RES, "paper_tables", "paper_runtime_accuracy.csv"))
    df_b = df[df["case"] == "VRE120_base"].copy()

    include = ["M1", "M1b", "M1c", "M2", "M3", "HOPE-UC"]
    df_b = df_b[df_b["model_internal"].isin(include)].copy()

    # For balanced VRE, PCM-UCED EUE == Full-year ED EUE, so abs_eue_error_mwh (vs M3)
    # equals the error vs PCM-UCED for all methods; HOPE-UC self-error is 0.
    eue_map = {row["model_internal"]: row["abs_eue_error_mwh"] for _, row in df_b.iterrows()}

    FLOOR = 0.05   # MWh floor for zero-error methods on log axis

    label_map = {
        "M1":      "Naive",
        "M1b":     "SOC-floor",
        "M1c":     "Emergency",
        "M2":      "Event-window",
        "M3":      "Full-year ED",
        "HOPE-UC": "PCM-UCED",
    }

    # Smaller, lighter markers for cautionary heuristics
    style_override = {
        "M1":  dict(color=C["red"],    marker="X",  s=38, alpha=0.65),
        "M1b": dict(color=C["orange"], marker="s",  s=30, alpha=0.65),
    }

    rows = []
    for _, row in df_b.iterrows():
        mid = row["model_internal"]
        rt  = row["mean_runtime_s"]
        err = eue_map[mid]
        rows.append(dict(mid=mid, rt=rt, err=err, err_plot=max(err, FLOOR)))

    fig, ax = plt.subplots(figsize=(4.5, 3.3))

    for r in rows:
        mid = r["mid"]
        lbl = label_map.get(mid, mid)
        if mid in style_override:
            st = style_override[mid]
            ax.scatter(r["rt"], r["err_plot"],
                       color=st["color"], marker=st["marker"], s=st["s"],
                       alpha=st["alpha"], zorder=5, label=lbl, clip_on=False)
        else:
            st = METHOD_STYLE.get(mid, dict(color="gray", marker="o", ms=6))
            ax.scatter(r["rt"], r["err_plot"],
                       color=st["color"], marker=st["marker"], s=st["ms"]**2,
                       zorder=5, label=lbl, clip_on=False)

    # Direct text labels using pixel-based offsets
    offsets = {
        # (dx_pts, dy_pts, va, ha)
        "M1":      (+12,   0, "center", "left"),    # right of X marker
        "M1b":     (  0, -14, "top",    "center"),  # below square marker
        "M1c":     (+6,  +10, "bottom", "left"),
        "M2":      (+6,   +9, "bottom", "left"),
        "M3":      (+6,   +9, "bottom", "left"),
        "HOPE-UC": (-8,  +10, "bottom", "right"),   # left to clear green annotation
    }
    for r in rows:
        mid = r["mid"]
        lbl = label_map.get(mid, mid)
        ox, oy, va, ha = offsets.get(mid, (6, 0, "center", "left"))
        st = style_override.get(mid, METHOD_STYLE.get(mid, dict(color="gray")))
        col = st["color"] if "color" in st else "gray"
        ax.annotate(
            lbl,
            xy=(r["rt"], r["err_plot"]),
            xytext=(ox, oy),
            textcoords="offset points",
            fontsize=6.5, color=col, va=va, ha=ha,
            arrowprops=dict(arrowstyle="-", color=col, lw=0.4,
                            shrinkA=2, shrinkB=0)
                    if (ox != 0 or oy != 0) else None,
        )

    # Zero-error floor line: green with label in upper-right empty area
    ax.axhline(FLOOR, color=C["green"], ls=":", lw=0.9, zorder=1, alpha=0.7)
    ax.text(0.97, 0.17,
            "zero EUE error\nvs PCM-UCED",
            transform=ax.transAxes, fontsize=6.0, color=C["green"],
            va="bottom", ha="right", style="italic")

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Runtime per scenario (s)")
    ax.set_ylabel("Absolute EUE error vs PCM-UCED (MWh)")
    ax.set_title("Accuracy–runtime comparison", fontsize=9, fontweight="bold")
    ax.grid(True, which="both", alpha=0.22)
    fig.tight_layout()
    save_fig(fig, "runtime_accuracy_frontier")


# ─────────────────────────────────────────────────────────────────────────────
# Figure 4 — Sampling convergence  (unchanged)
# ─────────────────────────────────────────────────────────────────────────────

def make_fig4():
    """Two-panel: (a) EUE + CI95 by N, (b) CI95 shrinkage and method errors."""
    agg = pd.read_csv(os.path.join(RES, "sampling_convergence",
                                    "convergence_aggregate_metrics.csv"))
    err = pd.read_csv(os.path.join(RES, "sampling_convergence",
                                    "convergence_errors_vs_full_ed.csv"))

    ns = sorted(agg["n_scenarios"].unique())

    def get_agg(model, col):
        return [agg[(agg["model"] == model) & (agg["n_scenarios"] == n)][col].values[0]
                for n in ns]

    m3_eue     = get_agg("M3",  "eue_mwh")
    m3_ci95    = get_agg("M3",  "eue_ci95_hw_mwh")
    m3_lolh_ci = get_agg("M3",  "lolh_ci95_hw")
    m1c_eue    = get_agg("M1c", "eue_mwh")
    m2_eue     = get_agg("M2",  "eue_mwh")

    m1c_err_abs = [abs(err[(err["model"] == "M1c") & (err["n_scenarios"] == n)]
                       ["eue_error_vs_full_ed"].values[0]) for n in ns]
    m2_err_abs  = [abs(err[(err["model"] == "M2")  & (err["n_scenarios"] == n)]
                       ["eue_error_vs_full_ed"].values[0]) for n in ns]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(6.8, 3.0))

    ax1.fill_between(
        ns,
        [m3_eue[i] - m3_ci95[i] for i in range(len(ns))],
        [m3_eue[i] + m3_ci95[i] for i in range(len(ns))],
        alpha=0.18, color=C["blue"], label="_CI95 band",
    )
    ax1.plot(ns, m3_eue, color=C["dgray"], marker="^", ms=6, lw=1.5,
             label="Full-Year ED")
    ax1.plot(ns, m1c_eue, color=C["green"], marker="o", ms=5.5, lw=1.4,
             ls="--", label="Emergency-Only Storage MCS")
    ax1.plot(ns, m2_eue,  color=C["blue"],  marker="D", ms=5.5, lw=1.4,
             ls=":",  label="Event-Window Storage MCS")

    ax1.set_xlabel("Monte Carlo scenarios (N)")
    ax1.set_ylabel("EUE (MWh/yr)")
    ax1.set_title("(a) EUE estimates with 95% CI", fontsize=8.5)
    ax1.legend(fontsize=6.5, loc="lower left")
    ax1.set_xticks(ns)
    ax1.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax1.text(0.98, 0.97,
             "All three methods\nproduce the same EUE",
             transform=ax1.transAxes, fontsize=6.5, color="#2E7D32",
             ha="right", va="top",
             bbox=dict(boxstyle="round,pad=0.2", facecolor=C["lgreen"],
                       edgecolor=C["green"], lw=0.7))

    ax2.plot(ns, m3_ci95, color=C["dgray"], marker="^", ms=6, lw=1.5,
             label="Full-Year ED EUE CI95 (MWh)")
    ax2.plot(ns, m3_lolh_ci, color=C["dgray"], marker="^", ms=6, lw=1.5,
             ls="--", alpha=0.6, label="Full-Year ED LOLH CI95 (h)")

    ns_arr   = np.array(ns, dtype=float)
    ref_eue  = m3_ci95[0] * np.sqrt(ns[0] / ns_arr)
    ax2.plot(ns, ref_eue, color=C["dgray"], lw=0.7, ls="-.", alpha=0.4,
             label="1/√N reference")

    ax2r = ax2.twinx()
    ax2r.set_ylabel("LOLH CI95 (h)", fontsize=8, color="#555555")
    ax2r.tick_params(labelsize=7, colors="#555555")
    ax2r.set_ylim(0, max(m3_lolh_ci) * 1.35)

    ax2.text(0.50, 0.22,
             "Method EUE error:\n0.0 MWh at all N",
             transform=ax2.transAxes, fontsize=7, color="#2E7D32",
             ha="center", va="bottom",
             bbox=dict(boxstyle="round,pad=0.25", facecolor=C["lgreen"],
                       edgecolor=C["green"], lw=0.8))

    ax2.set_xlabel("Monte Carlo scenarios (N)")
    ax2.set_ylabel("EUE CI95 half-width (MWh)", fontsize=8)
    ax2.set_title("(b) CI95 shrinkage with N", fontsize=8.5)
    ax2.legend(fontsize=6.5, loc="upper right")
    ax2.set_xticks(ns)
    ax2.set_ylim(0, max(m3_ci95) * 1.35)

    for ax in (ax1, ax2):
        ax.grid(alpha=0.22)
        ax.set_axisbelow(True)

    fig.tight_layout(w_pad=2.8)
    save_fig(fig, "sampling_convergence")


# ─────────────────────────────────────────────────────────────────────────────
# Figure 5 (appendix) — Robustness sweep EUE  (revised: no internal annotation)
# ─────────────────────────────────────────────────────────────────────────────

def make_fig5():
    """Bar chart: Full-Year ED EUE across storage robustness variants."""
    metrics  = pd.read_csv(os.path.join(RES, "storage_robustness_sweep", "metrics_all.csv"))

    m3_base = metrics[(metrics["model"] == "M3") &
                      (metrics["case"].str.startswith("VRE120_base_"))].copy()

    groups = {
        "A — Storage duration": [
            ("VRE120_base_dur2h",  "2 h"),
            ("VRE120_base_dur4h",  "4 h"),
            ("VRE120_base_dur8h",  "8 h"),
            ("VRE120_base_dur12h", "12 h"),
        ],
        "B — Storage power": [
            ("VRE120_base_pwr0p5x", "0.5×P"),
            ("VRE120_base_pwr1p0x", "1.0×P"),
            ("VRE120_base_pwr2p0x", "2.0×P"),
        ],
        "C — Load stress": [
            ("VRE120_base_ls1p225",          "LS 1.225\n(base stor)"),
            ("VRE120_base_ls1p25",           "LS 1.25\n(base stor)"),
            ("VRE120_base_dur2h_ls1p225",    "LS 1.225\n(2 h stor)"),
            ("VRE120_base_pwr0p5x_ls1p225",  "LS 1.225\n(0.5×P)"),
        ],
    }
    grp_colors = [C["blue"], C["orange"], C["green"]]

    ordered_cases  = []
    ordered_labels = []
    bar_colors     = []
    boundaries     = []
    x_pos = 0

    for gi, (gname, entries) in enumerate(groups.items()):
        x_start = x_pos
        for (cname, clabel) in entries:
            row = m3_base[m3_base["case"] == cname]
            if row.empty:
                continue
            ordered_cases.append(cname)
            ordered_labels.append(clabel)
            bar_colors.append(grp_colors[gi])
            x_pos += 1
        boundaries.append((x_start, x_pos - 1, gname, grp_colors[gi]))

    ordered_eue = [m3_base[m3_base["case"] == c]["mean_eue_mwh"].values[0]
                   for c in ordered_cases]
    xs = np.arange(len(ordered_cases))

    fig, ax = plt.subplots(figsize=(6.5, 3.4))
    ax.bar(xs, ordered_eue, color=bar_colors, alpha=0.80,
           edgecolor="white", linewidth=0.5, width=0.68)

    y_max = max(ordered_eue)
    for (x0, x1, gname, gcol) in boundaries:
        mid_x = (x0 + x1) / 2
        ax.text(mid_x, y_max * 1.08, f"Exp {gname}",
                ha="center", va="bottom", fontsize=7.0,
                fontweight="bold", color=gcol)
        if x0 > 0:
            ax.axvline(x0 - 0.5, color="#dddddd", lw=0.9, ls="--")

    ax.set_xticks(xs)
    ax.set_xticklabels(ordered_labels, fontsize=7.0)
    ax.set_ylabel("Full-Year ED EUE (MWh/yr)")
    ax.set_ylim(0, y_max * 1.28)
    ax.set_title("Robustness across storage variants (Balanced VRE, $N=20$)",
                 fontsize=9, fontweight="bold")
    ax.grid(axis="y", alpha=0.22)
    ax.set_axisbelow(True)
    fig.tight_layout()
    save_fig(fig, "robustness_eue_error")


# ─────────────────────────────────────────────────────────────────────────────
# Figure 6 — Event-shape comparison  (new, main text)
# ─────────────────────────────────────────────────────────────────────────────

def make_fig6():
    """Four-panel bar chart: event-shape metrics for storage-aware methods (balanced VRE)."""
    df = pd.read_csv(os.path.join(RES, "paper_tables", "event_shape_summary.csv"))

    # Balanced VRE portfolio, N=20
    bal = df[df["case"].str.startswith("Balanced")].copy()

    # Key storage-aware methods in display order (matches CSV method names exactly)
    METHODS = [
        ("Emergency-only storage MCS", "Emerg.-Only\nStorage MCS", C["green"]),
        ("Event-window storage MCS",   "Event-Window\nStorage MCS", C["blue"]),
        ("Full-year ED",               "Full-Year ED",               C["dgray"]),
        ("PCM-UCED",                   "PCM-UCED",                   C["purple"]),
    ]
    method_names  = [m[0] for m in METHODS]
    method_labels = [m[1] for m in METHODS]
    method_colors = [m[2] for m in METHODS]

    bal = bal[bal["method"].isin(method_names)].copy()
    # Enforce display order
    bal["_order"] = bal["method"].map({m: i for i, m in enumerate(method_names)})
    bal = bal.sort_values("_order").reset_index(drop=True)

    metrics = [
        ("events_per_yr",           "(a) Events per year",        "Events/yr"),
        ("mean_event_duration_h",   "(b) Mean event duration",    "Duration (h)"),
        ("max_event_duration_h",    "(c) Max event duration",     "Duration (h)"),
        ("max_hourly_shortfall_mw", "(d) Max shortfall",          "Shortfall (MW)"),
    ]

    fig, axes = plt.subplots(2, 2, figsize=(6.8, 4.0))
    axes_flat = axes.flatten()
    x = np.arange(len(METHODS))

    for ax, (col, title, ylabel) in zip(axes_flat, metrics):
        vals = bal[col].values
        ax.bar(x, vals, 0.58, color=method_colors, alpha=0.84,
               edgecolor="white", linewidth=0.5)
        ax.set_xticks(x)
        ax.set_xticklabels(method_labels, fontsize=6.1)
        ax.set_ylabel(ylabel, fontsize=7.5)
        ax.set_title(title, fontsize=8.2, fontweight="bold")
        # Value labels on top of each bar
        for xi, v in zip(x, vals):
            ax.text(xi, v * 1.03, f"{v:.1f}",
                    ha="center", va="bottom", fontsize=6.0, color="#333333")
        ax.grid(axis="y", alpha=0.20)
        ax.set_axisbelow(True)
        ymax = max(vals)
        ax.set_ylim(0, ymax * 1.30)

    fig.suptitle(
        "Event-shape metrics — Balanced VRE portfolio ($N = 20$)",
        fontsize=9, fontweight="bold",
    )
    fig.tight_layout()
    save_fig(fig, "event_shape_comparison")


# ─────────────────────────────────────────────────────────────────────────────
# Figure captions
# ─────────────────────────────────────────────────────────────────────────────

CAPTIONS = r"""# Figure Captions

---

**Figure 1 — Method hierarchy.**
Methodological ladder from the no-storage capacity-balance baseline to the
PCM unit-commitment benchmark.
Methods are ordered by increasing computational cost per Monte Carlo scenario
(from $<0.1$~s/scenario for heuristic methods to ${\sim}570$~s/scenario for
PCM-UCED).
\textit{Naive Storage MCS} and \textit{SOC-Floor Storage MCS} (\ding{55})
substantially overestimate reliability risk because proactive peak-shaving
discharge depletes storage state of charge before shortage events.
\textit{Emergency-Only Storage MCS} and \textit{Event-Window Storage MCS}
(\ding{51}) match the Full-Year ED EUE benchmark with ${\sim}150{\times}$
and ${\sim}22{\times}$ speedups, respectively.

---

**Figure 2 — EUE by storage dispatch method.**
Expected unserved energy (MWh/yr) for five storage dispatch methods,
$N=20$ Monte Carlo scenarios, seed~42, RTS-GMLC test system.
Panel~(a): balanced VRE portfolio; panel~(b): wind-heavy VRE portfolio.
All methods use common random numbers (identical outage sequences).
Dashed lines mark the Full-Year ED reference EUE in each panel.
\textit{Naive Storage MCS} and \textit{SOC-Floor Storage MCS} substantially
overestimate EUE because proactive discharge depletes storage before shortage events.
\textit{Emergency-Only Storage MCS}, \textit{Event-Window Storage MCS}, and
Full-Year ED produce identical EUE in both portfolios (bars reach the reference lines;
log scale).

---

**Figure 3 — Accuracy--runtime trade-off.**
Absolute EUE error relative to Full-Year ED as a function of per-scenario
computational runtime, balanced VRE portfolio, $N=20$, seed~42.
Methods with zero EUE error are shown at a floor of 0.05~MWh (annotated).
\textit{Emergency-Only Storage MCS} achieves zero EUE error at
${\sim}0.06$~s/scenario ($150{\times}$ faster than Full-Year ED at
${\sim}9.6$~s/scenario); \textit{Event-Window Storage MCS} achieves zero EUE
error at ${\sim}0.4$~s/scenario ($22{\times}$ faster).
PCM-UCED validates the EUE benchmark at ${\sim}570$~s/scenario.
Naive Storage MCS and SOC-Floor Storage MCS (lighter markers) are retained for
reference but are not part of the recommended frontier.

---

**Figure 4 — Event-shape metrics for storage-aware methods.**
Four event-shape statistics for the balanced VRE portfolio ($N=20$):
(a)~events per year, (b)~mean event duration, (c)~maximum event duration,
and (d)~maximum hourly shortfall.
All four methods produce identical EUE and NEUE (55~ppm); differences in
event-shape metrics reflect how the same total energy deficit is distributed
across shortage hours.
Emergency-Only Storage MCS and Full-Year ED agree on all event-shape statistics.
Event-Window Storage MCS produces more, shorter events (2.9 vs 2.0 events/yr,
mean duration 2.0 vs 3.0~h) because windowed LP optimization allocates the same
deficit differently.
PCM-UCED further fragments events (4.1 events/yr, 1.8~h mean) due to commitment
constraints, with a higher maximum shortfall.

---

**Appendix Figure 1 — Monte Carlo sampling convergence.**
(a) Expected unserved energy estimates with $95\%$ confidence interval
half-widths (shaded band and error bars on the Full-Year ED line) for $N =
20, 50, 100, 200$ scenarios.
Emergency-Only and Event-Window Storage MCS produce identical EUE to
Full-Year ED at every~$N$ (lines are coincident).
(b) Full-Year ED $95\%$ CI half-width as a function of~$N$ (EUE in solid
triangles, LOLH in dashed; right axis), with a $1/\sqrt{N}$ reference curve
(dash-dot).
Method EUE errors are $0.0$~MWh at all~$N$ (annotated); the figure confirms
that the EUE convergence result is not a small-sample artifact.

---

**Appendix Figure 2 — Robustness across storage variants (balanced VRE, $N=20$).**
Full-Year ED expected unserved energy for 11 storage robustness variants
grouped by stress dimension: Experiment~A (storage duration 2--12~h at fixed
power), Experiment~B (storage power $0.5{\times}$--$2{\times}$ at fixed 4~h
duration), and Experiment~C (load scaling 1.225--1.25 with two storage
configurations).
Emergency-Only and Event-Window Storage MCS match the Full-Year ED EUE exactly
($\Delta = 0.0$~MWh) across all 11 variants, including the most stressed case
(load scale~1.225, 2-h storage, sufficiency ratio~0.69).
"""

def write_captions():
    path = os.path.join(FIG, "figure_captions.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(CAPTIONS)
    print("    figure_captions.md")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("Generating paper figures ...")
    print("  [1] Method hierarchy")
    make_fig1()
    print("  [2] EUE by method (two panels)")
    make_fig2()
    print("  [3] Runtime-accuracy frontier")
    make_fig3()
    print("  [4] Event-shape comparison (new)")
    make_fig6()
    print("  [App-1] Sampling convergence")
    make_fig4()
    print("  [App-2] Robustness sweep EUE")
    make_fig5()
    print("  [captions] figure_captions.md")
    write_captions()
    print(f"\nOutput directory: {FIG}")
    for f in sorted(os.listdir(FIG)):
        fp = os.path.join(FIG, f)
        print(f"  {f:<45} {os.path.getsize(fp):>8,} bytes")
