#!/usr/bin/env julia
# 07_run_case.jl
#
# Run selected methods on a single experiment case folder and write results
# under results/cases/<case_name>/.
#
# Method labels:
#   M1  = RA-1a: naive peak-shaving chronological heuristic (cautionary baseline)
#   M2  = rolling-window LP (diagnostic only — slow; avoid for broad experiments)
#   M3  = RA-3: full-year ED LP benchmark
#
# Usage:
#   julia --project=. scripts/07_run_case.jl <case_dir> [options]
#
# Options:
#   --models          Comma-separated subset of M1,M2,M3  (default: M1,M2,M3)
#   --n-scenarios     Override n_scenarios from base_case.yaml
#   --seed            Override seed from base_case.yaml
#   --lookahead-hours Override M2 lookahead_hours from m2.yaml
#   --save-dispatch   true | false  (default: from each model config)
#
# Example:
#   julia --project=. scripts/07_run_case.jl data_processed/cases/rts_base
#   julia --project=. scripts/07_run_case.jl data_processed/cases/load_scale_110 --models M1,M3 --n-scenarios 20

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Printf
using Logging, Dates

# ── argument parsing ──────────────────────────────────────────────────────────
function parse_cli(args::Vector{String})
    isempty(args) && error(
        "Usage: julia --project=. scripts/07_run_case.jl <case_dir> [--models M1,M2,M3] " *
        "[--n-scenarios N] [--seed S] [--lookahead-hours H] [--save-dispatch true|false]")

    case_dir = args[1]
    kw = Dict{String,String}()
    i  = 2
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") ||
            error("Unexpected positional argument: $arg (only one case_dir is accepted)")
        key = arg[3:end]
        i + 1 <= length(args) && !startswith(args[i+1], "--") ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]
        i += 2
    end
    return case_dir, kw
end

# ── config helpers ────────────────────────────────────────────────────────────

# Build a per-model SimConfig from the base config, the model-specific config,
# and any CLI overrides. The caller supplies concrete values for the fields
# that differ between models or may be overridden.
function _make_cfg(base  ::SimConfig,
                   m_cfg ::SimConfig,
                   n_scen::Int,
                   seed  ::Int,
                   lah   ::Int,           # lookahead_hours
                   save  ::Bool,
                   out   ::String)::SimConfig
    return SimConfig(
        n_scen,
        seed,
        base.voll,
        base.high_net_load_quantile,
        base.charge_net_load_quantile,
        m_cfg.reserve_fraction,
        lah,
        m_cfg.epsilon_cycling,
        m_cfg.cyclic_soc,
        m_cfg.storage_cycling_cost,
        base.cvar_alpha,
        save,
        out,
    )
end

function _load_cfg(path::String, fallback::SimConfig)::SimConfig
    isfile(path) ? load_config(path) : fallback
end

