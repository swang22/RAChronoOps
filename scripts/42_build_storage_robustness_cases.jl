#!/usr/bin/env julia
# 42_build_storage_robustness_cases.jl
#
# Build storage robustness case variants for Experiments A, B, and C.
#
# Experiment A — Duration sweep (fixed power, vary energy/duration)
#   Variants: dur2h, dur4h (base), dur8h, dur12h
#   Storage power fixed at 983 MW (10% of peak load).
#   Energy = power × duration hours.
#
# Experiment B — Power sweep (fixed 4h duration, vary power)
#   Variants: pwr0p5x, pwr1p0x (base), pwr2p0x
#   Duration fixed at 4h; energy scales with power.
#
# Experiment C — Load stress (baseline storage, elevated load scale)
#   Variants: ls1p225, ls1p25 (load stress only)
#             dur2h_ls1p225, pwr0p5x_ls1p225 (combos with weak storage)
#   Load series is scaled from the source case's load_timeseries.csv.
#   The source load_timeseries.csv corresponds to load_scale=1.2; we derive
#   the raw (scale=1) load and re-apply the target scale.
#
# Source cases: VRE120_base, VRE120_wind_hvy
# Output:  data_processed/storage_robustness_cases/<variant_name>/
# Summary: results/storage_robustness/case_variant_summary.csv
#
# Usage:
#   julia --project=. scripts/42_build_storage_robustness_cases.jl \
#     [--source-cases VRE120_base,VRE120_wind_hvy] \
#     [--data-dir data_processed/cases] \
#     [--out-dir  data_processed/storage_robustness_cases]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using CSV, DataFrames, Printf, Dates

# ── CLI ───────────────────────────────────────────────────────────────────────

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional argument: $arg")
        key = arg[3:end]
        i + 1 <= length(args) && !startswith(args[i+1], "--") ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

# ── Variant definitions ────────────────────────────────────────────────────────

struct StorageVariant
    label          ::String  # suffix appended to source case name
    power_scale    ::Float64 # multiplier on base power_mw
    duration_hours ::Float64 # energy = power × duration
    load_scale     ::Float64 # target load_scale (source load_scale = 1.2)
    experiment     ::String  # "A", "B", or "C"
    description    ::String
end

# Base storage: power=983 MW, duration=4h, load_scale=1.2
BASE_POWER_MW       = 983.0
BASE_DURATION_HOURS = 4.0
BASE_LOAD_SCALE     = 1.2
BASE_CHARGE_EFF     = 0.9486832980505138
BASE_DISCHARGE_EFF  = 0.9486832980505138
BASE_VCOST          = 0.01

const BASE_VARIANTS = StorageVariant[
    # Experiment A — duration sweep (fixed power)
    StorageVariant("dur2h",  1.0, 2.0,  1.2,  "A", "2h duration (983 MW, 1966 MWh)"),
    StorageVariant("dur4h",  1.0, 4.0,  1.2,  "A", "4h duration base (983 MW, 3932 MWh)"),
    StorageVariant("dur8h",  1.0, 8.0,  1.2,  "A", "8h duration (983 MW, 7864 MWh)"),
    StorageVariant("dur12h", 1.0, 12.0, 1.2,  "A", "12h duration (983 MW, 11796 MWh)"),

    # Experiment B — power sweep (fixed 4h duration)
    StorageVariant("pwr0p5x", 0.5, 4.0, 1.2, "B", "0.5x power (491.5 MW, 1966 MWh)"),
    StorageVariant("pwr1p0x", 1.0, 4.0, 1.2, "B", "1.0x power base (983 MW, 3932 MWh)"),
    StorageVariant("pwr2p0x", 2.0, 4.0, 1.2, "B", "2.0x power (1966 MW, 7864 MWh)"),
]

# Experiment C: base + wind-heavy source cases with load stress
const BASE_C_VARIANTS = StorageVariant[
    StorageVariant("ls1p225",          1.0, 4.0,  1.225, "C", "Load scale 1.225 (base storage)"),
    StorageVariant("ls1p25",           1.0, 4.0,  1.25,  "C", "Load scale 1.25  (base storage)"),
    StorageVariant("dur2h_ls1p225",    1.0, 2.0,  1.225, "C", "2h storage + load scale 1.225"),
    StorageVariant("pwr0p5x_ls1p225",  0.5, 4.0,  1.225, "C", "0.5x power + load scale 1.225"),
]

# ── Case builder ──────────────────────────────────────────────────────────────

