#!/usr/bin/env julia
# 06_build_experiment_cases.jl
#
# Reads the base processed RTS-GMLC single-zone dataset and writes one case
# folder per experiment configuration under data_processed/cases/.
#
# Each case folder contains:
#   generators.csv  storage.csv  load_timeseries.csv
#   wind_timeseries.csv  solar_timeseries.csv  case_metadata.csv
#
# A master index is written to data_processed/cases/case_index.csv.
#
# Usage:
#   julia --project=. scripts/06_build_experiment_cases.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using CSV, DataFrames, Statistics, Printf

# ── case definition ───────────────────────────────────────────────────────────
struct CaseDef
    name                   :: String
    load_scale             :: Float64
    wind_scale             :: Float64
    solar_scale            :: Float64
    storage_power_pct_peak :: Float64
    storage_duration_hours :: Int
    notes                  :: String
end

const ETA = sqrt(0.90)   # charge = discharge = √0.90 → round-trip ≈ 90%

const CASES = CaseDef[
    # ── Phase 1: baseline ────────────────────────────────────────────────
    CaseDef("rts_base",       1.00, 1.00, 1.00, 0.10,  4, "RTS-GMLC baseline"),

    # ── Phase 2: load-scaling calibration ───────────────────────────────
    CaseDef("load_scale_105", 1.05, 1.00, 1.00, 0.10,  4, "Load scaled to 105%"),
    CaseDef("load_scale_110", 1.10, 1.00, 1.00, 0.10,  4, "Load scaled to 110%"),
    CaseDef("load_scale_115", 1.15, 1.00, 1.00, 0.10,  4, "Load scaled to 115%"),
    CaseDef("load_scale_120", 1.20, 1.00, 1.00, 0.10,  4, "Load scaled to 120%"),

    # ── Phase 3: storage duration × penetration matrix ───────────────────
    CaseDef("storage_p05_d2",  1.00, 1.00, 1.00, 0.05,  2, "Storage 5% peak, 2-hour"),
    CaseDef("storage_p05_d4",  1.00, 1.00, 1.00, 0.05,  4, "Storage 5% peak, 4-hour"),
    CaseDef("storage_p05_d8",  1.00, 1.00, 1.00, 0.05,  8, "Storage 5% peak, 8-hour"),
    CaseDef("storage_p05_d12", 1.00, 1.00, 1.00, 0.05, 12, "Storage 5% peak, 12-hour"),
    CaseDef("storage_p10_d2",  1.00, 1.00, 1.00, 0.10,  2, "Storage 10% peak, 2-hour"),
    CaseDef("storage_p10_d4",  1.00, 1.00, 1.00, 0.10,  4, "Storage 10% peak, 4-hour"),
    CaseDef("storage_p10_d8",  1.00, 1.00, 1.00, 0.10,  8, "Storage 10% peak, 8-hour"),
    CaseDef("storage_p10_d12", 1.00, 1.00, 1.00, 0.10, 12, "Storage 10% peak, 12-hour"),
    CaseDef("storage_p20_d2",  1.00, 1.00, 1.00, 0.20,  2, "Storage 20% peak, 2-hour"),
    CaseDef("storage_p20_d4",  1.00, 1.00, 1.00, 0.20,  4, "Storage 20% peak, 4-hour"),
    CaseDef("storage_p20_d8",  1.00, 1.00, 1.00, 0.20,  8, "Storage 20% peak, 8-hour"),
    CaseDef("storage_p20_d12", 1.00, 1.00, 1.00, 0.20, 12, "Storage 20% peak, 12-hour"),

    # ── Phase 4: VRE profile sensitivity ─────────────────────────────────
    CaseDef("vre_balanced_2x", 1.00, 2.00, 2.00, 0.10,  4, "Balanced high VRE (2x wind, 2x solar)"),
    CaseDef("vre_solar_heavy", 1.00, 1.00, 3.00, 0.10,  4, "Solar-heavy (1x wind, 3x solar)"),
    CaseDef("vre_wind_heavy",  1.00, 3.00, 1.00, 0.10,  8, "Wind-heavy (3x wind, 1x solar)"),
]

# ── helpers ───────────────────────────────────────────────────────────────────
function _vre_type(row)::String
    t = get(row, :vre_type, missing)
    ismissing(t) ? "" : string(t)
end

function _storage_id(pct::Float64, dur::Int)::String
    pct_str = string(round(Int, pct * 100))
    pct_padded = length(pct_str) == 1 ? "0$pct_str" : pct_str
    return "BAT_$(dur)H_$(pct_padded)PCT"
