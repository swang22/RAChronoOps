#!/usr/bin/env julia
# 70_market_pattern_marginal_cc.jl
#
# Marginal capacity credit (CC) and Table IV rows for market-pattern storage.
#
# CC formula (consistent with scripts 61/64):
#   CC(δ) = [EUE(x) − EUE(x+ΔS)] / [EUE(x) − EUE(x+ΔF)]
#   Denominator: explicit perfect-firm rerun with CRN (common random numbers).
#
# Methods: MP_pure_cur, MP_emergency_cur, M1c (reference)
# Cases:   VRE120_base, VRE120_wind_hvy
# δ:       1, 5, 10 MW
# N:       nested — generate N_MAX=1000 once; subsample first N for each N in N_SIZES
#
# Calibration: pattern_energy_balanced.csv (preferred per calibration_audit.md)
# SOC init:    cyclic fixed-point = 23.1% (per soc_boundary_study.csv / script 72)
#
# Outputs:
#   results/market_pattern_cc/scenario_level_cc_components.csv
#   results/market_pattern_cc/policy_switching_diagnostics.csv
#   results/paper_tables/market_pattern_capacity_credit.csv
#   results/paper_tables/market_pattern_table_iv_rows.csv
#
# Usage:
#   julia --project=. scripts/70_market_pattern_marginal_cc.jl [--with-m2]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics, Printf, Dates, Random

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASES       = ["VRE120_base", "VRE120_wind_hvy"]
const CASE_LABELS = Dict("VRE120_base" => "Balanced VRE", "VRE120_wind_hvy" => "Wind-heavy")

const N_MAX        = 1000
const N_SIZES      = [20, 50, 100, 200, 500, 1000]
const SEED         = 42

const DELTA_MWS   = [1.0, 5.0, 10.0]
const DURATION_H  = 4.0      # storage duration for CC increment (matches scripts 61/64)

const CYCLIC_SOC_FRAC = 0.231   # energy-balanced pattern fixed point (docs/market_pattern_calibration_audit.md)

const M2_RISK_MW  = 1000.0
const M2_BUF_H    = 48

const BOOT_SAMPLES = 2000
const BOOT_SEED    = 1234

const METHODS = [
    # (label, paper_name, emergency_override, charge_curtailed)
    ("MP_pure_cur",      "Market-pattern storage MCS",             false, true),
    ("MP_emergency_cur", "Market-pattern + emergency storage MCS", true,  true),
    ("M1c",              "Emergency-only storage MCS",             false, false),
]

const CALIBRATION_VERSION = "pattern_energy_balanced"

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

WITH_M2 = "--with-m2" in ARGS

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

const REPO       = abspath(joinpath(@__DIR__, ".."))
const DATA_ROOT  = joinpath(REPO, "data_processed", "cases")
const PT_DIR     = joinpath(REPO, "results", "paper_tables")
const MPC_DIR    = joinpath(REPO, "results", "market_pattern_cc")
const PAT_CSV    = joinpath(REPO, "data_processed", "caiso_storage_patterns",
                             "pattern_energy_balanced.csv")

mkpath(PT_DIR)
mkpath(MPC_DIR)
isfile(PAT_CSV) || error("Energy-balanced pattern CSV not found: $PAT_CSV\n" *
                          "Run scripts/build_caiso_storage_patterns.py first.")

# Git commit for provenance
const CODE_COMMIT = try
    strip(read(Cmd(["git", "-C", REPO, "rev-parse", "--short", "HEAD"]), String))
catch
    "unknown"
end

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────

