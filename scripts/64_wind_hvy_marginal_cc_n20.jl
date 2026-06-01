#!/usr/bin/env julia
# 64_wind_hvy_marginal_cc_n20.jl
#
# Recompute normalized marginal storage CC for wind-heavy VRE at N=20,
# so the main comparison table uses a consistent scenario count (N=20).
#
# Methods:
#   M1  – Naive storage MCS
#   M1b – SOC-floor storage MCS
#   M1c – Emergency-only storage MCS
#   M2  – Event-window storage MCS
#   M3  – Full-year ED (LP, Gurobi)
#   PCM-UCED (fixed-UC redispatch LP from N=20 HOPE-UC outputs)
#
# CC formula (model-rerun denominator, consistent with scripts 59 and 61):
#   CC(δ) = [EUE(x) − EUE(x + δ_storage)] / [EUE(x) − EUE(x + δ_perfect_rerun)]
#
# CRN: seed=42; N=20 scenarios for MCS methods and M3.
# PCM-UCED: reads existing HOPE-UC outputs s001–s020; no new HOPE runs needed.
#
# Outputs:
#   results/paper_tables/marginal_cc_all_methods_n20.csv
#       Schema identical to marginal_cc_all_methods_rerun.csv.
#       Contains wind-heavy N=20 rows for M1, M1b, M1c, M2, M3.
#   results/paper_tables/pcm_uced_marginal_cc.csv
#       Re-written with wind-heavy N=5 rows kept + new wind-heavy N=20 rows appended.
#
# Usage:
#   julia --project=. scripts/64_wind_hvy_marginal_cc_n20.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using JuMP, Gurobi
import MathOptInterface as MOI

using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASE       = "VRE120_wind_hvy"
const N_SCEN     = 20
const SEED       = 42
const DELTA_MWS  = [1.0, 5.0, 10.0]
const DURATION_H = 4.0

const RISK_MARGIN_MW      = 1000.0
const WINDOW_BUFFER_HOURS = 48

const REPO      = abspath(joinpath(@__DIR__, ".."))
const DATA_ROOT = abspath(joinpath(REPO, "data_processed", "cases"))
const CASES_DIR = abspath(joinpath(REPO, "exports", "hope_model_cases"))
const TAB_DIR   = abspath(joinpath(REPO, "results", "paper_tables"))

mkpath(TAB_DIR)

# Fixed-UC LP constants (matches script 63)
const VOLL       = 10_000.0
const CYC_CC     = 0.01
const COMMIT_THR = 0.01
const MARG_ETA   = sqrt(0.90)
const SOC0_FRAC  = 0.50
const PEAK_LOAD  = 9830.203148399996   # MW

println("=" ^ 70)
println("64_wind_hvy_marginal_cc_n20.jl")
println("Date:   ", Dates.now())
println("Case:   $CASE  (N=$N_SCEN, seed=$SEED)")
println("δ (MW): ", join(DELTA_MWS, ", "))
println("=" ^ 70)

# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers — MCS / M3
# ─────────────────────────────────────────────────────────────────────────────

function run_method_dispatch(tag::Symbol, sys::SystemData, avail::Array{Int8,3},
                             base_cfg::SimConfig, m2_cfg::SimConfig)::Vector{DispatchResult}
    if tag == :m1
        return run_m1_rule_based(sys, avail, base_cfg)
    elseif tag == :m1b
        return run_m1b_reserve_aware(sys, avail, base_cfg)
    elseif tag == :m1c
        return run_m1c_emergency_only(sys, avail, base_cfg)
    elseif tag == :m2
        return first(run_m2_with_diagnostics(sys, avail, m2_cfg))
    elseif tag == :m3
        return run_m3_ed_dispatch(sys, avail, base_cfg)
    else
        error("Unknown method tag: $tag")
    end
end

eue_mean(res::Vector{DispatchResult}) =
    isempty(res) ? 0.0 : mean(sum(r.load_shed) for r in res)

eue_analytical_perfect(res::Vector{DispatchResult}, δ::Float64) =
    isempty(res) ? 0.0 : mean(sum(max(0.0, v - δ) for v in r.load_shed) for r in res)

