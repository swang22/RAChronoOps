# Results Index

Generated output folders and their classification.  Large dispatch CSVs,
HOPE case folders, and solver logs are not committed; only small aggregate
CSVs and text summaries are tracked.

For narrative interpretation, see
[docs/current_findings_synthesis.md](current_findings_synthesis.md).

---

## Commit policy

- **Commit:** aggregate CSVs (< ~500 rows), `summary.txt` files, and
  `hope_metrics_by_scenario.csv` / `hope_run_status.csv` files that are the
  primary output of a comparison script.
- **Do not commit:** full HOPE case folders (`exports/hope_model_cases/`),
  per-hour dispatch CSVs for large runs, hourly load-shed CSVs larger than
  ~10 k rows, solver logs, or Julia depot caches.
- Large output files are regenerable from committed scripts and seed-fixed
  scenario generation; reproducibility does not require committing them.

---

## 1. Data summaries

**Folder:** `results/data_summary/`

**Script:** `scripts/04_summarize_processed_data.jl`

**Status:** Diagnostic — completed.  System summary CSV; useful as source
for paper data tables.  Regenerate with:

```bash
julia --project=. scripts/04_summarize_processed_data.jl
```

**Committed:** Yes (small summary CSVs).

---

## 2. Load-scaling calibration

**Files:**
- `results/load_scaling/load_scaling_calibration.csv`
- `results/load_scaling/load_scaling_calibration_extended.csv`

**Script:** `scripts/09_calibrate_load_scaling.jl`

**Status:** Diagnostic — completed.  Established `load_scale = 1.20` as the
calibrated stress case.  M3 LOLH ≈ 6–8 h/yr at that scale.

**Committed:** Yes.

---

## 3. Storage diagnostic matrix

**Folder:** `results/storage_matrix/`

**Script:** `scripts/10_run_storage_matrix.jl`

**Status:** Diagnostic — completed.  10-scenario run across 12 storage
configurations at `load_scale = 1.20`.  Revealed that M1 LOLH is
insensitive to storage size (later confirmed as a heuristic limitation).

**Committed:** Yes (small summary CSVs).

---

## 4. Storage debug

**Folder:** `results/storage_debug/`

**Script:** `scripts/11_debug_storage_cases.jl`

**Status:** Diagnostic — completed.  Investigated EUE anomaly between
`storage120_p10_d4` and `storage120_p20_d2` (confirmed as small-sample
coincidence with disjoint shortage sets).

**Committed:** Summary and comparison CSVs only.

---

## 5. Selected storage validation

**Folder:** `results/storage_validation/`

**Script:** `scripts/12_run_selected_storage_validation.jl`

**Status:** Diagnostic — completed.  50-scenario M3 benchmark numbers for
six storage configurations at `load_scale = 1.20`.

**Key results (M3, N=50, seed=42):**

| Case | LOLH (h/yr) | EUE (MWh) |
|------|-------------|-----------|
| p05\_d4 | 28.96 | 9,925 |
| p10\_d2 | 20.06 | 9,670 |
| p10\_d4 | 6.22 | 2,889 |
| p10\_d8 | 2.78 | 543 |
| p20\_d2 | 4.90 | 2,889 |
| p20\_d4 | 0.30 | 215 |

**Committed:** Yes.

---

## 6. M1 debug

**Folder:** `results/m1_debug/`

**Script:** `scripts/13_debug_m1_storage_sensitivity.jl`

**Status:** Diagnostic — completed.  Confirms that M1 (RA-1a) priority-2
proactive discharge depletes storage SOC to zero before 100% of shortage
events; priority-1 emergency discharge fires zero times.

**Committed:** Summary CSVs and `diagnosis.txt`.

---

## 7. VRE method comparison

**Folder:** `results/vre_method_comparison/`

**Scripts:**
- `scripts/15_summarize_vre_cases.jl` — builds `vre_case_summary.csv`
- `scripts/16_run_vre_method_comparison.jl` — runs M1/M1b/M1c/M2/M3

