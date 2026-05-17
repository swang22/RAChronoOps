#!/usr/bin/env julia
# 21_run_m1c_comparison.jl
#
# Five-method comparison: M1, M1b, M1c, M2 (rm=1000/buf=48), M3.
# Validates the M1c emergency-only heuristic against the existing model ladder
# using common random numbers.
#
# M1c adds a new rung between M1b and M2:
#   M1  (RA-1a) — naive peak-shaving
#   M1b (RA-1b) — reserve-aware peak-shaving
#   M1c (RA-1c) — emergency-only (no proactive discharge; charges from surplus)
#   M2  (RA-2)  — event-window LP hybrid (rm=1000, buf=48)
#   M3  (RA-3)  — full-year ED LP benchmark
#
# Outputs (results/m1c_comparison/<subdir>/):
#   m1c_comparison_results.csv   — all models, expanded metrics
#   m1c_comparison_errors.csv    — each heuristic vs M3
#   summary.txt
#   run_<timestamp>.log
#
# Usage:
#   julia --project=. scripts/21_run_m1c_comparison.jl [options]
#
# Options:
#   --n-scenarios N      Number of MC scenarios       (default: 20)
#   --seed S             RNG seed                     (default: 42)
#   --cases C1,C2,...    Comma-separated VRE120 cases
#   --out-subdir DIR     Subdirectory name
#   --skip-m3            Omit M3 benchmark (fast testing mode)

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