function with_marginal_storage(sys::SystemData, δ::Float64)::SystemData
    eta   = MARG_ETA
    extra = DataFrame(
        storage_id            = ["MARG_$(δ)MW"],
        power_mw              = [δ],
        energy_mwh            = [δ * DURATION_H],
        charge_efficiency     = [eta],
        discharge_efficiency  = [eta],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [δ * DURATION_H * SOC0_FRAC],
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

avail_with_perfect_firm(avail::Array{Int8,3}) =
    cat(avail, ones(Int8, size(avail, 1), 1, size(avail, 3)); dims=2)

# ─────────────────────────────────────────────────────────────────────────────
# Part 1: MCS methods (M1, M1b, M1c, M2) and M3 at N=20
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "─" ^ 70)
println("Part 1: MCS methods (M1, M1b, M1c, M2) and M3 at N=$N_SCEN")
println("─" ^ 70)

const MCS_METHODS = [
    ("M1",  "Naive storage MCS",          :m1),
    ("M1b", "SOC-floor storage MCS",      :m1b),
    ("M1c", "Emergency-only storage MCS", :m1c),
    ("M2",  "Event-window storage MCS",   :m2),
    ("M3",  "Full-year ED (M3)",          :m3),
]

case_dir = joinpath(DATA_ROOT, CASE)
isdir(case_dir) || error("Case directory not found: $case_dir")
sys      = load_system_data(case_dir)
base_cfg = SimConfig(n_scenarios = N_SCEN, seed = SEED)
m2_cfg   = SimConfig(n_scenarios = N_SCEN, seed = SEED,
                     risk_margin_mw      = RISK_MARGIN_MW,
                     window_buffer_hours = WINDOW_BUFFER_HOURS)

println("  Generating $N_SCEN scenarios (seed=$SEED)…")
scen       = generate_scenarios(sys, base_cfg)
avail_orig = scen.availability
avail_perf = avail_with_perfect_firm(avail_orig)
N, n_therm, T = size(avail_orig)
@printf("  Availability: [%d scenarios, %d thermal gens, %d hours]\n", N, n_therm, T)

mcs_rows = NamedTuple[]

for (mname, mlabel, mtag) in MCS_METHODS
    println("\n  ─── $mname ($mlabel) ───")

    t0       = time()
    res_base = run_method_dispatch(mtag, sys, avail_orig, base_cfg, m2_cfg)
    eue_base = eue_mean(res_base)
    @printf("    baseline EUE = %.4f MWh  (%.1f s)\n", eue_base, time()-t0)

    for δ in DELTA_MWS
        @printf("    δ = %.0f MW:\n", δ)

        eue_perf_anal = eue_analytical_perfect(res_base, δ)
        denom_anal    = eue_base - eue_perf_anal

        sys_stor = with_marginal_storage(sys, δ)
        t0       = time()
        res_stor = run_method_dispatch(mtag, sys_stor, avail_orig, base_cfg, m2_cfg)
        eue_stor = eue_mean(res_stor)
        numer    = eue_base - eue_stor
        @printf("      +storage:  EUE=%.4f  ΔEUE=%.6f  (%.1f s)\n",
                eue_stor, numer, time()-t0)

        sys_pf = with_perfect_firm(sys, δ)
        t0     = time()
        res_pf = run_method_dispatch(mtag, sys_pf, avail_perf, base_cfg, m2_cfg)
        eue_pf = eue_mean(res_pf)
        denom_rerun = eue_base - eue_pf
        @printf("      +perfect:  EUE=%.4f  ΔEUE_rerun=%.6f  ΔEUE_anal=%.6f  (%.1f s)\n",
                eue_pf, denom_rerun, denom_anal, time()-t0)

        cc_rerun = denom_rerun > 1e-9 ? numer / denom_rerun : NaN
        cc_anal  = denom_anal  > 1e-9 ? numer / denom_anal  : NaN
        @printf("      CC_rerun=%.5f  CC_anal=%.5f\n",
                isnan(cc_rerun) ? NaN : cc_rerun,
                isnan(cc_anal)  ? NaN : cc_anal)

        push!(mcs_rows, (
            case                              = CASE,
            model                             = mlabel,
            model_internal                    = mname,
            n_scen                            = N_SCEN,
            delta_mw                          = δ,
            eue_baseline_mwh                  = eue_base,
            eue_plus_storage_mwh              = eue_stor,
            eue_plus_perfect_rerun_mwh        = eue_pf,
            eue_plus_perfect_analytical_mwh   = eue_perf_anal,
            delta_eue_storage_mwh             = numer,
            delta_eue_perfect_rerun_mwh       = denom_rerun,
            delta_eue_perfect_analytical_mwh  = denom_anal,
            normalized_marginal_cc_rerun      = cc_rerun,
            normalized_marginal_cc_analytical = cc_anal,
        ))
    end