**Status:** N=20 priority-case runs complete.

**Key results (M3 benchmark, N=20, seed=42):**

| Case | M3 LOLH (h) | M3 EUE (MWh) |
|------|------------|--------------|
| VRE120\_base | 6.2 | 2,479 |
| VRE120\_wind\_hvy | variable | variable |

M1/M1b: biased high.  M1c: matches M3 EUE/CVaR.
M2 (rm=1000, buf=48): matches M3 EUE to near-precision; LOLH within 0.2 h.

**Committed:** `vre_case_summary.csv`, `vre_method_comparison_results.csv`,
`vre_method_comparison_errors.csv`, `summary.txt`.

---

## 8. No-storage comparison

**Folder:** `results/no_storage_comparison/`

**Script:** `scripts/34_compare_no_storage_classic_vs_ed.jl`

**Status:** Complete (N=20, VRE120\_base and VRE120\_wind\_hvy).

**Key result:** MC-NoStorage = M3-NoStorage exactly.  Storage introduces the
temporal operation challenge; without it the classical capacity check is
exact.

| Case | MC-NoStorage EUE (MWh) | ΔEUE vs M3 |
|------|----------------------|------------|
| VRE120\_base | 31,017 | 0.00 MWh |
| VRE120\_wind\_hvy | 15,801 | 0.00 MWh |

**Committed:** Aggregate and per-scenario CSVs, `summary.txt`.

---

## 9. HOPE no-storage validation

**Folders:**
- `results/nostorage_hope_uc_comparison/base_n5/` — four-model aggregate
- `results/hope_nostorage_n5_pilot/` — HOPE run status and metrics

**Scripts:**
- `scripts/36_compare_nostorage_hope_uc_n5.jl`
- `scripts/27_collect_hope_results.jl`
- `scripts/29_run_hope_n5_pilot.jl`

**Status:** Complete (N=5, VRE120\_base\_nostorage, scenarios 1–5).

**Key result:** All four models produce identical LOLH and EUE.

| Model | LOLH (h) | EUE (MWh) | Runtime (s) |
|-------|----------|-----------|-------------|
| MC-NoStorage | 115.6 | 41,846 | 0.5 |
| M3-NoStorage | 115.6 | 41,846 | 40.0 |
| PCM-ED-NS (HOPE-ED-NoStorage) | 115.6 | 41,846 | 614.3 |
| PCM-UCED-NS (HOPE-UC-NoStorage) | 115.6 | 41,846 | 4,331.1 |

UC adds 7× runtime with zero reliability benefit in the no-storage case.

**Committed:** `hope_metrics_by_scenario.csv`, `hope_run_status.csv`,
`all_model_aggregate_metrics.csv`, `summary.txt`.

---

## 10. HOPE full-year storage-enabled base validation

**Folders:**
- `results/full_model_comparison_with_hope/base_n5/` — five-model N=5
- `results/hope_smoke_runs/` — HOPE ED/UC run outputs

**Scripts:**
- `scripts/25_build_hope_full_year_cases.jl`
- `scripts/29_run_hope_n5_pilot.jl`
- `scripts/27_collect_hope_results.jl`
- `scripts/30_compare_all_models_hope_n5.jl`

**Status:** Complete (VRE120\_base, N=5 and N=20).

**Key result (VRE120\_base, N=20):**

| Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | Runtime (s) |
|-------|----------|-----------|-----------|-------------|
| PCM-ED (HOPE-ED) | 6.2 | 2,479 | 9,783 | 2,356 |
| PCM-UCED (HOPE-UC) | 7.2 | 2,479 | 9,783 | 11,438 |

PCM-UCED uses real Pmin/ramp/startup/min-up/down from RTS-GMLC.
PCM-UCED increases LOLH by ~1 h but leaves EUE unchanged.