function with_marginal_storage(sys::SystemData, δ::Float64;
                                dur::Float64    = DURATION_H,
                                soc_frac::Float64 = CYCLIC_SOC_FRAC)::SystemData
    eta   = sqrt(0.90)
    extra = DataFrame(
        storage_id            = ["MARG_$(δ)MW"],
        power_mw              = [δ],
        energy_mwh            = [δ * dur],
        charge_efficiency     = [eta],
        discharge_efficiency  = [eta],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [δ * dur * soc_frac],
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

function avail_with_perfect_firm(avail::Array{Int8,3})::Array{Int8,3}
    N, _, T = size(avail)
    return cat(avail, ones(Int8, N, 1, T); dims=2)
end

eue_per_scen(results::Vector{DispatchResult})::Vector{Float64} =
    [sum(r.load_shed) for r in results]

function subcfg(n::Int)::SimConfig
    return SimConfig(n_scenarios=n, seed=SEED,
                     risk_margin_mw=M2_RISK_MW,
                     window_buffer_hours=M2_BUF_H,
                     merge_gap_hours=24,
                     min_window_length_hours=24)
end

function run_dispatch(method::String, sys::SystemData,
                      avail::Array{<:Integer,3}, cfg::SimConfig)
    if method == "M1c"
        return run_m1c_emergency_only(sys, avail, cfg), nothing, nothing
    elseif method == "M2"
        return run_m2_event_window_lp(sys, avail, cfg), nothing, nothing
    else
        emerg     = (method == "MP_emergency_cur")
        curtailed = true
        return run_market_pattern_storage(sys, avail, cfg;
                                          pattern_csv            = PAT_CSV,
                                          emergency_override     = emerg,
                                          charge_curtailed       = curtailed,
                                          override_init_soc_frac = CYCLIC_SOC_FRAC)
    end
end

"""
Paired bootstrap resampling of CC = numerator / denominator.
Returns named tuple with cc estimate, 95% CI, denominator CI, status, and n_valid.

Status is "unstable/not identified" when the 95% CI of the denominator includes zero,
indicating that the firm-increment effect is not reliably identified at this sample size.
"""
function bootstrap_cc_paired(eue_base::Vector{Float64},
                              eue_stor::Vector{Float64},
                              eue_firm::Vector{Float64};
                              n_boot::Int = BOOT_SAMPLES,
                              boot_seed::Int = BOOT_SEED)
    N   = length(eue_base)
    rng = MersenneTwister(boot_seed)

    cc_boots    = Vector{Float64}(undef, n_boot)
    denom_boots = Vector{Float64}(undef, n_boot)
    numer_boots = Vector{Float64}(undef, n_boot)

    for b in 1:n_boot
        idx    = rand(rng, 1:N, N)
        numer  = mean(eue_base[idx]) - mean(eue_stor[idx])
        denom  = mean(eue_base[idx]) - mean(eue_firm[idx])
        numer_boots[b] = numer
        denom_boots[b] = denom
        cc_boots[b]    = denom > 1e-12 ? numer / denom : NaN
    end

    denom_lo = quantile(denom_boots, 0.025)
    denom_hi = quantile(denom_boots, 0.975)
    denom_stable = denom_lo > 0.0

    valid_ccs  = filter(!isnan, cc_boots)
    n_valid    = length(valid_ccs)
    status     = (denom_stable && n_valid >= n_boot * 0.9) ? "identified" :
                 "unstable/not identified"

    if n_valid == 0
        return (cc=NaN, ci_lo=NaN, ci_hi=NaN,
                denom_ci_lo=denom_lo, denom_ci_hi=denom_hi,
                status=status, n_valid_boots=0)
    end

    cc_lo = quantile(valid_ccs, 0.025)
    cc_hi = quantile(valid_ccs, 0.975)
    return (cc=mean(valid_ccs), ci_lo=cc_lo, ci_hi=cc_hi,
            denom_ci_lo=denom_lo, denom_ci_hi=denom_hi,
            status=status, n_valid_boots=n_valid)
end

# ─────────────────────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 72)
println("70_market_pattern_marginal_cc.jl")
println("Date:      ", Dates.now())
println("Commit:    ", CODE_COMMIT)
println("N_MAX:     ", N_MAX, "  N_SIZES: ", join(N_SIZES, ","))
println("δ (MW):    ", join(DELTA_MWS, ", "))
println("Bootstrap: ", BOOT_SAMPLES, " samples (seed=", BOOT_SEED, ")")
println("Calibration: ", CALIBRATION_VERSION)
println("SOC init:  cyclic fixed-point = ", CYCLIC_SOC_FRAC)
println("=" ^ 72)

# Accumulate output rows
cc_rows     = NamedTuple[]   # aggregate CC per (case, method, N, δ)
scen_rows   = NamedTuple[]   # per-scenario CC components at N_MAX
switch_rows = NamedTuple[]   # policy switching diagnostics (MP_emergency_cur only)
tab4_rows   = NamedTuple[]   # Table IV rows (N=20 only)

for cname in CASES
    cdir = joinpath(DATA_ROOT, cname)
    isdir(cdir) || error("Case directory not found: $cdir")
    sys  = load_system_data(cdir)
    cfg_max = subcfg(N_MAX)

    println("\n" * "─" ^ 72)
    println("Case: $cname  N_MAX=$N_MAX")
    println("─" ^ 72)

    # Generate N_MAX scenarios once — first N scenarios used for each N in N_SIZES
    scen_max      = generate_scenarios(sys, cfg_max)
    avail_max     = scen_max.availability            # (N_MAX, n_therm, T)
    avail_firm_max = avail_with_perfect_firm(avail_max)

    for (method, paper_name, _, _) in METHODS
        println("\n  Method: $method")

        # ── Run base system at N_MAX ──────────────────────────────────────────
        t0 = time()
        results_base, _, eue_decomp_base = run_dispatch(method, sys, avail_max, cfg_max)
        rt_base = time() - t0
        eue_base_all = eue_per_scen(results_base)  # length N_MAX
        @printf("    base N=%d  EUE_mean=%.2f MWh  (%.1f s)\n",
                N_MAX, mean(eue_base_all), rt_base)

        # ── Policy switching diagnostics (MP_emergency_cur only) ──────────────
        if method == "MP_emergency_cur" && !isnothing(eue_decomp_base)
            d = eue_decomp_base
            push!(switch_rows, (
                portfolio              = cname,
                case_label             = CASE_LABELS[cname],
                method                 = method,
                N                      = N_MAX,
                seed                   = SEED,
                calibration_version    = CALIBRATION_VERSION,
                cyclic_soc_frac        = CYCLIC_SOC_FRAC,
                total_eue              = d.total_eue,
                pre_storage_shortfall_eue = d.pre_storage_shortfall_eue,
                missed_discharge_eue   = d.missed_discharge_eue,
                charging_induced_eue   = d.charging_induced_eue,
                low_soc_shortfall_eue  = d.low_soc_shortfall_eue,
                pre_storage_pct        = d.pre_storage_pct,
                missed_discharge_pct   = d.missed_discharge_pct,
                charging_induced_pct   = d.charging_induced_pct,
                low_soc_pct            = d.low_soc_pct,
                code_commit            = CODE_COMMIT,
            ))
        end

        for δ in DELTA_MWS
            sys_s = with_marginal_storage(sys, δ)
            sys_f = with_perfect_firm(sys, δ)

            # ── Run +δS at N_MAX ──────────────────────────────────────────────
            t0 = time()
            results_stor, _, _ = run_dispatch(method, sys_s, avail_max, cfg_max)
            rt_s = time() - t0
            eue_stor_all = eue_per_scen(results_stor)

            # ── Run +δF at N_MAX ──────────────────────────────────────────────
            t0 = time()
            results_firm, _, _ = run_dispatch(method, sys_f, avail_firm_max, cfg_max)
            rt_f = time() - t0
            eue_firm_all = eue_per_scen(results_firm)

            eue_b_mean = mean(eue_base_all)
            eue_s_mean = mean(eue_stor_all)
            eue_f_mean = mean(eue_firm_all)
            delta_stor_full = eue_b_mean - eue_s_mean
            delta_firm_full = eue_b_mean - eue_f_mean
            cc_full = delta_firm_full > 1e-9 ? delta_stor_full / delta_firm_full : NaN
            @printf("    δ=%2.0f MW  ΔEUE_stor=%7.3f  ΔEUE_firm=%7.3f  CC=%7.4f  (stor %.1f s, firm %.1f s)\n",
                    δ, delta_stor_full, delta_firm_full, isnan(cc_full) ? -999.0 : cc_full, rt_s, rt_f)

            # ── Save per-scenario CC components at N_MAX ──────────────────────
            for i in 1:N_MAX
                push!(scen_rows, (
                    portfolio    = cname,
                    method       = method,
                    delta_mw     = δ,
                    scenario_idx = i,
                    eue_base_mwh  = eue_base_all[i],
                    eue_stor_mwh  = eue_stor_all[i],
                    eue_firm_mwh  = eue_firm_all[i],
                    delta_stor_mwh = eue_base_all[i] - eue_stor_all[i],
                    delta_firm_mwh = eue_base_all[i] - eue_firm_all[i],
                ))
            end

            # ── Per-N bootstrap CC ────────────────────────────────────────────
            for N in N_SIZES
                eue_b = eue_base_all[1:N]
                eue_s = eue_stor_all[1:N]
                eue_f = eue_firm_all[1:N]

                eue_base_pt = mean(eue_b)
                delta_stor  = eue_base_pt - mean(eue_s)
                delta_firm  = eue_base_pt - mean(eue_f)
                cc_pt       = delta_firm > 1e-9 ? delta_stor / delta_firm : NaN

                boot = bootstrap_cc_paired(eue_b, eue_s, eue_f)

                push!(cc_rows, (
                    portfolio              = cname,
                    case_label             = CASE_LABELS[cname],
                    method                 = method,
                    paper_name             = paper_name,
                    N                      = N,
                    seed                   = SEED,
                    delta_mw               = δ,
                    eue_base_mwh           = eue_base_pt,
                    eue_storage_increment_mwh = mean(eue_s),
                    eue_firm_increment_mwh = mean(eue_f),
                    delta_eue_storage      = delta_stor,
                    delta_eue_firm         = delta_firm,
                    cc                     = cc_pt,
                    cc_bootstrap_mean      = boot.cc,
                    cc_ci_lo               = boot.ci_lo,
                    cc_ci_hi               = boot.ci_hi,
                    denom_ci_lo            = boot.denom_ci_lo,
                    denom_ci_hi            = boot.denom_ci_hi,
                    denominator_status     = boot.status,
                    n_bootstrap_valid      = boot.n_valid_boots,
                    n_bootstrap_total      = BOOT_SAMPLES,
                    calibration_version    = CALIBRATION_VERSION,
                    cyclic_soc_frac        = CYCLIC_SOC_FRAC,
                    code_commit            = CODE_COMMIT,
                ))
            end
        end  # δ loop

        # ── Table IV row at N=20 (paper N, δ=1 MW) ───────────────────────────
        # Use first 20 of the N_MAX run (same scenarios by nested construction);
        # avoids a redundant dispatch call.  For calibrated runtime use script 71.
        begin
            N20 = 20
            results20 = results_base[1:N20]
            m20 = compute_metrics(results20, sys)
            rt_per_scen_est = rt_base / N_MAX   # rough estimate; script 71 gives IQR

            cc_entry = filter(r -> r.portfolio == cname &&
                                   r.method == method &&
                                   r.N == N20 &&
                                   r.delta_mw == 1.0, cc_rows)
            cc20      = isempty(cc_entry) ? NaN : cc_entry[1].cc
            cc_lo     = isempty(cc_entry) ? NaN : cc_entry[1].cc_ci_lo
            cc_hi     = isempty(cc_entry) ? NaN : cc_entry[1].cc_ci_hi
            cc_status = isempty(cc_entry) ? "" : cc_entry[1].denominator_status
            cc_numer  = isempty(cc_entry) ? NaN : cc_entry[1].delta_eue_storage
            cc_denom  = isempty(cc_entry) ? NaN : cc_entry[1].delta_eue_firm

            push!(tab4_rows, (
                portfolio           = cname,
                method              = method,
                paper_name          = paper_name,
                N                   = N20,
                seed                = SEED,
                lolh_hours          = m20.lolh,
                eue_mwh             = m20.eue,
                neue_ppm            = m20.neue * 1e6,
                cvar_eue_mwh        = m20.cvar_eue,
                lolh_ci95_hw        = m20.lolh_ci95_halfwidth,
                eue_ci95_hw         = m20.eue_ci95_halfwidth,
                runtime_median      = rt_per_scen_est,   # s/scenario from N_MAX run
                runtime_IQR         = NaN,               # run script 71 for IQR
                cc                  = cc20,
                cc_lower_95         = cc_lo,
                cc_upper_95         = cc_hi,
                cc_status           = cc_status,
                cc_numerator_mwh    = cc_numer,
                cc_denominator_mwh  = cc_denom,
                calibration_version = CALIBRATION_VERSION,
                code_commit         = CODE_COMMIT,
            ))
        end
    end  # method loop

    # ── M2 benchmark (optional, slow) ────────────────────────────────────────
    if WITH_M2
        println("\n  Method: M2 (event-window LP, optional benchmark)")
        m2cfg_max = SimConfig(n_scenarios=N_MAX, seed=SEED,
                              risk_margin_mw=M2_RISK_MW,
                              window_buffer_hours=M2_BUF_H,
                              merge_gap_hours=24, min_window_length_hours=24)

        t0 = time()
        results_m2_base = run_m2_event_window_lp(sys, avail_max, m2cfg_max)
        rt_m2 = time() - t0
        eue_base_m2 = eue_per_scen(results_m2_base)
        @printf("    M2 base N=%d  EUE_mean=%.2f MWh  (%.1f s)\n",
                N_MAX, mean(eue_base_m2), rt_m2)

        for δ in DELTA_MWS
            sys_s = with_marginal_storage(sys, δ)
            sys_f = with_perfect_firm(sys, δ)

            results_m2_s = run_m2_event_window_lp(sys_s, avail_max, m2cfg_max)
            results_m2_f = run_m2_event_window_lp(sys_f, avail_firm_max, m2cfg_max)
            eue_stor_m2 = eue_per_scen(results_m2_s)
            eue_firm_m2 = eue_per_scen(results_m2_f)

            for N in N_SIZES
                eue_b = eue_base_m2[1:N]
                eue_s = eue_stor_m2[1:N]
                eue_f = eue_firm_m2[1:N]
                delta_stor  = mean(eue_b) - mean(eue_s)
                delta_firm  = mean(eue_b) - mean(eue_f)
                cc_pt = delta_firm > 1e-9 ? delta_stor / delta_firm : NaN
                boot  = bootstrap_cc_paired(eue_b, eue_s, eue_f)

                push!(cc_rows, (
                    portfolio              = cname,
                    case_label             = CASE_LABELS[cname],
                    method                 = "M2",
                    paper_name             = "Event-window storage MCS",
                    N                      = N,
                    seed                   = SEED,
                    delta_mw               = δ,
                    eue_base_mwh           = mean(eue_b),
                    eue_storage_increment_mwh = mean(eue_s),
                    eue_firm_increment_mwh = mean(eue_f),
                    delta_eue_storage      = delta_stor,
                    delta_eue_firm         = delta_firm,
                    cc                     = cc_pt,
                    cc_bootstrap_mean      = boot.cc,
                    cc_ci_lo               = boot.ci_lo,
                    cc_ci_hi               = boot.ci_hi,
                    denom_ci_lo            = boot.denom_ci_lo,
                    denom_ci_hi            = boot.denom_ci_hi,
                    denominator_status     = boot.status,
                    n_bootstrap_valid      = boot.n_valid_boots,
                    n_bootstrap_total      = BOOT_SAMPLES,
                    calibration_version    = "N/A",
                    cyclic_soc_frac        = NaN,
                    code_commit            = CODE_COMMIT,
                ))
            end
        end
    end
end  # case loop

# ─────────────────────────────────────────────────────────────────────────────
# Finite-difference check: CC should be consistent across δ=1,5,10 MW
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 72)
println("Finite-difference check: CC vs δ (N=$N_MAX, nested scenarios)")
println("=" ^ 72)
@printf("  %-20s  %-18s  %5s  %8s  %8s  %8s  %8s  %-28s\n",
        "Portfolio", "Method", "N", "δ(MW)", "CC", "CI_lo", "CI_hi", "Status")
