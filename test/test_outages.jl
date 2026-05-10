@testset "Outage generation" begin
    sys    = make_test_system(8760)   # full year for statistical accuracy
    therm  = thermal_generators(sys)
    n_therm = nrow(therm)
    N_scen  = 500   # enough to get statistical accuracy
    seed    = 7

    avail = generate_scenarios(sys, N_scen, seed)

    # ── shape ────────────────────────────────────────────────────────────
    @test size(avail) == (N_scen, n_therm, 8760)

    # ── binary values only ───────────────────────────────────────────────
    @test all(x -> x == 0 || x == 1, avail)

    # ── mean availability ≈ 1 − FOR (within ±3 σ under CLT) ─────────────
    for (g, row) in enumerate(eachrow(therm))
        FOR     = row.forced_outage_rate
        target  = 1.0 - FOR
        sim_avg = mean(avail[:, g, :])
        # standard error ≈ sqrt(p*(1-p)/(N*T))
        se = sqrt(target * (1 - target) / (N_scen * 8760))
        @test abs(sim_avg - target) < 5 * se   # 5-σ tolerance
    end

    # ── determinism: same seed → same array ──────────────────────────────
    avail2 = generate_scenarios(sys, N_scen, seed)
    @test avail == avail2

    # ── different seed → different array ─────────────────────────────────
    avail3 = generate_scenarios(sys, N_scen, seed + 1)
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
