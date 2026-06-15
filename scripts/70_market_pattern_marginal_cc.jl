#!/usr/bin/env julia
# 70_market_pattern_marginal_cc.jl
#
# Parts B–C–E–G of the market-pattern manuscript experiment suite.
#
# Part B: Marginal capacity credit (CC) for all 4 MP variants + M1c/M2 benchmarks.
#         CC(δ) = [EUE(x) − EUE(x+δ_S)] / [EUE(x) − EUE(x+δ_F)]
#         Denominator uses explicit perfect-firm rerun (consistent with script 61).
#
# Part C: Table IV candidate rows for the 2 paper-facing variants:
#         • Market-pattern storage MCS (MP_pure_cur: no emergency, charge-curtailed)
#         • Market-pattern + emergency storage MCS (MP_emergency_cur: both flags)
#         Includes LOLH, EUE, NEUE, CVaR-EUE, runtime/scenario, CC at δ=1 MW.
#
# Part E: SOC boundary check — initial vs end-of-year SOC distribution.
#         Compares fixed 50% init vs cyclic-init (init_soc = prior-year final mean).
#
# Part G: Sampling convergence for 2 paper-facing variants at N=20,50,100,200.
#
# Outputs:
#   results/paper_tables/market_pattern_capacity_credit.csv   (Part B)
#   results/paper_tables/market_pattern_table_iv_rows.csv     (Part C)
#   results/paper_tables/market_pattern_soc_boundary_check.csv (Part E)
#   results/paper_tables/market_pattern_sampling_convergence.csv (Part G)
#
# Usage:
#   julia --project=. scripts/70_market_pattern_marginal_cc.jl [--skip-m2] [--skip-part-e]
#                                                                [--skip-part-g]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASES       = ["VRE120_base", "VRE120_wind_hvy"]
const CASE_LABELS = Dict("VRE120_base" => "Balanced VRE", "VRE120_wind_hvy" => "Wind-heavy")

const PAPER_N     = 20          # N matching Table IV
const SEED        = 42
const DELTA_MWS   = [1.0, 5.0, 10.0]
const DURATION_H  = 4.0         # storage duration for CC increment (matches script 61)
const SOC_INIT_FRAC = 0.5       # 50% initial SOC for CC increment

const M2_RISK_MW  = 1000.0      # matches Table IV (script 38)
const M2_BUF_H    = 48          # matches Table IV (script 38)

# Four MP variants: (label, paper_label, emergency_override, charge_curtailed)
const MP_VARIANTS = [
    ("MP_pure",          "Market-pattern pure",                    false, false),
    ("MP_pure_cur",      "Market-pattern pure (curtailed)",        false, true),
    ("MP_emergency",     "Market-pattern + emergency",             true,  false),
    ("MP_emergency_cur", "Market-pattern + emergency (curtailed)", true,  true),
]

# Paper-facing variants (subset for Table IV rows and sampling convergence)
const PAPER_VARIANTS = [
    ("MP_pure_cur",      "Market-pattern storage MCS",              false, true),
    ("MP_emergency_cur", "Market-pattern + emergency storage MCS",  true,  true),
]

const CONV_NS = [20, 50, 100, 200]   # Part G convergence check

# ─────────────────────────────────────────────────────────────────────────────
# CLI flags
# ─────────────────────────────────────────────────────────────────────────────

function parse_flags(args)
    f = Set(args)
    return (
        skip_m2    = "--skip-m2"     in f,
        skip_part_e = "--skip-part-e" in f,
        skip_part_g = "--skip-part-g" in f,
    )
end

flags = parse_flags(ARGS)

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

const REPO      = abspath(joinpath(@__DIR__, ".."))
const DATA_ROOT = joinpath(REPO, "data_processed", "cases")
const PT_DIR    = joinpath(REPO, "results", "paper_tables")
const PAT_CSV   = joinpath(REPO, "data_processed", "caiso_storage_patterns",
                            "season_hour_pattern.csv")

mkpath(PT_DIR)
isfile(PAT_CSV) || error("Pattern CSV not found: $PAT_CSV\nRun scripts/build_caiso_storage_patterns.py first.")

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions (consistent with scripts 59 and 61)
# ─────────────────────────────────────────────────────────────────────────────

function with_marginal_storage(sys::SystemData, δ::Float64;
                                dur::Float64 = DURATION_H,
                                soc_frac::Float64 = SOC_INIT_FRAC)::SystemData
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

