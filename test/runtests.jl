using Test
using RAChronoOps
using DataFrames
using Statistics

# ── Build synthetic test data (does not require external RTS files) ────────
const PROJECT_ROOT  = joinpath(@__DIR__, "..")
const TEST_DATA_DIR = joinpath(PROJECT_ROOT, "data_processed", "rts_single_zone")
const RTS_RAW_DIR   = joinpath(PROJECT_ROOT, "data_raw", "RTS-GMLC")

if !isfile(joinpath(TEST_DATA_DIR, "generators.csv"))
    @info "Test data not found — building synthetic fallback..."
    build_rts_single_zone(RTS_RAW_DIR, TEST_DATA_DIR)
end

# ── tiny helper: 168-hour (1-week) system for fast unit tests ─────────────
"""
    make_test_system() -> SystemData

Creates a minimal in-memory system without touching disk.
  - 2 thermal generators (50 MW each, FOR=0.10, MTTR=10h)
  - 1 wind (40 MW), 1 solar (30 MW)
  - 1 battery (25 MW / 100 MWh, η=0.90, SOC₀=50 MWh)
  - 168-hour horizon
  - Load: flat 55 MW (intentionally below total thermal so shortfalls are rare
    but possible when both units trip simultaneously)
"""
function make_test_system(n_hours::Int = 168)::SystemData
    gen_df = DataFrame(
        gen_id                  = ["TH1", "TH2", "W1", "PV1"],
        gen_type                = ["CT", "CT", "Wind", "PV"],
        fuel                    = ["Gas", "Gas", "Wind", "Solar"],
        pmax_mw                 = [50.0, 50.0, 40.0, 30.0],
        pmin_mw                 = [ 5.0,  5.0,  0.0,  0.0],
        variable_cost_per_mwh   = [50.0, 50.0,  0.0,  0.0],
        forced_outage_rate      = [0.10, 0.10, 0.0, 0.0],
        mean_repair_time_hours  = [10.0, 10.0, 0.0, 0.0],
        is_thermal              = [1, 1, 0, 0],
        is_vre                  = [0, 0, 1, 1],
        vre_type                = ["", "", "wind", "solar"],
    )

    stor_df = DataFrame(
        storage_id            = ["BAT1"],
        power_mw              = [25.0],
        energy_mwh            = [100.0],
        charge_efficiency     = [0.90],
        discharge_efficiency  = [0.90],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [50.0],
    )

    load_mw  = fill(55.0, n_hours)
    wind_cf  = fill(0.30, n_hours)
    solar_cf = [( (h - 1) % 24 in 6:18) ? 0.30 : 0.0 for h in 1:n_hours]

    return SystemData(gen_df, stor_df, load_mw, wind_cf, solar_cf, n_hours)
end

# ── run all test suites ───────────────────────────────────────────────────
@testset "RAChronoOps" begin
    include("test_outages.jl")
    include("test_storage.jl")
    include("test_power_balance.jl")
end