**Committed:** `all_model_aggregate_metrics.csv`, `summary.txt`.

---

## 11. Wind-heavy HOPE-UC profile check

**Folders:**
- `results/wind_hvy_hope_uc_comparison/n5/` — five-model aggregate
- `results/hope_wind_hvy_n5_pilot/` — HOPE run status and metrics

**Script:** `scripts/37_compare_wind_hvy_hope_uc_n5.jl`

**Status:** Complete (VRE120\_wind\_hvy, N=5, scenarios 1–5).

**Key result:**

| Model | LOLH (h) | EUE (MWh) | Runtime (s) |
|-------|----------|-----------|-------------|
| M1c | 4.4 | 1,113 | 0.6 |
| M2 | 3.8 | 1,113 | 2.5 |
| M3 | 4.4 | 1,113 | 44.3 |
| PCM-ED (HOPE-ED) | 3.8 | 1,113 | 588 |
| PCM-UCED (HOPE-UC) | 4.2 | 1,113 | 2,712 |

EUE identical across all five models (exact match per scenario).
PCM-UCED shifts LOLH +0.4 h vs PCM-ED (same temporal redistribution
pattern as base case; milder because fewer tight scenarios).

**Committed:** `all_model_aggregate_metrics.csv`, `all_model_metrics_by_scenario.csv`,
`errors_vs_m3.csv`, `errors_vs_hope_ed.csv`, `summary.txt`,
`hope_metrics_by_scenario.csv`, `hope_run_status.csv`.

---

## 12. M1d within-event allocation comparison

**Folder:** `results/m1d_storage_heuristic_comparison/`

**Script:** `scripts/38_compare_m1d_storage_heuristics.jl`

**Status:** Complete (VRE120\_base and VRE120\_wind\_hvy, N=20, seed=42).

**Key results:**

| Model | LOLH (h) | EUE (MWh) | RT (s) | Case |
|-------|----------|-----------|--------|------|
| M1c | 6.0 | 2,479 | 1.3 | VRE120\_base |
| M1d\_earliest | 6.0 | 2,479 | 1.0 | VRE120\_base |
| M1d\_largest | 8.4 | 2,479 | 1.2 | VRE120\_base |
| M2 | 5.8 | 2,479 | 8.7 | VRE120\_base |
| M3 | 6.0 | 2,479 | 191 | VRE120\_base |

EUE is identical per scenario across all modes (ΔEUE = 0.00 MWh exactly).
M1d\_largest has higher LOLH because within-event reallocation to the largest
shortfall hours leaves smaller shortfall hours partially served, spreading the
same energy deficit across more shedding hours.

**Committed:** `m1d_aggregate_metrics.csv`, `m1d_metrics_by_scenario.csv`,
`m1d_errors_vs_m3.csv`, `summary.txt`.

---

## 13. M1 / M1b N=20 paper consistency run

**Folder:** `results/m1_m1b_n20_paper/`

**Script:** `scripts/41_run_m1_m1b_n20_for_paper.jl`

**Status:** Complete (VRE120\_base and VRE120\_wind\_hvy, N=20, seed=42).

**Purpose:** Replaces the old N=3 diagnostic pilot data so the paper
storage-method comparison table (Table III) is internally consistent at N=20.
M1 and M1b are retained as cautionary failure cases; they are not used as
the primary RA estimate.

**Key results (N=20, seed=42):**

| Case | Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | ΔEUE vs M3 |
|------|-------|----------|-----------|-----------|------------|
| VRE120\_base | M1 | 95.4 | 31,017 | 51,937 | +28,538 |
| VRE120\_base | M1b | 83.5 | 28,272 | 49,455 | +25,793 |
| VRE120\_wind\_hvy | M1 | 52.4 | 15,801 | 26,871 | +15,153 |
| VRE120\_wind\_hvy | M1b | 25.0 | 8,982 | 20,155 | +8,334 |

M1 and M1b substantially overestimate reliability risk because proactive
peak-shaving discharge depletes storage SOC before shortage events.