eue_mean(results::Vector{DispatchResult})::Float64 =
    isempty(results) ? 0.0 : mean(sum(r.load_shed) for r in results)

function run_mp(sys, avail, cfg; emerg, curtailed)
    return run_market_pattern_storage(sys, avail, cfg;
                                      pattern_csv = PAT_CSV,
                                      emergency_override = emerg,
                                      charge_curtailed   = curtailed)
end

# ─────────────────────────────────────────────────────────────────────────────
# Part B: Marginal CC for all 4 MP variants (+ M1c + M2 benchmarks)
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 72)
println("70_market_pattern_marginal_cc.jl")
println("Date:  ", Dates.now())
println("Parts: B (CC), C (Table IV rows), E (SOC boundary), G (convergence)")
println("=" ^ 72)

println("\n▶ Part B: Marginal capacity credit")
println("  δ = ", join(DELTA_MWS, ", "), " MW | N=", PAPER_N, " | seed=", SEED)

cc_rows = NamedTuple[]

for cname in CASES
    cdir = joinpath(DATA_ROOT, cname)
    isdir(cdir) || error("Case directory not found: $cdir")
    sys  = load_system_data(cdir)
    cfg  = SimConfig(n_scenarios = PAPER_N, seed = SEED)
    m2cfg = SimConfig(n_scenarios = PAPER_N, seed = SEED,
                      risk_margin_mw      = M2_RISK_MW,
                      window_buffer_hours = M2_BUF_H)

    println("\n  ── Case: $cname (N=$PAPER_N) ──")
    scen       = generate_scenarios(sys, cfg)
    avail      = scen.availability
    avail_perf = avail_with_perfect_firm(avail)

    # ── 4 MP variants ────────────────────────────────────────────────────────
    for (lbl, _, emerg, curtailed) in MP_VARIANTS
        println("\n    $lbl")
        t0       = time()
        r_base, _, _ = run_mp(sys, avail, cfg; emerg, curtailed)
        rt_base  = time() - t0
        eue_base = eue_mean(r_base)
        @printf("      baseline  EUE=%8.3f MWh  (%.2f s)\n", eue_base, rt_base)

        for δ in DELTA_MWS
            # Storage numerator
            sys_s  = with_marginal_storage(sys, δ)
            t0     = time()
            r_s, _, _ = run_mp(sys_s, avail, cfg; emerg, curtailed)
            rt_s   = time() - t0
            eue_s  = eue_mean(r_s)
            numer  = eue_base - eue_s

            # Perfect-firm rerun denominator
            sys_f    = with_perfect_firm(sys, δ)
            t0       = time()
            r_f, _, _ = run_mp(sys_f, avail_perf, cfg; emerg, curtailed)
            rt_f     = time() - t0
            eue_f    = eue_mean(r_f)
            denom    = eue_base - eue_f

            cc = denom > 1e-9 ? numer / denom : NaN
            @printf("      δ=%2.0fMW  +stor EUE=%8.3f ΔEUE=%7.4f  +firm EUE=%8.3f ΔEUE=%7.4f  CC=%7.4f\n",
                    δ, eue_s, numer, eue_f, denom, isnan(cc) ? -999.0 : cc)

            push!(cc_rows, (
                case_name            = cname,
                case_label           = CASE_LABELS[cname],
                method               = lbl,
                n_scenarios          = PAPER_N,
                seed                 = SEED,
                delta_mw             = δ,
                eue_baseline_mwh     = eue_base,
                eue_plus_storage_mwh = eue_s,
                eue_plus_firm_mwh    = eue_f,
                delta_eue_storage_mwh = numer,
                delta_eue_firm_mwh   = denom,
                marginal_cc          = cc,
            ))
        end
    end

    # ── M1c benchmark ────────────────────────────────────────────────────────
    println("\n    M1c (emergency-only, benchmark)")
    r_m1c_base = run_m1c_emergency_only(sys, avail, cfg)
    eue_m1c    = eue_mean(r_m1c_base)
    @printf("      baseline  EUE=%8.3f MWh\n", eue_m1c)

    for δ in DELTA_MWS
        sys_s    = with_marginal_storage(sys, δ)
        r_m1c_s  = run_m1c_emergency_only(sys_s, avail, cfg)
        eue_m1c_s = eue_mean(r_m1c_s)
        numer    = eue_m1c - eue_m1c_s

        sys_f    = with_perfect_firm(sys, δ)
        r_m1c_f  = run_m1c_emergency_only(sys_f, avail_perf, cfg)
        eue_m1c_f = eue_mean(r_m1c_f)
        denom    = eue_m1c - eue_m1c_f

        cc = denom > 1e-9 ? numer / denom : NaN
        @printf("      δ=%2.0fMW  ΔEUE_stor=%7.4f  ΔEUE_firm=%7.4f  CC=%7.4f\n",
                δ, numer, denom, isnan(cc) ? -999.0 : cc)

        push!(cc_rows, (
            case_name            = cname,
            case_label           = CASE_LABELS[cname],
            method               = "M1c",
            n_scenarios          = PAPER_N,
            seed                 = SEED,
            delta_mw             = δ,
            eue_baseline_mwh     = eue_m1c,
            eue_plus_storage_mwh = eue_m1c_s,
            eue_plus_firm_mwh    = eue_m1c_f,
            delta_eue_storage_mwh = numer,
            delta_eue_firm_mwh   = denom,
            marginal_cc          = cc,
        ))
    end

    # ── M2 benchmark (correct Table IV params) ───────────────────────────────
    if !flags.skip_m2
        println("\n    M2 (event-window LP, risk=1000 MW, buf=48 h)")
        r_m2_base = run_m2_event_window_lp(sys, avail, m2cfg)
        eue_m2    = eue_mean(r_m2_base)
        @printf("      baseline  EUE=%8.3f MWh\n", eue_m2)

        for δ in DELTA_MWS
            sys_s    = with_marginal_storage(sys, δ)
            r_m2_s   = run_m2_event_window_lp(sys_s, avail, m2cfg)
            eue_m2_s = eue_mean(r_m2_s)
            numer    = eue_m2 - eue_m2_s

            sys_f    = with_perfect_firm(sys, δ)
            r_m2_f   = run_m2_event_window_lp(sys_f, avail_perf, m2cfg)
            eue_m2_f = eue_mean(r_m2_f)
            denom    = eue_m2 - eue_m2_f

            cc = denom > 1e-9 ? numer / denom : NaN
            @printf("      δ=%2.0fMW  ΔEUE_stor=%7.4f  ΔEUE_firm=%7.4f  CC=%7.4f\n",
                    δ, numer, denom, isnan(cc) ? -999.0 : cc)

            push!(cc_rows, (
                case_name            = cname,
                case_label           = CASE_LABELS[cname],
                method               = "M2",
                n_scenarios          = PAPER_N,
                seed                 = SEED,
                delta_mw             = δ,
                eue_baseline_mwh     = eue_m2,
                eue_plus_storage_mwh = eue_m2_s,
                eue_plus_firm_mwh    = eue_m2_f,
                delta_eue_storage_mwh = numer,
                delta_eue_firm_mwh   = denom,
                marginal_cc          = cc,
            ))
        end
    end
