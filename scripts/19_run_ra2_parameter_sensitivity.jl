#!/usr/bin/env julia
# 19_run_ra2_parameter_sensitivity.jl
#
# RA-2 risk-window parameter sensitivity study.
# Tests combinations of risk_margin_mw and window_buffer_hours to identify
# parameter settings that minimise the M2–M3 LOLH gap while preserving the
# runtime advantage over M3.
#
# M3 is run ONCE per case/scenario set; all M2 comparisons reuse those metrics.
#
# Parameter grid:
#   risk_margin_mw    ∈ {300, 500, 800, 1000}   (flag hours: thermal+VRE-load < margin)
#   window_buffer_hours ∈ {24, 48}               (hours added each side of a risk hour)
#   min_window_length_hours = 24  (fixed)
#   merge_gap_hours         = 24  (fixed)
#
# Outputs (results/ra2_parameter_sensitivity/<subdir>/):
#   ra2_parameter_sensitivity_results.csv
#   ra2_parameter_sensitivity_errors.csv
#   ra2_parameter_sensitivity_window_diags.csv
#   summary.txt
#   run_<timestamp>.log
#
# Usage:
#   julia --project=. scripts/19_run_ra2_parameter_sensitivity.jl [options]
#
# Options:
#   --n-scenarios N     Number of MC scenarios (default: 5)
#   --seed S            RNG seed               (default: 42)
#   --cases C1,C2,...   Comma-separated VRE120 cases
#   --out-subdir DIR    Subdirectory under results/ra2_parameter_sensitivity/
#   --skip-m3           Omit M3 benchmark (fast testing mode)

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

