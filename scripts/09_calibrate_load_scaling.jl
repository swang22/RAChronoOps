#!/usr/bin/env julia
# 09_calibrate_load_scaling.jl
#
# Loops over load-scaling cases, runs M1 and M3 with a shared ScenarioSet
# for each case, and identifies the load-scale factor giving M3 LOLH ≈ 10 h/yr.
#
# Outputs (base mode):
#   results/calibration/load_scaling_calibration.csv
#   results/calibration/recommended_case.txt
#
# Outputs (--extended mode):
#   results/calibration/load_scaling_calibration_extended.csv
#   results/calibration/recommended_case.txt  (overwritten)
#
# Usage:
#   julia --project=. scripts/09_calibrate_load_scaling.jl
#   julia --project=. scripts/09_calibrate_load_scaling.jl --extended --n-scenarios 10 --seed 42

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Printf
using Statistics

# ── CLI parsing ───────────────────────────────────────────────────────────────
function _parse_cli(args)
    d = Dict{String,String}()
    i = 1
    while i <= length(args)
        k = args[i]
        if k == "--extended"
            d["extended"] = "true"
            i += 1
        elseif i < length(args) && startswith(k, "--")
            d[lstrip(k, '-')] = args[i+1]
            i += 2
        else
            i += 1
        end
    end
    return d
end

cli = _parse_cli(ARGS)

const EXTENDED    = get(cli, "extended", "false") == "true"
const N_SCENARIOS = parse(Int, get(cli, "n-scenarios", "20"))
const SEED        = parse(Int, get(cli, "seed",         "42"))

const BASE_CASE_NAMES  = ["rts_base", "load_scale_105", "load_scale_110",
                           "load_scale_115", "load_scale_120"]
const BASE_LOAD_SCALES = [1.00, 1.05, 1.10, 1.15, 1.20]

const EXT_CASE_NAMES   = ["load_scale_120",  "load_scale_1225", "load_scale_125",
                           "load_scale_1275", "load_scale_130",  "load_scale_135"]
const EXT_LOAD_SCALES  = [1.20, 1.225, 1.25, 1.275, 1.30, 1.35]

const CASE_NAMES  = EXTENDED ? EXT_CASE_NAMES  : BASE_CASE_NAMES
const LOAD_SCALES = EXTENDED ? EXT_LOAD_SCALES : BASE_LOAD_SCALES

# ── Monte Carlo 95% CI ────────────────────────────────────────────────────────
function _mc_ci95(values::Vector{Float64})
    n   = length(values)
    n < 2 && return (hw=NaN, rel=NaN)
    hat = mean(values)
    se  = std(values) / sqrt(n)
    hw  = 1.96 * se
    rel = hat > 0.0 ? hw / hat : NaN
    return (hw=hw, rel=rel)
end

