#!/usr/bin/env julia
# 11_debug_storage_cases.jl
#
# Investigates the EUE/LOLH anomaly between storage120_p10_d4 and
# storage120_p20_d2, which produced identical metrics in the storage matrix
# run despite very different storage configurations (983 MW/4h vs 1966 MW/2h).
#
# Outputs (per case, under results/storage_debug/<case_name>/):
#   m3_dispatch.csv      — full hourly dispatch for all scenarios
#   scenario_metrics.csv — per-scenario LOLH, EUE, n_events, max_shortfall
#   shortage_hours.csv   — rows where load_shed_mw > 0
#
# Cross-case comparison:
#   results/storage_debug/p10d4_vs_p20d2_shortage_comparison.csv
#
# Usage:
#   julia --project=. scripts/11_debug_storage_cases.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Printf
using Statistics

const DEBUG_CASES = ["storage120_p10_d4", "storage120_p20_d2"]
const N_SCENARIOS = 10
const SEED        = 42

# ── helpers ───────────────────────────────────────────────────────────────────
function _mc_ci95(values::Vector{Float64})
    n = length(values)
    n < 2 && return (hw=NaN, rel=NaN)
    hat = mean(values)
    se  = std(values) / sqrt(n)
    hw  = 1.96 * se
    rel = hat > 0.0 ? hw / hat : NaN
    return (hw=hw, rel=rel)
end

function _coalesce_f(x)
    ismissing(x) ? NaN : Float64(x)
end