end

# ── per-case builder ──────────────────────────────────────────────────────────
function build_case(c::CaseDef,
                    base_gen::DataFrame, base_load::DataFrame,
                    base_wind::DataFrame, base_solar::DataFrame,
                    out_dir::String)::DataFrame

    mkpath(out_dir)

    # ── generators: scale VRE Pmax, leave thermal unchanged ──────────────
    new_gen = copy(base_gen)
    for i in axes(new_gen, 1)
        vt = _vre_type(new_gen[i, :])
        if vt == "wind"
            new_gen[i, :pmax_mw] = new_gen[i, :pmax_mw] * c.wind_scale
            new_gen[i, :pmin_mw] = new_gen[i, :pmin_mw] * c.wind_scale
        elseif vt == "solar"
            new_gen[i, :pmax_mw] = new_gen[i, :pmax_mw] * c.solar_scale
            new_gen[i, :pmin_mw] = new_gen[i, :pmin_mw] * c.solar_scale
        end
    end

    # ── load: scale uniformly ─────────────────────────────────────────────
    new_load = DataFrame(
        hour    = base_load.hour,
        load_mw = base_load.load_mw .* c.load_scale,
    )

    # ── storage: recompute from scaled peak load ──────────────────────────
    peak_load      = maximum(new_load.load_mw)
    stor_power_mw  = round(c.storage_power_pct_peak * peak_load; digits = 0)
    stor_energy_mwh = stor_power_mw * c.storage_duration_hours
    new_stor = DataFrame(
        storage_id            = [_storage_id(c.storage_power_pct_peak,
                                             c.storage_duration_hours)],
        power_mw              = [stor_power_mw],
        energy_mwh            = [stor_energy_mwh],
        charge_efficiency     = [ETA],
        discharge_efficiency  = [ETA],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [0.5 * stor_energy_mwh],
    )

    # ── wind and solar CFs are unchanged (only Pmax was scaled) ──────────
    CSV.write(joinpath(out_dir, "generators.csv"),       new_gen)
    CSV.write(joinpath(out_dir, "storage.csv"),          new_stor)
    CSV.write(joinpath(out_dir, "load_timeseries.csv"),  new_load)
    CSV.write(joinpath(out_dir, "wind_timeseries.csv"),  base_wind)
    CSV.write(joinpath(out_dir, "solar_timeseries.csv"), base_solar)

    # ── metadata ──────────────────────────────────────────────────────────
    therm  = filter(r -> r.is_thermal == 1, new_gen)
    wind_g = filter(r -> _vre_type(r) == "wind",  new_gen)
    sol_g  = filter(r -> _vre_type(r) == "solar", new_gen)

    meta = DataFrame(
        case_name                = [c.name],
        load_scale               = [c.load_scale],
        wind_scale               = [c.wind_scale],
        solar_scale              = [c.solar_scale],
        storage_power_pct_peak   = [c.storage_power_pct_peak],
        storage_duration_hours   = [c.storage_duration_hours],
        storage_power_mw         = [stor_power_mw],
        storage_energy_mwh       = [stor_energy_mwh],
        peak_load_mw             = [round(peak_load;                   digits = 2)],
        annual_load_gwh          = [round(sum(new_load.load_mw) / 1e3, digits = 2)],
        total_thermal_capacity_mw= [isempty(therm)  ? 0.0 : round(sum(therm.pmax_mw);  digits = 1)],
        total_wind_capacity_mw   = [isempty(wind_g) ? 0.0 : round(sum(wind_g.pmax_mw), digits = 1)],
        total_solar_capacity_mw  = [isempty(sol_g)  ? 0.0 : round(sum(sol_g.pmax_mw),  digits = 1)],
        notes                    = [c.notes],
    )
    CSV.write(joinpath(out_dir, "case_metadata.csv"), meta)
    return meta
end

