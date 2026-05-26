#!/usr/bin/env julia
# 51_recharge_window_diagnostic.jl
#
# Recharge-window storage-dependence analysis.
#
# For each M3 (full-year ED) residual shortage event, computes how much of the
# event EUE could have been covered by M3 storage charging that occurred within
# lookback windows of 6, 12, 24, 48, 72, and 168 h prior to event start.
#
# Interpretation: if M3 accumulated enough charge within a short pre-event
# window to cover the event, an emergency-only rule (M1c) that greedily
# charges from system surplus can also accumulate enough charge, explaining
# why M1c matches full-year ED EUE in the tested cases.
#
# Data:
#   VRE120_base:     results/storage_operation_comparison/m3_dispatch.csv (cached)
#   VRE120_wind_hvy: run fresh, cache at results/recharge_window_diagnostic/
#
# Outputs:
#   results/recharge_window_diagnostic/event_level.csv  (per-event, not committed)
#   results/paper_tables/recharge_window_diagnostic.csv (summary, committed)
#
# Usage:
#   julia --project=. scripts/51_recharge_window_diagnostic.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASES      = ["VRE120_base", "VRE120_wind_hvy"]
const N_SCEN     = 20
const SEED       = 42
const LOOKBACKS  = Int[6, 12, 24, 48, 72, 168]
const STORAGE_E  = 3932.0   # MWh — 983 MW × 4 h (same for both VRE portfolios)

const DATA_ROOT  = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))
const DIAG_DIR   = abspath(joinpath(@__DIR__, "..", "results", "recharge_window_diagnostic"))
const TAB_DIR    = abspath(joinpath(@__DIR__, "..", "results", "paper_tables"))
const BASE_CACHE = abspath(joinpath(@__DIR__, "..", "results",
                                   "storage_operation_comparison", "m3_dispatch.csv"))

mkpath(DIAG_DIR)
mkpath(TAB_DIR)

# Per-case cache paths
const CACHE_PATHS = Dict{String,String}(
    "VRE120_base"     => BASE_CACHE,
    "VRE120_wind_hvy" => joinpath(DIAG_DIR, "m3_dispatch_wind_hvy.csv"),
)

println("=" ^ 70)
println("51_recharge_window_diagnostic.jl")
println("Date: ", Dates.now())
println("Cases: ", join(CASES, ", "))
println("Lookback windows: ", join(LOOKBACKS, ", "), " h")
println("=" ^ 70)

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

function load_or_run_m3(case::String)::DataFrame
    path = CACHE_PATHS[case]
    if isfile(path)
        println("  Loading cached M3 dispatch: $(basename(path))")
        df = CSV.read(path, DataFrame)
        println("  $(size(df, 1)) rows loaded")
        return df
    end
    println("  Running M3 ED for $case (N=$N_SCEN, seed=$SEED) — no cache found ...")
    case_dir = joinpath(DATA_ROOT, case)
    isdir(case_dir) || error("Case directory not found: $case_dir")
    sys  = load_system_data(case_dir)
    cfg  = SimConfig(n_scenarios=N_SCEN, seed=SEED)
    scen = generate_scenarios(sys, cfg)
    t0   = time()
    res  = run_m3_ed_dispatch(sys, scen.availability, cfg)
    println(@sprintf("  M3 runtime: %.1f s", time() - t0))
    df   = build_dispatch_df(res, sys, scen)
    CSV.write(path, df)
    println("  Cached $(size(df, 1)) rows to: $path  (not committed — large file)")
    return df
end

# Find contiguous shortage events from sorted (hours, load_shed) arrays.
# Returns a vector of NamedTuples with start_h, end_h, duration_h, eue.
function find_events(hours::Vector{Int}, shed::Vector{Float64})
    events = NamedTuple[]
    n = length(shed)
    i = 1
    while i <= n
        if shed[i] > 0.5
            j = i
            while j <= n && shed[j] > 0.5
                j += 1
            end
            j -= 1
            push!(events, (
                start_h    = hours[i],
                end_h      = hours[j],
                duration_h = j - i + 1,
                eue        = sum(shed[i:j]),
            ))
            i = j + 1
        else
            i += 1
        end
    end
    return events
end

# Cumulative M3 storage charge in [event_start_h - L, event_start_h - 1],
# capped at storage energy capacity.
function charge_before(hours::Vector{Int}, charge::Vector{Float64},
                       event_start_h::Int, L::Int)::Float64
    lo   = event_start_h - L
    hi   = event_start_h - 1
    mask = (hours .>= lo) .& (hours .<= hi)
    any(mask) || return 0.0
    return min(sum(charge[mask]), STORAGE_E)
end

# ─────────────────────────────────────────────────────────────────────────────
# Main loop — collect per-event data
# ─────────────────────────────────────────────────────────────────────────────

all_events = NamedTuple[]

