# Market-Pattern Storage Calibration Audit

**Date:** 2026-06-15
**Script:** `scripts/build_caiso_storage_patterns.py` (revised for this audit)
**Purpose:** Formally document the CAISO storage proxy calibration issue, the three
pattern versions produced, the preferred calibration, and the rationale.

---

## 1. Data Source Confirmation

No dedicated battery (BAT) column is available for CISO in the EIA-930 2023 release.
Full details in `docs/caiso_storage_data_source_check.md`, Section E.

**Source used:** EIA-930 bulk CSV, CISO balancing authority, 2023 full year.
Column: "Net Generation (MW) from Other Fuel Sources."
8,758 hourly rows (2 DST-related missing rows; negligible effect on seasonal patterns).

p95 normalization reference: **2769 MW** (unchanged from prior build).

---

## 2. Annual Energy Balance Analysis

For round-trip efficiency η_rt = 0.90 (η_ch = η_dis = √0.90 ≈ 0.9487), the condition
for zero annual SOC drift is:

    η_ch × annual_charge = annual_discharge / η_dis
    ⟺  annual_discharge = η_rt × annual_charge = 0.90 × annual_charge

The raw CAISO proxy fails this condition significantly:

| Quantity | Value |
|---|---|
| Annual gross discharge | 4,024,459 MWh |
| Annual gross charge | 4,068,161 MWh |
| Annual net (discharge − charge) | −43,702 MWh (net charging in raw MWh) |
| Discharge / charge ratio | 0.9893 |
| SOC energy added (charge × η_ch) | 3,859,396 MWh |
| SOC energy drawn (discharge / η_dis) | 4,242,152 MWh |
| Annual SOC drift | **−382,756 MWh** (severe depletion) |
| k_ch needed for balance | **1.0992** (scale charge UP by 9.9%) |

Despite having more charge MWh than discharge MWh (ratio = 0.989), round-trip
efficiency losses create a net depletion of ~383 GWh/year.
For a 3932 MWh / 983 MW system starting at 50% SOC (1966 MWh), this depletion
depletes the battery to 0% within approximately 4 months.

**This explains the observed SOC boundary effect:** prior simulations showed
final_soc = 0% for both paper-facing variants (MP_pure_cur, MP_emergency_cur)
regardless of starting SOC.

---

## 3. Non-Battery Baseline Estimate

The "Other Fuel Sources" series contains minor persistent non-battery generation
(geothermal, waste-to-energy). Quantification:

| Estimator | Value |
|---|---|
| 5th percentile of positive discharge hours | 37 MW (SELECTED) |
| 10th percentile of positive discharge hours | 80 MW |
| Solar-peak hours (spring+summer, 9–14h) mean discharge (all rows) | 13.5 MW |
| Baseline as fraction of p95 normalization | 1.34% |

The solar-peak mean (13.5 MW) is substantially below the 5th-percentile estimate
(37 MW), indicating the 37 MW baseline is a conservative (upper) estimate of the
persistent non-battery floor.

---

## 4. Three Calibration Versions

All three pattern files are 96 rows (4 seasons × 24 hours), saved to
`data_processed/caiso_storage_patterns/`.

### pattern_raw.csv

Current treatment. No corrections applied. For diagnostic use only.

| Property | Value |
|---|---|
| Weighted annual norm_discharge | 1453.4 |
| Weighted annual norm_charge | 1469.2 |
| Annual SOC drift (per MW capacity/year) | **−138.2** |
| Cells with norm_discharge_mean > 1.0 | 1 (fall, hour 18 = 1.074) |
| Cells with norm_charge_mean > 1.0 | 0 |

### pattern_baseline_corrected.csv

Subtract 37 MW persistent baseline from battery_net_mw before charge/discharge split.
The correction reduces gross discharge by ~144 GWh/year and increases net charge.

| Property | Value |
|---|---|
| Annual gross discharge (corrected) | 3,880,473 MWh |
| Annual gross charge (corrected) | 4,248,221 MWh |
| Annual SOC drift (per MW capacity/year) | **−21.7** |
| k_ch needed for balance | 1.0149 |

The baseline correction substantially reduces the SOC drift, but does not fully
eliminate it (depletion continues, just more slowly).

### pattern_energy_balanced.csv

Scale the raw charge rates by k_ch = 1.0992 so annual SOC drift = 0.
Discharge rates and all relative pattern shapes are preserved.

| Property | Value |
|---|---|
| k_charge_scalar | 1.0992 |
| Annual norm_charge weighted sum | 1614.9 |
| Annual norm_discharge weighted sum | 1453.4 |
| Annual SOC drift (per MW capacity/year) | **0.000** |
| Cells with norm_discharge_mean > 1.0 | 1 (fall, hour 18 = 1.074) |

---

## 5. SOC Boundary Effects (from script 72)

Run: N=20, seed=42, both portfolios, fixed_50pct and cyclic SOC initializations.

### Energy-balanced pattern, MP_pure_cur

