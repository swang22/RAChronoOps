#!/usr/bin/env julia
# 03_run_m1_m2_m3.jl
#
# Loads processed single-zone data, runs selected models (default: M1, M3),
# and writes results to a unique timestamped folder.
#
# Method labels:
#   M1  = RA-1a: naive peak-shaving chronological heuristic (cautionary baseline)
#   M2  = rolling-window LP (diagnostic only — too slow for broad experiments)
#   M3  = RA-3: full-year ED LP benchmark (~360 s/scenario)
#
#   results/runs/run_YYYYMMDD_HHMMSS/
#     aggregate_metrics.csv      — one row per model (+ Monte Carlo CI columns)
#     scenario_metrics.csv       — one row per (model, scenario)
#     run_metadata.csv           — run configuration and timing
#     logs/run.log               — run log
#     dispatch/<model>_dispatch.csv  (if save_dispatch=true in model config)
#
# Convenience copies (overwritten each run for quick access):
#   results/metrics/latest_aggregate_metrics.csv
#   results/metrics/latest_scenario_metrics.csv
#
# Usage:
#   julia --project=. scripts/03_run_m1_m2_m3.jl
#   julia --project=. scripts/03_run_m1_m2_m3.jl --models M1,M3 --n-scenarios 20 --seed 42
#   julia --project=. scripts/03_run_m1_m2_m3.jl --models M1,M2,M3 --n-scenarios 5 --seed 42
#
# Note: M2 (~360 s/scenario) is excluded from the default model set because it
# is very slow on 8760-hour datasets.  Pass --models M1,M2,M3 only for small N.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Printf
using Logging, Dates, Statistics

# ── CLI parsing ───────────────────────────────────────────────────────────────
function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") ||
            error("Unexpected argument: $arg. " *
                  "Accepted options: --models, --n-scenarios, --seed")
        key = arg[3:end]
        (i + 1 <= length(args) && !startswith(args[i+1], "--")) ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

# ── Monte Carlo 95% CI (standard-error approach) ──────────────────────────────
function _mc_ci95(values::Vector{Float64})
    n   = length(values)
    n < 2 && return (se=NaN, hw=NaN, rel=NaN)
    hat = mean(values)
    se  = std(values) / sqrt(n)      # sample std, n-1 denominator
    hw  = 1.96 * se
    rel = hat > 0.0 ? hw / hat : NaN
    return (se=se, hw=hw, rel=rel)
end

