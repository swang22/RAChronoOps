# ── SystemData ─────────────────────────────────────────────────────────────

"""
    SystemData

Holds the processed single-zone system.

`generators` contains both thermal (is_thermal=1) and VRE (is_vre=1) rows;
  thermal rows have valid FOR / MTTR values.
`storage` holds one row per storage unit.
Time-series vectors are length n_hours (typically 8760).
"""
struct SystemData
    generators  ::DataFrame
    storage     ::DataFrame
    load_mw     ::Vector{Float64}
    wind_cf     ::Vector{Float64}
    solar_cf    ::Vector{Float64}
    n_hours     ::Int
end

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

"""
    load_system_data(data_dir) -> SystemData

Read the five processed CSVs from `data_dir` and return a SystemData.
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
