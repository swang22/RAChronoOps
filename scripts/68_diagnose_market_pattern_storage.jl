#!/usr/bin/env julia
# 68_diagnose_market_pattern_storage.jl
#
# Diagnostic evaluation of all four Market-pattern storage MCS variants and
# pre-shortage SOC for M1c and M2 benchmarks.  Adds EUE decomposition output.
#
# Four market-pattern variants:
#   MP_pure          (false, false)  pure market-pattern, uncurtailed charging
#   MP_pure_cur      (false, true)   pure market-pattern, surplus-limited charging
#   MP_emergency     (true,  false)  emergency override, uncurtailed charging
#   MP_emergency_cur (true,  true)   emergency override, surplus-limited charging
#
# Benchmarks from script 67:  M1c (emergency-only), M2 (event-window LP).
# Pre-shortage SOC is computed for M1c and M2 via compute_soc_before_shortage.
#
# Outputs:
#   results/paper_tables/market_pattern_storage_results.csv   (all 4 MP variants + benchmarks)
#   results/paper_tables/market_pattern_eue_decomposition.csv (EUE decomposition for MP variants)
#   results/market_pattern_storage/soc_diagnostics.csv        (all 6 methods)
#   results/market_pattern_storage/run_<timestamp>.log
#
# Usage:
#   julia --project=. scripts/68_diagnose_market_pattern_storage.jl [--n-scenarios N] [--seed S]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

# ── Constants ─────────────────────────────────────────────────────────────────
const CASES        = ["VRE120_base", "VRE120_wind_hvy"]
const DEFAULT_N    = 20
const DEFAULT_SEED = 42

const CASE_LABELS = Dict(
    "VRE120_base"     => "Balanced VRE",
    "VRE120_wind_hvy" => "Wind-heavy",
)

