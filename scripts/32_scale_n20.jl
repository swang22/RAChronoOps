#!/usr/bin/env julia
# 32_scale_n20.jl
#
# Full N=20 HOPE pipeline for VRE120_base:
#   Step 1 — Export HOPE cases for scenarios 6–20 (ED and UC) via script 25
#   Step 2 — Run HOPE for scenarios 6–20 via script 29
#   Step 3 — Collect metrics for all 20 scenarios (1–20) via script 27
#             into results/hope_n20_pilot/
#   Step 4 — Full N=20 model comparison (M1/M1b/M1c/M2/M3/HOPE-ED/HOPE-UC)
#             via script 30 → results/full_model_comparison_with_hope/base_n20
#
# Prerequisites:
#   - Script 25 already exported + script 29 already ran scenarios 1–5 (N=5 pilot done)
#   - HOPE project available at --hope-path
#   - RU=RD=1.0 fix already applied to script 25 (ED mode, ramp_constraint_root_cause.txt)
#
# Usage:
#   julia --project=. scripts/32_scale_n20.jl \
#     --hope-path "D:/MIT Dropbox/Shen Wang/MIT/RA/HOPE_project" \
#     --julia-exe "C:/Users/swang16/AppData/Local/Microsoft/WindowsApps/julia.exe"
#
# Options:
#   --hope-path    Path to local HOPE Julia project
#   --julia-exe    Julia executable (default: julia in PATH)
#   --case         Case name (default: VRE120_base)
#   --skip-export  Skip export step (default: false)
#   --skip-run     Skip HOPE run step (default: false)
#   --skip-m3      Pass --skip-m3 to script 30 to skip M3 re-run (default: false)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Dates, Printf

# ── CLI ───────────────────────────────────────────────────────────────────────

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional arg: $arg")
        key = arg[3:end]
        if key in ("skip-export", "skip-run", "skip-m3")
            kw[key] = "true"
            i += 1
            continue
        end
        i + 1 <= length(args) && !startswith(args[i+1], "--") ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

# ── Sub-process helper ────────────────────────────────────────────────────────

function run_julia_script(julia_exe::String, project::String,
                           script_path::String, extra_args::Vector{String};
                           label::String = basename(script_path))
    println("─"^72)
    println("[$(Dates.format(now(), "HH:MM:SS"))] $label")
    println("  $(julia_exe) --project=$(project) $(script_path)")
    for a in extra_args
        println("    $a")
    end

    cmd = Cmd([julia_exe, "--project=$project", script_path, extra_args...])
    t0 = time()
    try
        run(cmd; wait = true)
    catch e
        @error "Script failed: $label" exception = e
        rethrow(e)
    end
    rt = time() - t0
    @printf("[%s] %s finished  (%.0f s = %.1f min)\n",
            Dates.format(now(), "HH:MM:SS"), label, rt, rt / 60)
    return rt
end

# ── Main ──────────────────────────────────────────────────────────────────────

