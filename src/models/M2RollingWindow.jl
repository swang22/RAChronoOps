# ── M2: Sequential Monte Carlo with rolling-window LP (MPC) ───────────────
#
# At each hour h the model solves a JuMP LP over the look-ahead window
#   W = h : min(h + lookahead_hours - 1, T)
# only the first-hour decisions (charge, discharge) are implemented, then
# the horizon rolls forward.
#
# LP (per window, aggregate storage):
#   min  VOLL * Σ_t load_shed[t]
#      + ε    * Σ_t (charge[t] + discharge[t])
#   s.t. thermal_avail[t] + vre[t] + discharge[t] - charge[t]
#                         + load_shed[t]  >=  load[t]
#        soc[t] = soc[t-1] + η_ch*charge[t] - discharge[t]/η_dis
#        0 ≤ charge[t]    ≤ power_mw
#        0 ≤ discharge[t] ≤ power_mw
#        0 ≤ soc[t]       ≤ energy_mwh
#        0 ≤ load_shed[t]
#        soc[0] = current SOC  (parameter, not variable)
#
# Note: power balance uses ≥ (excess implicitly curtailed, not modelled).
# The ε term discourages simultaneous charge/discharge without binary vars.

"""
    run_m2_rolling_window(system, availability, config) -> Vector{DispatchResult}

MPC rolling-window LP for each scenario.

`config.lookahead_hours` controls the look-ahead horizon H_LA.
`config.epsilon_cycling` is the small cycling cost ε.
`config.voll`            is the value of lost load ($/MWh).
"""
function run_m2_rolling_window(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        config      ::SimConfig)::Vector{DispatchResult}

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_scen  = size(availability, 1)
    n_hours = system.n_hours
    H_LA    = config.lookahead_hours
    VOLL    = config.voll
    eps     = config.epsilon_cycling

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

    # ── pre-compute exogenous vectors ─────────────────────────────────────
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:n_hours]

    results = Vector{DispatchResult}(undef, n_scen)

    for s in 1:n_scen
        t_start = time()

        load_shed = zeros(Float64, n_hours)
        st_dis    = zeros(Float64, n_hours)
        st_chg    = zeros(Float64, n_hours)
        soc       = zeros(Float64, n_hours)
        curtailmt = zeros(Float64, n_hours)

        curr_soc = init_soc

        for h in 1:n_hours
            T_w = min(H_LA, n_hours - h + 1)   # window length

            # ── build window-level data ────────────────────────────────────
            therm_avail_w = Vector{Float64}(undef, T_w)
            vre_w         = Vector{Float64}(undef, T_w)
            load_w        = Vector{Float64}(undef, T_w)

            for t in 1:T_w
                hh = h + t - 1
                ta = zero(Float64)
                for g in 1:n_therm
                    ta += pmax[g] * availability[s, g, hh]
                end
                therm_avail_w[t] = ta
                vre_w[t]         = p_vre[hh]
                load_w[t]        = system.load_mw[hh]
            end

            # ── JuMP LP ────────────────────────────────────────────────────
            mdl = Model(HiGHS.Optimizer)
            set_silent(mdl)

            @variable(mdl, charge[1:T_w]    >= 0.0)
            @variable(mdl, discharge[1:T_w] >= 0.0)
            @variable(mdl, soc_var[1:T_w]   >= 0.0)
            @variable(mdl, load_shed_var[1:T_w] >= 0.0)

            @constraint(mdl, [t=1:T_w], charge[t]    <= total_power)
            @constraint(mdl, [t=1:T_w], discharge[t] <= total_power)
            @constraint(mdl, [t=1:T_w], soc_var[t]   <= total_energy)

            # power balance (≥ form; excess curtailed implicitly)
            @constraint(mdl, pb[t=1:T_w],
                therm_avail_w[t] + vre_w[t] + discharge[t] - charge[t]
                + load_shed_var[t] >= load_w[t])

            # SOC dynamics
            @constraint(mdl, soc_var[1] ==
                curr_soc + eta_ch * charge[1] - discharge[1] / eta_dis)
            for t in 2:T_w
                @constraint(mdl,
                    soc_var[t] == soc_var[t-1] +
                        eta_ch * charge[t] - discharge[t] / eta_dis)
            end

            @objective(mdl, Min,
                VOLL * sum(load_shed_var) +
                eps  * sum(charge[t] + discharge[t] for t in 1:T_w))

            optimize!(mdl)

            # ── extract first-hour decision ────────────────────────────────
            if termination_status(mdl) == MOI.OPTIMAL ||
               termination_status(mdl) == MOI.LOCALLY_SOLVED
                dis_h = max(0.0, value(discharge[1]))
                chg_h = max(0.0, value(charge[1]))
                # recompute SOC from actual decisions for numerical consistency
                curr_soc = clamp(
                    curr_soc + eta_ch * chg_h - dis_h / eta_dis,
                    0.0, total_energy)
            else
                # fallback: emergency rule-based discharge
                max_dis = min(total_power, curr_soc * eta_dis)
                net_sup = therm_avail_w[1] + vre_w[1]
                sf      = max(0.0, load_w[1] - net_sup)
                dis_h   = min(sf, max_dis)
                chg_h   = 0.0
                curr_soc = clamp(curr_soc - dis_h / eta_dis, 0.0, total_energy)
                @warn "M2 LP infeasible/suboptimal at scenario=$s hour=$h; using fallback"
            end

            st_dis[h] = dis_h
            st_chg[h] = chg_h
            soc[h]    = curr_soc

            net_bal      = therm_avail_w[1] + vre_w[1] + dis_h - chg_h - load_w[1]
            load_shed[h] = max(0.0, -net_bal)
            curtailmt[h] = max(0.0,  net_bal)
        end

        results[s] = DispatchResult(s, load_shed, st_dis, st_chg, soc,
                                    nothing, curtailmt,
                                    time() - t_start)
    end

    return results
end

"""
    run_m2_rolling_window(system, config) -> Vector{DispatchResult}

Generate scenarios internally then run M2.
"""
function run_m2_rolling_window(system::SystemData,
                                config::SimConfig)::Vector{DispatchResult}
    avail = generate_scenarios(system, config)
    return run_m2_rolling_window(system, avail, config)
end
