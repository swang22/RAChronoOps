# Results Index

Generated output folders and their classification.  Large dispatch CSVs
are not committed to the repository; only small summary CSVs and text
summaries are tracked when needed for reproducibility.

For narrative interpretation of any result set, see
[docs/experiment_archive.md](experiment_archive.md).

---

## 1. Data summaries

**Folder:** `results/data_summary/`

**Contents:** system summary CSV and per-generator tables written by
`scripts/04_summarize_processed_data.jl`.

**Status:** Small files; useful as the source for paper data tables.
Regenerate with:
```bash
julia --project=. scripts/04_summarize_processed_data.jl
```

---

## 2. Load-scaling calibration

**Files:**
- `results/load_scaling/load_scaling_calibration.csv` — base five-point sweep (α = 1.00–1.20)
- `results/load_scaling/load_scaling_calibration_extended.csv` — extended six-point sweep (α = 1.20–1.35)

**Script:** `scripts/09_calibrate_load_scaling.jl`

**Status:** Diagnostic — completed.  Used to select `load_scale = 1.20`
as the calibrated stress case.  M3 LOLH ≈ 6–8 h/yr at that scale.

**Committed:** Yes (small summary CSVs).

---

## 3. Storage diagnostic matrix

**Folder:** `results/storage_matrix/`

**Files:**
- `storage_matrix_results.csv` — one row per (case, model); LOLH, EUE, runtime
- `storage_matrix_errors.csv` — M1 vs M3 delta and runtime ratio per case

**Script:** `scripts/10_run_storage_matrix.jl`

**Status:** Diagnostic — completed.  10-scenario run across 12 storage
configurations at `load_scale = 1.20`.  Revealed that M1 LOLH is
identical across all storage sizes (later confirmed as a heuristic
limitation by the M1 debug run).  Not the final main experiment.

**Committed:** Yes (small summary CSVs).

---

## 4. Storage debug

**Folder:** `results/storage_debug/`

**Files (per case):**
- `<case>/m3_dispatch.csv` — full hourly dispatch for all scenarios (large; not committed)
- `<case>/scenario_metrics.csv` — per-scenario LOLH, EUE, n\_events
- `<case>/shortage_hours.csv` — rows where load\_shed\_mw > 0

**Cross-case file:**
- `p10d4_vs_p20d2_shortage_comparison.csv`

**Script:** `scripts/11_debug_storage_cases.jl`

**Status:** Diagnostic — completed.  Investigated the EUE anomaly between
`storage120_p10_d4` and `storage120_p20_d2`, which produced identical
metrics at N=10.  Confirmed as a small-sample coincidence; the two cases
have disjoint shortage (scenario, hour) sets.

**Committed:** Summary and comparison CSVs only; large dispatch files
are not committed.

---

## 5. Selected storage validation

**Folder:** `results/storage_validation/`

**Files:**
- `selected_storage_validation_results.csv` — one row per (case, model); all metrics
- `selected_storage_validation_errors.csv` — M1 vs M3 delta, CI95, runtime ratio
- `selected_storage_validation_summary.txt` — auto-generated narrative answering six research sub-questions

**Script:** `scripts/12_run_selected_storage_validation.jl`

**Status:** Diagnostic — completed.  50-scenario validation of six
selected storage cases at `load_scale = 1.20`.  These are the authoritative
M3 benchmark numbers for the diagnostic phase.

Key results (M3, N=50, seed=42):

| Case | LOLH (h/yr) | EUE (MWh) |
|------|-------------|-----------|
| p05\_d4 | 28.96 | 9,925 |
| p10\_d2 | 20.06 | 9,670 |
| p10\_d4 | 6.22 | 2,889 |
| p10\_d8 | 2.78 | 543 |
| p20\_d2 | 4.90 | 2,889 |
| p20\_d4 | 0.30 | 215 |

**Committed:** Yes (all three files; no dispatch CSVs).

---

## 6. M1 debug

**Folder:** `results/m1_debug/`

