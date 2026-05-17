#!/usr/bin/env julia
# 20_run_ra2_n20_selected_params.jl
#
# N=20 validation of selected RA-2 parameter settings identified in the N=5 sensitivity
# study (script 19). Runs M1b once, M3 once, and two RA-2 configurations per case,
# sharing the same ScenarioSet (CRN) throughout.
#
# Default RA-2 configurations (from script-19 ranking):
#   1. risk_margin_mw=1000, window_buffer_hours=48  — lowest mean LOLH error at N=5
#   2. risk_margin_mw=800,  window_buffer_hours=24  — best accuracy/runtime balance
# Fixed: min_window_length_hours=24, merge_gap_hours=24
#
# Outputs (results/ra2_n20_selected_params/<subdir>/):
#   ra2_n20_selected_params_results.csv    — all models, expanded metrics
#   ra2_n20_selected_params_errors.csv     — M1b and each M2 config vs M3
#   ra2_n20_selected_params_window_diags.csv
#   summary.txt
#   run_<timestamp>.log
#
# Usage:
#   julia --project=. scripts/20_run_ra2_n20_selected_params.jl [options]
#
# Options:
#   --n-scenarios N      Number of MC scenarios       (default: 20)
#   --seed S             RNG seed                     (default: 42)
#   --cases C1,C2,...    Comma-separated VRE120 cases
#   --ra2-configs SPEC   Comma-sep rm:buf pairs       (default: "1000:48,800:24")
#   --out-subdir DIR     Subdirectory under results/ra2_n20_selected_params/
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
const FIXED_MIN_LEN   = 24
const FIXED_MERGE_GAP = 24
const DEFAULT_RA2_SPEC = "1000:48,800:24"

function parse_ra2_configs(s::String)
    result = NamedTuple[]
    for part in split(s, ",")
        tokens = split(strip(part), ":")
        length(tokens) == 2 ||
            error("Invalid --ra2-configs entry: '$part'  (expected rm:buf, e.g. 1000:48)")
        rm  = parse(Float64, tokens[1])
        buf = parse(Int,     tokens[2])
        label = "M2_rm$(Int(rm))_b$(buf)"
        push!(result, (risk_margin_mw=rm, window_buffer_hours=buf, label=label))
    end
    return result
