# RAChronoOps

Probabilistic resource adequacy assessment with chronological storage operations.
Single-zone copper-plate system based on a modified RTS-GMLC dataset.

## Models

| Model | Method | Storage dispatch |
|-------|--------|-----------------|
| M1 | Sequential Monte Carlo | Rule-based (peak-shaving / valley-filling) |
| M2 | Sequential Monte Carlo | Rolling-window LP (model predictive control) |
| M3 | Sequential Monte Carlo | Full-year economic dispatch LP (perfect foresight per scenario) |

## Quick start

```bash
# 1. Install Julia dependencies
julia --project=. -e "using Pkg; Pkg.instantiate()"

# 2. Download RTS-GMLC data (requires git on PATH)
julia --project=. scripts/00_get_rts_gmlc_data.jl

# 3. Build the processed single-zone dataset
julia --project=. scripts/01_build_single_zone_rts.jl

# 4. Run all three models and compare reliability metrics
julia --project=. scripts/03_run_m1_m2_m3.jl
```

If you skip step 2, the build script in step 3 falls back to a small
deterministic synthetic dataset so that tests and a first run still work.

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

# Quick sanity check: assert 8760 h, generate 3 scenarios, run M1
julia --project=. scripts/05_smoke_test_full_rts_data.jl
```

## Building formal experiment cases

After building the base dataset, create the 20 experiment case folders used
in the main experiments:

```bash
julia --project=. scripts/06_build_experiment_cases.jl
```

This writes one subfolder per case under `data_processed/cases/`, each
containing `generators.csv`, `storage.csv`, `load_timeseries.csv`,
`wind_timeseries.csv`, `solar_timeseries.csv`, and `case_metadata.csv`.
A master `case_index.csv` is written to `data_processed/cases/`.

Cases are derived from the base processed dataset by applying scale factors —
the original files in `data_processed/rts_single_zone/` are never modified.

| Experiment group | Scale factors applied |
|-----------------|----------------------|
| Load scaling (×5) | `load_scale` ∈ {1.00, 1.05, 1.10, 1.15, 1.20} |
| Storage matrix (×12) | `storage_power_pct_peak` ∈ {5%, 10%, 20%} × `storage_duration_hours` ∈ {2, 4, 8, 12} |
| VRE sensitivity (×3) | Balanced 2× / solar-heavy 3× / wind-heavy 3× |

The `data_processed/cases/` directory is git-ignored (generated data).

## Running one experiment case

Run all three models on a single case and write results to
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
# Run only M1 and M3 with 20 scenarios
julia --project=. scripts/07_run_case.jl data_processed/cases/load_scale_110 \
    --models M1,M3 --n-scenarios 20

# Run M2 with a shorter look-ahead (faster)
julia --project=. scripts/07_run_case.jl data_processed/cases/rts_base \
    --models M2 --lookahead-hours 48
```

All models use a **single shared ScenarioSet** generated once from the
base config (common random numbers), so metric differences are attributable
to dispatch strategy alone.

Output files written to `results/cases/<case_name>/`:

| File | Contents |
|------|----------|
| `aggregate_metrics.csv` | One row per model — LOLH, EUE, nEUE, CVaR-EUE, runtime |
| `scenario_metrics.csv` | One row per (model, scenario) |
| `run_metadata.csv` | Case path, config, timestamps, scale factors |
| `dispatch/<model>_dispatch.csv` | Hourly dispatch (only if `--save-dispatch true`) |
| `logs/run_<timestamp>.log` | Full run log |

The `results/cases/` directory is git-ignored (generated outputs).

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

You can also call the builder or the data helper programmatically:

```julia
using RAChronoOps
ensure_rts_gmlc_data("data_raw/RTS-GMLC")
build_rts_single_zone("data_raw/RTS-GMLC", "data_processed/rts_single_zone")
```

## Common random numbers

M1, M2, and M3 are evaluated on **identical Monte Carlo outage scenarios**
generated once from `configs/base_case.yaml` (the `n_scenarios` and `seed`
keys).  A single `ScenarioSet` is drawn before the model loop and passed
unchanged to every model, guaranteeing that differences in reliability
metrics are attributable to dispatch strategy alone and not to sampling
noise.

