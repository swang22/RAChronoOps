#!/usr/bin/env julia
# 71_runtime_benchmark.jl
#
# Part D: Warm-start dispatch runtime benchmark for all Table IV methods plus
# the two paper-facing market-pattern variants.
#
# Protocol:
#   1. Load data and generate scenarios once (excluded from timing).
#   2. Run each method once as a warm-up (JIT compilation).
#   3. Time DISPATCH_REPS repetitions of the dispatch function only.
#   4. Report median and mean wall-clock seconds per scenario.
#
# Configuration identical to Table IV: N=20, seed=42, M2 risk=1000 MW, buf=48 h.
# (VRE120_wind_hvy also N=20 here, consistent with market-pattern experiments.)
#
# Methods timed:
#   M1   Naive storage MCS
#   M1b  SOC-floor storage MCS
#   M1c  Emergency-only storage MCS
#   M2   Event-window storage MCS  (risk=1000 MW, buf=48 h)
#   M3   Full-year ED
#   MP_pure_cur      Market-pattern storage MCS
#   MP_emergency_cur Market-pattern + emergency storage MCS
#
# Output:
#   results/paper_tables/runtime_common_benchmark.csv
#
# Usage:
#   julia --project=. scripts/71_runtime_benchmark.jl [--skip-m3]
#                                                      [--n-reps N]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const PAPER_N          = 20
const SEED             = 42
const CASES            = ["VRE120_base", "VRE120_wind_hvy"]
const CASE_LABELS      = Dict("VRE120_base" => "Balanced VRE", "VRE120_wind_hvy" => "Wind-heavy")
const M2_RISK_MW       = 1000.0
const M2_BUF_H         = 48
const DEFAULT_REPS     = 3   # repetitions for fast methods
const M3_REPS          = 2   # M3 is slow; 2 timed reps is sufficient
const M2_REPS          = 3

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

function parse_flags(args)
    n_reps  = DEFAULT_REPS
    skip_m3 = false
    i = 1
    while i <= length(args)
        if args[i] == "--skip-m3"
            skip_m3 = true; i += 1
        elseif args[i] == "--n-reps" && i+1 <= length(args)
            n_reps = parse(Int, args[i+1]); i += 2
        else
            i += 1
        end
    end
    return (n_reps=n_reps, skip_m3=skip_m3)
end

opts = parse_flags(ARGS)
FAST_REPS = opts.n_reps

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

const REPO      = abspath(joinpath(@__DIR__, ".."))
const DATA_ROOT = joinpath(REPO, "data_processed", "cases")
const PT_DIR    = joinpath(REPO, "results", "paper_tables")
const PAT_CSV   = joinpath(REPO, "data_processed", "caiso_storage_patterns",
                            "season_hour_pattern.csv")

mkpath(PT_DIR)
isfile(PAT_CSV) || error("Pattern CSV not found: $PAT_CSV")

# ─────────────────────────────────────────────────────────────────────────────
# Timing helper
# ─────────────────────────────────────────────────────────────────────────────

function time_dispatch(f::Function, n_reps::Int)
    times = Vector{Float64}(undef, n_reps)
    for i in 1:n_reps
        t0 = time()
        f()
        times[i] = time() - t0
        GC.gc(false)   # prevent GC during measurement
    end
    return times
end

# ─────────────────────────────────────────────────────────────────────────────
# Method table
# Each entry: (label, paper_name, n_reps, dispatch_fn)
# dispatch_fn built after sys/avail are loaded for each case.
# ─────────────────────────────────────────────────────────────────────────────

# Placeholder — populated per case below
bench_rows = NamedTuple[]

println("=" ^ 72)
println("71_runtime_benchmark.jl  —  Part D")
println("Date:  ", Dates.now())
println("N=$PAPER_N  seed=$SEED  fast_reps=$FAST_REPS  m3_reps=$M3_REPS")
println("=" ^ 72)

