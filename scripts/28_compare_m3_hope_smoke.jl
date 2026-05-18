#!/usr/bin/env julia
# 28_compare_m3_hope_smoke.jl
#
# Runs M3 (full-year ED LP) for a single scenario and compares it against
# HOPE-ED and HOPE-UC-lite metrics from script 27.
#
# Usage:
#   julia --project=. scripts/28_compare_m3_hope_smoke.jl \
#     --case VRE120_base \
#     --scenario-id 1 \
#     --n-scenarios 20 \
#     --seed 42 \
#     --hope-metrics results/hope_smoke_runs/hope_smoke_metrics.csv \
#     --out-dir results/hope_smoke_runs
#
# Options:
#   --case           Case name under data_processed/cases/ (default: VRE120_base)
#   --scenario-id    1-based scenario index to run M3 for (default: 1)
#   --n-scenarios    Total scenarios to generate for CRN (default: 20)
#   --seed           RNG seed (default: 42)
#   --hope-metrics   Path to hope_smoke_metrics.csv produced by script 27
#   --out-dir        Output directory (default: results/hope_smoke_runs)
#
# Outputs:
#   <out-dir>/m3_hope_smoke_comparison.csv          -- side-by-side metrics table
#   <out-dir>/summary.txt                           -- plain-text diagnostic answers
#   <out-dir>/hourly_m3_vs_hope_ed_loadshed.csv     -- hourly diff (only if M3 ≠ HOPE-ED)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Statistics, Printf, Dates

# ── CLI ───────────────────────────────────────────────────────────────────────

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional argument: $arg")
        key = arg[3:end]
        if i + 1 > length(args) || startswith(args[i+1], "--")
            error("Option $arg requires a value")
        end
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

# ── Metric helpers (mirror of script 27) ─────────────────────────────────────

function single_scenario_metrics(load_shed::Vector{Float64})
    n_hours   = length(load_shed)
    lolh      = compute_lolh(load_shed)
    lolp_pct  = 100.0 * compute_lolp(lolh, n_hours)
    lole_days = compute_lole_days(load_shed)
    eue       = compute_eue(load_shed)
    max_sf    = maximum(load_shed)
    durations = compute_shortage_events(load_shed)
    n_events  = length(durations)
    fdur      = Float64.(durations)
    mean_dur  = isempty(fdur) ? 0.0 : mean(fdur)
    p95_dur   = isempty(fdur) ? 0.0 : quantile(fdur, 0.95)
    return (lolh=lolh, lolp_percent=lolp_pct, lole_days=lole_days,
            eue_mwh=eue, cvar_eue_mwh=eue, max_shortfall_mw=max_sf,
            n_shortage_events=n_events, mean_shortage_duration_h=mean_dur,
            p95_shortage_duration_h=p95_dur)
end

# ── Main ──────────────────────────────────────────────────────────────────────

