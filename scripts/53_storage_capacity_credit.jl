#!/usr/bin/env julia
# 53_storage_capacity_credit.jl
#
# Storage capacity-credit / accreditation diagnostic.
#
# Computes a PJM-style storage reliability value for each storage-aware
# sequential MCS method: the ratio of EUE improvement from storage to the
# improvement from an incremental perfect (FOR = 0) resource of the same size.
#
# For each case and method m:
#
#   PJM_ratio_m = (EUE_base − EUE_storage_m) / (EUE_base − EUE_perfect_X)
#
# where X = 100 MW (primary) and 500 MW (sensitivity).
#
# EUE_perfect_X is derived analytically from the MC-NoStorage hourly load-shed
# vectors, exploiting the additive structure of the capacity-balance check:
#
#   shed_with_perfect[s,h] = max(0, shed_base[s,h] − X)
#
# This guarantees perfect common random numbers — no separate scenario
# generation is required for the perfect-resource case.
#
# Equivalent firm capacity (EFC) is found by bisection: the firm MW that gives
# the same EUE as the storage case when added to the no-storage base.
#
# Storage method EUE values are loaded from existing committed CSVs; no new
# M1c / M2 / M3 runs are needed.
#
# Key result: methods that match full-year ED EUE (M1c, M2, M3) also produce
# identical PJM-style reliability value and EFC.  Naive heuristics (M1, M1b)
# have near-zero capacity credit because they waste stored energy before events.
#
# Outputs:
#   results/paper_tables/storage_capacity_credit_comparison.csv   (committed)
#
# Usage:
#   julia --project=. scripts/53_storage_capacity_credit.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASES    = ["VRE120_base", "VRE120_wind_hvy"]
const N_SCEN   = 20
const SEED     = 42
const FIRM_MWS = [100.0, 500.0]   # perfect-resource sizes for sensitivity

const DATA_ROOT  = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))
const TAB_DIR    = abspath(joinpath(@__DIR__, "..", "results", "paper_tables"))

mkpath(TAB_DIR)

# Committed source CSVs (no rerun needed)
const M1D_CSV   = abspath(joinpath(@__DIR__, "..",
    "results", "m1d_storage_heuristic_comparison", "m1d_aggregate_metrics.csv"))
const M1M1B_CSV = abspath(joinpath(@__DIR__, "..",
    "results", "m1_m1b_n20_paper", "m1_m1b_aggregate_metrics.csv"))

# Methods to include (in display order)
const METHODS = ["M1", "M1b", "M1c", "M2", "M3"]

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

function load_storage_eue()::Dict{Tuple{String,String}, Float64}
    d = Dict{Tuple{String,String}, Float64}()
    for path in (M1D_CSV, M1M1B_CSV)
        isfile(path) || error("Committed CSV not found: $path")
        df = CSV.read(path, DataFrame)
        for row in eachrow(df)
            d[(String(row.model), String(row.case))] = Float64(row.eue_mwh)
        end
    end
    return d
end

# EUE when firm_mw of always-available capacity is added to the no-storage base.
# Derived analytically: shed_perfect[s,h] = max(0, shed_base[s,h] − firm_mw).
function eue_with_perfect(results::Vector{DispatchResult}, firm_mw::Float64)::Float64
    n = length(results)
    n == 0 && return 0.0
    total = 0.0
    if firm_mw == 0.0
        for r in results
            total += sum(r.load_shed)
        end
    else
        for r in results
            for v in r.load_shed
                d = v - firm_mw
                total += d > 0.0 ? d : 0.0
            end
        end
    end
    return total / n
end

# Bisection: find firm_mw s.t. eue_with_perfect(results, firm_mw) ≈ target_eue.
# Returns the equivalent firm capacity (EFC) in MW.
function compute_efc(results::Vector{DispatchResult}, target_eue::Float64;
                     hi::Float64 = 20000.0, tol::Float64 = 0.1)::Float64
    lo     = 0.0
    eue_lo = eue_with_perfect(results, lo)
    # Guard: target ≥ base EUE → no improvement → EFC = 0
    target_eue >= eue_lo - tol && return 0.0
    # Guard: target ≤ EUE at hi → still above target → return hi as lower bound
    eue_hi = eue_with_perfect(results, hi)
    if target_eue <= eue_hi + tol
        return hi
    end
    for _ in 1:80
        hi - lo < 0.01 && break
        mid     = (lo + hi) / 2.0
        eue_mid = eue_with_perfect(results, mid)
        abs(eue_mid - target_eue) < tol && return mid
        eue_mid > target_eue ? (lo = mid) : (hi = mid)
    end
    return (lo + hi) / 2.0
