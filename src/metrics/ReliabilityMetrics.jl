# ── MetricsResult ─────────────────────────────────────────────────────────

"""
    MetricsResult

Reliability metrics aggregated over all Monte Carlo scenarios.

Frequency
---------
- `lolh`                       : Loss-of-load hours (expected hours/year with shortfall)
- `lolp`                       : Loss-of-load probability  = lolh / n_hours
- `lole_days`                  : Expected days/year with at least one shortage hour

Energy
------
- `eue`                        : Expected unserved energy (MWh/year)
- `neue`                       : Normalised EUE (fraction of annual energy demand)

Event structure
---------------
- `n_shortage_events`          : Expected number of contiguous shortage episodes/year
- `shortage_durations`         : All episode durations across scenarios (hours)
- `mean_shortage_duration`     : Mean episode duration (hours); 0.0 if no events
- `max_shortage_duration`      : Longest episode (hours); 0.0 if no events
- `p95_shortage_duration`      : 95th-percentile episode duration; 0.0 if no events

Severity
--------
- `max_shortfall`              : Expected maximum hourly shortfall (MW)
- `mean_shortfall_when_shedding`: Mean load_shed over all positive-shed hours (MW)

Tail risk
---------
- `scenario_eue`               : EUE for each individual scenario (MWh)
- `p50_scenario_eue`           : 50th-percentile scenario EUE (MWh)
- `p90_scenario_eue`           : 90th-percentile scenario EUE (MWh)
- `p95_scenario_eue`           : 95th-percentile scenario EUE (MWh)
- `p99_scenario_eue`           : 99th-percentile scenario EUE (MWh)
- `cvar_eue`                   : CVaR of scenario EUE at configured α (MWh)

Monte Carlo uncertainty (95 % CI half-widths)
---------------------------------------------
- `lolh_ci95_halfwidth`        : 1.96 × std(scenario_lolh) / √N  (hours)
- `eue_ci95_halfwidth`         : 1.96 × std(scenario_eue)  / √N  (MWh)
- `lolh_ci95_rel_halfwidth`    : lolh_ci95 / lolh;  NaN when lolh == 0
- `eue_ci95_rel_halfwidth`     : eue_ci95  / eue;   NaN when eue  == 0
"""
Base.@kwdef struct MetricsResult
    # Frequency
    lolh                        ::Float64
    lolp                        ::Float64
    lole_days                   ::Float64

    # Energy
    eue                         ::Float64
    neue                        ::Float64

    # Event structure
    n_shortage_events           ::Float64
    shortage_durations          ::Vector{Float64}
    mean_shortage_duration      ::Float64
    max_shortage_duration       ::Float64
    p95_shortage_duration       ::Float64

    # Severity
    max_shortfall               ::Float64
    mean_shortfall_when_shedding::Float64

    # Tail risk
    scenario_eue                ::Vector{Float64}
    p50_scenario_eue            ::Float64
    p90_scenario_eue            ::Float64
    p95_scenario_eue            ::Float64
    p99_scenario_eue            ::Float64
    cvar_eue                    ::Float64

    # Monte Carlo uncertainty
    lolh_ci95_halfwidth         ::Float64
    eue_ci95_halfwidth          ::Float64
    lolh_ci95_rel_halfwidth     ::Float64
    eue_ci95_rel_halfwidth      ::Float64
end

# ── internal helpers ───────────────────────────────────────────────────────

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
    in_event && push!(durations, count)
    return durations
end

function _cvar(sorted_values::Vector{Float64}, alpha::Float64)::Float64
    isempty(sorted_values) && return 0.0
    n      = length(sorted_values)
    cutoff = min(ceil(Int, alpha * n), n)
    tail   = @view sorted_values[cutoff:end]
    isempty(tail) ? sorted_values[end] : mean(tail)
end

# ─────────────────────────────────────────────────────────────────────────

