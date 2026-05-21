# RAChronoOps

RAChronoOps evaluates how much operational detail is needed inside
probabilistic sequential Monte Carlo resource adequacy assessment for
high-VRE, storage-rich power systems.  The project compares fast
RA-compatible dispatch approximations against full-year economic dispatch
and production-cost model (PCM) benchmarks.

Single-zone copper-plate system based on the RTS-GMLC dataset.

## Method hierarchy

| Label | Paper name | Method | Optimization | Status |
|-------|-----------|--------|--------------|--------|
| MC-NoStorage | Traditional MC | Traditional hourly sequential MC without storage | None | Implemented — no-storage baseline |
| RA-1a / M1 | Naive Storage MC | Sequential MC + naive peak-shaving storage heuristic | None | Implemented — cautionary baseline |
| RA-1b / M1b | Reserve-Floor MC | Sequential MC + reserve-aware storage heuristic | None | Implemented and validated |
| RA-1c / M1c | Emergency-Only MC | Sequential MC + emergency-only storage heuristic, system-surplus charging | None | Implemented and validated |
| M1c\_VREOnly | VRE-Surplus MC | Same as M1c but charges from VRE surplus only | None | Implemented — appendix sensitivity |
| RA-1d / M1d | Risk-Hour MC | Sequential MC + risk-hour allocation heuristic (earliest\_first / largest\_first) | None | Implemented — within-event allocation study |
| RA-2 / M2 | Event-Window LP-MC | Sequential MC + screened event-window LP near risk periods | Small LPs | Implemented and validated |
| RA-3 / M3 | Full-Year ED-MC | Sequential MC + full-year ED LP per scenario | LP (Gurobi) | Implemented — benchmark |
| HOPE-ED | PCM-ED | Full-year HOPE ED LP (PCM economic dispatch mode) | LP (Gurobi) | Validated — matches M3 |
| HOPE-UC / M4 | PCM-UCED | Full-year HOPE UC/PCM with real Pmin/ramp/startup/min-up/down | MILP (Gurobi) | Validated — N=5 and N=20 |

All implemented methods use **common random numbers**: one shared
`ScenarioSet` of thermal outage draws is passed to every method, so
reliability metric differences are attributable to dispatch strategy alone.

## Quick start

```bash
# 1. Install Julia dependencies
julia --project=. -e "using Pkg; Pkg.instantiate()"

# 2. Download RTS-GMLC data (requires git on PATH)
julia --project=. scripts/00_get_rts_gmlc_data.jl

# 3. Build the processed single-zone dataset
julia --project=. scripts/01_build_single_zone_rts.jl

# 4. Build VRE experiment cases
julia --project=. scripts/06_build_experiment_cases.jl

# 5. Build no-storage case variants
julia --project=. scripts/33_build_no_storage_cases.jl

# 6. No-storage MC vs ED baseline comparison (N=20)
julia --project=. scripts/34_compare_no_storage_classic_vs_ed.jl \
  --cases VRE120_base,VRE120_wind_hvy --n-scenarios 20 --seed 42

# 7. Export HOPE full-year cases (5 scenarios, ED + UC)
julia --project=. scripts/25_build_hope_full_year_cases.jl \
  --case VRE120_base --modes ED,UC --n-scenarios 20 --seed 42

# 8. HOPE no-storage four-model comparison (requires script 29 + 27 first)
julia --project=. scripts/36_compare_nostorage_hope_uc_n5.jl

# 9. Wind-heavy five-model storage-enabled HOPE-UC comparison
julia --project=. scripts/37_compare_wind_hvy_hope_uc_n5.jl
```

## Current completed experiments

The full experiment sequence is complete.  Clean narrative: traditional
sequential MC is valid without storage; storage introduces intertemporal
SOC coupling that makes reliability estimates sensitive to dispatch
assumptions; M1c and M2 recover M3/HOPE EUE at much lower runtime; HOPE-UC
mainly changes LOLH/event timing, not EUE.  A storage-energy sufficiency
bound explains why EUE convergence across M1c/M1d/M2/M3 is observed in the
tested RTS-GMLC cases: in these configurations, the binding constraint is
storage energy availability (MWh) rather than dispatch complexity.

### 1. No-storage MC validation

