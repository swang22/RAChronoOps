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

@testset "Storage dynamics — M1c" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=50, seed=13)
    avail  = generate_scenarios(sys, config)
    results = run_m1c_emergency_only(sys, avail, config)

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

        # SOC dynamics: consistent from initial state
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

@testset "M1c no discharge without pre-storage shortfall" begin
    # Abundant thermal (200 MW), no outages (FOR=0), flat load 55 MW.
    # Pre-storage shortfall is always zero → M1c must never discharge.
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
                        fill(55.0, 48), fill(0.0, 48), fill(0.0, 48), 48)

    cfg    = SimConfig(n_scenarios=5, seed=42)
    avail  = generate_scenarios(sys_nf, cfg)
    results = run_m1c_emergency_only(sys_nf, avail, cfg)

    for r in results
        # No shortfall possible → no emergency discharge
        @test all(r.storage_discharge .< 1e-9)
        @test all(r.load_shed         .< 1e-9)
    end
end

@testset "M1c discharges during pre-storage shortfall" begin
    # All thermal permanently offline (FOR=1.0 approximated via zero pmax), no VRE.
    # Load 55 MW, storage 25 MW / 100 MWh at 50 MWh SOC.
    # Every hour has shortfall_pre = 55 MW → M1c must discharge.
    gen_df = DataFrame(
        gen_id                 = ["TH1"],
        gen_type               = ["CT"],
        fuel                   = ["Gas"],
        pmax_mw                = [0.0],   # effectively offline
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
    sys_zero = SystemData(gen_df, stor_df,
                          fill(55.0, 48), fill(0.0, 48), fill(0.0, 48), 48)

    cfg    = SimConfig(n_scenarios=1, seed=42)
    avail  = generate_scenarios(sys_zero, cfg)
    r      = run_m1c_emergency_only(sys_zero, avail, cfg)[1]

    # Initial SOC = 50 MWh, power = 25 MW.  First two hours should discharge 25 MW each.
    @test r.storage_discharge[1] ≈ 25.0 atol=1e-6
    @test r.storage_discharge[2] ≈ 25.0 atol=1e-6
    # After SOC depletes, remaining hours are full load-shed
    @test r.load_shed[3] ≈ 55.0 atol=1e-6
    # No charging during shortfall hours
    @test all(r.storage_charge .< 1e-9)
end

@testset "M1c no-storage reduces to thermal+VRE adequacy" begin
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
        DataFrame(  # empty storage
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
    cfg    = SimConfig(n_scenarios=10, seed=42)
    avail  = generate_scenarios(sys_no_stor, cfg)
    results = run_m1c_emergency_only(sys_no_stor, avail, cfg)

    for r in results
        @test all(r.storage_discharge .< 1e-9)
        @test all(r.storage_charge    .< 1e-9)
        # load_shed[h] = max(0, load - thermal_avail - vre)
        @test all(r.load_shed .>= -1e-9)
    end
end

@testset "M1c charging only when surplus" begin
    # 200 MW thermal, no outages, 55 MW load → surplus = 145 MW every hour.
    # Storage 25 MW / 100 MWh, init SOC = 0 MWh.
    # M1c should charge at full power every hour until full.
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
        initial_soc_mwh       = [0.0],
    )
    sys_sur = SystemData(gen_df, stor_df,
                         fill(55.0, 48), fill(0.0, 48), fill(0.0, 48), 48)

    cfg    = SimConfig(n_scenarios=1, seed=42)
    avail  = generate_scenarios(sys_sur, cfg)
    r      = run_m1c_emergency_only(sys_sur, avail, cfg)[1]

    # First 4 hours: charge at 25 MW/h until SOC = 100 MWh
    @test r.storage_charge[1] ≈ 25.0 atol=1e-6
    @test r.storage_charge[2] ≈ 25.0 atol=1e-6
    @test r.storage_charge[3] ≈ 25.0 atol=1e-6
    @test r.storage_charge[4] ≈ 25.0 atol=1e-6
    # Once full, no further charging
    @test r.storage_charge[5] < 1e-9
    # No discharge (no shortfall)
    @test all(r.storage_discharge .< 1e-9)
end

@testset "Storage dynamics — M1c_VREOnlyCharge" begin
    sys    = make_test_system(168)
    config = SimConfig(n_scenarios=50, seed=17)
    avail  = generate_scenarios(sys, config)
    results = run_m1c_vre_only_charge(sys, avail, config)

    stor         = sys.storage
    total_energy = sum(stor.energy_mwh)
    eta_ch       = mean(stor.charge_efficiency)
    eta_dis      = mean(stor.discharge_efficiency)
    init_soc     = sum(stor.initial_soc_mwh)

    for r in results
        n = length(r.load_shed)

        @test all(r.soc .>= -1e-9)
        @test all(r.soc .<= total_energy + 1e-9)
        @test all(r.load_shed         .>= -1e-9)
        @test all(r.storage_discharge .>= -1e-9)
        @test all(r.storage_charge    .>= -1e-9)
        @test all(r.curtailment       .>= -1e-9)

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

        for h in 1:n
            @test !(r.storage_charge[h] > 1e-9 && r.storage_discharge[h] > 1e-9)
        end
    end
end

@testset "M1c_VREOnlyCharge never discharges without shortfall" begin
    # Abundant thermal, no outages → shortfall_pre = 0 always → no discharge.
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
                        fill(55.0, 48), fill(0.0, 48), fill(0.0, 48), 48)

    cfg    = SimConfig(n_scenarios=5, seed=42)
    avail  = generate_scenarios(sys_nf, cfg)
    results = run_m1c_vre_only_charge(sys_nf, avail, cfg)

    for r in results
        @test all(r.storage_discharge .< 1e-9)
        @test all(r.load_shed         .< 1e-9)
    end
