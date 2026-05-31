#!/usr/bin/env julia
# 63_pcm_uced_marginal_cc.jl
#
# Normalized marginal storage CC for PCM-UCED via fixed-UC redispatch LP.
#
# For each baseline HOPE PCM-UCED scenario ω:
#   1. Read HOPE UC dispatch; infer commitment u[g,h,ω] (threshold 0.01 MW).
#   2. Run a fixed-commitment LP: pmin lower bounds for committed generators,
#      decommitted generators locked at zero; re-optimise continuous dispatch
#      and storage SOC over the full year.
#   3. Compute CC(δ) = mean(ΔEUE_storage) / mean(ΔEUE_perfect_rerun).
#
# Note on full MILP reoptimisation:
#   ~570 s/scenario × 20 scen × 6 runs (baseline+stor+perf per 3 δ) ≈ 19 hours.
#   Computationally infeasible for routine analysis; fixed-UC LP is the
#   practical diagnostic.
#
# Cases:  VRE120_base (N=20), VRE120_wind_hvy (N=5)
# Deltas: 1, 5, 10 MW  (primary = 1 MW)
# Seed:   n/a  (reads pre-computed HOPE scenarios)
#
# Output: results/paper_tables/pcm_uced_marginal_cc.csv
#
# Usage:
#   julia --project=. scripts/63_pcm_uced_marginal_cc.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using JuMP, Gurobi
import MathOptInterface as MOI

using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const REPO       = abspath(joinpath(@__DIR__, ".."))
const CASES_DIR  = abspath(joinpath(REPO, "exports", "hope_model_cases"))
const TAB_DIR    = abspath(joinpath(REPO, "results", "paper_tables"))

mkpath(TAB_DIR)

# (case_key, n_scenarios, UC_folder_suffix)
const CASES_N = [("VRE120_base", 20), ("VRE120_wind_hvy", 5)]
const DELTA_MWS  = [1.0, 5.0, 10.0]   # marginal storage / perfect-firm size (MW)
const DURATION_H = 4.0                 # marginal storage duration (hours)
const VOLL       = 10_000.0            # $/MWh  (matches RAChronoOps SimConfig default)
const CYC_CC     = 0.01                # $/MWh  anti-simultaneous-C/D penalty
const COMMIT_THR = 0.01                # MW  dispatch below this → not committed
const MARG_ETA   = sqrt(0.90)          # marginal storage one-way efficiency
const SOC0_FRAC  = 0.50                # initial SOC as fraction of energy capacity
const PEAK_LOAD  = 9830.203148399996   # MW  (HOPE Z1 normalisation denominator)

# ─────────────────────────────────────────────────────────────────────────────
# Data structures
# ─────────────────────────────────────────────────────────────────────────────

struct HopeUCScenario
    pmax       ::Vector{Float64}   # [n_g]      thermal Pmax (MW)
    pmin_g     ::Vector{Float64}   # [n_g]      thermal Pmin (MW)
    vcost      ::Vector{Float64}   # [n_g]      variable cost ($/MWh)
    avail      ::Matrix{Float64}   # [n_g × T]  binary availability (0/1)
    committed  ::Matrix{Bool}      # [n_g × T]  inferred from HOPE dispatch
    p_vre      ::Vector{Float64}   # [T]        total VRE available (MW)
    load_mw    ::Vector{Float64}   # [T]        demand (MW)
    stor_pow   ::Float64           # storage max charge/discharge (MW)
    stor_eng   ::Float64           # storage energy capacity (MWh)
    stor_eta   ::Float64           # one-way efficiency (charge = discharge)
    stor_soc0  ::Float64           # initial SOC (MWh)
    stor_vcost ::Float64           # storage variable cost ($/MWh)
    eue_hope   ::Float64           # original HOPE UCED EUE (MWh), for cross-check
    T          ::Int
    n_g        ::Int
end

# ─────────────────────────────────────────────────────────────────────────────
# Data loading
# ─────────────────────────────────────────────────────────────────────────────