**Committed:** `m1_m1b_aggregate_metrics.csv`, `m1_m1b_metrics_by_scenario.csv`,
`m1_m1b_errors_vs_m3.csv`, `summary.txt`.

---

## 14. Storage-energy sufficiency bound

**Folder:** `results/storage_energy_sufficiency_bound/`

**Script:** `scripts/39_storage_energy_sufficiency_bound.jl`

**Documentation:** `docs/storage_energy_sufficiency_bound.md`

**Status:** Complete (VRE120\_base and VRE120\_wind\_hvy, N=20, seed=42, lookback=72 h).

**Key results:**

| Case | Pre-storage EUE | Bound EUE | M3 EUE | Bound − M3 | Sufficiency ratio |
|------|----------------|-----------|--------|-----------|-------------------|
| VRE120\_base | 31,017 MWh | 2,479 MWh | 2,479 MWh | 0.00 MWh | 0.941 |
| VRE120\_wind\_hvy | 15,801 MWh | 648 MWh | 648 MWh | 0.00 MWh | 0.972 |

The bound matches M3 EUE exactly per scenario in both cases.
In the tested RTS-GMLC cases, the binding constraint is storage energy (MWh)
rather than power (MW).
VRE120\_wind\_hvy has a higher sufficiency ratio because its shortage events
are smaller relative to the storage budget.

**Committed:** `event_level_storage_bound.csv`, `scenario_level_storage_bound.csv`,
`bound_vs_models.csv`, `summary.txt`.

---

## 15. Storage robustness sweep

**Folders:**
- `data_processed/storage_robustness_cases/` — 18 variant case directories
- `results/storage_robustness/case_variant_summary.csv` — variant metadata
- `results/storage_robustness_sweep/` — M1c/M2/M3/bound results

**Scripts:**
- `scripts/42_build_storage_robustness_cases.jl` — builds variant cases
- `scripts/43_run_storage_robustness_sweep.jl` — runs M1c/M2/M3/bound sweep

**Status:** Complete (18 variants, N=20, seed=42).

**Variants:** Experiment A (duration 2/4/8/12h), B (power 0.5×/1×/2×),
C (load stress 1.225/1.25 + combos), across VRE120\_base and
VRE120\_wind\_hvy source cases.

**Key results:**

| Metric | Result |
|--------|--------|
| M1c−M3 EUE max \|Δ\| | 0.0 MWh (all 18 variants) |
| M2−M3 EUE max \|Δ\| | 0.0 MWh (all 18 variants) |
| M2 LOLH vs M3 max \|Δ\| | 1.5 h (dur2h + load stress) |
| Sufficiency ratio range | 0.681 – 1.000 |
| M1c speedup vs M3 | ×101 (mean) |
| M2 speedup vs M3 | ×22 (mean) |

EUE convergence holds at suf\_ratio = 0.681 (short 2h storage + load
stress): the bound is tight enough that any dispatch preserving energy for
shortfall hours achieves the same residual EUE.

**Committed:** `metrics_all.csv`, `scenario_eue_all.csv`,
`bound_comparison_all.csv`, `runtime_all.csv`, `summary.txt`,
`case_variant_summary.csv`.

---

## 16. Sampling convergence and event-shape validation

**Folder:** `results/sampling_convergence/`

**Script:** `scripts/44_run_sampling_convergence.jl`

**Status:** Complete (VRE120\_base, N=20/50/100/200, seed=42, nested design).

**Purpose:** Validate that the method-error result (M1c = M2 = M3 EUE) is
not a small-sample artifact; quantify CI95 shrinkage with N; and add
event-shape metrics (shortage duration, event energy, shortfall severity)
beyond LOLH and EUE.

**Key results:**