"""
    compute_metrics(results, load_mw; cvar_alpha=0.95) -> MetricsResult

Compute reliability indices from a vector of `DispatchResult` objects.
`load_mw` is the hourly load vector (used for nEUE normalisation and
LOLE-days calculation).
"""
function compute_metrics(
        results    ::Vector{DispatchResult},
        load_mw    ::Vector{Float64};
        cvar_alpha ::Float64 = 0.95)::MetricsResult

    n_scen      = length(results)
    n_hours     = length(load_mw)
    annual_load = sum(load_mw)

    # ── per-scenario LOLH and EUE ────────────────────────────────────────
    scen_lolh = [Float64(count(ls -> ls > 0.0, r.load_shed)) for r in results]
    scen_eue  = [sum(r.load_shed) for r in results]

    # ── frequency ────────────────────────────────────────────────────────
    lolh = mean(scen_lolh)
    lolp = n_hours > 0 ? lolh / n_hours : 0.0

    # ── LOLE days: mean scenarios-days with ≥1 shortage hour ─────────────
    n_days = div(n_hours, 24)
    scen_loldays = Vector{Float64}(undef, n_scen)
    for (s, r) in enumerate(results)
        days_hit = 0
        for d in 1:n_days
            h0 = (d - 1) * 24 + 1
            h1 = d * 24
            for h in h0:h1
                if r.load_shed[h] > 0.0
                    days_hit += 1
                    break
                end
            end
        end
        scen_loldays[s] = Float64(days_hit)
    end
    lole_days = mean(scen_loldays)

    # ── energy ───────────────────────────────────────────────────────────
    eue  = mean(scen_eue)
    neue = annual_load > 0.0 ? eue / annual_load : 0.0

    # ── shortage event structure ──────────────────────────────────────────
    all_durations = Int[]
    all_n_events  = Int[]
    for r in results
        d = _find_shortage_durations(r.load_shed)
        append!(all_durations, d)
        push!(all_n_events, length(d))
    end
    n_shortage_events = mean(all_n_events)
    dur_float         = Float64.(all_durations)
    mean_dur = isempty(dur_float) ? 0.0 : mean(dur_float)
    max_dur  = isempty(dur_float) ? 0.0 : Float64(maximum(dur_float))
    p95_dur  = isempty(dur_float) ? 0.0 : quantile(dur_float, 0.95)

    # ── severity ─────────────────────────────────────────────────────────
    max_sf = mean(isempty(r.load_shed) ? 0.0 : maximum(r.load_shed)
                  for r in results)
    all_positive_shed = Float64[]
    for r in results
        for ls in r.load_shed
            ls > 0.0 && push!(all_positive_shed, ls)
        end
    end
    mean_sf_shedding = isempty(all_positive_shed) ? 0.0 : mean(all_positive_shed)

    # ── tail risk ─────────────────────────────────────────────────────────
    sorted_eue = sort(scen_eue)
    cvar       = _cvar(sorted_eue, cvar_alpha)
    p50 = quantile(scen_eue, 0.50)
    p90 = quantile(scen_eue, 0.90)
    p95 = quantile(scen_eue, 0.95)
    p99 = quantile(scen_eue, 0.99)

    # ── Monte Carlo CI95 ─────────────────────────────────────────────────
    lolh_ci95     = compute_ci95(scen_lolh)
    eue_ci95      = compute_ci95(scen_eue)
    lolh_ci95_rel = lolh > 0.0 ? lolh_ci95 / lolh : NaN
    eue_ci95_rel  = eue  > 0.0 ? eue_ci95  / eue  : NaN

    return MetricsResult(
        lolh                        = lolh,
        lolp                        = lolp,
        lole_days                   = lole_days,
        eue                         = eue,
        neue                        = neue,
        n_shortage_events           = n_shortage_events,
        shortage_durations          = dur_float,
        mean_shortage_duration      = mean_dur,
        max_shortage_duration       = max_dur,
        p95_shortage_duration       = p95_dur,
        max_shortfall               = max_sf,
        mean_shortfall_when_shedding= mean_sf_shedding,
        scenario_eue                = scen_eue,
        p50_scenario_eue            = p50,
        p90_scenario_eue            = p90,
        p95_scenario_eue            = p95,
        p99_scenario_eue            = p99,
        cvar_eue                    = cvar,
        lolh_ci95_halfwidth         = lolh_ci95,
        eue_ci95_halfwidth          = eue_ci95,
        lolh_ci95_rel_halfwidth     = lolh_ci95_rel,
        eue_ci95_rel_halfwidth      = eue_ci95_rel,
    )
end

"""
    compute_metrics(results, system; kwargs...) -> MetricsResult
"""
function compute_metrics(results ::Vector{DispatchResult},
                          system ::SystemData;
                          kwargs...)::MetricsResult
    return compute_metrics(results, system.load_mw; kwargs...)
end

"""
    compute_metrics(results, system, config) -> MetricsResult
"""
function compute_metrics(results ::Vector{DispatchResult},
                          system ::SystemData,
                          config ::SimConfig)::MetricsResult
    return compute_metrics(results, system.load_mw; cvar_alpha=config.cvar_alpha)
end

# ── Public helper functions ────────────────────────────────────────────────

"""
    compute_lolh(load_shed) -> Float64

Loss-of-load hours for a single scenario.
"""
compute_lolh(load_shed::Vector{Float64})::Float64 =
    Float64(count(x -> x > 0.0, load_shed))

"""
    compute_lolp(lolh, n_hours) -> Float64

Loss-of-load probability: LOLH / n_hours.
"""
compute_lolp(lolh::Float64, n_hours::Int)::Float64 =
    n_hours > 0 ? lolh / n_hours : 0.0

"""
    compute_lole_days(load_shed; hours_per_day=24) -> Float64

Number of days in a single scenario with at least one shortage hour.
"""
function compute_lole_days(load_shed::Vector{Float64};
                            hours_per_day::Int = 24)::Float64
    n_days = div(length(load_shed), hours_per_day)
    days_hit = 0
    for d in 1:n_days
        h0 = (d - 1) * hours_per_day + 1
        h1 = d * hours_per_day
        for h in h0:h1
            if load_shed[h] > 0.0
                days_hit += 1
                break
            end
        end
    end
    return Float64(days_hit)
end