end

# Compute cc_error_rerun_vs_m3 relative to M3 N=20
df_mcs = DataFrame(mcs_rows)
df_mcs[!, :cc_error_rerun_vs_m3]      = fill(NaN, nrow(df_mcs))
df_mcs[!, :cc_error_analytical_vs_m3] = fill(NaN, nrow(df_mcs))

for δ in DELTA_MWS
    m3_rows = filter(r -> r.model_internal == "M3" && r.delta_mw == δ, df_mcs)
    isempty(m3_rows) && continue
    cc_m3_r = m3_rows[1, :normalized_marginal_cc_rerun]
    cc_m3_a = m3_rows[1, :normalized_marginal_cc_analytical]
    for i in findall((df_mcs.delta_mw .== δ))
        cc_r = df_mcs[i, :normalized_marginal_cc_rerun]
        cc_a = df_mcs[i, :normalized_marginal_cc_analytical]
        df_mcs[i, :cc_error_rerun_vs_m3] =
            (isnan(cc_r) || isnan(cc_m3_r)) ? NaN : cc_r - cc_m3_r
        df_mcs[i, :cc_error_analytical_vs_m3] =
            (isnan(cc_a) || isnan(cc_m3_a)) ? NaN : cc_a - cc_m3_a
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Part 2: PCM-UCED fixed-UC redispatch LP at N=20
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "─" ^ 70)
println("Part 2: PCM-UCED fixed-UC redispatch LP at N=$N_SCEN")
println("─" ^ 70)

# ── Scenario data struct (identical to script 63) ────────────────────────────

struct HopeUCScenario
    pmax       ::Vector{Float64}
    pmin_g     ::Vector{Float64}
    vcost      ::Vector{Float64}
    avail      ::Matrix{Float64}
    committed  ::Matrix{Bool}
    p_vre      ::Vector{Float64}
    load_mw    ::Vector{Float64}
    stor_pow   ::Float64
    stor_eng   ::Float64
    stor_eta   ::Float64
    stor_soc0  ::Float64
    stor_vcost ::Float64
    eue_hope   ::Float64
    T          ::Int
    n_g        ::Int
end

