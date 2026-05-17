#!/usr/bin/env julia
# 17_run_ra2_priority_validation.jl
#
# Validate RA-2 (event-window LP) against RA-1b and RA-3 on the three priority
# VRE cases identified in script 16 (VRE120_base, VRE120_bal15, VRE120_wind_hvy).
#
# Research questions answered in summary.txt:
#   Q1. Does RA-2 reduce LOLH error vs RA-1b (relative to RA-3 benchmark)?
#   Q2. What is the remaining gap between RA-2 and RA-3?
#   Q3. What fraction of each scenario-year is processed by LP windows?
#   Q4. Are there LP solve failures?
#   Q5. What is the runtime cost of RA-2 vs RA-1b and RA-3?
#
# Outputs (written under results/ra2_priority_validation/<subdir>/):
#   ra2_validation_results.csv  — per-model aggregate metrics
#   ra2_validation_errors.csv   — method vs M3 error analysis
#   ra2_window_diags.csv        — RA-2 per-scenario window diagnostics
#   summary.txt                 — human-readable findings
#   run_<timestamp>.log         — full run log
#
# Usage:
#   julia --project=. scripts/17_run_ra2_priority_validation.jl [options]
#
# Options:
#   --n-scenarios N     Number of MC scenarios (default: 5)
#   --seed S            RNG seed               (default: 42)
#   --skip-m3           Omit RA-3 (fast mode)
#   --cases C1,C2,...   Comma-separated VRE120 cases (default: priority three)
#   --out-subdir DIR    Subdirectory under results/ra2_priority_validation/

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

const PRIORITY_CASES = [
    "VRE120_base",
    "VRE120_bal15",
    "VRE120_wind_hvy",
]
const ALL_VRE120_CASES = [
    "VRE120_base",
    "VRE120_bal15",
    "VRE120_bal20",
    "VRE120_bal30",
    "VRE120_solar_hvy",
    "VRE120_wind_hvy",
]

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") ||
            error("Unexpected positional argument: $arg")
        key = arg[3:end]
        if key == "skip-m3"
            kw["skip-m3"] = "true"
            i += 1
        else
            i + 1 <= length(args) && !startswith(args[i+1], "--") ||
                error("Option $arg requires a value")
            kw[key] = args[i+1]
            i += 2
        end
    end
    return kw
end

function auto_subdir(cases::Vector{String}, n_scenarios::Int)
    abbr = join([replace(c, "VRE120_" => "") for c in cases], "-")
    return "$(abbr)_n$(n_scenarios)"
end

