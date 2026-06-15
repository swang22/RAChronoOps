#!/usr/bin/env julia
# 72_market_pattern_revalidation.jl
#
# AUTHORITATIVE revalidation script for market-pattern storage methods.
# Replaces script 67 (retired — called uncurtailed variants with wrong labels).
# Corrects M2 parameter error from script 68 (default 500/24 → paper 1000/48).
#
# What this script does vs. prior scripts
# ─────────────────────────────────────────
#   - Uses charge-curtailed variants (MP_pure_cur, MP_emergency_cur) per paper
#   - M2 uses paper params: risk_margin_mw=1000, window_buffer_hours=48,
#     merge_gap_hours=24, min_window_length_hours=24
#   - Tests three calibration patterns from build_caiso_storage_patterns.py:
#       pattern_raw.csv                (diagnostic)
#       pattern_baseline_corrected.csv (subtract geothermal baseline ≈37 MW)
#       pattern_energy_balanced.csv    (scale charge ×1.099 for zero annual drift)
#   - Tests two SOC initializations:
#       fixed_50pct  : init_soc = 50% E_max  (paper standard)
#       cyclic       : run year 1 at 50%, take mean final SOC → run year 2
#   - Validates charging_induced_eue = 0 for charge-curtailed variants
#   - Computes event-start SOC for all methods and conditions
#
# Outputs
# ────────
#   results/paper_tables/market_pattern_revalidated_metrics.csv
#       Full comparison: all Table IV methods × 2 portfolios
#       (MP variants: preferred calibration + cyclic SOC)
#   results/market_pattern_storage/soc_boundary_study.csv
#       2 methods × 2 portfolios × 3 calibrations × 2 SOC conditions
#   results/market_pattern_storage/calibration_comparison.csv
#       3 calibrations × 2 portfolios (fixed 50% SOC, MP_pure_cur only)
#   results/market_pattern_storage/run_<timestamp>.log
#
# Run with:
#   julia --project=. scripts/72_market_pattern_revalidation.jl
#   julia --project=. scripts/72_market_pattern_revalidation.jl --n-scenarios 20 --seed 42

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

# ── Constants ─────────────────────────────────────────────────────────────────
const CASES = ["VRE120_base", "VRE120_wind_hvy"]

const CASE_LABELS = Dict(
    "VRE120_base"     => "Balanced VRE",
    "VRE120_wind_hvy" => "Wind-heavy",
)

const DEFAULT_N    = 20
const DEFAULT_SEED = 42

# Paper-correct M2 event-window LP parameters (Table II caption)
const M2_RISK_MARGIN_MW         = 1000.0
const M2_WINDOW_BUFFER_HOURS    = 48
const M2_MERGE_GAP_HOURS        = 24
const M2_MIN_WINDOW_LENGTH_HOURS = 24

# Preferred calibration for paper comparison (energy-balanced)
const PREFERRED_PATTERN = "pattern_energy_balanced.csv"

# Calibration patterns to test in SOC boundary and calibration comparison studies
const CALIB_PATTERNS = [
    ("raw",                 "pattern_raw.csv"),
    ("baseline_corrected",  "pattern_baseline_corrected.csv"),
    ("energy_balanced",     "pattern_energy_balanced.csv"),
]

# SOC initializations
const SOC_INITS = [
    ("fixed_50pct", 0.50),   # paper standard
    ("cyclic",      nothing), # 2-pass: run year 1 at 50%, use mean final SOC for year 2
]

# ── CLI parsing ───────────────────────────────────────────────────────────────
function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected argument: $arg")
        key = arg[3:end]
        i + 1 <= length(args) && !startswith(args[i+1], "--") ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]; i += 2
    end
    return kw
end

