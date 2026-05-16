# ── RA-1b / M1b: Reserve-aware chronological storage heuristic ────────────
#
# Identical structure to RA-1a / M1, with one change: Priority-2 proactive
# discharge is limited to SOC above the reserve floor
#     soc_floor = config.reserve_fraction × total_energy_mwh
# Priority-1 emergency discharge ignores the floor (it is unconditional).
#
# See docs/ra1b_implementation_checklist.md for the full algorithm spec
# and behavioral contracts.

"""
    run_m1b_reserve_aware(system, availability, config) -> Vector{DispatchResult}

Run RA-1b for every scenario encoded in `availability[scenario, gen, hour]`.

Identical to RA-1a / M1 except Priority-2 proactive discharge is restricted
to SOC above `config.reserve_fraction × total_energy_mwh`.  Priority-1
emergency discharge is unrestricted and may draw the SOC below the floor.
"""
function run_m1b_reserve_aware(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        config      ::SimConfig)::Vector{DispatchResult}

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_scen  = size(availability, 1)
    n_hours = system.n_hours

    pmax = Float64.(therm.pmax_mw)

    # ── aggregate storage parameters ──────────────────────────────────────
    stor = system.storage
    if nrow(stor) == 0
        total_power  = 0.0
        total_energy = 0.0
        init_soc     = 0.0
        eta_ch       = 1.0
        eta_dis      = 1.0
    else
        total_power  = sum(stor.power_mw)
        total_energy = sum(stor.energy_mwh)
        init_soc     = sum(stor.initial_soc_mwh)
        eta_ch       = mean(stor.charge_efficiency)
        eta_dis      = mean(stor.discharge_efficiency)
    end

    # ── pre-compute VRE output per hour ───────────────────────────────────
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:n_hours]

    # Net load = load - VRE (thermal residual demand, before storage)
    net_load = system.load_mw .- p_vre

    # Rule thresholds computed from the unconditional net-load distribution
    high_nl_thresh   = quantile(net_load, config.high_net_load_quantile)
    charge_nl_thresh = quantile(net_load, config.charge_net_load_quantile)

    # ── SOC reserve floor (the key RA-1b addition) ────────────────────────
    # Priority-2 proactive discharge may not reduce SOC below this level.
    # Priority-1 emergency discharge ignores it.
    soc_floor = config.reserve_fraction * total_energy

    results = Vector{DispatchResult}(undef, n_scen)

    for s in 1:n_scen
        load_shed = zeros(Float64, n_hours)
        st_dis    = zeros(Float64, n_hours)
        st_chg    = zeros(Float64, n_hours)
        soc       = zeros(Float64, n_hours)
        curtailmt = zeros(Float64, n_hours)

        curr_soc = init_soc

        for h in 1:n_hours
            load_h = system.load_mw[h]

            # Available thermal capacity this hour (pool)
            therm_avail = zero(Float64)
            for g in 1:n_therm
                therm_avail += pmax[g] * availability[s, g, h]
            end

            net_supply    = therm_avail + p_vre[h]
            shortfall_pre = max(0.0, load_h - net_supply)

            dis = 0.0
            chg = 0.0

            if shortfall_pre > 0.0 && total_power > 0.0
                # ── Priority 1: emergency discharge (no reserve-floor limit) ──
                max_dis  = min(total_power, curr_soc * eta_dis)
                dis      = min(shortfall_pre, max_dis)
                curr_soc -= dis / eta_dis

            elseif net_load[h] >= high_nl_thresh && total_power > 0.0
                # ── Priority 2: reserve-aware proactive discharge ──────────────
                # Only energy above the reserve floor is available for P2.
                avail_above = max(0.0, (curr_soc - soc_floor) * eta_dis)
                max_dis     = min(total_power, avail_above)
                if max_dis > 0.0
                    dis      = max_dis
                    curr_soc -= dis / eta_dis
                end
            end

            # ── Priority 3: charge during low net-load / surplus ──────────
            if dis == 0.0 && net_load[h] <= charge_nl_thresh && total_power > 0.0
                surplus  = net_supply - load_h
                headroom = total_energy - curr_soc
                if surplus > 0.0 && headroom > 0.0
                    max_chg = min(total_power, surplus, headroom / eta_ch)
                    chg     = max(0.0, max_chg)
                    curr_soc += chg * eta_ch
                end
            end

            # clamp SOC for floating-point safety
            curr_soc = clamp(curr_soc, 0.0, total_energy)

            soc[h]    = curr_soc
            st_dis[h] = dis
            st_chg[h] = chg

            # power balance
            net_bal      = net_supply + dis - chg - load_h
            load_shed[h] = max(0.0, -net_bal)
            curtailmt[h] = max(0.0,  net_bal)
        end

        results[s] = DispatchResult(s, load_shed, st_dis, st_chg, soc,
                                    nothing, curtailmt, 0.0)
    end

    return results
end

"""
    run_m1b_reserve_aware(system, scenarios::ScenarioSet, config) -> Vector{DispatchResult}

ScenarioSet overload — extracts the availability array and delegates.
"""
function run_m1b_reserve_aware(system   ::SystemData,
                                scenarios::ScenarioSet,
                                config   ::SimConfig)::Vector{DispatchResult}
    return run_m1b_reserve_aware(system, scenarios.availability, config)
end