println("  " * "─" ^ 100)
for r in filter(row -> row.N == N_MAX, cc_rows)
    @printf("  %-20s  %-18s  %5d  %8.1f  %8.4f  %8.4f  %8.4f  %-28s\n",
            r.case_label, r.method, r.N, r.delta_mw,
            isnan(r.cc) ? -999.0 : r.cc,
            isnan(r.cc_ci_lo) ? -999.0 : r.cc_ci_lo,
            isnan(r.cc_ci_hi) ? -999.0 : r.cc_ci_hi,
            r.denominator_status)
end

# ─────────────────────────────────────────────────────────────────────────────
# Write outputs
# ─────────────────────────────────────────────────────────────────────────────

cc_path     = joinpath(PT_DIR,  "market_pattern_capacity_credit.csv")
scen_path   = joinpath(MPC_DIR, "scenario_level_cc_components.csv")
switch_path = joinpath(MPC_DIR, "policy_switching_diagnostics.csv")
tab4_path   = joinpath(PT_DIR,  "market_pattern_table_iv_rows.csv")

CSV.write(cc_path,     DataFrame(cc_rows))
CSV.write(scen_path,   DataFrame(scen_rows))
CSV.write(tab4_path,   DataFrame(tab4_rows))
if !isempty(switch_rows)
    CSV.write(switch_path, DataFrame(switch_rows))