for cname in CASES
    cdir = joinpath(DATA_ROOT, cname)
    isdir(cdir) || error("Case directory not found: $cdir")
    sys  = load_system_data(cdir)
    cfg  = SimConfig(n_scenarios = PAPER_N, seed = SEED)
    m2cfg = SimConfig(n_scenarios = PAPER_N, seed = SEED,
                      risk_margin_mw      = M2_RISK_MW,
                      window_buffer_hours = M2_BUF_H)

    println("\n  ── Case: $cname ──────────────────────────────────────────────")
    scen  = generate_scenarios(sys, cfg)
    avail = scen.availability

    # Build method list for this case
    methods = [
        ("M1",          "Naive storage MCS",                        FAST_REPS,
         () -> run_m1_rule_based(sys, avail, cfg)),

        ("M1b",         "SOC-floor storage MCS",                    FAST_REPS,
         () -> run_m1b_reserve_aware(sys, avail, cfg)),

        ("M1c",         "Emergency-only storage MCS",               FAST_REPS,
         () -> run_m1c_emergency_only(sys, avail, cfg)),

        ("MP_pure_cur", "Market-pattern storage MCS",               FAST_REPS,
         () -> run_market_pattern_storage(sys, avail, cfg;
                                          pattern_csv        = PAT_CSV,
                                          emergency_override = false,
                                          charge_curtailed   = true)),

        ("MP_emergency_cur", "Market-pattern + emergency storage MCS", FAST_REPS,
         () -> run_market_pattern_storage(sys, avail, cfg;
                                          pattern_csv        = PAT_CSV,
                                          emergency_override = true,
                                          charge_curtailed   = true)),

        ("M2",          "Event-window storage MCS",                 M2_REPS,
         () -> run_m2_event_window_lp(sys, avail, m2cfg)),
    ]

    if !opts.skip_m3
        push!(methods, ("M3", "Full-year ED", M3_REPS,
                         () -> run_m3_ed_dispatch(sys, avail, cfg)))
    end

    for (mname, mlabel, n_reps, fn) in methods
        print("    $mname ($mlabel)  warm-up ... ")
        fn()   # warm-up — JIT compile + first run
        println("done")

        print("    $(repeat(' ', length(mname)+length(mlabel)+4))  timing $n_reps reps ... ")
        times = time_dispatch(fn, n_reps)
        println("done")

        med   = median(times)
        mn    = mean(times)
        mn_s  = minimum(times)
        mx    = maximum(times)
        med_per_scen = med / PAPER_N

        @printf("      median=%.4f s  mean=%.4f s  min=%.4f s  max=%.4f s  → %.5f s/scenario\n",
                med, mn, mn_s, mx, med_per_scen)

        push!(bench_rows, (
            case_name                = cname,
            case_label               = CASE_LABELS[cname],
            method                   = mname,
            paper_name               = mlabel,
            n_scenarios              = PAPER_N,
            seed                     = SEED,
            n_reps                   = n_reps,
            median_rt_s              = med,
            mean_rt_s                = mn,
            min_rt_s                 = mn_s,
            max_rt_s                 = mx,
            median_rt_s_per_scenario = med_per_scen,
            mean_rt_s_per_scenario   = mn / PAPER_N,
            m2_risk_margin_mw        = mname == "M2" ? M2_RISK_MW : NaN,
            m2_window_buffer_hours   = mname == "M2" ? Float64(M2_BUF_H) : NaN,
        ))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Save
# ─────────────────────────────────────────────────────────────────────────────

out_path = joinpath(PT_DIR, "runtime_common_benchmark.csv")
CSV.write(out_path, DataFrame(bench_rows))
println("\n✓ Runtime benchmark → $out_path")

# ─────────────────────────────────────────────────────────────────────────────
# Summary table
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 72)
println("Runtime summary (median, warm-start, N=$PAPER_N)")
println("=" ^ 72)
@printf("  %-24s  %-32s  %10s  %10s\n",
        "Case", "Method", "med(s)", "med(s/scen)")
println("  " * "─" ^ 80)
for r in bench_rows
    @printf("  %-24s  %-32s  %10.4f  %10.5f\n",
            r.case_label, r.paper_name, r.median_rt_s, r.median_rt_s_per_scenario)
end
println("\nDone: ", Dates.now())