for case in CASES
    println("\n─── $case " * "─" ^ max(0, 50 - length(case)))
    df_m3 = load_or_run_m3(case)
    # build_dispatch_df outputs rows in (scenario_id, hour) order already

    n_events_case = 0

    for g in groupby(df_m3, :scenario_id)
        scen_id = first(g.scenario_id)
        hours   = collect(Int,     g.hour)
        shed    = collect(Float64, g.load_shed_mw)
        charge  = collect(Float64, g.storage_charge_mw)

        events = find_events(hours, shed)
        n_events_case += length(events)

        for (ev_id, ev) in enumerate(events)
            charges = [charge_before(hours, charge, ev.start_h, L) for L in LOOKBACKS]
            covered = [c >= ev.eue for c in charges]
            min_lb  = let k = findfirst(covered)
                          isnothing(k) ? 9999 : LOOKBACKS[k]
                      end

            push!(all_events, (
                case             = case,
                scenario_id      = scen_id,
                event_id         = ev_id,
                event_start_h    = ev.start_h,
                event_end_h      = ev.end_h,
                event_duration_h = ev.duration_h,
                event_eue_mwh    = ev.eue,
                charge_6h        = charges[1],
                charge_12h       = charges[2],
                charge_24h       = charges[3],
                charge_48h       = charges[4],
                charge_72h       = charges[5],
                charge_168h      = charges[6],
                covered_6h       = covered[1],
                covered_12h      = covered[2],
                covered_24h      = covered[3],
                covered_48h      = covered[4],
                covered_72h      = covered[5],
                covered_168h     = covered[6],
                min_lookback_h   = min_lb,
            ))
        end
    end

    println("  Events found: $n_events_case across $N_SCEN scenarios")
end

df_ev = DataFrame(all_events)

# ─────────────────────────────────────────────────────────────────────────────
# Save event-level CSV (not committed — diagnostic detail)
# ─────────────────────────────────────────────────────────────────────────────

ev_path = joinpath(DIAG_DIR, "event_level.csv")
CSV.write(ev_path, df_ev)
println("\nEvent-level CSV: $ev_path  ($(length(all_events)) events, not committed)")

# ─────────────────────────────────────────────────────────────────────────────
# Summary statistics per case
# ─────────────────────────────────────────────────────────────────────────────

# Build summary as parallel vectors, one row per case
s_case                    = String[]
s_n_events                = Int[]
s_total_eue               = Float64[]
s_mean_event_eue          = Float64[]
s_max_event_eue           = Float64[]
s_n_events_need_gt72h     = Int[]

# shares: 6 columns each for events and EUE
s_sh_ev  = [Float64[] for _ in LOOKBACKS]
s_sh_eue = [Float64[] for _ in LOOKBACKS]

println("\n─── Summary ─────────────────────────────────────────────────────────")

for g in groupby(df_ev, :case)
    case      = first(g.case)
    n_ev      = size(g, 1)
    eue_vec   = collect(Float64, g.event_eue_mwh)
    total_eue = sum(eue_vec)
    n_long    = count(r -> r.min_lookback_h > 72, eachrow(g))

    push!(s_case,                case)
    push!(s_n_events,            n_ev)
    push!(s_total_eue,           total_eue)
    push!(s_mean_event_eue,      mean(eue_vec))
    push!(s_max_event_eue,       maximum(eue_vec))
    push!(s_n_events_need_gt72h, n_long)

    println("\n  $case: $n_ev events, total EUE $(round(total_eue; digits=1)) MWh")
    println("  $(lpad("Window",8))  $(lpad("% events",10))  $(lpad("% EUE",10))")

    for (idx, L) in enumerate(LOOKBACKS)
        cov_col   = collect(Bool, g[!, Symbol("covered_$(L)h")])
        sh_ev     = mean(cov_col)
        sh_eue    = any(cov_col) ? sum(eue_vec[cov_col]) / total_eue : 0.0

        push!(s_sh_ev[idx],  sh_ev)
        push!(s_sh_eue[idx], sh_eue)

        println(@sprintf("  %6d h:   %8.1f %%   %8.1f %%", L, 100sh_ev, 100sh_eue))
    end
end

# Assemble summary DataFrame
df_sum = DataFrame(
    case                        = s_case,
    n_events                    = s_n_events,
    total_eue_mwh               = s_total_eue,
    mean_event_eue_mwh          = s_mean_event_eue,
    max_event_eue_mwh           = s_max_event_eue,
    n_events_need_gt72h         = s_n_events_need_gt72h,
    share_events_covered_6h     = s_sh_ev[1],
    share_events_covered_12h    = s_sh_ev[2],
    share_events_covered_24h    = s_sh_ev[3],
    share_events_covered_48h    = s_sh_ev[4],
    share_events_covered_72h    = s_sh_ev[5],
    share_events_covered_168h   = s_sh_ev[6],
    share_eue_covered_6h        = s_sh_eue[1],
    share_eue_covered_12h       = s_sh_eue[2],
    share_eue_covered_24h       = s_sh_eue[3],
    share_eue_covered_48h       = s_sh_eue[4],
    share_eue_covered_72h       = s_sh_eue[5],
    share_eue_covered_168h      = s_sh_eue[6],
)

tab_path = joinpath(TAB_DIR, "recharge_window_diagnostic.csv")
CSV.write(tab_path, df_sum)
println("\nSummary CSV: $tab_path  (committed)")
println("\nDone.")
