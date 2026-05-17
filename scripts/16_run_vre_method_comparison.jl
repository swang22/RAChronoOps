#!/usr/bin/env julia
# 16_run_vre_method_comparison.jl
#
# Run RA-1a (M1), RA-1b (M1b), and RA-3 (M3) across the six VRE120 cases to
# examine how method accuracy varies with VRE penetration and profile shape.
#
# Research questions answered in summary.txt:
#   Q1. Does RA-1b improve over RA-1a across VRE cases?
#   Q2. Does RA-1b remain biased high relative to RA-3?
#   Q3. Does method error increase with VRE penetration?
#   Q4. Are solar-heavy and wind-heavy cases different?
#   Q5. Which VRE cases should be prioritised for RA-2?
#
# Outputs (written under results/vre_method_comparison/):
#   vre_method_comparison_results.csv  — per-model, per-case aggregate metrics
#   vre_method_comparison_errors.csv   — M1/M1b vs M3 error analysis
#   summary.txt                        — human-readable findings
#   run_<timestamp>.log                — full run log
#
# Intermediate results are flushed after every model × case to allow partial
# recovery if a later run fails.
#
# Usage:
#   julia --project=. scripts/16_run_vre_method_comparison.jl [options]
#
# Options:
#   --n-scenarios N        Number of MC scenarios (default: 5)
#   --seed S               RNG seed                (default: 42)
#   --skip-m3              Omit RA-3 (fast mode; useful for quick sanity check)
#   --cases C1,C2,...      Comma-separated subset of VRE120 cases to run
#                          (default: all six VRE120 cases)
#   --out-subdir DIR       Subdirectory name under results/vre_method_comparison/
#                          (auto-derived from --cases if omitted)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

const VRE120_CASES = [
    "VRE120_base",
    "VRE120_bal15",
    "VRE120_bal20",
    "VRE120_bal30",
    "VRE120_solar_hvy",
    "VRE120_wind_hvy",
]

# ── argument parsing ──────────────────────────────────────────────────────────
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

# ── derive a short output subdirectory name from the case list ────────────────
function auto_subdir(cases::Vector{String}, n_scenarios::Int)
    if cases == VRE120_CASES
        return "all_n$(n_scenarios)"
    end
    # build abbreviation: strip "VRE120_" prefix and join with "-"
    abbr = join([replace(c, "VRE120_" => "") for c in cases], "-")
    return "$(abbr)_n$(n_scenarios)"
end

# ── Priority-1 emergency discharge counter ────────────────────────────────────
function count_p1_fires(sys      ::SystemData,
                         scenarios::ScenarioSet,
                         results  ::Vector{DispatchResult})
    therm     = thermal_generators(sys)
    n_therm   = nrow(therm)
    n_hours   = sys.n_hours
    pmax      = Float64.(therm.pmax_mw)
    wind_cap  = wind_capacity_mw(sys)
    solar_cap = solar_capacity_mw(sys)
    avail     = scenarios.availability

    p1_scenarios   = 0
    total_p1_hours = 0

    for (s, r) in enumerate(results)
        fired_this_scen = false
        for h in 1:n_hours
            therm_avail = 0.0
            for g in 1:n_therm
                therm_avail += pmax[g] * avail[s, g, h]
            end
            p_vre_h       = wind_cap * sys.wind_cf[h] + solar_cap * sys.solar_cf[h]
            shortfall_pre = max(0.0, sys.load_mw[h] - therm_avail - p_vre_h)
            if shortfall_pre > 1e-6 && r.storage_discharge[h] > 1e-6
                total_p1_hours += 1
                fired_this_scen = true
            end
        end
        fired_this_scen && (p1_scenarios += 1)
    end

    return p1_scenarios, total_p1_hours
end

