#!/usr/bin/env julia
# 51_wind_heavy_event_dispatch.jl
#
# Generates M1c, M2, M3 hourly dispatch for VRE120_wind_hvy, scenario 15
# (the top-ΔEUE scenario vs PCM-UCED), and saves the event-window CSV.
#
# Outputs (results/storage_operation_comparison/):
#   wind_heavy_event_window.csv   — event window for the critical sub-event
#   wind_heavy_m1c_dispatch.csv   — full-year M1c dispatch
#   wind_heavy_m2_dispatch.csv    — full-year M2  dispatch
#   wind_heavy_m3_dispatch.csv    — full-year M3  dispatch
#
# Usage:
#   julia --project=. scripts/51_wind_heavy_event_dispatch.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Statistics, Printf, Dates

const CASE       = "VRE120_wind_hvy"
const N_SCEN     = 20
const SEED       = 42
const TARGET_SCEN = 15    # top-ΔEUE scenario
const M2_RISK    = 1000.0
const M2_BUF     = 48
const OUT_DIR    = abspath(joinpath(@__DIR__, "..", "results",
                                   "storage_operation_comparison"))

mkpath(OUT_DIR)

println("=" ^ 70)
println("51_wind_heavy_event_dispatch.jl")
println("Date: ", Dates.now())
println(@sprintf("Case: %s  N=%d  seed=%d  target_scenario=%d",
                 CASE, N_SCEN, SEED, TARGET_SCEN))
println("Output: ", OUT_DIR)
println("=" ^ 70)

data_root = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))
case_dir  = joinpath(data_root, CASE)
isdir(case_dir) || error("Case directory not found: $case_dir")

sys      = load_system_data(case_dir)
base_cfg = SimConfig(n_scenarios=N_SCEN, seed=SEED)
m2_cfg   = SimConfig(n_scenarios=N_SCEN, seed=SEED,
                     risk_margin_mw=M2_RISK, window_buffer_hours=M2_BUF)

p_m1c = joinpath(OUT_DIR, "wind_heavy_m1c_dispatch.csv")
p_m2  = joinpath(OUT_DIR, "wind_heavy_m2_dispatch.csv")
p_m3  = joinpath(OUT_DIR, "wind_heavy_m3_dispatch.csv")
cached = isfile(p_m1c) && isfile(p_m2) && isfile(p_m3)

if cached
    println("\nLoading cached dispatch CSVs …")
    df_m1c = CSV.read(p_m1c, DataFrame)
    df_m2  = CSV.read(p_m2,  DataFrame)
    df_m3  = CSV.read(p_m3,  DataFrame)
    println("  loaded $(size(df_m1c,1)) rows per method")