let
    kw = parse_cli(ARGS)

    hope_path   = get(kw, "hope-path",
                      "D:/MIT Dropbox/Shen Wang/MIT/RA/HOPE_project")
    julia_exe   = get(kw, "julia-exe", joinpath(Sys.BINDIR, "julia"))
    case_name   = get(kw, "case", "VRE120_base")
    skip_export = get(kw, "skip-export", "false") == "true"
    skip_run    = get(kw, "skip-run",    "false") == "true"
    skip_m3     = get(kw, "skip-m3",    "false") == "true"

    julia_exe = replace(abspath(julia_exe), "\\" => "/")
    hope_path = replace(abspath(hope_path), "\\" => "/")

    root = replace(abspath(joinpath(@__DIR__, "..")), "\\" => "/")
    scripts_dir = "$root/scripts"
    project = root

    new_scenarios   = 6:20   # scenarios not yet run in N=5 pilot
    all_scenarios   = 1:20

    new_subset_str = join(new_scenarios, ",")
    all_subset_str = join(all_scenarios, ",")

    # Folder name helper
    folder_name(s, mode) = "RAChronoOps_$(case_name)_s$(lpad(s, 3, '0'))_$(mode)"

    hope_n20_dir = "$root/results/hope_n20_pilot"
    out_n20_dir  = "$root/results/full_model_comparison_with_hope/base_n20"

    println("="^72)
    println("HOPE N=20 Scale-Up Pipeline")
    println("="^72)
    println("  Case          : $case_name")
    println("  New scenarios : $(new_subset_str)")
    println("  All scenarios : $(all_subset_str)")
    println("  HOPE project  : $hope_path")
    println("  Julia exe     : $julia_exe")
    println("  N=20 results  : $hope_n20_dir")
    println("  Comparison    : $out_n20_dir")
    println()

    t_pipeline_start = time()

    # ── Step 1: Export scenarios 6–20 ────────────────────────────────────────
    if skip_export
        println("Step 1: Export skipped (--skip-export).")
    else
        println("Step 1: Exporting HOPE cases for scenarios 6–20 …")
        run_julia_script(julia_exe, project,
            "$scripts_dir/25_build_hope_full_year_cases.jl",
            [
                "--cases",            case_name,
                "--n-scenarios",      "20",
                "--seed",             "42",
                "--scenario-subset",  new_subset_str,
                "--modes",            "ED,UC",
                "--out-dir",          "$root/exports/hope_model_cases",
            ];
            label = "Script 25: Export s6–20")
        println()
    end

    # ── Step 2: Run HOPE for scenarios 6–20 ──────────────────────────────────
    if skip_run
        println("Step 2: HOPE runs skipped (--skip-run).")
    else
        println("Step 2: Running HOPE for scenarios 6–20 (ED then UC) …")
        run_julia_script(julia_exe, project,
            "$scripts_dir/29_run_hope_n5_pilot.jl",
            [
                "--hope-path",        hope_path,
                "--hope-cases-dir",   "$root/exports/hope_model_cases",
                "--case",             case_name,
                "--scenario-subset",  new_subset_str,
                "--modes",            "ED,UC",
                "--julia-exe",        julia_exe,
                "--out-dir",          "$root/results/hope_n20_run",
            ];
            label = "Script 29: Run HOPE s6–20")
        println()
    end

    # ── Step 3: Collect all 20 scenario metrics ───────────────────────────────
    println("Step 3: Collecting metrics for all 20 scenarios (1–20) …")

    # Build the full list of case folders for all 20 × 2 = 40 cases
    all_folders = String[]
    for s in all_scenarios
        for mode in ["ED", "UC"]
            push!(all_folders, folder_name(s, mode))
        end
    end
    case_folders_str = join(all_folders, ",")

    run_julia_script(julia_exe, project,
        "$scripts_dir/27_collect_hope_results.jl",
        [
            "--hope-cases-dir",  "$root/exports/hope_model_cases",
            "--case-folders",    case_folders_str,
            "--out-dir",         hope_n20_dir,
            "--metrics-name",    "hope_metrics_by_scenario.csv",
        ];
        label = "Script 27: Collect all-20 metrics")
    println()

    # ── Step 4: Full N=20 model comparison ───────────────────────────────────
    println("Step 4: Running full N=20 model comparison …")
    step4_args = [
        "--case",            case_name,
        "--scenario-subset", all_subset_str,
        "--n-scenarios",     "20",
        "--seed",            "42",
        "--hope-dir",        hope_n20_dir,
        "--out-dir",         out_n20_dir,
    ]
    skip_m3 && push!(step4_args, "--skip-m3")

    run_julia_script(julia_exe, project,
        "$scripts_dir/30_compare_all_models_hope_n5.jl",
        step4_args;
        label = "Script 30: N=20 comparison")
    println()

    # ── Summary ──────────────────────────────────────────────────────────────
    total_rt = time() - t_pipeline_start
    println("="^72)
    @printf("Pipeline complete  (total: %.0f s = %.1f min = %.2f h)\n",
            total_rt, total_rt / 60, total_rt / 3600)
    println("  HOPE metrics  : $hope_n20_dir/hope_metrics_by_scenario.csv")
    println("  Comparison    : $out_n20_dir/summary.txt")
    println("="^72)
end