MC-NoStorage = M3-NoStorage exactly for VRE120\_base and VRE120\_wind\_hvy
at N=20.  For VRE120\_base\_nostorage at N=5, all four models agree:
MC-NoStorage = M3-NoStorage = PCM-ED-NS (HOPE-ED-NoStorage) = PCM-UCED-NS (HOPE-UC-NoStorage)
(ΔEUE = 0.00 MWh, ΔLOLH = 0.0 h).

**Interpretation:** traditional sequential MC is valid in the classic
no-storage RA setting.  Without storage there is no intertemporal state
variable, so LP and MILP dispatch collapse to the same feasible set as
the classical capacity check.

Scripts: `scripts/33_build_no_storage_cases.jl`,
`scripts/34_compare_no_storage_classic_vs_ed.jl`,
`scripts/36_compare_nostorage_hope_uc_n5.jl`

Results: `results/no_storage_comparison/`, `results/nostorage_hope_uc_comparison/`

### 2. Storage-aware MC method comparison

| Model | LOLH vs M3 | EUE vs M3 | Runtime |
|-------|-----------|-----------|---------|
| M1 (naive heuristic) | High bias | High bias | ~1 s/scenario |
| M1b (reserve-aware) | Reduced bias | Reduced bias | ~1 s/scenario |
| M1c (emergency-only) | Matches M3 | Matches M3 | ~1–2 s/scenario |
| M2 (event-window LP) | Within 0.2 h | Matches M3 | 5–10 s/scenario |
| M3 (full-year ED) | — | — (benchmark) | ~9–10 s/scenario |

M1 / M1b overestimate reliability risk (naive peak-shaving depletes storage
before shortage events).  M1c and M2 recover M3 EUE/CVaR closely.

Recommended M2 config: `risk_margin_mw=1000, window_buffer_hours=48`.

Scripts: `scripts/14_run_ra1b_validation.jl`,
`scripts/16_run_vre_method_comparison.jl`, `scripts/30_compare_all_models_hope_n5.jl`

### 3. PCM full-year validation (PCM-ED and PCM-UCED)

PCM-ED (HOPE-ED internally) matches M3 once ED-mode ramp constraints are
disabled (ΔEUE < 1 MWh).
PCM-UCED (HOPE-UC internally) uses real Pmin, ramp rates, startup costs,
and min up/down times from the RTS-GMLC dataset.

In tested cases (VRE120\_base N=20; VRE120\_wind\_hvy N=5), PCM-UCED mainly
changes LOLH/event timing, not EUE:

| Case | Model | LOLH (h) | EUE (MWh) | Runtime (s) |
|------|-------|----------|-----------|-------------|
| VRE120\_base | PCM-ED | 6.2 | 2,479 | 2,356 |
| VRE120\_base | PCM-UCED | 7.2 | 2,479 | 11,438 |
| VRE120\_wind\_hvy | PCM-ED | 3.8 | 1,113 | 588 |
| VRE120\_wind\_hvy | PCM-UCED | 4.2 | 1,113 | 2,712 |

**Runtime note:** PCM-UCED is 4–5× slower than PCM-ED with zero EUE
benefit in the tested cases.  UC is worth running only when storage is
present (storage SOC is the intertemporal link that activates UC timing
effects).

Scripts: `scripts/25_build_hope_full_year_cases.jl`,
`scripts/29_run_hope_n5_pilot.jl`, `scripts/27_collect_hope_results.jl`,
`scripts/37_compare_wind_hvy_hope_uc_n5.jl`

Results: `results/wind_hvy_hope_uc_comparison/`, `results/hope_wind_hvy_n5_pilot/`

### 4. Storage-energy sufficiency bound (theoretical diagnostic)

The sufficiency bound derives a per-scenario ceiling on EUE reduction from
storage, given surplus energy available in a 72-hour lookback window before
each shortage event:

```
coverage_bound = min(pre_event_EUE,
                     feasible_discharge_energy,   -- SOC × η_dis after charging
                     power_limited_coverage)       -- Σ min(shortfall[h], power_mw)
```

| Case | Pre-storage EUE | Bound/M3 EUE | Sufficiency ratio |
|------|----------------|-------------|-------------------|
| VRE120\_base | 31,017 MWh | 2,479 MWh | 0.941 |
| VRE120\_wind\_hvy | 15,801 MWh | 648 MWh | 0.972 |

The bound matches M3 EUE exactly per scenario (ΔEUE = 0.00 MWh).
Binding constraint in tested cases: storage energy (MWh), not power (MW).

