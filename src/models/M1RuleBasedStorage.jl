# ── DispatchResult (shared across M1/M2/M3) ───────────────────────────────

"""
    DispatchResult

Hourly dispatch outcome for one Monte Carlo scenario.

`soc[h]`             = end-of-hour state of charge (MWh)
`thermal_dispatch`   = n_thermal × n_hours matrix (M3 only; `nothing` for M1/M2)
`runtime_seconds`    = wall-clock solve time (0.0 for M1)
"""
struct DispatchResult
    scenario_id      ::Int
    load_shed        ::Vector{Float64}   # MW
    storage_discharge::Vector{Float64}   # MW
    storage_charge   ::Vector{Float64}   # MW
    soc              ::Vector{Float64}   # MWh, end-of-hour
    thermal_dispatch ::Union{Matrix{Float64}, Nothing}
    curtailment      ::Vector{Float64}   # MW
    runtime_seconds  ::Float64
end

# ── M1: Sequential Monte Carlo with rule-based storage dispatch ────────────
#
# Each hour the storage follows a priority stack:
#   1. Discharge to cover shortfall (emergency).
#   2. Proactive discharge during high-net-load hours (reliability rule).
#   3. Charge from surplus during low-net-load hours (valley-filling).
#   4. Idle.
#
# Storage is aggregated (aggregate power limit, aggregate energy, mean η).
# Thermal generators contribute their available capacity as a pool;
# no unit-level dispatch.

"""
    run_m1_rule_based(system, availability, config) -> Vector{DispatchResult}

Run M1 for every scenario encoded in `availability[scenario, gen, hour]`.
"""
function run_m1_rule_based(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        config      ::SimConfig)::Vector{DispatchResult}

    therm     = thermal_generators(system)
    n_therm   = nrow(therm)
    n_scen    = size(availability, 1)
    n_hours   = system.n_hours

    pmax = Float64.(therm.pmax_mw)

    # ── aggregate storage parameters ──────────────────────────────────────
    stor = system.storage
    n_stor = nrow(stor)
    if n_stor == 0
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

    # Rule thresholds computed from the unconditional distribution
    high_nl_thresh   = quantile(net_load, config.high_net_load_quantile)
    charge_nl_thresh = quantile(net_load, config.charge_net_load_quantile)

    results = Vector{DispatchResult}(undef, n_scen)

    for s in 1:n_scen
        load_shed  = zeros(Float64, n_hours)
        st_dis     = zeros(Float64, n_hours)
        st_chg     = zeros(Float64, n_hours)
        soc        = zeros(Float64, n_hours)
        curtailmt  = zeros(Float64, n_hours)

        curr_soc = init_soc

        for h in 1:n_hours
            load_h = system.load_mw[h]

            # Available thermal capacity this hour (pool)
            therm_avail = zero(Float64)
            for g in 1:n_therm
                therm_avail += pmax[g] * availability[s, g, h]
            end

            net_supply = therm_avail + p_vre[h]
            shortfall_pre = max(0.0, load_h - net_supply)

            dis = 0.0
            chg = 0.0

            if shortfall_pre > 0.0 && total_power > 0.0
                # ── priority 1: discharge to cover shortfall ───────────────
                max_dis = min(total_power, curr_soc * eta_dis)
                dis     = min(shortfall_pre, max_dis)
                curr_soc -= dis / eta_dis

            elseif net_load[h] >= high_nl_thresh &&
                   curr_soc > 0.0 && total_power > 0.0
                # ── priority 2: proactive discharge at peak net-load ────────
                max_dis = min(total_power, curr_soc * eta_dis)
                dis     = max_dis
                curr_soc -= dis / eta_dis
            end

            # ── priority 3: charge during low net-load / surplus ───────────
            if dis == 0.0 && net_load[h] <= charge_nl_thresh && total_power > 0.0
                surplus   = net_supply - load_h          # >= 0 when net_load ≤ thresh
                headroom  = total_energy - curr_soc
                if surplus > 0.0 && headroom > 0.0
                    max_chg = min(total_power, surplus, headroom / eta_ch)
                    chg     = max(0.0, max_chg)
                    curr_soc += chg * eta_ch
                end
            end

            # clamp SOC for floating-point safety
            curr_soc = clamp(curr_soc, 0.0, total_energy)

            soc[h]       = curr_soc
            st_dis[h]    = dis
            st_chg[h]    = chg

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
    run_m1_rule_based(system, config) -> Vector{DispatchResult}

Generate scenarios internally then run M1.
"""
function run_m1_rule_based(system::SystemData, config::SimConfig)::Vector{DispatchResult}
    avail = generate_scenarios(system, config)
    return run_m1_rule_based(system, avail, config)
end
