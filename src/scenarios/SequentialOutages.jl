# ── SequentialOutages ─────────────────────────────────────────────────────
#
# Two-state Markov outage model for thermal generators.
#
# For each generator g with FOR and MTTR:
#   MTTF     = MTTR * (1 - FOR) / FOR
#   p_fail   = 1 - exp(-1 / MTTF)    [prob of failing in one hour when up]
#   p_repair = 1 - exp(-1 / MTTR)    [prob of repairing in one hour when down]
#
# Steady-state availability = 1 - FOR  (used to draw the initial state).
#
# Returns availability[scenario, generator, hour] ∈ {0, 1}.

"""
    generate_scenarios(system, n_scenarios, seed) -> Array{Int8, 3}

Sample `n_scenarios` independent availability trajectories for all thermal
generators in `system`.  Uses a seeded MersenneTwister for reproducibility.

Returns a 3-D Int8 array of shape (n_scenarios, n_thermal, n_hours).
Availability == 1 means the unit is operational, 0 means forced-out.
"""
function generate_scenarios(
        system::SystemData,
        n_scenarios::Int,
        seed::Int)::Array{Int8, 3}

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_hours = system.n_hours

    avail = ones(Int8, n_scenarios, n_therm, n_hours)

    rng = MersenneTwister(seed)

    # pre-compute transition probabilities
    p_fail   = Vector{Float64}(undef, n_therm)
    p_repair = Vector{Float64}(undef, n_therm)
    p_ss_up  = Vector{Float64}(undef, n_therm)  # steady-state probability of being up

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
            MTTF        = MTTR * (1.0 - FOR) / FOR
            p_fail[g]   = 1.0 - exp(-1.0 / MTTF)
            p_repair[g] = 1.0 - exp(-1.0 / MTTR)
            p_ss_up[g]  = 1.0 - FOR
        end
    end

    for s in 1:n_scenarios
        for g in 1:n_therm
            # Draw initial state from steady-state distribution
            state = rand(rng) < p_ss_up[g] ? Int8(1) : Int8(0)

            pf = p_fail[g]
            pr = p_repair[g]

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

    return avail
end

"""
    generate_scenarios(system, config) -> Array{Int8, 3}

Convenience overload that reads n_scenarios and seed from `config`.
"""
function generate_scenarios(system::SystemData, config::SimConfig)::Array{Int8, 3}
    return generate_scenarios(system, config.n_scenarios, config.seed)
end