function read_hope_uc_scenario(folder::String)::HopeUCScenario
    data_dir = joinpath(folder, "Data_RAChronoOps_PCM")
    out_dir  = joinpath(folder, "output")

    # ── gendata ────────────────────────────────────────────────────────────
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

    # ── availability + VRE timeseries ─────────────────────────────────────
    av_df   = CSV.read(joinpath(data_dir, "gen_availability_timeseries.csv"), DataFrame)
    T       = nrow(av_df)
    # G1..G_n_g: thermal availability (binary); G(n_g+1)=wind CF; G(n_g+2)=solar CF
    g_cols  = ["G$i" for i in 1:n_g]
    avail_T = Matrix{Float64}(av_df[:, g_cols])   # T × n_g (CSV rows = hours)
    avail   = permutedims(avail_T)                 # n_g × T

    wind_cf  = Float64.(av_df[:, "G$(n_g + 1)"])
    solar_cf = Float64.(av_df[:, "G$(n_g + 2)"])
    p_vre    = wind_cap .* wind_cf .+ solar_cap .* solar_cf   # T

    # ── thermal dispatch → commitment inference ────────────────────────────
    h_cols   = ["h$i" for i in 1:T]
    ph_df    = CSV.read(joinpath(out_dir, "power_hourly.csv"), DataFrame)
    disp     = Matrix{Float64}(ph_df[1:n_g, h_cols])  # n_g × T (rows=gens, cols=hours)
    committed = (disp .> COMMIT_THR) .& (avail .> 0.5)  # n_g × T

    # ── load ───────────────────────────────────────────────────────────────
    ld_df   = CSV.read(joinpath(data_dir, "load_timeseries_regional.csv"), DataFrame)
    load_mw = Float64.(ld_df[:, "Z1"]) .* PEAK_LOAD        # T

    # ── storagedata ────────────────────────────────────────────────────────
    st_df     = CSV.read(joinpath(data_dir, "storagedata.csv"), DataFrame)
    stor_pow  = Float64(st_df[1, "Max Power (MW)"])
    stor_eng  = Float64(st_df[1, "Capacity (MWh)"])
    stor_eta  = Float64(st_df[1, "Charging efficiency"])
    stor_soc0 = stor_eng * SOC0_FRAC
    stor_vc   = Float64(st_df[1, "Cost (\$/MWh)"])

    # ── original HOPE UCED EUE (validation baseline) ──────────────────────
    ls_df    = CSV.read(joinpath(out_dir, "power_loadshedding.csv"), DataFrame)
    eue_hope = Float64(ls_df[1, "AnnTol"])   # annual MWh shed

    return HopeUCScenario(
        pmax_v, pmin_v, vcost_v, avail, committed, p_vre, load_mw,
        stor_pow, stor_eng, stor_eta, stor_soc0, stor_vc, eue_hope, T, n_g
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# Fixed-UC LP solver
# ─────────────────────────────────────────────────────────────────────────────
#
# Generator bounds under fixed commitment:
#   committed[g,h] = 1  → pmin[g]  ≤ p[g,h] ≤ avail[g,h] * pmax[g]
#   committed[g,h] = 0  →           p[g,h] = 0
#
# Returns: total EUE (sum of load-shed MWh over all T hours)

function run_fixed_uc_lp(sc::HopeUCScenario;
                          delta_storage_mw::Float64 = 0.0,
                          delta_perfect_mw::Float64 = 0.0)::Float64

    (; pmax, pmin_g, vcost, avail, committed, p_vre, load_mw,
       stor_pow, stor_eng, stor_eta, stor_soc0, stor_vcost, T, n_g) = sc

    mdl = Model(Gurobi.Optimizer)
    set_silent(mdl)

    # ── Thermal generators ─────────────────────────────────────────────────
    @variable(mdl, p[1:n_g, 1:T] >= 0.0)

    for g in 1:n_g, h in 1:T
        ub = avail[g, h] * Float64(committed[g, h]) * pmax[g]
        set_upper_bound(p[g, h], ub)
        lb = Float64(committed[g, h]) * pmin_g[g]
        if lb > 1e-9
            set_lower_bound(p[g, h], lb)
        end
    end

    # ── Load shed / curtailment ────────────────────────────────────────────
    @variable(mdl, ls[1:T]  >= 0.0)
    @variable(mdl, cur[1:T] >= 0.0)

    # ── Main storage ───────────────────────────────────────────────────────
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
    @constraint(mdl, soc[T] == stor_soc0)   # cyclic SOC

    # ── Marginal storage ───────────────────────────────────────────────────
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

    # ── Perfect-firm generator ─────────────────────────────────────────────
    add_perf = delta_perfect_mw > 1e-9
    if add_perf
        @variable(mdl, p_perf[1:T] >= 0.0)
        @constraint(mdl, [h=1:T], p_perf[h] <= delta_perfect_mw)
    end

    # ── Power balance ──────────────────────────────────────────────────────
    for h in 1:T
        gen_sum = sum(p[g, h] for g in 1:n_g; init = AffExpr(0.0))
        net = gen_sum + p_vre[h] + dis[h] - ch[h]
        if add_marg
            net = net + dis_m[h] - ch_m[h]
        end
        if add_perf
            net = net + p_perf[h]
        end
        @constraint(mdl, net + ls[h] - cur[h] == load_mw[h])
    end

    # ── Objective ─────────────────────────────────────────────────────────
    obj = AffExpr(0.0)
    sv  = stor_vcost + CYC_CC
    for h in 1:T
        for g in 1:n_g
            add_to_expression!(obj, vcost[g], p[g, h])
        end
        add_to_expression!(obj, VOLL, ls[h])
        add_to_expression!(obj, sv, ch[h])
        add_to_expression!(obj, sv, dis[h])
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
        @warn "Fixed-UC LP: termination status = $status"
        return NaN
    end

    return sum(max.(0.0, value.(ls)))
end

# ─────────────────────────────────────────────────────────────────────────────
# Header
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 70)
println("63_pcm_uced_marginal_cc.jl — Fixed-UC redispatch LP")
println("Date:    ", Dates.now())
println("Cases:   ", join(first.(CASES_N), ", "))
println("δ (MW):  ", join(DELTA_MWS, ", "))
println("Method:  Fixed-UC redispatch (commitment fixed from HOPE output)")
println("Full MILP note: ~570 s/scen × 20 scen × 6 runs × 3 δ ≈ 19 h (infeasible)")
println("=" ^ 70)

