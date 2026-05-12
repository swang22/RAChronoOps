#!/usr/bin/env julia
# 10_run_storage_matrix.jl
#
# Runs M1 and M3 across the calibrated storage matrix (storage120_* cases,
# all at load_scale = 1.20).  Intermediate results are written after every
# model × case so the file is usable even if the run is interrupted.
#
# Outputs:
#   results/storage_matrix/storage_matrix_results.csv
#   results/storage_matrix/storage_matrix_errors.csv
#
# Usage:
#   julia --project=. scripts/10_run_storage_matrix.jl
#   julia --project=. scripts/10_run_storage_matrix.jl --n-scenarios 10 --seed 42

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
const N_SCENARIOS = parse(Int, get(cli, "n-scenarios", "10"))
const SEED        = parse(Int, get(cli, "seed",        "42"))

const STORAGE120_CASES = [
    "storage120_p05_d2",  "storage120_p05_d4",  "storage120_p05_d8",  "storage120_p05_d12",
    "storage120_p10_d2",  "storage120_p10_d4",  "storage120_p10_d8",  "storage120_p10_d12",
    "storage120_p20_d2",  "storage120_p20_d4",  "storage120_p20_d8",  "storage120_p20_d12",
]

# ── Monte Carlo 95% CI ────────────────────────────────────────────────────────
function _mc_ci95(values::Vector{Float64})
    n   = length(values)
    n < 2 && return (hw=NaN, rel=NaN)
    hat = mean(values)
    se  = std(values) / sqrt(n)
    hw  = 1.96 * se
    rel = hat > 0.0 ? hw / hat : NaN
    return (hw=hw, rel=rel)
end

# ── helpers ───────────────────────────────────────────────────────────────────
function _nan_row(case_name, tag, meta, err_msg)
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
        eue_ci95_halfwidth_mwh  = NaN,
        eue_ci95_rel_halfwidth  = NaN,
        runtime_s               = NaN,
        status                  = "error",
        error_message           = err_msg,
    )
end

function _ok_row(case_name, tag, meta, m, eue_ci, rt)
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
        eue_ci95_halfwidth_mwh  = eue_ci.hw,
        eue_ci95_rel_halfwidth  = eue_ci.rel,
        runtime_s               = rt,
        status                  = "ok",
        error_message           = "",
    )
end

