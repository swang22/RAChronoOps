# ── ExperimentResult ──────────────────────────────────────────────────────

"""
    ExperimentResult

Collects dispatch results and reliability metrics for one model run.
"""
struct ExperimentResult
    model_name    ::String
    config        ::SimConfig
    dispatch      ::Vector{DispatchResult}
    metrics       ::MetricsResult
    runtime_total ::Float64   # wall-clock seconds for the full run
end

# ─────────────────────────────────────────────────────────────────────────

"""
    run_experiment(model, system, config; model_name="") -> ExperimentResult

High-level wrapper that:
1. Generates outage scenarios.
2. Dispatches `model` (one of `run_m1_rule_based`, `run_m2_rolling_window`,
   `run_m3_ed_dispatch`).
3. Computes `MetricsResult`.
4. Optionally saves dispatch and metrics CSV files.

`model` is a function with signature `f(system, availability, config)`.
"""
function run_experiment(
        model     ::Function,
        system    ::SystemData,
        config    ::SimConfig;
        model_name::String = "")::ExperimentResult

    t0 = time()

    @info "Generating $(config.n_scenarios) outage scenarios (seed=$(config.seed))..."
    avail = generate_scenarios(system, config)

    @info "Running model$(isempty(model_name) ? "" : " $model_name") ..."
    dispatch = model(system, avail, config)

    @info "Computing reliability metrics..."
    metrics = compute_metrics(dispatch, system, config)

    rt = time() - t0

    # ── optional output ───────────────────────────────────────────────────
    if config.save_dispatch && !isempty(config.output_dir)
        tag   = isempty(model_name) ? "model" : lowercase(model_name)
        d_dir = joinpath(config.output_dir, "dispatch")
        m_dir = joinpath(config.output_dir, "metrics")
        mkpath.([d_dir, m_dir])
        save_dispatch(dispatch, joinpath(d_dir, "$(tag)_dispatch.csv"))
        save_metrics(metrics,   joinpath(m_dir, "$(tag)_metrics.csv"))
        save_scenario_eue(metrics, joinpath(m_dir, "$(tag)_scenario_eue.csv"))
        @info "Results written to $(config.output_dir)"
    end

    _log_metrics(metrics, model_name)

    return ExperimentResult(model_name, config, dispatch, metrics, rt)
end

# ── pretty-print key metrics ──────────────────────────────────────────────
function _log_metrics(m::MetricsResult, tag::String)
    label = isempty(tag) ? "Results" : "Results [$tag]"
    @info "$label: LOLH=$(round(m.lolh,digits=2)) h/yr | " *
          "EUE=$(round(m.eue,digits=1)) MWh/yr | " *
          "nEUE=$(round(m.neue*1e6, digits=2)) ppm | " *
          "CVaR-EUE=$(round(m.cvar_eue,digits=1)) MWh"
end
