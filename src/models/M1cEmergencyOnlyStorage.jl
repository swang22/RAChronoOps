# ── RA-1c / M1c: Emergency-only storage heuristic ──────────────────────────
#
# Represents the simplest reliability-oriented storage rule: storage is only
# discharged when there is an observed pre-storage shortfall.  No proactive
# peak-shaving (no Priority-2 discharge).  Charging occurs whenever there is
# surplus energy after meeting load.
#
# Priority stack (each hour):
#   1. Emergency discharge: cover pre-storage shortfall up to power/SOC limits.
#   2. Charge from surplus: if no shortfall and net_supply > load, charge
#      subject to power limit, headroom, and charging efficiency.
#   3. Idle: no action.
#
# Diagnostic purpose: isolate whether the M1b LOLH overestimation bias
# originates from proactive discharging depleting SOC before shortage events.
# M1c does not attempt to outperform M2; it provides a clean practice-oriented
# lower rung on the baseline ladder (M1 → M1b → M1c → M2 → M3).

"""
    run_m1c_emergency_only(system, availability, config) -> Vector{DispatchResult}

Run RA-1c (M1c) for every scenario encoded in `availability[scenario, gen, hour]`.

Storage is discharged only to cover pre-storage shortfalls (Priority-1).
Charging occurs unconditionally whenever net supply exceeds load (no
net-load quantile threshold).  Priority-2 proactive peak-shaving discharge
is entirely absent.
"""
function run_m1c_emergency_only(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        _config     ::SimConfig)::Vector{DispatchResult}

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

            therm_avail = zero(Float64)
            for g in 1:n_therm
                therm_avail += pmax[g] * availability[s, g, h]
            end

            net_supply    = therm_avail + p_vre[h]
            shortfall_pre = max(0.0, load_h - net_supply)

            dis = 0.0
            chg = 0.0

            if shortfall_pre > 0.0 && total_power > 0.0
                # ── Priority 1: emergency discharge ───────────────────────
                max_dis  = min(total_power, curr_soc * eta_dis)
                dis      = min(shortfall_pre, max_dis)
                curr_soc -= dis / eta_dis

            else
                # ── Priority 2 (M1c): charge from surplus (no proactive discharge) ──
                # Charge whenever net supply exceeds load; no net-load quantile gate.
                surplus  = net_supply - load_h
                headroom = total_energy - curr_soc
                if surplus > 0.0 && headroom > 0.0 && total_power > 0.0
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
    run_m1c_emergency_only(system, scenarios::ScenarioSet, config) -> Vector{DispatchResult}

ScenarioSet overload — extracts the availability array and delegates.
"""
function run_m1c_emergency_only(system   ::SystemData,
                                 scenarios::ScenarioSet,
                                 config   ::SimConfig)::Vector{DispatchResult}
    return run_m1c_emergency_only(system, scenarios.availability, config)
end
