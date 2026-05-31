#!/usr/bin/env julia
# 61_marginal_cc_all_methods_rerun.jl
#
# Normalized marginal storage CC for M1, M1b, M1c, M2 using the model-rerun
# perfect-firm denominator, consistent with script 59 (M3 + HOPE-PCM-ED).
#
# CC(δ) = [EUE(x) - EUE(x+δ_storage)] / [EUE(x) - EUE(x+δ_perfect_rerun)]
#
# The perfect-firm denominator uses an explicit dispatch rerun with a δ MW
# always-available generator appended, not post-processing of baseline sheds.
# This eliminates LP-degeneracy sensitivity for M3 and gives a consistent
# denominator for all methods.
#
# M3 values are loaded from script 59 output for reference.
#
# Methods: M1 (naive), M1b (SOC-floor), M1c (emergency-only), M2 (event-window)
# Cases:   VRE120_base (N=20), VRE120_wind_hvy (N=5)
# Deltas:  1, 5, 10 MW  (primary = 1 MW)
# Seed:    42
#
# Outputs:
#   results/paper_tables/marginal_cc_all_methods_rerun.csv
#
# Usage:
#   julia --project=. scripts/61_marginal_cc_all_methods_rerun.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASES_N    = [("VRE120_base", 20), ("VRE120_wind_hvy", 5)]
const DELTA_MWS  = [1.0, 5.0, 10.0]
const DURATION_H = 4.0
const SEED       = 42

const RISK_MARGIN_MW      = 1000.0
const WINDOW_BUFFER_HOURS = 48

const REPO      = abspath(joinpath(@__DIR__, ".."))
const DATA_ROOT = abspath(joinpath(REPO, "data_processed", "cases"))
const TAB_DIR   = abspath(joinpath(REPO, "results", "paper_tables"))

mkpath(TAB_DIR)

# Method table: (internal_name, paper_label, run_function)
# run_function signature: (sys, avail::Array{Int8,3}, cfg, m2_cfg) -> Vector{DispatchResult}
const METHODS = [
    ("M1",  "Naive storage MCS",           :m1),
    ("M1b", "SOC-floor storage MCS",       :m1b),
    ("M1c", "Emergency-only storage MCS",  :m1c),
    ("M2",  "Event-window storage MCS",    :m2),
]

# ─────────────────────────────────────────────────────────────────────────────
# Dispatch helpers
# ─────────────────────────────────────────────────────────────────────────────

function run_method(tag::Symbol, sys::SystemData, avail::Array{Int8,3},
                    base_cfg::SimConfig, m2_cfg::SimConfig)::Vector{DispatchResult}
    if tag == :m1
        return run_m1_rule_based(sys, avail, base_cfg)
    elseif tag == :m1b
        return run_m1b_reserve_aware(sys, avail, base_cfg)
    elseif tag == :m1c
        return run_m1c_emergency_only(sys, avail, base_cfg)
    elseif tag == :m2
        return first(run_m2_with_diagnostics(sys, avail, m2_cfg))
    else
        error("Unknown method tag: $tag")
    end
end

function eue_mean(results::Vector{DispatchResult})::Float64
    isempty(results) && return 0.0
    return mean(sum(r.load_shed) for r in results)
end

function eue_analytical_perfect(results::Vector{DispatchResult}, δ::Float64)::Float64
    isempty(results) && return 0.0
    return mean(sum(max(0.0, v - δ) for v in r.load_shed) for r in results)
end

# ─────────────────────────────────────────────────────────────────────────────
# System modification helpers (identical to script 59)
# ─────────────────────────────────────────────────────────────────────────────

function with_marginal_storage(sys::SystemData, δ::Float64, dur::Float64 = DURATION_H)::SystemData
    eta   = sqrt(0.90)
    extra = DataFrame(
        storage_id            = ["MARG_$(δ)MW"],
        power_mw              = [δ],
        energy_mwh            = [δ * dur],
        charge_efficiency     = [eta],
        discharge_efficiency  = [eta],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [δ * dur * 0.5],
    )
    return SystemData(sys.generators, vcat(sys.storage, extra),
                      sys.load_mw, sys.wind_cf, sys.solar_cf, sys.n_hours)
end

