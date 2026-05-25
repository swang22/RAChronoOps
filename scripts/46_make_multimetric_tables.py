#!/usr/bin/env python3
"""
46_make_multimetric_tables.py

Create two paper-ready CSVs aligned with multi-metric RA reporting:
  results/paper_tables/multimetric_main_results.csv
  results/paper_tables/event_shape_summary.csv

NEUE (ppm) = 1e6 * EUE_MWh / expected_annual_load_MWh
Annual load is back-computed from the existing neue_ppm column in
convergence_aggregate_metrics.csv (M3, N=20).
Load scale is 1.2 × base RTS-GMLC profile → ~45,073 GWh/yr.

Event-shape sources:
  Balanced VRE N=20 : full_model_comparison_with_hope/base_n20/all_model_aggregate_metrics.csv
  Wind-heavy VRE N=5: wind_hvy_hope_uc_comparison/n5/all_model_aggregate_metrics.csv
  PCM hourly (wind-heavy): hope_wind_hvy_n5_pilot/hope_load_shed_hourly.csv
    (used to supplement NaN max_duration / p95_duration for HOPE-ED and HOPE-UC)
"""

import pandas as pd
import numpy as np
from pathlib import Path

BASE = Path(r"d:\MIT Dropbox\Shen Wang\MIT\RA\RA_assessment\RAChronoOps")
RESULTS = BASE / "results"
PAPER_TABLES = RESULTS / "paper_tables"
PAPER_TABLES.mkdir(exist_ok=True)

# ─── Annual load ────────────────────────────────────────────────────────────
# Back-computed from M3, N=20 row in convergence_aggregate_metrics.
# Equals load_scale=1.2 × base RTS-GMLC average load (4,288 MW × 8,760 h).
conv_agg = pd.read_csv(
    RESULTS / "sampling_convergence" / "convergence_aggregate_metrics.csv"
)
_ref = conv_agg[(conv_agg["model"] == "M3") & (conv_agg["n_scenarios"] == 20)].iloc[0]
ANNUAL_LOAD_MWH = float(_ref["eue_mwh"]) / float(_ref["neue_ppm"]) * 1e6
print(f"Annual load: {ANNUAL_LOAD_MWH:,.0f} MWh/yr  "
      f"({ANNUAL_LOAD_MWH/1e6:.3f} TWh/yr, "
      f"{ANNUAL_LOAD_MWH/8760:.0f} MW average)")


def neue(eue_mwh: float) -> float:
    return round(float(eue_mwh) / ANNUAL_LOAD_MWH * 1e6, 2)


# ─── Labels ─────────────────────────────────────────────────────────────────
METHOD_LABEL = {
    "M1":               "Naive storage MCS",
    "M1b":              "SOC-floor storage MCS",
    "M1c":              "Emergency-only storage MCS",
    "M2":               "Event-window storage MCS",
    "M3":               "Full-year ED",
    "M3-NoStorage":     "Full-year ED",
    "MC-NoStorage":     "Capacity-balance MCS",
    "HOPE-ED":          "PCM-ED cross-check",
    "HOPE-UC":          "PCM-UCED",
    "HOPE-ED-NoStorage":"PCM-ED cross-check",
    "HOPE-UC-NoStorage":"PCM-UCED",
}

CASE_LABEL = {
    "VRE120_base":          "Balanced VRE portfolio",
    "VRE120_wind_hvy":      "Wind-heavy VRE portfolio",
    "VRE120_base_nostorage":"Balanced VRE, PCM check (no storage)",
}

# ═══════════════════════════════════════════════════════════════════════════
# 1.  multimetric_main_results.csv
# ═══════════════════════════════════════════════════════════════════════════

nostorage  = pd.read_csv(PAPER_TABLES / "paper_no_storage_validation.csv")
storage    = pd.read_csv(PAPER_TABLES / "paper_storage_method_comparison.csv")
hope_val   = pd.read_csv(PAPER_TABLES / "paper_hope_validation.csv")

rows = []

# No-storage validation (keep only paper-table methods)
KEEP_NS = {"MC-NoStorage", "M3-NoStorage", "HOPE-ED-NoStorage", "HOPE-UC-NoStorage"}
for _, r in nostorage.iterrows():
    m = r["model_internal"]
    if m not in KEEP_NS:
        continue
    rows.append({
        "section":              "No-storage validation",
        "case":                 CASE_LABEL.get(r["case"], r["case"]),
        "n_scenarios":          int(r["n_scenarios"]),
        "method":               METHOD_LABEL.get(m, m),
        "LOLH_h_per_yr":        round(float(r["lolh"]), 2),
        "EUE_MWh_per_yr":       round(float(r["eue_mwh"]), 2),
        "NEUE_ppm":             neue(r["eue_mwh"]),
        "CVaR_EUE_MWh":         round(float(r["cvar_eue_mwh"]), 2),
        "runtime_s_per_scenario": round(float(r["mean_runtime_s"]), 3),
    })