| Metric | Result |
|--------|--------|
| M1c−M3 EUE max \|Δ\| across all N | 0.0 MWh |
| M1c−M3 LOLH max \|Δ\| across all N | 0.00 h (exact match) |
| M2−M3 EUE max \|Δ\| across all N | 0.0 MWh |
| M2−M3 LOLH range across all N | −0.2 to −0.45 h |
| CI95 EUE shrinkage N=20→N=200 | 2.3× (1500→643 MWh; heavy-tailed) |
| CI95 LOLH shrinkage N=20→N=200 | 3.0× (3.25→1.08 h; near 1/√N = 3.2×) |
| Method error vs CI95 | \|error\| ≪ CI95 at all N |
| M1c speedup vs M3 | ×148–205× across N |
| M2 speedup vs M3 | ×19–24× across N |

EUE convergence holds at N=20, 50, 100, and 200 with nested common random
numbers; the result is not a small-sample coincidence.  CI95 half-widths
shrink as expected with √N, confirming that N=20 provides adequate precision
for method comparison at the tested stress levels.  Event-shape metrics
(mean event duration, p95 event energy, p95 shortfall) are consistent across
M1c, M2, and M3.

**Committed:** `convergence_aggregate_metrics.csv`,
`convergence_event_shape_metrics.csv`,
`convergence_errors_vs_full_ed.csv`,
`convergence_runtime_summary.csv`,
`convergence_summary.txt`.

---

## 17. Paper figures

**Folder:** `figures/`

**Scripts:** `scripts/45_make_paper_figures.py` (main figures), `scripts/47_make_event_operation_figure.py` (ED vs UC comparison; Python, powergenome conda env), `scripts/48_generate_storage_operation_dispatch.jl` + `scripts/49_make_storage_operation_figure.py` (M1c/M2/M3 storage operation; Julia + Python), `scripts/50_make_storage_operation_compact.py` (compact version for main text; Python, powergenome conda env), `scripts/51_recharge_window_diagnostic.jl` + `scripts/52_make_recharge_window_figure.py` (recharge-window diagnostic; Julia + Python), `scripts/53_storage_capacity_credit.jl` + `scripts/54_make_capacity_credit_figure.py` (storage capacity-credit diagnostic; Julia + Python)

**Status:** Complete (8 figures + compact variant + LaTeX captions). Updated 2026-05-26.

**Run command:**
```
D:\Users\swang16\AppData\Local\Programs\Python\Python312\python.exe \
  scripts/45_make_paper_figures.py
```

**Figures generated:**

| File | Content | Placement |
|------|---------|-----------|
| `method_hierarchy.pdf/.png` | Figure 1: method hierarchy flow diagram | Main text |
| `eue_by_method.pdf/.png` | Figure 2: EUE by method — two-panel (balanced / wind-heavy VRE) | Main text |
| `runtime_accuracy_frontier.pdf/.png` | Figure 3: accuracy–runtime log–log scatter (legend upper-right, M1/M1b de-emphasized) | Main text |
| `event_shape_comparison.pdf/.png` | Figure 4: four-panel event-shape metrics for balanced VRE | Main text (new) |
| `sampling_convergence.pdf/.png` | Appendix: EUE estimates + CI95 shrinkage by N | Appendix A |
| `robustness_eue_error.pdf/.png` | Appendix: M3 EUE across 11 storage robustness variants (no internal annotation) | Appendix A |
| `event_operation_comparison.pdf/.png` | Appendix: representative shortage-event operation (Scenario 15, ED vs UC, h4984-4988) | Appendix B |
| `storage_operation_comparison.pdf/.png` | Appendix: 3-panel storage operation (load shed, discharge, SOC) for M1c/M2/M3 — Scenario 15, h4959-5048 | Appendix B |
| `storage_operation_comparison_compact.pdf/.png` | Main text Figure 5: compact 3-panel storage operation, local window rel -8 to +10 around first shedding hour | Main text |
| `recharge_window_diagnostic.pdf/.png` | Recharge-window availability diagnostic: share of event EUE with comparable M3 pre-event charge within 6/12/24/48/72/168 h (not a physical feasibility proof) | Supporting |
| `storage_capacity_credit_comparison.pdf/.png` | Two-panel: (a) PJM-style storage reliability value ratio, (b) EFC in MW; grouped bars for balanced/wind-heavy VRE | Supporting |
| `figure_captions.md` | LaTeX-ready captions for all figures | — |