const MP_VARIANTS = [
    ("MP_pure",          "Market-pattern pure",                     false, false),
    ("MP_pure_cur",      "Market-pattern pure (curtailed)",         false, true),
    ("MP_emergency",     "Market-pattern + emergency",              true,  false),
    ("MP_emergency_cur", "Market-pattern + emergency (curtailed)",  true,  true),
]

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
    kw          = parse_cli(ARGS)
    n_scenarios = parse(Int, get(kw, "n-scenarios", string(DEFAULT_N)))
    seed        = parse(Int, get(kw, "seed",         string(DEFAULT_SEED)))

    project_root = joinpath(@__DIR__, "..")
    pattern_csv  = joinpath(project_root, "data_processed", "caiso_storage_patterns",
                            "season_hour_pattern.csv")
    isfile(pattern_csv) || error("Pattern CSV not found: $pattern_csv\n" *
        "Run scripts/build_caiso_storage_patterns.py first.")

    cases_root = joinpath(project_root, "data_processed", "cases")
    out_dir    = joinpath(project_root, "results", "market_pattern_storage")
    pt_dir     = joinpath(project_root, "results", "paper_tables")
    mkpath(out_dir)
    mkpath(pt_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "Market-pattern storage MCS — diagnostic evaluation"
    @info "n=$n_scenarios | seed=$seed"
    @info "Pattern CSV: $pattern_csv"
    @info "Cases: $(join(CASES, ", "))"

    nan = NaN

    results_rows   = NamedTuple[]
    eue_decomp_rows = NamedTuple[]
    soc_diag_rows  = NamedTuple[]

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

        # ── Four market-pattern variants ─────────────────────────────────────
        for (lbl, paper_name, emerg, curtailed) in MP_VARIANTS
            try
                cfg = SimConfig(; n_scenarios, seed)
                @info "  running $lbl ..."
                t0 = time()
                r, soc_d, eue_d = run_market_pattern_storage(sys, scenarios, cfg;
                                                               pattern_csv,
                                                               emergency_override=emerg,
                                                               charge_curtailed=curtailed)
                rt      = time() - t0
                metrics = compute_metrics(r, sys, cfg)

                @info "  $lbl: LOLH=$(round(metrics.lolh, digits=2)) h  EUE=$(round(metrics.eue, digits=1)) MWh  chg_ind=$(round(eue_d.charging_induced_pct*100, digits=1))%  ($(round(rt, digits=2)) s)"

                push!(results_rows, (
                    case_name        = cname,
                    case_label       = get(CASE_LABELS, cname, cname),
                    model_label      = lbl,
                    model_paper_name = paper_name,
                    n_scenarios      = n_scenarios,
                    seed             = seed,
                    lolh_hours       = metrics.lolh,
                    eue_mwh          = metrics.eue,
                    cvar_eue_mwh     = metrics.cvar_eue,
                    runtime_s        = round(rt; digits=2),
                    mean_soc_before_shortage = soc_d.mean_soc_frac,
                    p10_soc_before_shortage  = soc_d.p10_soc_frac,
                    pct_low_soc_shortage     = soc_d.pct_low_soc_shortage,
                    n_shortage_hours_total   = soc_d.n_shortage_hours_total,
                ))

                push!(eue_decomp_rows, (
                    case_name               = cname,
                    case_label              = get(CASE_LABELS, cname, cname),
                    model_label             = lbl,
                    model_paper_name        = paper_name,
                    emergency_override      = emerg,
                    charge_curtailed        = curtailed,
                    total_eue_mwh           = eue_d.total_eue,
                    pre_storage_shortfall_eue_mwh = eue_d.pre_storage_shortfall_eue,
                    missed_discharge_eue_mwh      = eue_d.missed_discharge_eue,
                    charging_induced_eue_mwh      = eue_d.charging_induced_eue,
                    low_soc_shortfall_eue_mwh     = eue_d.low_soc_shortfall_eue,
                    pre_storage_pct         = eue_d.pre_storage_pct,
                    missed_discharge_pct    = eue_d.missed_discharge_pct,
                    charging_induced_pct    = eue_d.charging_induced_pct,
                    low_soc_pct             = eue_d.low_soc_pct,
                ))

                push!(soc_diag_rows, (
                    case_name            = cname,
                    model_label          = lbl,
                    mean_soc_frac        = soc_d.mean_soc_frac,
                    p10_soc_frac         = soc_d.p10_soc_frac,
                    pct_low_soc_shortage = soc_d.pct_low_soc_shortage,
                    n_shortage_hours_total = soc_d.n_shortage_hours_total,
                ))

            catch e
                @error "$lbl failed for $cname" exception=(e, catch_backtrace())
            end
        end

        # ── M1c benchmark + SOC diagnostics ─────────────────────────────────
        try
            cfg = SimConfig(; n_scenarios, seed)
            @info "  running M1c (benchmark)..."
            t0   = time()
            r_m1c = run_m1c_emergency_only(sys, scenarios, cfg)
            rt   = time() - t0
            met  = compute_metrics(r_m1c, sys, cfg)
            soc_d = compute_soc_before_shortage(r_m1c, sys)
            @info "  M1c: LOLH=$(round(met.lolh, digits=2)) h  SOC_pre=$(round(soc_d.mean_soc_frac, digits=3))  ($(round(rt, digits=2)) s)"

            push!(results_rows, (
                case_name        = cname,
                case_label       = get(CASE_LABELS, cname, cname),
                model_label      = "M1c",
                model_paper_name = "Emergency-only storage MCS",
                n_scenarios      = n_scenarios,
                seed             = seed,
                lolh_hours       = met.lolh,
                eue_mwh          = met.eue,
                cvar_eue_mwh     = met.cvar_eue,
                runtime_s        = round(rt; digits=2),
                mean_soc_before_shortage = soc_d.mean_soc_frac,
                p10_soc_before_shortage  = soc_d.p10_soc_frac,
                pct_low_soc_shortage     = soc_d.pct_low_soc_shortage,
                n_shortage_hours_total   = soc_d.n_shortage_hours_total,
            ))

            push!(soc_diag_rows, (
                case_name            = cname,
                model_label          = "M1c",
                mean_soc_frac        = soc_d.mean_soc_frac,
                p10_soc_frac         = soc_d.p10_soc_frac,
                pct_low_soc_shortage = soc_d.pct_low_soc_shortage,
                n_shortage_hours_total = soc_d.n_shortage_hours_total,
            ))
        catch e
            @error "M1c failed for $cname" exception=(e, catch_backtrace())
        end

        # ── M2 benchmark + SOC diagnostics ───────────────────────────────────
        try
            cfg = SimConfig(; n_scenarios, seed)
            @info "  running M2 event-window LP (benchmark)..."
            t0   = time()
            r_m2 = run_m2_event_window_lp(sys, scenarios, cfg)
            rt   = time() - t0
            met  = compute_metrics(r_m2, sys, cfg)
            soc_d = compute_soc_before_shortage(r_m2, sys)
            @info "  M2: LOLH=$(round(met.lolh, digits=2)) h  SOC_pre=$(round(soc_d.mean_soc_frac, digits=3))  ($(round(rt, digits=2)) s)"

            push!(results_rows, (
                case_name        = cname,
                case_label       = get(CASE_LABELS, cname, cname),
                model_label      = "M2",
                model_paper_name = "Event-window storage MCS (M2)",
                n_scenarios      = n_scenarios,
                seed             = seed,
                lolh_hours       = met.lolh,
                eue_mwh          = met.eue,
                cvar_eue_mwh     = met.cvar_eue,
                runtime_s        = round(rt; digits=2),
                mean_soc_before_shortage = soc_d.mean_soc_frac,
                p10_soc_before_shortage  = soc_d.p10_soc_frac,
                pct_low_soc_shortage     = soc_d.pct_low_soc_shortage,
                n_shortage_hours_total   = soc_d.n_shortage_hours_total,
            ))

            push!(soc_diag_rows, (
                case_name            = cname,
                model_label          = "M2",
                mean_soc_frac        = soc_d.mean_soc_frac,
                p10_soc_frac         = soc_d.p10_soc_frac,
                pct_low_soc_shortage = soc_d.pct_low_soc_shortage,
                n_shortage_hours_total = soc_d.n_shortage_hours_total,
            ))
        catch e
            @error "M2 failed for $cname" exception=(e, catch_backtrace())
        end
    end

    # ── Save outputs ─────────────────────────────────────────────────────────
    results_path  = joinpath(pt_dir, "market_pattern_storage_results.csv")
    decomp_path   = joinpath(pt_dir, "market_pattern_eue_decomposition.csv")
    soc_path      = joinpath(out_dir, "soc_diagnostics.csv")

    CSV.write(results_path, DataFrame(results_rows))
    CSV.write(decomp_path,  DataFrame(eue_decomp_rows))
    CSV.write(soc_path,     DataFrame(soc_diag_rows))

    @info "Results → $results_path"
    @info "EUE decomposition → $decomp_path"
    @info "SOC diagnostics → $soc_path"

    # ── Console summary ───────────────────────────────────────────────────────
    println("\n=== Market-pattern storage MCS — diagnostic results ===")
    println("\n--- Results summary ---")
    for r in results_rows
        isnan(r.lolh_hours) && continue
        @printf "  %-35s  %-26s  LOLH=%6.2f h  EUE=%8.1f MWh  CVaR=%8.1f MWh\n" r.case_name r.model_label r.lolh_hours r.eue_mwh r.cvar_eue_mwh
    end

    println("\n--- EUE decomposition (market-pattern variants) ---")
    for r in eue_decomp_rows
        isnan(r.total_eue_mwh) && continue
        ci  = isnan(r.charging_induced_pct) ? NaN : r.charging_induced_pct  * 100
        md  = isnan(r.missed_discharge_pct) ? NaN : r.missed_discharge_pct  * 100
        ls  = isnan(r.low_soc_pct)          ? NaN : r.low_soc_pct           * 100
        @printf "  %-35s  %-26s  chg_ind=%5.1f%%  missed_dis=%5.1f%%  low_soc=%5.1f%%\n" r.case_name r.model_label ci md ls
    end

    println("\n--- Pre-shortage SOC (all methods) ---")
    for r in soc_diag_rows
        isnan(r.mean_soc_frac) && continue
        @printf "  %-35s  %-26s  mean=%5.3f  p10=%5.3f  low_soc=%5.1f%%\n" r.case_name r.model_label r.mean_soc_frac r.p10_soc_frac (r.pct_low_soc_shortage * 100)
    end

    println("\nLog: $log_path")
    println("Done.")
end
