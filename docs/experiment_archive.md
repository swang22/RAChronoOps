# Diagnostic Experiment Archive

This document records the completed diagnostic experiments that informed
the revised research design.  These results are preserved as-is and should
not be re-run as part of the main experiment sequence.

See `results/storage_validation/` and `results/m1_debug/` for the raw outputs.

---

## 1. Diagnostic data preparation

**Dataset:** Full RTS-GMLC single-zone, 8760-hour (one full year).

**Generator fleet aggregated to a single copper-plate zone:**

| Category | Count | Capacity |
|----------|-------|---------|
| Thermal | 73 units | 8,076 MW |
| Wind VRE | 4 units | 2,508 MW (CF 32.4%) |
| Solar VRE (PV + RTPV) | 56 units | 2,716 MW (CF 24.7%) |
| **Total** | **133 units** | — |

**Excluded resource types (logged as warnings during aggregation):**
HYDRO (19 units), ROR (1), CSP (1), STORAGE (1), SYNC_COND (3).
These are excluded to keep the modelled fleet tractable; storage is
represented as a single aggregate unit.

**Baseline storage:** One aggregate battery at 10% of peak load power
(~819 MW), 4-hour duration (~3,276 MWh), round-trip efficiency η = 0.90
(η_ch = η_dis = √0.90 ≈ 0.9487 per half-trip).

**System summary at baseline (load_scale = 1.00):**

| Metric | Value |
|--------|-------|
| Hours | 8,760 |
| Peak load | 8,191.8 MW |
| Annual load | 37,561 GWh |
| Thermal capacity | 8,076 MW |
| Wind capacity | 2,508 MW |
| Solar capacity | 2,716 MW |
| Storage | 819 MW / 3,276 MWh |

Scripts: `scripts/00_get_rts_gmlc_data.jl`, `scripts/01_build_single_zone_rts.jl`,
`scripts/04_summarize_processed_data.jl`.

---

## 2. Load-scaling calibration

**Motivation:** The baseline RTS-GMLC system (load_scale = 1.00) is
well-provisioned relative to its thermal capacity.  RA-3 / M3 (full-year
ED LP) produced near-zero LOLH at baseline, making it impossible to
distinguish between dispatch strategies.  A calibrated stress case was needed.

**Method:** Load timeseries scaled by a uniform multiplier α while holding
generation and storage fixed.  RA-3 / M3 was used as the reliability benchmark
because it represents an upper bound on achievable reliability for a given
dispatch strategy.

**Base calibration results (10 scenarios, seed 42):**

| load_scale | M3 LOLH (h/yr) | M1 LOLH (h/yr) |
|------------|----------------|----------------|
| 1.00 | ~0 | ~0 |
| 1.05 | ~0 | ~0 |
| 1.10 | ~0 | ~0 |
| 1.15 | ~0 | ~0 |
| 1.20 | ~7–8 | ~96 |

**Extended calibration results (α = 1.20 to 1.35, 10 scenarios, seed 42):**

| load_scale | M3 LOLH (h/yr) |
|------------|----------------|
| 1.20 | ~7–8 |
| 1.225 | ~15 |
| 1.25 | ~24 |
| 1.275 | ~35 |
| 1.30 | ~50 |
| 1.35 | ~80 |

**Selected stress case:** `load_scale = 1.20`.

**Why not target exactly 10 h/yr:** At 10 scenarios per run, Monte Carlo
uncertainty is too large for precise LOLH targeting.  The 50-scenario
validation at α = 1.20 produced M3 LOLH = 6.22 h/yr for the reference
storage case (10% peak / 4h), which is close enough to the 10 h/yr
industry-of-record target to make inter-method comparisons meaningful
without requiring a computationally expensive additional calibration round.

Scripts: `scripts/06_build_experiment_cases.jl`,
`scripts/09_calibrate_load_scaling.jl`.

Outputs: `results/load_scaling/load_scaling_calibration.csv`,
`results/load_scaling/load_scaling_calibration_extended.csv`.

---

## 3. Storage matrix and validation

### 3a. Initial storage matrix (10 scenarios, seed 42)

All 12 cases run at `load_scale = 1.20`.  Storage power varies over
{5%, 10%, 20%} of peak load; duration over {2, 4, 8, 12} hours.
RA-1a / M1 and RA-3 / M3 were compared.

Script: `scripts/10_run_storage_matrix.jl`.
Output: `results/storage_matrix/storage_matrix_results.csv`.

**Finding:** RA-1a / M1 produced identical LOLH and EUE across all 12 storage
configurations, despite widely varying storage parameters.  This was
initially flagged as an anomaly requiring investigation (see Section 4).

### 3b. Selected 50-scenario validation

Six cases were selected for re-validation with 50 scenarios (seed 42)
to confirm that 10-scenario matrix findings were not sampling artefacts.

Script: `scripts/12_run_selected_storage_validation.jl`.
Outputs: `results/storage_validation/selected_storage_validation_results.csv`,
`results/storage_validation/selected_storage_validation_errors.csv`,
`results/storage_validation/selected_storage_validation_summary.txt`.

**Key RA-3 / M3 benchmark findings (50 scenarios, load_scale = 1.20):**

| Case | Storage | M3 LOLH (h/yr) | M3 EUE (MWh) | M3 EUE CI95 |
|------|---------|----------------|--------------|-------------|
| p05_d4 | 492 MW / 4h | 28.96 | 9,925 | ±22.3% |
| p10_d2 | 983 MW / 2h | 20.06 | 9,670 | ±22.9% |
| p10_d4 | 983 MW / 4h | 6.22 | 2,889 | ±37.8% |
| p10_d8 | 983 MW / 8h | 2.78 | 543 | ±60.4% |
| p20_d2 | 1,966 MW / 2h | 4.90 | 2,889 | ±37.8% |
| p20_d4 | 1,966 MW / 4h | 0.30 | 215 | ±126.0% |

