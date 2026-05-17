@testset "Reliability metrics — expanded suite" begin

    # ── helper: build a DispatchResult with known load_shed ───────────────
    # DispatchResult positional: (scenario_id, load_shed, storage_discharge,
    #   storage_charge, soc, thermal_dispatch, curtailment, runtime_seconds)
    function make_result(load_shed::Vector{Float64}; n_hours=length(load_shed))
        DispatchResult(1, load_shed, zeros(n_hours), zeros(n_hours),
                       zeros(n_hours), nothing, zeros(n_hours), 0.0)
    end

    n_hours  = 8760
    load_mw  = fill(100.0, n_hours)

    @testset "No-shortage case" begin
        results = [make_result(zeros(n_hours)) for _ in 1:10]
        m = compute_metrics(results, load_mw)

        @test m.lolh                         == 0.0
        @test m.lolp                         == 0.0
        @test m.lole_days                    == 0.0
        @test m.eue                          == 0.0
        @test m.neue                         == 0.0
        @test m.n_shortage_events            == 0.0
        @test m.mean_shortage_duration       == 0.0
        @test m.max_shortage_duration        == 0.0
        @test m.p95_shortage_duration        == 0.0
        @test m.max_shortfall                == 0.0
        @test m.mean_shortfall_when_shedding == 0.0
        @test m.p50_scenario_eue             == 0.0
        @test m.p90_scenario_eue             == 0.0
        @test m.p95_scenario_eue             == 0.0
        @test m.p99_scenario_eue             == 0.0
        @test m.cvar_eue                     == 0.0
        # CI half-widths: all scenarios identical → std = 0
        @test m.lolh_ci95_halfwidth          == 0.0
        @test m.eue_ci95_halfwidth           == 0.0
        # relative CI: mean == 0 → NaN
        @test isnan(m.lolh_ci95_rel_halfwidth)
        @test isnan(m.eue_ci95_rel_halfwidth)
    end

    @testset "LOLP = LOLH / n_hours" begin
        # 876 shortage hours spread deterministically across 10 identical scenarios
        shed = zeros(n_hours)
        shed[1:876] .= 10.0
        results = [make_result(copy(shed)) for _ in 1:10]
        m = compute_metrics(results, load_mw)

        @test m.lolh ≈ 876.0
        @test m.lolp ≈ 876.0 / 8760.0  atol=1e-12
        # also test the standalone helper
        @test compute_lolp(876.0, 8760) ≈ 876.0 / 8760.0  atol=1e-12
    end

    @testset "LOLE_days counts days with ≥1 shortage hour" begin
        # One shortage hour per day for 3 days, nothing else
        shed = zeros(n_hours)
        shed[1]  = 5.0   # day 1, hour 1
        shed[25] = 5.0   # day 2, hour 1
        shed[49] = 5.0   # day 3, hour 1
        results = [make_result(copy(shed)) for _ in 1:5]
        m = compute_metrics(results, load_mw)

        @test m.lole_days ≈ 3.0
        # standalone helper
        @test compute_lole_days(shed) ≈ 3.0
    end

    @testset "LOLE_days — multiple shortage hours in same day count as 1" begin
        shed = zeros(n_hours)
        shed[1:5] .= 2.0   # 5 hours all in day 1
        results = [make_result(copy(shed)) for _ in 1:4]
        m = compute_metrics(results, load_mw)
        @test m.lole_days ≈ 1.0
    end

    @testset "EUE and nEUE unchanged" begin
        shed = zeros(n_hours)
        shed[100:109] .= 20.0   # 10 h × 20 MW = 200 MWh
        results = [make_result(copy(shed)) for _ in 1:8]
        m = compute_metrics(results, load_mw)

        @test m.eue  ≈ 200.0
        @test m.neue ≈ 200.0 / (100.0 * 8760)  atol=1e-12
    end

    @testset "CI95 = 0 for identical scenario values" begin
        shed = zeros(n_hours)
        shed[1:10] .= 5.0
        results = [make_result(copy(shed)) for _ in 1:20]
        m = compute_metrics(results, load_mw)

        @test m.lolh_ci95_halfwidth == 0.0
        @test m.eue_ci95_halfwidth  == 0.0
        # standalone helper
        @test compute_ci95(fill(42.0, 20)) == 0.0
        @test compute_ci95([1.0])          == 0.0   # n=1 returns 0
    end

    @testset "CI95 shrinks with more scenarios" begin
        rng = MersenneTwister(1)
        scen_vals = randn(rng, 100) .* 10.0 .+ 50.0
        ci_100 = compute_ci95(scen_vals[1:100])
        ci_25  = compute_ci95(scen_vals[1:25])
        @test ci_25 > ci_100   # wider CI with fewer scenarios
    end

    @testset "Event-duration metrics" begin
        # Three distinct events: 2 h, 5 h, 3 h, separated by zeros
        shed = zeros(n_hours)
        shed[10:11]  .= 1.0   # 2-hour event
        shed[50:54]  .= 1.0   # 5-hour event
        shed[200:202].= 1.0   # 3-hour event
        results = [make_result(copy(shed)) for _ in 1:6]
        m = compute_metrics(results, load_mw)

        @test m.n_shortage_events  ≈ 3.0
        @test m.mean_shortage_duration ≈ (2.0 + 5.0 + 3.0) / 3.0  atol=1e-10
        @test m.max_shortage_duration  ≈ 5.0
        # all_durations has 6 scen × 3 events = 18 values: [2,5,3] repeated 6×
        @test m.p95_shortage_duration  ≈ quantile(repeat([2.0, 5.0, 3.0], 6), 0.95) atol=1e-10
    end

    @testset "mean_shortfall_when_shedding" begin
        shed = zeros(n_hours)
        shed[1] = 10.0
        shed[2] = 20.0
        shed[3] = 30.0
        results = [make_result(copy(shed)) for _ in 1:4]
        m = compute_metrics(results, load_mw)
        @test m.mean_shortfall_when_shedding ≈ 20.0   atol=1e-9
        # standalone helper
        @test compute_shortfall_severity(shed) ≈ 20.0  atol=1e-9
        @test compute_shortfall_severity(zeros(10)) == 0.0
    end

    @testset "Scenario EUE quantiles" begin
        # 10 scenarios with EUE = 0,10,20,...,90
        results = [make_result(fill(Float64(i * 10) / n_hours, n_hours)) for i in 0:9]
        m = compute_metrics(results, load_mw)
        scen_eue = [Float64(i * 10) for i in 0:9]   # 0,10,20,...,90

        @test m.p50_scenario_eue ≈ quantile(scen_eue, 0.50)  atol=1e-9
        @test m.p90_scenario_eue ≈ quantile(scen_eue, 0.90)  atol=1e-9
        @test m.p95_scenario_eue ≈ quantile(scen_eue, 0.95)  atol=1e-9
        @test m.p99_scenario_eue ≈ quantile(scen_eue, 0.99)  atol=1e-9
    end

    @testset "compute_quantile wrapper" begin
        vals = [1.0, 2.0, 3.0, 4.0, 5.0]
        @test compute_quantile(vals, 0.5) ≈ 3.0
    end

    @testset "LOLH / EUE consistency with existing public helpers" begin
        shed = zeros(168)
        shed[10:15] .= 5.0   # 6 hours, 30 MWh total
        @test compute_lolh(shed) ≈ 6.0
        @test compute_eue(shed)  ≈ 30.0
        @test compute_neue(shed, fill(50.0, 168)) ≈ 30.0 / (50.0 * 168)  atol=1e-12
    end

    @testset "Synthetic system — integration check" begin
        sys    = make_test_system(168)
        cfg    = SimConfig(n_scenarios=10, seed=99)
        scen   = generate_scenarios(sys, cfg)
        r_m1   = run_m1_rule_based(sys, scen, cfg)
        m      = compute_metrics(r_m1, sys, cfg)

        # Structural invariants
        @test m.lolp ≈ m.lolh / 168.0                  atol=1e-12
        @test m.eue  >= 0.0
        @test m.lolh >= 0.0
        @test m.lolh_ci95_halfwidth >= 0.0
        @test m.eue_ci95_halfwidth  >= 0.0
        @test m.p90_scenario_eue >= m.p50_scenario_eue - 1e-9
        @test m.p95_scenario_eue >= m.p90_scenario_eue - 1e-9
        @test m.p99_scenario_eue >= m.p95_scenario_eue - 1e-9
        @test length(m.scenario_eue) == 10

        # LOLE days ≤ n_days
        @test m.lole_days <= div(168, 24)

        if m.lolh > 0.0
            @test !isnan(m.lolh_ci95_rel_halfwidth)
            @test m.mean_shortfall_when_shedding > 0.0
        end
    end
end