function read_hope_uc_scenario(folder::String)::HopeUCScenario
    data_dir = joinpath(folder, "Data_RAChronoOps_PCM")
    out_dir  = joinpath(folder, "output")

    gd       = CSV.read(joinpath(data_dir, "gendata.csv"), DataFrame)
    therm    = gd[gd[:, "Flag_thermal"] .== 1, :]
    n_g      = nrow(therm)
    pmax_v   = Float64.(therm[:, "Pmax (MW)"])
    pmin_v   = Float64.(therm[:, "Pmin (MW)"])
    vcost_v  = Float64.(therm[:, "Cost (\$/MWh)"])

    wind_rows  = gd[(gd[:, "Flag_VRE"] .== 1) .& (gd[:, "Type"] .== "WindOn"),  :]
    solar_rows = gd[(gd[:, "Flag_VRE"] .== 1) .& (gd[:, "Type"] .== "SolarPV"), :]
    wind_cap   = sum(Float64.(wind_rows[:,  "Pmax (MW)"]))
    solar_cap  = sum(Float64.(solar_rows[:, "Pmax (MW)"]))

    av_df   = CSV.read(joinpath(data_dir, "gen_availability_timeseries.csv"), DataFrame)
    T_h     = nrow(av_df)
    g_cols  = ["G$i" for i in 1:n_g]
    avail_T = Matrix{Float64}(av_df[:, g_cols])
    avail   = permutedims(avail_T)

    wind_cf  = Float64.(av_df[:, "G$(n_g + 1)"])
    solar_cf = Float64.(av_df[:, "G$(n_g + 2)"])
    p_vre    = wind_cap .* wind_cf .+ solar_cap .* solar_cf

    h_cols   = ["h$i" for i in 1:T_h]
    ph_df    = CSV.read(joinpath(out_dir, "power_hourly.csv"), DataFrame)
    disp     = Matrix{Float64}(ph_df[1:n_g, h_cols])
    committed = (disp .> COMMIT_THR) .& (avail .> 0.5)

    ld_df   = CSV.read(joinpath(data_dir, "load_timeseries_regional.csv"), DataFrame)
    load_mw = Float64.(ld_df[:, "Z1"]) .* PEAK_LOAD

    st_df     = CSV.read(joinpath(data_dir, "storagedata.csv"), DataFrame)
    stor_pow  = Float64(st_df[1, "Max Power (MW)"])
    stor_eng  = Float64(st_df[1, "Capacity (MWh)"])
    stor_eta  = Float64(st_df[1, "Charging efficiency"])
    stor_soc0 = stor_eng * SOC0_FRAC
    stor_vc   = Float64(st_df[1, "Cost (\$/MWh)"])

    ls_df    = CSV.read(joinpath(out_dir, "power_loadshedding.csv"), DataFrame)
    eue_hope = Float64(ls_df[1, "AnnTol"])

    return HopeUCScenario(pmax_v, pmin_v, vcost_v, avail, committed, p_vre,
                          load_mw, stor_pow, stor_eng, stor_eta, stor_soc0,
                          stor_vc, eue_hope, T_h, n_g)
end

# ── Fixed-UC LP solver (identical to script 63) ──────────────────────────────

