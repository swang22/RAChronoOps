# ── SequentialOutages ─────────────────────────────────────────────────────
#
# Two-state Markov outage model for thermal generators.
#
# For each generator g with FOR and MTTR:
#   MTTF     = MTTR * (1 - FOR) / FOR
#   p_fail   = 1 - exp(-1 / MTTF)    [prob of failing in one hour when up]
#   p_repair = 1 - exp(-1 / MTTR)    [prob of repairing in one hour when down]
#
# Initial state drawn from the steady-state distribution (prob_up = 1 − FOR).
# Returns a ScenarioSet whose .availability[scenario, gen, hour] ∈ {0, 1}.

"""
    generate_scenarios(system, n_scenarios, seed) -> ScenarioSet

Sample `n_scenarios` independent availability trajectories for all thermal
generators in `system` using a seeded MersenneTwister.

Returns a `ScenarioSet` with `availability[scenario, generator, hour]` ∈ {0,1}.
"""
function generate_scenarios(
        system      ::SystemData,
        n_scenarios ::Int,
        seed        ::Int)::ScenarioSet

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_hours = system.n_hours

    avail = ones(Int8, n_scenarios, n_therm, n_hours)

    rng = MersenneTwister(seed)

    # pre-compute per-generator transition probabilities
    p_fail   = Vector{Float64}(undef, n_therm)
    p_repair = Vector{Float64}(undef, n_therm)
    p_ss_up  = Vector{Float64}(undef, n_therm)

    for (g, row) in enumerate(eachrow(therm))
        FOR  = Float64(row.forced_outage_rate)
        MTTR = Float64(row.mean_repair_time_hours)

        if FOR <= 0.0
            p_fail[g]   = 0.0
            p_repair[g] = 1.0
            p_ss_up[g]  = 1.0
        elseif FOR >= 1.0
            p_fail[g]   = 1.0
            p_repair[g] = 0.0
            p_ss_up[g]  = 0.0
        else
            # p_repair from hourly repair rate; p_fail calibrated so that
            # the DTMC steady-state unavailability exactly equals FOR:
            #   p_fail / (p_fail + p_repair) = FOR  =>  p_fail = FOR * p_repair / (1 - FOR)
            p_repair[g] = 1.0 - exp(-1.0 / MTTR)
            p_fail[g]   = FOR * p_repair[g] / (1.0 - FOR)
            p_ss_up[g]  = 1.0 - FOR
        end
    end

    for s in 1:n_scenarios
        for g in 1:n_therm
            state = rand(rng) < p_ss_up[g] ? Int8(1) : Int8(0)
            pf    = p_fail[g]
            pr    = p_repair[g]
            for h in 1:n_hours
                if state == Int8(1)
                    state = rand(rng) < pf ? Int8(0) : Int8(1)
                else
                    state = rand(rng) < pr ? Int8(1) : Int8(0)
                end
                avail[s, g, h] = state
            end
        end
    end

    return ScenarioSet(avail, n_scenarios, n_therm, n_hours, seed)
end

"""
    generate_scenarios(system, config) -> ScenarioSet

Convenience overload that reads `n_scenarios` and `seed` from `config`.
"""
function generate_scenarios(system::SystemData,
                             config::SimConfig)::ScenarioSet
    return generate_scenarios(system, config.n_scenarios, config.seed)
end