end

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 72)
println("CC summary: δ=1 MW, N=20 (paper N)")
println("=" ^ 72)
@printf("  %-20s  %-18s  %8s  %8s  %8s  %-28s\n",
        "Portfolio", "Method", "CC", "CI_lo", "CI_hi", "Status")
println("  " * "─" ^ 90)
for r in filter(row -> row.N == 20 && row.delta_mw == 1.0, cc_rows)
    @printf("  %-20s  %-18s  %8.4f  %8.4f  %8.4f  %-28s\n",
            r.case_label, r.method,
            isnan(r.cc) ? -999.0 : r.cc,
            isnan(r.cc_ci_lo) ? -999.0 : r.cc_ci_lo,
            isnan(r.cc_ci_hi) ? -999.0 : r.cc_ci_hi,
            r.denominator_status)
end

println("\n" * "=" ^ 72)
println("Table IV rows (N=20, δ=1 MW CC)")
println("=" ^ 72)
@printf("  %-20s  %-18s  %7s  %9s  %7s  %7s  %8s\n",
        "Portfolio", "Method", "LOLH", "EUE(MWh)", "NEUE", "CC", "CC_status")
println("  " * "─" ^ 80)
for r in tab4_rows
    @printf("  %-20s  %-18s  %7.2f  %9.1f  %7.3f  %7.4f  %s\n",
            r.case_label, r.method, r.lolh_hours, r.eue_mwh,
            r.neue_ppm,
            isnan(r.cc) ? -999.0 : r.cc,
            r.cc_status)
end

println("\nOutputs:")
println("  CC aggregate:      $cc_path")
println("  Scenario-level:    $scen_path")
println("  Policy switching:  $switch_path")
println("  Table IV rows:     $tab4_path")
println("Done: ", Dates.now())
