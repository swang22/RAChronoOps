@testset "build_risk_windows" begin
    n = 8760

    # No risk hours → empty result
    @test isempty(build_risk_windows(fill(1000.0, n), n, 500.0, 24, 24, 24))

    # Single risk hour → one window; check buffer arithmetic
    margin_one = fill(1000.0, n)
    margin_one[100] = 0.0
    wins = build_risk_windows(margin_one, n, 500.0, 24, 24, 24)
    @test length(wins) == 1
    @test wins[1][1] == 76     # max(1, 100-24)
    @test wins[1][2] == 124    # min(8760, 100+24)

    # Buffer clips at left boundary
    margin_edge = fill(1000.0, n)
    margin_edge[5] = 0.0
    wins_edge = build_risk_windows(margin_edge, n, 500.0, 24, 24, 24)
    @test length(wins_edge) == 1
    @test wins_edge[1][1] == 1        # clipped to 1

    # Two nearby risk hours merge into one window
    margin_near = fill(1000.0, n)
    margin_near[100] = 0.0
    margin_near[110] = 0.0
    wins_near = build_risk_windows(margin_near, n, 500.0, 24, 24, 24)
    @test length(wins_near) == 1

    # Two distant risk hours stay separate
    margin_far = fill(1000.0, n)
    margin_far[100]  = 0.0
    margin_far[1000] = 0.0
    wins_far = build_risk_windows(margin_far, n, 500.0, 24, 24, 24)
    @test length(wins_far) == 2

    # min_len enforced: single risk hour with buffer=0 → window padded to 48h
    margin_short = fill(1000.0, n)
    margin_short[n ÷ 2] = 0.0
    wins_short = build_risk_windows(margin_short, n, 500.0, 0, 0, 48)
    @test length(wins_short) == 1
    @test wins_short[1][2] - wins_short[1][1] + 1 >= 48

    # All windows respect [1, n_hours] clip
    for (ws, we) in wins_far
        @test ws >= 1
        @test we <= n
        @test ws <= we
    end
end

@testset "RA-2 output bounds" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=5, seed=42)
    avail  = generate_scenarios(sys, config)
    results = run_m2_event_window_lp(sys, avail, config)

    total_energy = sum(sys.storage.energy_mwh)

    @test length(results) == 5
    for r in results
        @test all(r.load_shed         .>= -1e-9)
        @test all(r.storage_discharge .>= -1e-9)
        @test all(r.storage_charge    .>= -1e-9)
        @test all(r.curtailment       .>= -1e-9)
        @test all(r.soc               .>= -1e-6)
        @test all(r.soc               .<= total_energy + 1e-6)
        @test r.runtime_seconds        >= 0.0
        @test isnothing(r.thermal_dispatch)   # RA-2 uses aggregated dispatch
    end
end

@testset "RA-2 no risk hours degenerates to M1b" begin
    # Thermal capacity >> load and FOR=0 → margin = 1900 MW >> risk_margin_mw=500
    # → no risk hours → no LP windows → RA-2 is pure RA-1b → results identical
    gen_df = DataFrame(
        gen_id                 = ["TH1"],
        gen_type               = ["CT"],
        fuel                   = ["Gas"],
        pmax_mw                = [2000.0],
        pmin_mw                = [0.0],
        variable_cost_per_mwh  = [50.0],
        forced_outage_rate     = [0.0],
        mean_repair_time_hours = [0.0],
        is_thermal             = [1],
        is_vre                 = [0],
        vre_type               = [""],
    )
    stor_df = DataFrame(
        storage_id            = ["BAT1"],
        power_mw              = [25.0],
        energy_mwh            = [100.0],
        charge_efficiency     = [0.90],
        discharge_efficiency  = [0.90],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [50.0],
    )
    sys_big = SystemData(gen_df, stor_df,
                         fill(100.0, 48), fill(0.0, 48), fill(0.0, 48), 48)
    config = SimConfig(n_scenarios=5, seed=42)
    avail  = generate_scenarios(sys_big, config)
    res_m2  = run_m2_event_window_lp(sys_big, avail, config)
    res_m1b = run_m1b_reserve_aware(sys_big, avail, config)

    for (r2, r1b) in zip(res_m2, res_m1b)
        @test r2.load_shed         ≈ r1b.load_shed         atol=1e-9
        @test r2.storage_discharge ≈ r1b.storage_discharge atol=1e-9
        @test r2.storage_charge    ≈ r1b.storage_charge    atol=1e-9
        @test r2.soc               ≈ r1b.soc               atol=1e-9
    end
end

@testset "Ra2ScenarioDiag fields" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=5, seed=42)
    avail  = generate_scenarios(sys, config)
    results, diags = run_m2_with_diagnostics(sys, avail, config)

    @test length(results) == 5
    @test length(diags)   == 5

    for (i, d) in enumerate(diags)
        @test d.scenario_id    == i
        @test d.n_risk_hours   >= 0
        @test d.n_windows      >= 0
        @test d.total_window_h >= 0
        @test d.n_lp_failures  == 0     # well-posed system, no LP failures

        if d.n_windows > 0
            @test d.mean_window_len ≈ d.total_window_h / d.n_windows  atol=1e-9
            @test d.max_window_len  >= d.mean_window_len - 1e-9
        else
            @test d.mean_window_len == 0.0
            @test d.max_window_len  == 0
        end
    end
end

@testset "RA-2 stressed system: LP windows present and output valid" begin
    # pmax=60 MW, load=55 MW → pre-storage margin = 5 MW < risk_margin_mw=50
    # → every hour is a risk hour → one LP window covers the full 48-hour horizon
    gen_df = DataFrame(
        gen_id                 = ["TH1"],
        gen_type               = ["CT"],
        fuel                   = ["Gas"],
        pmax_mw                = [60.0],
        pmin_mw                = [0.0],
        variable_cost_per_mwh  = [50.0],
        forced_outage_rate     = [0.10],
        mean_repair_time_hours = [10.0],
        is_thermal             = [1],
        is_vre                 = [0],
        vre_type               = [""],
    )
    stor_df = DataFrame(
        storage_id            = ["BAT1"],
        power_mw              = [20.0],
        energy_mwh            = [80.0],
        charge_efficiency     = [0.90],
        discharge_efficiency  = [0.90],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [40.0],
    )
    sys_s = SystemData(gen_df, stor_df,
                       fill(55.0, 48), fill(0.0, 48), fill(0.0, 48), 48)
    config = SimConfig(n_scenarios=5, seed=42, risk_margin_mw=50.0)
    avail  = generate_scenarios(sys_s, config)
    results, diags = run_m2_with_diagnostics(sys_s, avail, config)

    @test length(results) == 5
    # All scenarios should have at least one window
    @test all(d.n_windows > 0 for d in diags)
    @test all(d.n_lp_failures == 0 for d in diags)
    # Output bounds still hold after LP dispatch
    stor_energy = sum(sys_s.storage.energy_mwh)
    for r in results
        @test all(r.load_shed         .>= -1e-9)
        @test all(r.storage_discharge .>= -1e-9)
        @test all(r.storage_charge    .>= -1e-9)
        @test all(r.soc               .>= -1e-6)
        @test all(r.soc               .<= stor_energy + 1e-6)
    end
end
