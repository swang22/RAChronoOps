# RAChronoOps

RAChronoOps is a research codebase for evaluating how much operational detail
is needed inside probabilistic sequential Monte Carlo resource adequacy
assessment for high-VRE, storage-rich power systems.  The project compares
fast RA-compatible dispatch approximations against full-year economic dispatch
and later UC/PCM benchmarks.

Single-zone copper-plate system based on the RTS-GMLC dataset.

## Method hierarchy

| Label | Status | Method | Optimization | Intended role |
|-------|--------|--------|--------------|---------------|
| RA-0 | not yet implemented | Static capacity-balance RA | None | Classical baseline |
| RA-1a / M1 | implemented | Sequential MC + naive peak-shaving storage heuristic | None | Cautionary heuristic baseline |
| RA-1b | scaffolded (not yet implemented) | Sequential MC + reserve-aware storage heuristic | None | Practical improved heuristic |
| RA-2 | planned | Sequential MC + screened/event-window LP | Small LPs near risk periods only | Proposed hybrid method |
| RA-3 / M3 | implemented | Sequential MC + full-year ED LP per scenario | LP (HiGHS) | Reliability benchmark |
| RA-4 / M4 | future | HOPE UC/PCM on selected stress periods | UC/PCM | High-fidelity validation benchmark |

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

# 4. Verify M3 with a single-scenario smoke test (~6 min)
julia --project=. scripts/06_smoke_test_m3_full_year.jl