**Key changes (2026-05-25):**
- `eue_by_method`: replaced single grouped chart with two panels (one per VRE portfolio);
  Full-Year ED reference dashed line in each panel; log scale; emphasizes accuracy not severity.
- `runtime_accuracy_frontier`: legend moved to upper-right (empty region); M1/M1b markers
  smaller and lighter; zero-error annotation repositioned above M3 point.
- `robustness_eue_error`: removed internal green annotation banner; shorter title;
  explanatory text moved to caption only.
- `event_shape_comparison` (new): 2×2 panel bar chart for balanced VRE — events/yr, mean
  event duration, max event duration, max shortfall — for M1c/M2/M3/HOPE-UC.

**Committed:** all PDF, PNG, and markdown files listed above; `scripts/45_make_paper_figures.py`.

---

## 18. Multi-metric reporting tables (NEUE and event-shape)

**Folder:** `results/paper_tables/`

**Script:** `scripts/46_make_multimetric_tables.py` (Python 3.12)

**Status:** Complete (2 CSVs).

### 18a. `multimetric_main_results.csv`

Combines no-storage validation, storage method comparison, and PCM validation
results with NEUE (ppm) added.  Annual load back-computed from M3 N=20 row in
`convergence_aggregate_metrics.csv`: ≈ 45,074 GWh/yr (load_scale=1.2 × RTS-GMLC).

Columns: `section`, `case`, `n_scenarios`, `method`, `LOLH_h_per_yr`,
`EUE_MWh_per_yr`, `NEUE_ppm`, `CVaR_EUE_MWh`, `runtime_s_per_scenario`.

Key NEUE values (balanced VRE, storage-enabled):
- Naive storage MCS: 688 ppm
- SOC-floor storage MCS: 627 ppm
- Emergency-only / Event-window / Full-year ED: 55 ppm

### 18b. `event_shape_summary.csv`

Event-shape metrics for M1c, M2, M3, PCM-ED, PCM-UCED.
Balanced VRE uses N=20 (from `full_model_comparison_with_hope/base_n20/`).
Wind-heavy VRE uses N=5 (from `wind_hvy_hope_uc_comparison/n5/`).
PCM max_duration and p95_duration for wind-heavy are computed from
`hope_wind_hvy_n5_pilot/hope_load_shed_hourly.csv`.

Columns: `case`, `n_scenarios`, `method`, `events_per_yr`,
`mean_event_duration_h`, `max_event_duration_h`, `p95_event_duration_h`,
`mean_event_energy_mwh`, `max_hourly_shortfall_mw`,
`mean_shortfall_when_shedding_mw`, `EUE_MWh_per_yr`, `NEUE_ppm`.

Key finding: Emergency-only storage MCS and full-year ED produce identical
event shapes (balanced VRE: 2.0 events/yr, 3.0 h mean, 7 h max).
Event-window MCS produces more, shorter events (2.9/yr, 2.0 h mean) with
the same EUE — LP degeneracy distributes deficit across more hourly slots.
PCM-UCED produces even more, shorter events (4.1/yr, 1.8 h mean) due to
unit-commitment constraints.

---

## 19. Normalized marginal storage capacity-credit diagnostic

**Folder:** `results/paper_tables/`

**Deprecated:** The previous 100 MW average reliability-value diagnostic (scripts 53/54,
`storage_capacity_credit_comparison.csv`) has been deprecated.  The revised diagnostic
computes normalized marginal CC using a 1 MW storage and 1 MW perfect-resource increment.