function run_fixed_uc_lp(sc::HopeUCScenario;
                          delta_storage_mw::Float64 = 0.0,
                          delta_perfect_mw::Float64 = 0.0)::Float64
    (; pmax, pmin_g, vcost, avail, committed, p_vre, load_mw,
       stor_pow, stor_eng, stor_eta, stor_soc0, stor_vcost, T, n_g) = sc

    mdl = Model(Gurobi.Optimizer)
    set_silent(mdl)

    @variable(mdl, p[1:n_g, 1:T] >= 0.0)
    for g in 1:n_g, h in 1:T
        ub = avail[g, h] * Float64(committed[g, h]) * pmax[g]
        set_upper_bound(p[g, h], ub)
        lb = Float64(committed[g, h]) * pmin_g[g]
        lb > 1e-9 && set_lower_bound(p[g, h], lb)
    end

    @variable(mdl, ls[1:T]  >= 0.0)
    @variable(mdl, cur[1:T] >= 0.0)
    @variable(mdl, ch[1:T]  >= 0.0)
    @variable(mdl, dis[1:T] >= 0.0)
    @variable(mdl, soc[1:T] >= 0.0)

    @constraint(mdl, [h=1:T], ch[h]  <= stor_pow)
    @constraint(mdl, [h=1:T], dis[h] <= stor_pow)
    @constraint(mdl, [h=1:T], soc[h] <= stor_eng)
    @constraint(mdl, soc[1] == stor_soc0 + stor_eta * ch[1] - dis[1] / stor_eta)
    for h in 2:T
        @constraint(mdl, soc[h] == soc[h-1] + stor_eta * ch[h] - dis[h] / stor_eta)
    end
    @constraint(mdl, soc[T] == stor_soc0)

    add_marg = delta_storage_mw > 1e-9
    marg_soc0 = delta_storage_mw * DURATION_H * SOC0_FRAC
    if add_marg
        @variable(mdl, ch_m[1:T]  >= 0.0)
        @variable(mdl, dis_m[1:T] >= 0.0)
        @variable(mdl, soc_m[1:T] >= 0.0)
        @constraint(mdl, [h=1:T], ch_m[h]  <= delta_storage_mw)
        @constraint(mdl, [h=1:T], dis_m[h] <= delta_storage_mw)
        @constraint(mdl, [h=1:T], soc_m[h] <= delta_storage_mw * DURATION_H)
        @constraint(mdl, soc_m[1] == marg_soc0 + MARG_ETA * ch_m[1] - dis_m[1] / MARG_ETA)
        for h in 2:T
            @constraint(mdl, soc_m[h] == soc_m[h-1] + MARG_ETA * ch_m[h] - dis_m[h] / MARG_ETA)
        end
        @constraint(mdl, soc_m[T] == marg_soc0)
    end

    add_perf = delta_perfect_mw > 1e-9
    if add_perf
        @variable(mdl, p_perf[1:T] >= 0.0)
        @constraint(mdl, [h=1:T], p_perf[h] <= delta_perfect_mw)
    end

    for h in 1:T
        gen_sum = sum(p[g, h] for g in 1:n_g; init = AffExpr(0.0))
        net = gen_sum + p_vre[h] + dis[h] - ch[h]
        add_marg && (net = net + dis_m[h] - ch_m[h])
        add_perf && (net = net + p_perf[h])
        @constraint(mdl, net + ls[h] - cur[h] == load_mw[h])
    end

    obj = AffExpr(0.0)
    sv  = stor_vcost + CYC_CC
    for h in 1:T
        for g in 1:n_g
            add_to_expression!(obj, vcost[g], p[g, h])
        end
        add_to_expression!(obj, VOLL, ls[h])
        add_to_expression!(obj, sv,   ch[h])
        add_to_expression!(obj, sv,   dis[h])
    end
    if add_marg
        mv = 0.01 + CYC_CC
        for h in 1:T
            add_to_expression!(obj, mv, ch_m[h])
            add_to_expression!(obj, mv, dis_m[h])
        end
    end
    @objective(mdl, Min, obj)
    optimize!(mdl)

    status = termination_status(mdl)
    if status ∉ (MOI.OPTIMAL, MOI.LOCALLY_SOLVED)
        @warn "Fixed-UC LP: termination = $status"
        return NaN
    end
    return sum(max.(0.0, value.(ls)))
end

# ── Load N=20 UC scenarios ────────────────────────────────────────────────────

println("\n  Loading N=$N_SCEN HOPE-UC scenarios…")
uc_scenarios = HopeUCScenario[]
for s in 1:N_SCEN
    folder = joinpath(CASES_DIR, @sprintf("RAChronoOps_%s_s%03d_UC", CASE, s))
    isdir(folder) || error("UC folder not found: $folder")
    push!(uc_scenarios, read_hope_uc_scenario(folder))
end
@printf("  Loaded %d scenarios.  T=%d h, n_g=%d thermal gens\n",
        N_SCEN, uc_scenarios[1].T, uc_scenarios[1].n_g)
@printf("  Mean commitment rate: %.1f%%\n",
        mean(mean(sc.committed) for sc in uc_scenarios) * 100)

# ── Baseline fixed-UC LP ──────────────────────────────────────────────────────

println("\n  Baseline fixed-UC LP…")
eue_base_fuc = Float64[]
eue_hope_raw = Float64[]
t0_block = time()
for (s, sc) in enumerate(uc_scenarios)
    t0  = time()
    eue = run_fixed_uc_lp(sc)
    push!(eue_base_fuc, eue)
    push!(eue_hope_raw, sc.eue_hope)
    diff_pct = abs(eue - sc.eue_hope) / max(sc.eue_hope, 1.0) * 100
    @printf("    s%03d  EUE_fixedUC=%8.3f MWh  HOPE_EUE=%8.3f MWh  |diff|=%.2f%%  (%.1f s)\n",
            s, eue, sc.eue_hope, diff_pct, time()-t0)
