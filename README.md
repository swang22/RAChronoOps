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

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()

# 1. Build processed data (creates synthetic fallback if RTS-GMLC absent)
include("scripts/01_build_single_zone_rts.jl")

# 2. Run all three models
include("scripts/03_run_m1_m2_m3.jl")
```

## Data

Place RTS-GMLC source files under `data_raw/RTS-GMLC/`. If absent, the build
script generates a synthetic 8760-hour fallback system automatically.

Expected RTS-GMLC layout:

```
data_raw/RTS-GMLC/
  SourceData/
    gen.csv
    bus.csv
  timeseries_data_files/
    Load/
      DAY_AHEAD_regional_Load.csv
    WIND/
      DAY_AHEAD_<unit>_<date>.csv   (or similar)
    PV/
      DAY_AHEAD_<unit>_<date>.csv
```

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
      LoadData.jl           # SystemData struct + CSV loader
      BuildRTSSingleZone.jl # RTS-GMLC → single-zone aggregation
      ExportHOPECase.jl     # placeholder for future HOPE interface
    scenarios/
      SequentialOutages.jl  # two-state Markov outage sampler
    models/
      M1RuleBasedStorage.jl
      M2RollingWindow.jl
      M3EDDispatch.jl
    metrics/
      ReliabilityMetrics.jl # LOLH, EUE, nEUE, CVaR
    experiments/
      RunExperiment.jl      # high-level orchestration
  configs/
    base_case.yaml
    m1.yaml  m2.yaml  m3.yaml
  scripts/
    01_build_single_zone_rts.jl
    02_generate_scenarios.jl
    03_run_m1_m2_m3.jl
    04_export_hope_cases.jl
  test/
    runtests.jl
    test_storage.jl
    test_outages.jl
    test_power_balance.jl
```

## Future work (M4 / M5)

M4 will couple with HOPE (network_model=0, unit_commitment=1).
See `src/data/ExportHOPECase.jl` for the placeholder interface.