# ── Helper: format metric row ─────────────────────────────────────────────────
function metric_row(;
        case_name, case_label, method, paper_name,
        calibration="N/A", soc_init="fixed_50pct",
        n_scenarios, seed,
        m::Union{MetricsResult,Nothing},
        runtime_s::Float64,
        charging_induced_eue::Float64 = NaN,
        mean_event_start_soc::Float64 = NaN,
        final_soc_mean::Float64       = NaN,
        final_soc_std::Float64        = NaN,
    )
    nan = NaN
    (
        case_name                   = case_name,
        case_label                  = case_label,
        method                      = method,
        paper_name                  = paper_name,
        calibration                 = calibration,
        soc_init                    = soc_init,
        n_scenarios                 = n_scenarios,
        seed                        = seed,
        lolh_hours                  = isnothing(m) ? nan : m.lolh,
        eue_mwh                     = isnothing(m) ? nan : m.eue,
        neue_ppm                    = isnothing(m) ? nan : m.neue * 1e6,
        cvar_eue_mwh                = isnothing(m) ? nan : m.cvar_eue,
        n_shortage_events           = isnothing(m) ? nan : m.n_shortage_events,
        mean_shortage_duration_h    = isnothing(m) ? nan : m.mean_shortage_duration,
        max_shortage_duration_h     = isnothing(m) ? nan : m.max_shortage_duration,
        max_shortfall_mw            = isnothing(m) ? nan : m.max_shortfall,
        lolh_ci95_halfwidth         = isnothing(m) ? nan : m.lolh_ci95_halfwidth,
        eue_ci95_halfwidth          = isnothing(m) ? nan : m.eue_ci95_halfwidth,
        charging_induced_eue_mwh    = charging_induced_eue,
        mean_event_start_soc_frac   = mean_event_start_soc,
        final_soc_mean_frac         = final_soc_mean,
        final_soc_std_frac          = final_soc_std,
        runtime_s_total             = round(runtime_s; digits=2),
        runtime_s_per_scen          = round(runtime_s / n_scenarios; digits=5),
    )
end

# ── Helper: compute event-start SOC ──────────────────────────────────────────
function event_start_soc_mean(results::Vector{DispatchResult},
                               sys::SystemData,
                               avail::Array{<:Integer, 3})::Float64
    try
        ess = compute_event_start_soc(results, sys, avail)
        return isnan(ess.mean_soc_frac) ? NaN : ess.mean_soc_frac
    catch
        return NaN
    end
end

# ── Helper: compute final SOC distribution ────────────────────────────────────
function final_soc_stats(results::Vector{DispatchResult}, sys::SystemData)
    stor = sys.storage
    e_max = nrow(stor) > 0 ? max(sum(stor.energy_mwh), 1.0) : 1.0
    final_fracs = [r.soc[end] / e_max for r in results if !isempty(r.soc)]
    isempty(final_fracs) && return (NaN, NaN)
    return mean(final_fracs), std(final_fracs)
end

# ── Helper: run one MP variant with SOC override + cyclic option ──────────────
function run_mp(sys, avail, cfg, pattern_csv, emerg, curtailed, soc_init_spec)
    """
    Run market-pattern storage with the specified SOC initialization.
    soc_init_spec: Float64 → use as fixed fraction; nothing → cyclic (2-pass).
    Returns (results, eue_decomp, init_soc_frac_used, final_soc_mean)
    """
    if isnothing(soc_init_spec)
        # Cyclic: year 1 at 50% → take mean final SOC → year 2
        res1, _, _ = run_market_pattern_storage(sys, avail, cfg;
                                                 pattern_csv,
                                                 emergency_override=emerg,
                                                 charge_curtailed=curtailed,
                                                 override_init_soc_frac=0.5)
        stor = sys.storage
        e_max = nrow(stor) > 0 ? max(sum(stor.energy_mwh), 1.0) : 1.0
        soc_cyclic = mean(r.soc[end] / e_max for r in res1 if !isempty(r.soc))
        soc_cyclic = isnan(soc_cyclic) ? 0.5 : clamp(soc_cyclic, 0.0, 1.0)

        res2, _, eue_d = run_market_pattern_storage(sys, avail, cfg;
                                                     pattern_csv,
                                                     emergency_override=emerg,
                                                     charge_curtailed=curtailed,
                                                     override_init_soc_frac=soc_cyclic)
        fin_soc_mean, _ = final_soc_stats(res2, sys)
        return res2, eue_d, soc_cyclic, fin_soc_mean
    else
        res, _, eue_d = run_market_pattern_storage(sys, avail, cfg;
                                                    pattern_csv,
                                                    emergency_override=emerg,
                                                    charge_curtailed=curtailed,
                                                    override_init_soc_frac=soc_init_spec)
        fin_soc_mean, _ = final_soc_stats(res, sys)
        return res, eue_d, soc_init_spec, fin_soc_mean
    end