end
mean_eue_base_fuc = mean(eue_base_fuc)
mean_eue_hope     = mean(eue_hope_raw)
mean_diff_pct     = abs(mean_eue_base_fuc - mean_eue_hope) / max(mean_eue_hope, 1.0) * 100
@printf("  → Mean EUE_fixedUC=%.3f MWh  Mean HOPE=%.3f MWh  |diff|=%.3f%%  (%.1f s total)\n",
        mean_eue_base_fuc, mean_eue_hope, mean_diff_pct, time()-t0_block)

uced_rows = NamedTuple[]

for δ in DELTA_MWS
    @printf("\n  δ = %.0f MW:\n", δ)

    print("    +storage … ")
    eue_stor = Float64[]
    t0 = time()
    for sc in uc_scenarios
        push!(eue_stor, run_fixed_uc_lp(sc; delta_storage_mw = δ))
    end
    mean_eue_stor = mean(eue_stor)
    numer = mean_eue_base_fuc - mean_eue_stor
    @printf("mean EUE=%.4f  ΔEUE=%.6f  (%.1f s)\n", mean_eue_stor, numer, time()-t0)

    print("    +perfect  … ")
    eue_perf = Float64[]
    t0 = time()
    for sc in uc_scenarios
        push!(eue_perf, run_fixed_uc_lp(sc; delta_perfect_mw = δ))
    end
    mean_eue_perf = mean(eue_perf)
    denom = mean_eue_base_fuc - mean_eue_perf
    @printf("mean EUE=%.4f  ΔEUE=%.6f  (%.1f s)\n", mean_eue_perf, denom, time()-t0)

    cc = denom > 1e-9 ? numer / denom : NaN
    @printf("    CC_fixed_UC = %.5f\n", isnan(cc) ? 0.0 : cc)

    push!(uced_rows, (
        case                              = CASE,
        model                             = "PCM-UCED (fixed-UC)",
        model_internal                    = "HOPE-UC-FixedUC",
        n_scen                            = N_SCEN,
        delta_mw                          = δ,
        eue_hope_uced_mean_mwh            = mean_eue_hope,
        eue_fixed_uc_baseline_mean_mwh    = mean_eue_base_fuc,
        eue_fixed_uc_storage_mean_mwh     = mean_eue_stor,
        eue_fixed_uc_perfect_mean_mwh     = mean_eue_perf,
        delta_eue_storage_mwh             = numer,
        delta_eue_perfect_mwh             = denom,
        normalized_marginal_cc            = cc,
        fixed_uc_vs_hope_diff_pct         = mean_diff_pct,
        milp_reopt_note                   = "infeasible: ~$(round(Int, 2820*N_SCEN*6/3600)) h for N=$N_SCEN",
    ))
end

df_uced_new = DataFrame(uced_rows)

# ─────────────────────────────────────────────────────────────────────────────
# Part 3: N=5 vs N=20 comparison summary
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 70)
println("N=5 vs N=20 CC comparison (δ = 1 MW, wind-heavy, model-rerun denominator)")
println("=" ^ 70)

# Load N=5 values from existing CSVs
n5_cc = Dict{String, Float64}()  # model_internal → CC_rerun at N=5

cc61_path = joinpath(TAB_DIR, "marginal_cc_all_methods_rerun.csv")
if isfile(cc61_path)
    df61 = CSV.read(cc61_path, DataFrame)
    for row in eachrow(filter(r -> r.case == CASE && r.n_scen == 5 && r.delta_mw == 1.0, df61))
        n5_cc[row.model_internal] = row.normalized_marginal_cc_rerun
    end
end

cc59_path = joinpath(TAB_DIR, "marginal_cc_model_rerun_validation.csv")
if isfile(cc59_path)
    df59 = CSV.read(cc59_path, DataFrame)
    for row in eachrow(filter(r -> r.case == CASE && r.n_scen == 5 && r.delta_mw == 1.0, df59))
        if row.model == "Full-year ED (M3)"
            n5_cc["M3"] = row.normalized_marginal_cc_rerun
        end
    end
end