let
    project_root = joinpath(@__DIR__, "..")
    cases_dir    = joinpath(project_root, "data_processed", "cases")
    conf_dir     = joinpath(project_root, "configs")
    out_root     = joinpath(project_root, "results", "storage_debug")
    mkpath(out_root)

    function _get_cfg(name)
        p = joinpath(conf_dir, "$name.yaml")
        isfile(p) ? load_config(p) : SimConfig()
    end
    m3_cfg = _get_cfg("m3")

    # Shared CRN — must match the storage matrix run exactly
    crn_cfg   = SimConfig(; n_scenarios=N_SCENARIOS, seed=SEED)

    shortage_dfs = Dict{String, DataFrame}()

    for case_name in DEBUG_CASES
        case_dir = joinpath(cases_dir, case_name)
        isdir(case_dir) || error("Case not found: $case_dir")
        out_dir  = joinpath(out_root, case_name)
        mkpath(out_dir)

        println("\n" * "=" ^ 72)
        println("Case: $case_name")
        println("=" ^ 72)

        sys       = load_system_data(case_dir)
        scenarios = generate_scenarios(sys, crn_cfg)

        t0  = time()
        res = run_m3_ed_dispatch(sys, scenarios, m3_cfg)
        rt  = time() - t0
        @printf "  M3 completed in %.1f s\n" rt

        # ── dispatch ──────────────────────────────────────────────────────────
        disp_df = build_dispatch_df(res, sys, scenarios)
        CSV.write(joinpath(out_dir, "m3_dispatch.csv"), disp_df)

        # ── scenario metrics ──────────────────────────────────────────────────
        sm_df = build_scenario_metrics_df(res)
        CSV.write(joinpath(out_dir, "scenario_metrics.csv"), sm_df)

        # ── aggregate metrics for reference ───────────────────────────────────
        m      = compute_metrics(res, sys, m3_cfg)
        eue_ci = _mc_ci95(m.scenario_eue)
        ci_str = isnan(eue_ci.rel) ? "      ---" : @sprintf("%8.1f%%", eue_ci.rel * 100)
        @printf "  LOLH=%7.2f h  EUE=%9.1f MWh  CVaR=%9.1f  CI95=%s\n" m.lolh m.eue m.cvar_eue ci_str

        # ── shortage hours ────────────────────────────────────────────────────
        shortage = filter(r -> r.load_shed_mw > 0.0, disp_df)
        CSV.write(joinpath(out_dir, "shortage_hours.csv"), shortage)

        shortage_dfs[case_name] = shortage

        println("  Shortage rows: $(size(shortage, 1))")
        if size(shortage, 1) > 0
            scens_with_short = sort(unique(shortage.scenario_id))
            println("  Scenarios with shortage: $scens_with_short")
            @printf "  Total load-shed: %.4f MWh\n" sum(shortage.load_shed_mw)
            println()
            @printf "  %-6s %6s %10s %12s %13s %10s\n" "scen" "hour" "load_mw" "charge_mw" "discharge_mw" "shed_mw"
            println("  " * "-" ^ 62)
            for r in eachrow(shortage)
                @printf "  %-6d %6d %10.1f %12.2f %13.2f %10.4f\n" r.scenario_id r.hour r.load_mw r.storage_charge_mw r.storage_discharge_mw r.load_shed_mw
            end
        end
    end

    # ── cross-case comparison ─────────────────────────────────────────────────
    println("\n" * "=" ^ 72)
    println("Cross-case comparison: p10_d4 vs p20_d2")
    println("=" ^ 72)

    df_a = shortage_dfs["storage120_p10_d4"]
    df_b = shortage_dfs["storage120_p20_d2"]

    key_a = Set(zip(df_a.scenario_id, df_a.hour))
    key_b = Set(zip(df_b.scenario_id, df_b.hour))

    same_keys  = key_a == key_b
    only_in_a  = setdiff(key_a, key_b)
    only_in_b  = setdiff(key_b, key_a)

    @printf "  p10_d4 shortage rows : %d\n" size(df_a, 1)
    @printf "  p20_d2 shortage rows : %d\n" size(df_b, 1)
    @printf "  Identical (scen,hour) sets : %s\n" string(same_keys)
    @printf "  Only in p10_d4 : %d pairs\n" length(only_in_a)
    @printf "  Only in p20_d2 : %d pairs\n" length(only_in_b)
    println()

    # Build comparison via outer join
    a_slim = select(df_a,
        :scenario_id, :hour,
        :load_mw,
        :wind_mw,
        :solar_mw,
        :thermal_dispatch_mw,
        :storage_charge_mw    => :charge_p10d4,
        :storage_discharge_mw => :discharge_p10d4,
        :storage_soc_mwh      => :soc_p10d4,
        :curtailment_mw       => :curtail_p10d4,
        :load_shed_mw         => :shed_p10d4,
    )
    b_slim = select(df_b,
        :scenario_id, :hour,
        :storage_charge_mw    => :charge_p20d2,
        :storage_discharge_mw => :discharge_p20d2,
        :storage_soc_mwh      => :soc_p20d2,
        :curtailment_mw       => :curtail_p20d2,
        :load_shed_mw         => :shed_p20d2,
    )

    comp = outerjoin(a_slim, b_slim; on=[:scenario_id, :hour])
    comp = comp[sortperm(collect(zip(comp.scenario_id, comp.hour))), :]
    CSV.write(joinpath(out_root, "p10d4_vs_p20d2_shortage_comparison.csv"), comp)

    # ── identity checks ───────────────────────────────────────────────────────
    if size(comp, 1) > 0
        shed_a  = _coalesce_f.(comp.shed_p10d4)
        shed_b  = _coalesce_f.(comp.shed_p20d2)
        ch_a    = _coalesce_f.(comp.charge_p10d4)
        ch_b    = _coalesce_f.(comp.charge_p20d2)
        dis_a   = _coalesce_f.(comp.discharge_p10d4)
        dis_b   = _coalesce_f.(comp.discharge_p20d2)
        soc_a   = _coalesce_f.(comp.soc_p10d4)
        soc_b   = _coalesce_f.(comp.soc_p20d2)

        shed_match     = all(isapprox.(shed_a,  shed_b;  atol=1e-6))
        charge_match   = all(isapprox.(ch_a,    ch_b;    atol=1e-6))
        dis_match      = all(isapprox.(dis_a,   dis_b;   atol=1e-6))

        @printf "  Load-shed amounts identical   : %s\n" string(shed_match)
        @printf "  Storage charge identical      : %s\n" string(charge_match)
        @printf "  Storage discharge identical   : %s\n" string(dis_match)
        println()

        println("  Shortage-hour detail:")
        @printf "  %-4s %5s %9s  %9s %10s %8s  %9s %10s %8s\n" "scen" "hour" "load_mw" "ch_p10d4" "dis_p10d4" "shed_p10d4" "ch_p20d2" "dis_p20d2" "shed_p20d2"
        println("  " * "-" ^ 90)
        for r in eachrow(comp)
            @printf "  %-4s %5s %9.1f  %9.2f %10.2f %10.4f  %9.2f %10.2f %10.4f\n" string(r.scenario_id) string(r.hour) _coalesce_f(r.load_mw) _coalesce_f(r.charge_p10d4) _coalesce_f(r.discharge_p10d4) _coalesce_f(r.shed_p10d4) _coalesce_f(r.charge_p20d2) _coalesce_f(r.discharge_p20d2) _coalesce_f(r.shed_p20d2)
        end

        # Summary of SOC differences at shortage hours
        if !all(isapprox.(soc_a, soc_b; atol=1e-6))
            println()
            println("  SOC differs between cases at shortage hours (p10_d4 vs p20_d2):")
            for (i, r) in enumerate(eachrow(comp))
                if !isapprox(soc_a[i], soc_b[i]; atol=1e-6)
                    @printf "    scen=%s hour=%s  soc_p10d4=%.2f  soc_p20d2=%.2f  delta=%.2f MWh\n" string(r.scenario_id) string(r.hour) soc_a[i] soc_b[i] (soc_a[i]-soc_b[i])
                end
            end
        end
    end

    println("\nResults → $out_root")
end
