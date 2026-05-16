# ── SimConfig ──────────────────────────────────────────────────────────────
# All simulation parameters with defaults.  Load from YAML with load_config().

Base.@kwdef struct SimConfig
    # ── Monte Carlo ────────────────────────────────────────────────────────
    n_scenarios::Int     = 100
    seed::Int            = 42

    # ── Economics ─────────────────────────────────────────────────────────
    voll::Float64        = 10_000.0   # $/MWh value of lost load

    # ── M1/M1b rule thresholds ───────────────────────────────────────────
    high_net_load_quantile::Float64   = 0.75  # proactive discharge above this
    charge_net_load_quantile::Float64 = 0.25  # charge below this
    reserve_fraction::Float64         = 0.50  # M1b: SOC floor as fraction of total energy

    # ── M2 rolling-window LP ──────────────────────────────────────────────
    lookahead_hours::Int              = 24
    epsilon_cycling::Float64          = 1e-3  # small cost on charge+discharge

    # ── M3 full-year ED ───────────────────────────────────────────────────
    cyclic_soc::Bool                  = true
    storage_cycling_cost::Float64     = 0.01  # $/MWh to deter simultaneous c/d

    # ── Risk metric ───────────────────────────────────────────────────────
    cvar_alpha::Float64  = 0.95

    # ── Output ────────────────────────────────────────────────────────────
    save_dispatch::Bool  = false
    output_dir::String   = "results"
end

"""
    load_config(path) -> SimConfig

Load a YAML file and return a SimConfig.  Keys not present in the file keep
their defaults.  Unknown keys are silently ignored.
"""
function load_config(path::String)::SimConfig
    raw = YAML.load_file(path)
    valid = fieldnames(SimConfig)
    kwargs = Dict{Symbol,Any}()
    for (k, v) in raw
        sym = Symbol(k)
        sym in valid && (kwargs[sym] = v)
    end
    return SimConfig(; kwargs...)
end