end

# ── main ─────────────────────────────────────────────────────────────────────
let
    kw          = parse_cli(ARGS)
    n_scenarios = parse(Int, get(kw, "n-scenarios", string(DEFAULT_N)))
    seed        = parse(Int, get(kw, "seed",         string(DEFAULT_SEED)))

    project_root = joinpath(@__DIR__, "..")
    pat_dir      = joinpath(project_root, "data_processed", "caiso_storage_patterns")
    cases_root   = joinpath(project_root, "data_processed", "cases")
    out_dir      = joinpath(project_root, "results", "market_pattern_storage")
    pt_dir       = joinpath(project_root, "results", "paper_tables")
    mkpath(out_dir)
    mkpath(pt_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    io_log   = open(log_path, "w")
    logger   = SimpleLogger(io_log)
    global_logger(logger)

    @info "Market-pattern storage revalidation — script 72"
    @info "n=$n_scenarios | seed=$seed"
    @info "Preferred pattern: $PREFERRED_PATTERN"
    @info "Cases: $(join(CASES, ", "))"

    # ── Verify pattern files exist ─────────────────────────────────────────────
    for (_, fname) in CALIB_PATTERNS
        p = joinpath(pat_dir, fname)
        if !isfile(p)
            @warn "Pattern file not found: $p\n  → Run scripts/build_caiso_storage_patterns.py first"
        end
    end
    preferred_csv = joinpath(pat_dir, PREFERRED_PATTERN)
    isfile(preferred_csv) || error("Preferred pattern not found: $preferred_csv\n" *
        "Run scripts/build_caiso_storage_patterns.py first.")

    nan = NaN

    # ────────────────────────────────────────────────────────────────────────────
    # 1. Full comparison table: all Table IV methods, preferred calibration
    # ────────────────────────────────────────────────────────────────────────────
    main_rows  = NamedTuple[]
    m2_cfg_str = "risk_margin=$(M2_RISK_MARGIN_MW)MW buffer=$(M2_WINDOW_BUFFER_HOURS)h"

    for cname in CASES
        cdir = joinpath(cases_root, cname)
        if !isdir(cdir)
            @warn "Case directory not found — skipping: $cdir"
            continue
        end

        @info "━━━━  Case: $cname  ━━━━"
        clabel   = get(CASE_LABELS, cname, cname)
        sys      = load_system_data(cdir)
        crn_cfg  = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)
        avail    = scenarios.availability

        # M1a — Rule-based storage MCS
        try
            @info "  M1a (rule-based)..."
            t0 = time()
            r  = run_m1_rule_based(sys, avail, crn_cfg)
            rt = time() - t0
            m  = compute_metrics(r, sys, crn_cfg)
            es = event_start_soc_mean(r, sys, avail)
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="M1a", paper_name="Rule-based storage MCS",
                n_scenarios, seed, m, runtime_s=rt, mean_event_start_soc=es))
            @info "  M1a: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh"
        catch e
            @error "M1a failed" exception=(e, catch_backtrace())
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="M1a", paper_name="Rule-based storage MCS",
                n_scenarios, seed, m=nothing, runtime_s=0.0))
        end

        # M1b — Reserve-aware storage MCS
        try
            @info "  M1b (reserve-aware)..."
            t0 = time()
            r  = run_m1b_reserve_aware(sys, avail, crn_cfg)
            rt = time() - t0
            m  = compute_metrics(r, sys, crn_cfg)
            es = event_start_soc_mean(r, sys, avail)
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="M1b", paper_name="Reserve-aware storage MCS",
                n_scenarios, seed, m, runtime_s=rt, mean_event_start_soc=es))
            @info "  M1b: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh"
        catch e
            @error "M1b failed" exception=(e, catch_backtrace())
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="M1b", paper_name="Reserve-aware storage MCS",
                n_scenarios, seed, m=nothing, runtime_s=0.0))
        end

        # M1c — Emergency-only storage MCS
        try
            @info "  M1c (emergency-only)..."
            t0 = time()
            r  = run_m1c_emergency_only(sys, avail, crn_cfg)
            rt = time() - t0
            m  = compute_metrics(r, sys, crn_cfg)
            es = event_start_soc_mean(r, sys, avail)
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="M1c", paper_name="Emergency-only storage MCS",
                n_scenarios, seed, m, runtime_s=rt, mean_event_start_soc=es))
            @info "  M1c: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh"
        catch e
            @error "M1c failed" exception=(e, catch_backtrace())
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="M1c", paper_name="Emergency-only storage MCS",
                n_scenarios, seed, m=nothing, runtime_s=0.0))
        end

        # M2 — Event-window LP with PAPER parameters (corrected from script 68)
        try
            cfg_m2 = SimConfig(; n_scenarios, seed,
                               risk_margin_mw=M2_RISK_MARGIN_MW,
                               window_buffer_hours=M2_WINDOW_BUFFER_HOURS,
                               merge_gap_hours=M2_MERGE_GAP_HOURS,
                               min_window_length_hours=M2_MIN_WINDOW_LENGTH_HOURS)
            @info "  M2 (event-window LP, $m2_cfg_str)..."
            t0 = time()
            r  = run_m2_event_window_lp(sys, avail, cfg_m2)
            rt = time() - t0
            m  = compute_metrics(r, sys, crn_cfg)
            es = event_start_soc_mean(r, sys, avail)
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="M2", paper_name="Event-window storage MCS",
                n_scenarios, seed, m, runtime_s=rt, mean_event_start_soc=es))
            @info "  M2: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh"
        catch e
            @error "M2 failed" exception=(e, catch_backtrace())
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="M2", paper_name="Event-window storage MCS",
                n_scenarios, seed, m=nothing, runtime_s=0.0))
        end

        # M3 — Full-year ED (load from existing results; rerun only if no prior results)
        m3_existing = joinpath(pt_dir, "paper_storage_method_comparison.csv")
        if isfile(m3_existing)
            try
                df_bench = CSV.read(m3_existing, DataFrame)
                m3_rows  = filter(r -> String(r.case) == cname &&
                                       String(r.model_internal) == "M3", df_bench)
                if !isempty(m3_rows)
                    r3 = m3_rows[1, :]
                    push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                        method="M3", paper_name="Full-year ED (from prior results)",
                        n_scenarios, seed, m=nothing,
                        runtime_s=hasproperty(r3, :mean_runtime_s) ? r3.mean_runtime_s * n_scenarios : 0.0))
                    @info "  M3: loaded from prior results (lolh=$(r3.lolh) h)"
                    # Patch in the metrics from the file
                    last_row = pop!(main_rows)
                    push!(main_rows, merge(last_row, (
                        lolh_hours               = Float64(r3.lolh),
                        eue_mwh                  = hasproperty(r3, :eue_mwh) ? Float64(r3.eue_mwh) : nan,
                        cvar_eue_mwh             = hasproperty(r3, :cvar_eue_mwh) ? Float64(r3.cvar_eue_mwh) : nan,
                        paper_name               = "Full-year ED (prior results N=$(hasproperty(r3, :n_scenarios) ? r3.n_scenarios : n_scenarios))",
                    )))
                end
            catch e
                @warn "Could not load M3 from prior results: $e"
            end
        end

        # MP_pure_cur — Market-pattern storage MCS (paper label; charge-curtailed)
        try
            @info "  MP_pure_cur (market-pattern, curtailed, preferred calibration, cyclic SOC)..."
            t0 = time()
            res, eue_d, soc_used, fin_soc = run_mp(sys, avail, crn_cfg,
                                                     preferred_csv, false, true, nothing)
            rt = time() - t0
            m  = compute_metrics(res, sys, crn_cfg)
            es = event_start_soc_mean(res, sys, avail)
            fin_mean, fin_std = final_soc_stats(res, sys)
            # Validate charge-curtailed invariant
            if eue_d.charging_induced_eue > 1e-9
                @warn "MP_pure_cur: charging_induced_eue=$(eue_d.charging_induced_eue) > 0 (unexpected)"
            end
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="MP_pure_cur", paper_name="Market-pattern storage MCS",
                calibration="energy_balanced", soc_init="cyclic (init=$(round(soc_used*100,digits=1))%)",
                n_scenarios, seed, m, runtime_s=rt,
                charging_induced_eue=eue_d.charging_induced_eue,
                mean_event_start_soc=es, final_soc_mean=fin_mean, final_soc_std=fin_std))
            @info "  MP_pure_cur: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  init_soc=$(round(soc_used*100, digits=1))%  final_soc=$(round(fin_mean*100, digits=1))%"
        catch e
            @error "MP_pure_cur failed" exception=(e, catch_backtrace())
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="MP_pure_cur", paper_name="Market-pattern storage MCS",
                n_scenarios, seed, m=nothing, runtime_s=0.0))
        end

        # MP_emergency_cur — Market-pattern + emergency MCS (paper label; charge-curtailed)
        try
            @info "  MP_emergency_cur (market-pattern + emergency, curtailed, preferred calibration, cyclic SOC)..."
            t0 = time()
            res, eue_d, soc_used, fin_soc = run_mp(sys, avail, crn_cfg,
                                                     preferred_csv, true, true, nothing)
            rt = time() - t0
            m  = compute_metrics(res, sys, crn_cfg)
            es = event_start_soc_mean(res, sys, avail)
            fin_mean, fin_std = final_soc_stats(res, sys)
            if eue_d.charging_induced_eue > 1e-9
                @warn "MP_emergency_cur: charging_induced_eue=$(eue_d.charging_induced_eue) > 0 (unexpected)"
            end
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="MP_emergency_cur", paper_name="Market-pattern + emergency MCS",
                calibration="energy_balanced", soc_init="cyclic (init=$(round(soc_used*100,digits=1))%)",
                n_scenarios, seed, m, runtime_s=rt,
                charging_induced_eue=eue_d.charging_induced_eue,
                mean_event_start_soc=es, final_soc_mean=fin_mean, final_soc_std=fin_std))
            @info "  MP_emergency_cur: LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  init_soc=$(round(soc_used*100, digits=1))%  final_soc=$(round(fin_mean*100, digits=1))%"
        catch e
            @error "MP_emergency_cur failed" exception=(e, catch_backtrace())
            push!(main_rows, metric_row(; case_name=cname, case_label=clabel,
                method="MP_emergency_cur", paper_name="Market-pattern + emergency MCS",
                n_scenarios, seed, m=nothing, runtime_s=0.0))
        end
    end

    main_path = joinpath(pt_dir, "market_pattern_revalidated_metrics.csv")
    CSV.write(main_path, DataFrame(main_rows))
    @info "Main comparison table → $main_path"

    # ────────────────────────────────────────────────────────────────────────────
    # 2. SOC boundary study: 2 paper methods × 3 calibrations × 2 SOC inits
    # ────────────────────────────────────────────────────────────────────────────
    soc_rows = NamedTuple[]

    for cname in CASES
        cdir = joinpath(cases_root, cname)
        isdir(cdir) || continue

        @info "━━━━  SOC boundary study: $cname  ━━━━"
        clabel    = get(CASE_LABELS, cname, cname)
        sys       = load_system_data(cdir)
        crn_cfg   = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)
        avail     = scenarios.availability
        stor      = sys.storage
        e_max     = nrow(stor) > 0 ? max(sum(stor.energy_mwh), 1.0) : 1.0

        for (calib_label, calib_fname) in CALIB_PATTERNS
            pat_csv = joinpath(pat_dir, calib_fname)
            if !isfile(pat_csv)
                @warn "  Pattern not found ($calib_label): $pat_csv — skipping"
                continue
            end

            for (method_label, emerg, curtailed) in [
                    ("MP_pure_cur",      false, true),
                    ("MP_emergency_cur", true,  true),
                ]

                for (soc_label, soc_spec) in SOC_INITS
                    @info "  $method_label | $calib_label | $soc_label..."
                    t0 = time()
                    try
                        res, eue_d, soc_used, fin_soc_mean = run_mp(sys, avail, crn_cfg,
                                                                      pat_csv, emerg, curtailed, soc_spec)
                        rt = time() - t0
                        m  = compute_metrics(res, sys, crn_cfg)
                        es = event_start_soc_mean(res, sys, avail)
                        fin_soc_std = final_soc_stats(res, sys)[2]

                        # Count hours where SOC = 0% or SOC = 100%
                        n_empty_hours = sum(sum(r.soc .< 1.0) for r in res) / n_scenarios
                        n_full_hours  = sum(sum(r.soc .> (e_max - 1.0)) for r in res) / n_scenarios

                        push!(soc_rows, (
                            case_name                   = cname,
                            case_label                  = clabel,
                            method                      = method_label,
                            calibration                 = calib_label,
                            soc_init                    = soc_label,
                            init_soc_frac               = round(soc_used, digits=4),
                            final_soc_mean_frac         = round(fin_soc_mean, digits=4),
                            final_soc_std_frac          = round(fin_soc_std, digits=4),
                            soc_drift_frac              = round(fin_soc_mean - soc_used, digits=4),
                            lolh_hours                  = round(m.lolh, digits=4),
                            eue_mwh                     = round(m.eue, digits=2),
                            cvar_eue_mwh                = round(m.cvar_eue, digits=2),
                            n_shortage_events           = round(m.n_shortage_events, digits=3),
                            mean_shortage_duration_h    = round(m.mean_shortage_duration, digits=3),
                            max_shortage_duration_h     = m.max_shortage_duration,
                            max_shortfall_mw            = round(m.max_shortfall, digits=1),
                            mean_event_start_soc_frac   = round(es, digits=4),
                            mean_empty_hours_per_year   = round(n_empty_hours, digits=1),
                            mean_full_hours_per_year    = round(n_full_hours, digits=1),
                            charging_induced_eue_mwh    = eue_d.charging_induced_eue,
                            runtime_s                   = round(rt, digits=2),
                        ))
                        @info "    LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  " *
                              "init=$(round(soc_used*100,digits=1))%  final=$(round(fin_soc_mean*100,digits=1))%  " *
                              "empty_h=$(round(n_empty_hours, digits=0))"
                    catch e
                        @error "  Failed: $method_label/$calib_label/$soc_label" exception=(e, catch_backtrace())
                    end
                end
            end
        end
    end

    soc_path = joinpath(out_dir, "soc_boundary_study.csv")
    CSV.write(soc_path, DataFrame(soc_rows))
    @info "SOC boundary study → $soc_path"

    # ────────────────────────────────────────────────────────────────────────────
    # 3. Calibration comparison: MP_pure_cur × 3 calibrations (fixed 50% SOC)
    # ────────────────────────────────────────────────────────────────────────────
    calib_rows = NamedTuple[]

    for cname in CASES
        cdir = joinpath(cases_root, cname)
        isdir(cdir) || continue

        @info "━━━━  Calibration comparison: $cname  ━━━━"
        clabel    = get(CASE_LABELS, cname, cname)
        sys       = load_system_data(cdir)
        crn_cfg   = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)
        avail     = scenarios.availability
        stor      = sys.storage
        e_max     = nrow(stor) > 0 ? max(sum(stor.energy_mwh), 1.0) : 1.0

        for (calib_label, calib_fname) in CALIB_PATTERNS
            pat_csv = joinpath(pat_dir, calib_fname)
            isfile(pat_csv) || continue

            for (method_label, emerg, curtailed) in [
                    ("MP_pure_cur",      false, true),
                    ("MP_emergency_cur", true,  true),
                ]
                @info "  $method_label | $calib_label..."
                t0 = time()
                try
                    res, _, eue_d = run_market_pattern_storage(sys, avail, crn_cfg;
                                                                pattern_csv=pat_csv,
                                                                emergency_override=emerg,
                                                                charge_curtailed=curtailed,
                                                                override_init_soc_frac=0.50)
                    rt = time() - t0
                    m  = compute_metrics(res, sys, crn_cfg)
                    fin_mean, fin_std = final_soc_stats(res, sys)
                    es = event_start_soc_mean(res, sys, avail)
                    n_empty = sum(sum(r.soc .< 1.0) for r in res) / n_scenarios

                    push!(calib_rows, (
                        case_name                = cname,
                        case_label               = clabel,
                        method                   = method_label,
                        calibration              = calib_label,
                        soc_init                 = "fixed_50pct",
                        lolh_hours               = round(m.lolh, digits=4),
                        eue_mwh                  = round(m.eue, digits=2),
                        neue_ppm                 = round(m.neue * 1e6, digits=4),
                        cvar_eue_mwh             = round(m.cvar_eue, digits=2),
                        final_soc_mean_frac      = round(fin_mean, digits=4),
                        final_soc_std_frac       = round(fin_std, digits=4),
                        soc_drift_frac           = round(fin_mean - 0.50, digits=4),
                        mean_event_start_soc_frac= round(es, digits=4),
                        mean_empty_hours_per_year= round(n_empty, digits=1),
                        charging_induced_eue_mwh = eue_d.charging_induced_eue,
                        runtime_s                = round(rt, digits=2),
                    ))
                    @info "    LOLH=$(round(m.lolh, digits=2)) h  EUE=$(round(m.eue, digits=1)) MWh  final_soc=$(round(fin_mean*100,digits=1))%"
                catch e
                    @error "  Failed: $method_label/$calib_label" exception=(e, catch_backtrace())
                end
            end
        end
    end

    calib_path = joinpath(out_dir, "calibration_comparison.csv")
    CSV.write(calib_path, DataFrame(calib_rows))
    @info "Calibration comparison → $calib_path"

    close(io_log)

    # ── Console summary ────────────────────────────────────────────────────────
    println("\n╔══ Market-pattern storage revalidation — results ══╗")

    println("\n── Main comparison (preferred calibration + cyclic SOC) ──")
    for r in main_rows
        isnan(r.lolh_hours) && continue
        @printf "  %-40s  %-22s  LOLH=%7.2f h  EUE=%9.1f MWh  CVaR=%9.1f MWh\n" r.case_name r.method r.lolh_hours r.eue_mwh r.cvar_eue_mwh
    end

    println("\n── SOC boundary study (MP_pure_cur, energy_balanced) ──")
    for r in soc_rows
        r.calibration == "energy_balanced" && r.method == "MP_pure_cur" || continue
        @printf "  %-22s  %-15s  LOLH=%7.2f h  init=%5.1f%%  final=%5.1f%%  empty_h=%6.1f\n" r.case_name r.soc_init r.lolh_hours (r.init_soc_frac*100) (r.final_soc_mean_frac*100) r.mean_empty_hours_per_year
    end

    println("\n── Calibration comparison (fixed 50% SOC, MP_pure_cur) ──")
    for r in calib_rows
        r.method == "MP_pure_cur" || continue
        @printf "  %-22s  %-20s  LOLH=%7.2f h  EUE=%9.1f MWh  final_soc=%5.1f%%\n" r.case_name r.calibration r.lolh_hours r.eue_mwh (r.final_soc_mean_frac*100)
    end

    println("\nOutputs:")
    @printf "  Main table:           %s\n" main_path
    @printf "  SOC boundary study:   %s\n" soc_path
    @printf "  Calibration compare:  %s\n" calib_path
    @printf "  Log:                  %s\n" log_path
    println("Done.")
end