function with_perfect_firm(sys::SystemData, δ::Float64)::SystemData
    gens = copy(sys.generators)
    for col in names(gens)
        if eltype(gens[!, col]) <: AbstractString
            gens[!, col] = String.(gens[!, col])
        end
    end
    perf = copy(gens[1:1, :])
    perf[1, :gen_id]                 = "PERFECT_$(δ)MW"
    perf[1, :gen_type]               = "PerfectFirm"
    perf[1, :fuel]                   = "Other"
    perf[1, :pmax_mw]                = δ
    perf[1, :pmin_mw]                = 0.0
    perf[1, :variable_cost_per_mwh]  = 0.0
    perf[1, :forced_outage_rate]     = 0.0
    perf[1, :mean_repair_time_hours] = 0.0
    perf[1, :is_thermal]             = 1
    perf[1, :is_vre]                 = 0
    perf[1, :vre_type]               = ""
    return SystemData(vcat(gens, perf), sys.storage,
                      sys.load_mw, sys.wind_cf, sys.solar_cf, sys.n_hours)
end

function avail_with_perfect_firm(avail_orig::Array{Int8,3})::Array{Int8,3}
    N, _, T = size(avail_orig)
    return cat(avail_orig, ones(Int8, N, 1, T); dims=2)
end

# ─────────────────────────────────────────────────────────────────────────────
# Load M3 reference values from script 59 output
# ─────────────────────────────────────────────────────────────────────────────

m3_ref_path = joinpath(TAB_DIR, "marginal_cc_model_rerun_validation.csv")
m3_ref = if isfile(m3_ref_path)
    df_ref = CSV.read(m3_ref_path, DataFrame)
    # Build lookup: (case, delta_mw) => (cc_rerun, cc_analytical)
    Dict(
        (row.case, row.delta_mw) => (row.normalized_marginal_cc_rerun,
                                     row.normalized_marginal_cc_analytical)
        for row in eachrow(df_ref)
        if row.model == "Full-year ED (M3)"
    )
else
    @warn "Script 59 output not found at $m3_ref_path — cc_error_vs_m3 will be NaN"
    Dict{Tuple{String,Float64}, Tuple{Float64,Float64}}()
end

# ─────────────────────────────────────────────────────────────────────────────
# Header
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 70)
println("61_marginal_cc_all_methods_rerun.jl")
println("Date: ", Dates.now())
println("Cases:   ", join(string.(first.(CASES_N)), ", "))
println("Methods: ", join(first.(METHODS), ", "))
println("δ (MW):  ", join(DELTA_MWS, ", "))
println("=" ^ 70)

# ─────────────────────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────────────────────

all_rows = NamedTuple[]

