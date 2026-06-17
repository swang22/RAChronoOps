using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using RAChronoOps, Statistics, Printf

REPO = joinpath(@__DIR__, "..")
CASE = "VRE120_base"

cfg = SimConfig(n_scenarios=5, seed=42,
                risk_margin_mw=1000.0,
                window_buffer_hours=48,
                merge_gap_hours=24,
                min_window_length_hours=24)

println("Loading case: $CASE")
sys = load_system_data(joinpath(REPO, "data_processed", "cases", CASE))

println("Generating 5 scenarios...")
scen = generate_scenarios(sys, cfg)

println("\nRunning M2 diagnostic (5 scenarios, risk=1000MW, buf=48, gap=24, min=24)...")
t0 = time()
_, diags = run_m2_with_diagnostics(sys, scen.availability, cfg)
elapsed = time() - t0

println("\n=== Per-Scenario Window Diagnostics ===")
println("Scen  RiskHrs  NWin  TotalWinH  MeanWinLen  MaxWinLen  LPfail  Time(s)")
for d in diags
    r = scen  # just for context
    # get timing from results - not directly available from diag, estimate
end

println("\nTotal elapsed: $(round(elapsed, digits=2)) s for 5 scenarios")
println("Per-scenario: $(round(elapsed/5, digits=3)) s")

println("\n=== Window Summary ===")
for d in diags
    @printf("Scen %d: %d risk hours → %d windows, total %d h, mean %.1f h, max %d h\n",
            d.scenario_id, d.n_risk_hours, d.n_windows,
            d.total_window_h, d.mean_window_len, d.max_window_len)
end

println("\n=== Risk Hour Fraction ===")
T = sys.n_hours
mean_risk_hrs = mean(d.n_risk_hours for d in diags)
@printf("Mean risk hours per scenario: %.0f / %d = %.1f%%\n",
        mean_risk_hrs, T, 100*mean_risk_hrs/T)
mean_win_h = mean(d.total_window_h for d in diags)
@printf("Mean total window hours: %.0f / %d = %.1f%%\n",
        mean_win_h, T, 100*mean_win_h/T)
