module RAChronoOps

using CSV
using DataFrames
using YAML
using Random
using Statistics
using Distributions
using JuMP
using HiGHS
using Logging

# ── include order respects forward references ──────────────────────────────
# 1. configuration
include("utils/Config.jl")

# 2. core data structures
include("data/LoadData.jl")

# 3. data preparation
include("data/BuildRTSSingleZone.jl")
include("data/ExportHOPECase.jl")

# 4. scenario generation
include("scenarios/SequentialOutages.jl")

# 5. models (M1 defines DispatchResult first; M2 and M3 reuse it)
include("models/M1RuleBasedStorage.jl")
include("models/M2RollingWindow.jl")
include("models/M3EDDispatch.jl")

# 6. metrics (defines MetricsResult)
include("metrics/ReliabilityMetrics.jl")

# 7. high-level experiment runner
include("experiments/RunExperiment.jl")

# 8. IO (uses DispatchResult + MetricsResult defined above)
include("utils/IO.jl")

# ── public API ─────────────────────────────────────────────────────────────
export SystemData, load_system_data
export thermal_generators, vre_generators, wind_capacity_mw, solar_capacity_mw

export SimConfig, load_config

export build_rts_single_zone
export export_hope_case  # placeholder

export generate_scenarios

export DispatchResult
export run_m1_rule_based
export run_m2_rolling_window
export run_m3_ed_dispatch

export MetricsResult, compute_metrics

export ExperimentResult, run_experiment

export save_metrics, save_dispatch

end # module