else
    println("\nGenerating ScenarioSet (N=$N_SCEN, seed=$SEED) …")
    scen = generate_scenarios(sys, base_cfg)

    println("\nRunning models:")

    print("  M1c (emergency-only heuristic) … ")
    t0 = time(); res_m1c = run_m1c_emergency_only(sys, scen, base_cfg)
    println(@sprintf("%.1f s", time() - t0))

    print("  M2  (event-window LP)          … ")
    t0 = time(); res_m2 = first(run_m2_with_diagnostics(sys, scen.availability, m2_cfg))
    println(@sprintf("%.1f s", time() - t0))

    print("  M3  (full-year ED LP)          … ")
    t0 = time(); res_m3 = run_m3_ed_dispatch(sys, scen.availability, base_cfg)
    println(@sprintf("%.1f s", time() - t0))

    println("\nBuilding and saving dispatch DataFrames …")
    df_m1c = build_dispatch_df(res_m1c, sys, scen)
    df_m2  = build_dispatch_df(res_m2,  sys, scen)
    df_m3  = build_dispatch_df(res_m3,  sys, scen)
    CSV.write(p_m1c, df_m1c)
    CSV.write(p_m2,  df_m2)
    CSV.write(p_m3,  df_m3)
    println("  wind_heavy_m1c_dispatch.csv ($(size(df_m1c, 1)) rows)")
    println("  wind_heavy_m2_dispatch.csv  ($(size(df_m2, 1)) rows)")
    println("  wind_heavy_m3_dispatch.csv  ($(size(df_m3, 1)) rows)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Extract event window for target scenario (the critical sub-event)
# ─────────────────────────────────────────────────────────────────────────────

println("\nExtracting event window for scenario $TARGET_SCEN …")

function indexed_col(df::DataFrame, col::Symbol)::Matrix{Float64}
    n_s = maximum(df.scenario_id)
    n_h = maximum(df.hour)
    mat = zeros(Float64, n_s, n_h)
    for i in eachindex(df.scenario_id)
        mat[df.scenario_id[i], df.hour[i]] = df[!, col][i]
    end
    return mat
end

ls_m1c  = indexed_col(df_m1c, :load_shed_mw)
ls_m2   = indexed_col(df_m2,  :load_shed_mw)
ls_m3   = indexed_col(df_m3,  :load_shed_mw)
dc_m1c  = indexed_col(df_m1c, :storage_discharge_mw)
dc_m2   = indexed_col(df_m2,  :storage_discharge_mw)
dc_m3   = indexed_col(df_m3,  :storage_discharge_mw)
soc_m1c = indexed_col(df_m1c, :storage_soc_mwh)
soc_m2  = indexed_col(df_m2,  :storage_soc_mwh)
soc_m3  = indexed_col(df_m3,  :storage_soc_mwh)

# The critical sub-event is h4983–4988 (the PCM-UCED vs ED divergence window)
# Expand ±10 hours for context
s = TARGET_SCEN

all_shed = [h for h in 1:sys.n_hours
            if ls_m1c[s,h] > 0 || ls_m2[s,h] > 0 || ls_m3[s,h] > 0]

if isempty(all_shed)
    error("No shedding hours found for scenario $s")
end

# Find the sub-event with the highest EUE (should be second cluster ≥4983)
# Split into clusters (gap ≥ 20 hours = new event)
clusters = Vector{Vector{Int}}()
cluster_buf = [all_shed[1]]
for i in eachindex(all_shed)[2:end]
    if all_shed[i] - cluster_buf[end] > 20
        push!(clusters, copy(cluster_buf))
        empty!(cluster_buf)
        push!(cluster_buf, all_shed[i])
    else
        push!(cluster_buf, all_shed[i])
    end
end
push!(clusters, cluster_buf)

# Score each cluster by M1c EUE
best_cluster = argmax([sum(ls_m1c[s, c[1]:c[end]]) for c in clusters])
h_shed = clusters[best_cluster]
h_first = minimum(h_shed)
h_last  = maximum(h_shed)

PAD_BEFORE = 8
PAD_AFTER  = 10
h_start = max(1, h_first - PAD_BEFORE)
h_end   = min(sys.n_hours, h_last + PAD_AFTER)

println("  Shed hours (cluster $best_cluster): $(h_shed)")
println(@sprintf("  Window: h%d-h%d  (rel: %+d to %+d)",
                 h_start, h_end, h_start - h_first, h_end - h_first))

rows = NamedTuple[]
for h in h_start:h_end
    push!(rows, (
        hour            = h,
        rel_hour        = h - h_first,
        scenario_id     = s,
        m1c_load_shed_mw         = ls_m1c[s, h],
        m2_load_shed_mw          = ls_m2[s, h],
        m3_load_shed_mw          = ls_m3[s, h],
        m1c_storage_discharge_mw = dc_m1c[s, h],
        m2_storage_discharge_mw  = dc_m2[s, h],
        m3_storage_discharge_mw  = dc_m3[s, h],
        m1c_soc_mwh              = soc_m1c[s, h],
        m2_soc_mwh               = soc_m2[s, h],
        m3_soc_mwh               = soc_m3[s, h],
    ))
end

df_win = DataFrame(rows)
p_win  = joinpath(OUT_DIR, "wind_heavy_event_window.csv")
CSV.write(p_win, df_win)
println("Saved: wind_heavy_event_window.csv  ($(nrow(df_win)) rows, h$(h_start)-h$(h_end))")

# Print window EUE summary
eue_m1c = sum(df_win.m1c_load_shed_mw)
eue_m2  = sum(df_win.m2_load_shed_mw)
eue_m3  = sum(df_win.m3_load_shed_mw)
println(@sprintf("Window EUE: M1c=%.1f  M2=%.1f  M3=%.1f MWh",
                 eue_m1c, eue_m2, eue_m3))
println("Done.")
