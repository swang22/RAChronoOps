#!/usr/bin/env julia
# 71_common_runtime_benchmark.jl
#
# Warm-start dispatch runtime benchmark for all Table IV methods.
#
# Protocol (per task spec):
#   1. Load case data outside the timed block.
#   2. Generate scenarios outside the timed block.
#   3. Warm up each method once (JIT compilation + first run).
#   4. Time dispatch only — 5 repetitions per method.
#   5. Report median and IQR (Q3−Q1) of wall-clock seconds per scenario.
#
# Configuration:
#   N=20, seed=42, M2: risk=1000 MW, buf=48 h, gap=24 h, min=24 h
#   MP methods: pattern_energy_balanced.csv, cyclic SOC init = 0.231
#   (Consistent with scripts/70 and scripts/72.)
#
# Methods:
#   M1a  Naive storage MCS         (run_m1_rule_based)
#   M1b  SOC-floor storage MCS     (run_m1b_reserve_aware)
#   M1c  Emergency-only storage MCS (run_m1c_emergency_only)
#   MP   Market-pattern storage MCS (MP_pure_cur)
#   MP+E Market-pattern + emergency  (MP_emergency_cur)
#   M2   Event-window storage MCS  (run_m2_event_window_lp)
#   M3   Full-year ED              (run_m3_ed_dispatch)
#
# Output:
#   results/paper_tables/runtime_common_benchmark.csv
#
# Usage:
#   julia --project=. scripts/71_common_runtime_benchmark.jl [--skip-m3] [--n-reps N]

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
const DEFAULT_REPS     = 5   # 5 reps per method (all methods); report median + IQR
const M3_REPS          = 3   # M3 is slow; reduce reps to keep total runtime reasonable
const CYCLIC_SOC_FRAC  = 0.231

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
        elseif args[i] == "--n-reps" && i + 1 <= length(args)
            n_reps = parse(Int, args[i + 1]); i += 2
        else
            i += 1
        end
    end
    return (n_reps=n_reps, skip_m3=skip_m3)
end

opts      = parse_flags(ARGS)
FAST_REPS = opts.n_reps

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

const REPO      = abspath(joinpath(@__DIR__, ".."))
const DATA_ROOT = joinpath(REPO, "data_processed", "cases")
const PT_DIR    = joinpath(REPO, "results", "paper_tables")
const PAT_CSV   = joinpath(REPO, "data_processed", "caiso_storage_patterns",
                            "pattern_energy_balanced.csv")

mkpath(PT_DIR)
isfile(PAT_CSV) || error("Energy-balanced pattern CSV not found: $PAT_CSV\n" *
                          "Run scripts/build_caiso_storage_patterns.py first.")

const CODE_COMMIT = try
    strip(read(Cmd(["git", "-C", REPO, "rev-parse", "--short", "HEAD"]), String))
catch
    "unknown"
end

# ─────────────────────────────────────────────────────────────────────────────
# Timing helper
# ─────────────────────────────────────────────────────────────────────────────

function time_dispatch(f::Function, n_reps::Int)::Vector{Float64}
    times = Vector{Float64}(undef, n_reps)
    for i in 1:n_reps
        t0      = time()
        f()
        times[i] = time() - t0
        GC.gc(false)
    end
    return times
end

# ─────────────────────────────────────────────────────────────────────────────
# Main benchmark loop
# ─────────────────────────────────────────────────────────────────────────────

bench_rows = NamedTuple[]

println("=" ^ 72)
println("71_common_runtime_benchmark.jl")
println("Date:    ", Dates.now())
println("Commit:  ", CODE_COMMIT)
println("N=", PAPER_N, "  seed=", SEED, "  reps=", FAST_REPS, " (M3:", M3_REPS, ")")
println("PAT_CSV: ", basename(PAT_CSV))
println("=" ^ 72)

