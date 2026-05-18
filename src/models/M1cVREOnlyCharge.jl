# ── RA-1c-V / M1c_VREOnlyCharge: VRE-surplus-only emergency heuristic ───────
#
# Identical to M1c (RA-1c) in every respect except charging:
#   M1c          charges from any surplus (thermal headroom included).
#   M1c_VREOnly  charges only from p_vre_h - load_h (strict VRE surplus).
#
# This model tests the "storage as renewable firming" interpretation: storage
# accumulates only curtailed renewable energy and discharges only in emergencies.
# In systems where VRE alone never exceeds load (e.g. VRE120_base/bal15 at
# current load scales), the battery effectively never charges, making the model
# equivalent to a no-storage baseline in those cases.
#
# Diagnostic purpose: quantify how much of M1c's LOLH accuracy depends on the
# ability to charge from dispatchable thermal headroom vs. VRE curtailment only.

"""
    run_m1c_vre_only_charge(system, availability, config) -> Vector{DispatchResult}

Run M1c_VREOnlyCharge for every scenario in `availability[scenario, gen, hour]`.

Storage charges only from VRE surplus (p_vre[h] > load[h]).  Emergency
discharge (Priority-1) and SOC dynamics are identical to M1c.  No
proactive discharge, no charging from thermal headroom.
"""
function run_m1c_vre_only_charge(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        _config     ::SimConfig)::Vector{DispatchResult}

    therm   = thermal_generators(system)
    n_therm = size(therm, 1)
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
                # ── VRE-only charging: only from p_vre > load surplus ─────
                # Thermal headroom is NOT available as a charging source.
                vre_surplus = max(0.0, p_vre[h] - load_h)
                headroom    = total_energy - curr_soc
                if vre_surplus > 0.0 && headroom > 0.0 && total_power > 0.0
                    max_chg = min(total_power, vre_surplus, headroom / eta_ch)
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
    run_m1c_vre_only_charge(system, scenarios::ScenarioSet, config) -> Vector{DispatchResult}

ScenarioSet overload — extracts the availability array and delegates.
"""
function run_m1c_vre_only_charge(system   ::SystemData,
                                  scenarios::ScenarioSet,
                                  config   ::SimConfig)::Vector{DispatchResult}
    return run_m1c_vre_only_charge(system, scenarios.availability, config)
end
