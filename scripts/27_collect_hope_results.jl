#!/usr/bin/env julia
# 27_collect_hope_results.jl
#
# Parses HOPE full-year PCM outputs from completed smoke runs and computes
# standard RAChronoOps reliability metrics for each case.
#
# Usage:
#   julia --project=. scripts/27_collect_hope_results.jl \
#     --hope-cases-dir exports/hope_model_cases \
#     --case-folders RAChronoOps_VRE120_base_s001_ED,RAChronoOps_VRE120_base_s001_UC \
#     --out-dir results/hope_smoke_runs
#
# Options:
#   --hope-cases-dir  Root directory containing HOPE case folders (default: exports/hope_model_cases)
#   --case-folders    Comma-separated case folder names to process (required)
#   --out-dir         Output directory (default: results/hope_smoke_runs)
#   --runtimes        Optional comma-separated observed solve times (seconds),
#                     in the same order as --case-folders; use NaN for unknown
#
# Outputs:
#   <out-dir>/hope_smoke_metrics.csv       -- one row per case, all reliability metrics
#   <out-dir>/hope_load_shed_hourly.csv    -- non-zero load-shed hours (long format)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Statistics, Printf

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

# ── Helpers ───────────────────────────────────────────────────────────────────

function parse_mode_from_folder(folder::String)::String
    # Folder naming convention: ..._ED or ..._UC (case-insensitive)
    u = uppercase(folder)
    endswith(u, "_UC") && return "UC"
    endswith(u, "_ED") && return "ED"
    return "UNKNOWN"
end

function load_hope_loadshed(csv_path::String)::Tuple{Vector{Float64}, Float64}
    isfile(csv_path) || error("HOPE load shedding CSV not found:\n  $csv_path")
    df = CSV.read(csv_path, DataFrame)
    size(df, 1) >= 1 || error("Empty load shedding file: $csv_path")

    row = df[1, :]   # single-zone: first (and only) zone row
    ann_tol = Float64(row[:AnnTol])

    n_hours = 8760
    load_shed = Vector{Float64}(undef, n_hours)
    for h in 1:n_hours
        load_shed[h] = Float64(row[Symbol("h$h")])
    end
    return load_shed, ann_tol
end

function compute_hope_metrics(case_folder::String,
                               mode      ::String,
                               load_shed ::Vector{Float64},
                               ann_tol   ::Float64;
                               runtime_s ::Float64 = NaN)

    n_hours   = length(load_shed)
    lolh      = compute_lolh(load_shed)
    lolp_pct  = 100.0 * compute_lolp(lolh, n_hours)
    lole_days = compute_lole_days(load_shed)
    eue       = compute_eue(load_shed)
    ann_err   = ann_tol > 0.0 ? abs(eue - ann_tol) / ann_tol * 100.0 : 0.0
    max_sf    = maximum(load_shed)   # load_shed is 8760 elements, never empty
    durations = compute_shortage_events(load_shed)
    n_events  = length(durations)
    fdur      = Float64.(durations)
    mean_dur  = isempty(fdur) ? 0.0 : mean(fdur)
    p95_dur   = isempty(fdur) ? 0.0 : quantile(fdur, 0.95)

    return (
        case_folder              = case_folder,
        mode                     = mode,
        lolh                     = lolh,
        lolp_percent             = lolp_pct,
        lole_days                = lole_days,
        eue_mwh                  = eue,
        ann_tol_mwh              = ann_tol,
        eue_ann_tol_error_pct    = ann_err,
        cvar_eue_mwh             = eue,      # single deterministic run: CVaR = EUE
        max_shortfall_mw         = max_sf,
        n_shortage_events        = n_events,
        mean_shortage_duration_h = mean_dur,
        p95_shortage_duration_h  = p95_dur,
        runtime_s                = runtime_s,
    )
end

# ── Main ──────────────────────────────────────────────────────────────────────

let
    kw = parse_cli(ARGS)

    hope_cases_dir = get(kw, "hope-cases-dir",
                         joinpath(@__DIR__, "..", "exports", "hope_model_cases"))
    case_folders_raw = get(kw, "case-folders", "")
    isempty(case_folders_raw) && error("--case-folders is required")
    case_folders = String.(split(case_folders_raw, ","))
    out_dir = get(kw, "out-dir",
                  joinpath(@__DIR__, "..", "results", "hope_smoke_runs"))

    # Optional per-case observed runtimes (comma-separated seconds)
    runtimes_raw = get(kw, "runtimes", "")
    runtimes = if isempty(runtimes_raw)
        fill(NaN, length(case_folders))
    else
        vals = parse.(Float64, split(runtimes_raw, ","))
        length(vals) == length(case_folders) ||
            error("--runtimes has $(length(vals)) values but --case-folders has $(length(case_folders))")
        vals
    end

    # Optional output filename override (default keeps backward-compat name)
    metrics_name = get(kw, "metrics-name", "hope_smoke_metrics.csv")

    mkpath(out_dir)

    println("="^72)
    println("HOPE Smoke Run Results Collection")
    println("="^72)
    println("  Hope cases dir : $hope_cases_dir")
    println("  Cases          : $(length(case_folders))")
    println("  Output dir     : $out_dir")
    println()

    metrics_rows = NamedTuple[]
    hourly_rows  = NamedTuple[]

    for (idx, folder) in enumerate(case_folders)
        csv_path = joinpath(hope_cases_dir, folder, "output", "power_loadshedding.csv")
        println("Processing: $folder")

        load_shed, ann_tol = load_hope_loadshed(csv_path)
        mode = parse_mode_from_folder(folder)

        # AnnTol sanity check
        s = sum(load_shed)
        if ann_tol > 0.0
            rel_err = abs(s - ann_tol) / ann_tol * 100.0
            if rel_err > 0.01
                @warn "AnnTol mismatch for $folder: AnnTol=$ann_tol, sum(hourly)=$s ($(round(rel_err, digits=4))%)"
            end
        end

        m = compute_hope_metrics(folder, mode, load_shed, ann_tol;
                                 runtime_s = runtimes[idx])
        push!(metrics_rows, m)

        # Collect non-zero hourly rows for the hourly output
        for h in eachindex(load_shed)
            if load_shed[h] > 0.0
                push!(hourly_rows, (case_folder = folder,
                                    mode        = mode,
                                    hour        = h,
                                    load_shed_mw = load_shed[h]))
            end
        end

        @printf("  %-50s  mode=%-3s  LOLH=%4.0f h  EUE=%9.1f MWh  events=%d\n",
                folder, mode, m.lolh, m.eue_mwh, m.n_shortage_events)
    end

    # Write metrics CSV
    metrics_df  = DataFrame(metrics_rows)
    metrics_path = joinpath(out_dir, metrics_name)
    CSV.write(metrics_path, metrics_df)
    println("\nWritten: $metrics_path")

    # Write hourly load shed (non-zero rows only, long format)
    hourly_df   = isempty(hourly_rows) ? DataFrame(case_folder=String[], mode=String[],
                                                    hour=Int[], load_shed_mw=Float64[]) :
                                          DataFrame(hourly_rows)
    hourly_path = joinpath(out_dir, "hope_load_shed_hourly.csv")
    CSV.write(hourly_path, hourly_df)
    println("Written: $hourly_path  ($(size(hourly_df, 1)) non-zero rows)")

    println("\nDone.")
end
