#!/usr/bin/env julia
# 29_run_hope_n5_pilot.jl
#
# Runs N=5 HOPE full-year PCM cases (ED and UC modes) by spawning Julia
# subprocesses.  Each subprocess activates the HOPE project and calls
# HOPE.run_hope(case_path).  Continues on failure; records status and
# runtime for every case.
#
# Prerequisites:
#   - Script 25 must have exported all case folders first.
#   - HOPE project must be available at --hope-path.
#
# Usage:
#   julia --project=. scripts/29_run_hope_n5_pilot.jl \
#     --hope-path "D:/MIT Dropbox/Shen Wang/MIT/RA/HOPE_project" \
#     --hope-cases-dir exports/hope_model_cases \
#     --case VRE120_base \
#     --scenario-subset 1,2,3,4,5 \
#     --modes ED,UC \
#     --out-dir results/hope_n5_pilot
#
# Options:
#   --hope-path         Path to local HOPE Julia project
#   --hope-cases-dir    Root of exported HOPE case folders (default: exports/hope_model_cases)
#   --case              Case name (default: VRE120_base)
#   --scenario-subset   Comma-separated 1-based scenario IDs (default: 1,2,3,4,5)
#   --modes             Comma-separated modes: ED and/or UC (default: ED,UC)
#   --julia-exe         Julia executable to use (default: this process's julia)
#   --out-dir           Output directory for status CSV (default: results/hope_n5_pilot)
#
# Output:
#   <out-dir>/hope_run_status.csv

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using CSV, DataFrames, Dates, Printf

# ── CLI ───────────────────────────────────────────────────────────────────────

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional argument: $arg")
        key = arg[3:end]
        if i + 1 > length(args) || startswith(args[i+1], "--")
            error("Option $arg requires a value")
        end
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

# ── Helper: case folder name ─────────────────────────────────────────────────

folder_name(case::String, s_id::Int, mode::String) =
    "RAChronoOps_$(case)_s$(lpad(s_id, 3, '0'))_$(mode)"

# ── Main ──────────────────────────────────────────────────────────────────────

let
    kw = parse_cli(ARGS)

    hope_path = get(kw, "hope-path",
                    joinpath("D:", "MIT Dropbox", "Shen Wang", "MIT", "RA", "HOPE_project"))
    hope_cases_dir = get(kw, "hope-cases-dir",
                         joinpath(@__DIR__, "..", "exports", "hope_model_cases"))
    case_name  = get(kw, "case", "VRE120_base")
    scen_ids   = parse.(Int, split(get(kw, "scenario-subset", "1,2,3,4,5"), ","))
    modes      = String.(split(get(kw, "modes", "ED,UC"), ","))
    out_dir    = get(kw, "out-dir",
                     joinpath(@__DIR__, "..", "results", "hope_n5_pilot"))
    julia_exe  = get(kw, "julia-exe", joinpath(Sys.BINDIR, "julia"))

    # Normalise paths to forward slashes (Julia accepts these on Windows)
    hope_path      = replace(abspath(hope_path),      "\\" => "/")
    hope_cases_dir = replace(abspath(hope_cases_dir), "\\" => "/")
    julia_exe      = replace(julia_exe, "\\" => "/")

    mkpath(out_dir)

    println("="^72)
    println("HOPE N=5 Pilot Runner")
    println("="^72)
    println("  HOPE project  : $hope_path")
    println("  Cases dir     : $hope_cases_dir")
    println("  Case          : $case_name")
    println("  Scenarios     : $(join(scen_ids, ", "))")
    println("  Modes         : $(join(modes, ", "))")
    println("  Julia exe     : $julia_exe")
    println("  Output dir    : $out_dir")
    println()

    # Build the ordered list of (scenario_id, mode) pairs: ED first, then UC
    pairs_to_run = [(s, m) for m in modes for s in scen_ids]

    status_rows = NamedTuple[]
    n_total = length(pairs_to_run)
    n_done  = 0

    for (s_id, mode) in pairs_to_run
        folder = folder_name(case_name, s_id, mode)
        case_path = "$hope_cases_dir/$folder"
        out_path  = "$case_path/output"

        println("─"^72)
        @printf("[%d/%d] %s\n", n_done + 1, n_total, folder)

        # Check the case folder exists (script 25 must have been run first)
        if !isdir(case_path)
            @warn "Case folder not found, skipping: $case_path"
            push!(status_rows, (
                case_name    = case_name,
                scenario_id  = s_id,
                mode         = mode,
                case_folder  = folder,
                start_time   = "",
                end_time     = "",
                runtime_s    = NaN,
                status       = "SKIPPED_MISSING_FOLDER",
                error_message = "Folder not found: $case_path",
                output_dir   = "",
            ))
            n_done += 1
            continue
        end

        start_dt = now()
        t0       = time()
        status   = "OK"
        err_msg  = ""

        # Build subprocess command: activate HOPE project, load HOPE, run case
        julia_code = """using HOPE; HOPE.run_hope("$case_path")"""
        cmd = Cmd([julia_exe, "--project=$hope_path", "-e", julia_code])

        try
            println("  Start: $(Dates.format(start_dt, "HH:MM:SS"))")
            run(cmd; wait = true)
        catch e
            status  = "FAILED"
            err_msg = sprint(showerror, e)
            @warn "Case failed: $folder\n  $err_msg"
        end

        rt      = time() - t0
        end_dt  = now()
        n_done += 1

        @printf("  End:    %s  (%.1f s)\n",
                Dates.format(end_dt, "HH:MM:SS"), rt)
        @printf("  Status: %s\n", status)

        push!(status_rows, (
            case_name     = case_name,
            scenario_id   = s_id,
            mode          = mode,
            case_folder   = folder,
            start_time    = Dates.format(start_dt, "yyyy-mm-dd HH:MM:SS"),
            end_time      = Dates.format(end_dt,   "yyyy-mm-dd HH:MM:SS"),
            runtime_s     = rt,
            status        = status,
            error_message = err_msg,
            output_dir    = isdir(out_path) ? out_path : "",
        ))

        # Flush status CSV after every case so partial results are always on disk
        status_df   = DataFrame(status_rows)
        status_path = joinpath(out_dir, "hope_run_status.csv")
        CSV.write(status_path, status_df)
    end

    println("="^72)
    println("All cases attempted: $n_done / $n_total")
    n_ok   = count(r -> r.status == "OK",      status_rows)
    n_fail = count(r -> r.status == "FAILED",   status_rows)
    n_skip = count(r -> r.status != "OK" && r.status != "FAILED", status_rows)
    @printf("  OK: %d  |  FAILED: %d  |  SKIPPED: %d\n", n_ok, n_fail, n_skip)

    status_path = joinpath(out_dir, "hope_run_status.csv")
    println("Status written: $status_path")
    println()
end
