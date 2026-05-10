#!/usr/bin/env julia
# 02_generate_scenarios.jl
#
# Generates and inspects Monte Carlo outage scenarios.
# Not required before running models — each model generates scenarios
# internally — but useful for standalone analysis and debugging.
#
# Usage:
#   julia --project scripts/02_generate_scenarios.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using Statistics
using CSV, DataFrames

const PROJECT_ROOT = joinpath(@__DIR__, "..")
const DATA_DIR     = joinpath(PROJECT_ROOT, "data_processed", "rts_single_zone")
const OUT_DIR      = joinpath(PROJECT_ROOT, "results", "scenarios")

sys    = load_system_data(DATA_DIR)
config = SimConfig(n_scenarios=200, seed=42)

@info "Generating $(config.n_scenarios) scenarios for $(nrow(thermal_generators(sys))) thermal units..."
avail  = generate_scenarios(sys, config)

therm  = thermal_generators(sys)
n_therm, n_hours, n_scen = nrow(therm), sys.n_hours, config.n_scenarios

@info "Availability array size: $(size(avail))"

# ── per-generator diagnostics ─────────────────────────────────────────────
rows = []
for (g, row) in enumerate(eachrow(therm))
    mean_avail  = mean(avail[:, g, :])
    target_avail = 1.0 - row.forced_outage_rate
    push!(rows, (
        gen_id         = row.gen_id,
        FOR_input      = row.forced_outage_rate,
        target_avail   = round(target_avail,  digits=4),
        simulated_avail = round(mean_avail,   digits=4),
        abs_error      = round(abs(mean_avail - target_avail), digits=4),
    ))
end
diag_df = DataFrame(rows)
println("\nGenerator availability diagnostics:")
println(diag_df)

# ── save per-scenario annual unavailability ────────────────────────────────
mkpath(OUT_DIR)
scen_unavail = [mean(1 .- avail[s, :, :]) for s in 1:n_scen]
CSV.write(joinpath(OUT_DIR, "scenario_unavailability.csv"),
          DataFrame(scenario=1:n_scen, mean_unavailability=scen_unavail))
@info "Saved scenario diagnostics to $OUT_DIR"
