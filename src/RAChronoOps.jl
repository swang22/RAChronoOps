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

# 2. core data structures (GeneratorData, StorageData, SystemData, ScenarioSet)
#    ModelResults is in RunExperiment.jl (needs MetricsResult defined first)
include("data/LoadData.jl")

# 3. data preparation
include("data/GetRTSGMLCData.jl")
include("data/BuildRTSSingleZone.jl")
include("data/ExportHOPECase.jl")

# 4. scenario generation (defines ScenarioSet + generate_scenarios)
include("scenarios/SequentialOutages.jl")

# 5. models (M1 defines DispatchResult; M2 and M3 reuse it)
include("models/M1RuleBasedStorage.jl")
include("models/M2RollingWindow.jl")
include("models/M3EDDispatch.jl")

# 6. metrics (defines MetricsResult + individual metric functions)
include("metrics/ReliabilityMetrics.jl")

# 7. experiment runner (defines ModelResults, build_dispatch_df, run_experiment)
include("experiments/RunExperiment.jl")

# 8. IO (uses DispatchResult + MetricsResult defined above)
include("utils/IO.jl")

# ── public API ─────────────────────────────────────────────────────────────
export GeneratorData, StorageData, SystemData, ScenarioSet, ModelResults
export load_system_data
export thermal_generators, vre_generators, wind_capacity_mw, solar_capacity_mw

export SimConfig, load_config

export ensure_rts_gmlc_data
export build_rts_single_zone
export export_hope_case  # placeholder

export generate_scenarios

export DispatchResult
export run_m1_rule_based
export run_m2_rolling_window
export run_m3_ed_dispatch

export MetricsResult, compute_metrics
export compute_lolh, compute_eue, compute_neue
export compute_shortage_events, compute_cvar, aggregate_metrics

export ExperimentResult, ModelResults, run_experiment
export build_dispatch_df, build_gen_dispatch_df, build_scenario_metrics_df

export save_metrics, save_dispatch, save_scenario_eue

end # module