# 5. Run RA-1a and RA-3 on the calibrated stress case
julia --project=. scripts/03_run_m1_m2_m3.jl --models M1,M3 --n-scenarios 20 --seed 42
```

If you skip step 2, the build script in step 3 falls back to a small
deterministic synthetic dataset so that tests and a first run still work.

## Current completed experiments

The diagnostic phase is complete.  Key results:

- **Dataset:** Full RTS-GMLC 8760-hour single-zone system built and
  validated (73 thermal + 60 VRE generators).
- **Load calibration:** Base RTS-GMLC is too reliable at load_scale=1.00
  (M3 LOLH ≈ 0).  `load_scale = 1.20` was selected as the calibrated
  stress case (M3 LOLH ≈ 6–8 h/yr at 10% peak / 4h storage).
- **RA-3 (M3):** Full-year ED LP is implemented and runs at ~360 s/scenario
  after an out-of-memory fix.  Validated at 50 scenarios.
- **RA-1a (M1) diagnosis:** Priority-2 proactive discharge fires at 25% of
  all hours and depletes storage SOC to zero before every shortage event.
  Priority-1 emergency discharge fires zero times across all scenarios and
  all storage configurations.  M1 LOLH is identical (96.48 h/yr) for all
  six storage cases tested — a heuristic limitation, not a data bug.
- **M2 (rolling-window LP):** Works correctly but solves one LP per hour
  per scenario (~360 s/scenario), giving no runtime advantage over RA-3
  while sacrificing full-year coherence.  Excluded from forward experiments.
- **Storage validation:** RA-3 benchmark at load_scale=1.20, 10% / 4h
  storage: LOLH = 6.22 h/yr, EUE = 2,889 MWh (N=50, seed=42).

Full numeric results and per-script output paths are in
[docs/experiment_archive.md](docs/experiment_archive.md).

## Why we are redesigning the experiments

The original M1/M2/M3 storage-duration study is now treated as a
**diagnostic phase** that exposed two problems with the initial design:

1. **RA-1a (M1) is not a credible simple RA method.**  The naive
   peak-shaving heuristic exhausts storage before shortage events and
   produces reliability metrics insensitive to storage size.  It is a
   useful failure case but not a fair comparison point for a proposed
   hybrid method.

2. **M2 (rolling-window LP) is the wrong incremental approach.**  Solving
   one LP per hour gives no runtime advantage over the full-year RA-3
   benchmark.  The correct approach is to solve LPs only near screened
   risk windows (RA-2 event-window LP).

The **new experiment design** fixes both problems:

- RA-1b adds an emergency SOC reserve to the heuristic, preventing
  proactive discharge from pre-empting emergency storage.
- RA-2 screens for risk periods and solves storage LPs only there,
  targeting 5–20 s/scenario vs RA-3's ~360 s.
- The main experiment varies VRE penetration and profile (not storage
  duration), testing each method's robustness as solar/wind increases.

See [docs/redesigned_experiment_plan.md](docs/redesigned_experiment_plan.md)
for the full design including research questions, experiment matrix,
metrics, and expected figures.

## Experiment roadmap

### Phase A — Finalize diagnostic baseline (completed)

- Load calibration and storage validation results are preserved as-is.
- `load_scale = 1.20`, storage = 10% peak / 4h used as the fixed stress
  case for all forward experiments.
- RA-1a diagnosis motivates RA-1b and RA-2.

See [docs/experiment_archive.md](docs/experiment_archive.md) for full
diagnostic results.

### Phase B — Implement RA-1b reserve-aware heuristic

Add an emergency SOC reserve to the heuristic dispatch rule: priority-2
proactive discharge is suppressed when `SOC < reserve_fraction ×
total_energy`.  This prevents peak-shaving from pre-empting emergency
storage capacity.

**Implemented** (`reserve_fraction = 0.50` default):

- `src/models/M1bReserveAwareStorage.jl` — full three-priority dispatch loop
  identical to RA-1a except Priority-2 is restricted to SOC above the floor.
  Priority-1 emergency discharge ignores the floor.
- `src/utils/Config.jl` — `reserve_fraction::Float64 = 0.50` added to
  `SimConfig` (field 6; keyword-only callers unaffected).
- `configs/m1b.yaml` — `reserve_fraction: 0.50` read at runtime.
- `test/test_storage.jl` — four new testsets: SOC dynamics, RF=1.0 disables
  P2, RF=0.0 matches RA-1a exactly, storage-sensitivity on calibrated cases.
- `scripts/14_run_ra1b_validation.jl` — compare RA-1a / RA-1b / RA-3 on
  `storage120_p05/p10/p20_d4`; answers four research questions in summary.txt.

### Phase C — Implement RA-2 event-window LP

Screen each scenario for risk windows (hours where available thermal +
VRE is within a configurable margin of load), expand and merge nearby
windows, and solve a storage dispatch LP only inside each window.  Use
RA-1b heuristic dispatch outside windows.

- New model file `src/models/M2EventWindowLP.jl`.
- Config parameters: `risk_margin_mw`, `window_buffer_hours`.
- Validation script: `scripts/16_run_ra2_validation.jl`.
- Target runtime: 5–20 s/scenario (vs RA-3 at ~360 s).

### Phase D — VRE penetration/profile experiment

Run RA-1a, RA-1b, RA-2, and RA-3 across six VRE cases at fixed
`load_scale = 1.20`, storage = 10% peak / 4h:

| Case | Wind scale | Solar scale |
|------|-----------|-------------|
| VRE-Base | 1.0 | 1.0 |
| VRE-Balanced-1.5x | 1.5 | 1.5 |
| VRE-Balanced-2x | 2.0 | 2.0 |
| VRE-Balanced-3x | 3.0 | 3.0 |
| Solar-heavy | 1.0 | 3.0 |
| Wind-heavy | 3.0 | 1.0 |

VRE scenarios are defined by installed capacity scaling; the analysis
reports both capacity-based and energy-based VRE penetration metrics.

Primary metrics: LOLH error and EUE error vs RA-3 benchmark, and
runtime ratio.  Experiment script: `scripts/15_run_vre_experiment.jl`
(RA-1a + RA-1b + RA-3) and `scripts/17_run_vre_all_methods.jl` (adds
RA-2 after Phase C).

### Phase E — HOPE UC/PCM validation (future)

Use RA-3 to identify stress weeks (scenario-hours with concentrated load
shedding).  Export those weeks via `src/data/ExportHOPECase.jl` and run
HOPE with unit commitment.  Compare ED (RA-3) vs UC (RA-4) reliability
and dispatch feasibility on the selected stress periods.

---

## Preparing the full RTS-GMLC dataset

The official RTS-GMLC dataset is hosted at
https://github.com/GridMod/RTS-GMLC.

Run the provided helper scripts in order:

```bash
# Clone RTS-GMLC into data_raw/RTS-GMLC/ (requires git on PATH; idempotent)
julia --project=. scripts/00_get_rts_gmlc_data.jl

# Build the 8760-hour single-zone processed dataset
julia --project=. scripts/01_build_single_zone_rts.jl

# Optionally verify: print system summary + write results/data_summary/ CSVs
julia --project=. scripts/04_summarize_processed_data.jl

# Quick sanity check: assert 8760 h, generate 3 scenarios, run RA-1a
julia --project=. scripts/05_smoke_test_full_rts_data.jl
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
still run.  The fallback is logged as a warning and never triggers the strict
8760-hour validation.

You can also call the builder programmatically:

```julia
using RAChronoOps
ensure_rts_gmlc_data("data_raw/RTS-GMLC")
build_rts_single_zone("data_raw/RTS-GMLC", "data_processed/rts_single_zone")
```

## Building experiment cases

`scripts/06_build_experiment_cases.jl` writes one subfolder per case under
`data_processed/cases/`, each containing `generators.csv`, `storage.csv`,
`load_timeseries.csv`, `wind_timeseries.csv`, `solar_timeseries.csv`, and
`case_metadata.csv`.  A master `case_index.csv` is written to
`data_processed/cases/`.

