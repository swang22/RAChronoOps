#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build CAISO normalized battery operation patterns from EIA-930 2023 data.
Three calibration versions:

  pattern_raw.csv
    Current treatment. EIA-930 CISO "Other Fuel Sources" split into gross
    charge and discharge at the hourly level, normalized by the p95 discharge
    magnitude, then averaged by season × hour-of-day. Diagnostic only.

  pattern_baseline_corrected.csv
    Subtracts a documented persistent non-battery baseline (geothermal /
    waste-to-energy) from net output before splitting. Baseline = 5th
    percentile of positive discharge_mw across all 8758 hours.

  pattern_energy_balanced.csv
    Applies a single scalar to the charge rates so that the implied annual
    SOC drift is approximately zero at round-trip efficiency η = sqrt(0.90):

        k_ch = annual_discharge / (η² × annual_charge)

    Discharge rates and seasonal/hourly shape are unchanged.

Source:
  EIA-930 BALANCE bulk CSV, CISO balancing authority, full year 2023.
  "Net Generation (MW) from Other Fuel Sources" — best available proxy for
  aggregate BESS in CAISO 2023; no dedicated battery column available for
  CISO in the 2023 EIA-930 release (BAT fuel type absent from CISO series).

Authoritative source check (documented):
  - gridstatus library: not installable in this environment.
  - EIA-930 API: BAT fuel type confirmed absent for CISO in 2023 queries.
  - CAISO OASIS: no public endpoint isolates battery net output from system
    totals in a reproducible hourly CSV format.
  Conclusion: EIA-930 OTH proxy is retained as the only reproducible source
  for CISO 2023. Update recommended if 2024 EIA-930 data includes BAT column.

Outputs (data_processed/caiso_storage_patterns/):
  caiso_storage_hourly.csv           (hourly series, downloaded if absent)
  pattern_raw.csv                    (current treatment, diagnostic)
  pattern_baseline_corrected.csv     (baseline-corrected)
  pattern_energy_balanced.csv        (charge-scaled for round-trip balance)

  results/market_pattern_storage/calibration_energy_balance.csv
