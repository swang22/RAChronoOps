#!/usr/bin/env julia
# 12_run_selected_storage_validation.jl
#
# 50-scenario M1/M3 validation for six selected storage cases at load_scale=1.20.
# Checks whether the 10-scenario storage matrix findings are robust at higher N.
#
# Outputs:
#   results/storage_validation/selected_storage_validation_results.csv
#   results/storage_validation/selected_storage_validation_errors.csv
#   results/storage_validation/selected_storage_validation_summary.txt
#
# Usage:
#   julia --project=. scripts/12_run_selected_storage_validation.jl
#   julia --project=. scripts/12_run_selected_storage_validation.jl --n-scenarios 50 --seed 42
#   julia --project=. scripts/12_run_selected_storage_validation.jl --cases storage120_p10_d4,storage120_p20_d2 --models M1,M3

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Printf
using Statistics

# ── CLI ───────────────────────────────────────────────────────────────────────
function _parse_cli(args)
    d = Dict{String,String}()
    i = 1
    while i <= length(args)
        k = args[i]
        if i < length(args) && startswith(k, "--")
            d[lstrip(k, '-')] = args[i+1]
            i += 2
        else
            i += 1
        end
    end
    return d
end

cli = _parse_cli(ARGS)
const N_SCENARIOS = parse(Int, get(cli, "n-scenarios", "50"))
const SEED        = parse(Int, get(cli, "seed",        "42"))

const DEFAULT_CASES = [
    "storage120_p05_d4",
    "storage120_p10_d2",
    "storage120_p10_d4",
    "storage120_p10_d8",
    "storage120_p20_d2",
    "storage120_p20_d4",
]
const DEFAULT_MODELS = ["M1", "M3"]

const SEL_CASES  = haskey(cli, "cases")  ? split(cli["cases"],  ",") : DEFAULT_CASES
const SEL_MODELS = haskey(cli, "models") ? split(cli["models"], ",") : DEFAULT_MODELS

# ── Monte Carlo 95% CI ────────────────────────────────────────────────────────
function _mc_ci95(values::Vector{Float64})
    n = length(values)
    n < 2 && return (hw=NaN, rel=NaN)
    hat = mean(values)
    se  = std(values) / sqrt(n)
    hw  = 1.96 * se
    rel = hat > 0.0 ? hw / hat : NaN
    return (hw=hw, rel=rel)
end

# ── row builders ──────────────────────────────────────────────────────────────
function _result_row(case_name, tag, meta, m, eue_ci, loh_ci, rt, status, err_msg)
    return (
        case_name               = case_name,
        model                   = tag,
        n_scenarios             = N_SCENARIOS,
        seed                    = SEED,
        load_scale              = meta.load_scale,
        storage_power_pct_peak  = meta.storage_power_pct_peak,
        storage_duration_hours  = Int(meta.storage_duration_hours),
        storage_power_mw        = meta.storage_power_mw,
        storage_energy_mwh      = meta.storage_energy_mwh,
        lolh_hours              = m.lolh,
        eue_mwh                 = m.eue,
        neue_ppm                = m.neue * 1e6,
        cvar_eue_mwh            = m.cvar_eue,
        n_events                = m.n_shortage_events,
        max_shortfall_mw        = m.max_shortfall,
        eue_ci95_halfwidth_mwh  = eue_ci.hw,
        eue_ci95_rel_halfwidth  = eue_ci.rel,
        lolh_ci95_halfwidth     = loh_ci.hw,
        lolh_ci95_rel_halfwidth = loh_ci.rel,
        runtime_s               = rt,
        status                  = status,
        error_message           = err_msg,
    )
end

function _nan_row(case_name, tag, meta, rt, err_msg)
    return (
        case_name               = case_name,
        model                   = tag,
        n_scenarios             = N_SCENARIOS,
        seed                    = SEED,
        load_scale              = meta.load_scale,
        storage_power_pct_peak  = meta.storage_power_pct_peak,
        storage_duration_hours  = Int(meta.storage_duration_hours),
        storage_power_mw        = meta.storage_power_mw,
        storage_energy_mwh      = meta.storage_energy_mwh,
        lolh_hours              = NaN,
        eue_mwh                 = NaN,
        neue_ppm                = NaN,
        cvar_eue_mwh            = NaN,
        n_events                = NaN,
        max_shortfall_mw        = NaN,
        eue_ci95_halfwidth_mwh  = NaN,
        eue_ci95_rel_halfwidth  = NaN,
        lolh_ci95_halfwidth     = NaN,
        lolh_ci95_rel_halfwidth = NaN,
        runtime_s               = rt,
        status                  = "error",
        error_message           = err_msg,
    )