**Key insight:** M1c, M1d\_earliest, M2, and M3 all achieve the bound because
they satisfy its two sufficient conditions (charge from surplus; discharge only
at shortfall hours).  M1/M1b violate condition 2 by proactively discharging,
depleting SOC before shortage events and moving away from the bound.

**Why LOLH can differ even when EUE matches:** EUE is set by the storage
energy budget; LOLH counts hours with any positive load shed.  M1d\_largest
reallocates discharge to the highest-shortfall hours first, leaving smaller
shortfall hours partially served (more LOLH, same EUE).  LP degeneracy and
HOPE-UC commitment constraints produce the same effect for different reasons.

Scripts: `scripts/38_compare_m1d_storage_heuristics.jl`,
`scripts/39_storage_energy_sufficiency_bound.jl`

Results: `results/m1d_storage_heuristic_comparison/`,
`results/storage_energy_sufficiency_bound/`

Documentation: `docs/storage_energy_sufficiency_bound.md`

Full numeric results and per-script output paths:
[docs/results_index.md](docs/results_index.md) and
[docs/current_findings_synthesis.md](docs/current_findings_synthesis.md).

---

## Archived diagnostics

The following early experiments informed the current design but are no
longer the primary results:

- **Rolling-window M2** (`M2RollingWindow.jl`): solves one LP per hour per
  scenario — no runtime advantage over M3.  Replaced by the event-window
  M2 (`M2EventWindowLP.jl`).
- **HOPE stress-week validation** (Phase E placeholder): the project moved
  to full-year HOPE ED/UC, making the stress-week-only approach unnecessary.
- **RA-1a / M1 diagnosis**: priority-2 proactive discharge depletes SOC to
  zero before 100% of shortage events; motivates M1b and M1c.

See [docs/experiment_archive.md](docs/experiment_archive.md) for
full diagnostic results.

---

## Preparing the full RTS-GMLC dataset

The official RTS-GMLC dataset is hosted at
https://github.com/GridMod/RTS-GMLC.

```bash
# Clone RTS-GMLC into data_raw/RTS-GMLC/ (idempotent)
julia --project=. scripts/00_get_rts_gmlc_data.jl

# Build the 8760-hour single-zone processed dataset
julia --project=. scripts/01_build_single_zone_rts.jl

# Optionally verify: print system summary + write results/data_summary/ CSVs
julia --project=. scripts/04_summarize_processed_data.jl
```

### What the builder does

`BuildRTSSingleZone.jl` aggregates the RTS-GMLC three-area system into a
single copper-plate zone:

| Step | Detail |
|------|--------|
| Generator fleet | 133 units: 73 thermal + 60 VRE (4 WIND, 25 PV, 31 RTPV) |
| Excluded types | HYDRO (19), ROR (1), CSP (1), STORAGE (1), SYNC\_COND (3) — logged as warnings |
| Heat rate | `HR_avg_0` column (BTU/kWh) ÷ 1000 → MMBTU/MWh; `variable_cost = VOM + HR × fuel_price` |
| Load | `DAY_AHEAD_regional_Load.csv` columns 5+ (three regions) summed per hour, truncated to 8760 h |
| Wind CF | `WIND/DAY_AHEAD_wind.csv` MW ÷ total wind capacity (2507.9 MW), clamped to [0, 1] |
| Solar CF | `PV/DAY_AHEAD_pv.csv` + `RTPV/DAY_AHEAD_rtpv.csv` MW ÷ total solar capacity (2715.9 MW) |
| Storage | One aggregate 4-hour battery: 10% of peak load power, η = √0.90 per half-trip |
| Validation | Strict (8760 h required) when RTS data detected; lenient for synthetic fallback |

### Expected output (RTS-GMLC)

After running script 01, `results/data_summary/system_summary.csv` should show:

| Metric | Value |
|--------|-------|
| n\_hours | 8760 |
| Peak load | 8191.8 MW |
| Annual load | 37,561 GWh |
| Thermal capacity | 8076 MW (73 units) |
| Wind capacity | 2508 MW (CF 32.4%) |
| Solar capacity | 2716 MW (CF 24.7%) |
| Storage | 819 MW / 3276 MWh (4 h) |

### Synthetic fallback

If RTS-GMLC data is absent (e.g., CI or first checkout without step 00),
the builder writes a deterministic 168-hour system so that tests and scripts
still run.

---

## Building experiment cases