# Storage method comparison (key methods only)
KEEP_ST = {"M1", "M1b", "M1c", "M2", "M3"}
for _, r in storage.iterrows():
    m = r["model_internal"]
    if m not in KEEP_ST:
        continue
    rows.append({
        "section":              "Storage method comparison",
        "case":                 CASE_LABEL.get(r["case"], r["case"]),
        "n_scenarios":          int(r["n_scenarios"]),
        "method":               METHOD_LABEL.get(m, m),
        "LOLH_h_per_yr":        round(float(r["lolh"]), 2),
        "EUE_MWh_per_yr":       round(float(r["eue_mwh"]), 2),
        "NEUE_ppm":             neue(r["eue_mwh"]),
        "CVaR_EUE_MWh":         round(float(r["cvar_eue_mwh"]), 2),
        "runtime_s_per_scenario": round(float(r["mean_runtime_s"]), 3),
    })

# PCM validation
for _, r in hope_val.iterrows():
    m = r["model_internal"]
    rows.append({
        "section":              "PCM validation",
        "case":                 CASE_LABEL.get(r["case"], r["case"]),
        "n_scenarios":          int(r["n_scenarios"]),
        "method":               METHOD_LABEL.get(m, m),
        "LOLH_h_per_yr":        round(float(r["lolh"]), 2),
        "EUE_MWh_per_yr":       round(float(r["eue_mwh"]), 2),
        "NEUE_ppm":             neue(r["eue_mwh"]),
        "CVaR_EUE_MWh":         round(float(r["cvar_eue_mwh"]), 2),
        "runtime_s_per_scenario": round(float(r["mean_runtime_s"]), 3),
    })

multimetric = pd.DataFrame(rows, columns=[
    "section", "case", "n_scenarios", "method",
    "LOLH_h_per_yr", "EUE_MWh_per_yr", "NEUE_ppm", "CVaR_EUE_MWh",
    "runtime_s_per_scenario",
])
out1 = PAPER_TABLES / "multimetric_main_results.csv"
multimetric.to_csv(out1, index=False)
print(f"\n{'-'*70}")
print(f"multimetric_main_results.csv  ({len(multimetric)} rows)")
print(multimetric.to_string(index=False))

# ═══════════════════════════════════════════════════════════════════════════
# 2.  event_shape_summary.csv
# ═══════════════════════════════════════════════════════════════════════════

def pcm_event_shape(hourly_csv: Path, n_total: int) -> dict:
    """
    Compute event-shape metrics from a PCM hourly load-shedding CSV.
    Columns expected: case_folder, mode, hour, load_shed_mw.
    A shortage event is a maximal run of consecutive hours with load_shed > 0
    within a single scenario.  n_total = total MC scenarios (including zeros).
    Returns dict[mode_str] -> dict of metrics.
    """
    df = pd.read_csv(hourly_csv)
    df["scenario"] = df["case_folder"].str.extract(r"_(s\d+)_")[0]
    out = {}
    for mode, dfm in df.groupby("mode"):
        events = []
        for scen, dfs in dfm.groupby("scenario"):
            hours = sorted(dfs["hour"].tolist())
            loads = dict(zip(dfs["hour"], dfs["load_shed_mw"]))
            grp = [hours[0]]
            for h in hours[1:]:
                if h == grp[-1] + 1:
                    grp.append(h)
                else:
                    events.append(grp)
                    grp = [h]
            events.append(grp)
        if not events:
            out[mode] = {}
            continue
        durs   = [len(e) for e in events]
        eners  = [sum(loads.get(h, 0) for e in [evt] for h in e) for evt in events]
        maxsfl = [max(loads.get(h, 0) for h in e) for e in events]
        all_shed = dfm["load_shed_mw"].values
        out[mode] = {
            "events_per_yr":              round(len(events) / n_total, 2),
            "mean_event_duration_h":      round(float(np.mean(durs)), 2),
            "max_event_duration_h":       int(max(durs)),
            "p95_event_duration_h":       round(float(np.percentile(durs, 95)), 1),
            "mean_event_energy_mwh":      round(float(np.mean(eners)), 1),
            "max_event_energy_mwh":       round(float(max(eners)), 1),
            "max_hourly_shortfall_mw":    round(float(max(maxsfl)), 1),
            "mean_shortfall_when_shedding_mw": round(float(np.mean(all_shed)), 1),
        }
    return out


SHAPE_METHODS = {
    "M1c":     "Emergency-only storage MCS",
    "M2":      "Event-window storage MCS",
    "M3":      "Full-year ED",
    "HOPE-ED": "PCM-ED cross-check",
    "HOPE-UC": "PCM-UCED",
}

# ── Balanced VRE, N=20 ──────────────────────────────────────────────────────
bal20 = pd.read_csv(
    RESULTS / "full_model_comparison_with_hope" / "base_n20" / "all_model_aggregate_metrics.csv"
)

