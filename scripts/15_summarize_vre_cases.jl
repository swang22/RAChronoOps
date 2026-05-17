#!/usr/bin/env julia
# 15_summarize_vre_cases.jl
#
# Reads the six VRE120 case folders built by 06_build_experiment_cases.jl,
# computes VRE penetration / system statistics, and writes:
#   results/vre_method_comparison/vre_case_summary.csv
#
# Usage:
#   julia --project=. scripts/15_summarize_vre_cases.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using CSV, DataFrames, Statistics, Printf

const VRE120_CASES = [
    "VRE120_base",
    "VRE120_bal15",
    "VRE120_bal20",
    "VRE120_bal30",
    "VRE120_solar_hvy",
    "VRE120_wind_hvy",
]

function summarize_case(case_dir::String)::DataFrameRow
    meta      = CSV.read(joinpath(case_dir, "case_metadata.csv"),    DataFrame)
    load_df   = CSV.read(joinpath(case_dir, "load_timeseries.csv"),  DataFrame)
    wind_df   = CSV.read(joinpath(case_dir, "wind_timeseries.csv"),  DataFrame)
    solar_df  = CSV.read(joinpath(case_dir, "solar_timeseries.csv"), DataFrame)

    m = first(meta)

    wind_cap_mw  = m.total_wind_capacity_mw
    solar_cap_mw = m.total_solar_capacity_mw
    therm_cap_mw = m.total_thermal_capacity_mw

    wind_avail_mw  = wind_df.wind_cf  .* wind_cap_mw
    solar_avail_mw = solar_df.solar_cf .* solar_cap_mw
    vre_avail_mw   = wind_avail_mw .+ solar_avail_mw
    net_load_mw    = load_df.load_mw .- vre_avail_mw

    total_vre_cap      = wind_cap_mw + solar_cap_mw
    vre_cap_share      = total_vre_cap / (therm_cap_mw + total_vre_cap)
    avail_wind_gwh     = sum(wind_avail_mw)  / 1e3
    avail_solar_gwh    = sum(solar_avail_mw) / 1e3
    avail_vre_gwh      = avail_wind_gwh + avail_solar_gwh
    annual_load_gwh    = m.annual_load_gwh
    vre_energy_share   = avail_vre_gwh / annual_load_gwh
    curtail_proxy_gwh  = sum(max.(0.0, -net_load_mw)) / 1e3
    min_net_load       = minimum(net_load_mw)
    n_neg_net_load     = count(<(0.0), net_load_mw)

    row = DataFrame(
        case_name                    = m.case_name,
        load_scale                   = m.load_scale,
        wind_scale                   = m.wind_scale,
        solar_scale                  = m.solar_scale,
        storage_power_pct_peak       = m.storage_power_pct_peak,
        storage_duration_hours       = m.storage_duration_hours,
        storage_power_mw             = m.storage_power_mw,
        storage_energy_mwh           = m.storage_energy_mwh,
        peak_load_mw                 = m.peak_load_mw,
        annual_load_gwh              = round(annual_load_gwh;      digits = 2),
        total_thermal_capacity_mw    = round(therm_cap_mw;         digits = 1),
        total_wind_capacity_mw       = round(wind_cap_mw;          digits = 1),
        total_solar_capacity_mw      = round(solar_cap_mw;         digits = 1),
        total_vre_capacity_mw        = round(total_vre_cap;        digits = 1),
        vre_capacity_share_no_storage= round(vre_cap_share;        digits = 4),
        available_wind_energy_gwh    = round(avail_wind_gwh;       digits = 2),
        available_solar_energy_gwh   = round(avail_solar_gwh;      digits = 2),
        available_vre_energy_gwh     = round(avail_vre_gwh;        digits = 2),
        available_vre_energy_share   = round(vre_energy_share;     digits = 4),
        vre_potential_curtailment_gwh= round(curtail_proxy_gwh;    digits = 2),
        min_net_load_mw              = round(min_net_load;         digits = 1),
        n_hours_negative_net_load    = n_neg_net_load,
        notes                        = m.notes,
    )
    return first(row)
end

let
    project_root = joinpath(@__DIR__, "..")
    cases_dir    = joinpath(project_root, "data_processed", "cases")
    out_dir      = joinpath(project_root, "results", "vre_method_comparison")
    mkpath(out_dir)

    @info "Summarizing $(length(VRE120_CASES)) VRE120 cases from $cases_dir"

    rows = DataFrame[]
    for name in VRE120_CASES
        case_dir = joinpath(cases_dir, name)
        isdir(case_dir) ||
            error("Case folder not found: $case_dir\n" *
                  "Run scripts/06_build_experiment_cases.jl first.")
        row_df = DataFrame([summarize_case(case_dir)])
        push!(rows, row_df)
        @info "  ✓ $name"
    end

    summary = vcat(rows...)
    out_path = joinpath(out_dir, "vre_case_summary.csv")
    CSV.write(out_path, summary)

    # ── terminal table ────────────────────────────────────────────────────────
    println()
    println("=" ^ 110)
    println("VRE120 Case Summary")
    println("=" ^ 110)
    @printf("  %-20s %9s %9s %10s %10s %10s %10s %10s\n",
            "case_name", "peak_load", "wind_cap", "solar_cap",
            "VRE_share", "VRE_avail", "vre_e_shr", "neg_NL_h")
    @printf("  %-20s %9s %9s %10s %10s %10s %10s %10s\n",
            "", "(MW)", "(MW)", "(MW)", "(cap)", "(GWh)", "(frac)", "(h)")
    println("  " * "-" ^ 106)
    for r in eachrow(summary)
        @printf("  %-20s %9.1f %9.1f %10.1f %10.4f %10.1f %10.4f %10d\n",
                r.case_name,
                r.peak_load_mw,
                r.total_wind_capacity_mw,
                r.total_solar_capacity_mw,
                r.vre_capacity_share_no_storage,
                r.available_vre_energy_gwh,
                r.available_vre_energy_share,
                r.n_hours_negative_net_load)
    end
    println("=" ^ 110)
    println()
    @info "vre_case_summary.csv written → $out_path"
    @info "Done — $(nrow(summary)) cases summarized."
end
