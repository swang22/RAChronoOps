#!/usr/bin/env julia
# 67_run_market_pattern_storage.jl
#
# Prototype evaluation of Market-pattern storage MCS on the main paper cases.
# Tests two variants:
#   1. Market-pattern storage MCS       (pure — no emergency override)
#   2. Market-pattern + emergency MCS   (emergency override in scarcity hours)
#
# Runs on:
#   VRE120_base     (balanced VRE portfolio)
#   VRE120_wind_hvy (wind-heavy VRE portfolio)
#
# Common random numbers: same ScenarioSet (N=20, seed=42) as all paper runs.
# Storage: 983 MW / 3932 MWh (system-level, same as paper).
#
# Outputs:
#   results/paper_tables/market_pattern_storage_results.csv
#   results/market_pattern_storage/soc_diagnostics.csv
#   results/market_pattern_storage/run_<timestamp>.log
#
# Usage:
#   julia --project=. scripts/67_run_market_pattern_storage.jl [--n-scenarios N] [--seed S]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

# ── Constants ─────────────────────────────────────────────────────────────────
const CASES = ["VRE120_base", "VRE120_wind_hvy"]
const DEFAULT_N = 20
const DEFAULT_SEED = 42

# Canonical paper labels for existing benchmark rows
const BENCHMARK_INTERNAL = Dict(
    "M1c"  => "Emergency-only storage MCS",
    "M2"   => "Event-window storage MCS",
    "M3"   => "Full-year ED",
)

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected arg: $arg")
        key = arg[3:end]
        i + 1 <= length(args) && !startswith(args[i+1], "--") ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]; i += 2
    end
    return kw
end