Cases are derived from the base processed dataset by applying scale factors —
the original files in `data_processed/rts_single_zone/` are never modified.

| Experiment group | Scale factors applied | Status |
|-----------------|----------------------|--------|
| Load scaling (×5) | `load_scale` ∈ {1.00, 1.05, 1.10, 1.15, 1.20} | Diagnostic — completed |
| Extended load scaling (×6) | `load_scale` ∈ {1.20, 1.225, 1.25, 1.275, 1.30, 1.35} | Diagnostic — completed |
| Storage matrix (×12) | `storage_power_pct_peak` ∈ {5%, 10%, 20%} × `storage_duration_hours` ∈ {2, 4, 8, 12} at load_scale=1.20 | Diagnostic — completed |
| VRE penetration/profile (×6) | wind/solar scale pairs — see Phase D table | Main experiment (Phase D) |

The `data_processed/cases/` directory is git-ignored (generated data).

```bash
julia --project=. scripts/06_build_experiment_cases.jl
```

## Running one experiment case

Run selected methods on a single case and write results to
`results/cases/<case_name>/`:

```bash
julia --project=. scripts/07_run_case.jl data_processed/cases/rts_base
```

Optional arguments:

| Option | Default | Description |
|--------|---------|-------------|
| `--models M1,M2,M3` | `M1,M2,M3` | Comma-separated subset of models to run |
| `--n-scenarios N` | from `base_case.yaml` | Override scenario count |
| `--seed S` | from `base_case.yaml` | Override random seed |
| `--lookahead-hours H` | from `m2.yaml` | Override M2 look-ahead window |
| `--save-dispatch true\|false` | from each model config | Override dispatch CSV output |

Examples:

```bash
# Run RA-1a and RA-3 with 20 scenarios
julia --project=. scripts/07_run_case.jl data_processed/cases/load_scale_110 \
    --models M1,M3 --n-scenarios 20

# Run M2 with a shorter look-ahead (diagnostic only — M2 is slow)
julia --project=. scripts/07_run_case.jl data_processed/cases/rts_base \
    --models M2 --lookahead-hours 48
```

Output files written to `results/cases/<case_name>/`:

| File | Contents |
|------|----------|
| `aggregate_metrics.csv` | One row per model — LOLH, EUE, nEUE, CVaR-EUE, runtime |
| `scenario_metrics.csv` | One row per (model, scenario) |
| `run_metadata.csv` | Case path, config, timestamps, scale factors |
| `dispatch/<model>_dispatch.csv` | Hourly dispatch (only if `--save-dispatch true`) |
| `logs/run_<timestamp>.log` | Full run log |

The `results/cases/` directory is git-ignored (generated outputs).

## Common random numbers

All RA methods are evaluated on **identical Monte Carlo outage scenarios**
generated once from `configs/base_case.yaml` (the `n_scenarios` and `seed`
keys).  A single `ScenarioSet` is drawn before the method loop and passed
unchanged to every method, guaranteeing that differences in reliability
metrics are attributable to dispatch strategy alone and not to sampling
noise.

Method-specific configs (`configs/m1.yaml`, `configs/m2.yaml`,
`configs/m3.yaml`) control **operational parameters only** — storage dispatch
strategy, look-ahead horizon, cycling cost, cyclic-SOC constraint, and
whether to save dispatch CSVs.  They must not contain `n_scenarios` or `seed`
keys.

## Scope (first implementation)

The following features are intentionally excluded to keep the baseline
tractable:

- Transmission network (single copper-plate zone)
- Net imports
- Operating reserves
- Demand response
- Unit commitment (continuous dispatch only in RA-0 through RA-3)
- Hydro water budget
- Fuel constraints
- VRE curtailment limits (only cost-based)

Storage is the primary energy-limited resource.  Load shedding is allowed
at a configurable VOLL (default \$10,000/MWh).  Unit commitment is
introduced only in RA-4 via HOPE.

## Reliability metric taxonomy

All implemented methods compute a common set of metrics stored in `MetricsResult`
(see `src/metrics/ReliabilityMetrics.jl`).

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
| Relative CIs | `*_ci95_rel_halfwidth` | Half-width / mean; `NaN` when mean = 0 |

Primary summary tables show **LOLH, LOLP %, LOLE days, EUE, CVaR-EUE, max shortfall,
and runtime**.  Full CSV outputs include event-duration metrics, scenario-EUE quantiles,
and Monte Carlo confidence intervals.

---

## Repository layout