end

# Save Part B
cc_path = joinpath(PT_DIR, "market_pattern_capacity_credit.csv")
CSV.write(cc_path, DataFrame(cc_rows))
println("\n  ✓ Part B → $cc_path")

# ─────────────────────────────────────────────────────────────────────────────
# Part C: Table IV candidate rows for 2 paper-facing variants
# ─────────────────────────────────────────────────────────────────────────────

println("\n▶ Part C: Table IV candidate rows (2 paper-facing variants)")

# Build CC lookup from Part B results (δ=1 MW only)
cc_lookup = Dict{Tuple{String,String}, NamedTuple}()
for r in cc_rows
    if r.delta_mw == 1.0
        cc_lookup[(r.case_name, r.method)] = r
    end
end

tab4_rows = NamedTuple[]

for cname in CASES
    cdir = joinpath(DATA_ROOT, cname)
    sys  = load_system_data(cdir)
    cfg  = SimConfig(n_scenarios = PAPER_N, seed = SEED)
    scen = generate_scenarios(sys, cfg)
    avail = scen.availability

    for (lbl, paper_name, emerg, curtailed) in PAPER_VARIANTS
        println("  $cname / $lbl ...")
        t0 = time()
        r, _, _ = run_mp(sys, avail, cfg; emerg, curtailed)
        rt = time() - t0
        rt_per_scen = rt / PAPER_N

        m = compute_metrics(r, sys)
        cc_entry = get(cc_lookup, (cname, lbl), nothing)
        cc_val   = cc_entry === nothing ? NaN : cc_entry.marginal_cc
        cc_numer = cc_entry === nothing ? NaN : cc_entry.delta_eue_storage_mwh
        cc_denom = cc_entry === nothing ? NaN : cc_entry.delta_eue_firm_mwh

        @printf("    LOLH=%5.2f h  EUE=%8.3f MWh  NEUE=%6.3f ppm  CVaR=%8.3f MWh  CC=%6.4f  %.3f s/scen\n",
                m.lolh, m.eue, m.neue * 1e6, m.cvar_eue, isnan(cc_val) ? -999.0 : cc_val, rt_per_scen)

        push!(tab4_rows, (
            case_name              = cname,
            case_label             = CASE_LABELS[cname],
            method                 = lbl,
            paper_name             = paper_name,
            n_scenarios            = PAPER_N,
            seed                   = SEED,
            m2_risk_margin_mw      = "N/A",
            m2_window_buffer_hours = "N/A",
            lolh_hours             = m.lolh,
            eue_mwh                = m.eue,
            neue_ppm               = m.neue * 1e6,
            cvar_eue_mwh           = m.cvar_eue,
            runtime_s_per_scenario = rt_per_scen,
            cc_delta_1mw           = cc_val,
            cc_numerator_mwh       = cc_numer,
            cc_denominator_mwh     = cc_denom,
            source_script          = "70_market_pattern_marginal_cc.jl",
            configuration          = "pattern=CAISO_season_hour, emergency_override=$emerg, charge_curtailed=$curtailed, N=$PAPER_N, seed=$SEED",
        ))
    end

    # Also include M1c reference row (correct params match Table IV)
    println("  $cname / M1c (benchmark) ...")
    scen = generate_scenarios(sys, cfg)
    avail = scen.availability
    t0 = time()
    r_m1c = run_m1c_emergency_only(sys, avail, cfg)
    rt_m1c = time() - t0
    m_m1c = compute_metrics(r_m1c, sys)
    cc_m1c = get(cc_lookup, (cname, "M1c"), nothing)

    push!(tab4_rows, (
        case_name              = cname,
        case_label             = CASE_LABELS[cname],
        method                 = "M1c",
        paper_name             = "Emergency-only storage MCS",
        n_scenarios            = PAPER_N,
        seed                   = SEED,
        m2_risk_margin_mw      = "N/A",
        m2_window_buffer_hours = "N/A",
        lolh_hours             = m_m1c.lolh,
        eue_mwh                = m_m1c.eue,
        neue_ppm               = m_m1c.neue * 1e6,
        cvar_eue_mwh           = m_m1c.cvar_eue,
        runtime_s_per_scenario = rt_m1c / PAPER_N,
        cc_delta_1mw           = cc_m1c === nothing ? NaN : cc_m1c.marginal_cc,
        cc_numerator_mwh       = cc_m1c === nothing ? NaN : cc_m1c.delta_eue_storage_mwh,
        cc_denominator_mwh     = cc_m1c === nothing ? NaN : cc_m1c.delta_eue_firm_mwh,
        source_script          = "70_market_pattern_marginal_cc.jl",
        configuration          = "M1c emergency-only, N=$PAPER_N, seed=$SEED",
    ))

    # M2 reference row with correct Table IV params
    if !flags.skip_m2
        println("  $cname / M2 (correct params, benchmark) ...")
        m2cfg = SimConfig(n_scenarios = PAPER_N, seed = SEED,
                          risk_margin_mw      = M2_RISK_MW,
                          window_buffer_hours = M2_BUF_H)
        t0 = time()
        r_m2 = run_m2_event_window_lp(sys, avail, m2cfg)
        rt_m2 = time() - t0
        m_m2 = compute_metrics(r_m2, sys)
        cc_m2 = get(cc_lookup, (cname, "M2"), nothing)

        push!(tab4_rows, (
            case_name              = cname,
            case_label             = CASE_LABELS[cname],
            method                 = "M2",
            paper_name             = "Event-window storage MCS",
            n_scenarios            = PAPER_N,
            seed                   = SEED,
            m2_risk_margin_mw      = string(M2_RISK_MW),
            m2_window_buffer_hours = string(M2_BUF_H),
            lolh_hours             = m_m2.lolh,
            eue_mwh                = m_m2.eue,
            neue_ppm               = m_m2.neue * 1e6,
            cvar_eue_mwh           = m_m2.cvar_eue,
            runtime_s_per_scenario = rt_m2 / PAPER_N,
            cc_delta_1mw           = cc_m2 === nothing ? NaN : cc_m2.marginal_cc,
            cc_numerator_mwh       = cc_m2 === nothing ? NaN : cc_m2.delta_eue_storage_mwh,
            cc_denominator_mwh     = cc_m2 === nothing ? NaN : cc_m2.delta_eue_firm_mwh,
            source_script          = "70_market_pattern_marginal_cc.jl",
            configuration          = "risk_margin=$(M2_RISK_MW)MW, window_buffer=$(M2_BUF_H)h, N=$PAPER_N, seed=$SEED",
        ))
    end
