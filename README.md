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

## Download RTS-GMLC data

The official RTS-GMLC dataset is hosted at
https://github.com/GridMod/RTS-GMLC.

Run the provided helper script to clone it into the correct local folder:

```bash
julia --project=. scripts/00_get_rts_gmlc_data.jl
```

The script is idempotent — if the data is already present it prints a message
and exits immediately.  After cloning, the directory layout will be:

```
data_raw/RTS-GMLC/
  RTS_Data/
    SourceData/
      gen.csv
      bus.csv
      branch.csv
    timeseries_data_files/
      Load/
        DAY_AHEAD_regional_Load.csv
      WIND/
        DAY_AHEAD_<unit>_<date>.csv
      PV/
        DAY_AHEAD_<unit>_<date>.csv
```

`BuildRTSSingleZone.jl` detects the `RTS_Data/` subdirectory automatically
and resolves the correct paths.

You can also call the helper programmatically:

```julia
using RAChronoOps
ensure_rts_gmlc_data("data_raw/RTS-GMLC")
```

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
    00_get_rts_gmlc_data.jl   # clone RTS-GMLC from GitHub
    01_build_single_zone_rts.jl
    02_generate_scenarios.jl
    03_run_m1_m2_m3.jl
    04_export_hope_cases.jl   # placeholder
  test/
    runtests.jl
    test_storage.jl
    test_outages.jl
    test_power_balance.jl
```

## Connecting to HOPE (M4 / M5)

M4 will couple with HOPE (a Julia production-cost model) using:
- `network_model = 0` (single-zone, no transmission)
- `unit_commitment = 0` (ED, consistent with M3) or `= 1` (full UC)

See `src/data/ExportHOPECase.jl` for the planned interface.
M5 (multi-zone) is not yet scoped.
