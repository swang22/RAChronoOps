#!/usr/bin/env julia
# 06_smoke_test_m3_full_year.jl
#
# Full-year smoke test for M3 on the 8760-hour RTS single-zone dataset.
# Loads processed data, asserts 8760 hours, generates exactly 1 outage
# scenario (base_case.yaml seed), runs M3, and prints reliability metrics.
# Exits with a clear message if M3 fails.
#
# Usage:
#   julia --project=. scripts/06_smoke_test_m3_full_year.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using Printf

let
    data_dir = joinpath(@__DIR__, "..", "data_processed", "rts_single_zone")
    conf_dir = joinpath(@__DIR__, "..", "configs")

    @info "Loading system data from $data_dir"
    sys = load_system_data(data_dir)

    # ── assert 8760-hour dataset ──────────────────────────────────────────────
    sys.n_hours == 8760 ||
        error("Smoke test FAILED: expected 8760 hours, got $(sys.n_hours). " *
              "Run scripts/01_build_single_zone_rts.jl first.")
    @info "n_hours = 8760 ✓"

    # ── generate exactly 1 scenario using base_case.yaml seed ────────────────
    base_cfg = load_config(joinpath(conf_dir, "base_case.yaml"))
    cfg1 = SimConfig(; n_scenarios=1, seed=base_cfg.seed,
                       voll=base_cfg.voll,
                       high_net_load_quantile=base_cfg.high_net_load_quantile,
                       charge_net_load_quantile=base_cfg.charge_net_load_quantile,
                       lookahead_hours=base_cfg.lookahead_hours,
                       epsilon_cycling=base_cfg.epsilon_cycling,
                       cyclic_soc=base_cfg.cyclic_soc,
                       storage_cycling_cost=base_cfg.storage_cycling_cost,
                       cvar_alpha=base_cfg.cvar_alpha,
                       save_dispatch=false,
                       output_dir="results")
    @info "Generating 1 outage scenario (seed = $(cfg1.seed))..."
    scenarios = generate_scenarios(sys, cfg1)
    @info "Scenario array: $(size(scenarios.availability))"

    # ── load M3 config ────────────────────────────────────────────────────────
    m3_cfg_path = joinpath(conf_dir, "m3.yaml")
    m3_cfg = isfile(m3_cfg_path) ? load_config(m3_cfg_path) : SimConfig()

    # ── run M3 ────────────────────────────────────────────────────────────────
    @info "Running M3 (full-year economic dispatch LP, 1 scenario)..."
    t0 = time()
    results = try
        run_m3_ed_dispatch(sys, scenarios, m3_cfg)
    catch e
        println("\nM3 FAILED: $(sprint(showerror, e))")
        exit(1)
    end
    runtime = time() - t0

    metrics = compute_metrics(results, sys, cfg1)

    println()
    println("=" ^ 60)
    println("M3 Full-Year Smoke Test — RTS single-zone (1 scenario)")
    println("=" ^ 60)
    @printf "  LOLH       : %10.4f  h/yr\n"   metrics.lolh
    @printf "  EUE        : %10.2f  MWh/yr\n" metrics.eue
    @printf "  nEUE       : %10.6f  %%\n"     metrics.neue * 100
    @printf "  CVaR-EUE   : %10.2f  MWh\n"   metrics.cvar_eue
    @printf "  Runtime    : %10.1f  s\n"       runtime
    println("=" ^ 60)
    println()
    @info "M3 smoke test PASSED"
end