**Files (per case):**
- `<case>_dispatch.csv` — full hourly dispatch with priority-action labels (large)
- `<case>_scenario_metrics.csv` — per-scenario priority tallies and SOC statistics
- `<case>_shortage_hours.csv` — rows where load\_shed\_mw > 0
- `<case>_priority_stats.csv` — P1/P2/P3 hour and MWh counts per scenario

**Cross-case files:**
- `cross_case_comparison.csv`
- `diagnosis.txt` — narrative root-cause diagnosis

**Script:** `scripts/13_debug_m1_storage_sensitivity.jl`

**Status:** Diagnostic — completed.  Confirms that M1 (RA-1a) priority-2
proactive discharge depletes storage SOC to zero before 100% of shortage
events; priority-1 emergency discharge fires zero times.  This is a
heuristic limitation, not a data-loading bug.  Motivates RA-1b and RA-2.

**Committed:** Summary CSVs and `diagnosis.txt`; large dispatch CSVs are
committed here because they are small (N=5 scenarios).

---

## 7. Future redesigned VRE experiments

**Folder:** `results/vre_method_comparison/`  *(planned)*

**Intended files:**
- `vre_case_summary.csv` — one row per VRE case; system-level penetration metrics
  computed at case-build time (see column list below).  Independent of dispatch method.
- `vre_method_comparison_results.csv` — one row per (VRE case, method); LOLH, EUE, runtime
- `vre_method_comparison_errors.csv` — error vs RA-3 benchmark, runtime ratio per (case, method)
- `accuracy_runtime_frontier.csv` — aggregated accuracy × runtime statistics for Figure 4

**`vre_case_summary.csv` columns:**

| Column | Description |
|--------|-------------|
| `case_name` | Case identifier (e.g. `VRE120_bal20`) |
| `load_scale` | Load multiplier (1.20 for all main cases) |
| `wind_scale` | Wind capacity scale factor relative to RTS-GMLC base |
| `solar_scale` | Solar capacity scale factor relative to RTS-GMLC base |
| `thermal_capacity_mw` | Total installed thermal capacity (MW) |
| `wind_capacity_mw` | Total installed wind capacity (MW) |
| `solar_capacity_mw` | Total installed solar capacity (MW) |
| `storage_power_mw` | Storage power rating (MW) |
| `storage_energy_mwh` | Storage energy rating (MWh) |
| `vre_capacity_share_incl_storage` | (P\_wind + P\_solar) / (P\_thermal + P\_wind + P\_solar + P\_storage) |
| `vre_capacity_share_no_storage` | (P\_wind + P\_solar) / (P\_thermal + P\_wind + P\_solar) |
| `available_vre_energy_share` | sum\_h(wind\_avail\_h + solar\_avail\_h) / sum\_h(load\_h) |
| `net_load_min_mw` | Minimum net load over all 8760 hours (MW) |
| `net_load_mean_mw` | Mean net load (MW) |
| `net_load_peak_mw` | Maximum net load (MW) |
| `negative_net_load_hours` | Hours where net load < 0 |
| `vre_exceeds_load_hours` | Hours where wind\_avail\_h + solar\_avail\_h > load\_h |

**Scripts:** `scripts/15_run_vre_experiment.jl`, `scripts/17_run_vre_all_methods.jl`

**Status:** Planned (Phase D).  Will contain the main experiment results
comparing RA-1a, RA-1b, RA-2, and RA-3 across six VRE penetration/profile
cases.

**Commit policy:** Commit summary and error CSVs; do not commit per-scenario
dispatch files.

---

## General commit policy for results

- **Commit:** small aggregate CSVs (< ~500 rows), text summaries, and
  `diagnosis.txt` files that are the primary output of a script.
- **Do not commit:** per-hour dispatch CSVs for large runs (8760 h × many
  scenarios × multiple models), intermediate debug files, or solver logs.
- Large dispatch files are regenerable from committed scripts and seed-fixed
  scenario generation; reproducibility does not require committing them.
- The `.gitignore` already excludes `results/cases/`, `results/runs/`,
  `results/dispatch/`, `results/logs/`, and `results/metrics/`.  New result
  subfolders that contain large files should be added to `.gitignore` as
  they are created.