let
    project_root  = joinpath(@__DIR__, "..")
    cases_dir     = joinpath(project_root, "data_processed", "cases")
    conf_dir      = joinpath(project_root, "configs")
    out_dir       = joinpath(project_root, "results", "storage_matrix")
    mkpath(out_dir)

    results_path = joinpath(out_dir, "storage_matrix_results.csv")
    errors_path  = joinpath(out_dir, "storage_matrix_errors.csv")

    function _get_cfg(name)
        p = joinpath(conf_dir, "$name.yaml")
        isfile(p) ? load_config(p) : SimConfig()
    end
    m1_cfg = _get_cfg("m1")
    m3_cfg = _get_cfg("m3")

    println("=" ^ 80)
    @printf "Storage Matrix | M1 + M3 | %d scenarios | seed=%d | %d cases\n" N_SCENARIOS SEED length(STORAGE120_CASES)
    println("=" ^ 80)

    all_rows = NamedTuple[]

    for case_name in STORAGE120_CASES
        case_dir = joinpath(cases_dir, case_name)
        isdir(case_dir) || error("Case not found: $case_dir\n" *
                                  "Run scripts/06_build_experiment_cases.jl first.")

        meta = CSV.read(joinpath(case_dir, "case_metadata.csv"), DataFrame)[1, :]
        println("\n--- $case_name  (pct=$(Int(round(meta.storage_power_pct_peak*100)))%  dur=$(Int(meta.storage_duration_hours))h  pwr=$(Int(meta.storage_power_mw))MW) ---")

        sys = load_system_data(case_dir)
        sys.n_hours == 8760 || error("Case $case_name: expected 8760 h, got $(sys.n_hours)")

        crn_cfg   = SimConfig(; n_scenarios=N_SCENARIOS, seed=SEED)
        scenarios = generate_scenarios(sys, crn_cfg)

        for (tag, fn, cfg) in [("M1", run_m1_rule_based,  m1_cfg),
                                ("M3", run_m3_ed_dispatch, m3_cfg)]
            t0  = time()
            res = try
                fn(sys, scenarios, cfg)
            catch e
                err_msg = sprint(showerror, e)
                println("  $tag FAILED: $err_msg")
                push!(all_rows, _nan_row(case_name, tag, meta, err_msg))
                CSV.write(results_path, DataFrame(all_rows))
                continue
            end
            rt = time() - t0

            m      = compute_metrics(res, sys, cfg)
            eue_ci = _mc_ci95(m.scenario_eue)

            ci_str = isnan(eue_ci.rel) ? "   ---" : @sprintf("%5.0f%%", eue_ci.rel * 100)
            @printf "  %-3s  LOLH=%7.2f h  EUE=%9.1f MWh  CVaR=%9.1f  EUE_CI95=%s  t=%6.1f s\n" tag m.lolh m.eue m.cvar_eue ci_str rt

            push!(all_rows, _ok_row(case_name, tag, meta, m, eue_ci, rt))
            CSV.write(results_path, DataFrame(all_rows))   # incremental save
        end
    end

    # ── errors file ───────────────────────────────────────────────────────────
    df = DataFrame(all_rows)

    m1_ok = select(
        filter(r -> r.model == "M1" && r.status == "ok", df),
        :case_name,
        :load_scale, :storage_power_pct_peak, :storage_duration_hours,
        :storage_power_mw, :storage_energy_mwh,
        :eue_mwh     => :eue_m1_mwh,
        :lolh_hours  => :lolh_m1_hours,
        :runtime_s   => :runtime_m1_s,
    )
    m3_ok = select(
        filter(r -> r.model == "M3" && r.status == "ok", df),
        :case_name,
        :eue_mwh    => :eue_m3_mwh,
        :lolh_hours => :lolh_m3_hours,
        :runtime_s  => :runtime_m3_s,
    )

    err_df = innerjoin(m1_ok, m3_ok; on=:case_name)
    err_df[!, :delta_eue_mwh]          = err_df.eue_m1_mwh  .- err_df.eue_m3_mwh
    err_df[!, :delta_lolh_hours]       = err_df.lolh_m1_hours .- err_df.lolh_m3_hours
    err_df[!, :runtime_ratio_m3_vs_m1] = err_df.runtime_m3_s ./ err_df.runtime_m1_s

    CSV.write(errors_path, err_df)

    # ── summary table ─────────────────────────────────────────────────────────
    println("\n" * "=" ^ 104)
    println("Storage Matrix Summary  (sorted by pct_peak / duration)")
    println("=" ^ 104)
    @printf "%-22s %6s %5s %8s %10s %10s %12s %12s %14s\n" "case_name" "pct%" "dur_h" "pwr_mw" "M1_LOLH" "M3_LOLH" "M1_EUE_MWh" "M3_EUE_MWh" "M3_runtime_s"
    println("-" ^ 104)

    m3_filt = filter(r -> r.model == "M3" && r.status == "ok", df)
    m3_rows = m3_filt[sortperm(collect(zip(m3_filt.storage_power_pct_peak,
                                           m3_filt.storage_duration_hours))), :]
    m1_lut  = Dict(r.case_name => r for r in eachrow(filter(r -> r.model == "M1" && r.status == "ok", df)))

    for r3 in eachrow(m3_rows)
        m1 = get(m1_lut, r3.case_name, nothing)
        m1l = isnothing(m1) ? NaN : m1.lolh_hours
        m1e = isnothing(m1) ? NaN : m1.eue_mwh
        @printf "%-22s %6.0f %5d %8.0f %10.2f %10.2f %12.1f %12.1f %14.1f\n" r3.case_name (r3.storage_power_pct_peak*100) r3.storage_duration_hours r3.storage_power_mw m1l r3.lolh_hours m1e r3.eue_mwh r3.runtime_s
    end
    println("=" ^ 104)
    println("\nResults → $out_dir")
end
