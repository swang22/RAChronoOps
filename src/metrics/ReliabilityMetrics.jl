# ── MetricsResult ─────────────────────────────────────────────────────────

"""
    MetricsResult

Reliability metrics aggregated over all Monte Carlo scenarios.

Fields
------
- `lolh`               : Loss-of-load hours (expected hours/year with shortfall)
- `eue`                : Expected unserved energy (MWh/year)
- `neue`               : Normalised EUE (fraction of annual energy demand)
- `n_shortage_events`  : Expected number of contiguous shortage episodes/year
- `shortage_durations` : All episode durations across scenarios (hours)
- `max_shortfall`      : Expected maximum hourly shortfall across scenarios (MW)
- `scenario_eue`       : EUE for each individual scenario (MWh)
- `cvar_eue`           : CVaR of scenario-level EUE at the configured α level (MWh)
"""
struct MetricsResult
    lolh               ::Float64
    eue                ::Float64
    neue               ::Float64
    n_shortage_events  ::Float64
    shortage_durations ::Vector{Float64}
    max_shortfall      ::Float64
    scenario_eue       ::Vector{Float64}
    cvar_eue           ::Float64
end

# ── internal helper: find contiguous shortage episodes ────────────────────
function _find_shortage_durations(load_shed::Vector{Float64})::Vector{Int}
    durations = Int[]
    in_event  = false
    count     = 0
    for ls in load_shed
        if ls > 0.0
            in_event = true
            count   += 1
        else
            if in_event
                push!(durations, count)
                count    = 0
                in_event = false
            end
        end
    end
    in_event && push!(durations, count)   # episode reaching end of horizon
    return durations
end

# ── CVaR (Conditional Value at Risk) ─────────────────────────────────────
function _cvar(sorted_values::Vector{Float64}, alpha::Float64)::Float64
    isempty(sorted_values) && return 0.0
    n        = length(sorted_values)
    cutoff   = ceil(Int, alpha * n)
    cutoff   = min(cutoff, n)
    tail     = @view sorted_values[cutoff:end]
    isempty(tail) ? sorted_values[end] : mean(tail)
end

# ─────────────────────────────────────────────────────────────────────────

"""
    compute_metrics(results, load_mw; cvar_alpha=0.95) -> MetricsResult

Compute reliability indices from a vector of `DispatchResult` objects.

`load_mw` is the hourly load vector (used for nEUE normalisation).
"""
function compute_metrics(
        results    ::Vector{DispatchResult},
        load_mw    ::Vector{Float64};
        cvar_alpha ::Float64 = 0.95)::MetricsResult

    n_scen       = length(results)
    annual_load  = sum(load_mw)

    # ── per-scenario EUE ─────────────────────────────────────────────────
    scen_eue = [sum(r.load_shed) for r in results]

    # ── LOLH: expected hours with any load shedding ───────────────────────
    lolh = mean(count(ls -> ls > 0.0, r.load_shed) for r in results)

    # ── EUE and nEUE ─────────────────────────────────────────────────────
    eue  = mean(scen_eue)
    neue = annual_load > 0.0 ? eue / annual_load : 0.0

    # ── shortage event statistics ─────────────────────────────────────────
    all_durations = Int[]
    all_n_events  = Int[]
    for r in results
        d = _find_shortage_durations(r.load_shed)
        append!(all_durations, d)
        push!(all_n_events, length(d))
    end
    n_shortage_events   = mean(all_n_events)
    dur_float           = Float64.(all_durations)

    # ── maximum hourly shortfall ──────────────────────────────────────────
    max_sf = mean(isempty(r.load_shed) ? 0.0 : maximum(r.load_shed)
                  for r in results)

    # ── CVaR of scenario EUE ─────────────────────────────────────────────
    sorted_eue = sort(scen_eue)
    cvar       = _cvar(sorted_eue, cvar_alpha)

    return MetricsResult(lolh, eue, neue, n_shortage_events,
                         dur_float, max_sf, scen_eue, cvar)
end

"""
    compute_metrics(results, system; kwargs...) -> MetricsResult

Convenience overload accepting a `SystemData`.
"""
function compute_metrics(results ::Vector{DispatchResult},
                          system ::SystemData;
                          kwargs...)::MetricsResult
    return compute_metrics(results, system.load_mw; kwargs...)
end

"""
    compute_metrics(results, system, config) -> MetricsResult

Use `config.cvar_alpha` for the CVaR level.
"""
function compute_metrics(results ::Vector{DispatchResult},
                          system ::SystemData,
                          config ::SimConfig)::MetricsResult
    return compute_metrics(results, system.load_mw; cvar_alpha=config.cvar_alpha)
end