shape_rows = []
for mint, pname in SHAPE_METHODS.items():
    rr = bal20[bal20["model"] == mint]
    if rr.empty:
        continue
    r   = rr.iloc[0]
    nev = float(r["n_shortage_events"])
    eue = float(r["eue_mwh"])
    shape_rows.append({
        "case":                          "Balanced VRE portfolio",
        "n_scenarios":                   20,
        "method":                        pname,
        "events_per_yr":                 round(nev, 2),
        "mean_event_duration_h":         round(float(r["mean_shortage_duration_h"]), 2),
        "max_event_duration_h":          float(r["max_shortage_duration_h"]),
        "p95_event_duration_h":          float(r["p95_shortage_duration_h"]) if pd.notna(r["p95_shortage_duration_h"]) else np.nan,
        "mean_event_energy_mwh":         round(eue / nev, 1) if nev > 0 else np.nan,
        "max_hourly_shortfall_mw":       round(float(r["max_shortfall_mw"]), 1),
        "mean_shortfall_when_shedding_mw": round(float(r["mean_shortfall_when_shedding_mw"]), 1),
        "EUE_MWh_per_yr":                round(eue, 2),
        "NEUE_ppm":                      neue(eue),
    })

# ── Wind-heavy VRE, N=5 ─────────────────────────────────────────────────────
wh5 = pd.read_csv(
    RESULTS / "wind_hvy_hope_uc_comparison" / "n5" / "all_model_aggregate_metrics.csv"
)
# Compute PCM event shape from hourly data for wind-heavy (fills NaN fields
# and corrects mean_event_duration for HOPE-ED / HOPE-UC).
wh_pcm = pcm_event_shape(
    RESULTS / "hope_wind_hvy_n5_pilot" / "hope_load_shed_hourly.csv",
    n_total=5,
)
MODE_MAP = {"HOPE-ED": "ED", "HOPE-UC": "UC"}

for mint, pname in SHAPE_METHODS.items():
    rr = wh5[wh5["model"] == mint]
    if rr.empty:
        continue
    r   = rr.iloc[0]
    nev = float(r["n_shortage_events"])
    eue = float(r["eue_mwh"])

    is_pcm = mint in MODE_MAP
    ps = wh_pcm.get(MODE_MAP.get(mint, ""), {}) if is_pcm else {}

    shape_rows.append({
        "case":                          "Wind-heavy VRE portfolio",
        "n_scenarios":                   5,
        "method":                        pname,
        # For PCM methods use hourly-computed values (pre-computed mean_dur is wrong);
        # for MCS methods the pre-computed values are consistent with LOLH.
        "events_per_yr":                 ps.get("events_per_yr", round(nev, 2)),
        "mean_event_duration_h":         ps.get("mean_event_duration_h", round(float(r["mean_shortage_duration_h"]), 2)),
        "max_event_duration_h":          ps.get("max_event_duration_h", float(r["max_shortage_duration_h"])),
        "p95_event_duration_h":          ps.get("p95_event_duration_h", float(r["p95_shortage_duration_h"]) if pd.notna(r["p95_shortage_duration_h"]) else np.nan),
        "mean_event_energy_mwh":         ps.get("mean_event_energy_mwh", round(eue / nev, 1) if nev > 0 else np.nan),
        "max_hourly_shortfall_mw":       round(float(r["max_shortfall_mw"]), 1),
        "mean_shortfall_when_shedding_mw": ps.get("mean_shortfall_when_shedding_mw", float(r["mean_shortfall_when_shedding_mw"]) if pd.notna(r["mean_shortfall_when_shedding_mw"]) else np.nan),
        "EUE_MWh_per_yr":                round(eue, 2),
        "NEUE_ppm":                      neue(eue),
    })

event_shape = pd.DataFrame(shape_rows, columns=[
    "case", "n_scenarios", "method",
    "events_per_yr", "mean_event_duration_h", "max_event_duration_h",
    "p95_event_duration_h", "mean_event_energy_mwh",
    "max_hourly_shortfall_mw", "mean_shortfall_when_shedding_mw",
    "EUE_MWh_per_yr", "NEUE_ppm",
])
out2 = PAPER_TABLES / "event_shape_summary.csv"
event_shape.to_csv(out2, index=False)
print(f"\n{'-'*70}")
print(f"event_shape_summary.csv  ({len(event_shape)} rows)")
print(event_shape.to_string(index=False))

# ─── Verification ────────────────────────────────────────────────────────────
print(f"\n{'-'*70}")
print("NEUE verification (should match neue_ppm in convergence_aggregate_metrics):")
for _, r in conv_agg[(conv_agg["model"] == "M3") & (conv_agg["n_scenarios"] == 20)].iterrows():
    expected = float(r["neue_ppm"])
    computed = neue(r["eue_mwh"])
    print(f"  M3 N=20: expected {expected:.4f} ppm, computed {computed:.4f} ppm  "
          f"{'OK' if abs(expected - computed) < 0.01 else 'MISMATCH'}")

print("\nDone.")
