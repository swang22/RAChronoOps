#!/usr/bin/env julia
# 69_event_start_soc.jl
#
# Computes event-start SOC diagnostics for all market-pattern storage MCS
# variants plus the M1c, M2, and M3 benchmarks.
#
# A "shortage event" is a maximal contiguous block of hours where the
# pre-storage shortfall δ_{h,ω} = max(0, load_h - thermal_avail_{h,ω} - VRE_h) > 0.
# SOC is measured at the end of the preceding hour (before the first hour of
# the event).  This is cleaner than per-hour diagnostics because it is
# unaffected by intra-event battery depletion.
#
# Motivation:
#   Emergency-only MCS (M1c) correctly depletes storage through sequential
#   shortage hours; this makes its *per-shortage-hour* SOC look low.  The
#   event-start SOC removes this artifact and directly answers: "did the
#   battery enter the shortage event with energy?"
#
# Outputs:
#   results/paper_tables/market_pattern_event_start_soc.csv
#   results/market_pattern_storage/run_<timestamp>.log
#
# Usage:
#   julia --project=. scripts/69_event_start_soc.jl [--n-scenarios N] [--seed S]
#                                                    [--skip-m3]

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

function parse_cli(args::Vector{String})
    kw      = Dict{String,String}()
    flags   = Set{String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected arg: $arg")
        key = arg[3:end]
        if i + 1 <= length(args) && !startswith(args[i+1], "--")
            kw[key] = args[i+1]; i += 2
        else
            push!(flags, key); i += 1
        end
    end
    return kw, flags
end

# ── main ─────────────────────────────────────────────────────────────────────
let
    kw, flags   = parse_cli(ARGS)
    n_scenarios = parse(Int, get(kw, "n-scenarios", string(DEFAULT_N)))
    seed        = parse(Int, get(kw, "seed",         string(DEFAULT_SEED)))
    skip_m3     = "skip-m3" in flags

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

    @info "Event-start SOC diagnostics"
    @info "n=$n_scenarios | seed=$seed | skip_m3=$skip_m3"

    rows = NamedTuple[]

    function push_row(cname, lbl, paper_name, es::EventStartSoc, rt)
        push!(rows, (
            case_name               = cname,
            case_label              = get(CASE_LABELS, cname, cname),
            model_label             = lbl,
            model_paper_name        = paper_name,
            n_scenarios             = n_scenarios,
            seed                    = seed,
            n_shortage_events_total = es.n_shortage_events_total,
            mean_event_start_soc    = es.mean_soc_frac,
            p10_event_start_soc     = es.p10_soc_frac,
            pct_events_low_025      = es.pct_events_low_soc_025,
            pct_events_low_050      = es.pct_events_low_soc_050,
            runtime_s               = round(rt; digits=2),
        ))
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

        # ── Four market-pattern variants ─────────────────────────────────────
        mp_variants = [
            ("MP_pure",          "Market-pattern pure",                    false, false),
            ("MP_pure_cur",      "Market-pattern pure (curtailed)",        false, true),
            ("MP_emergency",     "Market-pattern + emergency",             true,  false),
            ("MP_emergency_cur", "Market-pattern + emergency (curtailed)", true,  true),
        ]

        for (lbl, paper_name, emerg, curtailed) in mp_variants
            try
                cfg = SimConfig(; n_scenarios, seed)
                @info "  $lbl ..."
                t0 = time()
                r, _, _ = run_market_pattern_storage(sys, scenarios, cfg;
                                                       pattern_csv,
                                                       emergency_override=emerg,
                                                       charge_curtailed=curtailed)
                rt = time() - t0
                es = compute_event_start_soc(r, sys, scenarios)
                @info "  $lbl: n_events=$(es.n_shortage_events_total)  mean=$(round(es.mean_soc_frac, digits=3))  p10=$(round(es.p10_soc_frac, digits=3))  <25%=$(round(es.pct_events_low_soc_025*100, digits=1))%  <50%=$(round(es.pct_events_low_soc_050*100, digits=1))%"
                push_row(cname, lbl, paper_name, es, rt)
            catch e
                @error "$lbl failed for $cname" exception=(e, catch_backtrace())
            end
        end

        # ── M1c ──────────────────────────────────────────────────────────────
        try
            cfg = SimConfig(; n_scenarios, seed)
            @info "  M1c ..."
            t0 = time()
            r  = run_m1c_emergency_only(sys, scenarios, cfg)
            rt = time() - t0
            es = compute_event_start_soc(r, sys, scenarios)
            @info "  M1c: n_events=$(es.n_shortage_events_total)  mean=$(round(es.mean_soc_frac, digits=3))  p10=$(round(es.p10_soc_frac, digits=3))  <25%=$(round(es.pct_events_low_soc_025*100, digits=1))%  <50%=$(round(es.pct_events_low_soc_050*100, digits=1))%"
            push_row(cname, "M1c", "Emergency-only storage MCS", es, rt)
        catch e
            @error "M1c failed for $cname" exception=(e, catch_backtrace())
        end

        # ── M2 ───────────────────────────────────────────────────────────────
        try
            cfg = SimConfig(; n_scenarios, seed)
            @info "  M2 event-window LP ..."
            t0 = time()
            r  = run_m2_event_window_lp(sys, scenarios, cfg)
            rt = time() - t0
            es = compute_event_start_soc(r, sys, scenarios)
            @info "  M2: n_events=$(es.n_shortage_events_total)  mean=$(round(es.mean_soc_frac, digits=3))  p10=$(round(es.p10_soc_frac, digits=3))  <25%=$(round(es.pct_events_low_soc_025*100, digits=1))%  <50%=$(round(es.pct_events_low_soc_050*100, digits=1))%"
            push_row(cname, "M2", "Event-window storage MCS (M2)", es, rt)
        catch e
            @error "M2 failed for $cname" exception=(e, catch_backtrace())
        end

        # ── M3 (full-year ED) ─────────────────────────────────────────────────
        if skip_m3
            @info "  M3 skipped (--skip-m3)."
        else
            try
                cfg = SimConfig(; n_scenarios, seed)
                @info "  M3 full-year ED (this may take several minutes) ..."
                t0 = time()
                r  = run_m3_ed_dispatch(sys, scenarios, cfg)
                rt = time() - t0
                es = compute_event_start_soc(r, sys, scenarios)
                @info "  M3: n_events=$(es.n_shortage_events_total)  mean=$(round(es.mean_soc_frac, digits=3))  p10=$(round(es.p10_soc_frac, digits=3))  <25%=$(round(es.pct_events_low_soc_025*100, digits=1))%  <50%=$(round(es.pct_events_low_soc_050*100, digits=1))%  ($(round(rt, digits=1)) s)"
                push_row(cname, "M3", "Full-year ED (M3)", es, rt)
            catch e
                @error "M3 failed for $cname" exception=(e, catch_backtrace())
            end
        end
    end

    # ── Save ─────────────────────────────────────────────────────────────────
    out_path = joinpath(pt_dir, "market_pattern_event_start_soc.csv")
    CSV.write(out_path, DataFrame(rows))
    @info "Event-start SOC → $out_path"

    # ── Console summary ───────────────────────────────────────────────────────
    println("\n=== Event-start SOC diagnostics ===")
    println("(SOC measured before the first hour of each pre-storage shortage event)\n")
    cur_case = ""
    for r in rows
        if r.case_name != cur_case
            cur_case = r.case_name
            println("  Case: $(get(CASE_LABELS, cur_case, cur_case))")
        end
        isnan(r.mean_event_start_soc) && continue
        @printf "    %-26s  n_events=%4d  mean=%5.3f  p10=%5.3f  <25%%=%5.1f%%  <50%%=%5.1f%%\n" r.model_label r.n_shortage_events_total r.mean_event_start_soc r.p10_event_start_soc (r.pct_events_low_025*100) (r.pct_events_low_050*100)
    end
    println("\nLog: $log_path")
    println("Done.")
end
