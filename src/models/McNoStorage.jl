# ── MC-NoStorage: Classical no-storage Monte Carlo baseline ───────────────
#
# For each scenario, hourly load shedding is computed without storage:
#
#   load_shed[h] = max(0, load[h] − thermal_avail[h] − vre_avail[h])
#
# where
#   thermal_avail[h] = Σ_g pmax[g] × availability[s, g, h]   (binary 0/1)
#   vre_avail[h]     = wind_cap × wind_cf[h] + solar_cap × solar_cf[h]
#
# This is the "classic" hourly capacity-adequacy check: it asks whether
# available capacity is sufficient to serve load each hour, with no storage
# buffering or economic dispatch optimisation.  It is the correct no-storage
# baseline for isolating the reliability contribution of storage.
#
# The function returns a DispatchResult per scenario with all storage fields
# zeroed (storage_discharge, storage_charge, soc all zeros, thermal_dispatch
# nothing) so that compute_metrics and IO utilities accept the results
# unchanged.

"""
    run_mc_no_storage(system, availability, config) -> Vector{DispatchResult}

Classical no-storage Monte Carlo: hourly load shedding without any storage.
All storage fields in each DispatchResult are zero.
"""
function run_mc_no_storage(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        _config     ::SimConfig)::Vector{DispatchResult}

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_scen  = size(availability, 1)
    T       = system.n_hours

    pmax = Float64.(therm.pmax_mw)

    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:T]

    zeros_T = zeros(Float64, T)
    results = Vector{DispatchResult}(undef, n_scen)

    for s in 1:n_scen
        t_start = time()

        load_shed_s = zeros(Float64, T)
        for h in 1:T
            avail_h = zero(Float64)
            for g in 1:n_therm
                avail_h += pmax[g] * availability[s, g, h]
            end
            surplus = avail_h + p_vre[h] - system.load_mw[h]
            load_shed_s[h] = surplus < 0.0 ? -surplus : 0.0
        end

        results[s] = DispatchResult(
            s,
            load_shed_s,
            copy(zeros_T),  # storage_discharge
            copy(zeros_T),  # storage_charge
            copy(zeros_T),  # soc
            nothing,        # thermal_dispatch (not tracked)
            copy(zeros_T),  # curtailment
            time() - t_start,
        )
    end

    return results
end

"""
    run_mc_no_storage(system, scenarios, config) -> Vector{DispatchResult}
"""
function run_mc_no_storage(
        system   ::SystemData,
        scenarios::ScenarioSet,
        config   ::SimConfig)::Vector{DispatchResult}
    run_mc_no_storage(system, scenarios.availability, config)
end