"""
    compute_eue(load_shed) -> Float64

Expected unserved energy (MWh) for a single scenario.
"""
compute_eue(load_shed::Vector{Float64})::Float64 = sum(load_shed)

"""
    compute_neue(load_shed, load_mw) -> Float64

Normalised EUE — ratio of unserved energy to total energy demand.
"""
function compute_neue(load_shed::Vector{Float64},
                       load_mw  ::Vector{Float64})::Float64
    demand = sum(load_mw)
    demand > 0.0 ? compute_eue(load_shed) / demand : 0.0
end

"""
    compute_shortage_events(load_shed) -> Vector{Int}

Return the duration (hours) of each contiguous shortage episode.
"""
compute_shortage_events(load_shed::Vector{Float64})::Vector{Int} =
    _find_shortage_durations(load_shed)

"""
    compute_shortfall_severity(all_load_shed) -> Float64

Mean load shed over all positive-shed hours; 0.0 if no shedding.
`all_load_shed` should be the concatenation of load_shed across all
scenarios (or a single scenario's vector).
"""
function compute_shortfall_severity(all_load_shed::Vector{Float64})::Float64
    positive = filter(x -> x > 0.0, all_load_shed)
    isempty(positive) ? 0.0 : mean(positive)
end

"""
    compute_ci95(values) -> Float64

95 % confidence interval half-width: 1.96 × std(values) / √n.
Returns 0.0 when n ≤ 1 (no variance estimable).
"""
function compute_ci95(values::Vector{Float64})::Float64
    n = length(values)
    n <= 1 && return 0.0
    return 1.96 * std(values) / sqrt(Float64(n))
end

"""
    compute_quantile(values, q) -> Float64

q-th quantile of `values` (wraps `Statistics.quantile`).
"""
compute_quantile(values::Vector{Float64}, q::Float64)::Float64 =
    quantile(values, q)

"""
    compute_cvar(values; alpha=0.95) -> Float64

Conditional Value at Risk at confidence level `alpha`.
"""
function compute_cvar(values::Vector{Float64}; alpha::Float64 = 0.95)::Float64
    _cvar(sort(values), alpha)
end

"""
    aggregate_metrics(scenario_lolh, scenario_eue, scenario_durations, load_mw;
                      cvar_alpha=0.95) -> MetricsResult

Build a `MetricsResult` from pre-computed per-scenario vectors.
`mean_shortfall_when_shedding` and `lole_days` default to 0.0 when raw
hourly load_shed is not available.
"""
function aggregate_metrics(
        scenario_lolh      ::Vector{Float64},
        scenario_eue       ::Vector{Float64},
        scenario_durations ::Vector{Vector{Int}},
        load_mw            ::Vector{Float64};
        cvar_alpha         ::Float64 = 0.95)::MetricsResult

    n_hours     = length(load_mw)
    annual_load = sum(load_mw)

    lolh = mean(scenario_lolh)
    lolp = n_hours > 0 ? lolh / n_hours : 0.0
    eue  = mean(scenario_eue)
    neue = annual_load > 0.0 ? eue / annual_load : 0.0

    all_dur   = Float64.(vcat(scenario_durations...))
    n_events  = mean(length.(scenario_durations))
    mean_dur  = isempty(all_dur) ? 0.0 : mean(all_dur)
    max_dur   = isempty(all_dur) ? 0.0 : Float64(maximum(all_dur))
    p95_dur   = isempty(all_dur) ? 0.0 : quantile(all_dur, 0.95)

    sorted_eue = sort(scenario_eue)
    cvar       = _cvar(sorted_eue, cvar_alpha)
    p50 = quantile(scenario_eue, 0.50)
    p90 = quantile(scenario_eue, 0.90)
    p95 = quantile(scenario_eue, 0.95)
    p99 = quantile(scenario_eue, 0.99)

    lolh_ci95     = compute_ci95(scenario_lolh)
    eue_ci95      = compute_ci95(scenario_eue)
    lolh_ci95_rel = lolh > 0.0 ? lolh_ci95 / lolh : NaN
    eue_ci95_rel  = eue  > 0.0 ? eue_ci95  / eue  : NaN

    return MetricsResult(
        lolh                        = lolh,
        lolp                        = lolp,
        lole_days                   = 0.0,     # not computable without raw load_shed
        eue                         = eue,
        neue                        = neue,
        n_shortage_events           = n_events,
        shortage_durations          = all_dur,
        mean_shortage_duration      = mean_dur,
        max_shortage_duration       = max_dur,
        p95_shortage_duration       = p95_dur,
        max_shortfall               = 0.0,     # not computable without raw load_shed
        mean_shortfall_when_shedding= 0.0,     # not computable without raw load_shed
        scenario_eue                = scenario_eue,
        p50_scenario_eue            = p50,
        p90_scenario_eue            = p90,
        p95_scenario_eue            = p95,
        p99_scenario_eue            = p99,
        cvar_eue                    = cvar,
        lolh_ci95_halfwidth         = lolh_ci95,
        eue_ci95_halfwidth          = eue_ci95,
        lolh_ci95_rel_halfwidth     = lolh_ci95_rel,
        eue_ci95_rel_halfwidth      = eue_ci95_rel,
    )
end
