#!/usr/bin/env julia
# 23_compare_m1c_charging_assumptions.jl
#
# Compares two M1c charging formulations to test whether M1c's exact LOLH
# match with M3 depends on charging from thermal headroom:
#
#   M1c_current    (run_m1c_emergency_only):
#     Charges from any surplus: thermal_available + p_vre - load > 0.
#     Thermal headroom is a valid charging source.
#
#   M1c_VREOnlyCharge (run_m1c_vre_only_charge):
#     Charges only from VRE surplus: p_vre - load > 0.
#     Closer to "storage as renewable firming" interpretation.
#
#   M3 (run_m3_ed_dispatch):
#     Full-year ED LP.  Benchmark.  Also charges from thermal headroom
#     in practice (diagnostic script 22 shows 70–98% non-VRE-surplus charging).
#
# Outputs (results/m1c_charging_assumptions/<subdir>/):
#   m1c_charging_assumption_results.csv
#   m1c_charging_assumption_errors.csv
#   summary.txt
#   run_<timestamp>.log
#
# Usage:
#   julia --project=. scripts/23_compare_m1c_charging_assumptions.jl [options]
#
# Options:
#   --n-scenarios N      MC scenarios   (default: 20)
#   --seed S             RNG seed        (default: 42)
#   --cases C1,C2,...    VRE120 cases
#   --skip-m3            Omit M3 (fast testing)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

const PRIORITY_CASES = ["VRE120_base", "VRE120_bal15", "VRE120_wind_hvy"]
const ALL_VRE120_CASES = [
    "VRE120_base", "VRE120_bal15", "VRE120_bal20",
    "VRE120_bal30", "VRE120_solar_hvy", "VRE120_wind_hvy",
]

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional argument: $arg")
        key = arg[3:end]
        if key == "skip-m3"
            kw["skip-m3"] = "true"; i += 1
        else
            i + 1 <= length(args) && !startswith(args[i+1], "--") ||
                error("Option $arg requires a value")
            kw[key] = args[i+1]; i += 2
        end
    end
    return kw
end

