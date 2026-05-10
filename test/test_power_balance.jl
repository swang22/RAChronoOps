@testset "Power balance — M3" begin
    sys    = make_test_system(168)    # short horizon for speed
    config = SimConfig(n_scenarios=5, seed=33, cyclic_soc=true)
    scen   = generate_scenarios(sys, config)
    avail  = scen.availability   # Array{Int8,3}: n_scen × n_therm × n_hours
    results = run_m3_ed_dispatch(sys, avail, config)

    therm  = thermal_generators(sys)
    stor   = sys.storage
    n_therm = nrow(therm)
    n_stor  = nrow(stor)
    wind_cap  = wind_capacity_mw(sys)
    solar_cap = solar_capacity_mw(sys)
    eta_ch  = Float64.(stor.charge_efficiency)
    eta_dis = Float64.(stor.discharge_efficiency)
    soc0    = Float64.(stor.initial_soc_mwh)
    eng_mwh = Float64.(stor.energy_mwh)
    pow_mw  = Float64.(stor.power_mw)

    for (s, r) in enumerate(results)
        n = length(r.load_shed)
        A = Int8.(view(avail, s, :, :))   # n_therm × n_hours

        for h in 1:n
            vre_h  = wind_cap * sys.wind_cf[h] + solar_cap * sys.solar_cf[h]
            load_h = sys.load_mw[h]

            # thermal dispatch: sum over all generators
            gen_sum = n_therm > 0 && !isnothing(r.thermal_dispatch) ?
                      sum(r.thermal_dispatch[g, h] for g in 1:n_therm) : 0.0

            # storage net: only the single aggregate SOC is stored,
            # but we recorded aggregate dis/chg
            stor_net = r.storage_discharge[h] - r.storage_charge[h]

            balance = gen_sum + vre_h + stor_net + r.load_shed[h] - r.curtailment[h]
            @test balance ≈ load_h  atol=1e-4    # LP solver tolerance

            # non-negative variables
            @test r.load_shed[h]   >= -1e-9
            @test r.curtailment[h] >= -1e-9

            # generator bounds
            if !isnothing(r.thermal_dispatch)
                for g in 1:n_therm
                    @test r.thermal_dispatch[g, h] >= -1e-6
                    @test r.thermal_dispatch[g, h] <=
                          A[g, h] * therm.pmax_mw[g] + 1e-4
                end
            end
        end

        # ── SOC bounds ───────────────────────────────────────────────────
        total_energy = sum(eng_mwh)
        @test all(r.soc .>= -1e-6)
        @test all(r.soc .<= total_energy + 1e-4)

        # ── cyclic SOC: end SOC ≈ initial SOC ────────────────────────────
        if config.cyclic_soc
            @test r.soc[end] ≈ soc0[1]  atol=1e-3
        end
    end
end

@testset "M3 EUE ≤ M2 EUE (full-year LP ≥ rolling-window, same seed)" begin
    # Use a short horizon and a large lookahead in M2 so that M2 ≈ full-year.
    # With identical outage scenarios and M2 lookahead = horizon, M3 should
    # achieve EUE ≤ M2 EUE (M3 has global optimality, M2 is MPC sub-optimal).
    sys    = make_test_system(72)     # 3-day horizon
    seed   = 55
    n_scen = 10
    avail  = generate_scenarios(sys, n_scen, seed)

    cfg2 = SimConfig(n_scenarios=n_scen, seed=seed,
                     lookahead_hours=72,   # full horizon — best possible MPC
                     voll=10_000.0)
    cfg3 = SimConfig(n_scenarios=n_scen, seed=seed,
                     cyclic_soc=false,     # no cyclic constraint for fair comparison
                     voll=10_000.0)

    m2 = compute_metrics(run_m2_rolling_window(sys, avail, cfg2), sys)
    m3 = compute_metrics(run_m3_ed_dispatch(sys,   avail, cfg3), sys)

    # M3 (global optimum) must not exceed M2 EUE by more than numerical tol
    @test m3.eue <= m2.eue + 1e-3

    # Both models: load shedding non-negative
    for res in [run_m2_rolling_window(sys, avail, cfg2),
                run_m3_ed_dispatch(sys,   avail, cfg3)]
        for r in res
            @test all(r.load_shed .>= -1e-9)
        end
    end
end