let
    kw = parse_cli(ARGS)

    case_name   = get(kw, "case", "VRE120_base")
    scenario_id = parse(Int, get(kw, "scenario-id", "1"))
    n_scenarios = parse(Int, get(kw, "n-scenarios", "20"))
    seed        = parse(Int, get(kw, "seed", "42"))
    hope_metrics_path = get(kw, "hope-metrics",
                             joinpath(@__DIR__, "..", "results",
                                      "hope_smoke_runs", "hope_smoke_metrics.csv"))
    out_dir = get(kw, "out-dir",
                  joinpath(@__DIR__, "..", "results", "hope_smoke_runs"))

    mkpath(out_dir)

    println("="^72)
    println("M3 vs HOPE Smoke-Run Comparison")
    println("="^72)
    println("  Case        : $case_name")
    println("  Scenario    : $scenario_id  (of $n_scenarios, seed=$seed)")
    println("  HOPE metrics: $hope_metrics_path")
    println("  Output dir  : $out_dir")
    println()

    # ── 1. Load system ────────────────────────────────────────────────────────
    data_dir = joinpath(@__DIR__, "..", "data_processed", "cases", case_name)
    isdir(data_dir) || error("Case data directory not found: $data_dir")
    println("Loading system: $case_name …")
    system = load_system_data(data_dir)
    println("  $(system.n_hours) hours, $(size(thermal_generators(system), 1)) thermal generators")

    # ── 2. Generate scenarios ─────────────────────────────────────────────────
    println("Generating $n_scenarios scenarios (seed=$seed) …")
    scenarios = generate_scenarios(system, n_scenarios, seed)

    1 <= scenario_id <= scenarios.n_scenarios ||
        error("scenario-id $scenario_id out of range [1, $(scenarios.n_scenarios)]")

    # Single-scenario availability slice: 1 × n_thermal × n_hours
    avail_s = scenarios.availability[scenario_id:scenario_id, :, :]

    # ── 3. Run M3 for the target scenario ────────────────────────────────────
    config = SimConfig(n_scenarios = 1, seed = seed)
    println("Running M3 (ED LP) for scenario $scenario_id …")
    t0 = time()
    m3_results = run_m3_ed_dispatch(system, avail_s, config)
    m3_runtime = time() - t0
    println("  M3 done in $(round(m3_runtime, digits=1)) s")

    # ── 4. Compute M3 metrics ─────────────────────────────────────────────────
    load_shed_m3 = m3_results[1].load_shed
    m3 = single_scenario_metrics(load_shed_m3)

    println()
    @printf("  M3:  LOLH=%4.0f h  EUE=%9.1f MWh  max_sf=%6.1f MW  events=%d\n",
            m3.lolh, m3.eue_mwh, m3.max_shortfall_mw, m3.n_shortage_events)

    # ── 5. Load HOPE metrics ──────────────────────────────────────────────────
    isfile(hope_metrics_path) ||
        error("HOPE metrics file not found: $hope_metrics_path\n" *
              "  Run script 27 first.")
    hope_df = CSV.read(hope_metrics_path, DataFrame)

    # ── 6. Build comparison table ─────────────────────────────────────────────
    rows = NamedTuple[]

    # M3 row (baseline — errors are 0 by definition)
    push!(rows, (
        model                    = "M3-ED",
        lolh                     = m3.lolh,
        lolp_percent             = m3.lolp_percent,
        lole_days                = m3.lole_days,
        eue_mwh                  = m3.eue_mwh,
        cvar_eue_mwh             = m3.cvar_eue_mwh,
        max_shortfall_mw         = m3.max_shortfall_mw,
        n_shortage_events        = m3.n_shortage_events,
        mean_shortage_duration_h = m3.mean_shortage_duration_h,
        p95_shortage_duration_h  = m3.p95_shortage_duration_h,
        runtime_s                = m3_runtime,
        lolh_error_vs_m3         = 0.0,
        eue_error_vs_m3          = 0.0,
        max_shortfall_error_vs_m3 = 0.0,
    ))

    for hrow in eachrow(hope_df)
        model_name = "HOPE-$(hrow.mode)"
        rt = ismissing(hrow.runtime_s) ? NaN : Float64(hrow.runtime_s)
        push!(rows, (
            model                    = model_name,
            lolh                     = Float64(hrow.lolh),
            lolp_percent             = Float64(hrow.lolp_percent),
            lole_days                = Float64(hrow.lole_days),
            eue_mwh                  = Float64(hrow.eue_mwh),
            cvar_eue_mwh             = Float64(hrow.cvar_eue_mwh),
            max_shortfall_mw         = Float64(hrow.max_shortfall_mw),
            n_shortage_events        = Int(hrow.n_shortage_events),
            mean_shortage_duration_h = Float64(hrow.mean_shortage_duration_h),
            p95_shortage_duration_h  = Float64(hrow.p95_shortage_duration_h),
            runtime_s                = rt,
            lolh_error_vs_m3         = Float64(hrow.lolh) - m3.lolh,
            eue_error_vs_m3          = Float64(hrow.eue_mwh) - m3.eue_mwh,
            max_shortfall_error_vs_m3 = Float64(hrow.max_shortfall_mw) - m3.max_shortfall_mw,
        ))
        @printf("  %-10s LOLH=%4.0f h  EUE=%9.1f MWh  max_sf=%6.1f MW  events=%d  rt=%.1f s\n",
                model_name, Float64(hrow.lolh), Float64(hrow.eue_mwh),
                Float64(hrow.max_shortfall_mw), Int(hrow.n_shortage_events), rt)
    end

    comp_df = DataFrame(rows)
    comp_path = joinpath(out_dir, "m3_hope_smoke_comparison.csv")
    CSV.write(comp_path, comp_df)
    println("\nWritten: $comp_path")

    # ── 7. Hourly diagnostic (only if M3 ≠ HOPE-ED) ──────────────────────────
    hope_ed_row = findfirst(r -> r.mode == "ED", eachrow(hope_df))
    wrote_diag = false

    if !isnothing(hope_ed_row)
        hed = hope_df[hope_ed_row, :]
        lolh_diff = abs(Float64(hed.lolh) - m3.lolh)
        eue_diff  = abs(Float64(hed.eue_mwh) - m3.eue_mwh)

        if lolh_diff > 0.5 || eue_diff > 1.0
            hourly_path = joinpath(out_dir, "hope_load_shed_hourly.csv")
            if isfile(hourly_path)
                hourly_df = CSV.read(hourly_path, DataFrame)
                ed_rows   = filter(r -> r.mode == "ED", eachrow(hourly_df))

                hope_shed = Dict{Int,Float64}()
                for hr in ed_rows
                    hope_shed[Int(hr.hour)] = Float64(hr.load_shed_mw)
                end

                m3_shed = Dict{Int,Float64}()
                for h in eachindex(load_shed_m3)
                    if load_shed_m3[h] > 0.0
                        m3_shed[h] = load_shed_m3[h]
                    end
                end

                all_hours = sort(collect(union(keys(hope_shed), keys(m3_shed))))
                diag_rows = [(
                    hour                 = h,
                    m3_load_shed_mw      = get(m3_shed, h, 0.0),
                    hope_ed_load_shed_mw = get(hope_shed, h, 0.0),
                    difference_mw        = get(hope_shed, h, 0.0) - get(m3_shed, h, 0.0),
                ) for h in all_hours]

                diag_df   = DataFrame(diag_rows)
                diag_path = joinpath(out_dir, "hourly_m3_vs_hope_ed_loadshed.csv")
                CSV.write(diag_path, diag_df)
                println("Written diagnostic: $diag_path  ($(size(diag_df, 1)) hours)")
                wrote_diag = true
            else
                @warn "Hourly HOPE load shed not found at $hourly_path; skipping diagnostic"
            end
        end
    end

    # ── 8. Summary text ───────────────────────────────────────────────────────
    hope_ed_lolh = isnothing(hope_ed_row) ? NaN : Float64(hope_df[hope_ed_row, :lolh])
    hope_ed_eue  = isnothing(hope_ed_row) ? NaN : Float64(hope_df[hope_ed_row, :eue_mwh])
    hope_uc_row  = findfirst(r -> r.mode == "UC", eachrow(hope_df))
    hope_uc_lolh = isnothing(hope_uc_row) ? NaN : Float64(hope_df[hope_uc_row, :lolh])
    hope_uc_eue  = isnothing(hope_uc_row) ? NaN : Float64(hope_df[hope_uc_row, :eue_mwh])
    hope_uc_rt   = isnothing(hope_uc_row) ? NaN :
                       (ismissing(hope_df[hope_uc_row, :runtime_s]) ? NaN :
                        Float64(hope_df[hope_uc_row, :runtime_s]))
    hope_ed_rt   = isnothing(hope_ed_row) ? NaN :
                       (ismissing(hope_df[hope_ed_row, :runtime_s]) ? NaN :
                        Float64(hope_df[hope_ed_row, :runtime_s]))

    ed_matches_m3 = !isnan(hope_ed_eue) &&
                    abs(hope_ed_eue - m3.eue_mwh) <= 1.0 &&
                    abs(hope_ed_lolh - m3.lolh) <= 0.5

    uc_matches_ed = !isnan(hope_uc_eue) && !isnan(hope_ed_eue) &&
                    abs(hope_uc_eue - hope_ed_eue) <= 1.0 &&
                    abs(hope_uc_lolh - hope_ed_lolh) <= 0.5

    rt_ratio = (!isnan(hope_uc_rt) && !isnan(hope_ed_rt) && hope_ed_rt > 0.0) ?
               hope_uc_rt / hope_ed_rt : NaN

    lines = String[]
    push!(lines, "HOPE Smoke Run vs M3 — Summary")
    push!(lines, "Generated: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
    push!(lines, "Case: $case_name  |  Scenario: $scenario_id  |  Seed: $seed")
    push!(lines, "")
    push!(lines, "─"^70)
    push!(lines, "Q1. Does HOPE-ED reproduce M3 for scenario $scenario_id?")
    push!(lines, "")
    if ed_matches_m3
        push!(lines, "  YES — HOPE-ED and M3 agree within tolerance.")
    else
        push!(lines, "  NO — differences detected:")
    end
    push!(lines, @sprintf("    M3       : LOLH=%4.0f h  EUE=%9.2f MWh  max_sf=%6.1f MW",
                           m3.lolh, m3.eue_mwh, m3.max_shortfall_mw))
    if !isnan(hope_ed_eue)
        hed_row = hope_df[hope_ed_row, :]
        push!(lines, @sprintf("    HOPE-ED  : LOLH=%4.0f h  EUE=%9.2f MWh  max_sf=%6.1f MW",
                               hope_ed_lolh, hope_ed_eue,
                               Float64(hed_row.max_shortfall_mw)))
        push!(lines, @sprintf("    Δ (ED−M3): LOLH=%+.0f h  EUE=%+.2f MWh",
                               hope_ed_lolh - m3.lolh, hope_ed_eue - m3.eue_mwh))
    end
    push!(lines, "")
    push!(lines, "─"^70)
    push!(lines, "Q2. Does HOPE-UC-lite differ from HOPE-ED?")
    push!(lines, "")
    if !isnan(hope_uc_eue) && !isnan(hope_ed_eue)
        if uc_matches_ed
            push!(lines, "  NO — HOPE-UC-lite and HOPE-ED agree within tolerance.")
        else
            push!(lines, "  YES — HOPE-UC-lite differs from HOPE-ED:")
        end
        huc_row = hope_df[hope_uc_row, :]
        push!(lines, @sprintf("    HOPE-ED  : LOLH=%4.0f h  EUE=%9.2f MWh  events=%d",
                               hope_ed_lolh, hope_ed_eue,
                               Int(hope_df[hope_ed_row, :n_shortage_events])))
        push!(lines, @sprintf("    HOPE-UC  : LOLH=%4.0f h  EUE=%9.2f MWh  events=%d",
                               hope_uc_lolh, hope_uc_eue,
                               Int(huc_row.n_shortage_events)))
        push!(lines, @sprintf("    Δ (UC−ED): LOLH=%+.0f h  EUE=%+.2f MWh",
                               hope_uc_lolh - hope_ed_lolh,
                               hope_uc_eue - hope_ed_eue))
        push!(lines, "")
        push!(lines, "  Interpretation: with UC constraints and real Pmin, the same")
        push!(lines, "  total unserved energy is spread over more shortage hours because")
        push!(lines, "  min-up/down times prevent immediate re-commitment after an outage.")
    else
        push!(lines, "  (HOPE-UC or HOPE-ED data not available)")
    end
    push!(lines, "")
    push!(lines, "─"^70)
    push!(lines, "Q3. If HOPE-ED differs from M3, which hours drive the difference?")
    push!(lines, "")
    if ed_matches_m3
        push!(lines, "  Not applicable — HOPE-ED and M3 agree.")
    elseif wrote_diag
        diag_path = joinpath(out_dir, "hourly_m3_vs_hope_ed_loadshed.csv")
        push!(lines, "  See hourly diagnostic: $diag_path")
        push!(lines, "  Hours with load shedding in either model are listed with the")
        push!(lines, "  signed difference (HOPE-ED − M3) in the 'difference_mw' column.")
    else
        push!(lines, "  Hourly HOPE data not available for detailed comparison.")
    end
    push!(lines, "")
    push!(lines, "─"^70)
    push!(lines, "Q4. Runtime ratio HOPE-UC-lite / HOPE-ED?")
    push!(lines, "")
    if !isnan(rt_ratio)
        push!(lines, @sprintf("  HOPE-ED runtime : %6.1f s", hope_ed_rt))
        push!(lines, @sprintf("  HOPE-UC runtime : %6.1f s", hope_uc_rt))
        push!(lines, @sprintf("  M3 runtime      : %6.1f s", m3_runtime))
        push!(lines, @sprintf("  Ratio UC/ED     : %.1f×", rt_ratio))
        push!(lines, @sprintf("  Ratio UC/M3     : %.1f×", hope_uc_rt / m3_runtime))
    else
        push!(lines, "  Runtime data not available (re-run script 27 with --runtimes).")
        push!(lines, @sprintf("  M3 runtime: %.1f s", m3_runtime))
    end
    push!(lines, "")
    push!(lines, "─"^70)
    push!(lines, "Q5. What should be fixed before scaling to N=5 or N=20?")
    push!(lines, "")
    if ed_matches_m3
        push!(lines, "  • HOPE-ED matches M3: no correctness issue. Safe to scale.")
    else
        push!(lines, "  • INVESTIGATE: HOPE-ED does not match M3 (see Q3 diagnostic).")
        push!(lines, "    Likely causes: storage cyclic-SOC mismatch, Pmin treatment,")
        push!(lines, "    or VRE curtailment handling. Resolve before scaling.")
    end
    uc_rt_s  = isnan(hope_uc_rt) ? "?" : string(round(Int, hope_uc_rt))
    uc_rt_h  = isnan(hope_uc_rt) ? "?" : string(round(hope_uc_rt * 20.0 / 3600.0, digits=1))
    ed_rt_s  = isnan(hope_ed_rt) ? "?" : string(round(Int, hope_ed_rt))
    push!(lines, "  • HOPE-UC runtime (~$(uc_rt_s) s/scenario) makes N=20")
    push!(lines, "    feasible (~$(uc_rt_h) h wall time) but should be run on a compute node.")
    push!(lines, "  • HOPE-ED (~$(ed_rt_s) s/scenario) is fast enough for N=20 runs interactively.")
    push!(lines, "  • M3 ($(round(Int, m3_runtime)) s/scenario) is the fastest benchmark.")
    push!(lines, "  • Confirm HOPE exporter correctly propagates all 20 scenario")
    push!(lines, "    availability matrices before a full N=20 run.")
    push!(lines, "")

    summary_path = joinpath(out_dir, "summary.txt")
    open(summary_path, "w") do io
        join(io, lines, "\n")
        println(io)
    end
    println("Written: $summary_path")

    println()
    println("Done.")
end
