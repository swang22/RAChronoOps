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
