@testset "Storage dynamics — M1" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=50, seed=11)
    avail  = generate_scenarios(sys, config)
    results = run_m1_rule_based(sys, avail, config)

    stor        = sys.storage
    total_energy = sum(stor.energy_mwh)
    eta_ch       = mean(stor.charge_efficiency)
    eta_dis      = mean(stor.discharge_efficiency)
    init_soc     = sum(stor.initial_soc_mwh)

    for r in results
        n = length(r.load_shed)

        # ── SOC bounds ───────────────────────────────────────────────────
        @test all(r.soc .>= -1e-9)            # non-negative (with tol)
        @test all(r.soc .<= total_energy + 1e-9)

        # ── non-negative outputs ─────────────────────────────────────────
        @test all(r.load_shed         .>= -1e-9)
        @test all(r.storage_discharge .>= -1e-9)
        @test all(r.storage_charge    .>= -1e-9)
        @test all(r.curtailment       .>= -1e-9)

        # ── SOC dynamics ─────────────────────────────────────────────────
        # soc[1] = init_soc + charge[1]*η_ch - discharge[1]/η_dis
        @test r.soc[1] ≈ clamp(
            init_soc + r.storage_charge[1] * eta_ch
                     - r.storage_discharge[1] / eta_dis,
            0.0, total_energy) atol=1e-6

        # soc[h] ≈ soc[h-1] + charge[h]*η_ch - discharge[h]/η_dis
        for h in 2:n
            expected = clamp(
                r.soc[h-1] + r.storage_charge[h] * eta_ch
                           - r.storage_discharge[h] / eta_dis,
                0.0, total_energy)
            @test r.soc[h] ≈ expected atol=1e-6
        end

        # ── charge and discharge not simultaneously positive ───────────────
        # (Rule-based M1 ensures this by construction; verify it.)
        for h in 1:n
            @test !(r.storage_charge[h] > 1e-9 && r.storage_discharge[h] > 1e-9)
        end
    end
end

@testset "Storage dynamics — M1b (default reserve_fraction=0.50)" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=50, seed=11)   # reserve_fraction=0.50 by default
    avail  = generate_scenarios(sys, config)
    results = run_m1b_reserve_aware(sys, avail, config)

    stor         = sys.storage
    total_energy = sum(stor.energy_mwh)
    eta_ch       = mean(stor.charge_efficiency)
    eta_dis      = mean(stor.discharge_efficiency)
    init_soc     = sum(stor.initial_soc_mwh)

    for r in results
        n = length(r.load_shed)

        # SOC within [0, total_energy]
        @test all(r.soc .>= -1e-9)
        @test all(r.soc .<= total_energy + 1e-9)

        # All outputs non-negative
        @test all(r.load_shed         .>= -1e-9)
        @test all(r.storage_discharge .>= -1e-9)
        @test all(r.storage_charge    .>= -1e-9)
        @test all(r.curtailment       .>= -1e-9)

        # SOC dynamics: soc[1] consistent with init + charge - discharge
        @test r.soc[1] ≈ clamp(
            init_soc + r.storage_charge[1] * eta_ch
                     - r.storage_discharge[1] / eta_dis,
            0.0, total_energy) atol=1e-6

        for h in 2:n
            expected = clamp(
                r.soc[h-1] + r.storage_charge[h] * eta_ch
                           - r.storage_discharge[h] / eta_dis,
                0.0, total_energy)
            @test r.soc[h] ≈ expected atol=1e-6
        end

        # No simultaneous charge and discharge
        for h in 1:n
            @test !(r.storage_charge[h] > 1e-9 && r.storage_discharge[h] > 1e-9)
        end
    end
end

@testset "M1b reserve_fraction=1.0 disables Priority-2" begin
    # System with no thermal forced outages: P1 never fires.
    # With reserve_fraction=1.0, soc_floor = total_energy, so
    # available_above_floor = 0 always → P2 also never discharges.
    # Expected result: zero storage discharge across all scenarios.
    gen_df = DataFrame(
        gen_id                 = ["TH1"],
        gen_type               = ["CT"],
        fuel                   = ["Gas"],
        pmax_mw                = [200.0],
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
        charge_efficiency     = [1.0],
        discharge_efficiency  = [1.0],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [50.0],
    )
    sys_nf = SystemData(gen_df, stor_df,
                        fill(80.0, 48), fill(0.0, 48), fill(0.0, 48), 48)

    cfg_rf1 = SimConfig(n_scenarios=5, seed=42, reserve_fraction=1.0)
    avail   = generate_scenarios(sys_nf, cfg_rf1)
    results = run_m1b_reserve_aware(sys_nf, avail, cfg_rf1)

    for r in results
        @test all(r.storage_discharge .< 1e-9)   # P2 disabled, P1 never fires
        @test all(r.load_shed         .< 1e-9)   # no shortfalls possible
    end
end

@testset "M1b reserve_fraction=0.0 matches RA-1a" begin
    # With reserve_fraction=0, soc_floor=0, so available_above_floor = curr_soc*eta_dis
    # which equals M1's max_dis formula → results must be identical.
    sys        = make_test_system(168)
    cfg_rf0    = SimConfig(n_scenarios=20, seed=77, reserve_fraction=0.0)
    avail      = generate_scenarios(sys, cfg_rf0)
    results_m1  = run_m1_rule_based(sys,  avail, cfg_rf0)
    results_m1b = run_m1b_reserve_aware(sys, avail, cfg_rf0)

    for (r1, r1b) in zip(results_m1, results_m1b)
        @test r1.load_shed         ≈ r1b.load_shed         atol=1e-9
        @test r1.storage_discharge ≈ r1b.storage_discharge atol=1e-9
        @test r1.storage_charge    ≈ r1b.storage_charge    atol=1e-9
        @test r1.soc               ≈ r1b.soc               atol=1e-9
    end
end

@testset "M1b storage sensitivity — calibrated cases (conditional)" begin
    p05_dir = joinpath(PROJECT_ROOT, "data_processed", "cases", "storage120_p05_d4")
    p20_dir = joinpath(PROJECT_ROOT, "data_processed", "cases", "storage120_p20_d4")

    if isdir(p05_dir) && isdir(p20_dir)
        sys_p05 = load_system_data(p05_dir)
        sys_p20 = load_system_data(p20_dir)
        cfg     = SimConfig(n_scenarios=10, seed=42)

        scen_p05 = generate_scenarios(sys_p05, cfg)
        scen_p20 = generate_scenarios(sys_p20, cfg)

        res_p05 = run_m1b_reserve_aware(sys_p05, scen_p05, cfg)
        res_p20 = run_m1b_reserve_aware(sys_p20, scen_p20, cfg)

        m_p05 = compute_metrics(res_p05, sys_p05, cfg)
        m_p20 = compute_metrics(res_p20, sys_p20, cfg)

        # RA-1b should be storage-sensitive: more storage → lower LOLH
        @test m_p05.lolh != m_p20.lolh
        @test m_p20.lolh <= m_p05.lolh
    else
        @info "Skipping M1b storage-sensitivity test: calibrated cases not found in $p05_dir"
    end
end

@testset "Storage dynamics — M2" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=5, seed=22, lookahead_hours=12)
    avail  = generate_scenarios(sys, config)
    results = run_m2_rolling_window(sys, avail, config)

    stor        = sys.storage
    total_energy = sum(stor.energy_mwh)

    for r in results
        @test all(r.soc .>= -1e-6)
        @test all(r.soc .<= total_energy + 1e-6)
        @test all(r.load_shed .>= -1e-9)
    end
end