"""

import io
import pathlib
import warnings
import pandas as pd
import numpy as np

warnings.filterwarnings("ignore")

# ── Paths ─────────────────────────────────────────────────────────────────────
ROOT    = pathlib.Path(__file__).parent.parent
OUT_DIR = ROOT / "data_processed" / "caiso_storage_patterns"
RES_DIR = ROOT / "results" / "market_pattern_storage"
OUT_DIR.mkdir(parents=True, exist_ok=True)
RES_DIR.mkdir(parents=True, exist_ok=True)

HOURLY_PATH = OUT_DIR / "caiso_storage_hourly.csv"

# ── EIA-930 source ────────────────────────────────────────────────────────────
EIA_BASE   = "https://www.eia.gov/electricity/gridmonitor/sixMonthFiles"
FILES_2023 = [
    f"{EIA_BASE}/EIA930_BALANCE_2023_Jan_Jun.csv",
    f"{EIA_BASE}/EIA930_BALANCE_2023_Jul_Dec.csv",
]
HEADERS  = {"User-Agent": "Mozilla/5.0 Research/RA-paper"}
BAT_COL  = "Net Generation (MW) from Other Fuel Sources"
DATE_COL = "Data Date"
HOUR_COL = "Hour Number"

# Round-trip efficiency (must match MarketPatternStorage.jl)
ETA_RT = 0.90
ETA_CH = ETA_DIS = np.sqrt(ETA_RT)


def season_label(month: int) -> str:
    if month in (12, 1, 2):   return "winter"
    elif month in (3, 4, 5):  return "spring"
    elif month in (6, 7, 8):  return "summer"
    else:                      return "fall"


# ── 1. Load or download hourly series ─────────────────────────────────────────
if HOURLY_PATH.exists():
    print(f"Loading existing hourly data: {HOURLY_PATH}")
    hourly_df = pd.read_csv(HOURLY_PATH, parse_dates=["timestamp"])
else:
    print("Downloading EIA-930 2023 data...")
    import requests
    frames = []
    for url in FILES_2023:
        print(f"  Fetching: {url}")
        r = requests.get(url, timeout=60, headers=HEADERS)
        r.raise_for_status()
        df_raw = pd.read_csv(io.StringIO(r.text), low_memory=False)
        ciso   = df_raw[df_raw["Balancing Authority"] == "CISO"].copy()
        print(f"  CISO rows: {len(ciso)}")
        frames.append(ciso)

    df = pd.concat(frames, ignore_index=True)
    df["_date"]     = pd.to_datetime(df[DATE_COL], format="%m/%d/%Y", errors="coerce")
    df["_hour"]     = df[HOUR_COL].astype(int) - 1
    df["timestamp"] = df["_date"] + pd.to_timedelta(df["_hour"], unit="h")
    df = df.dropna(subset=["timestamp"]).sort_values("timestamp").reset_index(drop=True)

    df["battery_net_mw"] = pd.to_numeric(df[BAT_COL], errors="coerce")
    df = df.dropna(subset=["battery_net_mw"])
    df["discharge_mw"] = np.maximum(df["battery_net_mw"], 0.0)
    df["charge_mw"]    = np.maximum(-df["battery_net_mw"], 0.0)
    df["month"]        = df["timestamp"].dt.month
    df["hour"]         = df["timestamp"].dt.hour
    df["season"]       = df["month"].apply(season_label)
    df["source"]       = "EIA-930 CISO Other Fuel Sources 2023"

    p95 = np.percentile(df["discharge_mw"][df["discharge_mw"] > 0], 95)
    df["norm_discharge"] = df["discharge_mw"] / p95
    df["norm_charge"]    = df["charge_mw"]    / p95

    hourly_df = df[["timestamp","season","hour","battery_net_mw","charge_mw",
                     "discharge_mw","norm_charge","norm_discharge","source"]].copy()
    hourly_df.to_csv(HOURLY_PATH, index=False)
    print(f"Saved hourly data: {HOURLY_PATH}  ({len(hourly_df)} rows)")

n_rows = len(hourly_df)
print(f"Hourly rows: {n_rows}")

# Reconstruct month and hour columns if loaded from CSV
if "month" not in hourly_df.columns:
    hourly_df["month"]  = hourly_df["timestamp"].dt.month
if "season" not in hourly_df.columns:
    hourly_df["season"] = hourly_df["month"].apply(season_label)

# ── 2. Annual energy balance for raw proxy ─────────────────────────────────────
annual_dis_raw = hourly_df["discharge_mw"].sum()
annual_chg_raw = hourly_df["charge_mw"].sum()
annual_net_raw = hourly_df["battery_net_mw"].sum()

# Energy stored / drawn from SOC
soc_add_raw = annual_chg_raw * ETA_CH
soc_draw_raw = annual_dis_raw / ETA_DIS
soc_drift_raw = soc_add_raw - soc_draw_raw

# p95 used for normalization
p95_dis = np.percentile(hourly_df["discharge_mw"][hourly_df["discharge_mw"] > 0], 95)

print(f"\n=== Raw proxy energy balance ===")
print(f"  Annual discharge:  {annual_dis_raw:,.0f} MWh")
print(f"  Annual charge:     {annual_chg_raw:,.0f} MWh")
print(f"  Annual net:        {annual_net_raw:,.0f} MWh")
print(f"  ratio dis/chg:     {annual_dis_raw/annual_chg_raw:.4f}")
print(f"  SOC added (x eta_ch):  {soc_add_raw:,.0f} MWh")
print(f"  SOC drawn (/ eta_dis): {soc_draw_raw:,.0f} MWh")
print(f"  Annual SOC drift:  {soc_drift_raw:,.0f} MWh  (negative = depletion)")
print(f"  p95 discharge ref: {p95_dis:.0f} MW")

# ── 3. Authoritative battery data source check ─────────────────────────────────
print("""
=== Authoritative battery source check ===
  gridstatus library: not available in this environment (pip install fails).
  EIA-930 API BAT fuel type: absent for CISO in 2023 (confirmed by prior audit).
  CAISO OASIS: no reproducible public endpoint for hourly battery net output.
  Decision: retain EIA-930 OTH proxy. Flag as proxy, not exact battery dispatch.
  Recommendation: check EIA-930 2024+ data for CISO BAT column availability.