# ── main ──────────────────────────────────────────────────────────────────────
let
    case_dir, kw = parse_cli(ARGS)

    isdir(case_dir) || error("Case directory not found: $case_dir\n" *
                              "Run scripts/06_build_experiment_cases.jl first.")

    for f in ("generators.csv", "storage.csv", "load_timeseries.csv",
              "wind_timeseries.csv", "solar_timeseries.csv")
        isfile(joinpath(case_dir, f)) ||
            error("Missing file in case directory: $(joinpath(case_dir, f))")
    end

    # ── derived paths ─────────────────────────────────────────────────────
    project_root = joinpath(@__DIR__, "..")
    conf_dir     = joinpath(project_root, "configs")

    # Accept trailing separator in case_dir
    case_name = last(filter(!isempty, splitpath(case_dir)))
    out_dir   = joinpath(project_root, "results", "cases", case_name)
    disp_dir  = joinpath(out_dir, "dispatch")
    log_dir   = joinpath(out_dir, "logs")
    mkpath.([out_dir, disp_dir, log_dir])

    # ── file logger ───────────────────────────────────────────────────────
    ts       = Dates.format(now(), "yyyymmdd_HHMMSS")
    log_path = joinpath(log_dir, "run_$ts.log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)
    @info "Log: $log_path"

    # ── load case metadata (optional) ─────────────────────────────────────
    meta_path = joinpath(case_dir, "case_metadata.csv")
    case_meta = isfile(meta_path) ? CSV.read(meta_path, DataFrame)[1, :] : nothing

    # ── load system data and validate ─────────────────────────────────────
    @info "Loading system data from $case_dir"
    sys = load_system_data(case_dir)
    sys.n_hours == 8760 ||
        error("Formal experiment cases require 8760-hour data, but case " *
              "'$case_name' has $(sys.n_hours) hours. " *
              "Rebuild with scripts/06_build_experiment_cases.jl.")
    @info "System: $(nrow(thermal_generators(sys))) thermal, " *
          "$(nrow(vre_generators(sys))) VRE, " *
          "$(nrow(sys.storage)) storage, $(sys.n_hours) hours"

    # ── parse CLI overrides ───────────────────────────────────────────────
    model_tags_raw = get(kw, "models", "M1,M2,M3")
    model_tags     = String.(uppercase.(strip.(split(model_tags_raw, ","))))
    valid_models   = Set(["M1", "M2", "M3"])
    for m in model_tags
        m in valid_models ||
            error("Unknown model '$m'. Valid options: M1, M2, M3")
    end

    save_dispatch_cli = haskey(kw, "save-dispatch") ?
                        Some(parse(Bool, kw["save-dispatch"])) : nothing
    n_scenarios_cli   = haskey(kw, "n-scenarios")   ?
                        Some(parse(Int,  kw["n-scenarios"]))  : nothing
    seed_cli          = haskey(kw, "seed")           ?
                        Some(parse(Int,  kw["seed"]))         : nothing
    lah_cli           = haskey(kw, "lookahead-hours") ?
                        Some(parse(Int,  kw["lookahead-hours"])) : nothing

    # ── load configs ──────────────────────────────────────────────────────
    base_cfg = load_config(joinpath(conf_dir, "base_case.yaml"))
    m1_cfg   = _load_cfg(joinpath(conf_dir, "m1.yaml"), base_cfg)
    m2_cfg   = _load_cfg(joinpath(conf_dir, "m2.yaml"), base_cfg)
    m3_cfg   = _load_cfg(joinpath(conf_dir, "m3.yaml"), base_cfg)

    n_scen = something(n_scenarios_cli, base_cfg.n_scenarios)
    seed   = something(seed_cli,         base_cfg.seed)
    lah_m2 = something(lah_cli,          m2_cfg.lookahead_hours)

    # ── generate shared ScenarioSet (CRN) ────────────────────────────────
    @info "Generating $n_scen shared outage scenarios (seed=$seed)"
    crn_cfg   = SimConfig(n_scen, seed, base_cfg.voll,
                          base_cfg.high_net_load_quantile,
                          base_cfg.charge_net_load_quantile,
                          base_cfg.reserve_fraction,
                          base_cfg.lookahead_hours,
                          base_cfg.epsilon_cycling, base_cfg.cyclic_soc,
                          base_cfg.storage_cycling_cost,
                          base_cfg.cvar_alpha, false, out_dir)
    scenarios = generate_scenarios(sys, crn_cfg)
    @info "ScenarioSet: $(size(scenarios.availability))"  # (n_scen, n_thermal, n_hours)

    # ── model dispatch table ──────────────────────────────────────────────
    MODEL_FNS = Dict(
        "M1" => (run_m1_rule_based,     m1_cfg, 0),
        "M2" => (run_m2_rolling_window, m2_cfg, lah_m2),
        "M3" => (run_m3_ed_dispatch,    m3_cfg, sys.n_hours),
    )

    # ── run selected models ───────────────────────────────────────────────
    agg_rows  = NamedTuple[]
    scen_dfs  = DataFrame[]
    started   = now()

    for tag in model_tags
        fn, m_cfg_ref, lah = MODEL_FNS[tag]
        save_disp = something(save_dispatch_cli, m_cfg_ref.save_dispatch)

        eff_cfg = _make_cfg(base_cfg, m_cfg_ref, n_scen, seed,
                            lah, save_disp, out_dir)

        @info "=== $tag | lookahead=$(lah == sys.n_hours ? "$(sys.n_hours) (full year)" : "$(lah)h")"
        t0  = time()
        res = fn(sys, scenarios, eff_cfg)
        rt  = time() - t0

        m = compute_metrics(res, sys, eff_cfg)
        @info "$tag done in $(round(rt, digits=1))s | LOLH=$(round(m.lolh, digits=2)) | EUE=$(round(m.eue, digits=1)) MWh"

        push!(agg_rows, (
            case_name        = case_name,
            model            = tag,
            n_scenarios      = scenarios.n_scenarios,
            seed             = seed,
            lookahead_hours  = lah,
            lolh_hours       = m.lolh,
            eue_mwh          = m.eue,
            neue_ppm         = m.neue * 1e6,
            n_events         = m.n_shortage_events,
            max_shortfall_mw = m.max_shortfall,
            cvar_eue_mwh     = m.cvar_eue,
            runtime_s        = rt,
        ))

        sm = build_scenario_metrics_df(res)
        insertcols!(sm, 1, :case_name => fill(case_name, nrow(sm)),
                           :model     => fill(tag,       nrow(sm)))
        push!(scen_dfs, sm)

        if save_disp
            dp = joinpath(disp_dir, "$(lowercase(tag))_dispatch.csv")
            CSV.write(dp, build_dispatch_df(res, sys, scenarios))
            @info "Dispatch saved to $dp"
        end
    end

    finished = now()
    total_rt = sum(r.runtime_s for r in agg_rows)

    # ── aggregate_metrics.csv ─────────────────────────────────────────────
    agg_path = joinpath(out_dir, "aggregate_metrics.csv")
    CSV.write(agg_path, DataFrame(agg_rows))
    @info "Aggregate metrics → $agg_path"

    # ── scenario_metrics.csv ──────────────────────────────────────────────
    scen_path = joinpath(out_dir, "scenario_metrics.csv")
    CSV.write(scen_path, vcat(scen_dfs...))
    @info "Scenario metrics  → $scen_path"

    # ── run_metadata.csv ──────────────────────────────────────────────────
    meta_row = Dict{String,Any}(
        "case_name"        => case_name,
        "case_path"        => abspath(case_dir),
        "n_hours"          => sys.n_hours,
        "n_scenarios"      => scenarios.n_scenarios,
        "seed"             => seed,
        "models_run"       => join(model_tags, ","),
        "started_at"       => string(started),
        "finished_at"      => string(finished),
        "total_runtime_s"  => round(total_rt, digits = 1),
    )
    if !isnothing(case_meta)
        for col in (:load_scale, :wind_scale, :solar_scale,
                    :storage_power_pct_peak, :storage_duration_hours)
            hasproperty(case_meta, col) && (meta_row[string(col)] = case_meta[col])
        end
    end
    run_meta_path = joinpath(out_dir, "run_metadata.csv")
    CSV.write(run_meta_path, DataFrame(meta_row))
    @info "Run metadata      → $run_meta_path"

    # ── console summary ───────────────────────────────────────────────────
    println()
    println("=" ^ 76)
    @printf "Case: %s  |  %d scenarios  |  seed=%d\n" case_name scenarios.n_scenarios seed
    println("=" ^ 76)
    @printf "  %-6s %10s %12s %12s %14s %10s\n" "Model" "LOLH (h)" "EUE (MWh)" "nEUE (ppm)" "CVaR-EUE" "Time (s)"
    println("  " * "-" ^ 68)
    for r in agg_rows
        @printf "  %-6s %10.2f %12.1f %12.4f %14.1f %10.1f\n" r.model r.lolh_hours r.eue_mwh r.neue_ppm r.cvar_eue_mwh r.runtime_s
    end
    println("=" ^ 76)
    println("Results written to $out_dir")
end