# ─────────────────────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────────────────────

all_rows = NamedTuple[]

for (case, n_scen) in CASES_N
    println("\n" * "─" ^ 70)
    println("Case: $case  (N=$n_scen)")
    println("─" ^ 70)

    # -- Load all scenarios ─────────────────────────────────────────────────
    scenarios = HopeUCScenario[]
    for s in 1:n_scen
        folder = joinpath(CASES_DIR, @sprintf("RAChronoOps_%s_s%03d_UC", case, s))
        if !isdir(folder)
            error("HOPE UC folder not found: $folder")
        end
        push!(scenarios, read_hope_uc_scenario(folder))
    end
    @printf("  Loaded %d scenarios.\n", n_scen)

    T   = scenarios[1].T
    n_g = scenarios[1].n_g
    @printf("  T=%d hours, n_g=%d thermal generators\n", T, n_g)

    # ── Commitment statistics ───────────────────────────────────────────────
    mean_commit_rate = mean(mean(sc.committed) for sc in scenarios)
    @printf("  Mean commitment rate: %.1f%%\n", mean_commit_rate * 100)

    # ── Baseline fixed-UC LP (one per scenario) ─────────────────────────────
    println("\n  Running baseline fixed-UC LP…")
    eue_base = Float64[]
    eue_hope = Float64[]
    t0_block = time()
    for (s, sc) in enumerate(scenarios)
        t0  = time()
        eue = run_fixed_uc_lp(sc)
        push!(eue_base, eue)
        push!(eue_hope, sc.eue_hope)
        diff_pct = abs(eue - sc.eue_hope) / max(sc.eue_hope, 1.0) * 100
        @printf("    s%03d  EUE_fixedUC = %8.2f MWh   HOPE_EUE = %8.2f MWh   |diff| = %.1f%%   (%.1f s)\n",
                s, eue, sc.eue_hope, diff_pct, time()-t0)
    end
    mean_eue_base = mean(eue_base)
    mean_eue_hope = mean(eue_hope)
    mean_diff_pct = abs(mean_eue_base - mean_eue_hope) / max(mean_eue_hope, 1.0) * 100
    @printf("  → Mean EUE_fixedUC = %.2f MWh   Mean HOPE_EUE = %.2f MWh   |diff| = %.1f%%   (%.1f s total)\n",
            mean_eue_base, mean_eue_hope, mean_diff_pct, time()-t0_block)

    # ── Delta loop ──────────────────────────────────────────────────────────
    for δ in DELTA_MWS
        @printf("\n  δ = %.0f MW:\n", δ)

        # +storage
        print("    +storage  …")
        eue_stor = Float64[]
        t0 = time()
        for sc in scenarios
            push!(eue_stor, run_fixed_uc_lp(sc; delta_storage_mw = δ))
        end
        mean_eue_stor = mean(eue_stor)
        numer = mean_eue_base - mean_eue_stor
        @printf("  mean EUE=%.4f  ΔEUE=%.6f  (%.1f s)\n", mean_eue_stor, numer, time()-t0)

        # +perfect firm
        print("    +perfect  …")
        eue_perf = Float64[]
        t0 = time()
        for sc in scenarios
            push!(eue_perf, run_fixed_uc_lp(sc; delta_perfect_mw = δ))
        end
        mean_eue_perf = mean(eue_perf)
        denom = mean_eue_base - mean_eue_perf
        @printf("  mean EUE=%.4f  ΔEUE=%.6f  (%.1f s)\n", mean_eue_perf, denom, time()-t0)

        cc = denom > 1e-9 ? numer / denom : NaN
        @printf("    CC_fixed_UC = %.5f\n", isnan(cc) ? 0.0 : cc)

        push!(all_rows, (
            case                              = case,
            model                             = "PCM-UCED (fixed-UC)",
            model_internal                    = "HOPE-UC-FixedUC",
            n_scen                            = n_scen,
            delta_mw                          = δ,
            eue_hope_uced_mean_mwh            = mean_eue_hope,
            eue_fixed_uc_baseline_mean_mwh    = mean_eue_base,
            eue_fixed_uc_storage_mean_mwh     = mean_eue_stor,
            eue_fixed_uc_perfect_mean_mwh     = mean_eue_perf,
            delta_eue_storage_mwh             = numer,
            delta_eue_perfect_mwh             = denom,
            normalized_marginal_cc            = cc,
            fixed_uc_vs_hope_diff_pct         = mean_diff_pct,
            milp_reopt_note                   = "infeasible: ~$(round(Int, 570 * n_scen * 6 / 3600)) h for N=$n_scen",
        ))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

df = DataFrame(all_rows)

println("\n" * "=" ^ 70)
println("Summary — normalized marginal CC (δ = 1 MW, fixed-UC redispatch LP)")
println("=" ^ 70)
@printf("  %-24s  %-26s  %6s  %10s  %8s\n",
        "Case", "Model", "N", "CC", "|HOPE diff|")
println("  " * "─" ^ 82)
for row in eachrow(sort(filter(r -> r.delta_mw == 1.0, df), [:case]))
    @printf("  %-24s  %-26s  %6d  %10.5f  %7.1f%%\n",
            row.case, row.model,
            row.n_scen,
            isnan(row.normalized_marginal_cc) ? 0.0 : row.normalized_marginal_cc,
            row.fixed_uc_vs_hope_diff_pct)
end

# ─────────────────────────────────────────────────────────────────────────────
# Save
# ─────────────────────────────────────────────────────────────────────────────

csv_path = joinpath(TAB_DIR, "pcm_uced_marginal_cc.csv")
CSV.write(csv_path, df)
println("\nSaved: $csv_path")
println("Done.")
