#!/usr/bin/env julia
# 55_marginal_capacity_credit.jl
#
# Normalized marginal storage capacity-credit diagnostic.
#
# Replaces the average-reliability-value diagnostic (script 53).
#
# For each storage-dispatch method m, case, and increment δ:
#
#   CC_m(δ) = [EUE_m(x) − EUE_m(x + δ_storage)] /
#              [EUE_m(x) − EUE_m(x + δ_perfect)]
#
# where:
#   x             = existing 983 MW / 3932 MWh storage portfolio
#   δ_storage     = δ MW power / (4δ MWh energy, four-hour duration)
#   δ_perfect     = δ MW perfectly available firm resource (analytical CRN)
#
# Analytical perfect-resource denominator — common random numbers guaranteed:
#   shed_after_perfect[h] = max(0, shed_baseline[h] − δ)
#
# δ_storage requires one fresh dispatch run per (method, case, δ).
# All runs use the same availability matrix (scenario set) generated from
# the original system at N=20, seed=42.
#
# Primary metric:   δ = 1 MW (normalized marginal capacity credit)
# Sensitivity:      δ = 5, 10 MW (finite-difference approximation)
#
# Methods: M1c (emergency-only), M2 (event-window LP), M3 (full-year ED)
# Cases:   VRE120_base, VRE120_wind_hvy
# N=20, seed=42
#
# Outputs:
#   results/paper_tables/storage_marginal_capacity_credit.csv
#
# Usage:
#   julia --project=. scripts/55_marginal_capacity_credit.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASES      = ["VRE120_base", "VRE120_wind_hvy"]
const N_SCEN     = 20
const SEED       = 42
const DURATION_H = 4.0               # four-hour duration for marginal storage
const DELTA_MWS  = [1.0, 5.0, 10.0] # primary = 1, sensitivity = 5, 10
const METHODS    = ["M1c", "M2", "M3"]

const RISK_MARGIN_MW      = 1000.0   # M2 recommended config
const WINDOW_BUFFER_HOURS = 48

const DATA_ROOT = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))
const TAB_DIR   = abspath(joinpath(@__DIR__, "..", "results", "paper_tables"))

mkpath(TAB_DIR)

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Mean EUE (MWh/yr) across scenarios.
function eue_mean(results::Vector{DispatchResult})::Float64
    isempty(results) && return 0.0
    return mean(sum(r.load_shed) for r in results)
end

# Analytical EUE after adding δ MW of perfect firm capacity to the dispatch
# results.  Uses the same scenario load-shed vectors → CRN guaranteed.
#   shed_after_perfect[h,ω] = max(0, shed_base[h,ω] − δ)
function eue_after_perfect(results::Vector{DispatchResult}, delta_mw::Float64)::Float64
    n = length(results)
    n == 0 && return 0.0
    total = 0.0
    for r in results
        for v in r.load_shed
            d = v - delta_mw
            total += d > 0.0 ? d : 0.0
        end
    end
    return total / n
end

# Append one marginal storage unit to sys.storage.
# Efficiency matches existing battery (round-trip ≈ 90 %).
function with_marginal_storage(sys::SystemData, delta_mw::Float64;
                                duration_h::Float64 = DURATION_H)::SystemData
    eta   = sqrt(0.90)
    e_mwh = delta_mw * duration_h
    extra = DataFrame(
        storage_id            = ["MARGINAL_$(delta_mw)MW_$(duration_h)H"],
        power_mw              = [delta_mw],
        energy_mwh            = [e_mwh],
        charge_efficiency     = [eta],
        discharge_efficiency  = [eta],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [e_mwh * 0.5],   # 50 % initial SOC
    )
    return SystemData(sys.generators, vcat(sys.storage, extra),
                      sys.load_mw, sys.wind_cf, sys.solar_cf, sys.n_hours)
end

# Run named method using a pre-generated Int8 availability matrix.
# Passing the same availability to all calls guarantees common random numbers.
function run_dispatch(method::String, sys::SystemData,
                      avail::Array{Int8, 3},
                      base_cfg::SimConfig, m2_cfg::SimConfig)::Vector{DispatchResult}
    if method == "M1c"
        return run_m1c_emergency_only(sys, avail, base_cfg)
    elseif method == "M2"
        return first(run_m2_with_diagnostics(sys, avail, m2_cfg))
    elseif method == "M3"
        return run_m3_ed_dispatch(sys, avail, base_cfg)
    else
        error("Unknown method: $method")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 70)
println("55_marginal_capacity_credit.jl")
println("Date: ", Dates.now())
println("Cases:   ", join(CASES, ", "))
println("Methods: ", join(METHODS, ", "))
println("δ (MW):  ", join(DELTA_MWS, ", "), "  [1 MW = primary; 5/10 MW = sensitivity]")
println("Storage duration: $(DURATION_H) h  (four-hour)")
println("N=$(N_SCEN), seed=$(SEED)")
println("M2: risk_margin=$(RISK_MARGIN_MW) MW, buffer=$(WINDOW_BUFFER_HOURS) h")
println("=" ^ 70)

all_rows = NamedTuple[]

