#!/usr/bin/env julia
# 04_summarize_processed_data.jl
#
# Reads data_processed/rts_single_zone/ and writes three summary CSVs to
# results/data_summary/, then prints a concise report to the terminal.
#
# Output files:
#   results/data_summary/system_summary.csv    — one-row system-level stats
#   results/data_summary/generation_mix.csv    — one row per generator group
#   results/data_summary/time_series_summary.csv — one-row time-series stats
#
# Usage:
#   julia --project=. scripts/04_summarize_processed_data.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Statistics
using Printf

let
    project_root = joinpath(@__DIR__, "..")
    data_dir     = joinpath(project_root, "data_processed", "rts_single_zone")
    out_dir      = joinpath(project_root, "results", "data_summary")
    mkpath(out_dir)

    sys = load_system_data(data_dir)

    # Coerce missing vre_type (empty CSV cells) to "" before any grouping or comparison.
    gen  = transform(sys.generators, :vre_type => (x -> coalesce.(x, "")) => :vre_type)
    stor = sys.storage

    wind_cap  = wind_capacity_mw(sys)
    solar_cap = solar_capacity_mw(sys)

    # ── derived series ────────────────────────────────────────────────────
    wind_gen  = wind_cap  .* sys.wind_cf    # MW generated each hour
    solar_gen = solar_cap .* sys.solar_cf
    net_load  = sys.load_mw .- wind_gen .- solar_gen

    # ─────────────────────────────────────────────────────────────────────
    # 1. system_summary.csv
    # ─────────────────────────────────────────────────────────────────────
    therm_df = filter(r -> r.is_thermal == 1, gen)
    wind_df  = filter(r -> r.is_vre == 1 && r.vre_type == "wind",  gen)
    solar_df = filter(r -> r.is_vre == 1 && r.vre_type == "solar", gen)

    total_stor_power  = isempty(stor) ? 0.0 : sum(stor.power_mw)
    total_stor_energy = isempty(stor) ? 0.0 : sum(stor.energy_mwh)
    stor_duration     = total_stor_power > 0.0 ?
                            total_stor_energy / total_stor_power : 0.0

    wind_cf_annual  = wind_cap  > 0.0 ? mean(sys.wind_cf)  : 0.0
    solar_cf_annual = solar_cap > 0.0 ? mean(sys.solar_cf) : 0.0

    sys_df = DataFrame(
        n_hours                  = sys.n_hours,
        annual_load_gwh          = round(sum(sys.load_mw) / 1e3, digits=2),
        peak_load_mw             = round(maximum(sys.load_mw),   digits=2),
        total_thermal_capacity_mw= isempty(therm_df) ? 0.0 : sum(therm_df.pmax_mw),
        total_wind_capacity_mw   = wind_cap,
        total_solar_capacity_mw  = solar_cap,
        total_storage_power_mw   = total_stor_power,
        total_storage_energy_mwh = total_stor_energy,
        storage_duration_hours   = round(stor_duration,     digits=2),
        wind_annual_capacity_factor  = round(wind_cf_annual,  digits=4),
        solar_annual_capacity_factor = round(solar_cf_annual, digits=4),
    )
    CSV.write(joinpath(out_dir, "system_summary.csv"), sys_df)

    # ─────────────────────────────────────────────────────────────────────
    # 2. generation_mix.csv
    # ─────────────────────────────────────────────────────────────────────
    gdf = groupby(gen, [:gen_type, :fuel, :is_thermal, :is_vre, :vre_type])
    mix_df = combine(gdf,
        nrow                    => :number_of_units,
        :pmax_mw                => sum  => :total_capacity_mw,
        :forced_outage_rate     => mean => :mean_for,
        :mean_repair_time_hours => mean => :mean_mttr_hours,
        :variable_cost_per_mwh  => minimum => :min_variable_cost,
        :variable_cost_per_mwh  => mean    => :mean_variable_cost,
        :variable_cost_per_mwh  => maximum => :max_variable_cost,
    )
    CSV.write(joinpath(out_dir, "generation_mix.csv"), mix_df)

    # ─────────────────────────────────────────────────────────────────────
    # 3. time_series_summary.csv
    # ─────────────────────────────────────────────────────────────────────
    ts_df = DataFrame(
        load_min_mw      = round(minimum(sys.load_mw), digits=2),
        load_mean_mw     = round(mean(sys.load_mw),    digits=2),
        load_peak_mw     = round(maximum(sys.load_mw), digits=2),
        wind_cf_mean     = round(mean(sys.wind_cf),    digits=4),
        wind_cf_max      = round(maximum(sys.wind_cf), digits=4),
        solar_cf_mean    = round(mean(sys.solar_cf),   digits=4),
        solar_cf_max     = round(maximum(sys.solar_cf),digits=4),
        net_load_min_mw  = round(minimum(net_load),    digits=2),
        net_load_mean_mw = round(mean(net_load),       digits=2),
        net_load_peak_mw = round(maximum(net_load),    digits=2),
    )
    CSV.write(joinpath(out_dir, "time_series_summary.csv"), ts_df)

    # ─────────────────────────────────────────────────────────────────────
    # Terminal summary
    # ─────────────────────────────────────────────────────────────────────
    println()
    println("=" ^ 60)
    println("System Summary  ($(sys.n_hours) hours)")
    println("=" ^ 60)
    @printf "  Annual load        : %8.1f GWh\n"  sys_df.annual_load_gwh[1]
    @printf "  Peak load          : %8.1f MW\n"   sys_df.peak_load_mw[1]
    println()
    @printf "  Thermal capacity   : %8.1f MW  (%d units)\n" sys_df.total_thermal_capacity_mw[1] nrow(therm_df)
    @printf "  Wind capacity      : %8.1f MW  (CF %.1f%%)\n" wind_cap (wind_cf_annual * 100)
    @printf "  Solar capacity     : %8.1f MW  (CF %.1f%%)\n" solar_cap (solar_cf_annual * 100)
    @printf "  Storage            : %8.1f MW / %.0f MWh (%.1f h)\n" total_stor_power total_stor_energy stor_duration
    println()
    println("Generation mix:")
    println("  " * "-" ^ 56)
    @printf "  %-12s %-8s %8s %8s %8s\n" "Type" "Fuel" "Cap(MW)" "FOR" "VOM(\$/MWh)"
    println("  " * "-" ^ 56)
    for r in eachrow(mix_df)
        label = r.vre_type == "" ? r.gen_type : "$(r.gen_type)($(r.vre_type))"
        @printf "  %-12s %-8s %8.1f %8.3f %8.2f\n" label r.fuel r.total_capacity_mw r.mean_for r.mean_variable_cost
    end
    println()
    println("Time-series stats:")
    @printf "  Load     : min %6.1f  mean %6.1f  peak %6.1f MW\n" ts_df.load_min_mw[1] ts_df.load_mean_mw[1] ts_df.load_peak_mw[1]
    @printf "  Net load : min %6.1f  mean %6.1f  peak %6.1f MW\n" ts_df.net_load_min_mw[1] ts_df.net_load_mean_mw[1] ts_df.net_load_peak_mw[1]
    @printf "  Wind CF  :           mean %6.4f  max  %6.4f\n" ts_df.wind_cf_mean[1] ts_df.wind_cf_max[1]
    @printf "  Solar CF :           mean %6.4f  max  %6.4f\n" ts_df.solar_cf_mean[1] ts_df.solar_cf_max[1]
    println("=" ^ 60)
    println("Results written to $out_dir")
end