**Scripts:**
- `scripts/55_marginal_capacity_credit.jl` — Julia; runs marginal storage dispatch at δ=1,5,10 MW with analytical perfect-resource CRN
- `scripts/56_make_marginal_cc_figure.py` — Python (powergenome env); two-panel grouped bar chart

**Status:** Complete (2026-05-26).

### 19a. `storage_marginal_capacity_credit.csv`

Normalized marginal capacity credit for M1c, M2, M3 in both VRE portfolios at
δ = 1, 5, 10 MW (18 rows).  Analytical perfect-resource EUE guarantees common random
numbers; one extra dispatch run per (method, case, δ) needed for δ_storage.

Columns: `case`, `baseline_type`, `delta_mw`, `method`, `eue_baseline_mwh`,
`eue_plus_storage_mwh`, `eue_plus_perfect_mwh`, `delta_eue_storage_mwh`,
`delta_eue_perfect_mwh`, `normalized_marginal_cc`, `cc_error_vs_full_year_ed`.

Key results (N=20, seed=42, δ = 1 MW primary):
- Balanced VRE: M1c CC = 1.116, M2 CC = 1.155 (+0.039 vs M3), M3 CC = 1.116
- Wind-heavy VRE: M1c CC = 1.101, M2 CC = 1.270 (+0.169 vs M3), M3 CC = 1.101

**Committed:** Yes.

### 19b. `figures/storage_marginal_capacity_credit.pdf/.png`

Two-panel figure: (a) δ = 1 MW primary — normalized marginal capacity credit
(marginal reliability contribution relative to 1 MW perfect firm capacity);
(b) δ = 10 MW finite-difference check.  Grouped bars for balanced VRE (blue) and
wind-heavy VRE (green).  Dashed reference lines at M3 values.

**Committed:** Yes.

---

## 20. HOPE-PCM-ED marginal CC validation

**Folder:** `results/paper_tables/`

**Scripts:**
- `scripts/57_hope_marginal_cc_validation.jl` — Julia; runs 75 HOPE-ED marginal-storage scenarios (60 VRE120_base N=20, 15 VRE120_wind_hvy N=5); also re-runs M3 at N=5 for wind-heavy matched comparison
- `scripts/58_make_hope_marginal_cc_figure.py` — Python (powergenome env); two-panel bar chart

**Status:** Complete (2026-05-27).

### 20a. `hope_pcm_ed_marginal_cc_validation.csv`

Normalized marginal CC for HOPE-PCM-ED and Full-year ED (M3) across both cases and
δ = 1, 5, 10 MW (12 rows).

Columns: `case`, `model`, `n_scen`, `delta_mw`, `eue_baseline_mwh`,
`eue_plus_storage_mwh`, `eue_plus_perfect_mwh`, `delta_eue_storage_mwh`,
`delta_eue_perfect_mwh`, `normalized_marginal_cc`, `cc_error_vs_full_year_ed`,
`cc_greater_than_one`.

Key results (N=20 base, N=5 wind-heavy, δ = 1 MW):
- Balanced VRE: M3 CC = 1.116, HOPE-PCM-ED CC = 1.063 (diff = −0.054); both > 1
- Wind-heavy VRE: M3 CC = 1.171, HOPE-PCM-ED CC = 1.356 (diff = +0.185); both > 1

ΔEUEstor is identical between M3 and HOPE-PCM-ED.  ΔEUEperf differs because LP
degeneracy (barrier vs vertex solutions) produces different hourly load-shed
distributions at the same total EUE.

**Committed:** Yes.

### 20b. `figures/hope_pcm_ed_marginal_cc_validation.pdf/.png`

Two-panel figure (a: Balanced VRE N=20, b: Wind-heavy VRE N=5).  Grouped bars for
Full-year ED (M3) and HOPE-PCM-ED.  Horizontal dashed reference at 1.0.
Sensitivity markers (δ = 5 and 10 MW) overlaid.

**Committed:** Yes.