```
RAChronoOps/
  Project.toml
  docs/
    experiment_archive.md        # completed diagnostic results
    redesigned_experiment_plan.md # forward experiment design
  src/
    RAChronoOps.jl               # package entry point
    utils/
      Config.jl                  # SimConfig struct + YAML loader
      IO.jl                      # result serialisation
    data/
      GetRTSGMLCData.jl          # ensure_rts_gmlc_data() helper
      LoadData.jl                # GeneratorData / StorageData / SystemData / ScenarioSet
      BuildRTSSingleZone.jl      # RTS-GMLC → single-zone aggregation
      ExportHOPECase.jl          # placeholder for RA-4 HOPE interface
    scenarios/
      SequentialOutages.jl       # two-state Markov outage sampler
    models/
      M1RuleBasedStorage.jl      # RA-1a: naive peak-shaving heuristic
      M2RollingWindow.jl         # rolling-window LP (diagnostic only)
      M3EDDispatch.jl            # RA-3: full-year ED LP benchmark
    metrics/
      ReliabilityMetrics.jl      # LOLH, EUE, nEUE, CVaR + individual functions
    experiments/
      RunExperiment.jl           # ModelResults, build_dispatch_df, run_experiment
  configs/
    base_case.yaml
    m1.yaml  m2.yaml  m3.yaml
  scripts/
    # ── data preparation ──────────────────────────────────────────────────
    00_get_rts_gmlc_data.jl           # clone RTS-GMLC from GitHub
    01_build_single_zone_rts.jl       # build 8760-h processed CSVs
    02_generate_scenarios.jl          # generate outage scenarios standalone
    04_summarize_processed_data.jl    # write data_summary/ CSVs + terminal report
    05_smoke_test_full_rts_data.jl    # assert 8760 h, run RA-1a (3 scenarios)
    06_build_experiment_cases.jl      # build all case folders
    06_smoke_test_m3_full_year.jl     # assert 8760 h, run RA-3 (1 scenario, ~6 min)
    # ── general experiment runner ─────────────────────────────────────────
    03_run_m1_m2_m3.jl                # run selected methods, save metrics
    07_run_case.jl                    # run methods on one case folder
    # ── diagnostic scripts (completed) ────────────────────────────────────
    09_calibrate_load_scaling.jl      # load-scale sweep → load_scale=1.20 selected
    10_run_storage_matrix.jl          # 12-case storage matrix at load_scale=1.20
    11_debug_storage_cases.jl         # EUE anomaly investigation (p10_d4 vs p20_d2)
    12_run_selected_storage_validation.jl # 50-scenario validation of 6 cases
    13_debug_m1_storage_sensitivity.jl    # RA-1a priority-action diagnosis
    # ── forward experiment scripts (planned) ──────────────────────────────
    14_run_ra1b_validation.jl         # Phase B: RA-1b validation on reference case
    15_run_vre_experiment.jl          # Phase D: RA-1a/1b/RA-3 across VRE cases
    16_run_ra2_validation.jl          # Phase C: RA-2 single-case sanity check
    17_run_vre_all_methods.jl         # Phase D: full four-method VRE sweep
    18_run_hope_stress_weeks.jl       # Phase E: RA-4 HOPE UC/PCM validation
  test/
    runtests.jl
    test_storage.jl
    test_outages.jl
    test_power_balance.jl
    test_common_scenarios.jl
  results/
    storage_matrix/          # diagnostic: 12-case storage matrix
    storage_validation/      # diagnostic: 50-scenario selected validation
    m1_debug/                # diagnostic: RA-1a priority-action analysis
    load_scaling/            # diagnostic: calibration sweep results
```

## Connecting to HOPE (RA-4 / M4)

RA-4 will couple with HOPE (a Julia production-cost model) using:
- `network_model = 0` (single-zone, no transmission)
- `unit_commitment = 1` (full UC, consistent with RA-4 role)

The interface is planned via `src/data/ExportHOPECase.jl`.  RA-4 will
run HOPE only on stress periods identified by RA-3, not for every
Monte Carlo scenario — making it a feasible high-fidelity validation
benchmark rather than a full PCM simulation.

Multi-zone and network-constrained extensions are outside the scope of
the first implementation.

## Further reading

- [docs/experiment_archive.md](docs/experiment_archive.md) — completed
  diagnostic experiments: data preparation, load calibration, storage
  matrix, RA-1a diagnosis.
- [docs/redesigned_experiment_plan.md](docs/redesigned_experiment_plan.md)
  — forward design: research questions, method hierarchy, VRE experiment
  matrix, metrics, expected figures, and implementation task list.
- [docs/results_index.md](docs/results_index.md) — index of completed and
  planned result folders with commit policy and key file names.
- [docs/ra1b_implementation_checklist.md](docs/ra1b_implementation_checklist.md)
  — pre-implementation specification for RA-1b: exact algorithm, behavioral
  contracts, implementation steps, and validation tests.