# Fixed M2 configuration (best from N=20 validation, script 20)
const M2_RISK_MARGIN    = 1000.0
const M2_BUFFER         = 48
const M2_MIN_LEN        = 24
const M2_MERGE_GAP      = 24
const M2_LABEL          = "M2_rm1000_b48"

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
    base_out_dir = joinpath(project_root, "results", "m1c_comparison")
    abbr         = join([replace(c, "VRE120_" => "") for c in cases_to_run], "-")
    subdir       = get(kw, "out-subdir", "$(abbr)_n$(n_scenarios)")
    out_dir      = joinpath(base_out_dir, subdir)
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "M1c comparison"
    @info "n=$n_scenarios | seed=$seed | skip_m3=$skip_m3"
    @info "Cases: $(join(cases_to_run, ", "))"
    @info "M2 config: rm=$M2_RISK_MARGIN buf=$M2_BUFFER"
    @info "Output: $out_dir"

    results_path = joinpath(out_dir, "m1c_comparison_results.csv")
    errors_path  = joinpath(out_dir, "m1c_comparison_errors.csv")
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
            m3_runtime_s          = nan,   # filled post-loop
            method_runtime_s      = round(meth_rt; digits=1),
            runtime_speedup_vs_m3 = nan,   # filled post-loop
        )
    end

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

        # ── M1 ────────────────────────────────────────────────────────────────
        try
            m1_cfg = SimConfig(; n_scenarios, seed)
            @info "  running M1..."
            t0         = time()
            r_m1       = run_m1_rule_based(sys, scenarios, m1_cfg)
            rt         = time() - t0
            m          = compute_metrics(r_m1, sys, m1_cfg)
            push!(results_rows, make_results_row(cname, "M1", m, rt))
            @info "  M1:  LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
        catch e
            @error "M1 failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_results_row(cname, "M1", nothing, 0.0))
        end

        # ── M1b ───────────────────────────────────────────────────────────────
        try
            m1b_cfg = SimConfig(; n_scenarios, seed, reserve_fraction=0.50)
            @info "  running M1b..."
            t0    = time()
            r_m1b = run_m1b_reserve_aware(sys, scenarios, m1b_cfg)
            rt    = time() - t0
            m     = compute_metrics(r_m1b, sys, m1b_cfg)
            push!(results_rows, make_results_row(cname, "M1b", m, rt))
            @info "  M1b: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
        catch e
            @error "M1b failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_results_row(cname, "M1b", nothing, 0.0))
        end

        # ── M1c ───────────────────────────────────────────────────────────────
        try
            m1c_cfg = SimConfig(; n_scenarios, seed)
            @info "  running M1c..."
            t0    = time()
            r_m1c = run_m1c_emergency_only(sys, scenarios, m1c_cfg)
            rt    = time() - t0
            m     = compute_metrics(r_m1c, sys, m1c_cfg)
            push!(results_rows, make_results_row(cname, "M1c", m, rt))
            @info "  M1c: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
        catch e
            @error "M1c failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_results_row(cname, "M1c", nothing, 0.0))
        end

        # ── M2 (rm=1000/buf=48) ───────────────────────────────────────────────
        try
            m2_cfg = SimConfig(;
                n_scenarios,
                seed,
                reserve_fraction        = 0.50,
                risk_margin_mw          = M2_RISK_MARGIN,
                window_buffer_hours     = M2_BUFFER,
                min_window_length_hours = M2_MIN_LEN,
                merge_gap_hours         = M2_MERGE_GAP,
            )
            @info "  running $M2_LABEL..."
            t0          = time()
            r_m2, _diag = run_m2_with_diagnostics(sys, scenarios, m2_cfg)
            rt          = time() - t0
            m           = compute_metrics(r_m2, sys, m2_cfg)
            push!(results_rows, make_results_row(cname, M2_LABEL, m, rt))
            @info "  M2:  LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
        catch e
            @error "$M2_LABEL failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_results_row(cname, M2_LABEL, nothing, 0.0))
        end

        # ── M3 (once per case) ────────────────────────────────────────────────
        if !skip_m3
            try
                m3_cfg = SimConfig(; n_scenarios, seed)
                @info "  running M3 (RA-3, full-year ED LP)..."
                t0    = time()
                r_m3  = run_m3_ed_dispatch(sys, scenarios, m3_cfg)
                rt    = time() - t0
                m     = compute_metrics(r_m3, sys, m3_cfg)
                m3_metrics_by_case[cname] = m
                m3_runtime_by_case[cname] = rt
                push!(results_rows, make_results_row(cname, "M3", m, rt))
                @info "  M3:  LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
            catch e
                @error "M3 failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_results_row(cname, "M3", nothing, 0.0))
            end
        end

        # flush intermediate
        CSV.write(results_path, DataFrame(results_rows))
        @info "  Intermediate outputs saved → $out_dir"
    end

    total_rt = time() - total_t0
    @info "Total runtime: $(round(total_rt, digits=1)) s"

    df    = DataFrame(results_rows)
    ok_df = filter(r -> !isnan(r.lolh_hours), df)

    # ── build error rows ───────────────────────────────────────────────────────
    heuristic_labels = ["M1", "M1b", "M1c", M2_LABEL]
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
        sep  = "=" ^ 80
        println(io, sep)
        println(io, "M1c Emergency-Only Heuristic Comparison Summary")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d\n", n_scenarios, seed)
        @printf(io, "Cases: %s\n", join(cases_to_run, ", "))
        @printf(io, "M2 config: rm=%.0f  buf=%d  min_len=%d  merge_gap=%d\n",
                M2_RISK_MARGIN, M2_BUFFER, M2_MIN_LEN, M2_MERGE_GAP)
        println(io, sep)
        println(io)

        err_df = DataFrame(error_rows)
        all_labels = vcat(["M1", "M1b", "M1c", M2_LABEL], skip_m3 ? [] : ["M3"])

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

        # Q1: Does M1c outperform M1 and M1b?
        println(io, "Q1. Does M1c outperform M1 and M1b on LOLH accuracy?")
        println(io)
        if !isempty(err_df)
            for cname in cases_to_run
                sub = filter(r -> r.case_name == cname, err_df)
                isempty(sub) && continue
                println(io, "  $cname:")
                for lbl in ["M1", "M1b", "M1c"]
                    row = filter(r -> r.method_label == lbl, sub)
                    isempty(row) && continue
                    r = row[1, :]
                    @printf(io, "    %-6s LOLH=%7.2f h  err=%+7.2f h  abs=%.2f h  (%.1f%%)\n",
                            lbl, r.method_lolh, r.lolh_error, r.lolh_abs_error,
                            isnan(r.lolh_rel_error) ? 0.0 : 100.0*r.lolh_rel_error)
                end
                # verdict
                m1_row  = filter(r -> r.method_label == "M1",  sub)
                m1b_row = filter(r -> r.method_label == "M1b", sub)
                m1c_row = filter(r -> r.method_label == "M1c", sub)
                if !isempty(m1_row) && !isempty(m1b_row) && !isempty(m1c_row)
                    e1   = m1_row[1, :lolh_abs_error]
                    e1b  = m1b_row[1, :lolh_abs_error]
                    e1c  = m1c_row[1, :lolh_abs_error]
                    verdict = (e1c < e1b) ? "M1c < M1b: YES" : "M1c >= M1b: NO"
                    @printf(io, "    → M1c abs error %.2f h vs M1b %.2f h vs M1 %.2f h: %s\n",
                            e1c, e1b, e1, verdict)
                end
                println(io)
            end
        end

        # Q2: Is M1c closer to M3 than M1b?
        println(io, "Q2. Is M1c closer to M3 than M1b (mean absolute LOLH error)?")
        println(io)
        if !isempty(err_df)
            for lbl in ["M1", "M1b", "M1c", M2_LABEL]
                sub = filter(r -> r.method_label == lbl, err_df)
                isempty(sub) && continue
                mean_err = mean(sub.lolh_abs_error)
                mean_rt  = mean(sub.method_runtime_s)
                @printf(io, "  %-22s mean abs LOLH error = %.3f h  mean rt = %.1f s\n",
                        lbl, mean_err, mean_rt)
            end
        end
        println(io)

        # Q3: Does M1c overestimate or underestimate LOLH?
        println(io, "Q3. Does M1c overestimate or underestimate LOLH relative to M3?")
        println(io)
        if !isempty(err_df)
            m1c_rows = filter(r -> r.method_label == "M1c", err_df)
            if !isempty(m1c_rows)
                for r in eachrow(m1c_rows)
                    dir = r.lolh_error > 0 ? "overestimates" : "underestimates"
                    @printf(io, "  %s: M1c %s by %+.2f h (%+.1f%%)\n",
                            r.case_name, dir, r.lolh_error,
                            isnan(r.lolh_rel_error) ? 0.0 : 100.0*r.lolh_rel_error)
                end
                mean_err = mean(m1c_rows.lolh_error)
                @printf(io, "  Mean signed error: %+.3f h\n", mean_err)
                if mean_err > 0
                    println(io, "  → M1c systematically overestimates LOLH (storage underutilised).")
                elseif mean_err < 0
                    println(io, "  → M1c systematically underestimates LOLH (storage over-deployed).")
                else
                    println(io, "  → M1c shows no systematic LOLH bias.")
                end
            end
        end
        println(io)

        # Q4: How close is M1c to M2?
        println(io, "Q4. How close is M1c to M2 (event-window LP)?")
        println(io)
        if !isempty(err_df)
            for cname in cases_to_run
                sub = filter(r -> r.case_name == cname, err_df)
                m1c_r = filter(r -> r.method_label == "M1c",   sub)
                m2_r  = filter(r -> r.method_label == M2_LABEL, sub)
                (isempty(m1c_r) || isempty(m2_r)) && continue
                gap = m1c_r[1, :lolh_abs_error] - m2_r[1, :lolh_abs_error]
                @printf(io, "  %s:  M1c err=%.2f h  M2 err=%.2f h  gap=%.2f h\n",
                        cname, m1c_r[1, :lolh_abs_error], m2_r[1, :lolh_abs_error], gap)
            end
        end
        println(io)

        # Q5: Wind-heavy vs balanced
        println(io, "Q5. Does emergency-only dispatch work better in wind-heavy or balanced cases?")
        println(io)
        if !isempty(err_df)
            for cname in ["VRE120_wind_hvy", "VRE120_bal15"]
                sub = filter(r -> r.case_name == cname && r.method_label == "M1c", err_df)
                isempty(sub) && continue
                r = sub[1, :]
                @printf(io, "  %s:  M1c LOLH=%.2f h  err=%+.2f h (%.1f%%)\n",
                        cname, r.method_lolh, r.lolh_error,
                        isnan(r.lolh_rel_error) ? 0.0 : 100.0*r.lolh_rel_error)
            end
        end
        println(io)

        # Q6: Main table or appendix?
        println(io, "Q6. Should M1c appear in the main paper table or only the appendix?")
        println(io)
        if !isempty(err_df)
            m1b_mean = let sub = filter(r -> r.method_label == "M1b", err_df)
                isempty(sub) ? nan : mean(sub.lolh_abs_error)
            end
            m1c_mean = let sub = filter(r -> r.method_label == "M1c", err_df)
                isempty(sub) ? nan : mean(sub.lolh_abs_error)
            end
            m2_mean  = let sub = filter(r -> r.method_label == M2_LABEL, err_df)
                isempty(sub) ? nan : mean(sub.lolh_abs_error)
            end
            if !isnan(m1c_mean) && !isnan(m1b_mean) && !isnan(m2_mean)
                @printf(io, "  Mean abs LOLH error:  M1b=%.2f h  M1c=%.2f h  M2=%.2f h\n",
                        m1b_mean, m1c_mean, m2_mean)
                if m1c_mean < m1b_mean
                    println(io, "  → M1c outperforms M1b: recommend including in main paper table.")
                    println(io, "    M1c extends the baseline ladder and strengthens the M2 justification.")
                else
                    println(io, "  → M1c does not outperform M1b: appendix only.")
                    println(io, "    Include as supporting evidence that emergency-only dispatch")
                    println(io, "    does not resolve the heuristic LOLH overestimation.")
                end
            end
        end
        println(io)

        @printf(io, "Total runtime: %.1f s\n", total_rt)
        println(io, sep)
        println(io, "Files: m1c_comparison_results.csv")
        println(io, "       m1c_comparison_errors.csv")
    end

    # ── console output ─────────────────────────────────────────────────────────
    sep = "=" ^ 84
    println()
    println(sep)
    @printf("M1c Comparison  |  N=%d  |  seed=%d  |  subdir=%s\n",
            n_scenarios, seed, subdir)
    @printf("Cases: %s\n", join(cases_to_run, ", "))
    println(sep)

    @printf("  %-20s %-22s %8s %7s %7s %10s %10s %10s %8s\n",
            "Case", "Model", "LOLH(h)", "LOLP%", "LOLE_d",
            "EUE(MWh)", "CVaR-EUE", "MaxSF(MW)", "rt(s)")
    println("  " * "-" ^ 90)
    for lbl in vcat(["M1", "M1b", "M1c", M2_LABEL], skip_m3 ? [] : ["M3"])
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
