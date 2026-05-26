#!/usr/bin/env julia
# 48_generate_storage_operation_dispatch.jl
#
# Runs M1c, M2, M3 for VRE120_base (N=20, seed=42), selects a representative
# shortage event where Event-window storage MCS (M2) differs from Emergency-only
# storage MCS (M1c) / Full-year ED (M3), and saves the event-window data.
#
# Outputs  (results/storage_operation_comparison/):
#   event_window.csv      — selected event window (committed; ~50–120 rows)
#   event_selection.txt   — event metadata
#   m1c_dispatch.csv      — full-year M1c dispatch (NOT committed; >175k rows)
#   m2_dispatch.csv       — full-year M2  dispatch (NOT committed)
#   m3_dispatch.csv       — full-year M3  dispatch (NOT committed)
#
# Usage:
#   julia --project=. scripts/48_generate_storage_operation_dispatch.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASE       = "VRE120_base"
const N_SCEN     = 20
const SEED       = 42
const M2_RISK    = 1000.0
const M2_BUF     = 48
const PAD_BEFORE = 24   # display hours before first shedding hour
const PAD_AFTER  = 12   # display hours after last shedding hour
const SCAN_WIN   = 60   # sliding window for event detection (hours)
const OUT_DIR    = abspath(joinpath(@__DIR__, "..", "results",
                                   "storage_operation_comparison"))

mkpath(OUT_DIR)

println("=" ^ 70)
println("48_generate_storage_operation_dispatch.jl")
println("Date: ", Dates.now())
println(@sprintf("Case: %s  N=%d  seed=%d", CASE, N_SCEN, SEED))
println(@sprintf("M2: risk_margin=%.0f MW  buffer=%d h", M2_RISK, M2_BUF))
println("Output: ", OUT_DIR)
println("=" ^ 70)

# ─────────────────────────────────────────────────────────────────────────────
# Run models
# ─────────────────────────────────────────────────────────────────────────────

data_root = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))
case_dir  = joinpath(data_root, CASE)
isdir(case_dir) || error("Case directory not found: $case_dir")

sys      = load_system_data(case_dir)
base_cfg = SimConfig(n_scenarios=N_SCEN, seed=SEED)
m2_cfg   = SimConfig(n_scenarios=N_SCEN, seed=SEED,
                     risk_margin_mw=M2_RISK, window_buffer_hours=M2_BUF)

println("\nGenerating ScenarioSet (N=$N_SCEN, seed=$SEED) …")
n_hours = sys.n_hours

