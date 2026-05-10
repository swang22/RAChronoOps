@testset "Outage generation" begin
    sys    = make_test_system(8760)   # full year for statistical accuracy
    therm  = thermal_generators(sys)
    n_therm = nrow(therm)
    N_scen  = 500   # enough to get statistical accuracy
    seed    = 7

    scen  = generate_scenarios(sys, N_scen, seed)
    avail = scen.availability   # Array{Int8,3}: n_scen × n_therm × n_hours

    # ── shape ────────────────────────────────────────────────────────────
    @test size(avail) == (N_scen, n_therm, 8760)

    # ── binary values only ───────────────────────────────────────────────
    @test all(x -> x == 0 || x == 1, avail)

    # ── mean availability ≈ 1 − FOR ──────────────────────────────────────
    for (g, row) in enumerate(eachrow(therm))
        FOR     = row.forced_outage_rate
        target  = 1.0 - FOR
        MTTR    = row.mean_repair_time_hours
        sim_avg = mean(avail[:, g, :])
        # Autocorrelation in the Markov chain inflates the true variance:
        # IACT ≈ 1 + 2ρ/(1-ρ) where ρ = 1 - p_fail - p_repair.
        p_rep  = 1.0 - exp(-1.0 / max(MTTR, 1.0))
        p_fal  = FOR > 0 ? FOR * p_rep / (1.0 - FOR) : 0.0
        rho    = 1.0 - p_fal - p_rep
        iact   = 1.0 + 2.0 * rho / (1.0 - rho)
        se     = sqrt(target * (1.0 - target) / (N_scen * 8760) * iact)
        @test abs(sim_avg - target) < 5 * se   # 5-σ tolerance with IACT correction
    end

    # ── determinism: same seed → same array ──────────────────────────────
    avail2 = generate_scenarios(sys, N_scen, seed).availability
    @test avail == avail2

    # ── different seed → different array ─────────────────────────────────
    avail3 = generate_scenarios(sys, N_scen, seed + 1).availability
    @test avail != avail3

    # ── zero-FOR generator stays available ───────────────────────────────
    vre_idx_list = findall(eachrow(therm)) do r
        r.forced_outage_rate == 0.0
    end
    # (our test system has no zero-FOR thermal; guard with isempty)
    if !isempty(vre_idx_list)
        @test all(avail[:, vre_idx_list, :] .== 1)
    end
end