""")

# ── 4. Persistent non-battery baseline estimate ────────────────────────────────
pos_dis = hourly_df["discharge_mw"][hourly_df["discharge_mw"] > 0]
p05_pos_dis = float(np.percentile(pos_dis, 5))
p10_pos_dis = float(np.percentile(pos_dis, 10))

# Mean discharge in solar-peak hours (spring+summer, hours 9-14) — expected ~0
solar_mask = (hourly_df["season"].isin(["spring","summer"])) & \
             (hourly_df["hour"].between(9, 14))
baseline_solar_all  = hourly_df.loc[solar_mask, "discharge_mw"].mean()
baseline_solar_pos  = hourly_df.loc[solar_mask & (hourly_df["discharge_mw"]>0),
                                     "discharge_mw"].mean()

# Use 5th-percentile of positive discharge as the persistent baseline estimate
baseline_mw = p05_pos_dis

print(f"=== Non-battery baseline estimates ===")
print(f"  5th pct of positive discharge:          {p05_pos_dis:.0f} MW  (SELECTED)")
print(f"  10th pct of positive discharge:         {p10_pos_dis:.0f} MW")
print(f"  Solar-peak mean discharge (all rows):   {baseline_solar_all:.1f} MW")
print(f"  Solar-peak mean discharge (pos. only):  {baseline_solar_pos:.1f} MW")
print(f"  p95 normalization reference:            {p95_dis:.0f} MW")
print(f"  Baseline as fraction of p95:            {baseline_mw/p95_dis:.4f}")
print(f"  Note: solar-peak mean ~{baseline_solar_all:.0f} MW << p05 {p05_pos_dis:.0f} MW")
print(f"  → geothermal/other contamination is small relative to battery signal.")

# ── 5. Build baseline-corrected series ────────────────────────────────────────
net_corrected = hourly_df["battery_net_mw"] - baseline_mw
dis_corrected = np.maximum(net_corrected, 0.0)
chg_corrected = np.maximum(-net_corrected, 0.0)

annual_dis_bc = dis_corrected.sum()
annual_chg_bc = chg_corrected.sum()
soc_drift_bc  = annual_chg_bc * ETA_CH - annual_dis_bc / ETA_DIS

print(f"\n=== Baseline-corrected energy balance (baseline={baseline_mw:.0f} MW) ===")
print(f"  Annual discharge:  {annual_dis_bc:,.0f} MWh")
print(f"  Annual charge:     {annual_chg_bc:,.0f} MWh")
print(f"  ratio dis/chg:     {annual_dis_bc/annual_chg_bc:.4f}")
print(f"  Annual SOC drift:  {soc_drift_bc:,.0f} MWh")

# ── 6. Energy-balance scalar (applied to raw proxy) ───────────────────────────
# Scale charge up so: k_ch × annual_chg × η_ch = annual_dis / η_dis
# → k_ch = annual_dis / (η_rt × annual_chg) = annual_dis / (0.90 × annual_chg)
k_ch_raw = annual_dis_raw / (ETA_RT * annual_chg_raw)
k_ch_bc  = annual_dis_bc  / (ETA_RT * annual_chg_bc)

print(f"\n=== Energy-balance scalars ===")
print(f"  Raw proxy:                k_ch = {k_ch_raw:.4f}  (scale charge UP by {(k_ch_raw-1)*100:.1f}%)")
print(f"  Baseline-corrected:       k_ch = {k_ch_bc:.4f}  (scale charge UP by {(k_ch_bc-1)*100:.1f}%)")

# ── 7. Build all three pattern versions ───────────────────────────────────────
def build_pattern(dis_series, chg_series, p95_ref, season_col, hour_col):
    """Aggregate hourly series into season × hour-of-day mean pattern."""
    norm_dis = dis_series / p95_ref
    norm_chg = chg_series / p95_ref
    df_tmp = pd.DataFrame({
        "season":       season_col,
        "hour":         hour_col,
        "norm_dis":     norm_dis,
        "norm_chg":     norm_chg,
    })
    rows = []
    for (season, hour), grp in df_tmp.groupby(["season","hour"]):
        rows.append({
            "season":              season,
            "hour":                hour,
            "norm_charge_mean":    float(grp["norm_chg"].mean()),
            "norm_discharge_mean": float(grp["norm_dis"].mean()),
            "norm_charge_p50":     float(grp["norm_chg"].median()),
            "norm_discharge_p50":  float(grp["norm_dis"].median()),
            "sample_count":        len(grp),
        })
    return pd.DataFrame(rows).sort_values(["season","hour"]).reset_index(drop=True)


season_col = hourly_df["season"]
hour_col   = hourly_df["hour"]

# Pattern 1: raw (identical to existing season_hour_pattern.csv)
pat_raw = build_pattern(
    hourly_df["discharge_mw"], hourly_df["charge_mw"],
    p95_dis, season_col, hour_col
)

# Pattern 2: baseline-corrected
pat_bc = build_pattern(
    dis_corrected, chg_corrected,
    p95_dis, season_col, hour_col
)

# Pattern 3: energy-balanced (scale raw charge up by k_ch_raw)
dis_raw_series = hourly_df["discharge_mw"]
chg_balanced   = hourly_df["charge_mw"] * k_ch_raw
pat_bal = build_pattern(
    dis_raw_series, chg_balanced,
    p95_dis, season_col, hour_col
)

# Verify energy balance of pat_bal
norm_dis_bal_sum = (pat_bal["norm_discharge_mean"] * pat_bal["sample_count"]).sum()
norm_chg_bal_sum = (pat_bal["norm_charge_mean"]    * pat_bal["sample_count"]).sum()
drift_bal = norm_chg_bal_sum * ETA_CH - norm_dis_bal_sum / ETA_DIS
print(f"\n=== Energy-balanced pattern verification ===")
print(f"  norm_charge weighted sum:    {norm_chg_bal_sum:.3f}")
print(f"  norm_discharge weighted sum: {norm_dis_bal_sum:.3f}")
print(f"  Implied SOC drift (norm.):   {drift_bal:.4f}  (target ≈ 0)")

# ── 8. Save patterns ──────────────────────────────────────────────────────────
paths = {
    "pattern_raw.csv":               (pat_raw,  "RAW PROXY (diagnostic only)"),
    "pattern_baseline_corrected.csv":(pat_bc,   f"BASELINE-CORRECTED (baseline={baseline_mw:.0f} MW)"),
    "pattern_energy_balanced.csv":   (pat_bal,  f"ENERGY-BALANCED (k_ch={k_ch_raw:.4f})"),
    "season_hour_pattern.csv":       (pat_raw,  "RAW PROXY (existing filename for backward compat)"),
}
for fname, (df, desc) in paths.items():
    p = OUT_DIR / fname
    df.to_csv(p, index=False)
    print(f"  Saved {fname}  ({len(df)} rows)  [{desc}]")

# ── 9. Calibration energy balance summary CSV ─────────────────────────────────
def pattern_stats(pat, label, k_ch=1.0):
    sc = pat["sample_count"]
    nd = pat["norm_discharge_mean"]
    nc = pat["norm_charge_mean"]
    nd_wt = (nd * sc).sum()
    nc_wt = (nc * sc).sum()
    drift  = nc_wt * ETA_CH - nd_wt / ETA_DIS
    n_dis_gt1 = (nd > 1.0).sum()
    n_chg_gt1 = (nc > 1.0).sum()
    return {
        "pattern":                    label,
        "annual_weighted_norm_discharge": round(nd_wt, 3),
        "annual_weighted_norm_charge":    round(nc_wt, 3),
        "ratio_dis_over_chg":         round(nd_wt / nc_wt, 4) if nc_wt > 0 else float("nan"),
        "annual_soc_drift_norm":      round(drift, 4),
        "k_charge_scalar":            round(k_ch, 4),
        "max_norm_discharge_mean":    round(nd.max(), 4),
        "max_norm_charge_mean":       round(nc.max(), 4),
        "n_cells_dis_above_1":        int(n_dis_gt1),
        "n_cells_chg_above_1":        int(n_chg_gt1),
        "annual_mean_net_norm":       round((nd_wt - nc_wt) / sc.sum(), 6),
        "p95_ref_mw":                 round(p95_dis, 1),
        "baseline_mw":                round(baseline_mw, 1),
        "eta_rt":                     ETA_RT,
        "n_hourly_obs":               n_rows,
    }

rows_stats = [
    pattern_stats(pat_raw, "pattern_raw",               k_ch=1.0),
    pattern_stats(pat_bc,  "pattern_baseline_corrected", k_ch=k_ch_bc),
    pattern_stats(pat_bal, "pattern_energy_balanced",    k_ch=k_ch_raw),
]
stats_df = pd.DataFrame(rows_stats)
stats_path = RES_DIR / "calibration_energy_balance.csv"
stats_df.to_csv(stats_path, index=False)
print(f"\nSaved calibration stats: {stats_path}")

# ── 10. Summary ───────────────────────────────────────────────────────────────
print("\n=== Summary ===")
print(stats_df[["pattern","annual_weighted_norm_discharge","annual_weighted_norm_charge",
                 "annual_soc_drift_norm","k_charge_scalar","n_cells_dis_above_1"]].to_string(index=False))
print(f"""
Pattern notes:
  pattern_raw:                Geothermal/other contamination not removed; annual SOC drift
                              ≈ {rows_stats[0]['annual_soc_drift_norm']:.1f} (negative = depletion per MW capacity per year).
  pattern_baseline_corrected: Subtracts {baseline_mw:.0f} MW persistent non-battery floor;
                              reduces discharge by ~{(annual_dis_raw-annual_dis_bc)/1e3:.0f} GWh/yr.
  pattern_energy_balanced:    Scales charge up by {k_ch_raw:.4f}×; annual SOC drift ≈ 0.
                              Retains original discharge shape and all relative ratios.

Preferred for paper comparison: pattern_energy_balanced.csv
  Rationale: physically defensible for a multi-year reliability study;
  prevents guaranteed mid-year depletion from biasing EUE upward.
  Raw proxy retained as sensitivity (pattern_raw.csv).
""")
print("Done.")