Model-specific configs (`configs/m1.yaml`, `configs/m2.yaml`,
`configs/m3.yaml`) control **operational parameters only** — storage dispatch
strategy, look-ahead horizon, cycling cost, cyclic-SOC constraint, and
whether to save dispatch CSVs.  They must not contain `n_scenarios` or `seed`
keys; if they do, `scripts/03_run_m1_m2_m3.jl` logs a warning and uses the
base-case values.

## Ignored features (first implementation)

The following features are intentionally excluded from M1–M3 to keep the
baseline tractable:

- Transmission network (single copper-plate zone)
- Net imports
- Operating reserves
- Demand response
- Unit commitment (continuous dispatch only)
- Hydro water budget
- Fuel constraints
- VRE curtailment limits (only cost-based)

Storage is the primary energy-limited resource.  Load shedding is allowed
at a configurable VOLL (default \$10,000/MWh).

## Repository layout

```
RAChronoOps/
  Project.toml
  src/
    RAChronoOps.jl          # package entry point
    utils/
      Config.jl             # SimConfig struct + YAML loader
      IO.jl                 # result serialisation
    data/
      GetRTSGMLCData.jl     # ensure_rts_gmlc_data() helper
      LoadData.jl           # GeneratorData / StorageData / SystemData / ScenarioSet
      BuildRTSSingleZone.jl # RTS-GMLC → single-zone aggregation
      ExportHOPECase.jl     # placeholder for future HOPE interface
    scenarios/
      SequentialOutages.jl  # two-state Markov outage sampler
    models/
      M1RuleBasedStorage.jl
      M2RollingWindow.jl
      M3EDDispatch.jl
    metrics/
      ReliabilityMetrics.jl # LOLH, EUE, nEUE, CVaR + individual functions
    experiments/
      RunExperiment.jl      # ModelResults, build_dispatch_df, run_experiment
  configs/
    base_case.yaml
    m1.yaml  m2.yaml  m3.yaml
  scripts/
    00_get_rts_gmlc_data.jl        # clone RTS-GMLC from GitHub
    01_build_single_zone_rts.jl    # build 8760-h processed CSVs
    02_generate_scenarios.jl       # generate outage scenarios standalone
    03_run_m1_m2_m3.jl             # run all models, save metrics
    04_summarize_processed_data.jl # write data_summary/ CSVs + terminal report
    05_smoke_test_full_rts_data.jl # assert 8760 h, run M1 (3 scenarios)
    06_build_experiment_cases.jl   # build 20 case folders under data_processed/cases/
    07_run_case.jl                 # run M1/M2/M3 on one case, write results/cases/<name>/
  test/
    runtests.jl
    test_storage.jl
    test_outages.jl
    test_power_balance.jl
    test_common_scenarios.jl
```

## Connecting to HOPE (M4 / M5)

M4 will couple with HOPE (a Julia production-cost model) using:
- `network_model = 0` (single-zone, no transmission)
- `unit_commitment = 0` (ED, consistent with M3) or `= 1` (full UC)

See `src/data/ExportHOPECase.jl` for the planned interface.
M5 will be a screened MC+UC/PCM approximation that runs HOPE UC only on stress
periods identified by M3.  Multi-zone and network-constrained extensions are
outside the scope of the first implementation.

## Main experiment roadmap

### Phase 1: Baseline full RTS-GMLC run

- RTS-GMLC single-zone, 8760 hours
- 100 shared outage scenarios
- 4-hour battery scaled to 10% of peak load
- M1, M2 with 24-hour look-ahead, M3
- Main question: does the baseline system have meaningful scarcity?

### Phase 2: Load-scaling calibration

- Load scale factors: 1.00, 1.05, 1.10, 1.15, 1.20
- Goal: find a calibrated scarcity case where M3 has nonzero but not extreme
  LOLH/EUE.

### Phase 3: Storage duration and penetration matrix

- Storage power: 5%, 10%, 20% of peak load
- Storage duration: 2, 4, 8, 12 hours
- Goal: quantify how M1 and M2 differ from M3 as storage becomes more
  important.

### Phase 4: VRE profile sensitivity

- Balanced high VRE: wind scale 2.0, solar scale 2.0
- Solar-heavy: wind scale 1.0, solar scale 3.0
- Wind-heavy: wind scale 3.0, solar scale 1.0
- Goal: test whether look-ahead and full-year ED matter differently under
  daily solar cycling versus multi-day wind variation.