end

# ── model function map ────────────────────────────────────────────────────────
const MODEL_FNS = Dict(
    "M1" => run_m1_rule_based,
    "M3" => run_m3_ed_dispatch,
)

let
    project_root  = joinpath(@__DIR__, "..")
    cases_dir     = joinpath(project_root, "data_processed", "cases")
    conf_dir      = joinpath(project_root, "configs")
    out_dir       = joinpath(project_root, "results", "storage_validation")
    mkpath(out_dir)

    results_path = joinpath(out_dir, "selected_storage_validation_results.csv")
    errors_path  = joinpath(out_dir, "selected_storage_validation_errors.csv")
    summary_path = joinpath(out_dir, "selected_storage_validation_summary.txt")

    function _get_cfg(name)
        p = joinpath(conf_dir, "$name.yaml")
        isfile(p) ? load_config(p) : SimConfig()
    end
    cfgs = Dict("M1" => _get_cfg("m1"), "M3" => _get_cfg("m3"))

    t_total = time()
    println("=" ^ 80)
    @printf "Selected Storage Validation | %s | %d scenarios | seed=%d\n" join(SEL_MODELS, "+") N_SCENARIOS SEED
    @printf "Cases: %s\n" join(SEL_CASES, ", ")
    println("=" ^ 80)

    all_rows = NamedTuple[]

    for case_name in SEL_CASES
        case_dir = joinpath(cases_dir, string(case_name))
        isdir(case_dir) || error("Case not found: $case_dir\nRun scripts/06_build_experiment_cases.jl first.")

        meta = CSV.read(joinpath(case_dir, "case_metadata.csv"), DataFrame)[1, :]

        println("\n--- $case_name  (pct=$(Int(round(meta.storage_power_pct_peak*100)))%  dur=$(Int(meta.storage_duration_hours))h  pwr=$(Int(meta.storage_power_mw))MW) ---")

        sys = load_system_data(case_dir)
        sys.n_hours == 8760 || error("Case $case_name: expected 8760 h, got $(sys.n_hours)")

        crn_cfg   = SimConfig(; n_scenarios=N_SCENARIOS, seed=SEED)
        scenarios = generate_scenarios(sys, crn_cfg)

        for tag in SEL_MODELS
            fn  = get(MODEL_FNS, string(tag), nothing)
            isnothing(fn) && error("Unknown model: $tag")
            cfg = cfgs[string(tag)]

            t0  = time()
            res = try
                fn(sys, scenarios, cfg)
            catch e
                err_msg = sprint(showerror, e)
                println("  $tag FAILED: $err_msg")
                push!(all_rows, _nan_row(string(case_name), string(tag), meta, time()-t0, err_msg))
                CSV.write(results_path, DataFrame(all_rows))
                continue
            end
            rt = time() - t0

            m      = compute_metrics(res, sys, cfg)
            sm     = build_scenario_metrics_df(res)
            eue_ci = _mc_ci95(m.scenario_eue)
            loh_ci = _mc_ci95(sm.lolh_hours)

            ci_str = isnan(eue_ci.rel) ? "     ---" : @sprintf("%7.1f%%", eue_ci.rel * 100)
            @printf "  %-3s  LOLH=%7.2f h  EUE=%9.1f MWh  CVaR=%9.1f  CI95_EUE=%s  t=%7.1f s\n" tag m.lolh m.eue m.cvar_eue ci_str rt

            push!(all_rows, _result_row(string(case_name), string(tag), meta, m, eue_ci, loh_ci, rt, "ok", ""))
            CSV.write(results_path, DataFrame(all_rows))
        end
    end

    # ── errors file ───────────────────────────────────────────────────────────
    df    = DataFrame(all_rows)
    m1_ok = filter(r -> r.model == "M1" && r.status == "ok", df)
    m3_ok = filter(r -> r.model == "M3" && r.status == "ok", df)

    m1_sel = select(m1_ok,
        :case_name, :load_scale, :storage_power_pct_peak, :storage_duration_hours,
        :storage_power_mw, :storage_energy_mwh,
        :lolh_hours  => :m1_lolh_hours,
        :eue_mwh     => :m1_eue_mwh,
        :cvar_eue_mwh => :m1_cvar_eue_mwh,
        :n_events    => :m1_n_events,
        :max_shortfall_mw => :m1_max_shortfall_mw,
        :runtime_s   => :runtime_m1_s,
    )
    m3_sel = select(m3_ok,
        :case_name,
        :lolh_hours  => :m3_lolh_hours,
        :eue_mwh     => :m3_eue_mwh,
        :cvar_eue_mwh => :m3_cvar_eue_mwh,
        :n_events    => :m3_n_events,
        :max_shortfall_mw => :m3_max_shortfall_mw,
        :runtime_s   => :runtime_m3_s,
    )

    err_df = innerjoin(m1_sel, m3_sel; on=:case_name)
    err_df[!, :delta_lolh_m1_minus_m3]  = err_df.m1_lolh_hours  .- err_df.m3_lolh_hours
    err_df[!, :delta_eue_m1_minus_m3]   = err_df.m1_eue_mwh     .- err_df.m3_eue_mwh
    err_df[!, :delta_cvar_m1_minus_m3]  = err_df.m1_cvar_eue_mwh .- err_df.m3_cvar_eue_mwh
    err_df[!, :runtime_ratio_m3_vs_m1]  = err_df.runtime_m3_s ./ err_df.runtime_m1_s

    # reorder columns to match spec
    col_order = [:case_name, :load_scale, :storage_power_pct_peak, :storage_duration_hours,
                 :storage_power_mw, :storage_energy_mwh,
                 :m1_lolh_hours, :m3_lolh_hours, :delta_lolh_m1_minus_m3,
                 :m1_eue_mwh, :m3_eue_mwh, :delta_eue_m1_minus_m3,
                 :m1_cvar_eue_mwh, :m3_cvar_eue_mwh, :delta_cvar_m1_minus_m3,
                 :m1_n_events, :m3_n_events,
                 :m1_max_shortfall_mw, :m3_max_shortfall_mw,
                 :runtime_m1_s, :runtime_m3_s, :runtime_ratio_m3_vs_m1]
    err_df = select(err_df, [c for c in col_order if c in Symbol.(names(err_df))])
    CSV.write(errors_path, err_df)

    # ── terminal summary table ────────────────────────────────────────────────
    total_rt = time() - t_total
    println("\n" * "=" ^ 110)
    println("Selected Storage Validation Summary")
    println("=" ^ 110)
    @printf "%-22s %5s %5s %9s %9s %11s %11s %15s %14s %16s\n" "case_name" "pct%" "dur_h" "M1_LOLH" "M3_LOLH" "M1_EUE" "M3_EUE" "EUE_gap_M1-M3" "M3_runtime_s" "M3_EUE_CI95_rel"
    println("-" ^ 110)

    m1_lut = Dict(r.case_name => r for r in eachrow(filter(r -> r.model == "M1" && r.status == "ok", df)))
    m3_lut = Dict(r.case_name => r for r in eachrow(filter(r -> r.model == "M3" && r.status == "ok", df)))

    sorted_cases = sort(
        [c for c in SEL_CASES if haskey(m3_lut, string(c))],
        by = c -> (m3_lut[string(c)].storage_power_pct_peak,
                   m3_lut[string(c)].storage_duration_hours)
    )

    for c in sorted_cases
        cn  = string(c)
        m1  = get(m1_lut, cn, nothing)
        m3  = get(m3_lut, cn, nothing)
        m1l = isnothing(m1) ? NaN : m1.lolh_hours
        m1e = isnothing(m1) ? NaN : m1.eue_mwh
        m3l = m3.lolh_hours
        m3e = m3.eue_mwh
        m3r = m3.runtime_s
        m3ci_str = isnan(m3.eue_ci95_rel_halfwidth) ? "         ---" : @sprintf("%15.1f%%", m3.eue_ci95_rel_halfwidth * 100)
        pct = Int(round(m3.storage_power_pct_peak * 100))
        dur = Int(m3.storage_duration_hours)
        @printf "%-22s %5d %5d %9.2f %9.2f %11.1f %11.1f %15.1f %14.1f %s\n" cn pct dur m1l m3l m1e m3e (m1e-m3e) m3r m3ci_str
    end
    println("=" ^ 110)
    @printf "\nTotal runtime: %.0f s (%.1f h)\n" total_rt (total_rt/3600)

    # ── summary text file ─────────────────────────────────────────────────────
    open(summary_path, "w") do f
        println(f, "Selected Storage Validation Summary")
        println(f, "N=$(N_SCENARIOS) scenarios, seed=$(SEED), load_scale=1.20")
        println(f, "=" ^ 72)
        println(f)

        function _val(cn, model, field)
            lut = model == "M3" ? m3_lut : m1_lut
            r   = get(lut, cn, nothing)
            isnothing(r) ? NaN : Float64(r[field])
        end

        # 1. Is 10%/4h near target?
        lolh_p10d4 = _val("storage120_p10_d4", "M3", :lolh_hours)
        ci_p10d4   = _val("storage120_p10_d4", "M3", :lolh_ci95_halfwidth)
        println(f, "1. Is 10%/4h near the 10 h/yr reliability target?")
        if !isnan(lolh_p10d4)
            delta = abs(lolh_p10d4 - 10.0)
            verdict = delta <= 3.0 ? "YES — within 3 h/yr of target" :
                      delta <= 6.0 ? "MARGINAL — within 6 h/yr of target" :
                                     "NO — more than 6 h/yr from target"
            @printf(f, "   p10_d4  M3 LOLH = %.2f h/yr  (target 10 h/yr, delta = %.2f h)\n", lolh_p10d4, delta)
            isnan(ci_p10d4) || @printf(f, "   LOLH CI95 halfwidth = ±%.2f h\n", ci_p10d4)
            println(f, "   Verdict: $verdict")
        else
            println(f, "   p10_d4 result not available.")
        end
        println(f)

        # 2. 2h→4h gain at 10%
        lolh_p10d2 = _val("storage120_p10_d2", "M3", :lolh_hours)
        eue_p10d2  = _val("storage120_p10_d2", "M3", :eue_mwh)
        eue_p10d4  = _val("storage120_p10_d4", "M3", :eue_mwh)
        println(f, "2. Does increasing duration 2h→4h at 10% give a large reliability gain?")
        if !isnan(lolh_p10d2) && !isnan(lolh_p10d4) && !isnan(eue_p10d2) && !isnan(eue_p10d4)
            lolh_drop = lolh_p10d2 - lolh_p10d4
            eue_drop_pct = eue_p10d2 > 0.0 ? (eue_p10d2 - eue_p10d4) / eue_p10d2 * 100 : NaN
            verdict = lolh_drop > 5.0 ? "YES — large LOLH reduction" :
                      lolh_drop > 2.0 ? "MODERATE" : "NO — small gain"
            @printf(f, "   p10_d2  M3 LOLH = %.2f h/yr  EUE = %.1f MWh\n", lolh_p10d2, eue_p10d2)
            @printf(f, "   p10_d4  M3 LOLH = %.2f h/yr  EUE = %.1f MWh\n", lolh_p10d4, eue_p10d4)
            @printf(f, "   LOLH reduction: %.2f h/yr  |  EUE reduction: %.1f%%\n", lolh_drop, eue_drop_pct)
            println(f, "   Verdict: $verdict")
        else
            println(f, "   Insufficient data.")
        end
        println(f)

        # 3. 4h→8h diminishing returns at 10%
        lolh_p10d8 = _val("storage120_p10_d8", "M3", :lolh_hours)
        eue_p10d8  = _val("storage120_p10_d8", "M3", :eue_mwh)
        println(f, "3. Does increasing duration 4h→8h at 10% show diminishing returns?")
        if !isnan(lolh_p10d4) && !isnan(lolh_p10d8) && !isnan(eue_p10d4) && !isnan(eue_p10d8)
            lolh_drop_48 = lolh_p10d4 - lolh_p10d8
            lolh_drop_24 = isnan(lolh_p10d2) ? NaN : lolh_p10d2 - lolh_p10d4
            verdict = if !isnan(lolh_drop_24) && lolh_drop_48 < 0.5 * lolh_drop_24
                "YES — 4h→8h gain is less than half of 2h→4h gain"
            elseif lolh_drop_48 < 2.0
                "YES — absolute gain is small (< 2 h/yr)"
            else
                "NO — substantial gain remains"
            end
            @printf(f, "   p10_d4  M3 LOLH = %.2f h/yr  EUE = %.1f MWh\n", lolh_p10d4, eue_p10d4)
            @printf(f, "   p10_d8  M3 LOLH = %.2f h/yr  EUE = %.1f MWh\n", lolh_p10d8, eue_p10d8)
            @printf(f, "   LOLH reduction 4h→8h: %.2f h/yr\n", lolh_drop_48)
            isnan(lolh_drop_24) || @printf(f, "   LOLH reduction 2h→4h: %.2f h/yr  (for comparison)\n", lolh_drop_24)
            println(f, "   Verdict: $verdict")
        else
            println(f, "   Insufficient data.")
        end
        println(f)

        # 4. 20%/4h near-zero scarcity?
        lolh_p20d4 = _val("storage120_p20_d4", "M3", :lolh_hours)
        eue_p20d4  = _val("storage120_p20_d4", "M3", :eue_mwh)
        println(f, "4. Does 20%/4h remain near-zero scarcity?")
        if !isnan(lolh_p20d4)
            verdict = lolh_p20d4 < 1.0 ? "YES — LOLH < 1 h/yr" :
                      lolh_p20d4 < 5.0 ? "NEAR-ZERO — LOLH < 5 h/yr" :
                                          "NO — LOLH ≥ 5 h/yr"
            @printf(f, "   p20_d4  M3 LOLH = %.2f h/yr  EUE = %.1f MWh\n", lolh_p20d4, eue_p20d4)
            println(f, "   Verdict: $verdict")
        else
            println(f, "   p20_d4 result not available.")
        end
        println(f)

        # 5. p10_d4 vs p20_d2 EUE — still similar?
        eue_p20d2  = _val("storage120_p20_d2", "M3", :eue_mwh)
        lolh_p20d2 = _val("storage120_p20_d2", "M3", :lolh_hours)
        println(f, "5. Do p10_d4 and p20_d2 still have similar EUE with 50 scenarios?")
        if !isnan(eue_p10d4) && !isnan(eue_p20d2)
            eue_diff     = abs(eue_p10d4 - eue_p20d2)
            eue_rel_diff = max(eue_p10d4, eue_p20d2) > 0.0 ? eue_diff / max(eue_p10d4, eue_p20d2) * 100 : NaN
            verdict = eue_rel_diff < 5.0 ? "STILL SIMILAR — within 5% relative" :
                      eue_rel_diff < 20.0 ? "DIVERGED SOMEWHAT — 5–20% relative difference" :
                                             "CLEARLY DIVERGED — >20% relative difference"
            @printf(f, "   p10_d4  M3 LOLH = %.2f h/yr  EUE = %.1f MWh\n", lolh_p10d4, eue_p10d4)
            @printf(f, "   p20_d2  M3 LOLH = %.2f h/yr  EUE = %.1f MWh\n", lolh_p20d2, eue_p20d2)
            @printf(f, "   |EUE difference| = %.1f MWh  (%.1f%% relative)\n", eue_diff, eue_rel_diff)
            println(f, "   Verdict: $verdict")
            println(f, "   Note: At 10 scenarios, EUE was identical (32,453 MWh) — a sampling coincidence.")
        else
            println(f, "   Insufficient data.")
        end
        println(f)

        # 6. M1 systematic overestimation?
        println(f, "6. Does M1 systematically overestimate scarcity relative to M3?")
        m1_lolh_vals = [_val(string(c), "M1", :lolh_hours) for c in SEL_CASES]
        m3_lolh_vals = [_val(string(c), "M3", :lolh_hours) for c in SEL_CASES]
        valid = [(a, b) for (a, b) in zip(m1_lolh_vals, m3_lolh_vals) if !isnan(a) && !isnan(b) && b > 0.0]
        if length(valid) >= 2
            ratios = [a / b for (a, b) in valid]
            println(f, "   M1/M3 LOLH ratios across cases with M3 LOLH > 0:")
            for (cn, (a, b)) in zip(SEL_CASES, zip(m1_lolh_vals, m3_lolh_vals))
                (!isnan(a) && !isnan(b)) || continue
                ratio_str = b > 0.0 ? @sprintf("%.1f×", a/b) : "(M3=0)"
                @printf(f, "     %-22s  M1=%.2f  M3=%.2f  ratio=%s\n", string(cn), a, b, ratio_str)
            end
            med_ratio = median(ratios)
            @printf(f, "   Median M1/M3 ratio: %.1f×\n", med_ratio)
            verdict = med_ratio > 5.0  ? "YES — M1 strongly overestimates (median >5× M3)" :
                      med_ratio > 2.0  ? "YES — M1 moderately overestimates (median 2–5× M3)" :
                                          "WEAK — M1/M3 ratio is within 2×"
            println(f, "   Verdict: $verdict")
        else
            println(f, "   Insufficient data for comparison.")
        end
        println(f)
        println(f, "=" ^ 72)
        @printf(f, "Total runtime: %.0f s (%.1f h)\n", total_rt, total_rt/3600)
    end

    println("\nSummary text → $summary_path")
    println("Results CSV  → $results_path")
    println("Errors CSV   → $errors_path")
end
