# ── Core data structs ─────────────────────────────────────────────────────

"""
    GeneratorData

Immutable parameters for one generator (thermal or VRE).
Thermal generators have meaningful FOR and mean_repair_time_hours.
VRE generators have is_vre=true and a non-empty vre_type ("wind" or "solar").
"""
struct GeneratorData
    gen_id                 ::String
    gen_type               ::String
    fuel                   ::String
    pmax_mw                ::Float64
    pmin_mw                ::Float64
    variable_cost_per_mwh  ::Float64
    forced_outage_rate     ::Float64
    mean_repair_time_hours ::Float64
    is_thermal             ::Bool
    is_vre                 ::Bool
    vre_type               ::String   # "wind", "solar", or ""
end

"""
    StorageData

Immutable parameters for one storage unit.
"""
struct StorageData
    storage_id            ::String
    power_mw              ::Float64   # charge / discharge power limit
    energy_mwh            ::Float64   # usable energy capacity
    charge_efficiency     ::Float64   # η_ch  ∈ (0,1]
    discharge_efficiency  ::Float64   # η_dis ∈ (0,1]
    variable_cost_per_mwh ::Float64
    initial_soc_mwh       ::Float64
end

"""
    SystemData

Single-zone system snapshot: generator fleet, storage, and hourly time series.

`generators` DataFrame contains both thermal (is_thermal=1) and VRE (is_vre=1)
rows with columns matching `GeneratorData` fields.
`storage` DataFrame contains one row per `StorageData` unit.
Time-series vectors have length `n_hours` (typically 8760).
"""
struct SystemData
    generators  ::DataFrame
    storage     ::DataFrame
    load_mw     ::Vector{Float64}
    wind_cf     ::Vector{Float64}
    solar_cf    ::Vector{Float64}
    n_hours     ::Int
end

"""
    ScenarioSet

Wraps the availability matrix produced by `generate_scenarios`.

`availability[scenario, thermal_generator, hour]` ∈ {0, 1}.
Carries the seed used so results are reproducible and traceable.
"""
struct ScenarioSet
    availability ::Array{Int8, 3}   # n_scenarios × n_thermal × n_hours
    n_scenarios  ::Int
    n_thermal    ::Int
    n_hours      ::Int
    seed         ::Int
end

Base.size(s::ScenarioSet) = (s.n_scenarios, s.n_thermal, s.n_hours)

# NOTE: ModelResults (which references MetricsResult) is defined in
# src/experiments/RunExperiment.jl, included after ReliabilityMetrics.jl.

# ── convenience selectors ─────────────────────────────────────────────────

thermal_generators(sys::SystemData) =
    filter(r -> r.is_thermal == 1, sys.generators)

vre_generators(sys::SystemData) =
    filter(r -> r.is_vre == 1, sys.generators)

function wind_capacity_mw(sys::SystemData)
    df = filter(r -> r.is_vre == 1 && r.vre_type == "wind", sys.generators)
    isempty(df) ? 0.0 : sum(df.pmax_mw)
end

function solar_capacity_mw(sys::SystemData)
    df = filter(r -> r.is_vre == 1 && r.vre_type == "solar", sys.generators)
    isempty(df) ? 0.0 : sum(df.pmax_mw)
end

# ── CSV loader ────────────────────────────────────────────────────────────

"""
    load_system_data(data_dir) -> SystemData

Read the five processed CSVs from `data_dir` and return a `SystemData`.
Run `scripts/01_build_single_zone_rts.jl` first if files are missing.
"""
function load_system_data(data_dir::String)::SystemData
    gen_path   = joinpath(data_dir, "generators.csv")
    stor_path  = joinpath(data_dir, "storage.csv")
    load_path  = joinpath(data_dir, "load_timeseries.csv")
    wind_path  = joinpath(data_dir, "wind_timeseries.csv")
    solar_path = joinpath(data_dir, "solar_timeseries.csv")

    for p in (gen_path, stor_path, load_path, wind_path, solar_path)
        isfile(p) || error("Missing processed data file: $p\n" *
            "Run scripts/01_build_single_zone_rts.jl first.")
    end

    generators = CSV.read(gen_path,   DataFrame)
    storage    = CSV.read(stor_path,  DataFrame)
    load_df    = CSV.read(load_path,  DataFrame)
    wind_df    = CSV.read(wind_path,  DataFrame)
    solar_df   = CSV.read(solar_path, DataFrame)

    n_hours = nrow(load_df)

    return SystemData(
        generators, storage,
        Float64.(load_df.load_mw),
        Float64.(wind_df.wind_cf),
        Float64.(solar_df.solar_cf),
        n_hours,
    )
end