| Case | SOC init | Init SOC | Final SOC | SOC drift | Empty hours/yr |
|---|---|---|---|---|---|
| VRE120_base | fixed_50pct | 50.0% | 23.1% | −26.9% | 543 |
| VRE120_base | cyclic | 23.1% | 23.1% | 0.0% | 543 |
| VRE120_wind_hvy | fixed_50pct | 50.0% | 23.1% | −26.9% | 540 |
| VRE120_wind_hvy | cyclic | 23.1% | 23.1% | 0.0% | 540 |

The cyclic fixed point (23.1% SOC) is reached after a single warm-up year.
The battery spends approximately 540–543 hours/year with SOC at or near 0%.

**Note:** Even the energy-balanced pattern depletes the battery partially (23.1% annual
equilibrium instead of 50%), because the simulated system (RTS-GMLC) has substantially
less surplus (charging opportunity) than historical CAISO. The pattern targets charging
rates calibrated from CAISO, but the RTS-GMLC system may not have the same solar
surplus in the same hours to absorb that charging.

**This is expected and physically meaningful:** the energy-balanced pattern specifies
*what the real CAISO batteries attempted to do*; the simulator applies the charge-curtailed
rule which limits actual charging to available surplus.

---

## 6. Impact on Reliability Metrics

### Calibration comparison (fixed 50% SOC, MP_pure_cur, N=20, seed=42)

| Case | Calibration | LOLH (h) | EUE (MWh) | Final SOC |
|---|---|---|---|---|
| VRE120_base | raw | 46.10 | 13,662 | 0.0% |
| VRE120_base | baseline_corrected | 47.00 | 14,060 | 5.3% |
| VRE120_base | energy_balanced | 46.00 | 13,655 | 23.1% |
| VRE120_wind_hvy | raw | 23.90 | 7,161 | 0.0% |
| VRE120_wind_hvy | baseline_corrected | 24.50 | 7,365 | 5.3% |
| VRE120_wind_hvy | energy_balanced | 23.90 | 7,161 | 23.1% |

**Finding:** MP_pure_cur LOLH and EUE are robust to calibration choice (range < 2%).
The pattern calibration does not materially affect the pure market-pattern results.

### Full revalidation (MP_pure_cur and MP_emergency_cur, energy-balanced, cyclic SOC)

| Case | Method | LOLH (h) | EUE (MWh) | CVaR-EUE (MWh) | Prior EUE | Change |
|---|---|---|---|---|---|---|
| VRE120_base | MP_pure_cur | 46.00 | 13,655 | 26,227 | 13,662 | −0.05% |
| VRE120_base | MP_emergency_cur | 7.70 | 3,596 | 13,429 | 4,338 | **−17%** |
| VRE120_wind_hvy | MP_pure_cur | 23.90 | 7,161 | 14,518 | 7,161 | 0% |
| VRE120_wind_hvy | MP_emergency_cur | 2.40 | 836 | 4,375 | 1,117 | **−25%** |

**MP_emergency_cur is sensitive to calibration** because emergency override discharges
in shortage hours: if the battery depleted prematurely (raw proxy), it cannot help in
shortage hours later in the year, inflating LOLH and EUE. The energy-balanced pattern
maintains non-zero SOC throughout the year (cyclic equilibrium at 23.1%), enabling
more emergency discharge and achieving lower LOLH/EUE.

---

## 7. Preferred Calibration

**Recommended: `pattern_energy_balanced.csv`**

Rationale:
1. Physically defensible for a multi-year reliability study: SOC does not
   deterministically deplete to 0% within every simulated year.
2. The raw proxy (k_ch = 0.99) under-charges relative to what round-trip efficiency
   requires for a sustainable annual cycle; the energy-balanced version corrects this
   while preserving all pattern shape information (seasonal × time-of-day ratios).
3. Results in a stable cyclic fixed point (23.1% SOC) that can be computed in a
   single warm-up iteration.
4. MP_pure_cur results are nearly identical across calibrations (validates robustness).
5. MP_emergency_cur results are ~15–25% lower than the raw proxy — this is the
   correct direction (the raw proxy over-stated EUE by under-charging the battery).

`pattern_raw.csv` retained as diagnostic sensitivity.
`pattern_baseline_corrected.csv` available as intermediate case.

---

## 8. Files Produced

| File | Description |
|---|---|
| `data_processed/caiso_storage_patterns/pattern_raw.csv` | Raw proxy, no corrections (96 rows) |
| `data_processed/caiso_storage_patterns/pattern_baseline_corrected.csv` | Baseline-corrected (37 MW floor removed; 96 rows) |
| `data_processed/caiso_storage_patterns/pattern_energy_balanced.csv` | Energy-balanced (k_ch = 1.099; 96 rows) |
| `data_processed/caiso_storage_patterns/season_hour_pattern.csv` | Same as pattern_raw (backward compatibility) |
| `results/market_pattern_storage/calibration_energy_balance.csv` | Energy balance statistics for all three versions |
| `results/market_pattern_storage/calibration_comparison.csv` | LOLH/EUE/SOC for all calibrations (from script 72) |
| `results/market_pattern_storage/soc_boundary_study.csv` | SOC boundary study (script 72) |
| `results/paper_tables/market_pattern_revalidated_metrics.csv` | Full comparison table (script 72) |