`scripts/06_build_experiment_cases.jl` writes one subfolder per case under
`data_processed/cases/`.

| Experiment group | Scale factors applied | Status |
|-----------------|----------------------|--------|
| Load scaling (×5) | `load_scale` ∈ {1.00, 1.05, 1.10, 1.15, 1.20} | Diagnostic — completed |
| Storage matrix (×12) | `storage_power_pct_peak` ∈ {5%, 10%, 20%} × `storage_duration_hours` ∈ {2, 4, 8, 12} | Diagnostic — completed |
| VRE penetration/profile (×6) | wind/solar scale pairs — see docs/redesigned_experiment_plan.md | Main experiment — completed |

```bash
julia --project=. scripts/06_build_experiment_cases.jl
```

---

## Reliability metric taxonomy

All implemented methods compute a common set of metrics stored in
`MetricsResult` (see `src/metrics/ReliabilityMetrics.jl`).

### Frequency of shortfall

| Metric | Field | Definition |
|--------|-------|-----------|
| LOLH | `lolh` | Mean loss-of-load hours per year (h/yr) |
| LOLP | `lolp` | Loss-of-load probability = LOLH / n\_hours |
| LOLE days | `lole_days` | Mean days per year with ≥ 1 shortage hour |

### Energy not served

| Metric | Field | Definition |
|--------|-------|-----------|
| EUE | `eue` | Expected unserved energy (MWh/yr) |
| nEUE | `neue` | EUE / annual load energy (fraction; report in ppm = × 10⁶) |

### Shortage event structure

| Metric | Field | Definition |
|--------|-------|-----------|
| Event count | `n_shortage_events` | Mean number of distinct contiguous shortage events per scenario |
| Mean duration | `mean_shortage_duration` | Mean event duration (h) |
| Max duration | `max_shortage_duration` | Maximum event duration across all scenarios (h) |
| p95 duration | `p95_shortage_duration` | 95th percentile of event duration pooled across scenarios (h) |

### Shortfall severity

| Metric | Field | Definition |
|--------|-------|-----------|
| Max shortfall | `max_shortfall` | Maximum single-hour load shed across all scenario-hours (MW) |
| Mean shortfall | `mean_shortfall_when_shedding` | Mean load shed conditional on shed > 0 (MW) |

### Tail risk (scenario distribution)

| Metric | Field | Definition |
|--------|-------|-----------|
| p50/p90/p95/p99 EUE | `p{q}_scenario_eue` | Percentiles of the per-scenario EUE distribution (MWh) |
| CVaR-EUE | `cvar_eue` | Mean of the top 5% of per-scenario EUEs (MWh) |

### Monte Carlo uncertainty

| Metric | Field | Definition |
|--------|-------|-----------|
| LOLH CI95 | `lolh_ci95_halfwidth` | 1.96 × std(per-scenario LOLH) / √N (h) |
| EUE CI95 | `eue_ci95_halfwidth` | 1.96 × std(per-scenario EUE) / √N (MWh) |

---

## Scope

The following features are intentionally excluded from the core benchmark:

- Transmission network (single copper-plate zone)
- Operating reserves
- Demand response
- Hydro water budget
- Network congestion
- Imperfect foresight and investment re-optimization

These are future extensions.  The core study aligns with traditional RA
assumptions (single zone, copper plate, no ancillary services).

Unit commitment is introduced only in HOPE-UC, which serves as the
high-fidelity validation benchmark.

---

## Repository layout