for case in CASES
    println("\n─── $case " * "─" ^ max(0, 50 - length(case)))
    case_dir = joinpath(DATA_ROOT, case)
    isdir(case_dir) || error("Case directory not found: $case_dir")

    sys      = load_system_data(case_dir)
    base_cfg = SimConfig(n_scenarios = N_SCEN, seed = SEED)
    m2_cfg   = SimConfig(n_scenarios = N_SCEN, seed = SEED,
                         risk_margin_mw      = RISK_MARGIN_MW,
                         window_buffer_hours = WINDOW_BUFFER_HOURS)

    print("  Generating scenarios (N=$(N_SCEN), seed=$(SEED)) … ")
    scen  = generate_scenarios(sys, base_cfg)
    avail = scen.availability          # Array{Int8,3}: [N, n_thermal, 8760]
    println("n_thermal=$(scen.n_thermal)")

    for method in METHODS
        println("\n  ─ $method ─────────────────────────────────────────────────")

        # ── Baseline: existing storage (983 MW / 3932 MWh) ─────────────────
        t0 = time()
        print("    baseline … ")
        res_base = run_dispatch(method, sys, avail, base_cfg, m2_cfg)
        eue_base = eue_mean(res_base)
        println(@sprintf("EUE_base = %10.3f MWh  (%.1f s)", eue_base, time() - t0))

        for δ in DELTA_MWS

            # ── Perfect-firm denominator (analytical, no extra run) ─────────
            eue_perf = eue_after_perfect(res_base, δ)
            denom    = eue_base - eue_perf   # marginal EUE reduction from δ MW perfect

            # ── Marginal-storage numerator ──────────────────────────────────
            sys_m = with_marginal_storage(sys, δ)
            t0    = time()
            print("    +$(δ) MW/$(δ * DURATION_H) MWh storage … ")
            res_m = run_dispatch(method, sys_m, avail, base_cfg, m2_cfg)
            eue_m = eue_mean(res_m)
            numer = eue_base - eue_m

            cc = denom > 1e-9 ? numer / denom : NaN

            println(@sprintf(
                "ΔEUEstor=%8.4f  ΔEUEperf=%8.4f  CC=%8.5f  (%.1f s)",
                numer, denom, isnan(cc) ? NaN : cc, time() - t0))

            push!(all_rows, (
                case                    = case,
                baseline_type           = "existing_storage",
                delta_mw                = δ,
                method                  = method,
                eue_baseline_mwh        = eue_base,
                eue_plus_storage_mwh    = eue_m,
                eue_plus_perfect_mwh    = eue_perf,
                delta_eue_storage_mwh   = numer,
                delta_eue_perfect_mwh   = denom,
                normalized_marginal_cc  = cc,
                cc_error_vs_full_year_ed = NaN,
            ))
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Fill cc_error_vs_full_year_ed
# ─────────────────────────────────────────────────────────────────────────────

df = DataFrame(all_rows)
df[!, :cc_error_vs_full_year_ed] = fill(NaN, size(df, 1))

for case_name in unique(df.case)
    for δ in unique(df.delta_mw)
        m3_mask = (df.case .== case_name) .& (df.method .== "M3") .& (df.delta_mw .== δ)
        any(m3_mask) || continue
        cc_m3 = df[m3_mask, :normalized_marginal_cc][1]
        isnan(cc_m3) && continue
        mask = (df.case .== case_name) .& (df.delta_mw .== δ)
        for i in findall(mask)
            cc_i = df[i, :normalized_marginal_cc]
            df[i, :cc_error_vs_full_year_ed] = isnan(cc_i) ? NaN : cc_i - cc_m3
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Print summary
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 70)
println("Summary — normalized marginal CC (δ = 1 MW, existing-storage baseline)")
println("=" ^ 70)
println(@sprintf("  %-24s  %-5s  %12s  %10s  %12s",
                 "Case", "M", "EUE_base(MWh)", "CC (1MW)", "Err vs M3"))
println("  " * "─" ^ 70)
df1 = filter(r -> r.delta_mw == 1.0, df)
for row in eachrow(df1)
    println(@sprintf("  %-24s  %-5s  %12.3f  %10.5f  %+12.5f",
                     row.case, row.method,
                     row.eue_baseline_mwh,
                     isnan(row.normalized_marginal_cc) ? 0.0 : row.normalized_marginal_cc,
                     isnan(row.cc_error_vs_full_year_ed) ? 0.0 : row.cc_error_vs_full_year_ed))
end

println("\nSensitivity (δ = 5, 10 MW):")
println(@sprintf("  %-24s  %-5s  %6s  %10s  %12s",
                 "Case", "M", "δ(MW)", "CC", "Err vs M3"))
println("  " * "─" ^ 62)
df_sens = filter(r -> r.delta_mw in [5.0, 10.0], df)
for row in eachrow(df_sens)
    println(@sprintf("  %-24s  %-5s  %6.0f  %10.5f  %+12.5f",
                     row.case, row.method, row.delta_mw,
                     isnan(row.normalized_marginal_cc) ? 0.0 : row.normalized_marginal_cc,
                     isnan(row.cc_error_vs_full_year_ed) ? 0.0 : row.cc_error_vs_full_year_ed))
end

# ─────────────────────────────────────────────────────────────────────────────
# Save
# ─────────────────────────────────────────────────────────────────────────────

csv_path = joinpath(TAB_DIR, "storage_marginal_capacity_credit.csv")
CSV.write(csv_path, df)
println("\nSaved: $csv_path")
println("Done.")