# ── per-case validation ───────────────────────────────────────────────────────
function validate_case(c::CaseDef, out_dir::String)
    for fname in ("generators.csv", "storage.csv",
                  "load_timeseries.csv", "wind_timeseries.csv", "solar_timeseries.csv")
        isfile(joinpath(out_dir, fname)) ||
            error("Case $(c.name): missing file $fname")
    end

    gen_df   = CSV.read(joinpath(out_dir, "generators.csv"),       DataFrame)
    stor_df  = CSV.read(joinpath(out_dir, "storage.csv"),          DataFrame)
    load_df  = CSV.read(joinpath(out_dir, "load_timeseries.csv"),  DataFrame)
    wind_df  = CSV.read(joinpath(out_dir, "wind_timeseries.csv"),  DataFrame)
    solar_df = CSV.read(joinpath(out_dir, "solar_timeseries.csv"), DataFrame)

    nrow(load_df)  == 8760 || error("Case $(c.name): load_timeseries has $(nrow(load_df)) rows (expected 8760)")
    nrow(wind_df)  == 8760 || error("Case $(c.name): wind_timeseries has $(nrow(wind_df)) rows (expected 8760)")
    nrow(solar_df) == 8760 || error("Case $(c.name): solar_timeseries has $(nrow(solar_df)) rows (expected 8760)")

    all(load_df.load_mw .> 0)                      || error("Case $(c.name): load_mw has non-positive values")
    all(0.0 .<= wind_df.wind_cf   .<= 1.0)         || error("Case $(c.name): wind_cf outside [0,1]")
    all(0.0 .<= solar_df.solar_cf .<= 1.0)         || error("Case $(c.name): solar_cf outside [0,1]")
    all(stor_df.power_mw  .> 0)                    || error("Case $(c.name): storage power_mw ≤ 0")
    all(stor_df.energy_mwh .> 0)                   || error("Case $(c.name): storage energy_mwh ≤ 0")

    therm = filter(r -> r.is_thermal == 1, gen_df)
    nrow(therm) > 0 && sum(therm.pmax_mw) > 0 ||
        error("Case $(c.name): no thermal capacity found")
end

# ── main ──────────────────────────────────────────────────────────────────────
let
    project_root = joinpath(@__DIR__, "..")
    base_dir     = joinpath(project_root, "data_processed", "rts_single_zone")
    cases_dir    = joinpath(project_root, "data_processed", "cases")

    # ── load and validate base dataset ────────────────────────────────────
    for fname in ("generators.csv", "storage.csv",
                  "load_timeseries.csv", "wind_timeseries.csv", "solar_timeseries.csv")
        isfile(joinpath(base_dir, fname)) ||
            error("Base file missing: $(joinpath(base_dir, fname))\n" *
                  "Run scripts/01_build_single_zone_rts.jl first.")
    end

    base_load  = CSV.read(joinpath(base_dir, "load_timeseries.csv"),  DataFrame)
    base_wind  = CSV.read(joinpath(base_dir, "wind_timeseries.csv"),  DataFrame)
    base_solar = CSV.read(joinpath(base_dir, "solar_timeseries.csv"), DataFrame)
    base_gen   = CSV.read(joinpath(base_dir, "generators.csv"),       DataFrame)

    n_base = nrow(base_load)
    n_base == 8760 ||
        error("Formal experiment cases require the full RTS-GMLC dataset " *
              "(8760 hours), but the base load_timeseries.csv has $n_base rows.\n" *
              "Run scripts/01_build_single_zone_rts.jl with the RTS-GMLC " *
              "source data present (scripts/00_get_rts_gmlc_data.jl).")

    mkpath(cases_dir)

    @info "Building $(length(CASES)) experiment cases → $cases_dir"

    # ── build every case ──────────────────────────────────────────────────
    index_rows = DataFrame[]
    for c in CASES
        out_dir = joinpath(cases_dir, c.name)
        meta    = build_case(c, base_gen, base_load, base_wind, base_solar, out_dir)
        validate_case(c, out_dir)
        push!(index_rows, meta)
        @info "  ✓ $(c.name)"
    end

    # ── write master case index ───────────────────────────────────────────
    case_index = vcat(index_rows...)
    CSV.write(joinpath(cases_dir, "case_index.csv"), case_index)

    # ── terminal summary table ────────────────────────────────────────────
    println()
    println("=" ^ 100)
    println("Experiment case summary")
    println("=" ^ 100)
    @printf "  %-20s %12s %16s %16s %18s %22s\n" "case_name" "peak_load_mw" "wind_capacity_mw" "solar_capacity_mw" "storage_power_mw" "storage_duration_hours"
    println("  " * "-" ^ 96)
    for r in eachrow(case_index)
        @printf "  %-20s %12.1f %16.1f %16.1f %18.1f %22d\n" r.case_name r.peak_load_mw r.total_wind_capacity_mw r.total_solar_capacity_mw r.storage_power_mw r.storage_duration_hours
    end
    println("=" ^ 100)
    println()
    @info "case_index.csv written to $cases_dir"
    @info "Done — $(length(CASES)) cases built successfully."
end