for (case, n_scen) in CASES_N
    println("\n" * "─" ^ 70)
    println("Case: $case  (N=$n_scen)")
    println("─" ^ 70)

    case_dir = joinpath(DATA_ROOT, case)
    isdir(case_dir) || error("Case directory not found: $case_dir")
    sys      = load_system_data(case_dir)
    base_cfg = SimConfig(n_scenarios = n_scen, seed = SEED)
    m2_cfg   = SimConfig(n_scenarios = n_scen, seed = SEED,
                         risk_margin_mw      = RISK_MARGIN_MW,
                         window_buffer_hours = WINDOW_BUFFER_HOURS)

    println("\n  Generating $n_scen scenarios (seed=$SEED)…")
    scen       = generate_scenarios(sys, base_cfg)
    avail_orig = scen.availability
    avail_perf = avail_with_perfect_firm(avail_orig)
    N, n_therm, T = size(avail_orig)
    @printf("  availability: [%d scenarios, %d thermal gens, %d hours]\n", N, n_therm, T)

    for (mname, mlabel, mtag) in METHODS
        println("\n  ─── $mname ($mlabel) ───")

        # Baseline
        t0       = time()
        res_base = run_method(mtag, sys, avail_orig, base_cfg, m2_cfg)
        eue_base = eue_mean(res_base)
        @printf("    baseline EUE = %.3f MWh  (%.2f s)\n", eue_base, time()-t0)

        for δ in DELTA_MWS
            @printf("    δ = %.0f MW:\n", δ)

            # Analytical denominator (for reference / comparison)
            eue_perf_anal = eue_analytical_perfect(res_base, δ)
            denom_anal    = eue_base - eue_perf_anal

            # Storage numerator
            sys_stor = with_marginal_storage(sys, δ)
            t0       = time()
            res_stor = run_method(mtag, sys_stor, avail_orig, base_cfg, m2_cfg)
            eue_stor = eue_mean(res_stor)
            numer    = eue_base - eue_stor
            @printf("      +storage:  EUE=%.3f  ΔEUE=%.4f  (%.2f s)\n",
                    eue_stor, numer, time()-t0)

            # Perfect-firm rerun denominator
            sys_perf = with_perfect_firm(sys, δ)
            t0       = time()
            res_perf = run_method(mtag, sys_perf, avail_perf, base_cfg, m2_cfg)
            eue_perf_rerun = eue_mean(res_perf)
            denom_rerun    = eue_base - eue_perf_rerun
            @printf("      +perfect:  EUE=%.3f  ΔEUE_rerun=%.4f  ΔEUE_anal=%.4f  (%.2f s)\n",
                    eue_perf_rerun, denom_rerun, denom_anal, time()-t0)

            cc_rerun = denom_rerun > 1e-9 ? numer / denom_rerun : NaN
            cc_anal  = denom_anal  > 1e-9 ? numer / denom_anal  : NaN
            @printf("      CC_rerun=%.5f  CC_anal=%.5f\n",
                    isnan(cc_rerun) ? NaN : cc_rerun,
                    isnan(cc_anal)  ? NaN : cc_anal)

            # Compare with M3
            m3_cc_r, m3_cc_a = get(m3_ref, (case, δ), (NaN, NaN))
            err_rerun = (isnan(cc_rerun) || isnan(m3_cc_r)) ? NaN : cc_rerun - m3_cc_r
            err_anal  = (isnan(cc_anal)  || isnan(m3_cc_a)) ? NaN : cc_anal  - m3_cc_a

            push!(all_rows, (
                case                              = case,
                model                             = mlabel,
                model_internal                    = mname,
                n_scen                            = n_scen,
                delta_mw                          = δ,
                eue_baseline_mwh                  = eue_base,
                eue_plus_storage_mwh              = eue_stor,
                eue_plus_perfect_rerun_mwh        = eue_perf_rerun,
                eue_plus_perfect_analytical_mwh   = eue_perf_anal,
                delta_eue_storage_mwh             = numer,
                delta_eue_perfect_rerun_mwh       = denom_rerun,
                delta_eue_perfect_analytical_mwh  = denom_anal,
                normalized_marginal_cc_rerun      = cc_rerun,
                normalized_marginal_cc_analytical = cc_anal,
                cc_error_rerun_vs_m3              = err_rerun,
                cc_error_analytical_vs_m3         = err_anal,
            ))
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

df = DataFrame(all_rows)

println("\n" * "=" ^ 70)
println("Summary — normalized marginal CC (δ = 1 MW, model-rerun denominator)")
println("=" ^ 70)
@printf("  %-24s  %-30s  %6s  %10s  %10s  %12s\n",
        "Case", "Model", "N", "CC_rerun", "CC_anal", "Err_vs_M3")
println("  " * "─" ^ 98)
for row in eachrow(sort(filter(r -> r.delta_mw == 1.0, df), [:case, :model_internal]))
    @printf("  %-24s  %-30s  %6d  %10.5f  %10.5f  %+12.5f\n",
            row.case, row.model,
            row.n_scen,
            isnan(row.normalized_marginal_cc_rerun)      ? 0.0 : row.normalized_marginal_cc_rerun,
            isnan(row.normalized_marginal_cc_analytical)  ? 0.0 : row.normalized_marginal_cc_analytical,
            isnan(row.cc_error_rerun_vs_m3)               ? 0.0 : row.cc_error_rerun_vs_m3)
end

if any(m3_ref) do kv; true end
    println("\nM3 reference (from script 59):")
    for ((c, δ), (cc_r, cc_a)) in sort(collect(m3_ref), by=x -> (x[1][1], x[1][2]))
        δ == 1.0 || continue
        @printf("  %-24s  %-30s  %6s  %10.5f  %10.5f\n",
                c, "Full-year ED (M3)", "—", cc_r, cc_a)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Save
# ─────────────────────────────────────────────────────────────────────────────

csv_path = joinpath(TAB_DIR, "marginal_cc_all_methods_rerun.csv")
CSV.write(csv_path, df)
println("\nSaved: $csv_path")
println("Done.")