for cname in CASES
    cdir = joinpath(DATA_ROOT, cname)
    isdir(cdir) || error("Case directory not found: $cdir")
    sys  = load_system_data(cdir)
    cfg  = SimConfig(n_scenarios=PAPER_N, seed=SEED)
    m2cfg = SimConfig(n_scenarios=PAPER_N, seed=SEED,
                      risk_margin_mw      = M2_RISK_MW,
                      window_buffer_hours = M2_BUF_H,
                      merge_gap_hours     = 24,
                      min_window_length_hours = 24)

    println("\n  ── Case: $cname ──────────────────────────────────────────────")

    # Data and scenarios generated OUTSIDE the timed block
    scen  = generate_scenarios(sys, cfg)
    avail = scen.availability

    # Build method list
    methods = Tuple{String, String, Int, Function}[
        ("M1a", "Naive storage MCS", FAST_REPS,
         () -> run_m1_rule_based(sys, avail, cfg)),

        ("M1b", "SOC-floor storage MCS", FAST_REPS,
         () -> run_m1b_reserve_aware(sys, avail, cfg)),

        ("M1c", "Emergency-only storage MCS", FAST_REPS,
         () -> run_m1c_emergency_only(sys, avail, cfg)),

        ("MP_pure_cur", "Market-pattern storage MCS", FAST_REPS,
         () -> run_market_pattern_storage(sys, avail, cfg;
                                          pattern_csv            = PAT_CSV,
                                          emergency_override     = false,
                                          charge_curtailed       = true,
                                          override_init_soc_frac = CYCLIC_SOC_FRAC)),

        ("MP_emergency_cur", "Market-pattern + emergency storage MCS", FAST_REPS,
         () -> run_market_pattern_storage(sys, avail, cfg;
                                          pattern_csv            = PAT_CSV,
                                          emergency_override     = true,
                                          charge_curtailed       = true,
                                          override_init_soc_frac = CYCLIC_SOC_FRAC)),

        ("M2", "Event-window storage MCS", FAST_REPS,
         () -> run_m2_event_window_lp(sys, avail, m2cfg)),
    ]

    if !opts.skip_m3
        push!(methods, ("M3", "Full-year ED", M3_REPS,
                         () -> run_m3_ed_dispatch(sys, avail, cfg)))
    end

    for (mname, mlabel, n_reps, fn) in methods
        print("    [$mname] warm-up ... ")
        fn()   # JIT compile + first run (excluded from timing)
        println("done")

        print("    [$mname] timing $n_reps reps ... ")
        times = time_dispatch(fn, n_reps)
        println("done")

        med      = median(times)
        q1       = quantile(times, 0.25)
        q3       = quantile(times, 0.75)
        iqr      = q3 - q1
        mn_time  = minimum(times)
        mx_time  = maximum(times)
        med_per  = med / PAPER_N
        iqr_per  = iqr / PAPER_N

        @printf("      median=%.4f s  IQR=%.4f s  min=%.4f s  max=%.4f s  → %.5f s/scenario\n",
                med, iqr, mn_time, mx_time, med_per)

        push!(bench_rows, (
            case_name                = cname,
            case_label               = CASE_LABELS[cname],
            method                   = mname,
            paper_name               = mlabel,
            n_scenarios              = PAPER_N,
            seed                     = SEED,
            n_reps                   = n_reps,
            median_rt_s              = med,
            iqr_rt_s                 = iqr,
            q1_rt_s                  = q1,
            q3_rt_s                  = q3,
            min_rt_s                 = mn_time,
            max_rt_s                 = mx_time,
            median_rt_s_per_scenario = med_per,
            iqr_rt_s_per_scenario    = iqr_per,
            m2_risk_margin_mw        = mname == "M2" ? M2_RISK_MW : NaN,
            m2_window_buffer_hours   = mname == "M2" ? Float64(M2_BUF_H) : NaN,
            calibration_version      = startswith(mname, "MP") ? "pattern_energy_balanced" : "N/A",
            cyclic_soc_frac          = startswith(mname, "MP") ? CYCLIC_SOC_FRAC : NaN,
            code_commit              = CODE_COMMIT,
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
# Summary
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 72)
println("Runtime summary (median ± IQR, warm-start, N=$PAPER_N, $FAST_REPS reps)")
println("=" ^ 72)
@printf("  %-22s  %-34s  %10s  %10s  %12s\n",
        "Case", "Method", "med(s)", "IQR(s)", "med(s/scen)")
println("  " * "─" ^ 92)
for r in bench_rows
    @printf("  %-22s  %-34s  %10.4f  %10.4f  %12.5f\n",
            r.case_label, r.paper_name,
            r.median_rt_s, r.iqr_rt_s, r.median_rt_s_per_scenario)
end
println("\nDone: ", Dates.now())
