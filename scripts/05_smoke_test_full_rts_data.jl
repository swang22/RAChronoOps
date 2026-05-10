#!/usr/bin/env julia
# 05_smoke_test_full_rts_data.jl
#
# Quick sanity check for the full 8760-hour RTS single-zone dataset.
# Loads processed data, asserts it has 8760 hours, generates 3 outage
# scenarios, runs M1, and prints LOLH / EUE / nEUE.
#
# Usage:
#   julia --project=. scripts/05_smoke_test_full_rts_data.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using Printf

let
    data_dir = joinpath(@__DIR__, "..", "data_processed", "rts_single_zone")

    @info "Loading system data from $data_dir"
    sys = load_system_data(data_dir)

    # ── assert 8760-hour dataset ──────────────────────────────────────────
    sys.n_hours == 8760 ||
        error("Smoke test FAILED: expected 8760 hours, got $(sys.n_hours). " *
              "Run scripts/01_build_single_zone_rts.jl first.")
    @info "n_hours = 8760 ✓"

    # ── generate 3 outage scenarios ───────────────────────────────────────
    cfg = load_config(joinpath(@__DIR__, "..", "configs", "base_case.yaml"))
    # Rebuild config with n_scenarios=3 for a fast smoke run; all other
    # parameters (seed, VOLL, storage, …) stay identical to base_case.yaml.
    cfg3 = SimConfig(3, cfg.seed, cfg.voll,
                     cfg.high_net_load_quantile, cfg.charge_net_load_quantile,
                     cfg.lookahead_hours, cfg.epsilon_cycling, cfg.cyclic_soc,
                     cfg.storage_cycling_cost, cfg.cvar_alpha,
                     cfg.save_dispatch, cfg.output_dir)
    @info "Generating 3 outage scenarios (seed = $(cfg3.seed))..."
    scenarios = generate_scenarios(sys, cfg3)
    @info "Scenario array: $(size(scenarios.availability))"

    # ── run M1 ────────────────────────────────────────────────────────────
    @info "Running M1 (rule-based storage)..."
    m1_cfg  = load_config(joinpath(@__DIR__, "..", "configs", "m1.yaml"))
    results = run_m1_rule_based(sys, scenarios.availability, m1_cfg)

    metrics = compute_metrics(results, sys, cfg3)

    println()
    println("=" ^ 50)
    println("Smoke test — M1 reliability metrics (3 scenarios)")
    println("=" ^ 50)
    @printf "  LOLH  : %8.2f  h/yr\n"  metrics.lolh
    @printf "  EUE   : %8.2f  MWh/yr\n" metrics.eue
    @printf "  nEUE  : %8.4f  %%\n"    metrics.neue * 100
    println("=" ^ 50)
    println()
    @info "Smoke test PASSED"
end