end

tab4_path = joinpath(PT_DIR, "market_pattern_table_iv_rows.csv")
CSV.write(tab4_path, DataFrame(tab4_rows))
println("\n  ✓ Part C → $tab4_path")

# ─────────────────────────────────────────────────────────────────────────────
# Part E: SOC boundary check
# ─────────────────────────────────────────────────────────────────────────────

if !flags.skip_part_e
    println("\n▶ Part E: SOC boundary check")

    soc_rows = NamedTuple[]

    for cname in CASES
        cdir = joinpath(DATA_ROOT, cname)
        sys  = load_system_data(cdir)
        cfg  = SimConfig(n_scenarios = PAPER_N, seed = SEED)
        scen = generate_scenarios(sys, cfg)
        avail = scen.availability

        stor         = sys.storage
        total_energy = nrow(stor) > 0 ? sum(stor.energy_mwh) : 1.0
        nominal_init = nrow(stor) > 0 ? sum(stor.initial_soc_mwh) : 0.0
        init_frac    = nominal_init / max(total_energy, 1.0)

        println("  $cname | E_max=$total_energy MWh | init_soc=$nominal_init MWh ($(round(init_frac*100, digits=1))%)")

        for (lbl, _, emerg, curtailed) in PAPER_VARIANTS
            r, _, _ = run_mp(sys, avail, cfg; emerg, curtailed)

            # End-of-year SOC distribution (last SOC element for each scenario)
            final_socs = [res.soc[end] for res in r] ./ total_energy
            mean_final  = mean(final_socs)
            p10_final   = quantile(final_socs, 0.10)
            p90_final   = quantile(final_socs, 0.90)

            # Compare: how different is end-of-year SOC from initial?
            soc_drift  = mean_final - init_frac    # positive = gained charge

            # Cyclic SOC test: re-run with init_soc = mean end-of-year (MWh)
            cyclic_init_mwh = mean_final * total_energy
            sys_cyc  = let
                stor_cyc = copy(sys.storage)
                if nrow(stor_cyc) > 0
                    # Distribute proportionally across storage units
                    frac = cyclic_init_mwh / max(nominal_init, 0.01)
                    stor_cyc[!, :initial_soc_mwh] .= stor_cyc.initial_soc_mwh .* frac
                end
                SystemData(sys.generators, stor_cyc, sys.load_mw,
                           sys.wind_cf, sys.solar_cf, sys.n_hours)
            end
            r_cyc, _, _ = run_mp(sys_cyc, avail, cfg; emerg, curtailed)
            m_base = compute_metrics(r, sys)
            m_cyc  = compute_metrics(r_cyc, sys_cyc)

            eue_delta = m_cyc.eue - m_base.eue

            @printf("    %-20s  init=%5.3f  final_mean=%5.3f  p10=%5.3f  p90=%5.3f  drift=%+6.3f  ΔEUE_cyclic=%+7.3f MWh\n",
                    lbl, init_frac, mean_final, p10_final, p90_final, soc_drift, eue_delta)

            push!(soc_rows, (
                case_name            = cname,
                case_label           = CASE_LABELS[cname],
                method               = lbl,
                n_scenarios          = PAPER_N,
                total_energy_mwh     = total_energy,
                nominal_init_soc_mwh = nominal_init,
                nominal_init_soc_frac = init_frac,
                mean_final_soc_frac  = mean_final,
                p10_final_soc_frac   = p10_final,
                p90_final_soc_frac   = p90_final,
                soc_drift_frac       = soc_drift,
                eue_baseline_mwh     = m_base.eue,
                eue_cyclic_init_mwh  = m_cyc.eue,
                delta_eue_cyclic_mwh = eue_delta,
            ))
        end
    end

    soc_path = joinpath(PT_DIR, "market_pattern_soc_boundary_check.csv")
    CSV.write(soc_path, DataFrame(soc_rows))
    println("  ✓ Part E → $soc_path")
