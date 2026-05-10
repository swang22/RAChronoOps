#!/usr/bin/env julia
# 03_run_m1_m2_m3.jl
#
# Loads processed single-zone data, runs M1 / M2 / M3, and writes:
#   results/metrics/aggregate_metrics.csv   — one row per model
#   results/metrics/scenario_metrics.csv    — one row per (model, scenario)
#   results/dispatch/<model>_dispatch.csv   — hourly dispatch (if save_dispatch=true)
#   results/logs/<timestamp>.log            — run log
#
# Usage:
#   julia --project scripts/03_run_m1_m2_m3.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Printf
using Logging, Dates

# Wrap in let so path variables are local and never conflict with other scripts.
let
    project_root = joinpath(@__DIR__, "..")
    data_dir     = joinpath(project_root, "data_processed", "rts_single_zone")
    conf_dir     = joinpath(project_root, "configs")
    res_dir      = joinpath(project_root, "results")

    mkpath.([ joinpath(res_dir, "metrics"),
              joinpath(res_dir, "dispatch"),
              joinpath(res_dir, "logs") ])

    # ── file logger ───────────────────────────────────────────────────────
    log_path = joinpath(res_dir, "logs",
                        "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    get_config(name) = begin
        p = joinpath(conf_dir, "$name.yaml")
        isfile(p) ? load_config(p) : SimConfig()
    end

    @info "Loading system data from $data_dir"
    sys = load_system_data(data_dir)
    @info "System: $(nrow(thermal_generators(sys))) thermal, " *
          "$(nrow(vre_generators(sys))) VRE, " *
          "$(nrow(sys.storage)) storage, $(sys.n_hours) hours"

    # ── generate shared scenario set (same seed for fair comparison) ──────
    base_cfg  = get_config("base_case")
    @info "Generating $(base_cfg.n_scenarios) shared outage scenarios (seed=$(base_cfg.seed))"
    scenarios = generate_scenarios(sys, base_cfg)

    # ── run each model ────────────────────────────────────────────────────
    agg_rows  = NamedTuple[]
    scen_rows = NamedTuple[]

    for (tag, model_fn, cfg_name) in [
            ("M1", run_m1_rule_based,     "m1"),
            ("M2", run_m2_rolling_window, "m2"),
            ("M3", run_m3_ed_dispatch,    "m3"),
        ]

        cfg = get_config(cfg_name)
        @info "\n=== $tag ==="
        t0  = time()
        res = model_fn(sys, scenarios, cfg)
        rt  = time() - t0

        m = compute_metrics(res, sys, cfg)
        @info "$tag done in $(round(rt,digits=1))s | " *
              "LOLH=$(round(m.lolh,digits=2)) | EUE=$(round(m.eue,digits=1)) MWh"

        push!(agg_rows, (
            model            = tag,
            n_scenarios      = cfg.n_scenarios,
            lolh_hours       = m.lolh,
            eue_mwh          = m.eue,
            neue_ppm         = m.neue * 1e6,
            n_events         = m.n_shortage_events,
            max_shortfall_mw = m.max_shortfall,
            cvar_eue_mwh     = m.cvar_eue,
            runtime_s        = rt,
        ))

        sm = build_scenario_metrics_df(res)
        insertcols!(sm, 1, :model => fill(tag, nrow(sm)))
        append!(scen_rows, Tables.rowtable(sm))

        if cfg.save_dispatch
            disp_path = joinpath(res_dir, "dispatch", "$(lowercase(tag))_dispatch.csv")
            CSV.write(disp_path, build_dispatch_df(res, sys, scenarios))
            @info "Dispatch saved to $disp_path"
        end
    end

    # ── write aggregate and scenario metric tables ────────────────────────
    agg_path  = joinpath(res_dir, "metrics", "aggregate_metrics.csv")
    scen_path = joinpath(res_dir, "metrics", "scenario_metrics.csv")
    CSV.write(agg_path,  DataFrame(agg_rows))
    CSV.write(scen_path, DataFrame(scen_rows))
    @info "Aggregate metrics → $agg_path"
    @info "Scenario metrics  → $scen_path"

    # ── console summary table ─────────────────────────────────────────────
    println("\n" * "="^72)
    println("Reliability Metrics Comparison")
    println("="^72)
    @printf "%-6s %10s %12s %12s %12s %10s\n" \
        "Model" "LOLH (h)" "EUE (MWh)" "nEUE (ppm)" "CVaR-EUE" "Time (s)"
    println("-"^72)
    for r in agg_rows
        @printf "%-6s %10.2f %12.1f %12.4f %12.1f %10.1f\n" \
            r.model r.lolh_hours r.eue_mwh r.neue_ppm r.cvar_eue_mwh r.runtime_s
    end
    println("="^72)
end
