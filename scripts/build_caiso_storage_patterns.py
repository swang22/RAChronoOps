#!/usr/bin/env python3
"""
Build CAISO normalized battery operation pattern from EIA-930 2023 data.

Source:
  EIA-930 BALANCE bulk CSV (six-month files, no API key required)
  "Net Generation (MW) from Other Fuel Sources" for CISO — best available
  proxy for aggregate battery storage in CAISO 2023.

Sign convention (EIA-930):
  Positive  → net generation  → battery net discharge (discharging > charging)
  Negative  → net consumption → battery net charging  (charging > discharging)

Normalization:
  95th percentile of observed discharge magnitude (positive values only).
  Applied uniformly to charge and discharge series.

Outputs:
  data_processed/caiso_storage_patterns/caiso_storage_hourly.csv
  data_processed/caiso_storage_patterns/season_hour_pattern.csv
"""

import io
import pathlib
import warnings
import requests
import pandas as pd
import numpy as np

warnings.filterwarnings("ignore")

# ── Output directory ──────────────────────────────────────────────────────────
ROOT = pathlib.Path(__file__).parent.parent
OUT_DIR = ROOT / "data_processed" / "caiso_storage_patterns"
OUT_DIR.mkdir(parents=True, exist_ok=True)

# ── EIA-930 six-month file URLs ───────────────────────────────────────────────
EIA_BASE = "https://www.eia.gov/electricity/gridmonitor/sixMonthFiles"
FILES_2023 = [
    f"{EIA_BASE}/EIA930_BALANCE_2023_Jan_Jun.csv",
    f"{EIA_BASE}/EIA930_BALANCE_2023_Jul_Dec.csv",
]

HEADERS = {"User-Agent": "Mozilla/5.0 Research/RA-paper"}
BAT_COL = "Net Generation (MW) from Other Fuel Sources"
DATE_COL = "Data Date"
HOUR_COL = "Hour Number"


def fetch_eia930(url: str) -> pd.DataFrame:
    print(f"  Fetching: {url}")
    r = requests.get(url, timeout=60, headers=HEADERS)
    r.raise_for_status()
    df = pd.read_csv(io.StringIO(r.text), low_memory=False)
    return df


def season_label(month: int) -> str:
    """Map month → season (meteorological)."""
    if month in (12, 1, 2):
        return "winter"
    elif month in (3, 4, 5):
        return "spring"
    elif month in (6, 7, 8):
        return "summer"
    else:
        return "fall"


# ── 1. Download and concat EIA-930 ───────────────────────────────────────────
print("Downloading EIA-930 2023 data...")
frames = []
for url in FILES_2023:
    try:
        df_raw = fetch_eia930(url)
        ciso = df_raw[df_raw["Balancing Authority"] == "CISO"].copy()
        print(f"  CISO rows: {len(ciso)}")
        frames.append(ciso)
    except Exception as e:
        print(f"  ERROR fetching {url}: {e}")

if not frames:
    raise RuntimeError("No EIA-930 data could be downloaded.")

df = pd.concat(frames, ignore_index=True)
print(f"Total CISO rows: {len(df)}")

# ── 2. Parse timestamps ───────────────────────────────────────────────────────
# EIA-930 uses local time (Pacific); "Data Date" + "Hour Number" (1-based)
df["_date"] = pd.to_datetime(df[DATE_COL], format="%m/%d/%Y", errors="coerce")
df["_hour"] = df[HOUR_COL].astype(int) - 1   # convert to 0-based hour (0..23)
df["timestamp"] = df["_date"] + pd.to_timedelta(df["_hour"], unit="h")
df = df.dropna(subset=["timestamp"])
df = df.sort_values("timestamp").reset_index(drop=True)

# ── 3. Extract battery proxy ──────────────────────────────────────────────────
if BAT_COL not in df.columns:
    raise KeyError(f"Column '{BAT_COL}' not found in EIA-930 data. "
                   "Check column mapping for the downloaded file.")

df["battery_net_mw"] = pd.to_numeric(df[BAT_COL], errors="coerce")
df = df.dropna(subset=["battery_net_mw"])

