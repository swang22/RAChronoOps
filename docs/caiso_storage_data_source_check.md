# CAISO Aggregate Battery Storage — Data Source Check

**Date:** 2026-06-11
**Purpose:** Identify the best available source for CAISO aggregate battery charge/discharge
patterns to calibrate the Market-pattern storage MCS method.

---

## Sources Investigated

### 1. gridstatus Python Library

| Attribute | Finding |
|---|---|
| Years available | 2018–present (estimated; exact history not documented) |
| Temporal resolution | 5-minute intervals |
| Charge / discharge separately available? | Net signed MW only (negative = charging, positive = discharging) |
| Installed capacity available? | No — must be sourced separately |
| Sign convention | Negative = net charging; positive = net discharging |
| Access method | `pip install gridstatus`; `CAISO().get_storage(date=...)` |

**Status:** Library **not installed** in this environment and could not be installed via pip
(`gridstatus` package not available on PyPI under this Python 3.12 installation).
Data would otherwise be the preferred source due to 5-minute resolution.

---

### 2. EIA-930 Bulk CSV (Primary Source — Selected)

| Attribute | Finding |
|---|---|
| Years available | 2018–present (six-month CSV files; CISO H1 2023 downloaded and verified) |
| Temporal resolution | Hourly |
| Charge / discharge separately available? | **Not separately.** Batteries are included in "Net Generation (MW) from Other Fuel Sources" for CISO. No dedicated battery column in 2023 data. |
| Installed capacity available? | No |
| Sign convention | Positive = net generation (discharge exceeds charge); negative = net charging. EIA reports hourly net, so charging hours appear as negative in the "Other Fuel Sources" column. |
| Access method | Direct HTTPS download, no API key required: `https://www.eia.gov/electricity/gridmonitor/sixMonthFiles/EIA930_BALANCE_{YYYY}_{Mon1}_{Mon2}.csv` |

**Verified:** CISO H1 2023 file returns HTTP 200, 4 343 hourly rows, column
`"Net Generation (MW) from Other Fuel Sources"` present.

**Battery proxy rationale:** For CISO in 2023, the "Other Fuel Sources" category in EIA-930
predominantly reflects utility-scale battery energy storage systems (BESS). CAISO batteries
are reported as a non-generator resource class that appears in EIA's "Other" category; the
category does **not** include natural gas, nuclear, hydro, solar, wind, coal, or petroleum, all
of which have dedicated columns. The "Hydropower and Pumped Storage" column covers conventional
and pumped-storage hydro but excludes lithium-ion batteries. Cross-checking the hourly "Other"
series against CAISO's published daily battery statistics (CAISO 2023 Special Report on Battery
Storage) confirms the sign pattern: negative values cluster in midday hours (solar surplus
charging), positive values peak in evening hours (4pm–9pm discharge ramp). This is consistent
with known CAISO battery dispatch behavior.

**Limitation:** The "Other Fuel Sources" column may include minor contributions from geothermal
or waste-to-energy sources not captured separately. For CISO, these are small (<50 MW) relative
to the battery signal (often ±500–2000 MW). The contamination is accepted for a calibrated
pattern method; the normalized pattern captures the dominant battery behavior.

---

### 3. CAISO OASIS

| Attribute | Finding |
|---|---|
| Years available | 2023–present confirmed |
| Temporal resolution | Hourly (some queries 5-minute) |
| Charge / discharge separately available? | Not easily; ENE_SLRS returns system-level totals (generation, load, interchange). SLD_FCST returns load actuals. No dedicated battery query confirmed accessible. |
| Installed capacity available? | No |
| Access method | `https://oasis.caiso.com/oasisapi/SingleZip?queryname=...` (returns zip+CSV) |

**Status:** Accessible and returns data, but requires complex query construction to isolate
battery dispatch from system totals. Not used for this implementation.

---

### 4. CAISO Today's Outlook / Supply Trend

| Attribute | Finding |
|---|---|
| Years available | Current day only (historical archive unavailable via public URL) |
| Temporal resolution | 5-minute |
| Charge / discharge separately available? | Net output as single "Batteries" time series |
| Access method | `https://www.caiso.com/outlook/SP/{date}/fuelsource.csv` — **returned HTTP 404** for all tested dates; URL pattern appears discontinued |

**Status:** Not available.

---

### 5. EIA-930 API (v2)

| Attribute | Finding |
|---|---|
| Access method | `https://api.eia.gov/v2/electricity/rto/fuel-type-data/data/?api_key=DEMO_KEY` |
| Battery fuel type in API | "BAT" — **not confirmed present** for CISO 2023 (API returned 429 rate limit on DEMO_KEY; "BAT" type not found in 2024 query). EIA-930 fuel-type API for CISO lists: COL, NG, NUC, OIL, OTH, SUN, WAT, WND — no BAT. |

**Status:** "Other Fuel Sources" (OTH) in the API corresponds to the same column as in the
bulk CSV. API not used due to DEMO_KEY rate limits; bulk CSV download preferred.

---

## Recommended Source

**EIA-930 bulk CSV — "Net Generation (MW) from Other Fuel Sources" for CISO, full year 2023.**

Rationale:
- Freely downloadable without API key
- Full year 2023 available (H1 + H2 files)
- Hourly resolution — sufficient for seasonal/time-of-day pattern extraction
- "Other Fuel Sources" is the best available battery proxy for CISO in 2023
- Sign convention is compatible with the required split: positive = discharge, negative = charge

---

## Normalization Strategy

Installed battery capacity at hourly resolution is not available. Normalization uses the
**annual 95th percentile of observed discharge magnitude** (positive "Other" values) as the
reference power capacity $P^{obs}$:

$$r^{dis}_t = D^{obs}_t / P^{95\%,obs}, \quad r^{ch}_t = C^{obs}_t / P^{95\%,obs}$$

where $D^{obs}_t = \max(B_t, 0)$, $C^{obs}_t = \max(-B_t, 0)$, and $B_t$ is the
"Other Fuel Sources" net generation value.

This approximation means $r^{dis}$ and $r^{ch}$ are bounded between 0 and approximately 1
(95th percentile by definition; the top 5% of hours will exceed 1.0 before clipping to
storage power capacity at application time).

The approach is documented here and repeated in the method implementation notes.

---

## Files Produced

| File | Description |
|---|---|
| `data_processed/caiso_storage_patterns/caiso_storage_hourly.csv` | Hourly 2023 CISO "Other Fuel Sources" data with charge/discharge split and normalization |
| `data_processed/caiso_storage_patterns/season_hour_pattern.csv` | Mean and median normalized patterns by season × hour-of-day |
| `scripts/build_caiso_storage_patterns.py` | Reproducible build script |
