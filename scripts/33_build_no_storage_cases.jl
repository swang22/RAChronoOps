#!/usr/bin/env julia
# 33_build_no_storage_cases.jl
#
# Create no-storage variants of existing processed cases by zeroing out
# the storage CSV.  All time-series and generator data are copied unchanged;
# storage.csv is overwritten with the header only (zero rows) so that
# load_system_data returns n_stor=0 and all dispatch models skip storage.
#
# The resulting case directories are named <source_case>_nostorage and live
# alongside the source cases in data_processed/cases/.
#
# Usage:
#   julia --project=. scripts/33_build_no_storage_cases.jl \
#     [--cases VRE120_base,VRE120_wind_hvy,VRE120_bal15] \
#     [--data-dir data_processed/cases]
#
# Options:
#   --cases     Comma-separated source case names
#               (default: VRE120_base,VRE120_wind_hvy,VRE120_bal15)
#   --data-dir  Root directory for processed cases (default: data_processed/cases)

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

# ── Main ──────────────────────────────────────────────────────────────────────

function build_no_storage_case(src_dir::String, dst_dir::String)
    isdir(src_dir) || error("Source case directory not found: $src_dir")
    mkpath(dst_dir)

    # Copy all CSV files except storage.csv
    for fname in readdir(src_dir)
        endswith(fname, ".csv") || continue
        src_path = joinpath(src_dir, fname)
        dst_path = joinpath(dst_dir, fname)
        if fname == "storage.csv"
            # Write header-only storage.csv so n_stor = 0 in all models
            hdr = first(eachline(src_path))   # read column header line
            open(dst_path, "w") do io
                println(io, hdr)
            end
        else
            cp(src_path, dst_path; force=true)
        end
    end

    # Update case_name field in case_metadata.csv if present
    meta_path = joinpath(dst_dir, "case_metadata.csv")
    if isfile(meta_path)
        meta = CSV.read(meta_path, DataFrame)
        if "case_name" in names(meta)
            meta[!, :case_name] .= basename(dst_dir)
            CSV.write(meta_path, meta)
        end
    end
end

function validate_case(case_dir::String)
    required = ["generators.csv", "storage.csv",
                "load_timeseries.csv", "wind_timeseries.csv",
                "solar_timeseries.csv"]
    missing_files = filter(f -> !isfile(joinpath(case_dir, f)), required)
    isempty(missing_files) || error("Missing files in $case_dir: $missing_files")

    # Confirm storage is empty (header only)
    stor = CSV.read(joinpath(case_dir, "storage.csv"), DataFrame)
    n_stor = size(stor, 1)
    if n_stor != 0
        error("Expected 0 storage rows in $(case_dir)/storage.csv, got $n_stor")
    end
end

function main()
    kw = parse_cli(ARGS)

    cases_str = get(kw, "cases", "VRE120_base,VRE120_wind_hvy,VRE120_bal15")
    cases     = strip.(split(cases_str, ","))
    data_dir  = get(kw, "data-dir", joinpath(@__DIR__, "..", "data_processed", "cases"))
    data_dir  = abspath(data_dir)

    println("=" ^ 70)
    println("33_build_no_storage_cases.jl")
    println("Date: ", Dates.now())
    println("Source cases: ", join(cases, ", "))
    println("Data dir: ", data_dir)
    println("=" ^ 70)

    summary_rows = NamedTuple[]

    for case_name in cases
        src_dir = joinpath(data_dir, case_name)
        dst_dir = joinpath(data_dir, case_name * "_nostorage")

        print("  $case_name → $(case_name)_nostorage … ")

        if !isdir(src_dir)
            println("SKIP (source not found)")
            push!(summary_rows, (
                source_case  = case_name,
                nostorage_case = case_name * "_nostorage",
                status       = "SKIP — source not found",
            ))
            continue
        end

        try
            build_no_storage_case(src_dir, dst_dir)
            validate_case(dst_dir)

            # Load generator count for summary
            gen_df = CSV.read(joinpath(dst_dir, "generators.csv"), DataFrame)
            n_therm = sum(gen_df.is_thermal .== 1)

            println("OK (n_thermal=$n_therm, storage cleared)")
            push!(summary_rows, (
                source_case    = case_name,
                nostorage_case = case_name * "_nostorage",
                n_thermal      = n_therm,
                status         = "OK",
            ))
        catch e
            println("ERROR: $e")
            push!(summary_rows, (
                source_case    = case_name,
                nostorage_case = case_name * "_nostorage",
                n_thermal      = 0,
                status         = "ERROR: $e",
            ))
        end
    end

    println()
    println("Summary:")
    for r in summary_rows
        @printf("  %-35s → %-45s %s\n",
                r.source_case, r.nostorage_case, r.status)
    end

    all_ok = all(r.status == "OK" for r in summary_rows)
    println()
    println(all_ok ? "All cases built successfully." :
                     "WARNING: some cases had errors — see above.")
end

main()