function build_variant(src_dir::String, dst_dir::String, v::StorageVariant,
                       src_meta::DataFrameRow)
    mkpath(dst_dir)

    power_mw    = BASE_POWER_MW * v.power_scale
    energy_mwh  = power_mw * v.duration_hours
    init_soc    = energy_mwh / 2.0   # 50% initial SOC

    # ── storage.csv ──────────────────────────────────────────────────────────
    stor_id = @sprintf("BAT_%dH_%dPCT",
                       round(Int, v.duration_hours),
                       round(Int, v.power_scale * 10))
    stor_df = DataFrame(
        storage_id            = [stor_id],
        power_mw              = [power_mw],
        energy_mwh            = [energy_mwh],
        charge_efficiency     = [BASE_CHARGE_EFF],
        discharge_efficiency  = [BASE_DISCHARGE_EFF],
        variable_cost_per_mwh = [BASE_VCOST],
        initial_soc_mwh       = [init_soc],
    )
    CSV.write(joinpath(dst_dir, "storage.csv"), stor_df)

    # ── generators.csv ───────────────────────────────────────────────────────
    cp(joinpath(src_dir, "generators.csv"), joinpath(dst_dir, "generators.csv"); force=true)

    # ── wind and solar timeseries ─────────────────────────────────────────────
    cp(joinpath(src_dir, "wind_timeseries.csv"),
       joinpath(dst_dir, "wind_timeseries.csv"); force=true)
    cp(joinpath(src_dir, "solar_timeseries.csv"),
       joinpath(dst_dir, "solar_timeseries.csv"); force=true)

    # ── load_timeseries.csv (rescale if needed) ───────────────────────────────
    src_load_scale = src_meta[:load_scale]
    if abs(v.load_scale - src_load_scale) < 1e-9
        cp(joinpath(src_dir, "load_timeseries.csv"),
           joinpath(dst_dir, "load_timeseries.csv"); force=true)
    else
        # Derive raw (scale=1) from the source series, then re-scale.
        load_df = CSV.read(joinpath(src_dir, "load_timeseries.csv"), DataFrame)
        load_df[!, :load_mw] = load_df[!, :load_mw] .* (v.load_scale / src_load_scale)
        CSV.write(joinpath(dst_dir, "load_timeseries.csv"), load_df)
    end

    # ── case_metadata.csv ─────────────────────────────────────────────────────
    peak_load_mw  = maximum(CSV.read(joinpath(dst_dir, "load_timeseries.csv"),
                                     DataFrame)[!, :load_mw])
    annual_gwh    = sum(CSV.read(joinpath(dst_dir, "load_timeseries.csv"),
                                 DataFrame)[!, :load_mw]) / 1000.0
    # Reuse thermal/wind/solar capacity from source metadata
    meta_df = DataFrame(
        case_name              = [basename(dst_dir)],
        load_scale             = [v.load_scale],
        wind_scale             = [src_meta[:wind_scale]],
        solar_scale            = [src_meta[:solar_scale]],
        storage_power_pct_peak = [power_mw / peak_load_mw * 100.0],
        storage_duration_hours = [v.duration_hours],
        storage_power_mw       = [power_mw],
        storage_energy_mwh     = [energy_mwh],
        peak_load_mw           = [peak_load_mw],
        annual_load_gwh        = [round(annual_gwh, digits=2)],
        total_thermal_capacity_mw = [src_meta[:total_thermal_capacity_mw]],
        total_wind_capacity_mw    = [src_meta[:total_wind_capacity_mw]],
        total_solar_capacity_mw   = [src_meta[:total_solar_capacity_mw]],
        notes                  = ["$(v.description); source=$(basename(src_dir))"],
    )
    CSV.write(joinpath(dst_dir, "case_metadata.csv"), meta_df)

    return (power_mw=power_mw, energy_mwh=energy_mwh, peak_load_mw=peak_load_mw)
end