pcm_path = joinpath(TAB_DIR, "pcm_uced_marginal_cc.csv")
if isfile(pcm_path)
    df_pcm = CSV.read(pcm_path, DataFrame)
    for row in eachrow(filter(r -> r.case == CASE && r.n_scen == 5 && r.delta_mw == 1.0, df_pcm))
        n5_cc["HOPE-UC-FixedUC"] = row.normalized_marginal_cc
    end
end

@printf("  %-24s  %10s  %10s  %10s  %s\n",
        "Method", "CC (N=5)", "CC (N=20)", "ΔCC", "Stable?")
println("  " * "─" ^ 72)

# MCS + M3 methods
for (mname, mlabel, _) in MCS_METHODS
    n20_row = filter(r -> r.model_internal == mname && r.delta_mw == 1.0, df_mcs)
    cc20 = isempty(n20_row) ? NaN : n20_row[1, :normalized_marginal_cc_rerun]
    cc5  = get(n5_cc, mname, NaN)
    Δcc  = isnan(cc5) || isnan(cc20) ? NaN : cc20 - cc5
    stable = isnan(Δcc) ? "?" : (abs(Δcc) < 0.02 ? "similar across N=5 and N=20" : "CHANGED (|ΔCC|=$(round(abs(Δcc),digits=3)))")
    @printf("  %-24s  %10.5f  %10.5f  %+10.5f  %s\n",
            mname, isnan(cc5) ? 0.0 : cc5, isnan(cc20) ? 0.0 : cc20,
            isnan(Δcc) ? 0.0 : Δcc, stable)
end

# PCM-UCED
uced_n20_row = filter(r -> r.delta_mw == 1.0, df_uced_new)
cc20_uced = isempty(uced_n20_row) ? NaN : uced_n20_row[1, :normalized_marginal_cc]
cc5_uced  = get(n5_cc, "HOPE-UC-FixedUC", NaN)
Δcc_uced  = isnan(cc5_uced) || isnan(cc20_uced) ? NaN : cc20_uced - cc5_uced
stable_uced = isnan(Δcc_uced) ? "?" : (abs(Δcc_uced) < 0.02 ? "similar across N=5 and N=20" : "CHANGED (|ΔCC|=$(round(abs(Δcc_uced),digits=3)))")
@printf("  %-24s  %10.5f  %10.5f  %+10.5f  %s\n",
        "HOPE-UC-FixedUC",
        isnan(cc5_uced) ? 0.0 : cc5_uced,
        isnan(cc20_uced) ? 0.0 : cc20_uced,
        isnan(Δcc_uced) ? 0.0 : Δcc_uced,
        stable_uced)

# ─────────────────────────────────────────────────────────────────────────────
# Save outputs
# ─────────────────────────────────────────────────────────────────────────────

# 1. marginal_cc_all_methods_n20.csv (same schema as script 61 output)
out_mcs = joinpath(TAB_DIR, "marginal_cc_all_methods_n20.csv")
CSV.write(out_mcs, df_mcs)
println("\nSaved: $out_mcs  ($(nrow(df_mcs)) rows)")

# 2. pcm_uced_marginal_cc.csv — keep existing rows, append/replace N=20 wind-heavy
out_pcm = joinpath(TAB_DIR, "pcm_uced_marginal_cc.csv")
if isfile(out_pcm)
    df_pcm_existing = CSV.read(out_pcm, DataFrame)
    # Remove any existing wind-heavy N=20 rows (avoid duplicates on re-run)
    df_pcm_keep = filter(r -> !(r.case == CASE && r.n_scen == N_SCEN), df_pcm_existing)
    df_pcm_out  = vcat(df_pcm_keep, df_uced_new)
else
    df_pcm_out = df_uced_new
end
CSV.write(out_pcm, df_pcm_out)
println("Saved: $out_pcm  ($(nrow(df_pcm_out)) rows, including N=$N_SCEN wind-heavy)")

println("\n" * "=" ^ 70)
println("Done.")
println("=" ^ 70)
println("\nNext steps:")
println("  1. Run scripts/62_build_main_comparison_and_dashboard.py to rebuild")
println("     main_method_comparison_with_runtime_cc.csv with N=20 CC values.")
println("  2. Check: does the N=20 CC differ materially from N=5 for any method?")
