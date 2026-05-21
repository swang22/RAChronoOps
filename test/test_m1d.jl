@testset "M1d no-storage reduces to classical capacity check" begin
    # No storage → load_shed[h] = max(0, load - thermal_avail - vre), identical to MC-NoStorage.
    sys_no_stor = SystemData(
        DataFrame(
            gen_id                 = ["TH1"],
            gen_type               = ["CT"],
            fuel                   = ["Gas"],
            pmax_mw                = [50.0],
            pmin_mw                = [0.0],
            variable_cost_per_mwh  = [50.0],
            forced_outage_rate     = [0.10],
            mean_repair_time_hours = [10.0],
            is_thermal             = [1],
            is_vre                 = [0],
            vre_type               = [""],
        ),
        DataFrame(
            storage_id            = String[],
            power_mw              = Float64[],
            energy_mwh            = Float64[],
            charge_efficiency     = Float64[],
            discharge_efficiency  = Float64[],
            variable_cost_per_mwh = Float64[],
            initial_soc_mwh       = Float64[],
        ),
        fill(55.0, 168), fill(0.3, 168), fill(0.0, 168), 168,
    )
    cfg   = SimConfig(n_scenarios=10, seed=42)
    avail = generate_scenarios(sys_no_stor, cfg)
    res   = run_m1d_risk_hour_allocation(sys_no_stor, avail, cfg)
    res_mc = run_mc_no_storage(sys_no_stor, avail, cfg)

    for (r, rmc) in zip(res, res_mc)
        @test r.load_shed ≈ rmc.load_shed atol=1e-9
        @test all(r.storage_discharge .< 1e-9)
        @test all(r.storage_charge    .< 1e-9)
    end
end

@testset "M1d discharge only at pre-storage shortfall hours" begin
    # Abundant thermal (200 MW), no outages, load 55 MW → no shortfall → no discharge.
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
    sys_nf = SystemData(gen_df, stor_df, fill(55.0, 48), fill(0.0, 48), fill(0.0, 48), 48)

    cfg    = SimConfig(n_scenarios=5, seed=42)
    avail  = generate_scenarios(sys_nf, cfg)
    res    = run_m1d_risk_hour_allocation(sys_nf, avail, cfg)

    for r in res
        @test all(r.storage_discharge .< 1e-9)
        @test all(r.load_shed         .< 1e-9)
    end
end

@testset "M1d SOC bounds always hold" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=50, seed=42)
    avail  = generate_scenarios(sys, config)

    stor         = sys.storage
    total_energy = sum(stor.energy_mwh)

    for mode in ("earliest_first", "largest_first")
        cfg = SimConfig(n_scenarios=50, seed=42, risk_allocation_mode=mode)
        for r in run_m1d_risk_hour_allocation(sys, avail, cfg)
            @test all(r.soc .>= -1e-9)
            @test all(r.soc .<= total_energy + 1e-9)
            @test all(r.storage_discharge .>= -1e-9)
            @test all(r.storage_charge    .>= -1e-9)
            @test all(r.load_shed         .>= -1e-9)
        end
    end
end

@testset "M1d largest_first reduces max shortfall vs earliest_first (toy event)" begin
    # One thermal at 0 pmax (always offline), load=55 MW, storage 50 MW / 200 MWh at SOC=150 MWh.
    # Three-hour horizon with shortfalls [100, 50, 200] MW → event spans all 3 hours.
    # Wait — with load=55 and thermal=0: shortfall_pre = 55 every hour.
    # Let's build a 3-hour system to test the allocation explicitly.
    # shortfalls [10, 50, 100] MW, storage power=200 MW energy=80 MWh, SOC=80 MWh
    # earliest_first: h1 gets 10, h2 gets 50, h3 gets 20 → remaining shed: 0, 0, 80
    # largest_first:  h3 gets 80, h2=0, h1=0 → remaining shed: 10, 50, 20
    # max shed earliest = 80, max shed largest = 50 → largest-first wins

    gen_df = DataFrame(
        gen_id                 = ["TH1"],
        gen_type               = ["CT"],
        fuel                   = ["Gas"],
        pmax_mw                = [0.0],
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
        power_mw              = [200.0],
        energy_mwh            = [80.0],
        charge_efficiency     = [1.0],
        discharge_efficiency  = [1.0],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [80.0],
    )
    # Load varies: [10, 50, 100] MW — shortfall = load (no thermal, no VRE)
    sys3 = SystemData(gen_df, stor_df,
                      [10.0, 50.0, 100.0], fill(0.0, 3), fill(0.0, 3), 3)

    avail3 = generate_scenarios(sys3, SimConfig(n_scenarios=1, seed=42))

    cfg_ef = SimConfig(n_scenarios=1, seed=42, risk_allocation_mode="earliest_first")
    cfg_lf = SimConfig(n_scenarios=1, seed=42, risk_allocation_mode="largest_first")

    r_ef = run_m1d_risk_hour_allocation(sys3, avail3, cfg_ef)[1]
    r_lf = run_m1d_risk_hour_allocation(sys3, avail3, cfg_lf)[1]

    # largest_first should weakly reduce max hourly load_shed vs earliest_first
    @test maximum(r_lf.load_shed) <= maximum(r_ef.load_shed) + 1e-9

    # Total EUE must be equal (same storage budget)
    @test sum(r_ef.load_shed) ≈ sum(r_lf.load_shed) atol=1e-6
end

@testset "M1d earliest_first matches M1c on single scenario" begin
    # With a full-year lookback (8760 h), M1d earliest_first should match M1c exactly:
    # both charge from all surplus and discharge chronologically at shortfall hours.
    sys    = make_test_system(168)
    cfg_m1c = SimConfig(n_scenarios=10, seed=99)
    cfg_m1d = SimConfig(n_scenarios=10, seed=99,
                        risk_allocation_mode="earliest_first",
                        event_charge_lookback_hours=168,
                        risk_event_gap_hours=0)

    avail = generate_scenarios(sys, cfg_m1c)

    res_m1c = run_m1c_emergency_only(sys, avail, cfg_m1c)
    res_m1d = run_m1d_risk_hour_allocation(sys, avail, cfg_m1d)

    for (r_c, r_d) in zip(res_m1c, res_m1d)
        @test sum(r_c.load_shed) ≈ sum(r_d.load_shed) atol=1e-3
    end
end

@testset "Storage dynamics — M1d (SOC consistency)" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=30, seed=55,
                       risk_allocation_mode="earliest_first",
                       event_charge_lookback_hours=72)
    avail  = generate_scenarios(sys, config)
    results = run_m1d_risk_hour_allocation(sys, avail, config)

    stor         = sys.storage
    total_energy = sum(stor.energy_mwh)
    eta_ch       = mean(stor.charge_efficiency)
    eta_dis      = mean(stor.discharge_efficiency)
    init_soc     = sum(stor.initial_soc_mwh)

    for r in results
        n = length(r.load_shed)

        # SOC bounds
        @test all(r.soc .>= -1e-9)
        @test all(r.soc .<= total_energy + 1e-9)

        # Non-negative outputs
        @test all(r.load_shed         .>= -1e-9)
        @test all(r.storage_discharge .>= -1e-9)
        @test all(r.storage_charge    .>= -1e-9)
        @test all(r.curtailment       .>= -1e-9)

        # No simultaneous charge and discharge
        for h in 1:n
            @test !(r.storage_charge[h] > 1e-9 && r.storage_discharge[h] > 1e-9)
        end
    end
end