let
    project_root = joinpath(@__DIR__, "..")
    cases_dir    = joinpath(project_root, "data_processed", "cases")
    conf_dir     = joinpath(project_root, "configs")
    out_dir      = joinpath(project_root, "results", "calibration")
    mkpath(out_dir)

    csv_name = EXTENDED ? "load_scaling_calibration_extended.csv" :
                          "load_scaling_calibration.csv"

    function _get_cfg(name)
        p = joinpath(conf_dir, "$name.yaml")
        isfile(p) ? load_config(p) : SimConfig()
    end
    m1_cfg = _get_cfg("m1")
    m3_cfg = _get_cfg("m3")

    mode_tag = EXTENDED ? "EXTENDED" : "BASE"
    println("=" ^ 80)
    @printf "Load-Scaling Calibration [%s] | M1 + M3 | %d scenarios | seed=%d\n" mode_tag N_SCENARIOS SEED
    println("=" ^ 80)

    all_rows = NamedTuple[]

    for (case_name, load_scale) in zip(CASE_NAMES, LOAD_SCALES)
        case_dir = joinpath(cases_dir, case_name)
        isdir(case_dir) || error("Case directory not found: $case_dir\n" *
                                  "Run scripts/06_build_experiment_cases.jl first.")

        println("\n--- $case_name  (alpha = $load_scale) ---")

        sys = load_system_data(case_dir)
        sys.n_hours == 8760 ||
            error("Case $case_name: expected 8760 h, got $(sys.n_hours)")

        crn_cfg   = SimConfig(; n_scenarios=N_SCENARIOS, seed=SEED)
        scenarios = generate_scenarios(sys, crn_cfg)

        for (tag, fn, cfg) in [("M1", run_m1_rule_based,  m1_cfg),
                                ("M3", run_m3_ed_dispatch, m3_cfg)]

            t0 = time()
            res = try
                fn(sys, scenarios, cfg)
            catch e
                println("  $tag FAILED: $(sprint(showerror, e))")
                push!(all_rows, (
                    case_name               = case_name,
                    load_scale              = load_scale,
                    model                   = tag,
                    n_scenarios             = N_SCENARIOS,
                    seed                    = SEED,
                    lolh_hours              = NaN,
                    eue_mwh                 = NaN,
                    neue_ppm                = NaN,
                    cvar_eue_mwh            = NaN,
                    eue_ci95_halfwidth_mwh  = NaN,
                    eue_ci95_rel_halfwidth  = NaN,
                    lolh_ci95_halfwidth     = NaN,
                    lolh_ci95_rel_halfwidth = NaN,
                    runtime_s               = NaN,
                ))
                continue
            end
            rt = time() - t0

            m      = compute_metrics(res, sys, cfg)
            sm     = build_scenario_metrics_df(res)
            eue_ci = _mc_ci95(m.scenario_eue)
            loh_ci = _mc_ci95(sm.lolh_hours)

            ci_str = isnan(eue_ci.rel) ? "   ---" :
                     @sprintf("%5.0f%%", eue_ci.rel * 100)
            @printf "  %-3s  LOLH=%7.2f h  EUE=%9.1f MWh  CVaR=%9.1f  EUE_CI95=%s  t=%6.1f s\n" tag m.lolh m.eue m.cvar_eue ci_str rt

            push!(all_rows, (
                case_name               = case_name,
                load_scale              = load_scale,
                model                   = tag,
                n_scenarios             = N_SCENARIOS,
                seed                    = SEED,
                lolh_hours              = m.lolh,
                eue_mwh                 = m.eue,
                neue_ppm                = m.neue * 1e6,
                cvar_eue_mwh            = m.cvar_eue,
                eue_ci95_halfwidth_mwh  = eue_ci.hw,
                eue_ci95_rel_halfwidth  = eue_ci.rel,
                lolh_ci95_halfwidth     = loh_ci.hw,
                lolh_ci95_rel_halfwidth = loh_ci.rel,
                runtime_s               = rt,
            ))
        end
    end

    # ── save CSV ──────────────────────────────────────────────────────────────
    df       = DataFrame(all_rows)
    csv_path = joinpath(out_dir, csv_name)
    CSV.write(csv_path, df)

    # ── recommended case ──────────────────────────────────────────────────────
    m3_df = filter(r -> r.model == "M3" && !isnan(r.lolh_hours), df)
    max_scale = maximum(LOAD_SCALES)

    rec_text = if nrow(m3_df) == 0
        "No M3 results available (all cases failed)."
    elseif all(iszero.(m3_df.lolh_hours))
        "All tested load scales have zero M3 LOLH. Increase load_scale beyond $max_scale."
    else
        nonzero = filter(r -> r.lolh_hours > 0.0, m3_df)
        if all(nonzero.lolh_hours .> 50.0)
            "All tested load scales are too scarce. Use a smaller load scale."
        else
            diffs = abs.(nonzero.lolh_hours .- 10.0)
            best  = nonzero[argmin(diffs), :]
            "Recommended case: $(best.case_name) " *
            "(load_scale=$(best.load_scale), " *
            "M3 LOLH=$(round(best.lolh_hours, digits=2)) h/yr, " *
            "M3 EUE=$(round(best.eue_mwh, digits=1)) MWh/yr)"
        end
    end

    rec_path = joinpath(out_dir, "recommended_case.txt")
    open(rec_path, "w") do f; println(f, rec_text); end

    # ── summary table ─────────────────────────────────────────────────────────
    println("\n" * "=" ^ 96)
    println("Calibration Summary [$mode_tag]")
    println("=" ^ 96)
    @printf "%-20s %10s %10s %10s %12s %12s %13s %14s\n" "case_name" "load_scale" "M1_LOLH" "M3_LOLH" "M1_EUE" "M3_EUE" "EUE_M1-M3" "M3_runtime_s"
    println("-" ^ 96)
    for (cn, ls) in zip(CASE_NAMES, LOAD_SCALES)
        sub    = filter(r -> r.case_name == cn, df)
        m1_sub = filter(r -> r.model == "M1", sub)
        m3_sub = filter(r -> r.model == "M3", sub)
        if nrow(m1_sub) == 0 || nrow(m3_sub) == 0
            @printf "%-20s %10.3f  (data missing)\n" cn ls
            continue
        end
        m1l = m1_sub[1, :lolh_hours];  m3l = m3_sub[1, :lolh_hours]
        m1e = m1_sub[1, :eue_mwh];     m3e = m3_sub[1, :eue_mwh]
        m3r = m3_sub[1, :runtime_s]
        @printf "%-20s %10.3f %10.2f %10.2f %12.1f %12.1f %13.1f %14.1f\n" cn ls m1l m3l m1e m3e (m1e - m3e) m3r
    end
    println("=" ^ 96)
    println("\nRecommendation: $rec_text")
    println("Results → $out_dir/$csv_name")
end
