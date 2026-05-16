# ── RA-3 / M3: Full-year economic dispatch LP benchmark ───────────────────
#
# This module implements RA-3 in the method hierarchy:
#   RA-3 is a sequential Monte Carlo method where each scenario is solved as
#   a single full-year (8760-hour) economic dispatch LP with perfect foresight
#   within the scenario.  It is the reliability benchmark against which faster
#   RA-compatible approximations (RA-1b, RA-2) are compared.
#
# Scope: ED only (no unit commitment).  RA-4 / M4 (HOPE UC/PCM) will provide
# a higher-fidelity benchmark for selected stress periods where UC constraints
# may materially affect feasibility.
#
# Runtime: ~360 s/scenario on the 8760-hour RTS-GMLC dataset (HiGHS solver).
#
# ── Full-year economic dispatch LP (per scenario) ─────────────────────────
#
# For each Monte Carlo scenario, build a single JuMP LP over all T hours.
#
# Variables:
#   p[g,h]          thermal generator g dispatch (MW)
#   charge[s,h]     storage unit s charging (MW)
#   discharge[s,h]  storage unit s discharging (MW)
#   soc[s,h]        storage unit s state of charge, end-of-hour (MWh)
#   load_shed[h]    involuntary load shedding (MW)
#   curtailment[h]  VRE / thermal curtailment (MW)
#
# Objective (minimise total cost):
#   Σ_h Σ_g var_cost[g] * p[g,h]
# + Σ_h Σ_s stor_var_cost[s] * (charge[s,h] + discharge[s,h])
# + Σ_h VOLL * load_shed[h]
#
# Power balance (equality):
#   Σ_g p[g,h] + p_vre[h] + Σ_s discharge[s,h] - Σ_s charge[s,h]
#   + load_shed[h] - curtailment[h]  =  load[h]
#
# Generator bounds:
#   0  ≤  p[g,h]  ≤  A[g,h] * pmax[g]
#
# Storage dynamics (per unit s):
#   soc[s,h] = soc[s,h-1] + η_ch[s]*charge[s,h] - discharge[s,h]/η_dis[s]
#   soc[s,0] = initial_soc_mwh[s]  (parameter)
#   0  ≤  soc[s,h]        ≤  energy_mwh[s]
#   0  ≤  charge[s,h]     ≤  power_mw[s]
#   0  ≤  discharge[s,h]  ≤  power_mw[s]
#
# Cyclic SOC (if config.cyclic_soc):
#   soc[s,T] = initial_soc_mwh[s]
#
# A small storage_cycling_cost (config) on (charge+discharge) discourages
# simultaneous charging and discharging without adding binary variables.

