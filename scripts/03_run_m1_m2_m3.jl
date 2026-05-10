#!/usr/bin/env julia
# 03_run_m1_m2_m3.jl
#
# Runs all three RA models on the processed single-zone RTS system and
# prints a comparison table of reliability metrics.
#
# Usage:
#   julia --project scripts/03_run_m1_m2_m3.jl [--config base_case]
#
# The optional --config flag selects a YAML under configs/.
# Default: uses per-model YAML files (configs/m1.yaml, etc.).

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using Printf

const PROJECT_ROOT = joinpath(@__DIR__, "..")
const DATA_DIR     = joinpath(PROJECT_ROOT, "data_processed", "rts_single_zone")
const CONF_DIR     = joinpath(PROJECT_ROOT, "configs")

# ── parse optional CLI arg ────────────────────────────────────────────────
function get_config(name::String)::SimConfig
    p = joinpath(CONF_DIR, "$name.yaml")
    isfile(p) ? load_config(p) : SimConfig()
end

@info "Loading system data from $DATA_DIR..."
sys = load_system_data(DATA_DIR)
@info "System: $(nrow(thermal_generators(sys))) thermal, " *
      "$(nrow(vre_generators(sys))) VRE, " *
      "$(nrow(sys.storage)) storage, $(sys.n_hours) hours"

# ── M1 ────────────────────────────────────────────────────────────────────
@info "\n=== M1: Rule-Based Storage ==="
cfg1 = get_config("m1")
res1 = run_experiment(run_m1_rule_based, sys, cfg1; model_name="M1")

# ── M2 ────────────────────────────────────────────────────────────────────
@info "\n=== M2: Rolling-Window LP (lookahead=$(get_config("m2").lookahead_hours)h) ==="
cfg2 = get_config("m2")
res2 = run_experiment(run_m2_rolling_window, sys, cfg2; model_name="M2")

# ── M3 ────────────────────────────────────────────────────────────────────
@info "\n=== M3: Full-Year Economic Dispatch LP ==="
cfg3 = get_config("m3")
res3 = run_experiment(run_m3_ed_dispatch, sys, cfg3; model_name="M3")

# ── comparison table ──────────────────────────────────────────────────────
println("\n" * "="^72)
println("Reliability Metrics Comparison")
println("="^72)
@printf "%-8s %10s %12s %12s %12s %10s\n" \
    "Model" "LOLH (h)" "EUE (MWh)" "nEUE (ppm)" "CVaR-EUE" "Runtime(s)"
println("-"^72)
for (tag, res) in [("M1", res1), ("M2", res2), ("M3", res3)]
    m = res.metrics
    @printf "%-8s %10.2f %12.1f %12.4f %12.1f %10.1f\n" \
        tag m.lolh m.eue m.neue*1e6 m.cvar_eue res.runtime_total
end
println("="^72)
println("nEUE in parts-per-million of annual load demand.")
