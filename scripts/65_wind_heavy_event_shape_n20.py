#!/usr/bin/env python3
"""
65_wind_heavy_event_shape_n20.py

Compute event-shape metrics for the wind-heavy VRE portfolio at N=20.

Sources:
  results/wind_hvy_hope_uc_comparison/n20/all_model_aggregate_metrics.csv
    — M1c, M2, M3 aggregate metrics (event-shape fields are correct for MCS methods)
  results/wind_hvy_hope_uc_comparison/n20/hope_metrics_by_scenario.csv
    — per-scenario HOPE-ED and HOPE-UC metrics (needed to compute correct
      mean_event_duration; the aggregate file uses a biased mean that
      averages per-scenario means including zero-event scenarios)

Computation notes:
  For MCS methods (M1c, M2, M3):
    events_per_yr     = n_shortage_events (already mean per scenario)
    mean_event_dur    = lolh / events_per_yr  [== total_lolh / total_events]
    max_event_dur     = max_shortage_duration_h
    max_shortfall     = max_shortfall_mw

  For HOPE methods (ED, UC):
    events_per_yr     = sum(n_shortage_events) / n_scenarios
    mean_event_dur    = sum(lolh) / sum(n_shortage_events)
                        [correct pooled mean, not mean of per-scenario means]
    max_event_dur     = estimated from per-scenario p95_shortage_duration_h;
                        for scenarios with 1–2 events, p95 ≈ max; flagged as
                        approximate in the output
    max_shortfall     = max(max_shortfall_mw) across scenarios

Output:
  results/paper_tables/event_shape_wind_heavy_n20.csv
"""

import numpy as np
import pandas as pd
from pathlib import Path

BASE   = Path(r"d:\MIT Dropbox\Shen Wang\MIT\RA\RA_assessment\RAChronoOps")
RES    = BASE / "results"
WH20   = RES / "wind_hvy_hope_uc_comparison" / "n20"
TAB    = RES / "paper_tables"
TAB.mkdir(exist_ok=True)

N_SCEN = 20

# ─── Annual load (same as script 46) ─────────────────────────────────────────
conv_agg = pd.read_csv(RES / "sampling_convergence" / "convergence_aggregate_metrics.csv")
_ref = conv_agg[(conv_agg["model"] == "M3") & (conv_agg["n_scenarios"] == 20)].iloc[0]
ANNUAL_LOAD_MWH = float(_ref["eue_mwh"]) / float(_ref["neue_ppm"]) * 1e6

# ─── MCS / ED aggregate metrics ──────────────────────────────────────────────
agg = pd.read_csv(WH20 / "all_model_aggregate_metrics.csv")

METHOD_LABEL = {
    "M1c":     "Emergency-only storage MCS",
    "M2":      "Event-window storage MCS",
    "M3":      "Full-year ED",
    "HOPE-ED": "PCM-ED (cross-check)",
    "HOPE-UC": "PCM-UCED",
}

rows = []

for mint in ["M1c", "M2", "M3"]:
    rr = agg[agg["model"] == mint]
    if rr.empty:
        print(f"  [MISSING] {mint} in aggregate metrics — skipping")
        continue
    r   = rr.iloc[0]
    nev = float(r["n_shortage_events"])    # mean events per scenario
    eue = float(r["eue_mwh"])
    lolh = float(r["lolh"])

    # Correct mean: total_lolh / total_events (both scaled by N_SCEN, cancel)
    mean_dur = lolh / nev if nev > 0 else float("nan")

    rows.append({
        "case":                   "Wind-heavy VRE portfolio",
        "n_scenarios":            N_SCEN,
        "method":                 METHOD_LABEL[mint],
        "events_per_yr":          round(nev, 2),
        "mean_event_duration_h":  round(mean_dur, 2),
        "max_event_duration_h":   float(r["max_shortage_duration_h"]),
        "max_event_duration_note":"exact",
        "max_hourly_shortfall_mw":round(float(r["max_shortfall_mw"]), 1),
        "EUE_MWh_per_yr":         round(eue, 2),
        "LOLH_h_per_yr":          round(lolh, 2),
        "NEUE_ppm":               round(eue / ANNUAL_LOAD_MWH * 1e6, 2),
    })