# ── 4. Split into charge and discharge ────────────────────────────────────────
df["discharge_mw"] = np.maximum(df["battery_net_mw"], 0.0)
df["charge_mw"]    = np.maximum(-df["battery_net_mw"], 0.0)

# ── 5. Normalize by 95th percentile of discharge magnitude ───────────────────
p95_discharge = np.percentile(df["discharge_mw"][df["discharge_mw"] > 0], 95)
print(f"95th-percentile discharge magnitude: {p95_discharge:.1f} MW")

df["norm_discharge"] = df["discharge_mw"] / p95_discharge
df["norm_charge"]    = df["charge_mw"]    / p95_discharge

# ── 6. Add season and hour columns ───────────────────────────────────────────
df["month"]  = df["timestamp"].dt.month
df["hour"]   = df["timestamp"].dt.hour
df["season"] = df["month"].apply(season_label)
df["source"] = "EIA-930 CISO Other Fuel Sources 2023"

# ── 7. Save hourly file ───────────────────────────────────────────────────────
hourly_cols = [
    "timestamp", "season", "hour",
    "battery_net_mw", "charge_mw", "discharge_mw",
    "norm_charge", "norm_discharge", "source",
]
hourly_df = df[hourly_cols].copy()
hourly_path = OUT_DIR / "caiso_storage_hourly.csv"
hourly_df.to_csv(hourly_path, index=False)
print(f"Saved hourly data: {hourly_path}  ({len(hourly_df)} rows)")

# ── 8. Build seasonal-hour average pattern ───────────────────────────────────
grouped = hourly_df.groupby(["season", "hour"])

pattern_rows = []
for (season, hour), grp in grouped:
    pattern_rows.append({
        "season":              season,
        "hour":                hour,
        "norm_charge_mean":    grp["norm_charge"].mean(),
        "norm_discharge_mean": grp["norm_discharge"].mean(),
        "norm_charge_p50":     grp["norm_charge"].median(),
        "norm_discharge_p50":  grp["norm_discharge"].median(),
        "sample_count":        len(grp),
    })

pattern_df = pd.DataFrame(pattern_rows).sort_values(["season", "hour"]).reset_index(drop=True)
pattern_path = OUT_DIR / "season_hour_pattern.csv"
pattern_df.to_csv(pattern_path, index=False)
print(f"Saved pattern data: {pattern_path}  ({len(pattern_df)} rows)")

# ── 9. Quick sanity check ─────────────────────────────────────────────────────
print("\n=== Pattern sanity check (summer mean by hour) ===")
summer = pattern_df[pattern_df["season"] == "summer"].set_index("hour")
print("Hour  Chg(mean)  Dis(mean)")
for h in [6, 9, 12, 15, 18, 21]:
    if h in summer.index:
        row = summer.loc[h]
        print(f"  {h:02d}    {row['norm_charge_mean']:.3f}     {row['norm_discharge_mean']:.3f}")

print("\n=== Pattern sanity check (winter mean by hour) ===")
winter = pattern_df[pattern_df["season"] == "winter"].set_index("hour")
for h in [6, 9, 12, 15, 18, 21]:
    if h in winter.index:
        row = winter.loc[h]
        print(f"  {h:02d}    {row['norm_charge_mean']:.3f}     {row['norm_discharge_mean']:.3f}")

print("\n=== Annual statistics ===")
print(f"  Total hours:            {len(hourly_df)}")
print(f"  Hours with discharge:   {(hourly_df['discharge_mw'] > 50).sum()}")
print(f"  Hours with charge:      {(hourly_df['charge_mw'] > 50).sum()}")
print(f"  Max discharge:          {hourly_df['discharge_mw'].max():.0f} MW")
print(f"  Max charge:             {hourly_df['charge_mw'].max():.0f} MW")
print(f"  95th-pct discharge ref: {p95_discharge:.0f} MW")
print(f"  Mean norm_discharge:    {hourly_df['norm_discharge'].mean():.3f}")
print(f"  Mean norm_charge:       {hourly_df['norm_charge'].mean():.3f}")
print("\nDone.")