# ── main ──────────────────────────────────────────────────────────────────────
let
    kw = parse_cli(ARGS)

    n_scenarios = parse(Int, get(kw, "n-scenarios", "5"))
    seed        = parse(Int, get(kw, "seed",         "42"))
    skip_m3     = get(kw, "skip-m3", "false") == "true"

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
    base_out_dir = joinpath(project_root, "results", "ra2_priority_validation")
    subdir       = get(kw, "out-subdir", auto_subdir(cases_to_run, n_scenarios))
    out_dir      = joinpath(base_out_dir, subdir)
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "RA-2 priority validation | n=$n_scenarios | seed=$seed | skip_m3=$skip_m3"
    @info "Cases: $(join(cases_to_run, ", "))"
    @info "Output: $out_dir"

    # ── load VRE case summary for penetration metadata ────────────────────────
    vre_meta_path = joinpath(base_out_dir, "..", "vre_method_comparison", "vre_case_summary.csv")
    # fallback: try project-root results dir
    if !isfile(vre_meta_path)
        vre_meta_path = joinpath(project_root, "results", "vre_method_comparison", "vre_case_summary.csv")
    end
    vre_meta = if isfile(vre_meta_path)
        CSV.read(vre_meta_path, DataFrame)
    else
        @warn "vre_case_summary.csv not found; VRE metadata columns will be NaN"
        DataFrame()
    end

    results_path = joinpath(out_dir, "ra2_validation_results.csv")
    errors_path  = joinpath(out_dir, "ra2_validation_errors.csv")
    diags_path   = joinpath(out_dir, "ra2_window_diags.csv")
    summary_path = joinpath(out_dir, "summary.txt")

    results_rows = NamedTuple[]
    diag_rows    = NamedTuple[]

    model_labels = skip_m3 ? ["M1b", "M2"] : ["M1b", "M2", "M3"]
    total_t0 = time()

    for cname in cases_to_run
        cdir = joinpath(cases_root, cname)
        if !isdir(cdir)
            @warn "Case directory not found — skipping: $cdir"
            continue
        end

        meta_rows = isempty(vre_meta) ? DataFrame() :
                    filter(r -> r.case_name == cname, vre_meta)
        has_meta  = !isempty(meta_rows)
        vmeta     = has_meta ? first(meta_rows) : nothing

        @info "── Case: $cname ──────────────────────────────────────────────"
        sys = load_system_data(cdir)

        crn_cfg   = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)

        nan = NaN
        function make_row(model, metrics, rt, status, errmsg)
            m = metrics
            return (
                case_name                       = cname,
                model                           = model,
                n_scenarios                     = n_scenarios,
                seed                            = seed,
                load_scale      = has_meta ? vmeta.load_scale                      : nan,
                wind_scale      = has_meta ? vmeta.wind_scale                      : nan,
                solar_scale     = has_meta ? vmeta.solar_scale                     : nan,
                available_vre_energy_share      = has_meta ? vmeta.available_vre_energy_share      : nan,
                vre_capacity_share_no_storage   = has_meta ? vmeta.vre_capacity_share_no_storage   : nan,
                vre_capacity_share_incl_storage = has_meta ? vmeta.vre_capacity_share_incl_storage : nan,
                negative_net_load_hours         = has_meta ? vmeta.negative_net_load_hours         : nan,
                vre_exceeds_load_hours          = has_meta ? vmeta.vre_exceeds_load_hours          : nan,
                net_load_peak_mw                = has_meta ? vmeta.net_load_peak_mw                : nan,
                lolh_hours                      = isnothing(m) ? nan : m.lolh,
                lolp                            = isnothing(m) ? nan : m.lolp,
                lolp_percent                    = isnothing(m) ? nan : 100.0 * m.lolp,
                lole_days                       = isnothing(m) ? nan : m.lole_days,
                eue_mwh                         = isnothing(m) ? nan : m.eue,
                neue_ppm                        = isnothing(m) ? nan : m.neue * 1e6,
                cvar_eue_mwh                    = isnothing(m) ? nan : m.cvar_eue,
                p50_scenario_eue_mwh            = isnothing(m) ? nan : m.p50_scenario_eue,
                p90_scenario_eue_mwh            = isnothing(m) ? nan : m.p90_scenario_eue,
                p95_scenario_eue_mwh            = isnothing(m) ? nan : m.p95_scenario_eue,
                p99_scenario_eue_mwh            = isnothing(m) ? nan : m.p99_scenario_eue,
                n_shortage_events               = isnothing(m) ? nan : m.n_shortage_events,
                mean_shortage_duration_h        = isnothing(m) ? nan : m.mean_shortage_duration,
                max_shortage_duration_h         = isnothing(m) ? nan : m.max_shortage_duration,
                p95_shortage_duration_h         = isnothing(m) ? nan : m.p95_shortage_duration,
                max_shortfall_mw                = isnothing(m) ? nan : m.max_shortfall,
                mean_shortfall_when_shedding_mw = isnothing(m) ? nan : m.mean_shortfall_when_shedding,
                lolh_ci95_halfwidth             = isnothing(m) ? nan : m.lolh_ci95_halfwidth,
                lolh_ci95_rel_halfwidth         = isnothing(m) ? nan : m.lolh_ci95_rel_halfwidth,
                eue_ci95_halfwidth_mwh          = isnothing(m) ? nan : m.eue_ci95_halfwidth,
                eue_ci95_rel_halfwidth          = isnothing(m) ? nan : m.eue_ci95_rel_halfwidth,
                runtime_s                       = round(rt; digits=1),
                status                          = status,
                error_message                   = errmsg,
            )
        end

        # ── RA-1b (M1b) ───────────────────────────────────────────────────────
        try
            m1b_cfg = SimConfig(; n_scenarios, seed, reserve_fraction=0.50)
            @info "  running M1b (RA-1b)..."
            t0    = time()
            r_m1b = run_m1b_reserve_aware(sys, scenarios, m1b_cfg)
            rt    = time() - t0
            m_m1b = compute_metrics(r_m1b, sys, m1b_cfg)
            push!(results_rows, make_row("M1b", m_m1b, rt, "ok", ""))
            @info "  M1b: LOLH=$(round(m_m1b.lolh, digits=2)) h  EUE=$(round(m_m1b.eue, digits=1)) MWh  ($(round(rt, digits=1))s)"
        catch e
            @error "M1b failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_row("M1b", nothing, 0.0, "error", sprint(showerror, e)))
        end

        # ── RA-2 event-window LP (M2) ─────────────────────────────────────────
        try
            m2_cfg = SimConfig(; n_scenarios, seed, reserve_fraction=0.50)
            @info "  running M2 (RA-2 event-window LP)..."
            t0          = time()
            r_m2, diags = run_m2_with_diagnostics(sys, scenarios, m2_cfg)
            rt          = time() - t0
            m_m2        = compute_metrics(r_m2, sys, m2_cfg)
            push!(results_rows, make_row("M2", m_m2, rt, "ok", ""))
            @info "  M2:  LOLH=$(round(m_m2.lolh, digits=2)) h  EUE=$(round(m_m2.eue, digits=1)) MWh  ($(round(rt, digits=1))s)"

            # aggregate window diagnostics
            n_lp_fail_total = sum(d.n_lp_failures  for d in diags)
            mean_n_windows  = mean(d.n_windows      for d in diags)
            mean_coverage   = mean(d.total_window_h for d in diags) / sys.n_hours
            mean_risk_h     = mean(d.n_risk_hours   for d in diags)
            @info "  M2 windows: mean=$(round(mean_n_windows, digits=1))/scen  " *
                  "coverage=$(round(100*mean_coverage, digits=1))%  LP_fails=$n_lp_fail_total"

            for d in diags
                push!(diag_rows, (
                    case_name       = cname,
                    scenario_id     = d.scenario_id,
                    n_risk_hours    = d.n_risk_hours,
                    n_windows       = d.n_windows,
                    total_window_h  = d.total_window_h,
                    window_coverage = sys.n_hours > 0 ? d.total_window_h / sys.n_hours : 0.0,
                    mean_window_len = d.mean_window_len,
                    max_window_len  = d.max_window_len,
                    n_lp_failures   = d.n_lp_failures,
                ))
            end
        catch e
            @error "M2 failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_row("M2", nothing, 0.0, "error", sprint(showerror, e)))
        end

        # ── RA-3 (M3) — optional benchmark ────────────────────────────────────
        if !skip_m3
            try
                m3_cfg = SimConfig(; n_scenarios, seed)
                @info "  running M3 (RA-3, full-year ED LP) — may be slow..."
                t0   = time()
                r_m3 = run_m3_ed_dispatch(sys, scenarios, m3_cfg)
                rt   = time() - t0
                m_m3 = compute_metrics(r_m3, sys, m3_cfg)
                push!(results_rows, make_row("M3", m_m3, rt, "ok", ""))
                @info "  M3:  LOLH=$(round(m_m3.lolh, digits=2)) h  EUE=$(round(m_m3.eue, digits=1)) MWh  ($(round(rt, digits=1))s)"
            catch e
                @error "M3 failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_row("M3", nothing, 0.0, "error", sprint(showerror, e)))
            end
        end

        # flush intermediate outputs after every case
        CSV.write(results_path, DataFrame(results_rows))
        isempty(diag_rows) || CSV.write(diags_path, DataFrame(diag_rows))
        @info "  Intermediate results saved → $results_path"
    end

    total_rt = time() - total_t0
    @info "Total runtime: $(round(total_rt, digits=1)) s"

    df    = DataFrame(results_rows)
    ok_df = filter(r -> r.status == "ok", df)

    # ── error comparison table ─────────────────────────────────────────────────
    error_rows = NamedTuple[]
    if !skip_m3
        for cname in cases_to_run
            m3_row = filter(r -> r.case_name == cname && r.model == "M3" && r.status == "ok", ok_df)
            isempty(m3_row) && continue
            m3_lolh = m3_row[1, :lolh_hours]
            m3_eue  = m3_row[1, :eue_mwh]
            safe_rel(mval, bval) = bval > 0.0 ? (mval - bval) / bval : NaN
            for mlabel in ("M1b", "M2")
                mrow = filter(r -> r.case_name == cname && r.model == mlabel && r.status == "ok", ok_df)
                isempty(mrow) && continue
                push!(error_rows, (
                    case_name         = cname,
                    method            = mlabel,
                    m3_lolh           = m3_lolh,
                    method_lolh       = mrow[1, :lolh_hours],
                    lolh_err_h        = mrow[1, :lolh_hours] - m3_lolh,
                    lolh_rel_err      = safe_rel(mrow[1, :lolh_hours], m3_lolh),
                    m3_eue            = m3_eue,
                    method_eue        = mrow[1, :eue_mwh],
                    eue_err_mwh       = mrow[1, :eue_mwh] - m3_eue,
                    eue_rel_err       = safe_rel(mrow[1, :eue_mwh], m3_eue),
                    m3_cvar_eue       = m3_row[1, :cvar_eue_mwh],
                    method_cvar_eue   = mrow[1, :cvar_eue_mwh],
                    cvar_eue_err      = mrow[1, :cvar_eue_mwh] - m3_row[1, :cvar_eue_mwh],
                    runtime_vs_m3     = m3_row[1, :runtime_s] > 0.0 ?
                                        m3_row[1, :runtime_s] / mrow[1, :runtime_s] : NaN,
                ))
            end
        end
    end

    CSV.write(results_path, df)
    CSV.write(errors_path,  DataFrame(error_rows))
    isempty(diag_rows) || CSV.write(diags_path, DataFrame(diag_rows))

    # ── write summary.txt ─────────────────────────────────────────────────────
    open(summary_path, "w") do io
        sep = "=" ^ 80
        println(io, sep)
        println(io, "RA-2 Priority Validation Summary")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d  |  skip_m3: %s\n",
                n_scenarios, seed, skip_m3)
        @printf(io, "Cases: %s\n", join(cases_to_run, ", "))
        println(io, sep)
        println(io)

        # ── main results table ─────────────────────────────────────────────────
        println(io, "Aggregate reliability metrics")
        println(io, "-" ^ 100)
        @printf(io, "  %-20s %-5s %8s %7s %7s %10s %10s %10s %8s\n",
                "Case", "Model", "LOLH(h)", "LOLP%", "LOLE_d",
                "EUE(MWh)", "CVaR-EUE", "MaxSF(MW)", "rt(s)")
        println(io, "  " * "-" ^ 94)
        for r in eachrow(ok_df)
            @printf(io, "  %-20s %-5s %8.2f %7.3f %7.2f %10.1f %10.1f %10.1f %8.1f\n",
                    r.case_name, r.model,
                    r.lolh_hours, 100.0 * r.lolp, r.lole_days,
                    r.eue_mwh, r.cvar_eue_mwh, r.max_shortfall_mw, r.runtime_s)
        end
        println(io)
        println(io, "  Note: RA-2 window diagnostics are in ra2_window_diags.csv")

        # ── error comparison (vs M3) ───────────────────────────────────────────
        if !skip_m3 && !isempty(error_rows)
            println(io)
            println(io, "Method error vs M3 benchmark")
            println(io, "-" ^ 90)
            @printf(io, "  %-20s %-5s %10s %10s %10s %12s\n",
                    "Case", "Meth", "M3_LOLH", "Meth_LOLH", "err_h", "rel_err")
            println(io, "  " * "-" ^ 84)
            for r in eachrow(DataFrame(error_rows))
                rel_pct = isnan(r.lolh_rel_err) ? "n/a" :
                          @sprintf("%+.1f%%", 100.0 * r.lolh_rel_err)
                @printf(io, "  %-20s %-5s %10.2f %10.2f %10.2f %12s\n",
                        r.case_name, r.method, r.m3_lolh, r.method_lolh,
                        r.lolh_err_h, rel_pct)
            end
            println(io)

            # ── Q1: RA-2 error reduction vs RA-1b ─────────────────────────────
            println(io, "Q1. Does RA-2 reduce LOLH error vs RA-1b (relative to M3 benchmark)?")
            err_df = DataFrame(error_rows)
            for cname in cases_to_run
                m1b_rows = filter(r -> r.case_name == cname && r.method == "M1b", err_df)
                m2_rows  = filter(r -> r.case_name == cname && r.method == "M2",  err_df)
                (isempty(m1b_rows) || isempty(m2_rows)) && continue
                m1b_err  = m1b_rows[1, :lolh_err_h]
                m2_err   = m2_rows[1,  :lolh_err_h]
                direction = m2_err < m1b_err ? "↓ improved" : "↑ worsened"
                @printf(io, "  %-20s  M1b_err=%+.2f h  M2_err=%+.2f h  %s %.2f h\n",
                        cname, m1b_err, m2_err, direction, abs(m1b_err - m2_err))
            end

            # ── Q2: remaining gap (M2 vs M3) ──────────────────────────────────
            println(io)
            println(io, "Q2. Remaining gap — M2 vs M3:")
            for cname in cases_to_run
                m2_rows = filter(r -> r.case_name == cname && r.method == "M2", err_df)
                isempty(m2_rows) && continue
                rel_pct = isnan(m2_rows[1, :lolh_rel_err]) ? "n/a" :
                          @sprintf("%+.1f%%", 100.0 * m2_rows[1, :lolh_rel_err])
                @printf(io, "  %-20s  M2=%+.2f h vs M3=%.2f h  (%s)\n",
                        cname, m2_rows[1, :lolh_err_h],
                        m2_rows[1, :m3_lolh], rel_pct)
            end
        end

        # ── Q3: window coverage ────────────────────────────────────────────────
        if !isempty(diag_rows)
            diag_df = DataFrame(diag_rows)
            println(io)
            println(io, "Q3. RA-2 window coverage (fraction of scenario-hours in LP windows):")
            for cname in cases_to_run
                cd = filter(r -> r.case_name == cname, diag_df)
                isempty(cd) && continue
                mean_cov    = mean(cd.window_coverage)
                mean_nwin   = mean(cd.n_windows)
                mean_riskh  = mean(cd.n_risk_hours)
                total_fails = sum(cd.n_lp_failures)
                @printf(io, "  %-20s  coverage=%.1f%%  mean_windows=%.1f  mean_risk_h=%.0f  lp_failures=%d\n",
                        cname, 100.0 * mean_cov, mean_nwin, mean_riskh, total_fails)
            end

            # ── Q4: LP failure rate ────────────────────────────────────────────
            println(io)
            total_lp_fails = sum(r.n_lp_failures for r in diag_rows)
            total_wins     = sum(r.n_windows      for r in diag_rows)
            println(io, "Q4. LP failure rate:")
            @printf(io, "  Total LP windows solved: %d  |  Failures: %d  |  Rate: %.3f%%\n",
                    total_wins, total_lp_fails,
                    total_wins > 0 ? 100.0 * total_lp_fails / total_wins : 0.0)
        end

        # ── Q5: runtime comparison ─────────────────────────────────────────────
        println(io)
        println(io, "Q5. Runtime comparison:")
        for cname in cases_to_run
            for mlabel in model_labels
                mrow = filter(r -> r.case_name == cname && r.model == mlabel && r.status == "ok", ok_df)
                isempty(mrow) && continue
                @printf(io, "  %-20s  %-5s  %.1f s\n", cname, mlabel, mrow[1, :runtime_s])
            end
        end

        println(io)
        println(io, "Runtime summary")
        println(io, "-" ^ 40)
        @printf(io, "  Total wall time: %.1f s\n", total_rt)
        println(io)
        println(io, sep)
        println(io, "Full results: ra2_validation_results.csv")
        println(io, "Error table:  ra2_validation_errors.csv")
        println(io, "Window diags: ra2_window_diags.csv")
        @printf(io, "Log:          run_%s.log\n",
                Dates.format(now(), "yyyymmdd_HHMMSS"))
    end

    # ── console output ─────────────────────────────────────────────────────────
    sep  = "=" ^ 90
    sep2 = "-" ^ 84
    n_cases = length(cases_to_run)
    println()
    println(sep)
    @printf("RA-2 Priority Validation  |  n_scenarios=%d  |  seed=%d  |  subdir=%s\n",
            n_scenarios, seed, subdir)
    @printf("Cases: %s\n", join(cases_to_run, ", "))
    println(sep)

    @printf("  %-20s %-5s %8s %7s %7s %10s %10s %10s %8s\n",
            "Case", "Model", "LOLH(h)", "LOLP%", "LOLE_d",
            "EUE(MWh)", "CVaR-EUE", "MaxSF(MW)", "rt(s)")
    println("  " * "-" ^ 84)
    for r in eachrow(ok_df)
        @printf("  %-20s %-5s %8.2f %7.3f %7.2f %10.1f %10.1f %10.1f %8.1f\n",
                r.case_name, r.model,
                r.lolh_hours, 100.0 * r.lolp, r.lole_days,
                r.eue_mwh, r.cvar_eue_mwh, r.max_shortfall_mw, r.runtime_s)
    end
    println()
    println("  Note: Full CSV outputs include event-duration metrics, scenario-EUE quantiles,")
    println("        and Monte Carlo confidence intervals.")
    println(sep)

    if !skip_m3 && !isempty(error_rows)
        println()
        println("M1b / M2 vs M3 error analysis")
        println("-" ^ 74)
        @printf("  %-20s %-5s %10s %10s %10s %12s\n",
                "Case", "Meth", "M3_LOLH", "Meth_LOLH", "err_h", "rel_err")
        println("  " * "-" ^ 70)
        for r in eachrow(DataFrame(error_rows))
            rel_pct = isnan(r.lolh_rel_err) ? "n/a" :
                      @sprintf("%+.1f%%", 100.0 * r.lolh_rel_err)
            @printf("  %-20s %-5s %10.2f %10.2f %10.2f %12s\n",
                    r.case_name, r.method, r.m3_lolh, r.method_lolh,
                    r.lolh_err_h, rel_pct)
        end
        println("-" ^ 74)
    end

    if !isempty(diag_rows)
        diag_df = DataFrame(diag_rows)
        println()
        println("RA-2 window diagnostics (means across scenarios)")
        println("-" ^ 74)
        @printf("  %-20s %10s %12s %12s %10s\n",
                "Case", "coverage%", "mean_windows", "mean_risk_h", "lp_fails")
        println("  " * "-" ^ 68)
        for cname in cases_to_run
            cd = filter(r -> r.case_name == cname, diag_df)
            isempty(cd) && continue
            @printf("  %-20s %10.1f %12.1f %12.0f %10d\n",
                    cname,
                    100.0 * mean(cd.window_coverage),
                    mean(cd.n_windows),
                    mean(cd.n_risk_hours),
                    sum(cd.n_lp_failures))
        end
        println("-" ^ 74)
    end

    @printf("\nTotal runtime: %.1f s\n", total_rt)
    @printf("Output directory: %s\n", abspath(out_dir))
    @printf("Summary written to: %s\n", abspath(summary_path))
    println()
end