# ─── HOPE methods from per-scenario CSV ──────────────────────────────────────
scen = pd.read_csv(WH20 / "hope_metrics_by_scenario.csv")

# Extract scenario ID from case_folder (e.g. "RAChronoOps_VRE120_wind_hvy_s015_UC")
scen["mode"] = scen["case_folder"].str.extract(r"_(UC|ED)$")[0]

for hope_key, mint in [("ED", "HOPE-ED"), ("UC", "HOPE-UC")]:
    df_m = scen[scen["mode"] == hope_key].copy()
    if df_m.empty:
        print(f"  [MISSING] {hope_key} in HOPE scenario CSV — skipping")
        continue

    total_events = df_m["n_shortage_events"].sum()
    total_lolh   = df_m["lolh"].sum()
    events_per_yr = total_events / N_SCEN

    mean_dur = total_lolh / total_events if total_events > 0 else float("nan")

    max_sf = df_m["max_shortfall_mw"].max()

    # max_event_duration: use max of per-scenario p95 as approximation.
    # For scenarios with 1–2 events, p95 ≈ max.
    # This is an estimate; flagged as "approx" in the output.
    p95_vals = df_m[df_m["n_shortage_events"] > 0]["p95_shortage_duration_h"]
    max_dur_est = float(p95_vals.max()) if not p95_vals.empty else float("nan")

    # Also compute the single-event exact max (for scenarios with n_ev=1, dur=lolh)
    single_ev = df_m[df_m["n_shortage_events"] == 1]
    max_single = float(single_ev["lolh"].max()) if not single_ev.empty else 0.0

    # Take the greater of the two estimates
    max_dur_est = max(max_dur_est, max_single)

    rows.append({
        "case":                   "Wind-heavy VRE portfolio",
        "n_scenarios":            N_SCEN,
        "method":                 METHOD_LABEL[mint],
        "events_per_yr":          round(events_per_yr, 2),
        "mean_event_duration_h":  round(mean_dur, 2),
        "max_event_duration_h":   round(max_dur_est, 1),
        "max_event_duration_note":"approx (from per-scenario p95)",
        "max_hourly_shortfall_mw":round(max_sf, 1),
        "EUE_MWh_per_yr":         round(float(df_m["eue_mwh"].sum()) / N_SCEN, 2),
        "LOLH_h_per_yr":          round(total_lolh / N_SCEN, 2),
        "NEUE_ppm":               round(
            (df_m["eue_mwh"].sum() / N_SCEN) / ANNUAL_LOAD_MWH * 1e6, 2
        ),
    })

df_out = pd.DataFrame(rows, columns=[
    "case", "n_scenarios", "method",
    "events_per_yr", "mean_event_duration_h",
    "max_event_duration_h", "max_event_duration_note",
    "max_hourly_shortfall_mw",
    "EUE_MWh_per_yr", "LOLH_h_per_yr", "NEUE_ppm",
])

out_path = TAB / "event_shape_wind_heavy_n20.csv"
df_out.to_csv(out_path, index=False)
print(f"Saved: {out_path}")
print()
print(df_out.to_string(index=False))

# ─── Cross-check: EUE and LOLH should match paper_hope_validation.csv ────────
hope_val = pd.read_csv(TAB / "paper_hope_validation.csv")
wh_val   = hope_val[hope_val["case"] == "VRE120_wind_hvy"].copy()
print()
print("Cross-check vs paper_hope_validation.csv (VRE120_wind_hvy, N=20):")
for _, r in wh_val.iterrows():
    mint  = r["model_internal"]
    label = METHOD_LABEL.get(mint, mint)
    ev_row = df_out[df_out["method"] == label]
    if ev_row.empty:
        continue
    ev = ev_row.iloc[0]
    eue_ok   = abs(ev["EUE_MWh_per_yr"] - r["eue_mwh"]) < 1.0
    lolh_ok  = abs(ev["LOLH_h_per_yr"]  - r["lolh"]) < 0.01
    print(f"  {label:38s}  EUE: {ev['EUE_MWh_per_yr']:.2f} vs {r['eue_mwh']:.2f}  {'OK' if eue_ok else 'MISMATCH'}  "
          f"LOLH: {ev['LOLH_h_per_yr']:.2f} vs {r['lolh']:.2f}  {'OK' if lolh_ok else 'MISMATCH'}")

print()
print("Done.")