"""
    run_m3_ed_dispatch(system, availability, config) -> Vector{DispatchResult}

Full-year ED LP for every scenario in `availability[scenario, gen, hour]`.
Each scenario is solved as one LP; results include per-generator dispatch.
"""
function run_m3_ed_dispatch(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        config      ::SimConfig)::Vector{DispatchResult}

    therm   = thermal_generators(system)
    stor    = system.storage
    n_therm = nrow(therm)
    n_stor  = nrow(stor)
    n_scen  = size(availability, 1)
    T       = system.n_hours
    VOLL    = config.voll
    cyc_cc  = config.storage_cycling_cost

    pmax      = Float64.(therm.pmax_mw)
    var_cost  = Float64.(therm.variable_cost_per_mwh)

    if n_stor > 0
        pow_mw    = Float64.(stor.power_mw)
        eng_mwh   = Float64.(stor.energy_mwh)
        eta_ch    = Float64.(stor.charge_efficiency)
        eta_dis   = Float64.(stor.discharge_efficiency)
        s_vcost   = Float64.(stor.variable_cost_per_mwh)
        soc0      = Float64.(stor.initial_soc_mwh)
    end

    # ── pre-compute VRE output ─────────────────────────────────────────────
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:T]

    results = Vector{DispatchResult}(undef, n_scen)

    for s in 1:n_scen
        t_start = time()

        # availability matrix for this scenario: A[g, h]
        A = Int8.(view(availability, s, :, :))   # n_therm × T

        mdl = Model(HiGHS.Optimizer)
        set_silent(mdl)
        set_optimizer_attribute(mdl, "presolve", "on")
        set_optimizer_attribute(mdl, "parallel", "on")

        # ── decision variables ────────────────────────────────────────────
        @variable(mdl, p[1:n_therm, 1:T]     >= 0.0)
        @variable(mdl, load_shed[1:T]         >= 0.0)
        @variable(mdl, curtailment[1:T]       >= 0.0)

        if n_stor > 0
            @variable(mdl, charge[1:n_stor, 1:T]    >= 0.0)
            @variable(mdl, discharge_s[1:n_stor, 1:T] >= 0.0)
            @variable(mdl, soc_var[1:n_stor, 1:T]   >= 0.0)
        end

        # ── generator bounds ──────────────────────────────────────────────
        for g in 1:n_therm, h in 1:T
            @constraint(mdl, p[g, h] <= A[g, h] * pmax[g])
        end

        # ── storage constraints ───────────────────────────────────────────
        if n_stor > 0
            for st in 1:n_stor
                @constraint(mdl, [h=1:T], charge[st, h]      <= pow_mw[st])
                @constraint(mdl, [h=1:T], discharge_s[st, h] <= pow_mw[st])
                @constraint(mdl, [h=1:T], soc_var[st, h]     <= eng_mwh[st])

                # SOC dynamics
                @constraint(mdl,
                    soc_var[st, 1] ==
                    soc0[st] + eta_ch[st] * charge[st, 1]
                             - discharge_s[st, 1] / eta_dis[st])
                for h in 2:T
                    @constraint(mdl,
                        soc_var[st, h] ==
                        soc_var[st, h-1] + eta_ch[st] * charge[st, h]
                                         - discharge_s[st, h] / eta_dis[st])
                end

                # cyclic SOC
                if config.cyclic_soc
                    @constraint(mdl, soc_var[st, T] == soc0[st])
                end
            end
        end

        # ── power balance (equality) ───────────────────────────────────────
        for h in 1:T
            gen_sum = sum(p[g, h] for g in 1:n_therm; init = AffExpr(0.0))
            if n_stor > 0
                stor_net = sum(discharge_s[st, h] - charge[st, h]
                               for st in 1:n_stor; init = AffExpr(0.0))
                @constraint(mdl,
                    gen_sum + p_vre[h] + stor_net +
                    load_shed[h] - curtailment[h] == system.load_mw[h])
            else
                @constraint(mdl,
                    gen_sum + p_vre[h] +
                    load_shed[h] - curtailment[h] == system.load_mw[h])
            end
        end

        # ── objective ─────────────────────────────────────────────────────
        # Build incrementally to avoid allocating 639K+ temporary AffExprs.
        obj = JuMP.AffExpr(0.0)
        for h in 1:T
            for g in 1:n_therm
                JuMP.add_to_expression!(obj, var_cost[g], p[g, h])
            end
            JuMP.add_to_expression!(obj, VOLL, load_shed[h])
        end
        if n_stor > 0
            stor_cost = s_vcost .+ cyc_cc
            for h in 1:T, st in 1:n_stor
                JuMP.add_to_expression!(obj, stor_cost[st], charge[st, h])
                JuMP.add_to_expression!(obj, stor_cost[st], discharge_s[st, h])
            end
        end
        @objective(mdl, Min, obj)

        optimize!(mdl)

        status = termination_status(mdl)
        if status ∉ (MOI.OPTIMAL, MOI.LOCALLY_SOLVED)
            @warn "M3 scenario=$s: solver status $status"
        end

        # ── extract results ───────────────────────────────────────────────
        ls_vec   = max.(0.0, value.(load_shed))
        cur_vec  = max.(0.0, value.(curtailment))
        rt       = time() - t_start

        if n_stor > 0
            dis_vec = vec(sum(max.(0.0, value.(discharge_s)), dims=1))
            chg_vec = vec(sum(max.(0.0, value.(charge)),      dims=1))
            soc_vec = vec(value.(soc_var[1, :]))   # first storage unit's SOC
        else
            dis_vec = zeros(T)
            chg_vec = zeros(T)
            soc_vec = zeros(T)
        end

        th_mat = Matrix{Float64}(value.(p))   # n_therm × T

        results[s] = DispatchResult(s, ls_vec, dis_vec, chg_vec, soc_vec,
                                    th_mat, cur_vec, rt)
    end

    return results
end

"""
    run_m3_ed_dispatch(system, scenarios::ScenarioSet, config) -> Vector{DispatchResult}

ScenarioSet overload.
"""
function run_m3_ed_dispatch(system    ::SystemData,
                             scenarios ::ScenarioSet,
                             config    ::SimConfig)::Vector{DispatchResult}
    return run_m3_ed_dispatch(system, scenarios.availability, config)
end

"""
    run_m3_ed_dispatch(system, config) -> Vector{DispatchResult}

Generate scenarios internally then run M3.
"""
function run_m3_ed_dispatch(system::SystemData,
                             config::SimConfig)::Vector{DispatchResult}
    avail = generate_scenarios(system, config)
    return run_m3_ed_dispatch(system, avail, config)
end