const RISK_MARGINS    = [300.0, 500.0, 800.0, 1000.0]   # MW
const BUFFERS         = [24, 48]                          # hours
const FIXED_MIN_LEN   = 24                                # hours
const FIXED_MERGE_GAP = 24                                # hours

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
    base_out_dir = joinpath(project_root, "results", "ra2_parameter_sensitivity")
    subdir       = get(kw, "out-subdir", "risk_buffer_n$(n_scenarios)")
    out_dir      = joinpath(base_out_dir, subdir)
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "RA-2 parameter sensitivity | n=$n_scenarios | seed=$seed | skip_m3=$skip_m3"
    @info "Cases: $(join(cases_to_run, ", "))"
    @info "Grid: risk_margin_mw=$(RISK_MARGINS)  window_buffer_hours=$(BUFFERS)"
    @info "Fixed: min_window_length=$(FIXED_MIN_LEN) h  merge_gap=$(FIXED_MERGE_GAP) h"
    @info "Output: $out_dir"

    results_path = joinpath(out_dir, "ra2_parameter_sensitivity_results.csv")
    errors_path  = joinpath(out_dir, "ra2_parameter_sensitivity_errors.csv")
    diags_path   = joinpath(out_dir, "ra2_parameter_sensitivity_window_diags.csv")
    summary_path = joinpath(out_dir, "summary.txt")

    results_rows = NamedTuple[]
    diag_rows    = NamedTuple[]

    # M3 metrics/runtime cached by case_name — populated on first M3 run
    m3_metrics_by_case = Dict{String, Any}()
    m3_runtime_by_case = Dict{String, Float64}()

    nan = NaN

    function make_results_row(cname, model, rm, buf, metrics, rt)
        m = metrics
        (
            case_name                       = cname,
            model                           = model,
            risk_margin_mw                  = Float64(rm),
            window_buffer_hours             = Float64(buf),
            n_scenarios                     = n_scenarios,
            seed                            = seed,
            lolh_hours                      = isnothing(m) ? nan : m.lolh,
            lolp_percent                    = isnothing(m) ? nan : 100.0 * m.lolp,
            lole_days                       = isnothing(m) ? nan : m.lole_days,
            eue_mwh                         = isnothing(m) ? nan : m.eue,
            cvar_eue_mwh                    = isnothing(m) ? nan : m.cvar_eue,
            max_shortfall_mw                = isnothing(m) ? nan : m.max_shortfall,
            mean_shortfall_when_shedding_mw = isnothing(m) ? nan : m.mean_shortfall_when_shedding,
            p95_shortage_duration_h         = isnothing(m) ? nan : m.p95_shortage_duration,
            eue_ci95_rel_halfwidth          = isnothing(m) ? nan : m.eue_ci95_rel_halfwidth,
            runtime_s                       = round(rt; digits=1),
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
        sys = load_system_data(cdir)

        crn_cfg   = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)

        # ── M3 benchmark (once per case) ──────────────────────────────────────
        if !skip_m3
            try
                m3_cfg = SimConfig(; n_scenarios, seed)
                @info "  running M3 (RA-3, full-year ED LP)..."
                t0   = time()
                r_m3 = run_m3_ed_dispatch(sys, scenarios, m3_cfg)
                rt   = time() - t0
                m_m3 = compute_metrics(r_m3, sys, m3_cfg)
                m3_metrics_by_case[cname] = m_m3
                m3_runtime_by_case[cname] = rt
                push!(results_rows, make_results_row(cname, "M3", nan, nan, m_m3, rt))
                @info "  M3:  LOLH=$(round(m_m3.lolh, digits=2)) h  EUE=$(round(m_m3.eue, digits=1)) MWh  ($(round(rt, digits=1)) s)"
            catch e
                @error "M3 failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_results_row(cname, "M3", nan, nan, nothing, 0.0))
            end
        end

        # ── M2 parameter grid ────────────────────────────────────────────────
        for rm in RISK_MARGINS, buf in BUFFERS
            param_tag = "rm$(Int(rm))_buf$(buf)"
            try
                m2_cfg = SimConfig(;
                    n_scenarios,
                    seed,
                    reserve_fraction        = 0.50,
                    risk_margin_mw          = rm,
                    window_buffer_hours     = buf,
                    min_window_length_hours = FIXED_MIN_LEN,
                    merge_gap_hours         = FIXED_MERGE_GAP,
                )
                @info "  running M2 [$param_tag]..."
                t0          = time()
                r_m2, diags = run_m2_with_diagnostics(sys, scenarios, m2_cfg)
                rt          = time() - t0
                m_m2        = compute_metrics(r_m2, sys, m2_cfg)
                push!(results_rows, make_results_row(cname, "M2", rm, buf, m_m2, rt))

                n_lp_fail   = sum(d.n_lp_failures  for d in diags)
                mean_wins   = mean(d.n_windows      for d in diags)
                mean_cov    = mean(d.total_window_h for d in diags) / sys.n_hours
                @info "  M2[$param_tag]: LOLH=$(round(m_m2.lolh, digits=2)) h  cov=$(round(100*mean_cov, digits=1))%  wins=$(round(mean_wins, digits=1))  LP_fails=$n_lp_fail  ($(round(rt, digits=1)) s)"

                for d in diags
                    push!(diag_rows, (
                        case_name           = cname,
                        risk_margin_mw      = Float64(rm),
                        window_buffer_hours = Float64(buf),
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
                @error "M2[$param_tag] failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_results_row(cname, "M2", rm, buf, nothing, 0.0))
            end
        end

        # flush intermediate CSVs after each case
        CSV.write(results_path, DataFrame(results_rows))
        isempty(diag_rows) || CSV.write(diags_path, DataFrame(diag_rows))
        @info "  Intermediate outputs saved → $out_dir"
    end

    total_rt = time() - total_t0
    @info "Total runtime: $(round(total_rt, digits=1)) s"

    df    = DataFrame(results_rows)
    ok_df = filter(r -> !isnan(r.lolh_hours), df)

    # ── error comparison table ─────────────────────────────────────────────────
    error_rows = NamedTuple[]
    if !skip_m3
        diag_df_full = isempty(diag_rows) ? DataFrame() : DataFrame(diag_rows)

        for cname in cases_to_run
            haskey(m3_metrics_by_case, cname) || continue
            m3    = m3_metrics_by_case[cname]
            m3_rt = get(m3_runtime_by_case, cname, 0.0)

            m2_ok = filter(r -> r.case_name == cname && r.model == "M2" && !isnan(r.lolh_hours), ok_df)
            isempty(m2_ok) && continue

            for r in eachrow(m2_ok)
                rm  = r.risk_margin_mw
                buf = r.window_buffer_hours

                mean_cov    = nan
                mean_nwin   = nan
                total_fails = 0
                if !isempty(diag_df_full)
                    dcs = filter(x -> x.case_name == cname &&
                                      x.risk_margin_mw == rm &&
                                      x.window_buffer_hours == buf,
                                 diag_df_full)
                    if !isempty(dcs)
                        mean_cov    = mean(dcs.window_coverage)
                        mean_nwin   = mean(dcs.n_windows)
                        total_fails = sum(dcs.n_lp_failures)
                    end
                end

                push!(error_rows, (
                    case_name                     = cname,
                    risk_margin_mw                = rm,
                    window_buffer_hours           = buf,
                    m2_lolh                       = r.lolh_hours,
                    m3_lolh                       = m3.lolh,
                    lolh_error                    = r.lolh_hours - m3.lolh,
                    lolh_abs_error                = abs(r.lolh_hours - m3.lolh),
                    m2_eue                        = r.eue_mwh,
                    m3_eue                        = m3.eue,
                    eue_error                     = r.eue_mwh - m3.eue,
                    m2_cvar_eue                   = r.cvar_eue_mwh,
                    m3_cvar_eue                   = m3.cvar_eue,
                    cvar_eue_error                = r.cvar_eue_mwh - m3.cvar_eue,
                    m2_max_shortfall              = r.max_shortfall_mw,
                    m3_max_shortfall              = m3.max_shortfall,
                    max_shortfall_error           = r.max_shortfall_mw - m3.max_shortfall,
                    m2_runtime_s                  = r.runtime_s,
                    m3_runtime_s                  = round(m3_rt; digits=1),
                    runtime_speedup_vs_m3         = m3_rt > 0.0 ? m3_rt / r.runtime_s : nan,
                    mean_window_coverage_fraction = mean_cov,
                    mean_n_windows                = mean_nwin,
                    total_lp_failures             = total_fails,
                ))
            end
        end
    end

    CSV.write(results_path, df)
    CSV.write(errors_path,  DataFrame(error_rows))
    isempty(diag_rows) || CSV.write(diags_path, DataFrame(diag_rows))

    # ── summary.txt ────────────────────────────────────────────────────────────
    open(summary_path, "w") do io
        sep = "=" ^ 80
        println(io, sep)
        println(io, "RA-2 Parameter Sensitivity Summary")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d\n", n_scenarios, seed)
        @printf(io, "Cases: %s\n", join(cases_to_run, ", "))
        @printf(io, "Grid: risk_margin_mw=%s  window_buffer_hours=%s\n",
                string(RISK_MARGINS), string(BUFFERS))
        @printf(io, "Fixed: min_window_length=%d h  merge_gap=%d h\n",
                FIXED_MIN_LEN, FIXED_MERGE_GAP)
        println(io, sep)
        println(io)

        err_df = DataFrame(error_rows)

        # ── full M2 vs M3 table ────────────────────────────────────────────────
        println(io, "Full M2 results vs M3 benchmark")
        println(io, "-" ^ 90)
        @printf(io, "  %-16s %8s %4s %8s %8s %9s %10s %10s\n",
                "Case", "risk_mw", "buf", "M2_LOLH", "M3_LOLH", "LOLH_err", "M2_EUE", "M3_EUE")
        println(io, "  " * "-" ^ 84)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_df)
            isempty(sub) && continue
            for r in eachrow(sub)
                @printf(io, "  %-16s %8g %4d %8.2f %8.2f %+9.2f %10.1f %10.1f\n",
                        cname, r.risk_margin_mw, Int(r.window_buffer_hours),
                        r.m2_lolh, r.m3_lolh, r.lolh_error,
                        r.m2_eue, r.m3_eue)
            end
        end
        println(io)

        # ── Q1: best LOLH match per case ──────────────────────────────────────
        println(io, "Q1. Which parameter combination minimizes LOLH absolute error vs M3?")
        println(io)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_df)
            isempty(sub) && continue
            best_idx = argmin(sub.lolh_abs_error)
            best     = sub[best_idx, :]
            rel_pct  = best.m3_lolh > 0.0 ? 100.0 * best.lolh_error / best.m3_lolh : nan
            @printf(io, "  %s:\n", cname)
            @printf(io, "    Best: risk_margin=%g MW  buffer=%d h  M2=%.2f h  M3=%.2f h  err=%+.2f h (%+.1f%%)\n",
                    best.risk_margin_mw, Int(best.window_buffer_hours),
                    best.m2_lolh, best.m3_lolh, best.lolh_error, rel_pct)
            # also show default (rm=500, buf=24) for comparison
            ref = filter(r -> r.risk_margin_mw == 500.0 && r.window_buffer_hours == 24.0, sub)
            if !isempty(ref)
                ref_pct = ref[1, :m3_lolh] > 0.0 ?
                          100.0 * ref[1, :lolh_error] / ref[1, :m3_lolh] : nan
                @printf(io, "    Default (rm=500, buf=24): err=%+.2f h (%+.1f%%)  improvement=%.2f h\n",
                        ref[1, :lolh_error], ref_pct,
                        ref[1, :lolh_abs_error] - best.lolh_abs_error)
            end
            println(io)
        end

        # ── Q2: EUE accuracy ──────────────────────────────────────────────────
        println(io, "Q2. Which combination preserves EUE accuracy?")
        println(io)
        if !isempty(err_df)
            eue_abs_errs = abs.(err_df.eue_error)
            max_abs = maximum(eue_abs_errs)
            @printf(io, "  Max absolute EUE error across all combos/cases: %.6f MWh\n", max_abs)
            if max_abs < 1e-6
                println(io, "  → EUE is matched to machine precision for ALL parameter combinations.")
                println(io, "    (RA-2 window LP enforces exact power-balance equality, so EUE is invariant")
                println(io, "     to risk_margin_mw and window_buffer_hours.)")
            else
                for cname in cases_to_run
                    sub = filter(r -> r.case_name == cname, err_df)
                    isempty(sub) && continue
                    min_eue_err_idx = argmin(abs.(sub.eue_error))
                    best = sub[min_eue_err_idx, :]
                    rel_pct = best.m3_eue > 0.0 ? 100.0 * best.eue_error / best.m3_eue : nan
                    @printf(io, "  %s: best EUE: rm=%g buf=%d  err=%+.4f MWh (%+.6f%%)\n",
                            cname, best.risk_margin_mw, Int(best.window_buffer_hours),
                            best.eue_error, rel_pct)
                end
            end
        end
        println(io)

        # ── Q3: window coverage ───────────────────────────────────────────────
        println(io, "Q3. How does window coverage change with risk_margin_mw and buffer?")
        println(io)
        @printf(io, "  %-16s %8s %4s  %9s  %9s  %8s\n",
                "Case", "risk_mw", "buf", "cov%", "mean_wins", "lp_fails")
        println(io, "  " * "-" ^ 64)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_df)
            isempty(sub) && continue
            for r in eachrow(sub)
                isnan(r.mean_window_coverage_fraction) && continue
                @printf(io, "  %-16s %8g %4d  %9.1f  %9.1f  %8d\n",
                        cname, r.risk_margin_mw, Int(r.window_buffer_hours),
                        100.0 * r.mean_window_coverage_fraction,
                        r.mean_n_windows, r.total_lp_failures)
            end
        end
        println(io)

        # ── Q4: runtime/accuracy tradeoff ─────────────────────────────────────
        println(io, "Q4. Runtime / accuracy tradeoff:")
        println(io)
        @printf(io, "  %-16s %8s %4s  %8s  %13s  %10s  %8s\n",
                "Case", "risk_mw", "buf", "M2_rt(s)", "speedup_vs_M3", "LOLH_err_h", "LOLH_err%")
        println(io, "  " * "-" ^ 76)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_df)
            isempty(sub) && continue
            for r in eachrow(sub)
                rel_pct    = r.m3_lolh > 0.0 ? 100.0 * r.lolh_error / r.m3_lolh : nan
                spd_str    = isnan(r.runtime_speedup_vs_m3) ? "n/a" :
                             @sprintf("%.1fx", r.runtime_speedup_vs_m3)
                @printf(io, "  %-16s %8g %4d  %8.1f  %13s  %+10.2f  %7.1f%%\n",
                        cname, r.risk_margin_mw, Int(r.window_buffer_hours),
                        r.m2_runtime_s, spd_str, r.lolh_error, rel_pct)
            end
        end
        println(io)

        # ── Q5: does rm=800 fix the M3-only missed-hour problem? ──────────────
        println(io, "Q5. Does risk_margin_mw=800 improve the M3-only missed-hour problem?")
        println(io, "    (Comparing LOLH absolute error at rm=500,buf=24 vs rm=800,buf=24)")
        println(io)
        found_any = false
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_df)
            isempty(sub) && continue
            r500 = filter(r -> r.risk_margin_mw == 500.0 && r.window_buffer_hours == 24.0, sub)
            r800 = filter(r -> r.risk_margin_mw == 800.0 && r.window_buffer_hours == 24.0, sub)
            (isempty(r500) || isempty(r800)) && continue
            found_any = true
            err500 = r500[1, :lolh_abs_error]
            err800 = r800[1, :lolh_abs_error]
            chg    = err500 - err800        # positive = improvement
            direction = chg > 0 ? "↓ improved" : (chg < 0 ? "↑ worsened" : "unchanged")
            @printf(io, "  %s:\n", cname)
            @printf(io, "    rm=500: err=%+.2f h (abs=%.2f h)  rm=800: err=%+.2f h (abs=%.2f h)  %s by %.2f h\n",
                    r500[1, :lolh_error], err500,
                    r800[1, :lolh_error], err800,
                    direction, abs(chg))
        end
        found_any || println(io, "  (data not available — check skip-m3 flag)")
        println(io)

        # ── Q6: recommended defaults ──────────────────────────────────────────
        println(io, "Q6. Recommended default RA-2 parameters for the next N=20 validation:")
        println(io)
        if !isempty(err_df)
            # score each (rm, buf) combo by mean LOLH absolute error across all cases
            combos    = unique(select(err_df, :risk_margin_mw, :window_buffer_hours))
            scores    = NamedTuple[]
            for crow in eachrow(combos)
                rm  = crow.risk_margin_mw
                buf = crow.window_buffer_hours
                sub = filter(r -> r.risk_margin_mw == rm && r.window_buffer_hours == buf, err_df)
                isempty(sub) && continue
                mean_abs   = mean(sub.lolh_abs_error)
                mean_rt    = mean(sub.m2_runtime_s)
                spds       = filter(!isnan, sub.runtime_speedup_vs_m3)
                mean_spd   = isempty(spds) ? nan : mean(spds)
                mean_cov   = mean(filter(!isnan, sub.mean_window_coverage_fraction))
                push!(scores, (
                    risk_margin_mw      = rm,
                    window_buffer_hours = buf,
                    mean_lolh_abs_err_h = mean_abs,
                    mean_rt_s           = mean_rt,
                    mean_speedup        = mean_spd,
                    mean_cov_pct        = 100.0 * mean_cov,
                ))
            end
            sc_df  = DataFrame(scores)
            order  = sortperm(sc_df.mean_lolh_abs_err_h)
            println(io, "  Ranking by mean LOLH absolute error across all cases (lower = better):")
            println(io)
            @printf(io, "  %4s  %8s  %4s  %10s  %10s  %12s  %8s\n",
                    "Rank", "risk_mw", "buf", "mean_err_h", "mean_rt(s)", "mean_speedup", "cov%")
            println(io, "  " * "-" ^ 64)
            for (rank, idx) in enumerate(order)
                r   = sc_df[idx, :]
                spd = isnan(r.mean_speedup) ? "n/a" : @sprintf("%.1fx", r.mean_speedup)
                @printf(io, "  %4d  %8g  %4d  %10.3f  %10.1f  %12s  %7.1f\n",
                        rank, r.risk_margin_mw, Int(r.window_buffer_hours),
                        r.mean_lolh_abs_err_h, r.mean_rt_s, spd, r.mean_cov_pct)
            end
            println(io)
            best = sc_df[order[1], :]
            best_spd = isnan(best.mean_speedup) ? "n/a" : @sprintf("%.1fx", best.mean_speedup)
            @printf(io, "  Recommended: risk_margin_mw=%.0f  window_buffer_hours=%d\n",
                    best.risk_margin_mw, Int(best.window_buffer_hours))
            @printf(io, "  Mean LOLH abs error: %.3f h  |  Mean runtime: %.1f s  |  Mean speedup vs M3: %s\n",
                    best.mean_lolh_abs_err_h, best.mean_rt_s, best_spd)
            @printf(io, "  Mean window coverage: %.1f%%\n", best.mean_cov_pct)
            println(io)
            println(io, "  Caveats:")
            println(io, "  - N=5 results have wide confidence intervals (~47–63% above N=20 values).")
            println(io, "  - EUE is invariant to parameter choice; LOLH ranking may shift at N=20.")
            println(io, "  - Runtime advantage may decrease as coverage grows with larger margins.")
            println(io, "  - Validate recommended parameters at N=20 before adopting as default.")
        end
        println(io)

        @printf(io, "Total runtime: %.1f s\n", total_rt)
        println(io, sep)
        println(io, "Files: ra2_parameter_sensitivity_results.csv")
        println(io, "       ra2_parameter_sensitivity_errors.csv")
        println(io, "       ra2_parameter_sensitivity_window_diags.csv")
    end

    # ── console output ─────────────────────────────────────────────────────────
    sep = "=" ^ 84
    println()
    println(sep)
    @printf("RA-2 Parameter Sensitivity  |  n=%d  |  seed=%d  |  subdir=%s\n",
            n_scenarios, seed, subdir)
    @printf("Cases: %s\n", join(cases_to_run, ", "))
    println(sep)

    err_df_con = DataFrame(error_rows)
    if !isempty(err_df_con)
        @printf("  %-16s %8s %4s  %8s  %8s  %9s  %9s  %10s\n",
                "Case", "risk_mw", "buf", "M2_LOLH", "M3_LOLH", "err_h", "cov%", "speedup")
        println("  " * "-" ^ 80)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_df_con)
            isempty(sub) && continue
            for r in eachrow(sub)
                cov_str = isnan(r.mean_window_coverage_fraction) ? "     n/a" :
                          @sprintf("%8.1f", 100.0 * r.mean_window_coverage_fraction)
                spd_str = isnan(r.runtime_speedup_vs_m3) ? "     n/a" :
                          @sprintf("%8.1fx", r.runtime_speedup_vs_m3)
                @printf("  %-16s %8g %4d  %8.2f  %8.2f  %+9.2f  %9s  %10s\n",
                        cname, r.risk_margin_mw, Int(r.window_buffer_hours),
                        r.m2_lolh, r.m3_lolh, r.lolh_error, cov_str, spd_str)
            end
        end
        println()

        # per-case best
        println("Best parameter per case (min LOLH absolute error):")
        println("-" ^ 70)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, err_df_con)
            isempty(sub) && continue
            best = sub[argmin(sub.lolh_abs_error), :]
            rel_pct = best.m3_lolh > 0.0 ? 100.0 * best.lolh_error / best.m3_lolh : nan
            @printf("  %-16s  rm=%4g  buf=%2d  err=%+.2f h (%+.1f%%)\n",
                    cname, best.risk_margin_mw, Int(best.window_buffer_hours),
                    best.lolh_error, rel_pct)
        end

        # overall ranking
        if !isempty(err_df_con)
            combos  = unique(select(err_df_con, :risk_margin_mw, :window_buffer_hours))
            scores2 = NamedTuple[]
            for crow in eachrow(combos)
                sub = filter(r -> r.risk_margin_mw == crow.risk_margin_mw &&
                                  r.window_buffer_hours == crow.window_buffer_hours, err_df_con)
                isempty(sub) && continue
                push!(scores2, (
                    risk_margin_mw      = crow.risk_margin_mw,
                    window_buffer_hours = crow.window_buffer_hours,
                    mean_lolh_abs_err_h = mean(sub.lolh_abs_error),
                    mean_rt_s           = mean(sub.m2_runtime_s),
                ))
            end
            sc2   = DataFrame(scores2)
            ord2  = sortperm(sc2.mean_lolh_abs_err_h)
            best2 = sc2[ord2[1], :]
            println()
            println("Overall ranking (mean LOLH abs error across all cases):")
            println("-" ^ 56)
            @printf("  %4s  %8s  %4s  %10s  %10s\n",
                    "Rank", "risk_mw", "buf", "mean_err_h", "mean_rt(s)")
            println("  " * "-" ^ 48)
            for (rank, idx) in enumerate(ord2)
                r = sc2[idx, :]
                @printf("  %4d  %8g  %4d  %10.3f  %10.1f\n",
                        rank, r.risk_margin_mw, Int(r.window_buffer_hours),
                        r.mean_lolh_abs_err_h, r.mean_rt_s)
            end
            println()
            @printf("Recommended: risk_margin_mw=%.0f  window_buffer_hours=%d  (mean err=%.3f h  mean rt=%.1f s)\n",
                    best2.risk_margin_mw, Int(best2.window_buffer_hours),
                    best2.mean_lolh_abs_err_h, best2.mean_rt_s)
        end
    end

    println()
    @printf("Total runtime: %.1f s\n", total_rt)
    @printf("Output: %s\n", abspath(out_dir))
    @printf("Summary: %s\n", abspath(summary_path))
    println()
end