```
RAChronoOps/
  Project.toml
  docs/
    current_findings_synthesis.md  # key findings across all experiments
    redesigned_experiment_plan.md  # current experiment design
    results_index.md               # index of result folders
    storage_energy_sufficiency_bound.md  # theory note on the sufficiency bound
    experiment_archive.md          # completed diagnostic results
    hope_full_year_case_preparation.md  # HOPE case export details
    next_experiment_design_nostorage_and_real_uc.md
    ra2_n20_validation_memo.md
    vre_method_comparison_memo.md
    m1c_charging_assumption_memo.md
    ra1b_validation_memo.md
  src/
    RAChronoOps.jl
    utils/
      Config.jl
      IO.jl
    data/
      GetRTSGMLCData.jl
      LoadData.jl
      BuildRTSSingleZone.jl
      ExportHOPECase.jl
    scenarios/
      SequentialOutages.jl
    models/
      McNoStorage.jl               # classical no-storage MC baseline
      M1RuleBasedStorage.jl        # RA-1a: naive peak-shaving heuristic
      M1bReserveAwareStorage.jl    # RA-1b: reserve-aware heuristic
      M1cEmergencyOnlyStorage.jl   # RA-1c: emergency-only heuristic
      M1cVREOnlyCharge.jl          # M1c_VREOnly: VRE-surplus charging variant
      M1dRiskHourAllocation.jl     # RA-1d: risk-hour allocation heuristic
      M2EventWindowLP.jl           # RA-2: event-window LP
      M2RollingWindow.jl           # rolling-window LP (archived diagnostic)
      M3EDDispatch.jl              # RA-3: full-year ED LP benchmark
    metrics/
      ReliabilityMetrics.jl
    experiments/
      RunExperiment.jl
  scripts/
    # ── data preparation ──────────────────────────────────────────────────
    00_get_rts_gmlc_data.jl
    01_build_single_zone_rts.jl
    04_summarize_processed_data.jl
    05_smoke_test_full_rts_data.jl
    06_build_experiment_cases.jl
    # ── main comparison scripts ───────────────────────────────────────────
    30_compare_all_models_hope_n5.jl     # M1c/M2/M3/HOPE-ED on base case N=5
    33_build_no_storage_cases.jl         # build <case>_nostorage variants
    34_compare_no_storage_classic_vs_ed.jl  # MC-NoStorage vs M3-NoStorage
    36_compare_nostorage_hope_uc_n5.jl   # four-model no-storage HOPE-UC check
    37_compare_wind_hvy_hope_uc_n5.jl    # five-model wind-heavy HOPE-UC check
    38_compare_m1d_storage_heuristics.jl # M1c/M1d/M2/M3 within-event allocation study
    39_storage_energy_sufficiency_bound.jl # theoretical sufficiency bound diagnostic
    # ── HOPE export and run ───────────────────────────────────────────────
    25_build_hope_full_year_cases.jl     # export HOPE full-year case folders
    27_collect_hope_results.jl           # collect HOPE output metrics
    29_run_hope_n5_pilot.jl              # run HOPE cases via Julia subprocess
    # ── diagnostic scripts (archived) ────────────────────────────────────
    09_calibrate_load_scaling.jl
    10_run_storage_matrix.jl
    11_debug_storage_cases.jl
    12_run_selected_storage_validation.jl
    13_debug_m1_storage_sensitivity.jl
    14_run_ra1b_validation.jl
    16_run_vre_method_comparison.jl
  test/
    runtests.jl
    test_storage.jl
    test_m1d.jl
    test_outages.jl
    test_power_balance.jl
    test_common_scenarios.jl
  results/
    # main experiment results
    no_storage_comparison/         # MC-NoStorage vs M3-NoStorage (N=20)
    nostorage_hope_uc_comparison/  # four-model no-storage HOPE-UC check
    wind_hvy_hope_uc_comparison/   # five-model wind-heavy HOPE-UC check
    hope_wind_hvy_n5_pilot/        # HOPE run status + metrics for wind-hvy
    hope_nostorage_n5_pilot/       # HOPE run status + metrics for nostorage
    full_model_comparison_with_hope/  # M1c/M2/M3/HOPE-ED on base case
    vre_method_comparison/         # M1/M1b/M1c/M2/M3 across VRE cases
    m1d_storage_heuristic_comparison/  # M1c/M1d/M2/M3 within-event allocation
    storage_energy_sufficiency_bound/  # theoretical sufficiency bound
    # diagnostic results (archived)
    storage_matrix/
    storage_validation/
    m1_debug/
    load_scaling/
```

---

## Further reading

- [docs/current_findings_synthesis.md](docs/current_findings_synthesis.md)
  — key findings across all completed experiments
- [docs/redesigned_experiment_plan.md](docs/redesigned_experiment_plan.md)
  — current experiment design: research questions, methods, metrics
- [docs/results_index.md](docs/results_index.md)
  — index of result folders with commit policy
- [docs/storage_energy_sufficiency_bound.md](docs/storage_energy_sufficiency_bound.md)
  — theory note on the storage-energy sufficiency bound
- [docs/experiment_archive.md](docs/experiment_archive.md)
  — completed diagnostic experiments
- [docs/hope_full_year_case_preparation.md](docs/hope_full_year_case_preparation.md)
  — HOPE case export format and UC parameter mapping