else
    println("\n  Part E skipped (--skip-part-e)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Part G: Sampling convergence
# ─────────────────────────────────────────────────────────────────────────────

if !flags.skip_part_g
    println("\n▶ Part G: Sampling convergence (N = ", join(CONV_NS, ", "), ")")

    conv_rows = NamedTuple[]

    for cname in CASES
        cdir = joinpath(DATA_ROOT, cname)
        sys  = load_system_data(cdir)

        println("\n  Case: $cname")

        for n in CONV_NS
            cfg   = SimConfig(n_scenarios = n, seed = SEED)
            scen  = generate_scenarios(sys, cfg)
            avail = scen.availability

            for (lbl, paper_name, emerg, curtailed) in PAPER_VARIANTS
                t0 = time()
                r, _, _ = run_mp(sys, avail, cfg; emerg, curtailed)
                rt = time() - t0
                m  = compute_metrics(r, sys)

                # CC at δ=1 MW
                sys_s = with_marginal_storage(sys, 1.0)
                r_s, _, _ = run_mp(sys_s, avail, cfg; emerg, curtailed)
                eue_s = eue_mean(r_s)

                sys_f   = with_perfect_firm(sys, 1.0)
                avail_p = avail_with_perfect_firm(avail)
                r_f, _, _ = run_mp(sys_f, avail_p, cfg; emerg, curtailed)
                eue_f = eue_mean(r_f)

                numer_cc = m.eue - eue_s
                denom_cc = m.eue - eue_f
                cc_val   = denom_cc > 1e-9 ? numer_cc / denom_cc : NaN

                @printf("    N=%3d  %-20s  LOLH=%5.2f  EUE=%8.3f  CC=%6.4f  (%.1f s)\n",
                        n, lbl, m.lolh, m.eue, isnan(cc_val) ? -999.0 : cc_val, rt)

                push!(conv_rows, (
                    case_name   = cname,
                    case_label  = CASE_LABELS[cname],
                    method      = lbl,
                    paper_name  = paper_name,
                    n_scenarios = n,
                    seed        = SEED,
                    lolh_hours  = m.lolh,
                    eue_mwh     = m.eue,
                    neue_ppm    = m.neue * 1e6,
                    cvar_eue_mwh = m.cvar_eue,
                    lolh_ci95_halfwidth = m.lolh_ci95_halfwidth,
                    eue_ci95_halfwidth  = m.eue_ci95_halfwidth,
                    cc_delta_1mw = cc_val,
                    runtime_s    = rt,
                ))
            end
        end
    end

    conv_path = joinpath(PT_DIR, "market_pattern_sampling_convergence.csv")
    CSV.write(conv_path, DataFrame(conv_rows))
    println("\n  ✓ Part G → $conv_path")
else
    println("\n  Part G skipped (--skip-part-g)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 72)
println("Part B CC summary (δ=1 MW, N=$PAPER_N, seed=$SEED)")
println("=" ^ 72)
@printf("  %-24s  %-10s  %6s  %8s  %8s  %8s\n",
        "Case", "Method", "δ=1", "EUE_base", "ΔEUE_S", "CC")
println("  " * "─" ^ 72)
for r in sort(filter(x -> x.delta_mw == 1.0, cc_rows), by = x -> (x.case_name, x.method))
    @printf("  %-24s  %-10s  %6.1f  %8.3f  %8.4f  %8.4f\n",
            r.case_label, r.method, r.delta_mw,
            r.eue_baseline_mwh, r.delta_eue_storage_mwh,
            isnan(r.marginal_cc) ? -999.0 : r.marginal_cc)
end

println("\n" * "=" ^ 72)
println("Part C Table IV candidate rows")
println("=" ^ 72)
@printf("  %-24s  %-28s  %6s  %8s  %6s  %6s\n",
        "Case", "Method", "LOLH", "EUE", "NEUE", "CC")
println("  " * "─" ^ 72)
for r in tab4_rows
    @printf("  %-24s  %-28s  %6.2f  %8.3f  %6.3f  %6.4f\n",
            r.case_label, r.paper_name, r.lolh_hours, r.eue_mwh,
            r.neue_ppm,
            isnan(r.cc_delta_1mw) ? -999.0 : r.cc_delta_1mw)
end

println("\nOutputs:")
println("  $cc_path")
println("  $tab4_path")
flags.skip_part_e || println("  $(joinpath(PT_DIR, "market_pattern_soc_boundary_check.csv"))")
flags.skip_part_g || println("  $(joinpath(PT_DIR, "market_pattern_sampling_convergence.csv"))")
println("Done: ", Dates.now())