end

@testset "M1c_VREOnlyCharge discharges when shortfall exists" begin
    # Zero thermal, no VRE → shortfall = load every hour → discharge.
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
        power_mw              = [25.0],
        energy_mwh            = [100.0],
        charge_efficiency     = [1.0],
        discharge_efficiency  = [1.0],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [50.0],
    )
    sys_zero = SystemData(gen_df, stor_df,
                          fill(55.0, 48), fill(0.0, 48), fill(0.0, 48), 48)

    cfg = SimConfig(n_scenarios=1, seed=42)
    r   = run_m1c_vre_only_charge(sys_zero, generate_scenarios(sys_zero, cfg), cfg)[1]

    @test r.storage_discharge[1] ≈ 25.0 atol=1e-6
    @test r.storage_discharge[2] ≈ 25.0 atol=1e-6
    @test r.load_shed[3]         ≈ 55.0 atol=1e-6
    @test all(r.storage_charge   .< 1e-9)
end

@testset "M1c_VREOnlyCharge never charges when p_vre <= load" begin
    # Thermal always covers load exactly; VRE capacity = 0 → p_vre = 0 always.
    # No VRE surplus → no charging allowed.
    gen_df = DataFrame(
        gen_id                 = ["TH1"],
        gen_type               = ["CT"],
        fuel                   = ["Gas"],
        pmax_mw                = [55.0],
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
        initial_soc_mwh       = [0.0],
    )
    # load = 55, thermal_pmax = 55, no VRE → vre_surplus = 0 every hour
    sys_novresur = SystemData(gen_df, stor_df,
                              fill(55.0, 48), fill(0.0, 48), fill(0.0, 48), 48)

    cfg = SimConfig(n_scenarios=3, seed=42)
    for r in run_m1c_vre_only_charge(sys_novresur, generate_scenarios(sys_novresur, cfg), cfg)
        @test all(r.storage_charge .< 1e-9)
    end
end

@testset "M1c_VREOnlyCharge charges when p_vre > load" begin
    # No thermal, VRE 100 MW, load 55 MW → vre_surplus = 45 MW every hour.
    # Battery 25 MW / 100 MWh, init SOC = 0.
    # Expected: charges at 25 MW/h until full (4 hours).
    gen_df = DataFrame(
        gen_id                 = ["W1"],
        gen_type               = ["Wind"],
        fuel                   = ["Wind"],
        pmax_mw                = [100.0],
        pmin_mw                = [0.0],
        variable_cost_per_mwh  = [0.0],
        forced_outage_rate     = [0.0],
        mean_repair_time_hours = [0.0],
        is_thermal             = [0],
        is_vre                 = [1],
        vre_type               = ["wind"],
    )
    stor_df = DataFrame(
        storage_id            = ["BAT1"],
        power_mw              = [25.0],
        energy_mwh            = [100.0],
        charge_efficiency     = [1.0],
        discharge_efficiency  = [1.0],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [0.0],
    )
    # wind_cf = 1.0 everywhere → p_vre = 100 MW > load = 55 MW → surplus = 45 MW
    sys_vre = SystemData(gen_df, stor_df,
                         fill(55.0, 48), fill(1.0, 48), fill(0.0, 48), 48)

    cfg = SimConfig(n_scenarios=1, seed=42)
    r   = run_m1c_vre_only_charge(sys_vre, generate_scenarios(sys_vre, cfg), cfg)[1]

    @test r.storage_charge[1] ≈ 25.0 atol=1e-6
    @test r.storage_charge[2] ≈ 25.0 atol=1e-6
    @test r.storage_charge[3] ≈ 25.0 atol=1e-6
    @test r.storage_charge[4] ≈ 25.0 atol=1e-6
    @test r.storage_charge[5] < 1e-9   # full
    @test all(r.storage_discharge .< 1e-9)
    @test all(r.load_shed         .< 1e-9)
end

@testset "M1c_VREOnlyCharge no-storage reduces to thermal+VRE adequacy" begin
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
    cfg     = SimConfig(n_scenarios=10, seed=42)
    avail   = generate_scenarios(sys_no_stor, cfg)
    results = run_m1c_vre_only_charge(sys_no_stor, avail, cfg)

    for r in results
        @test all(r.storage_discharge .< 1e-9)
        @test all(r.storage_charge    .< 1e-9)
        @test all(r.load_shed         .>= -1e-9)
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