# ── main ──────────────────────────────────────────────────────────────────────
let
    kw = parse_cli(ARGS)

    n_scenarios  = parse(Int, get(kw, "n-scenarios", "20"))
    seed         = parse(Int, get(kw, "seed",         "42"))
    skip_m3      = get(kw, "skip-m3", "false") == "true"

    cases_to_run = if haskey(kw, "cases")
        requested = split(kw["cases"], ",")
        for c in requested
            c in ALL_VRE120_CASES ||
                error("Unknown case: $c (valid: $(join(ALL_VRE120_CASES, ", ")))")
        end
        String.(requested)
    else
        PRIORITY_CASES
    end

    project_root = joinpath(@__DIR__, "..")
    cases_root   = joinpath(project_root, "data_processed", "cases")
    base_out_dir = joinpath(project_root, "results", "m1c_charging_assumptions")
    abbr         = join([replace(c, "VRE120_" => "") for c in cases_to_run], "-")
    subdir       = get(kw, "out-subdir", "$(abbr)_n$(n_scenarios)")
    out_dir      = joinpath(base_out_dir, subdir)
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "M1c charging-assumption comparison"
    @info "n=$n_scenarios | seed=$seed | skip_m3=$skip_m3"
    @info "Cases: $(join(cases_to_run, ", "))"
    @info "Output: $out_dir"

    results_path = joinpath(out_dir, "m1c_charging_assumption_results.csv")
    errors_path  = joinpath(out_dir, "m1c_charging_assumption_errors.csv")
    summary_path = joinpath(out_dir, "summary.txt")

    results_rows = NamedTuple[]

    m3_metrics_by_case = Dict{String, Any}()
    m3_runtime_by_case = Dict{String, Float64}()

    nan = NaN

    function make_results_row(cname, label, m, rt)
        (
            case_name                       = cname,
            model_label                     = label,
            n_scenarios                     = n_scenarios,
            seed                            = seed,
            lolh_hours                      = isnothing(m) ? nan : m.lolh,
            lolp_percent                    = isnothing(m) ? nan : 100.0 * m.lolp,
            lole_days                       = isnothing(m) ? nan : m.lole_days,
            eue_mwh                         = isnothing(m) ? nan : m.eue,
            neue_ppm                        = isnothing(m) ? nan : m.neue * 1e6,
            cvar_eue_mwh                    = isnothing(m) ? nan : m.cvar_eue,
            p90_scenario_eue_mwh            = isnothing(m) ? nan : m.p90_scenario_eue,
            p95_scenario_eue_mwh            = isnothing(m) ? nan : m.p95_scenario_eue,
            p99_scenario_eue_mwh            = isnothing(m) ? nan : m.p99_scenario_eue,
            n_shortage_events               = isnothing(m) ? nan : m.n_shortage_events,
            mean_shortage_duration_h        = isnothing(m) ? nan : m.mean_shortage_duration,
            max_shortage_duration_h         = isnothing(m) ? nan : m.max_shortage_duration,
            p95_shortage_duration_h         = isnothing(m) ? nan : m.p95_shortage_duration,
            max_shortfall_mw                = isnothing(m) ? nan : m.max_shortfall,
            mean_shortfall_when_shedding_mw = isnothing(m) ? nan : m.mean_shortfall_when_shedding,
            lolh_ci95_halfwidth_h           = isnothing(m) ? nan : m.lolh_ci95_halfwidth,
            lolh_ci95_rel_halfwidth         = isnothing(m) ? nan : m.lolh_ci95_rel_halfwidth,
            eue_ci95_halfwidth_mwh          = isnothing(m) ? nan : m.eue_ci95_halfwidth,
            eue_ci95_rel_halfwidth          = isnothing(m) ? nan : m.eue_ci95_rel_halfwidth,
            runtime_s                       = round(rt; digits=1),
        )
    end

    function make_error_row(cname, label, m3, meth, meth_rt)
        safe_rel(a, b) = b != 0.0 && !isnan(b) ? (a - b) / b : nan
        (
            case_name             = cname,
            method_label          = label,
            m3_lolh               = isnothing(m3)   ? nan : m3.lolh,
            method_lolh           = isnothing(meth) ? nan : meth.lolh,
            lolh_error            = isnothing(meth) || isnothing(m3) ? nan : meth.lolh - m3.lolh,
            lolh_abs_error        = isnothing(meth) || isnothing(m3) ? nan : abs(meth.lolh - m3.lolh),
            lolh_rel_error        = isnothing(meth) || isnothing(m3) ? nan : safe_rel(meth.lolh, m3.lolh),
            m3_eue                = isnothing(m3)   ? nan : m3.eue,
            method_eue            = isnothing(meth) ? nan : meth.eue,
            eue_error             = isnothing(meth) || isnothing(m3) ? nan : meth.eue - m3.eue,
            eue_rel_error         = isnothing(meth) || isnothing(m3) ? nan : safe_rel(meth.eue, m3.eue),
            m3_cvar_eue           = isnothing(m3)   ? nan : m3.cvar_eue,
            method_cvar_eue       = isnothing(meth) ? nan : meth.cvar_eue,
            cvar_eue_error        = isnothing(meth) || isnothing(m3) ? nan : meth.cvar_eue - m3.cvar_eue,
            m3_lole_days          = isnothing(m3)   ? nan : m3.lole_days,
            method_lole_days      = isnothing(meth) ? nan : meth.lole_days,
            lole_days_error       = isnothing(meth) || isnothing(m3) ? nan : meth.lole_days - m3.lole_days,
            m3_max_shortfall      = isnothing(m3)   ? nan : m3.max_shortfall,
            method_max_shortfall  = isnothing(meth) ? nan : meth.max_shortfall,
            max_shortfall_error   = isnothing(meth) || isnothing(m3) ? nan : meth.max_shortfall - m3.max_shortfall,
            m3_runtime_s          = nan,
            method_runtime_s      = round(meth_rt; digits=1),
            runtime_speedup_vs_m3 = nan,
        )
    end

    heuristic_labels = ["M1c_current", "M1c_VREOnly"]

    total_t0 = time()

    for cname in cases_to_run
        cdir = joinpath(cases_root, cname)
        if !isdir(cdir)
            @warn "Case directory not found — skipping: $cdir"
            continue
        end

        @info "── Case: $cname ──────────────────────────────────────────────"
        sys       = load_system_data(cdir)
        crn_cfg   = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)

        # ── M1c_current ───────────────────────────────────────────────────────
        try
            cfg = SimConfig(; n_scenarios, seed)
            @info "  running M1c_current..."
            t0 = time()
            r  = run_m1c_emergency_only(sys, scenarios, cfg)
            rt = time() - t0
            m  = compute_metrics(r, sys, cfg)
            push!(results_rows, make_results_row(cname, "M1c_current", m, rt))
            @info "  M1c_current: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
        catch e
            @error "M1c_current failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_results_row(cname, "M1c_current", nothing, 0.0))
        end

        # ── M1c_VREOnly ───────────────────────────────────────────────────────
        try
            cfg = SimConfig(; n_scenarios, seed)
            @info "  running M1c_VREOnly..."
            t0 = time()
            r  = run_m1c_vre_only_charge(sys, scenarios, cfg)
            rt = time() - t0
            m  = compute_metrics(r, sys, cfg)
            push!(results_rows, make_results_row(cname, "M1c_VREOnly", m, rt))
            @info "  M1c_VREOnly: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
        catch e
            @error "M1c_VREOnly failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_results_row(cname, "M1c_VREOnly", nothing, 0.0))
        end

        # ── M3 ────────────────────────────────────────────────────────────────
        if !skip_m3
            try
                cfg = SimConfig(; n_scenarios, seed)
                @info "  running M3..."
                t0 = time()
                r  = run_m3_ed_dispatch(sys, scenarios, cfg)
                rt = time() - t0
                m  = compute_metrics(r, sys, cfg)
                m3_metrics_by_case[cname] = m
                m3_runtime_by_case[cname] = rt
                push!(results_rows, make_results_row(cname, "M3", m, rt))
                @info "  M3: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
            catch e
                @error "M3 failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_results_row(cname, "M3", nothing, 0.0))
            end
        end

        CSV.write(results_path, DataFrame(results_rows))
        @info "  Intermediate outputs saved → $out_dir"
    end

    total_rt = time() - total_t0
    @info "Total runtime: $(round(total_rt, digits=1)) s"

    df    = DataFrame(results_rows)
    ok_df = filter(r -> !isnan(r.lolh_hours), df)

    # ── build error rows ───────────────────────────────────────────────────────
    error_rows = NamedTuple[]
    if !skip_m3
        for cname in cases_to_run
            haskey(m3_metrics_by_case, cname) || continue
            m3    = m3_metrics_by_case[cname]
            m3_rt = get(m3_runtime_by_case, cname, 0.0)
            for lbl in heuristic_labels
                mrow = filter(r -> r.case_name == cname && r.model_label == lbl && !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                meth_m = (lolh=r.lolh_hours, eue=r.eue_mwh, cvar_eue=r.cvar_eue_mwh,
                          lole_days=r.lole_days, max_shortfall=r.max_shortfall_mw,
                          mean_shortfall_when_shedding=r.mean_shortfall_when_shedding_mw)
                row = make_error_row(cname, lbl, m3, meth_m, r.runtime_s)
                push!(error_rows, merge(row, (
                    m3_runtime_s          = round(m3_rt; digits=1),
                    runtime_speedup_vs_m3 = m3_rt > 0.0 ? m3_rt / r.runtime_s : nan,
                )))
            end
        end
    end

    CSV.write(results_path, df)
    CSV.write(errors_path,  DataFrame(error_rows))

    # ── summary.txt ────────────────────────────────────────────────────────────
    open(summary_path, "w") do io
        sep = "=" ^ 80
        println(io, sep)
        println(io, "M1c Charging-Assumption Comparison Summary")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d\n", n_scenarios, seed)
        @printf(io, "Cases: %s\n", join(cases_to_run, ", "))
        println(io, sep)
        println(io)

        err_df = DataFrame(error_rows)
        all_labels = vcat(heuristic_labels, skip_m3 ? [] : ["M3"])

        # ── main results table ─────────────────────────────────────────────────
        println(io, "Aggregate reliability metrics")
        println(io, "-" ^ 100)
        @printf(io, "  %-22s %-22s %8s %7s %7s %10s %10s %10s %8s\n",
                "Case", "Model", "LOLH(h)", "LOLP%", "LOLE_d",
                "EUE(MWh)", "CVaR-EUE", "MaxSF(MW)", "rt(s)")
        println(io, "  " * "-" ^ 94)
        for lbl in all_labels
            for cname in cases_to_run
                mrow = filter(r -> r.case_name == cname && r.model_label == lbl && !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                @printf(io, "  %-22s %-22s %8.2f %7.3f %7.2f %10.1f %10.1f %10.1f %8.1f\n",
                        cname, lbl,
                        r.lolh_hours, r.lolp_percent, r.lole_days,
                        r.eue_mwh, r.cvar_eue_mwh, r.max_shortfall_mw, r.runtime_s)
            end
        end
        println(io)

        # ── event-structure metrics ────────────────────────────────────────────
        println(io, "Event-structure and severity metrics")
        println(io, "-" ^ 100)
        @printf(io, "  %-22s %-22s %8s %8s %8s %10s %10s\n",
                "Case", "Model", "n_evts", "mean_dur", "p95_dur", "MaxSF(MW)", "MeanSF(MW)")
        println(io, "  " * "-" ^ 94)
        for lbl in all_labels
            for cname in cases_to_run
                mrow = filter(r -> r.case_name == cname && r.model_label == lbl && !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                @printf(io, "  %-22s %-22s %8.1f %8.2f %8.2f %10.1f %10.1f\n",
                        cname, lbl,
                        r.n_shortage_events, r.mean_shortage_duration_h,
                        r.p95_shortage_duration_h, r.max_shortfall_mw,
                        r.mean_shortfall_when_shedding_mw)
            end
        end
        println(io)

        # ── MC uncertainty (M3 only) ───────────────────────────────────────────
        if !skip_m3
            println(io, "Monte Carlo uncertainty (M3 benchmark)")
            println(io, "-" ^ 80)
            @printf(io, "  %-22s %12s %12s %12s %12s\n",
                    "Case", "LOLH_CI95", "LOLH_CI95%", "EUE_CI95", "EUE_CI95%")
            println(io, "  " * "-" ^ 74)
            for cname in cases_to_run
                mrow = filter(r -> r.case_name == cname && r.model_label == "M3" && !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                lolh_ci_pct = isnan(r.lolh_ci95_rel_halfwidth) ? "n/a" :
                              @sprintf("%.1f%%", 100.0 * r.lolh_ci95_rel_halfwidth)
                eue_ci_pct  = isnan(r.eue_ci95_rel_halfwidth)  ? "n/a" :
                              @sprintf("%.1f%%", 100.0 * r.eue_ci95_rel_halfwidth)
                @printf(io, "  %-22s %12.3f %12s %12.1f %12s\n",
                        cname, r.lolh_ci95_halfwidth_h, lolh_ci_pct,
                        r.eue_ci95_halfwidth_mwh, eue_ci_pct)
            end
            println(io)
        end

        # ── error table ────────────────────────────────────────────────────────
        if !isempty(err_df)
            println(io, "Method error vs M3 benchmark")
            println(io, "-" ^ 100)
            @printf(io, "  %-22s %-22s %9s %9s %9s %10s %10s %10s\n",
                    "Case", "Method", "M3_LOLH", "Meth_LOLH", "err_h",
                    "rel_err%", "M3_EUE", "EUE_err")
            println(io, "  " * "-" ^ 94)
            for cname in cases_to_run
                sub = filter(r -> r.case_name == cname, err_df)
                isempty(sub) && continue
                for r in eachrow(sub)
                    rel_pct = isnan(r.lolh_rel_error) ? "n/a" :
                              @sprintf("%+.1f%%", 100.0 * r.lolh_rel_error)
                    @printf(io, "  %-22s %-22s %9.2f %9.2f %+9.2f %10s %10.1f %+10.4f\n",
                            cname, r.method_label,
                            r.m3_lolh, r.method_lolh, r.lolh_error,
                            rel_pct, r.m3_eue, r.eue_error)
                end
            end
            println(io)

            # runtime table
            println(io, "Runtime and speedup vs M3")
            println(io, "-" ^ 80)
            @printf(io, "  %-22s %-22s %10s %10s %12s\n",
                    "Case", "Method", "rt(s)", "M3_rt(s)", "speedup")
            println(io, "  " * "-" ^ 74)
            for cname in cases_to_run
                sub = filter(r -> r.case_name == cname, err_df)
                isempty(sub) && continue
                for r in eachrow(sub)
                    spd_str = isnan(r.runtime_speedup_vs_m3) ? "n/a" :
                              @sprintf("%.1fx", r.runtime_speedup_vs_m3)
                    @printf(io, "  %-22s %-22s %10.1f %10.1f %12s\n",
                            cname, r.method_label, r.method_runtime_s, r.m3_runtime_s, spd_str)
                end
            end
            println(io)
        end

        # ── Research questions ─────────────────────────────────────────────────
        println(io, sep)
        println(io, "Research questions")
        println(io, sep)
        println(io)

        # Q1: Does VRE-only charging break the M1c = M3 match?
        println(io, "Q1. Does VRE-only charging break the exact M1c = M3 LOLH match?")
        println(io)
        if !isempty(err_df)
            for cname in cases_to_run
                sub = filter(r -> r.case_name == cname, err_df)
                curr_r  = filter(r -> r.method_label == "M1c_current", sub)
                vre_r   = filter(r -> r.method_label == "M1c_VREOnly", sub)
                (isempty(curr_r) || isempty(vre_r)) && continue
                curr_err = curr_r[1, :lolh_error]
                vre_err  = vre_r[1,  :lolh_error]
                broke    = abs(vre_err) > abs(curr_err) + 0.05
                @printf(io, "  %s:  M1c_current err=%+.2f h  M1c_VREOnly err=%+.2f h  → %s\n",
                        cname, curr_err, vre_err, broke ? "MATCH BROKEN" : "match preserved")
            end
        end
        println(io)

        # Q2: How much worse is VRE-only charging?
        println(io, "Q2. How much worse is VRE-only charging than current M1c?")
        println(io)
        if !isempty(err_df)
            for cname in cases_to_run
                sub = filter(r -> r.case_name == cname, err_df)
                curr_r  = filter(r -> r.method_label == "M1c_current", sub)
                vre_r   = filter(r -> r.method_label == "M1c_VREOnly", sub)
                (isempty(curr_r) || isempty(vre_r)) && continue
                delta_lolh = vre_r[1, :lolh_abs_error] - curr_r[1, :lolh_abs_error]
                delta_eue  = vre_r[1, :eue_error]       - curr_r[1, :eue_error]
                @printf(io, "  %s:  ΔLOLH_abs = %+.2f h  ΔEUE = %+.1f MWh\n",
                        cname, delta_lolh, delta_eue)
            end
            println(io)
            curr_mean = let s = filter(r -> r.method_label == "M1c_current", err_df)
                isempty(s) ? nan : mean(s.lolh_abs_error)
            end
            vre_mean = let s = filter(r -> r.method_label == "M1c_VREOnly", err_df)
                isempty(s) ? nan : mean(s.lolh_abs_error)
            end
            @printf(io, "  Mean abs LOLH error:  M1c_current=%.3f h  M1c_VREOnly=%.3f h  Δ=%+.3f h\n",
                    curr_mean, vre_mean, vre_mean - curr_mean)
        end
        println(io)

        # Q3: Which cases are most sensitive?
        println(io, "Q3. Which cases are most sensitive to the charging-source assumption?")
        println(io)
        if !isempty(err_df)
            case_sensitivity = NamedTuple[]
            for cname in cases_to_run
                sub    = filter(r -> r.case_name == cname, err_df)
                curr_r = filter(r -> r.method_label == "M1c_current", sub)
                vre_r  = filter(r -> r.method_label == "M1c_VREOnly", sub)
                (isempty(curr_r) || isempty(vre_r)) && continue
                delta = abs(vre_r[1, :lolh_abs_error] - curr_r[1, :lolh_abs_error])
                push!(case_sensitivity, (case=cname, delta_lolh_abs=delta))
            end
            sort!(case_sensitivity, by=x -> x.delta_lolh_abs, rev=true)
            for cs in case_sensitivity
                @printf(io, "  %s:  ΔLOLH_abs = %.2f h\n", cs.case, cs.delta_lolh_abs)
            end
        end
        println(io)

        # Q4: Does VRE-only M1c still outperform M1b?
        println(io, "Q4. Does VRE-only M1c still outperform M1b (from script 21)?")
        println(io)
        println(io, "  (M1b N=20 reference from script 21:)")
        println(io, "    VRE120_base:     M1b LOLH = 83.55 h  (err = +77.60 h vs M3)")
        println(io, "    VRE120_bal15:    M1b LOLH = 36.75 h  (err = +35.40 h vs M3)")
        println(io, "    VRE120_wind_hvy: M1b LOLH = 25.00 h  (err = +22.75 h vs M3)")
        if !isempty(err_df)
            for cname in cases_to_run
                sub   = filter(r -> r.case_name == cname && r.method_label == "M1c_VREOnly", err_df)
                isempty(sub) && continue
                r     = sub[1, :]
                m3l   = r.m3_lolh
                vrel  = r.method_lolh
                @printf(io, "  %s: M1c_VREOnly LOLH=%.2f h  err=%+.2f h vs M3\n",
                        cname, vrel, r.lolh_error)
            end
        end
        println(io)

        # Q5: Which formulation for the main paper?
        println(io, "Q5. Which M1c formulation should the paper present?")
        println(io)
        if !isempty(err_df)
            curr_mean = let s = filter(r -> r.method_label == "M1c_current", err_df)
                isempty(s) ? nan : mean(s.lolh_abs_error)
            end
            vre_mean = let s = filter(r -> r.method_label == "M1c_VREOnly", err_df)
                isempty(s) ? nan : mean(s.lolh_abs_error)
            end
            if !isnan(curr_mean) && !isnan(vre_mean)
                gap = vre_mean - curr_mean
                if gap < 0.5
                    println(io, "  → Both formulations are close (<0.5 h mean LOLH difference).")
                    println(io, "    Recommend: present M1c_current (thermal-headroom charging) as main")
                    println(io, "    result, because it is consistent with the M3 ED formulation (which")
                    println(io, "    also charges from thermal headroom). Present M1c_VREOnly as a")
                    println(io, "    sensitivity test with explicit note on interpretation.")
                elseif gap < 2.0
                    println(io, "  → Moderate difference (0.5–2 h mean LOLH error gap).")
                    println(io, "    Recommend: present both side-by-side as a sensitivity check.")
                    println(io, "    The gap illustrates the importance of the charging-source assumption.")
                else
                    println(io, "  → Large difference (>2 h mean LOLH error gap).")
                    println(io, "    M1c_VREOnly is significantly worse. Recommend presenting M1c_current")
                    println(io, "    as the main result and M1c_VREOnly as an appendix sensitivity.")
                end
                @printf(io, "  Mean abs LOLH error:  M1c_current=%.3f h  M1c_VREOnly=%.3f h  gap=%.3f h\n",
                        curr_mean, vre_mean, gap)
            end
        end
        println(io)

        @printf(io, "Total runtime: %.1f s\n", total_rt)
        println(io, sep)
        println(io, "Files: m1c_charging_assumption_results.csv")
        println(io, "       m1c_charging_assumption_errors.csv")
    end

    # ── console output ─────────────────────────────────────────────────────────
    sep = "=" ^ 84
    println()
    println(sep)
    @printf("M1c Charging-Assumption Comparison  |  N=%d  |  seed=%d  |  subdir=%s\n",
            n_scenarios, seed, subdir)
    @printf("Cases: %s\n", join(cases_to_run, ", "))
    println(sep)

    @printf("  %-20s %-22s %8s %7s %7s %10s %10s %10s %8s\n",
            "Case", "Model", "LOLH(h)", "LOLP%", "LOLE_d",
            "EUE(MWh)", "CVaR-EUE", "MaxSF(MW)", "rt(s)")
    println("  " * "-" ^ 90)
    for lbl in vcat(heuristic_labels, skip_m3 ? [] : ["M3"])
        for cname in cases_to_run
            mrow = filter(r -> r.case_name == cname && r.model_label == lbl && !isnan(r.lolh_hours), ok_df)
            isempty(mrow) && continue
            r = mrow[1, :]
            @printf("  %-20s %-22s %8.2f %7.3f %7.2f %10.1f %10.1f %10.1f %8.1f\n",
                    cname, lbl,
                    r.lolh_hours, r.lolp_percent, r.lole_days,
                    r.eue_mwh, r.cvar_eue_mwh, r.max_shortfall_mw, r.runtime_s)
        end
    end
    println()

    if !isempty(error_rows)
        err_con = DataFrame(error_rows)
        println("Method errors vs M3:")
        println("-" ^ 80)
        @printf("  %-20s %-22s %9s %9s %+9s %10s\n",
                "Case", "Method", "M3_LOLH", "Meth_LOLH", "err_h", "speedup")
        println("  " * "-" ^ 74)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_con)
            isempty(sub) && continue
            for r in eachrow(sub)
                spd_str = isnan(r.runtime_speedup_vs_m3) ? "n/a" :
                          @sprintf("%.1fx", r.runtime_speedup_vs_m3)
                @printf("  %-20s %-22s %9.2f %9.2f %+9.2f %10s\n",
                        cname, r.method_label, r.m3_lolh, r.method_lolh,
                        r.lolh_error, spd_str)
            end
        end
    end

    @printf("\nTotal runtime: %.1f s\n", total_rt)
    @printf("Output: %s\n", abspath(out_dir))
    @printf("Summary: %s\n", abspath(summary_path))
    println()
end