let
    kw = parse_cli(ARGS)

    project_root = joinpath(@__DIR__, "..")
    data_dir     = joinpath(project_root, "data_processed", "rts_single_zone")
    conf_dir     = joinpath(project_root, "configs")

    # ── timestamped output folder ─────────────────────────────────────────────
    ts       = Dates.format(now(), "yyyymmdd_HHMMSS")
    run_id   = "run_$ts"
    run_dir  = joinpath(project_root, "results", "runs", run_id)
    log_dir  = joinpath(run_dir, "logs")
    disp_dir = joinpath(run_dir, "dispatch")
    lat_dir  = joinpath(project_root, "results", "metrics")
    mkpath.([run_dir, log_dir, disp_dir, lat_dir])

    # ── file logger ───────────────────────────────────────────────────────────
    log_path = joinpath(log_dir, "run.log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    # ── base config ───────────────────────────────────────────────────────────
    base_cfg_path = joinpath(conf_dir, "base_case.yaml")
    base_cfg = isfile(base_cfg_path) ? load_config(base_cfg_path) : SimConfig()

    # ── CLI overrides ─────────────────────────────────────────────────────────
    # Default: M1 + M3.  M2 (~354 s/scenario) is excluded unless requested.
    models_raw = get(kw, "models", "M1,M3")
    model_tags = String.(uppercase.(strip.(split(models_raw, ","))))
    valid_set  = Set(["M1", "M2", "M3"])
    for m in model_tags
        m in valid_set || error("Unknown model '$m'. Valid options: M1, M2, M3")
    end

    n_scen = haskey(kw, "n-scenarios") ? parse(Int, kw["n-scenarios"]) : base_cfg.n_scenarios
    seed   = haskey(kw, "seed")         ? parse(Int, kw["seed"])        : base_cfg.seed

    # ── announce ──────────────────────────────────────────────────────────────
    println("Models     : $(join(model_tags, ", "))")
    println("n_scenarios: $n_scen")
    println("seed       : $seed")
    println("Output     : $run_dir")
    @info "Models=$(join(model_tags,",")), n_scenarios=$n_scen, seed=$seed"

    # ── load system data ──────────────────────────────────────────────────────
    @info "Loading system data from $data_dir"
    sys = load_system_data(data_dir)
    @info "System: $(nrow(thermal_generators(sys))) thermal, " *
          "$(nrow(vre_generators(sys))) VRE, " *
          "$(nrow(sys.storage)) storage, $(sys.n_hours) hours"

    # ── generate shared ScenarioSet (CRN for fair comparison) ─────────────────
    @info "Generating $n_scen shared outage scenarios (seed=$seed) — same ScenarioSet for all models"
    crn_cfg   = SimConfig(; n_scenarios=n_scen, seed=seed)
    scenarios = generate_scenarios(sys, crn_cfg)

    # ── per-model configs ─────────────────────────────────────────────────────
    function _get_cfg(name)
        p = joinpath(conf_dir, "$name.yaml")
        isfile(p) ? load_config(p) : SimConfig()
    end

    MODEL_FNS = Dict(
        "M1" => (run_m1_rule_based,     _get_cfg("m1")),
        "M2" => (run_m2_rolling_window, _get_cfg("m2")),
        "M3" => (run_m3_ed_dispatch,    _get_cfg("m3")),
    )

    # ── run selected models ───────────────────────────────────────────────────
    agg_rows = NamedTuple[]
    scen_dfs = DataFrame[]
    started  = now()

    for tag in model_tags
        fn, cfg = MODEL_FNS[tag]

        @info "=== $tag ==="
        t0  = time()
        res = fn(sys, scenarios, cfg)
        rt  = time() - t0

        m = compute_metrics(res, sys, cfg)
        @info "$tag done in $(round(rt,digits=1))s | " *
              "LOLH=$(round(m.lolh,digits=2)) | EUE=$(round(m.eue,digits=1)) MWh"

        # ── Monte Carlo convergence statistics ────────────────────────────────
        eue_ci  = _mc_ci95(m.scenario_eue)

        sm      = build_scenario_metrics_df(res)
        lolh_ci = _mc_ci95(sm.lolh_hours)

        push!(agg_rows, (
            model                   = tag,
            n_scenarios             = scenarios.n_scenarios,
            seed                    = seed,
            lolh_hours              = m.lolh,
            eue_mwh                 = m.eue,
            neue_ppm                = m.neue * 1e6,
            n_events                = m.n_shortage_events,
            max_shortfall_mw        = m.max_shortfall,
            cvar_eue_mwh            = m.cvar_eue,
            eue_se_mwh              = eue_ci.se,
            eue_ci95_halfwidth_mwh  = eue_ci.hw,
            eue_ci95_rel_halfwidth  = eue_ci.rel,
            lolh_se                 = lolh_ci.se,
            lolh_ci95_halfwidth     = lolh_ci.hw,
            lolh_ci95_rel_halfwidth = lolh_ci.rel,
            runtime_s               = rt,
        ))

        insertcols!(sm, 1, :model => fill(tag, nrow(sm)))
        push!(scen_dfs, sm)

        if cfg.save_dispatch
            dp = joinpath(disp_dir, "$(lowercase(tag))_dispatch.csv")
            CSV.write(dp, build_dispatch_df(res, sys, scenarios))
            @info "Dispatch saved to $dp"
        end
    end

    finished = now()
    total_rt = sum(r.runtime_s for r in agg_rows)

    # ── write timestamped run outputs ─────────────────────────────────────────
    agg_df    = DataFrame(agg_rows)
    scen_df   = vcat(scen_dfs...)

    agg_path  = joinpath(run_dir, "aggregate_metrics.csv")
    scen_path = joinpath(run_dir, "scenario_metrics.csv")
    CSV.write(agg_path,  agg_df)
    CSV.write(scen_path, scen_df)
    @info "Aggregate metrics → $agg_path"
    @info "Scenario metrics  → $scen_path"

    # ── run_metadata.csv ──────────────────────────────────────────────────────
    meta_path = joinpath(run_dir, "run_metadata.csv")
    CSV.write(meta_path, DataFrame([(
        run_id          = run_id,
        started_at      = string(started),
        finished_at     = string(finished),
        selected_models = join(model_tags, ","),
        n_scenarios     = n_scen,
        seed            = seed,
        n_hours         = sys.n_hours,
        system_path     = abspath(data_dir),
        total_runtime_s = round(total_rt, digits=1),
        notes           = "",
    )]))
    @info "Run metadata      → $meta_path"

    # ── convenience copies (latest) ───────────────────────────────────────────
    cp(agg_path,  joinpath(lat_dir, "latest_aggregate_metrics.csv"),  force=true)
    cp(scen_path, joinpath(lat_dir, "latest_scenario_metrics.csv"),   force=true)
    @info "Latest copies → $lat_dir"

    # ── console summary table ─────────────────────────────────────────────────
    println("\n" * "="^80)
    println("Reliability Metrics Comparison")
    @printf "Models: %s  |  %d scenarios  |  seed=%d\n" join(model_tags,",") n_scen seed
    println("="^80)
    @printf "%-6s %10s %12s %12s %12s %10s %10s\n" "Model" "LOLH (h)" "EUE (MWh)" "nEUE (ppm)" "CVaR-EUE" "EUE CI95%" "Time (s)"
    println("-"^80)
    for r in agg_rows
        ci_str = isnan(r.eue_ci95_rel_halfwidth) ? "      ---" :
                 @sprintf("%8.1f%%", r.eue_ci95_rel_halfwidth * 100)
        @printf "%-6s %10.2f %12.1f %12.4f %12.1f %10s %10.1f\n" r.model r.lolh_hours r.eue_mwh r.neue_ppm r.cvar_eue_mwh ci_str r.runtime_s
    end
    println("="^80)
    println("Results → $run_dir")
end
