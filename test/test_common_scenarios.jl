@testset "Common random numbers — all models share identical ScenarioSet" begin
    sys      = make_test_system(24)     # 24-hour horizon for speed
    base_cfg = SimConfig(n_scenarios=3, seed=7)
    scenarios = generate_scenarios(sys, base_cfg)
    avail    = scenarios.availability

    # ScenarioSet metadata must match base_cfg.
    @test scenarios.n_scenarios == base_cfg.n_scenarios
    @test scenarios.seed        == base_cfg.seed
    @test size(avail)           == (base_cfg.n_scenarios,
                                    nrow(thermal_generators(sys)), 24)

    # For each model: running on the raw array (avail) must produce the
    # same load_shed as running on the ScenarioSet wrapper.  This verifies
    # that the ScenarioSet overload faithfully forwards the same availability
    # data that a comparison run would use.
    cfg_m2 = SimConfig(n_scenarios=3, seed=7, lookahead_hours=6)
    cfg_m3 = SimConfig(n_scenarios=3, seed=7, cyclic_soc=false)

    for (label, model_fn, cfg) in [
            ("M1", run_m1_rule_based,     base_cfg),
            ("M2", run_m2_rolling_window, cfg_m2),
            ("M3", run_m3_ed_dispatch,    cfg_m3),
        ]
        res_raw     = model_fn(sys, avail,     cfg)
        res_wrapped = model_fn(sys, scenarios, cfg)

        for s in 1:base_cfg.n_scenarios
            @test res_raw[s].load_shed == res_wrapped[s].load_shed
        end
    end

    # A second ScenarioSet from the same seed must be bit-identical.
    scenarios2 = generate_scenarios(sys, base_cfg)
    @test scenarios.availability == scenarios2.availability

    # A ScenarioSet from a different seed must differ.
    other_cfg  = SimConfig(n_scenarios=3, seed=8)
    scenarios3 = generate_scenarios(sys, other_cfg)
    @test scenarios.availability != scenarios3.availability
end