RA-1a / M1 LOLH was 96.48 h/yr uniformly across all six cases (see Section 4).

**Interpretation:**

- **2h → 4h at 10% penetration** gives a large reliability gain: LOLH
  falls from 20.06 to 6.22 h/yr (−69%), EUE drops 70.1%.  Duration is
  the binding constraint at this penetration level.
- **4h → 8h at 10% penetration** shows clear diminishing returns: LOLH
  falls from 6.22 to 2.78 h/yr (−55%), but the absolute gain is only
  3.44 h/yr compared with 13.84 h/yr for the 2h → 4h step.
- **20% / 4h** nearly eliminates scarcity (LOLH = 0.30 h/yr), consistent
  with the system being over-provisioned relative to its outage risk.
- **p10_d4 and p20_d2** have identical EUE (2,889 MWh) at 50 scenarios
  despite very different storage configurations (same total MWh: 3,932 vs
  3,932).  LOLH differs (6.22 vs 4.90 h/yr), reflecting different
  event-duration structure.  The EUE equivalence is a genuine result
  (not a sampling artefact at N=50) because total stored energy is equal.

### 3c. Debug run for the EUE anomaly (p10_d4 vs p20_d2)

Script: `scripts/11_debug_storage_cases.jl`.
Output: `results/storage_debug/`.

Confirmed that the two cases have entirely disjoint shortage (scenario, hour)
sets at N=10 but identical total load-shed — a small-sample coincidence.
At N=50 the sets diverge in structure but the equal total MWh persists.

---

## 4. M1a diagnosis — naive peak-shaving heuristic

### What M1 (RA-1a) does

The M1 rule-based dispatch applies three priority levels every hour:

1. **Priority 1 (P1) — emergency discharge:** if thermal + VRE cannot
   cover load, discharge storage up to the shortfall.
2. **Priority 2 (P2) — proactive peak-shaving:** if net load exceeds the
   75th-percentile threshold but there is no current shortfall, discharge
   storage at full power.
3. **Priority 3 (P3) — valley-filling charge:** if net load is below the
   25th-percentile threshold and there is surplus generation, charge storage.

### What the debug run found

Script: `scripts/13_debug_m1_storage_sensitivity.jl`.
Output: `results/m1_debug/` (dispatch CSVs, priority stats, diagnosis.txt).

Cases compared: `storage120_p05_d4` (492 MW / 1,968 MWh) vs
`storage120_p20_d4` (1,966 MW / 7,864 MWh).  N = 5, seed = 42.

| Metric | p05_d4 | p20_d4 |
|--------|--------|--------|
| Storage capacity read correctly | 492 MW / 1,968 MWh | 1,966 MW / 7,864 MWh |
| P1 discharge (shortage-driven) | **0.0 MWh** | **0.0 MWh** |
| P2 discharge (proactive) | 138,384 MWh | 552,973 MWh |
| SOC ≈ 0 at shortage hours | **100%** | **100%** |
| Shortage (scenario, hour) sets identical | — | **true** |
| LOLH | 115.6 h/yr | 115.6 h/yr |

**Root cause:** The P2 rule fires at all 2,190 hours/yr (25% of hours)
where net load ≥ Q0.75 = 4,670 MW, regardless of generator availability.
A 4-hour battery (either 492 MW or 1,966 MW) is fully depleted within
~4 consecutive peak hours.  Shortage events (generator forced outages)
occur within or immediately following these peak periods, so storage SOC
is already zero when P1 fires.  P1 effectively never provides any energy.

**Verdict:** This is a **heuristic limitation**, not a data-loading bug.
Storage capacity is read correctly from each case's `storage.csv`.  The
physical dispatch differs (P2 volumes differ 4×), but the reliability
impact is identical because storage is always empty during shortage.

The identical RA-1a / M1 LOLH = 96.48 h/yr across all six 50-scenario
validation cases is the same failure mode at larger N.

### Implication for research design

M1 (RA-1a) is useful as a **cautionary baseline** that shows what happens
when peak-shaving heuristics are used without reserving emergency storage
capacity.  It is not a credible simple RA model.

This motivates:
- **RA-1b:** reserve-aware heuristic that prevents P2 from discharging
  storage below an emergency SOC floor.
- **RA-2:** event-window LP that solves storage dispatch only near
  risk periods identified by net-load and thermal-availability screening.

---

## Script summary

| Script | Purpose | Output folder | Status |
|--------|---------|---------------|--------|
| `scripts/09_calibrate_load_scaling.jl` | Scan load scale factors; find calibrated stress case | `results/load_scaling/` | Diagnostic — completed |
| `scripts/10_run_storage_matrix.jl` | Run RA-1a / M1 + RA-3 / M3 across 12 storage configurations at load_scale=1.20 | `results/storage_matrix/` | Diagnostic — completed |
| `scripts/11_debug_storage_cases.jl` | Investigate EUE anomaly between p10_d4 and p20_d2 | `results/storage_debug/` | Diagnostic — completed |
| `scripts/12_run_selected_storage_validation.jl` | 50-scenario re-validation of six selected storage cases | `results/storage_validation/` | Diagnostic — completed |
| `scripts/13_debug_m1_storage_sensitivity.jl` | Classify RA-1a / M1 dispatch actions; diagnose why RA-1a / M1 is insensitive to storage size | `results/m1_debug/` | Diagnostic — completed |

All scripts above belong to the **completed diagnostic phase**.  They are
preserved for reproducibility but are not part of the main forward experiment
design (Phases A–E described in `README.md`).