p_m1c = joinpath(OUT_DIR, "m1c_dispatch.csv")
p_m2  = joinpath(OUT_DIR, "m2_dispatch.csv")
p_m3  = joinpath(OUT_DIR, "m3_dispatch.csv")
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
    println("  m1c_dispatch.csv ($(size(df_m1c, 1)) rows — not committed)")
    println("  m2_dispatch.csv  ($(size(df_m2, 1)) rows — not committed)")
    println("  m3_dispatch.csv  ($(size(df_m3, 1)) rows — not committed)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Event selection
# ─────────────────────────────────────────────────────────────────────────────

println("\nSelecting representative event …")

# Build indexed arrays [scenario, hour] from DataFrames
function indexed_col(df::DataFrame, col::Symbol)::Matrix{Float64}
    n_s = maximum(df.scenario_id)
    n_h = maximum(df.hour)
    mat = zeros(Float64, n_s, n_h)
    for i in eachindex(df.scenario_id)
        mat[df.scenario_id[i], df.hour[i]] = df[!, col][i]
    end
    return mat
end

ls_m1c = indexed_col(df_m1c, :load_shed_mw)
ls_m2  = indexed_col(df_m2,  :load_shed_mw)
ls_m3  = indexed_col(df_m3,  :load_shed_mw)
dc_m1c = indexed_col(df_m1c, :storage_discharge_mw)
dc_m2  = indexed_col(df_m2,  :storage_discharge_mw)
dc_m3  = indexed_col(df_m3,  :storage_discharge_mw)
soc_m1c = indexed_col(df_m1c, :storage_soc_mwh)
soc_m2  = indexed_col(df_m2,  :storage_soc_mwh)
soc_m3  = indexed_col(df_m3,  :storage_soc_mwh)

# For each scenario, find sliding window with highest |M2 - M1c| + M1c shedding
function select_event(ls_m1c, ls_m2, n_scen, n_hours, scan_win)
    best_scen  = 0
    best_win_h = 1
    best_score = 0.0
    for s in 1:n_scen
        m1c_row = ls_m1c[s, :]
        m2_row  = ls_m2[s, :]
        diff    = abs.(m2_row .- m1c_row)
        for w in 1:(n_hours - scan_win + 1)
            win         = w:(w + scan_win - 1)
            m1c_win_eue = sum(m1c_row[win])
            m1c_win_eue < 20.0 && continue
            score = sum(diff[win]) + 0.3 * m1c_win_eue
            if score > best_score
                best_score  = score
                best_scen   = s
                best_win_h  = w
            end
        end
    end
    return best_scen, best_win_h, best_score
end

best_scen, best_win_h, best_score = select_event(ls_m1c, ls_m2, N_SCEN, n_hours, SCAN_WIN)

println(@sprintf("  Selected scenario: %d  (window start h=%d, score=%.1f)",
                 best_scen, best_win_h, best_score))

# Find shedding hours within the best window
win_range = best_win_h:(best_win_h + SCAN_WIN - 1)
shed_hours_m1c = [h for h in win_range if ls_m1c[best_scen, h] > 0.0]
shed_hours_m2  = [h for h in win_range if ls_m2[best_scen, h]  > 0.0]
all_shed_hours = sort(union(shed_hours_m1c, shed_hours_m2))

if isempty(all_shed_hours)
    # Fallback: use window center
    h_first = best_win_h + div(SCAN_WIN, 2)
    h_last  = h_first
else
    h_first = minimum(all_shed_hours)
    h_last  = maximum(all_shed_hours)
end

h_start = max(1,       h_first - PAD_BEFORE)
h_end   = min(n_hours, h_last  + PAD_AFTER)
window  = h_start:h_end

println(@sprintf("  Shedding hours: %d–%d  display window: %d–%d  (%d hours)",
                 h_first, h_last, h_start, h_end, length(window)))

eue_m1c_win = sum(ls_m1c[best_scen, window])
eue_m2_win  = sum(ls_m2[best_scen, window])
eue_m3_win  = sum(ls_m3[best_scen, window])
println(@sprintf("  Window EUE — M1c: %.1f  M2: %.1f  M3: %.1f  MWh",
                 eue_m1c_win, eue_m2_win, eue_m3_win))

# ─────────────────────────────────────────────────────────────────────────────
# Save event window CSV (committed)
# ─────────────────────────────────────────────────────────────────────────────

ev_rows = NamedTuple[]
for h in window
    push!(ev_rows, (
        hour                     = h,
        rel_hour                 = h - h_first,
        scenario_id              = best_scen,
        m1c_load_shed_mw         = ls_m1c[best_scen, h],
        m2_load_shed_mw          = ls_m2[best_scen, h],
        m3_load_shed_mw          = ls_m3[best_scen, h],
        m1c_storage_discharge_mw = dc_m1c[best_scen, h],
        m2_storage_discharge_mw  = dc_m2[best_scen, h],
        m3_storage_discharge_mw  = dc_m3[best_scen, h],
        m1c_soc_mwh              = soc_m1c[best_scen, h],
        m2_soc_mwh               = soc_m2[best_scen, h],
        m3_soc_mwh               = soc_m3[best_scen, h],
    ))
end

ev_df = DataFrame(ev_rows)
CSV.write(joinpath(OUT_DIR, "event_window.csv"), ev_df)
println("\nSaved event_window.csv ($(size(ev_df, 1)) rows)")

open(joinpath(OUT_DIR, "event_selection.txt"), "w") do io
    println(io, "Script: 48_generate_storage_operation_dispatch.jl")
    println(io, "Date:   ", Dates.now())
    println(io, "Case:   $CASE  N=$N_SCEN  seed=$SEED")
    println(io, "M2 config: risk_margin_mw=$M2_RISK  window_buffer_hours=$M2_BUF")
    println(io, "")
    println(io, "Selected scenario: $best_scen")
    println(io, @sprintf("First shedding hour: %d   Last: %d", h_first, h_last))
    println(io, @sprintf("Display window: h%d – h%d  (%d hours)", h_start, h_end, length(window)))
    println(io, "")
    println(io, @sprintf("Window EUE (MWh):  M1c=%.1f  M2=%.1f  M3=%.1f",
                         eue_m1c_win, eue_m2_win, eue_m3_win))
    println(io, @sprintf("Max shed (MW):     M1c=%.1f  M2=%.1f  M3=%.1f",
                         maximum(ls_m1c[best_scen, window]),
                         maximum(ls_m2[best_scen,  window]),
                         maximum(ls_m3[best_scen,  window])))
    println(io, @sprintf("Shed hours (M1c):  %d   (M2): %d",
                         sum(ls_m1c[best_scen, window] .> 0),
                         sum(ls_m2[best_scen,  window] .> 0)))
    println(io, "")
    println(io, "Note: m1c_dispatch.csv, m2_dispatch.csv, m3_dispatch.csv are NOT")
    println(io, "committed (>175k rows each). Regenerate with this script.")
end

println("Saved event_selection.txt")
println("\nDone.")