end

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 70)
println("53_storage_capacity_credit.jl")
println("Date: ", Dates.now())
println("Cases: ", join(CASES, ", "))
println("Firm resource sizes: ", join(Int.(FIRM_MWS), " MW, "), " MW")
println("Methods: ", join(METHODS, ", "))
println("=" ^ 70)

storage_eue = load_storage_eue()
all_rows    = NamedTuple[]

for case in CASES
    println("\n─── $case " * "─" ^ max(0, 50 - length(case)))
    case_dir = joinpath(DATA_ROOT, case)
    isdir(case_dir) || error("Case directory not found: $case_dir")

    sys  = load_system_data(case_dir)
    cfg  = SimConfig(n_scenarios=N_SCEN, seed=SEED)
    scen = generate_scenarios(sys, cfg)
    println("  n_thermal = $(scen.n_thermal)")

    # ── Base: MC-NoStorage ──────────────────────────────────────────────────
    t0 = time()
    print("  MC-NoStorage (N=$N_SCEN, seed=$SEED) … ")
    results_base = run_mc_no_storage(sys, scen.availability, cfg)
    eue_base     = eue_with_perfect(results_base, 0.0)
    println(@sprintf("EUE_base = %.2f MWh  (%.1f s)", eue_base, time() - t0))

    # ── Perfect-resource sensitivities (analytical) ────────────────────────
    eue_perfects = Dict{Float64, Float64}()
    for fw in FIRM_MWS
        ep = eue_with_perfect(results_base, fw)
        eue_perfects[fw] = ep
        println(@sprintf("  EUE_perfect_%dMW = %.2f MWh  (improvement = %.2f MWh)",
                         Int(fw), ep, eue_base - ep))
    end

    denom_100 = eue_base - eue_perfects[100.0]
    denom_500 = eue_base - eue_perfects[500.0]

    # ── Reference (M3) ─────────────────────────────────────────────────────
    eue_m3   = get(storage_eue, ("M3", case), NaN)
    impr_m3  = eue_base - eue_m3
    ref_ratio_100 = denom_100 > 1e-6 ? impr_m3 / denom_100 : NaN

    println(@sprintf("\n  %-8s  %12s  %12s  %12s  %12s  %12s",
                     "Method", "EUE_storage", "ratio_100MW", "ratio_500MW",
                     "EFC (MW)", "err_vs_M3"))
    println("  " * "─" ^ 72)

    for method in METHODS
        eue_stor = get(storage_eue, (method, case), NaN)
        isnan(eue_stor) && continue

        impr_stor    = eue_base - eue_stor
        ratio_100    = denom_100 > 1e-6 ? impr_stor / denom_100 : NaN
        ratio_500    = denom_500 > 1e-6 ? impr_stor / denom_500 : NaN
        ratio_error  = isnan(ratio_100) || isnan(ref_ratio_100) ?
                       NaN : ratio_100 - ref_ratio_100

        efc_mw = compute_efc(results_base, eue_stor)

        println(@sprintf("  %-8s  %12.2f  %12.4f  %12.4f  %12.2f  %+12.4f",
                         method, eue_stor,
                         isnan(ratio_100) ? 0.0 : ratio_100,
                         isnan(ratio_500) ? 0.0 : ratio_500,
                         efc_mw,
                         isnan(ratio_error) ? 0.0 : ratio_error))

        push!(all_rows, (
            case                         = case,
            method                       = method,
            eue_base_mwh                 = eue_base,
            eue_storage_mwh              = eue_stor,
            eue_perfect_100mw_mwh        = eue_perfects[100.0],
            eue_perfect_500mw_mwh        = eue_perfects[500.0],
            eue_improvement_storage_mwh  = impr_stor,
            eue_improvement_100mw_mwh    = denom_100,
            pjm_ratio_100mw              = ratio_100,
            pjm_ratio_500mw              = ratio_500,
            ratio_error_vs_full_year_ed  = ratio_error,
            efc_mw                       = efc_mw,
        ))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Save
# ─────────────────────────────────────────────────────────────────────────────

df_out   = DataFrame(all_rows)
csv_path = joinpath(TAB_DIR, "storage_capacity_credit_comparison.csv")
CSV.write(csv_path, df_out)
println("\nSaved: $csv_path")
println("Done.")