end

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
    ra2_spec     = get(kw, "ra2-configs", DEFAULT_RA2_SPEC)
    ra2_configs  = parse_ra2_configs(ra2_spec)

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
    base_out_dir = joinpath(project_root, "results", "ra2_n20_selected_params")
    abbr         = join([replace(c, "VRE120_" => "") for c in cases_to_run], "-")
    subdir       = get(kw, "out-subdir", "$(abbr)_n$(n_scenarios)")
    out_dir      = joinpath(base_out_dir, subdir)
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "RA-2 N=20 selected-params validation"
    @info "n=$n_scenarios | seed=$seed | skip_m3=$skip_m3"
    @info "Cases: $(join(cases_to_run, ", "))"
    @info "RA-2 configs: $([(c.label, c.risk_margin_mw, c.window_buffer_hours) for c in ra2_configs])"
    @info "Output: $out_dir"

    results_path = joinpath(out_dir, "ra2_n20_selected_params_results.csv")
    errors_path  = joinpath(out_dir, "ra2_n20_selected_params_errors.csv")
    diags_path   = joinpath(out_dir, "ra2_n20_selected_params_window_diags.csv")
    summary_path = joinpath(out_dir, "summary.txt")

    results_rows = NamedTuple[]
    diag_rows    = NamedTuple[]

    m3_metrics_by_case = Dict{String, Any}()
    m3_runtime_by_case = Dict{String, Float64}()

    nan = NaN

    function make_results_row(cname, label, rm, buf, m, rt)
        (
            case_name                       = cname,
            model_label                     = label,
            risk_margin_mw                  = Float64(rm),
            window_buffer_hours             = Float64(buf),
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

    function make_error_row(cname, label, rm, buf, m3, meth, meth_rt,
                            mean_cov, mean_nwin, total_lp_fails)
        safe_rel(a, b) = b != 0.0 && !isnan(b) ? (a - b) / b : nan
        (
            case_name                     = cname,
            method_label                  = label,
            risk_margin_mw                = Float64(rm),
            window_buffer_hours           = Float64(buf),
            m3_lolh                       = isnothing(m3)   ? nan : m3.lolh,
            method_lolh                   = isnothing(meth) ? nan : meth.lolh,
            lolh_error                    = isnothing(meth) || isnothing(m3) ? nan : meth.lolh - m3.lolh,
            lolh_abs_error                = isnothing(meth) || isnothing(m3) ? nan : abs(meth.lolh - m3.lolh),
            lolh_rel_error                = isnothing(meth) || isnothing(m3) ? nan : safe_rel(meth.lolh, m3.lolh),
            m3_eue                        = isnothing(m3)   ? nan : m3.eue,
            method_eue                    = isnothing(meth) ? nan : meth.eue,
            eue_error                     = isnothing(meth) || isnothing(m3) ? nan : meth.eue - m3.eue,
            eue_rel_error                 = isnothing(meth) || isnothing(m3) ? nan : safe_rel(meth.eue, m3.eue),
            m3_cvar_eue                   = isnothing(m3)   ? nan : m3.cvar_eue,
            method_cvar_eue               = isnothing(meth) ? nan : meth.cvar_eue,
            cvar_eue_error                = isnothing(meth) || isnothing(m3) ? nan : meth.cvar_eue - m3.cvar_eue,
            m3_lole_days                  = isnothing(m3)   ? nan : m3.lole_days,
            method_lole_days              = isnothing(meth) ? nan : meth.lole_days,
            lole_days_error               = isnothing(meth) || isnothing(m3) ? nan : meth.lole_days - m3.lole_days,
            m3_max_shortfall              = isnothing(m3)   ? nan : m3.max_shortfall,
            method_max_shortfall          = isnothing(meth) ? nan : meth.max_shortfall,
            max_shortfall_error           = isnothing(meth) || isnothing(m3) ? nan : meth.max_shortfall - m3.max_shortfall,
            m3_mean_shortfall             = isnothing(m3)   ? nan : m3.mean_shortfall_when_shedding,
            method_mean_shortfall         = isnothing(meth) ? nan : meth.mean_shortfall_when_shedding,
            mean_shortfall_error          = isnothing(meth) || isnothing(m3) ? nan : meth.mean_shortfall_when_shedding - m3.mean_shortfall_when_shedding,
            m3_runtime_s                  = nan,  # filled in post-loop
            method_runtime_s              = round(meth_rt; digits=1),
            runtime_speedup_vs_m3         = nan,  # filled in post-loop
            mean_window_coverage_fraction = mean_cov,
            mean_n_windows                = mean_nwin,
            total_lp_failures             = total_lp_fails,
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

        # ── M1b ───────────────────────────────────────────────────────────────
        m1b_metrics = nothing
        m1b_rt      = 0.0
        try
            m1b_cfg = SimConfig(; n_scenarios, seed, reserve_fraction=0.50)
            @info "  running M1b..."
            t0          = time()
            r_m1b       = run_m1b_reserve_aware(sys, scenarios, m1b_cfg)
            m1b_rt      = time() - t0
            m1b_metrics = compute_metrics(r_m1b, sys, m1b_cfg)
            push!(results_rows, make_results_row(cname, "M1b", nan, nan, m1b_metrics, m1b_rt))
            @info "  M1b: LOLH=$(round(m1b_metrics.lolh, digits=2)) h  EUE=$(round(m1b_metrics.eue, digits=1)) MWh  ($(round(m1b_rt, digits=1)) s)"
        catch e
            @error "M1b failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_results_row(cname, "M1b", nan, nan, nothing, 0.0))
        end

        # ── M3 (once per case) ────────────────────────────────────────────────
        m3_metrics = nothing
        m3_rt      = 0.0
        if !skip_m3
            try
                m3_cfg = SimConfig(; n_scenarios, seed)
                @info "  running M3 (RA-3, full-year ED LP)..."
                t0         = time()
                r_m3       = run_m3_ed_dispatch(sys, scenarios, m3_cfg)
                m3_rt      = time() - t0
                m3_metrics = compute_metrics(r_m3, sys, m3_cfg)
                m3_metrics_by_case[cname] = m3_metrics
                m3_runtime_by_case[cname] = m3_rt
                push!(results_rows, make_results_row(cname, "M3", nan, nan, m3_metrics, m3_rt))
                @info "  M3:  LOLH=$(round(m3_metrics.lolh, digits=2)) h  EUE=$(round(m3_metrics.eue, digits=1)) MWh  ($(round(m3_rt, digits=1)) s)"
            catch e
                @error "M3 failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_results_row(cname, "M3", nan, nan, nothing, 0.0))
            end
        end

        # ── M2 configs ────────────────────────────────────────────────────────
        for cfg in ra2_configs
            try
                m2_cfg = SimConfig(;
                    n_scenarios,
                    seed,
                    reserve_fraction        = 0.50,
                    risk_margin_mw          = cfg.risk_margin_mw,
                    window_buffer_hours     = cfg.window_buffer_hours,
                    min_window_length_hours = FIXED_MIN_LEN,
                    merge_gap_hours         = FIXED_MERGE_GAP,
                )
                @info "  running $(cfg.label) (rm=$(cfg.risk_margin_mw) buf=$(cfg.window_buffer_hours))..."
                t0            = time()
                r_m2, diags   = run_m2_with_diagnostics(sys, scenarios, m2_cfg)
                m2_rt         = time() - t0
                m2_metrics    = compute_metrics(r_m2, sys, m2_cfg)
                push!(results_rows, make_results_row(
                    cname, cfg.label, cfg.risk_margin_mw, cfg.window_buffer_hours,
                    m2_metrics, m2_rt))

                n_lp_fail = sum(d.n_lp_failures  for d in diags)
                mean_wins = mean(d.n_windows      for d in diags)
                mean_cov  = mean(d.total_window_h for d in diags) / sys.n_hours
                @info "  $(cfg.label): LOLH=$(round(m2_metrics.lolh, digits=2)) h  cov=$(round(100*mean_cov, digits=1))%  wins=$(round(mean_wins, digits=1))  LP_fails=$n_lp_fail  ($(round(m2_rt, digits=1)) s)"

                for d in diags
                    push!(diag_rows, (
                        case_name           = cname,
                        m2_label            = cfg.label,
                        risk_margin_mw      = Float64(cfg.risk_margin_mw),
                        window_buffer_hours = Float64(cfg.window_buffer_hours),
                        scenario_id         = d.scenario_id,
                        n_risk_hours        = d.n_risk_hours,
                        n_windows           = d.n_windows,
                        total_window_h      = d.total_window_h,
                        window_coverage     = sys.n_hours > 0 ? d.total_window_h / sys.n_hours : 0.0,
                        mean_window_len     = d.mean_window_len,
                        max_window_len      = d.max_window_len,
                        n_lp_failures       = d.n_lp_failures,
                    ))
                end
            catch e
                @error "$(cfg.label) failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_results_row(
                    cname, cfg.label, cfg.risk_margin_mw, cfg.window_buffer_hours, nothing, 0.0))
            end
        end

        # flush intermediate
        CSV.write(results_path, DataFrame(results_rows))
        isempty(diag_rows) || CSV.write(diags_path, DataFrame(diag_rows))
        @info "  Intermediate outputs saved → $out_dir"
    end

    total_rt = time() - total_t0
    @info "Total runtime: $(round(total_rt, digits=1)) s"

    df    = DataFrame(results_rows)
    ok_df = filter(r -> !isnan(r.lolh_hours), df)

    # ── build error rows ───────────────────────────────────────────────────────
    error_rows = NamedTuple[]
    if !skip_m3
        diag_df_full = isempty(diag_rows) ? DataFrame() : DataFrame(diag_rows)

        for cname in cases_to_run
            haskey(m3_metrics_by_case, cname) || continue
            m3    = m3_metrics_by_case[cname]
            m3_rt = get(m3_runtime_by_case, cname, 0.0)

            # M1b error
            m1b_r = filter(r -> r.case_name == cname && r.model_label == "M1b" && !isnan(r.lolh_hours), ok_df)
            if !isempty(m1b_r)
                r = m1b_r[1, :]
                m1b_m = (lolh=r.lolh_hours, eue=r.eue_mwh, cvar_eue=r.cvar_eue_mwh,
                         lole_days=r.lole_days, max_shortfall=r.max_shortfall_mw,
                         mean_shortfall_when_shedding=r.mean_shortfall_when_shedding_mw)
                row = make_error_row(cname, "M1b", nan, nan, m3, m1b_m, r.runtime_s,
                                     nan, nan, 0)
                push!(error_rows, merge(row, (m3_runtime_s=round(m3_rt; digits=1),
                                              runtime_speedup_vs_m3=m3_rt > 0.0 ? m3_rt / r.runtime_s : nan)))
            end

            # M2 errors
            for cfg in ra2_configs
                lbl = cfg.label
                m2_r = filter(r -> r.case_name == cname && r.model_label == lbl && !isnan(r.lolh_hours), ok_df)
                isempty(m2_r) && continue
                r    = m2_r[1, :]
                m2_m = (lolh=r.lolh_hours, eue=r.eue_mwh, cvar_eue=r.cvar_eue_mwh,
                        lole_days=r.lole_days, max_shortfall=r.max_shortfall_mw,
                        mean_shortfall_when_shedding=r.mean_shortfall_when_shedding_mw)

                mean_cov    = nan
                mean_nwin   = nan
                total_fails = 0
                if !isempty(diag_df_full)
                    dcs = filter(x -> x.case_name == cname && x.m2_label == lbl, diag_df_full)
                    if !isempty(dcs)
                        mean_cov    = mean(dcs.window_coverage)
                        mean_nwin   = mean(dcs.n_windows)
                        total_fails = sum(dcs.n_lp_failures)
                    end
                end

                row = make_error_row(cname, lbl, cfg.risk_margin_mw, cfg.window_buffer_hours,
                                     m3, m2_m, r.runtime_s, mean_cov, mean_nwin, total_fails)
                push!(error_rows, merge(row, (m3_runtime_s=round(m3_rt; digits=1),
                                              runtime_speedup_vs_m3=m3_rt > 0.0 ? m3_rt / r.runtime_s : nan)))
            end
        end
    end

    CSV.write(results_path, df)
    CSV.write(errors_path,  DataFrame(error_rows))
    isempty(diag_rows) || CSV.write(diags_path, DataFrame(diag_rows))

    # ── summary.txt ────────────────────────────────────────────────────────────
    open(summary_path, "w") do io
        sep  = "=" ^ 80
        sep2 = "-" ^ 76
        println(io, sep)
        println(io, "RA-2 N=$(n_scenarios) Selected-Parameter Validation Summary")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d\n", n_scenarios, seed)
        @printf(io, "Cases: %s\n", join(cases_to_run, ", "))
        configs_str = join(["$(c.label) (rm=$(Int(c.risk_margin_mw)) buf=$(c.window_buffer_hours))"
                            for c in ra2_configs], ", ")
        @printf(io, "RA-2 configs: %s\n", configs_str)
        println(io, sep)
        println(io)

        err_df = DataFrame(error_rows)

        # ── main results table ─────────────────────────────────────────────────
        all_labels = vcat(["M1b"], [c.label for c in ra2_configs], skip_m3 ? [] : ["M3"])
        println(io, "Aggregate reliability metrics")
        println(io, "-" ^ 100)
        @printf(io, "  %-22s %-5s %8s %7s %7s %10s %10s %10s %8s\n",
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
                eue_ci_pct  = isnan(r.eue_ci95_rel_halfwidth) ? "n/a" :
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

            # extended error table
            println(io, "Extended error metrics (M2 configs only)")
            println(io, "-" ^ 100)
            @printf(io, "  %-22s %-22s %9s %9s %9s %10s %10s %8s\n",
                    "Case", "Method", "CVaR_err", "LOLE_err", "MaxSF_err",
                    "cov%", "n_wins", "lp_fail")
            println(io, "  " * "-" ^ 94)
            for cname in cases_to_run
                sub = filter(r -> r.case_name == cname &&
                                  r.method_label != "M1b", err_df)
                isempty(sub) && continue
                for r in eachrow(sub)
                    cov_str = isnan(r.mean_window_coverage_fraction) ? "n/a" :
                              @sprintf("%.1f", 100.0 * r.mean_window_coverage_fraction)
                    nwin_str = isnan(r.mean_n_windows) ? "n/a" :
                               @sprintf("%.1f", r.mean_n_windows)
                    @printf(io, "  %-22s %-22s %+9.2f %+9.2f %+9.2f %10s %10s %8d\n",
                            cname, r.method_label,
                            r.cvar_eue_error, r.lole_days_error, r.max_shortfall_error,
                            cov_str, nwin_str, r.total_lp_failures)
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

        # ── Questions ─────────────────────────────────────────────────────────
        println(io, sep)
        println(io, "Research questions")
        println(io, sep)
        println(io)

        # Q1: EUE match
        println(io, "Q1. Does RA-2 still match M3 EUE at N=$(n_scenarios)?")
        println(io)
        if !isempty(err_df)
            m2_eue_errors = filter(r -> startswith(r.method_label, "M2"), err_df)
            if !isempty(m2_eue_errors)
                max_abs_eue = maximum(abs.(m2_eue_errors.eue_error))
                @printf(io, "  Max |M2 EUE - M3 EUE| across all configs/cases: %.6f MWh\n", max_abs_eue)
                if max_abs_eue < 1e-4
                    println(io, "  → YES. EUE is matched to machine precision for all RA-2 configurations.")
                    println(io, "    The LP power-balance equality constraint makes EUE invariant to parameter choice.")
                else
                    println(io, "  → EUE differences detected — see error table above.")
                end
            end
        end
        println(io)

        # Q2: LOLH improvement over M1b
        println(io, "Q2. Does RA-2 match M3 LOLH better than M1b?")
        println(io)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_df)
            isempty(sub) && continue
            m1b_row = filter(r -> r.method_label == "M1b", sub)
            isempty(m1b_row) && continue
            m1b_err = m1b_row[1, :lolh_abs_error]
            println(io, "  $cname:")
            @printf(io, "    M1b: LOLH=%5.2f h  err=%+.2f h (abs=%.2f h)\n",
                    m1b_row[1, :method_lolh], m1b_row[1, :lolh_error], m1b_err)
            for r in eachrow(filter(x -> startswith(x.method_label, "M2"), sub))
                improvement = m1b_err - r.lolh_abs_error
                dir = r.lolh_abs_error < m1b_err ? "↓ better" : "↑ worse"
                @printf(io, "    %-22s LOLH=%5.2f h  err=%+.2f h (abs=%.2f h)  %s by %.2f h\n",
                        r.method_label, r.method_lolh, r.lolh_error, r.lolh_abs_error,
                        dir, abs(improvement))
            end
            println(io)
        end

        # Q3: accuracy comparison between configs
        println(io, "Q3. Which setting is better for LOLH accuracy: rm=1000/buf=48 or rm=800/buf=24?")
        println(io)
        if length(ra2_configs) >= 2
            for cname in cases_to_run
                sub = filter(r -> r.case_name == cname && startswith(r.method_label, "M2"), err_df)
                isempty(sub) && continue
                best_idx = argmin(sub.lolh_abs_error)
                best     = sub[best_idx, :]
                @printf(io, "  %s:  best=%s (err=%+.2f h, abs=%.2f h)\n",
                        cname, best.method_label, best.lolh_error, best.lolh_abs_error)
                for r in eachrow(sub)
                    r.method_label == best.method_label && continue
                    @printf(io, "           vs %s   (err=%+.2f h, abs=%.2f h)  Δ=%.2f h\n",
                            r.method_label, r.lolh_error, r.lolh_abs_error,
                            r.lolh_abs_error - best.lolh_abs_error)
                end
            end
            # cross-case mean
            println(io)
            for cfg in ra2_configs
                lbl = cfg.label
                sub_all = filter(r -> r.method_label == lbl, err_df)
                isempty(sub_all) && continue
                mean_err = mean(sub_all.lolh_abs_error)
                mean_rt  = mean(sub_all.method_runtime_s)
                @printf(io, "  %s: mean abs LOLH error = %.3f h  mean rt = %.1f s\n",
                        lbl, mean_err, mean_rt)
            end
        end
        println(io)

        # Q4: runtime/coverage
        println(io, "Q4. Which setting is better for runtime and window coverage?")
        println(io)
        for cfg in ra2_configs
            lbl = cfg.label
            sub = filter(r -> r.method_label == lbl, err_df)
            isempty(sub) && continue
            mean_rt  = mean(sub.method_runtime_s)
            mean_spd = let spds = filter(!isnan, sub.runtime_speedup_vs_m3)
                isempty(spds) ? nan : mean(spds)
            end
            cov_vals  = filter(!isnan, sub.mean_window_coverage_fraction)
            mean_cov  = isempty(cov_vals) ? nan : mean(cov_vals)
            nwin_vals = filter(!isnan, sub.mean_n_windows)
            mean_nwin = isempty(nwin_vals) ? nan : mean(nwin_vals)
            @printf(io, "  %s:\n", lbl)
            @printf(io, "    Mean runtime: %.1f s  |  Mean speedup: %s  |  Mean coverage: %.1f%%  |  Mean windows: %.1f\n",
                    mean_rt,
                    isnan(mean_spd) ? "n/a" : @sprintf("%.1fx", mean_spd),
                    isnan(mean_cov) ? 0.0 : 100.0 * mean_cov,
                    isnan(mean_nwin) ? 0.0 : mean_nwin)
        end
        println(io)

        # Q5: wind-heavy vs balanced
        println(io, "Q5. Does wind-heavy remain harder than balanced VRE at N=$(n_scenarios)?")
        println(io)
        if !skip_m3
            for cname in ["VRE120_wind_hvy", "VRE120_bal15"]
                mrow = filter(r -> r.case_name == cname && r.model_label == "M3" && !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                @printf(io, "  %s (M3):  LOLH=%.2f h  CVaR-EUE=%.1f MWh  MaxSF=%.1f MW  p95_dur=%.2f h\n",
                        cname, r.lolh_hours, r.cvar_eue_mwh,
                        r.max_shortfall_mw, r.p95_shortage_duration_h)
            end
        end
        println(io)

        # Q6: CI widths at N=20
        println(io, "Q6. Are M3 confidence intervals still wide at N=$(n_scenarios)?")
        println(io)
        if !skip_m3
            max_lolh_ci = 0.0
            max_eue_ci  = 0.0
            for cname in cases_to_run
                mrow = filter(r -> r.case_name == cname && r.model_label == "M3" && !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                lci = isnan(r.lolh_ci95_rel_halfwidth) ? 0.0 : r.lolh_ci95_rel_halfwidth
                eci = isnan(r.eue_ci95_rel_halfwidth)  ? 0.0 : r.eue_ci95_rel_halfwidth
                max_lolh_ci = max(max_lolh_ci, lci)
                max_eue_ci  = max(max_eue_ci,  eci)
                lolh_pct = @sprintf("%.1f%%", 100.0 * lci)
                eue_pct  = @sprintf("%.1f%%", 100.0 * eci)
                @printf(io, "  %s (M3):  LOLH CI95 rel = %s  |  EUE CI95 rel = %s\n",
                        cname, lolh_pct, eue_pct)
            end
            println(io)
            if max_lolh_ci > 0.4
                @printf(io, "  Max M3 LOLH CI95 rel = %.1f%%  → CIs are still wide at N=%d.\n",
                        100.0 * max_lolh_ci, n_scenarios)
                println(io, "  Near-zero LOLH cases are particularly noisy; N=20 benchmarks")
                println(io, "  should be treated as provisional.")
            else
                @printf(io, "  Max M3 LOLH CI95 rel = %.1f%%  → CIs are acceptable at N=%d.\n",
                        100.0 * max_lolh_ci, n_scenarios)
            end
        end
        println(io)

        # Q7: recommended parameter setting
        println(io, "Q7. Which RA-2 parameter setting should be used as the main paper result?")
        println(io)
        if !isempty(err_df) && length(ra2_configs) >= 1
            combo_scores = NamedTuple[]
            for cfg in ra2_configs
                lbl  = cfg.label
                sub  = filter(r -> r.method_label == lbl, err_df)
                isempty(sub) && continue
                mean_abs  = mean(sub.lolh_abs_error)
                mean_rt   = mean(sub.method_runtime_s)
                spds      = filter(!isnan, sub.runtime_speedup_vs_m3)
                mean_spd  = isempty(spds) ? nan : mean(spds)
                push!(combo_scores, (label=lbl, rm=cfg.risk_margin_mw, buf=cfg.window_buffer_hours,
                                     mean_lolh_abs_err=mean_abs, mean_rt=mean_rt, mean_spd=mean_spd))
            end
            sc_df = DataFrame(combo_scores)
            ord   = sortperm(sc_df.mean_lolh_abs_err)
            best  = sc_df[ord[1], :]
            @printf(io, "  Recommendation: %s (rm=%.0f, buf=%d)\n",
                    best.label, best.rm, Int(best.buf))
            @printf(io, "  Mean LOLH abs error: %.3f h  |  Mean runtime: %.1f s  |  Mean speedup: %s\n",
                    best.mean_lolh_abs_err, best.mean_rt,
                    isnan(best.mean_spd) ? "n/a" : @sprintf("%.1fx", best.mean_spd))
            println(io)
            if size(sc_df, 1) > 1
                runner = sc_df[ord[2], :]
                @printf(io, "  Runner-up:  %s  mean err=%.3f h  mean rt=%.1f s\n",
                        runner.label, runner.mean_lolh_abs_err, runner.mean_rt)
                delta = best.mean_lolh_abs_err - runner.mean_lolh_abs_err
                if abs(delta) < 0.2
                    println(io, "  Note: The two configs are close in accuracy (<0.2 h difference).")
                    println(io, "  If runtime is a concern, the lower-coverage config may be preferred.")
                end
            end
        end
        println(io)

        # Q8: should we run N=50?
        println(io, "Q8. Should we run N=50 for a final selected case?")
        println(io)
        if !skip_m3
            max_ci = 0.0
            worst_case = ""
            for cname in cases_to_run
                mrow = filter(r -> r.case_name == cname && r.model_label == "M3" && !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                ci = mrow[1, :lolh_ci95_rel_halfwidth]
                isnan(ci) && continue
                if ci > max_ci
                    max_ci     = ci
                    worst_case = cname
                end
            end
            if max_ci > 0.40
                @printf(io, "  YES — largest M3 LOLH CI95 rel = %.1f%% (%s).\n",
                        100.0 * max_ci, worst_case)
                println(io, "  N=20 benchmarks for near-zero LOLH cases are not stable.")
                println(io, "  Recommended: run N=50 on VRE120_base (highest M3 LOLH, lowest noise)")
                println(io, "  for a definitive method-comparison result.")
            elseif max_ci > 0.20
                @printf(io, "  MAYBE — largest M3 LOLH CI95 rel = %.1f%% (%s).\n",
                        100.0 * max_ci, worst_case)
                println(io, "  N=20 may be marginally acceptable. N=50 would give more stable results.")
            else
                @printf(io, "  N=%d appears sufficient — max M3 LOLH CI95 rel = %.1f%%.\n",
                        n_scenarios, 100.0 * max_ci)
            end
        end
        println(io)

        @printf(io, "Total runtime: %.1f s\n", total_rt)
        println(io, sep)
        println(io, "Files: ra2_n20_selected_params_results.csv")
        println(io, "       ra2_n20_selected_params_errors.csv")
        println(io, "       ra2_n20_selected_params_window_diags.csv")
    end

    # ── console output ─────────────────────────────────────────────────────────
    sep = "=" ^ 84
    println()
    println(sep)
    @printf("RA-2 N=%d Selected-Param Validation  |  seed=%d  |  subdir=%s\n",
            n_scenarios, seed, subdir)
    @printf("Cases: %s\n", join(cases_to_run, ", "))
    println(sep)

    all_labels = vcat(["M1b"], [c.label for c in ra2_configs], skip_m3 ? [] : ["M3"])
    @printf("  %-20s %-22s %8s %7s %7s %10s %10s %10s %8s\n",
            "Case", "Model", "LOLH(h)", "LOLP%", "LOLE_d",
            "EUE(MWh)", "CVaR-EUE", "MaxSF(MW)", "rt(s)")
    println("  " * "-" ^ 90)
    for lbl in all_labels
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
                        cname, r.method_label, r.m3_lolh, r.method_lolh, r.lolh_error, spd_str)
            end
        end
    end

    @printf("\nTotal runtime: %.1f s\n", total_rt)
    @printf("Output: %s\n", abspath(out_dir))
    @printf("Summary: %s\n", abspath(summary_path))
    println()
end
