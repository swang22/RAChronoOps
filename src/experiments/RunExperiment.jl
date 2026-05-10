# ── ModelResults ──────────────────────────────────────────────────────────
# Defined here (after ReliabilityMetrics.jl) because it references MetricsResult.

"""
    ModelResults

Collects all outputs from one model run (M1, M2, or M3).

Fields
------
- `model_name`       : "M1", "M2", or "M3"
- `dispatch_df`      : tidy long-format hourly dispatch per scenario
- `gen_dispatch_df`  : per-generator hourly dispatch (M3 only; `nothing` for M1/M2)
- `metrics`          : aggregated `MetricsResult`
- `scenario_metrics` : per-scenario DataFrame (scenario_id, eue_mwh, lolh, n_events)
- `runtime_seconds`  : total wall-clock time for the run
"""
struct ModelResults
    model_name        ::String
    dispatch_df       ::DataFrame
    gen_dispatch_df   ::Union{DataFrame, Nothing}
    metrics           ::MetricsResult
    scenario_metrics  ::DataFrame
    runtime_seconds   ::Float64
end

# ── dispatch DataFrame builder ─────────────────────────────────────────────

"""
    build_dispatch_df(results, system, availability) -> DataFrame

Convert `Vector{DispatchResult}` to a tidy DataFrame with the columns
specified for M1/M2/M3.  `availability[scenario, gen, hour]` is needed
to compute `thermal_available_mw` for M1/M2.

M1/M2 columns: scenario_id, hour, load_mw, thermal_available_mw,
               wind_mw, solar_mw, storage_charge_mw, storage_discharge_mw,
               storage_soc_mwh, load_shed_mw

M3 columns: same but `thermal_dispatch_mw` replaces `thermal_available_mw`,
            plus `curtailment_mw`.
"""
function build_dispatch_df(
        results      ::Vector{DispatchResult},
        system       ::SystemData,
        availability ::Array{Int8, 3})::DataFrame

    therm     = thermal_generators(system)
    n_therm   = nrow(therm)
    pmax      = Float64.(therm.pmax_mw)
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    is_m3     = !isnothing(results[1].thermal_dispatch)

    rows = NamedTuple[]
    for r in results
        s = r.scenario_id
        for h in 1:length(r.load_shed)
            wind_h  = wind_cap  * system.wind_cf[h]
            solar_h = solar_cap * system.solar_cf[h]
            load_h  = system.load_mw[h]

            if is_m3
                th_val = sum(r.thermal_dispatch[g, h] for g in 1:n_therm; init=0.0)
                push!(rows, (
                    scenario_id         = s,
                    hour                = h,
                    load_mw             = load_h,
                    thermal_dispatch_mw = th_val,
                    wind_mw             = wind_h,
                    solar_mw            = solar_h,
                    storage_charge_mw   = r.storage_charge[h],
                    storage_discharge_mw= r.storage_discharge[h],
                    storage_soc_mwh     = r.soc[h],
                    curtailment_mw      = r.curtailment[h],
                    load_shed_mw        = r.load_shed[h],
                ))
            else
                th_avail = sum(pmax[g] * availability[s, g, h]
                               for g in 1:n_therm; init=0.0)
                push!(rows, (
                    scenario_id          = s,
                    hour                 = h,
                    load_mw              = load_h,
                    thermal_available_mw = th_avail,
                    wind_mw              = wind_h,
                    solar_mw             = solar_h,
                    storage_charge_mw    = r.storage_charge[h],
                    storage_discharge_mw = r.storage_discharge[h],
                    storage_soc_mwh      = r.soc[h],
                    load_shed_mw         = r.load_shed[h],
                ))
            end
        end
    end
    return DataFrame(rows)
end

"""
    build_dispatch_df(results, system, scenarios::ScenarioSet) -> DataFrame

ScenarioSet overload.
"""
function build_dispatch_df(results   ::Vector{DispatchResult},
                            system    ::SystemData,
                            scenarios ::ScenarioSet)::DataFrame
    return build_dispatch_df(results, system, scenarios.availability)
end

"""
    build_gen_dispatch_df(results, system) -> Union{DataFrame, Nothing}

Build the per-generator dispatch DataFrame for M3.  Returns `nothing` for M1/M2.

Columns: scenario_id, hour, gen_id, dispatch_mw
"""
function build_gen_dispatch_df(results::Vector{DispatchResult},
                                system ::SystemData)::Union{DataFrame, Nothing}
    isnothing(results[1].thermal_dispatch) && return nothing

    therm  = thermal_generators(system)
    gen_ids = String.(therm.gen_id)
    n_therm = nrow(therm)

    rows = NamedTuple[]
    for r in results
        s = r.scenario_id
        for h in 1:length(r.load_shed), g in 1:n_therm
            push!(rows, (
                scenario_id  = s,
                hour         = h,
                gen_id       = gen_ids[g],
                dispatch_mw  = r.thermal_dispatch[g, h],
            ))
        end
    end
    return DataFrame(rows)
end

"""
    build_scenario_metrics_df(results) -> DataFrame

Per-scenario reliability statistics.

Columns: scenario_id, eue_mwh, lolh_hours, n_shortage_events, max_shortfall_mw
"""
function build_scenario_metrics_df(results::Vector{DispatchResult})::DataFrame
    rows = [(
        scenario_id       = r.scenario_id,
        eue_mwh           = compute_eue(r.load_shed),
        lolh_hours        = compute_lolh(r.load_shed),
        n_shortage_events = length(compute_shortage_events(r.load_shed)),
        max_shortfall_mw  = isempty(r.load_shed) ? 0.0 : maximum(r.load_shed),
    ) for r in results]
    return DataFrame(rows)
end

# ── ExperimentResult (thin wrapper kept for run_experiment) ───────────────

"""
    ExperimentResult

Legacy thin wrapper returned by `run_experiment`.
For the full structured output see `ModelResults`.
"""
struct ExperimentResult
    model_name    ::String
    config        ::SimConfig
    dispatch      ::Vector{DispatchResult}
    metrics       ::MetricsResult
    runtime_total ::Float64
end

# ─────────────────────────────────────────────────────────────────────────

"""
    run_experiment(model, system, config; model_name="") -> ExperimentResult

High-level wrapper that:
1. Generates outage scenarios via `generate_scenarios`.
2. Calls `model(system, availability, config)`.
3. Computes `MetricsResult`.
4. Optionally saves dispatch and metrics CSV files.

`model` is one of `run_m1_rule_based`, `run_m2_rolling_window`,
`run_m3_ed_dispatch` (or any function with the same signature).
"""
function run_experiment(
        model     ::Function,
        system    ::SystemData,
        config    ::SimConfig;
        model_name::String = "")::ExperimentResult

    t0 = time()

    @info "Generating $(config.n_scenarios) outage scenarios (seed=$(config.seed))..."
    scenarios = generate_scenarios(system, config)

    @info "Running model$(isempty(model_name) ? "" : " $model_name") ..."
    dispatch = model(system, scenarios.availability, config)

    @info "Computing reliability metrics..."
    metrics = compute_metrics(dispatch, system, config)

    rt = time() - t0

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

function _log_metrics(m::MetricsResult, tag::String)
    label = isempty(tag) ? "Results" : "Results [$tag]"
    @info "$label: LOLH=$(round(m.lolh,digits=2)) h/yr | " *
          "EUE=$(round(m.eue,digits=1)) MWh/yr | " *
          "nEUE=$(round(m.neue*1e6, digits=2)) ppm | " *
          "CVaR-EUE=$(round(m.cvar_eue,digits=1)) MWh"
end