# ── main ─────────────────────────────────────────────────────────────────────
let
    kw           = parse_cli(ARGS)
    n_scenarios  = parse(Int, get(kw, "n-scenarios", string(DEFAULT_N)))
    seed         = parse(Int, get(kw, "seed",         string(DEFAULT_SEED)))

    project_root = joinpath(@__DIR__, "..")
    pattern_csv  = joinpath(project_root, "data_processed", "caiso_storage_patterns",
                            "season_hour_pattern.csv")
    isfile(pattern_csv) || error("Pattern CSV not found: $pattern_csv\n" *
        "Run scripts/build_caiso_storage_patterns.py first.")

    cases_root   = joinpath(project_root, "data_processed", "cases")
    out_dir      = joinpath(project_root, "results", "market_pattern_storage")
    pt_dir       = joinpath(project_root, "results", "paper_tables")
    mkpath(out_dir)
    mkpath(pt_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "Market-pattern storage MCS evaluation"
    @info "n=$n_scenarios | seed=$seed"
    @info "Pattern CSV: $pattern_csv"
    @info "Cases: $(join(CASES, ", "))"

    results_rows = NamedTuple[]
    soc_diag_rows = NamedTuple[]

    nan = NaN

    function make_row(cname, label, paper_name, m, rt, soc_d)
        (
            case_name                       = cname,
            model_label                     = label,
            model_paper_name                = paper_name,
            n_scenarios                     = n_scenarios,
            seed                            = seed,
            lolh_hours                      = isnothing(m) ? nan : m.lolh,
            lolp_percent                    = isnothing(m) ? nan : 100.0 * m.lolp,
            eue_mwh                         = isnothing(m) ? nan : m.eue,
            neue_ppm                        = isnothing(m) ? nan : m.neue * 1e6,
            cvar_eue_mwh                    = isnothing(m) ? nan : m.cvar_eue,
            p50_scenario_eue_mwh            = isnothing(m) ? nan : m.p50_scenario_eue,
            p90_scenario_eue_mwh            = isnothing(m) ? nan : m.p90_scenario_eue,
            p95_scenario_eue_mwh            = isnothing(m) ? nan : m.p95_scenario_eue,
            n_shortage_events               = isnothing(m) ? nan : m.n_shortage_events,
            mean_shortage_duration_h        = isnothing(m) ? nan : m.mean_shortage_duration,
            max_shortage_duration_h         = isnothing(m) ? nan : m.max_shortage_duration,
            max_shortfall_mw                = isnothing(m) ? nan : m.max_shortfall,
            mean_shortfall_when_shedding_mw = isnothing(m) ? nan : m.mean_shortfall_when_shedding,
            runtime_s                       = round(rt; digits=2),
            mean_soc_before_shortage        = isnothing(soc_d) ? nan : soc_d.mean_soc_frac,
            p10_soc_before_shortage         = isnothing(soc_d) ? nan : soc_d.p10_soc_frac,
            pct_low_soc_shortage            = isnothing(soc_d) ? nan : soc_d.pct_low_soc_shortage,
            n_shortage_hours_total          = isnothing(soc_d) ? 0   : soc_d.n_shortage_hours_total,
        )
    end

    for cname in CASES
        cdir = joinpath(cases_root, cname)
        if !isdir(cdir)
            @warn "Case directory not found — skipping: $cdir"
            continue
        end

        @info "── Case: $cname ──────────────────────────────────────────────"
        sys      = load_system_data(cdir)
        crn_cfg  = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)

        # ── Variant 1: Pure market-pattern ───────────────────────────────────
        try
            cfg = SimConfig(; n_scenarios, seed)
            @info "  running Market-pattern storage MCS (pure)..."
            t0 = time()
            r_mp, soc_d = run_market_pattern_pure(sys, scenarios, cfg;
                                                   pattern_csv)
            rt      = time() - t0
            metrics = compute_metrics(r_mp, sys, cfg)
            push!(results_rows, make_row(cname, "MP_pure",
                                         "Market-pattern storage MCS", metrics, rt, soc_d))
            @info "  MP_pure: LOLH=$(round(metrics.lolh, digits=2)) h  EUE=$(round(metrics.eue, digits=1)) MWh  SOC_pre=$(round(soc_d.mean_soc_frac, digits=3))  ($(round(rt, digits=2)) s)"
            push!(soc_diag_rows, (
                case_name = cname, model_label = "MP_pure",
                mean_soc_frac = soc_d.mean_soc_frac,
                p10_soc_frac = soc_d.p10_soc_frac,
                pct_low_soc_shortage = soc_d.pct_low_soc_shortage,
                n_shortage_hours_total = soc_d.n_shortage_hours_total,
            ))
        catch e
            @error "MP_pure failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_row(cname, "MP_pure",
                                         "Market-pattern storage MCS", nothing, 0.0, nothing))
        end

        # ── Variant 2: Market-pattern + emergency override ───────────────────
        try
            cfg = SimConfig(; n_scenarios, seed)
            @info "  running Market-pattern + emergency MCS..."
            t0 = time()
            r_me, soc_d = run_market_pattern_emergency(sys, scenarios, cfg;
                                                         pattern_csv)
            rt      = time() - t0
            metrics = compute_metrics(r_me, sys, cfg)
            push!(results_rows, make_row(cname, "MP_emergency",
                                         "Market-pattern + emergency MCS", metrics, rt, soc_d))
            @info "  MP_emergency: LOLH=$(round(metrics.lolh, digits=2)) h  EUE=$(round(metrics.eue, digits=1)) MWh  SOC_pre=$(round(soc_d.mean_soc_frac, digits=3))  ($(round(rt, digits=2)) s)"
            push!(soc_diag_rows, (
                case_name = cname, model_label = "MP_emergency",
                mean_soc_frac = soc_d.mean_soc_frac,
                p10_soc_frac = soc_d.p10_soc_frac,
                pct_low_soc_shortage = soc_d.pct_low_soc_shortage,
                n_shortage_hours_total = soc_d.n_shortage_hours_total,
            ))
        catch e
            @error "MP_emergency failed for $cname" exception=(e, catch_backtrace())
            push!(results_rows, make_row(cname, "MP_emergency",
                                         "Market-pattern + emergency MCS", nothing, 0.0, nothing))
        end
    end

    # ── Append existing benchmark rows from the main comparison table ─────────
    paper_table = joinpath(pt_dir, "paper_storage_method_comparison.csv")
    if isfile(paper_table)
        bench_df = CSV.read(paper_table, DataFrame)
        bench_labels = ["M1c", "M2", "M3"]
        for cname in CASES, lbl in bench_labels
            rows = filter(r -> r.case == cname && r.model_internal == lbl, bench_df)
            isempty(rows) && continue
            r = rows[1, :]
            paper_name = get(BENCHMARK_INTERNAL, lbl, lbl)
            push!(results_rows, (
                case_name                       = cname,
                model_label                     = lbl,
                model_paper_name                = paper_name,
                n_scenarios                     = n_scenarios,
                seed                            = seed,
                lolh_hours                      = r.lolh,
                lolp_percent                    = nan,
                eue_mwh                         = r.eue_mwh,
                neue_ppm                        = nan,
                cvar_eue_mwh                    = r.cvar_eue_mwh,
                p50_scenario_eue_mwh            = nan,
                p90_scenario_eue_mwh            = nan,
                p95_scenario_eue_mwh            = nan,
                n_shortage_events               = nan,
                mean_shortage_duration_h        = nan,
                max_shortage_duration_h         = nan,
                max_shortfall_mw                = nan,
                mean_shortfall_when_shedding_mw = nan,
                runtime_s                       = r.mean_runtime_s,
                mean_soc_before_shortage        = nan,
                p10_soc_before_shortage         = nan,
                pct_low_soc_shortage            = nan,
                n_shortage_hours_total          = 0,
            ))
        end
        # Also include PCM-UCED from hope validation table
        hope_table = joinpath(pt_dir, "paper_hope_validation.csv")
        if isfile(hope_table)
            hope_df = CSV.read(hope_table, DataFrame)
            for cname in CASES
                rows = filter(r -> r.case == cname && r.model_internal == "HOPE-UC", hope_df)
                isempty(rows) && continue
                r = rows[1, :]
                push!(results_rows, (
                    case_name                       = cname,
                    model_label                     = "PCM_UCED",
                    model_paper_name                = "PCM-UCED",
                    n_scenarios                     = n_scenarios,
                    seed                            = seed,
                    lolh_hours                      = hasproperty(r, :lolh) ? r.lolh : nan,
                    lolp_percent                    = nan,
                    eue_mwh                         = hasproperty(r, :eue_mwh) ? r.eue_mwh : nan,
                    neue_ppm                        = nan,
                    cvar_eue_mwh                    = hasproperty(r, :cvar_eue_mwh) ? r.cvar_eue_mwh : nan,
                    p50_scenario_eue_mwh            = nan,
                    p90_scenario_eue_mwh            = nan,
                    p95_scenario_eue_mwh            = nan,
                    n_shortage_events               = nan,
                    mean_shortage_duration_h        = nan,
                    max_shortage_duration_h         = nan,
                    max_shortfall_mw                = nan,
                    mean_shortfall_when_shedding_mw = nan,
                    runtime_s                       = nan,
                    mean_soc_before_shortage        = nan,
                    p10_soc_before_shortage         = nan,
                    pct_low_soc_shortage            = nan,
                    n_shortage_hours_total          = 0,
                ))
            end
        end
        @info "Benchmark rows appended from paper tables."
    else
        @warn "paper_storage_method_comparison.csv not found; skipping benchmarks."
    end

    # ── Save outputs ─────────────────────────────────────────────────────────
    results_path = joinpath(pt_dir, "market_pattern_storage_results.csv")
    CSV.write(results_path, DataFrame(results_rows))
    @info "Results → $results_path"

    soc_path = joinpath(out_dir, "soc_diagnostics.csv")
    CSV.write(soc_path, DataFrame(soc_diag_rows))
    @info "SOC diagnostics → $soc_path"

    # ── Console summary ───────────────────────────────────────────────────────
    println("\n=== Market-pattern storage MCS results ===")
    for r in results_rows
        isnan(r.lolh_hours) && continue
        @printf "  %-35s  %-18s  LOLH=%6.2f h  EUE=%8.1f MWh  CVaR=%8.1f MWh\n" r.case_name r.model_label r.lolh_hours r.eue_mwh r.cvar_eue_mwh
    end
    println("\nLog: $log_path")
    println("Done.")
end