# ── main ──────────────────────────────────────────────────────────────────────
let
    kw = parse_cli(ARGS)

    n_scenarios = parse(Int, get(kw, "n-scenarios", "5"))
    seed        = parse(Int, get(kw, "seed",         "42"))
    skip_m3     = get(kw, "skip-m3", "false") == "true"

    # ── resolve case list ─────────────────────────────────────────────────────
    cases_to_run = if haskey(kw, "cases")
        requested = split(kw["cases"], ",")
        for c in requested
            c in VRE120_CASES || error("Unknown case: $c (valid: $(join(VRE120_CASES, ", ")))")
        end
        String.(requested)
    else
        VRE120_CASES
    end

    project_root  = joinpath(@__DIR__, "..")
    cases_root    = joinpath(project_root, "data_processed", "cases")
    base_out_dir  = joinpath(project_root, "results", "vre_method_comparison")

    # ── resolve output subdirectory ───────────────────────────────────────────
    subdir  = get(kw, "out-subdir", auto_subdir(cases_to_run, n_scenarios))
    out_dir = joinpath(base_out_dir, subdir)
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "VRE method comparison | n_scenarios=$n_scenarios | seed=$seed | skip_m3=$skip_m3"
    @info "Cases: $(join(cases_to_run, ", "))"
    @info "Output: $out_dir"

    # ── load VRE case summary for penetration metadata ────────────────────────
    # Always read from the base output dir where script 15 writes it
    summary_csv = joinpath(base_out_dir, "vre_case_summary.csv")
    isfile(summary_csv) ||
        error("VRE case summary not found: $summary_csv\n" *
              "Run scripts/15_summarize_vre_cases.jl first.")
    vre_meta = CSV.read(summary_csv, DataFrame)

    # ── paths for intermediate + final output ─────────────────────────────────
    results_path = joinpath(out_dir, "vre_method_comparison_results.csv")
    errors_path  = joinpath(out_dir, "vre_method_comparison_errors.csv")
    summary_path = joinpath(out_dir, "summary.txt")

    results_rows = NamedTuple[]
    run_errors   = NamedTuple[]   # cases/models that threw exceptions

    model_labels = skip_m3 ? ["M1", "M1b"] : ["M1", "M1b", "M3"]

    total_t0 = time()

    for cname in cases_to_run
        cdir = joinpath(cases_root, cname)
        if !isdir(cdir)
            @warn "Case directory not found — skipping: $cdir"
            push!(run_errors, (case_name=cname, model="ALL",
                               error="directory not found: $cdir"))
            continue
        end

        # ── pull VRE metadata row ─────────────────────────────────────────────
        meta_rows = filter(r -> r.case_name == cname, vre_meta)
        isempty(meta_rows) && error("No metadata row for $cname in vre_case_summary.csv")
        vmeta = first(meta_rows)

        @info "── Case: $cname ──────────────────────────────────────────────"
        sys = load_system_data(cdir)
        sys.n_hours == 8760 ||
            @warn "$cname: expected 8760 h, got $(sys.n_hours)"

        # ── shared scenario set (CRN) ─────────────────────────────────────────
        crn_cfg   = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)

        # helper to build a full result NamedTuple
        function make_row(model, metrics, rt, p1_scen, p1_hrs, status, errmsg)
            m = metrics
            nan = NaN
            return (
                case_name                       = cname,
                model                           = model,
                n_scenarios                     = n_scenarios,
                seed                            = seed,
                load_scale                      = vmeta.load_scale,
                wind_scale                      = vmeta.wind_scale,
                solar_scale                     = vmeta.solar_scale,
                available_vre_energy_share      = vmeta.available_vre_energy_share,
                vre_capacity_share_no_storage   = vmeta.vre_capacity_share_no_storage,
                vre_capacity_share_incl_storage = vmeta.vre_capacity_share_incl_storage,
                negative_net_load_hours         = vmeta.negative_net_load_hours,
                vre_exceeds_load_hours          = vmeta.vre_exceeds_load_hours,
                net_load_peak_mw                = vmeta.net_load_peak_mw,
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
                p1_fire_scenarios               = p1_scen,
                p1_fire_hours                   = p1_hrs,
                runtime_s                       = round(rt; digits=1),
                status                          = status,
                error_message                   = errmsg,
            )
        end

        # ── RA-1a (M1) ────────────────────────────────────────────────────────
        if "M1" in model_labels
            try
                @info "  running M1 (RA-1a)..."
                t0   = time()
                r_m1 = run_m1_rule_based(sys, scenarios, crn_cfg)
                rt   = time() - t0
                m_m1 = compute_metrics(r_m1, sys, crn_cfg)
                p1s, p1h = count_p1_fires(sys, scenarios, r_m1)
                push!(results_rows, make_row("M1", m_m1, rt, p1s, p1h, "ok", ""))
                @info "  M1:  LOLH=$(round(m_m1.lolh, digits=2)) h  EUE=$(round(m_m1.eue, digits=1)) MWh  ($(round(rt, digits=1))s)"
            catch e
                @error "M1 failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_row("M1", nothing, 0.0, -1, -1, "error", sprint(showerror, e)))
                push!(run_errors, (case_name=cname, model="M1", error=sprint(showerror, e)))
            end
        end

        # ── RA-1b (M1b) ───────────────────────────────────────────────────────
        if "M1b" in model_labels
            try
                m1b_cfg = SimConfig(; n_scenarios, seed, reserve_fraction=0.50)
                @info "  running M1b (RA-1b, reserve_fraction=0.50)..."
                t0    = time()
                r_m1b = run_m1b_reserve_aware(sys, scenarios, m1b_cfg)
                rt    = time() - t0
                m_m1b = compute_metrics(r_m1b, sys, m1b_cfg)
                p1s, p1h = count_p1_fires(sys, scenarios, r_m1b)
                push!(results_rows, make_row("M1b", m_m1b, rt, p1s, p1h, "ok", ""))
                @info "  M1b: LOLH=$(round(m_m1b.lolh, digits=2)) h  EUE=$(round(m_m1b.eue, digits=1)) MWh  ($(round(rt, digits=1))s)"
            catch e
                @error "M1b failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_row("M1b", nothing, 0.0, -1, -1, "error", sprint(showerror, e)))
                push!(run_errors, (case_name=cname, model="M1b", error=sprint(showerror, e)))
            end
        end

        # ── RA-3 (M3) ─────────────────────────────────────────────────────────
        if !skip_m3
            try
                m3_cfg = SimConfig(; n_scenarios, seed)
                @info "  running M3 (RA-3, full-year ED LP) — may be slow..."
                t0   = time()
                r_m3 = run_m3_ed_dispatch(sys, scenarios, m3_cfg)
                rt   = time() - t0
                m_m3 = compute_metrics(r_m3, sys, m3_cfg)
                push!(results_rows, make_row("M3", m_m3, rt, -1, -1, "ok", ""))
                @info "  M3:  LOLH=$(round(m_m3.lolh, digits=2)) h  EUE=$(round(m_m3.eue, digits=1)) MWh  ($(round(rt, digits=1))s)"
            catch e
                @error "M3 failed for $cname" exception=(e, catch_backtrace())
                push!(results_rows, make_row("M3", nothing, 0.0, -1, -1, "error", sprint(showerror, e)))
                push!(run_errors, (case_name=cname, model="M3", error=sprint(showerror, e)))
            end
        end

        # ── flush intermediate results after every case ───────────────────────
        CSV.write(results_path, DataFrame(results_rows))
        @info "  Intermediate results saved → $results_path"
    end

    total_rt = time() - total_t0
    @info "Total runtime: $(round(total_rt, digits=1)) s"

    # ── build errors / method-comparison DataFrame ────────────────────────────
    df = DataFrame(results_rows)
    ok_df = filter(r -> r.status == "ok", df)

    error_comparison_rows = NamedTuple[]
    if !skip_m3
        for cname in cases_to_run
            m3_row = filter(r -> r.case_name == cname && r.model == "M3" && r.status == "ok", ok_df)
            isempty(m3_row) && continue
            m3_lolh = m3_row[1, :lolh_hours]
            m3_eue  = m3_row[1, :eue_mwh]
            m3_rt   = m3_row[1, :runtime_s]

            for mlabel in ("M1", "M1b")
                mrow = filter(r -> r.case_name == cname && r.model == mlabel && r.status == "ok", ok_df)
                isempty(mrow) && continue
                safe_rel(method_val, bench_val) =
                    bench_val > 0.0 ? (method_val - bench_val) / bench_val : NaN

                push!(error_comparison_rows, (
                    case_name                          = cname,
                    method                             = mlabel,
                    m3_lolh_hours                      = m3_row[1, :lolh_hours],
                    method_lolh_hours                  = mrow[1, :lolh_hours],
                    lolh_error_h                       = mrow[1, :lolh_hours] - m3_row[1, :lolh_hours],
                    lolh_rel_error                     = safe_rel(mrow[1, :lolh_hours],   m3_row[1, :lolh_hours]),
                    m3_lolp                            = m3_row[1, :lolp],
                    method_lolp                        = mrow[1, :lolp],
                    lolp_error                         = mrow[1, :lolp] - m3_row[1, :lolp],
                    m3_lole_days                       = m3_row[1, :lole_days],
                    method_lole_days                   = mrow[1, :lole_days],
                    lole_days_error                    = mrow[1, :lole_days] - m3_row[1, :lole_days],
                    m3_eue_mwh                         = m3_row[1, :eue_mwh],
                    method_eue_mwh                     = mrow[1, :eue_mwh],
                    eue_error_mwh                      = mrow[1, :eue_mwh] - m3_row[1, :eue_mwh],
                    eue_rel_error                      = safe_rel(mrow[1, :eue_mwh], m3_row[1, :eue_mwh]),
                    m3_neue_ppm                        = m3_row[1, :neue_ppm],
                    method_neue_ppm                    = mrow[1, :neue_ppm],
                    neue_ppm_error                     = mrow[1, :neue_ppm] - m3_row[1, :neue_ppm],
                    neue_rel_error                     = safe_rel(mrow[1, :neue_ppm], m3_row[1, :neue_ppm]),
                    m3_cvar_eue_mwh                    = m3_row[1, :cvar_eue_mwh],
                    method_cvar_eue_mwh                = mrow[1, :cvar_eue_mwh],
                    cvar_eue_error_mwh                 = mrow[1, :cvar_eue_mwh] - m3_row[1, :cvar_eue_mwh],
                    cvar_eue_rel_error                 = safe_rel(mrow[1, :cvar_eue_mwh], m3_row[1, :cvar_eue_mwh]),
                    m3_n_shortage_events               = m3_row[1, :n_shortage_events],
                    method_n_shortage_events           = mrow[1, :n_shortage_events],
                    n_shortage_events_error            = mrow[1, :n_shortage_events] - m3_row[1, :n_shortage_events],
                    m3_max_shortfall_mw                = m3_row[1, :max_shortfall_mw],
                    method_max_shortfall_mw            = mrow[1, :max_shortfall_mw],
                    max_shortfall_error_mw             = mrow[1, :max_shortfall_mw] - m3_row[1, :max_shortfall_mw],
                    m3_mean_shortfall_mw               = m3_row[1, :mean_shortfall_when_shedding_mw],
                    method_mean_shortfall_mw           = mrow[1, :mean_shortfall_when_shedding_mw],
                    mean_shortfall_error_mw            = mrow[1, :mean_shortfall_when_shedding_mw] - m3_row[1, :mean_shortfall_when_shedding_mw],
                    runtime_ratio_vs_m3                = m3_row[1, :runtime_s] > 0.0 ?
                                                         m3_row[1, :runtime_s] / mrow[1, :runtime_s] : NaN,
                ))
            end
        end
    end

    CSV.write(results_path, df)
    CSV.write(errors_path,  DataFrame(error_comparison_rows))
    @info "Results → $results_path"
    @info "Errors  → $errors_path"

    # ── write summary.txt ─────────────────────────────────────────────────────
    open(summary_path, "w") do io
        println(io, "=" ^ 80)
        println(io, "VRE Method Comparison Summary")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d  |  skip_m3: %s\n",
                n_scenarios, seed, skip_m3)
        @printf(io, "Cases: %s\n", join(cases_to_run, ", "))
        @printf(io, "Output subdir: %s\n", subdir)
        println(io, "=" ^ 80)
        println(io)

        if isempty(results_rows)
            println(io, "No results available (all cases failed or were skipped).")
        else
            # ── main results table ─────────────────────────────────────────────
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
            println(io, "  Note: Full CSV outputs include event-duration metrics, " *
                        "scenario-EUE quantiles, and Monte Carlo confidence intervals.")
            println(io)

            # ── Q1: does M1b improve over M1? ─────────────────────────────────
            println(io, "Q1. Does RA-1b improve over RA-1a across VRE cases?")
            for cname in cases_to_run
                m1r  = filter(r -> r.case_name == cname && r.model == "M1",  ok_df)
                m1br = filter(r -> r.case_name == cname && r.model == "M1b", ok_df)
                (isempty(m1r) || isempty(m1br)) && continue
                d = m1r[1,:lolh_hours] - m1br[1,:lolh_hours]
                dir = d > 0.01 ? "↓ improved $(round(d, digits=2)) h" :
                      d < -0.01 ? "↑ WORSE $(round(-d, digits=2)) h" : "≈ unchanged"
                @printf(io, "  %-20s  M1=%.2f h  M1b=%.2f h  %s\n",
                        cname, m1r[1,:lolh_hours], m1br[1,:lolh_hours], dir)
            end
            println(io)

            # ── Q2: is M1b still biased high vs M3? ───────────────────────────
            println(io, "Q2. Does RA-1b remain biased high relative to RA-3?")
            if !skip_m3 && !isempty(error_comparison_rows)
                ec = DataFrame(error_comparison_rows)
                m1b_ec = filter(r -> r.method == "M1b", ec)
                for r in eachrow(m1b_ec)
                    ratio = isnan(r.lolh_rel_error) ? "∞" :
                            @sprintf("%.1fx", 1.0 + r.lolh_rel_error)
                    @printf(io, "  %-20s  M1b=%.2f h  M3=%.2f h  error=%+.2f h (%s)\n",
                            r.case_name, r.method_lolh_hours, r.m3_lolh_hours,
                            r.lolh_error_h, ratio)
                end
            else
                println(io, "  RA-3 not run.")
            end
            println(io)

            # ── Q3: does error grow with VRE penetration? ─────────────────────
            println(io, "Q3. Does method error increase with VRE penetration?")
            if !skip_m3 && !isempty(error_comparison_rows)
                ec = DataFrame(error_comparison_rows)
                m1b_ec = sort(filter(r -> r.method == "M1b", ec),
                              :case_name)
                # join VRE energy share for context
                meta_sub = select(vre_meta, :case_name, :available_vre_energy_share,
                                  :negative_net_load_hours)
                joined = leftjoin(m1b_ec, meta_sub; on=:case_name)
                for r in eachrow(joined)
                    @printf(io, "  %-20s  vre_e_shr=%.4f  neg_NL_h=%4d  lolh_err=%+.2f h\n",
                            r.case_name, r.available_vre_energy_share,
                            r.negative_net_load_hours, r.lolh_error_h)
                end
            else
                println(io, "  RA-3 not run — cannot compute errors.")
            end
            println(io)

            # ── Q4: solar-heavy vs wind-heavy ─────────────────────────────────
            println(io, "Q4. Are solar-heavy and wind-heavy cases different?")
            for cname in filter(c -> c in cases_to_run,
                                ["VRE120_solar_hvy", "VRE120_wind_hvy"])
                for mlabel in model_labels
                    mrow = filter(r -> r.case_name == cname && r.model == mlabel, ok_df)
                    isempty(mrow) && continue
                    @printf(io, "  %-20s  %-5s  LOLH=%.2f h  EUE=%.1f MWh\n",
                            cname, mlabel, mrow[1,:lolh_hours], mrow[1,:eue_mwh])
                end
            end
            println(io)

            # ── Q5: which cases should be prioritised for RA-2? ───────────────
            println(io, "Q5. Which VRE cases should be prioritised for RA-2 (event-window LP)?")
            if !skip_m3 && !isempty(error_comparison_rows)
                ec = DataFrame(error_comparison_rows)
                m1b_ec = filter(r -> r.method == "M1b", ec)
                # rank by absolute LOLH error (largest first)
                sorted = sort(m1b_ec, :lolh_error_h; rev=true)
                println(io, "  (ranked by M1b absolute LOLH error vs M3, largest first)")
                for (i, r) in enumerate(eachrow(sorted))
                    @printf(io, "  %d. %-20s  lolh_err=%+.2f h  m3=%.2f h  m1b=%.2f h\n",
                            i, r.case_name, r.lolh_error_h,
                            r.m3_lolh_hours, r.method_lolh_hours)
                end
            else
                println(io, "  RA-3 not run — cannot rank cases.")
            end
            println(io)
        end

        # ── runtime summary ────────────────────────────────────────────────────
        println(io, "Runtime summary")
        println(io, "-" ^ 40)
        for r in eachrow(ok_df)
            @printf(io, "  %-20s  %-5s  %.1f s\n",
                    r.case_name, r.model, r.runtime_s)
        end
        @printf(io, "  Total wall time: %.1f s\n", total_rt)
        println(io)

        if !isempty(run_errors)
            println(io, "Errors / skipped:")
            for e in run_errors
                @printf(io, "  %s [%s]: %s\n", e.case_name, e.model, e.error)
            end
            println(io)
        end

        println(io, "=" ^ 80)
        println(io, "Full results: vre_method_comparison_results.csv")
        println(io, "Error table:  vre_method_comparison_errors.csv")
        println(io, "Log:          $(basename(log_path))")
    end

    @info "Summary → $summary_path"

    # ── console output ─────────────────────────────────────────────────────────
    println()
    println("=" ^ 90)
    @printf("VRE Method Comparison  |  n_scenarios=%d  |  seed=%d  |  subdir=%s\n",
            n_scenarios, seed, subdir)
    @printf("Cases: %s\n", join(cases_to_run, ", "))
    println("=" ^ 90)

    if !isempty(results_rows)
        @printf("  %-20s %-5s %8s %7s %7s %10s %10s %10s %8s\n",
                "Case", "Model", "LOLH(h)", "LOLP%", "LOLE_d",
                "EUE(MWh)", "CVaR-EUE", "MaxSF(MW)", "rt(s)")
        println("  " * "-" ^ 94)
        for r in eachrow(ok_df)
            @printf("  %-20s %-5s %8.2f %7.3f %7.2f %10.1f %10.1f %10.1f %8.1f\n",
                    r.case_name, r.model,
                    r.lolh_hours, 100.0 * r.lolp, r.lole_days,
                    r.eue_mwh, r.cvar_eue_mwh, r.max_shortfall_mw, r.runtime_s)
        end
        println()
        println("  Note: Full CSV outputs include event-duration metrics, " *
                "scenario-EUE quantiles, and Monte Carlo confidence intervals.")
    end

    println("=" ^ 90)

    if !skip_m3 && !isempty(error_comparison_rows)
        println()
        println("M1 / M1b vs M3 error analysis")
        println("-" ^ 90)
        @printf("  %-20s %-5s %10s %10s %12s %14s\n",
                "Case", "Meth", "M3_LOLH", "Meth_LOLH", "err_h", "rel_err")
        println("  " * "-" ^ 74)
        for r in DataFrame(error_comparison_rows) |> eachrow
            rel = isnan(r.lolh_rel_error) ? "  Inf" : @sprintf("%+.1f%%", r.lolh_rel_error * 100)
            @printf("  %-20s %-5s %10.2f %10.2f %12.2f %14s\n",
                    r.case_name, r.method,
                    r.m3_lolh_hours, r.method_lolh_hours,
                    r.lolh_error_h, rel)
        end
        println("-" ^ 90)
    end

    println()
    @printf("Total runtime: %.1f s\n", total_rt)
    println("Output directory: $out_dir")
    println()

    if !isempty(run_errors)
        println("Skipped / errors:")
        for e in run_errors
            println("  $(e.case_name) [$(e.model)]: $(e.error)")
        end
        println()
    end

    println("Summary written to: $summary_path")
end