function validate_variant(dst_dir::String, expected_energy::Float64)
    required = ["generators.csv", "storage.csv", "load_timeseries.csv",
                "wind_timeseries.csv", "solar_timeseries.csv"]
    missing_f = filter(f -> !isfile(joinpath(dst_dir, f)), required)
    isempty(missing_f) || error("Missing files in $dst_dir: $missing_f")

    stor = CSV.read(joinpath(dst_dir, "storage.csv"), DataFrame)
    n_stor = size(stor, 1)
    if n_stor != 1
        error("Expected 1 storage row, got $n_stor")
    end
    if abs(stor[1, :energy_mwh] - expected_energy) >= 1.0
        error("Energy mismatch: expected $expected_energy, got $(stor[1, :energy_mwh])")
    end
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    src_cases_s = get(kw, "source-cases", "VRE120_base,VRE120_wind_hvy")
    data_dir    = abspath(get(kw, "data-dir",
                    joinpath(@__DIR__, "..", "data_processed", "cases")))
    out_dir     = abspath(get(kw, "out-dir",
                    joinpath(@__DIR__, "..", "data_processed", "storage_robustness_cases")))

    src_cases = String.(strip.(split(src_cases_s, ",")))

    println("=" ^ 70)
    println("42_build_storage_robustness_cases.jl")
    println("Date: ", Dates.now())
    println("Source cases: ", join(src_cases, ", "))
    println("Source data:  ", data_dir)
    println("Output dir:   ", out_dir)
    println("=" ^ 70)

    mkpath(out_dir)
    results_dir = abspath(joinpath(@__DIR__, "..", "results", "storage_robustness"))
    mkpath(results_dir)

    summary_rows = NamedTuple[]

    for src_case in src_cases
        src_dir = joinpath(data_dir, src_case)
        isdir(src_dir) || begin
            @printf("  SKIP %-30s (not found)\n", src_case)
            continue
        end

        meta_df  = CSV.read(joinpath(src_dir, "case_metadata.csv"), DataFrame)
        src_meta = first(eachrow(meta_df))

        println("\n── Source: $src_case ──────────────────────────────────────────")

        # Choose variants: Exp A+B for all source cases; Exp C for base only
        variants = src_case == "VRE120_base" ?
                   vcat(BASE_VARIANTS, BASE_C_VARIANTS) :
                   BASE_VARIANTS

        for v in variants
            dst_name = "$(src_case)_$(v.label)"
            dst_dir  = joinpath(out_dir, dst_name)

            expected_energy = BASE_POWER_MW * v.power_scale * v.duration_hours
            print("  $(dst_name) … ")

            try
                stats = build_variant(src_dir, dst_dir, v, src_meta)
                validate_variant(dst_dir, expected_energy)

                @printf("OK  (power=%.0f MW, energy=%.0f MWh, load_scale=%.3f)\n",
                        stats.power_mw, stats.energy_mwh, v.load_scale)

                push!(summary_rows, (
                    source_case    = src_case,
                    variant_name   = dst_name,
                    experiment     = v.experiment,
                    power_mw       = stats.power_mw,
                    energy_mwh     = stats.energy_mwh,
                    duration_h     = v.duration_hours,
                    power_scale    = v.power_scale,
                    load_scale     = v.load_scale,
                    peak_load_mw   = stats.peak_load_mw,
                    out_dir        = dst_dir,
                    status         = "OK",
                    description    = v.description,
                ))
            catch e
                println("ERROR: $e")
                push!(summary_rows, (
                    source_case    = src_case,
                    variant_name   = dst_name,
                    experiment     = v.experiment,
                    power_mw       = BASE_POWER_MW * v.power_scale,
                    energy_mwh     = expected_energy,
                    duration_h     = v.duration_hours,
                    power_scale    = v.power_scale,
                    load_scale     = v.load_scale,
                    peak_load_mw   = 0.0,
                    out_dir        = dst_dir,
                    status         = "ERROR: $e",
                    description    = v.description,
                ))
            end
        end
    end

    # ── Write summary CSV ─────────────────────────────────────────────────────
    summary_path = joinpath(results_dir, "case_variant_summary.csv")
    CSV.write(summary_path, DataFrame(summary_rows))
    println()
    println("Case variant summary → $summary_path")
    println()

    n_ok  = count(r -> r.status == "OK", summary_rows)
    n_err = count(r -> r.status != "OK", summary_rows)
    println("Built: $n_ok OK, $n_err errors")
    if n_ok > 0
        println()
        println("Variant listing:")
        @printf("  %-45s  %-4s  %8s  %9s  %6s  %6s\n",
                "Variant", "Exp", "Power MW", "Energy MWh", "Dur h", "LScale")
        println("  " * "-"^80)
        for r in filter(x -> x.status == "OK", summary_rows)
            @printf("  %-45s  %-4s  %8.0f  %9.0f  %6.1f  %6.3f\n",
                    r.variant_name, r.experiment, r.power_mw, r.energy_mwh,
                    r.duration_h, r.load_scale)
        end
    end
    n_err > 0 && println("\nWARNING: $n_err variants had errors — see above.")
end

main()
