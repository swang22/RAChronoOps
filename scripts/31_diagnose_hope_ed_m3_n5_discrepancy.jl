#!/usr/bin/env julia
# 31_diagnose_hope_ed_m3_n5_discrepancy.jl
#
# Diagnoses the N=5 HOPE-ED vs M3 load-shedding discrepancy for VRE120_base.
# Runs M3 for scenarios 1-5, loads HOPE-ED hourly data, compares hour-by-hour,
# and produces diagnostic CSVs + summary.txt.
#
# Usage:
#   julia --project=. scripts/31_diagnose_hope_ed_m3_n5_discrepancy.jl \
#     --case VRE120_base \
#     --scenario-subset 1,2,3,4,5 \
#     --n-scenarios 20 \
#     --seed 42 \
#     --hope-cases-dir exports/hope_model_cases \
#     --hope-dir results/hope_n5_pilot \
#     --out-dir results/hope_n5_pilot_diagnostics
#
# Outputs:
#   scenario_level_m3_vs_hope_ed.csv   -- per-scenario summary
#   hourly_m3_vs_hope_ed_loadshed.csv  -- per-hour comparison for discrepant hours
#   summary.txt                         -- answers to 4 diagnostic questions

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

# ── Helpers ───────────────────────────────────────────────────────────────────

"""Parse a sparse HOPE-ED hourly load-shedding CSV into a Dict{Int, Vector{Float64}}.
Returns: scenario_id => 8760-element vector of load shed MW."""
function load_hope_hourly(csv_path::String, case_name::String,
                           scen_ids::Vector{Int})::Dict{Int, Vector{Float64}}
    isfile(csv_path) || error("HOPE hourly CSV not found: $csv_path")
    df = CSV.read(csv_path, DataFrame)

    result = Dict{Int, Vector{Float64}}()
    for s in scen_ids
        folder = "RAChronoOps_$(case_name)_s$(lpad(s, 3, '0'))_ED"
        rows   = filter(r -> r.case_folder == folder, eachrow(df))
        vec    = zeros(Float64, 8760)
        for r in rows
            h = Int(r.hour)
            1 <= h <= 8760 && (vec[h] = Float64(r.load_shed_mw))
        end
        result[s] = vec
    end
    return result
end

"""Parse HOPE storage SOC from wide-format es_power_soc.csv.
Returns a 8760-element vector for the first storage row."""
function load_hope_soc(soc_path::String)::Union{Vector{Float64}, Nothing}
    isfile(soc_path) || return nothing
    df = CSV.read(soc_path, DataFrame)
    nrow(df) == 0 && return nothing
    row       = df[1, :]
    col_names = Set(propertynames(row))
    soc       = Vector{Float64}(undef, 8760)
    for h in 1:8760
        col    = Symbol("soc_h$h")
        soc[h] = col ∈ col_names ? Float64(row[col]) : NaN
    end
    return soc
end

"""Classify hours where either M3 or HOPE has load shedding."""
function classify_hours(m3_ls::Vector{Float64}, hope_ls::Vector{Float64};
                         tol::Float64 = 1e-6)
    rows = NamedTuple[]
    for h in 1:length(m3_ls)
        m = m3_ls[h]
        he = hope_ls[h]
        (m > tol || he > tol) || continue
        cls = if m > tol && he > tol
            "common"
        elseif m > tol
            "m3_only"
        else
            "hope_only"
        end
        push!(rows, (hour = h, m3 = m, hope = he, cls = cls))
    end
    return rows
end

# ── Main ──────────────────────────────────────────────────────────────────────

let
    kw = parse_cli(ARGS)

    case_name      = get(kw, "case",            "VRE120_base")
    scen_ids       = parse.(Int, split(get(kw, "scenario-subset", "1,2,3,4,5"), ","))
    n_scenarios    = parse(Int, get(kw, "n-scenarios",  "20"))
    seed           = parse(Int, get(kw, "seed",          "42"))
    hope_cases_dir = get(kw, "hope-cases-dir",
                         joinpath(@__DIR__, "..", "exports", "hope_model_cases"))
    hope_dir       = get(kw, "hope-dir",
                         joinpath(@__DIR__, "..", "results", "hope_n5_pilot"))
    out_dir        = get(kw, "out-dir",
                         joinpath(@__DIR__, "..", "results",
                                  "hope_n5_pilot_diagnostics"))

    mkpath(out_dir)

    println("="^72)
    println("HOPE-ED vs M3 N=5 Discrepancy Diagnostics — $(case_name)")
    println("="^72)
    println("  Scenarios   : $(join(scen_ids, ", "))")
    println("  N total     : $n_scenarios  (seed=$seed)")
    println("  HOPE dir    : $hope_dir")
    println("  Output dir  : $out_dir")
    println()

    # ── 1. Load system & generate scenarios ──────────────────────────────────
    data_dir = joinpath(@__DIR__, "..", "data_processed", "cases", case_name)
    isdir(data_dir) || error("Case data not found: $data_dir")

    println("Loading system …")
    system = load_system_data(data_dir)
    T = system.n_hours

    println("Generating $n_scenarios scenarios (seed=$seed) …")
    scenarios = generate_scenarios(system, n_scenarios, seed)
    avail = scenarios.availability[scen_ids, :, :]
    println("  Scenarios selected: $(join(scen_ids, ", "))")
    println()

    # ── 2. System diagnostics: precompute hourly available capacity ───────────
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre_h   = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
                 for h in 1:T]

    therm = thermal_generators(system)
    pmax  = Float64.(therm.pmax_mw)

    # ── 3. Run M3 ─────────────────────────────────────────────────────────────
    println("Running M3 on $(length(scen_ids)) scenarios …")
    base_cfg = SimConfig(n_scenarios = length(scen_ids), seed = seed)
    t0_m3 = time()
    m3_results = run_m3_ed_dispatch(system, avail, base_cfg)
    rt_m3 = time() - t0_m3
    @printf("  M3 done in %.1f s\n\n", rt_m3)

    # ── 4. Load HOPE-ED hourly data ───────────────────────────────────────────
    hope_hourly_path = joinpath(hope_dir, "hope_load_shed_hourly.csv")
    println("Loading HOPE-ED hourly data …")
    hope_ls_by_scen = load_hope_hourly(hope_hourly_path, case_name, scen_ids)

    # ── 5. Build per-scenario comparison ─────────────────────────────────────
    println("Comparing M3 vs HOPE-ED per scenario …")
    println()

    scen_summary_rows = NamedTuple[]
    all_hourly_rows   = NamedTuple[]

    for (idx, s_id) in enumerate(scen_ids)
        m3_r   = m3_results[idx]
        m3_ls  = m3_r.load_shed     # 8760-element Vector{Float64}
        m3_soc = m3_r.soc           # 8760-element Vector{Float64}
        hope_ls = hope_ls_by_scen[s_id]

        # Classify hours
        hr_rows = classify_hours(m3_ls, hope_ls)

        # Aggregate stats per scenario
        common_hrs     = filter(r -> r.cls == "common",    hr_rows)
        m3_only_hrs    = filter(r -> r.cls == "m3_only",   hr_rows)
        hope_only_hrs  = filter(r -> r.cls == "hope_only", hr_rows)

        m3_eue    = sum(m3_ls)
        hope_eue  = sum(hope_ls)
        m3_lolh   = count(v -> v > 1e-6, m3_ls)
        hope_lolh = count(v -> v > 1e-6, hope_ls)

        common_eue_m3   = isempty(common_hrs) ? 0.0 : sum(r.m3   for r in common_hrs)
        common_eue_hope = isempty(common_hrs) ? 0.0 : sum(r.hope for r in common_hrs)
        m3_only_eue     = isempty(m3_only_hrs)  ? 0.0 : sum(r.m3   for r in m3_only_hrs)
        hope_only_eue   = isempty(hope_only_hrs) ? 0.0 : sum(r.hope for r in hope_only_hrs)

        push!(scen_summary_rows, (
            scenario_id              = s_id,
            m3_lolh                  = m3_lolh,
            hope_ed_lolh             = hope_lolh,
            lolh_diff                = hope_lolh - m3_lolh,
            m3_eue                   = m3_eue,
            hope_ed_eue              = hope_eue,
            eue_diff                 = hope_eue - m3_eue,
            m3_max_shortfall         = isempty(m3_ls) ? 0.0 : maximum(m3_ls),
            hope_ed_max_shortfall    = isempty(hope_ls) ? 0.0 : maximum(hope_ls),
            max_shortfall_diff       = maximum(hope_ls) - maximum(m3_ls),
            common_shortage_hours    = length(common_hrs),
            m3_only_shortage_hours   = length(m3_only_hrs),
            hope_only_shortage_hours = length(hope_only_hrs),
            m3_only_eue              = m3_only_eue,
            hope_only_eue            = hope_only_eue,
            common_eue_m3            = common_eue_m3,
            common_eue_hope          = common_eue_hope,
        ))

        @printf("  s%03d  M3: LOLH=%2dh EUE=%8.2f MWh  HOPE-ED: LOLH=%2dh EUE=%8.2f MWh  Δ=%+.2f MWh\n",
                s_id, m3_lolh, m3_eue, hope_lolh, hope_eue, hope_eue - m3_eue)
        @printf("        common=%d h  m3_only=%d h  hope_only=%d h\n",
                length(common_hrs), length(m3_only_hrs), length(hope_only_hrs))

        # Collect hourly rows for all affected hours
        # Try to load HOPE SOC for this scenario
        soc_path  = joinpath(hope_cases_dir,
                             "RAChronoOps_$(case_name)_s$(lpad(s_id, 3, '0'))_ED",
                             "output", "es_power_soc.csv")
        hope_soc = load_hope_soc(soc_path)
        has_hope_soc = !isnothing(hope_soc)

        for r in hr_rows
            h = r.hour
            # Available thermal capacity for this scenario
            therm_avail = sum(Int(avail[idx, g, h]) * pmax[g]
                              for g in eachindex(pmax))
            hope_soc_h = has_hope_soc ? hope_soc[h] : NaN
            push!(all_hourly_rows, (
                scenario_id       = s_id,
                hour              = h,
                m3_load_shed_mw   = r.m3,
                hope_ed_load_shed_mw = r.hope,
                diff_hope_minus_m3   = r.hope - r.m3,
                classification    = r.cls,
                load_mw           = system.load_mw[h],
                vre_available_mw  = p_vre_h[h],
                thermal_available_mw = therm_avail,
                m3_soc_mwh        = m3_soc[h],
                hope_soc_mwh      = hope_soc_h,
                net_available_mw  = therm_avail + p_vre_h[h],  # excl storage
            ))
        end
    end

    # ── 6. Write CSVs ─────────────────────────────────────────────────────────
    scen_path  = joinpath(out_dir, "scenario_level_m3_vs_hope_ed.csv")
    CSV.write(scen_path, DataFrame(scen_summary_rows))
    println("\nWritten: scenario_level_m3_vs_hope_ed.csv  ($(length(scen_summary_rows)) rows)")

    hourly_path = joinpath(out_dir, "hourly_m3_vs_hope_ed_loadshed.csv")
    hourly_df   = isempty(all_hourly_rows) ? DataFrame() : DataFrame(all_hourly_rows)
    CSV.write(hourly_path, hourly_df)
    println("Written: hourly_m3_vs_hope_ed_loadshed.csv  ($(size(hourly_df, 1)) rows)")

    # ── 7. Build summary ──────────────────────────────────────────────────────
    println()

    # Q1: which scenario drives the discrepancy?
    scen_df = DataFrame(scen_summary_rows)

    mean_eue_diff = mean(scen_df.eue_diff)
    max_diff_idx  = argmax(scen_df.eue_diff)
    max_diff_scen = scen_df.scenario_id[max_diff_idx]
    max_diff_val  = scen_df.eue_diff[max_diff_idx]

    # Q2: concentrated in one hour/event?
    # Count hope-only hours per scenario
    hope_only_counts = scen_df.hope_only_shortage_hours
    m3_only_counts   = scen_df.m3_only_shortage_hours

    # Q3: energy difference structure
    total_hope_only_eue = sum(scen_df.hope_only_eue)
    total_m3_only_eue   = sum(scen_df.m3_only_eue)
    total_common_diff   = sum(scen_df.common_eue_hope .- scen_df.common_eue_m3)

    # Q4: check if HOPE-only hours show near-zero net available capacity
    hope_only_h = filter(r -> r.classification == "hope_only", eachrow(hourly_df))
    m3_only_h   = filter(r -> r.classification == "m3_only",   eachrow(hourly_df))

    function fmt(x, digits=2)
        isnan(x) ? "N/A" : string(round(x, digits=digits))
    end

    lines = String[]
    push!(lines, "HOPE-ED vs M3 Discrepancy Diagnostics — $(case_name)  N=$(length(scen_ids))")
    push!(lines, "Generated: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
    push!(lines, "Scenarios: $(join(scen_ids, ", ")) from n_scenarios=$n_scenarios, seed=$seed")
    push!(lines, "")
    push!(lines, "─"^70)
    push!(lines, "Per-scenario EUE differences (HOPE-ED minus M3):")
    push!(lines, "─"^70)
    for r in eachrow(scen_df)
        push!(lines,
            @sprintf("  s%03d: M3=%7.2f MWh  HOPE-ED=%7.2f MWh  D=%+7.2f MWh  common=%d h  m3_only=%d h  hope_only=%d h",
                     r.scenario_id, r.m3_eue, r.hope_ed_eue, r.eue_diff,
                     r.common_shortage_hours, r.m3_only_shortage_hours,
                     r.hope_only_shortage_hours))
    end
    push!(lines, @sprintf("  MEAN: M3=%7.2f MWh  HOPE-ED=%7.2f MWh  Δ=%+7.2f MWh",
                           mean(scen_df.m3_eue), mean(scen_df.hope_ed_eue),
                           mean_eue_diff))
    push!(lines, "")

    # Q1
    push!(lines, "─"^70)
    push!(lines, "Q1. Which scenario drives the +$(fmt(mean_eue_diff)) MWh HOPE-ED EUE difference?")
    push!(lines, "")
    all_differ = all(r.eue_diff > 0.0 for r in eachrow(scen_df))
    all_positive = all(r.eue_diff >= -1e-3 for r in eachrow(scen_df))
    if all_positive
        push!(lines, "  All $(length(scen_ids)) scenarios show non-negative HOPE-ED EUE excess.")
        push!(lines, "  Largest single-scenario difference: s$(lpad(max_diff_scen,3,'0')) " *
                     "(Δ=$(fmt(max_diff_val)) MWh, $(round(100*max_diff_val/sum(scen_df.eue_diff),digits=1))% of total).")
        push!(lines, "  Pattern: $(join([@sprintf("s%03d:+%.1f",r.scenario_id,r.eue_diff) for r in eachrow(scen_df)], "  ")).")
        push!(lines, "  The difference is SYSTEMATIC — present in every scenario — rather than")
        push!(lines, "  driven by one outlier scenario.")
    else
        push!(lines, "  Scenario s$(lpad(max_diff_scen,3,'0')) has the largest difference ($(fmt(max_diff_val)) MWh).")
        neg_scens = filter(r -> r.eue_diff < -1e-3, eachrow(scen_df))
        !isempty(neg_scens) &&
            push!(lines, "  Note: $(length(neg_scens)) scenario(s) have M3 EUE > HOPE-ED EUE.")
    end
    push!(lines, "")

    # Q2
    push!(lines, "─"^70)
    push!(lines, "Q2. Is the difference concentrated in one hour/event?")
    push!(lines, "")
    total_hope_only_h = sum(hope_only_counts)
    total_m3_only_h   = sum(m3_only_counts)
    push!(lines,
        "  Across all scenarios: $(total_hope_only_h) HOPE-only hours, " *
        "$(total_m3_only_h) M3-only hours.")
    push!(lines,
        "  HOPE-only EUE (energy in hours M3 has no shedding): $(fmt(total_hope_only_eue)) MWh")
    push!(lines,
        "  M3-only EUE (energy in hours HOPE has no shedding): $(fmt(total_m3_only_eue)) MWh")
    push!(lines,
        "  Common hours EUE difference (same hours, diff magnitudes): " *
        "$(fmt(total_common_diff)) MWh")
    net_diff = total_hope_only_eue - total_m3_only_eue + total_common_diff
    push!(lines,
        "  Net: $(fmt(total_hope_only_eue)) - $(fmt(total_m3_only_eue)) + " *
        "$(fmt(total_common_diff)) = $(fmt(net_diff)) MWh  (should ≈ $(fmt(mean_eue_diff * length(scen_ids))))")
    push!(lines, "")

    # Q3
    push!(lines, "─"^70)
    push!(lines, "Q3. Is it an event-structure difference or an actual energy difference?")
    push!(lines, "")
    if abs(total_common_diff) < 1.0 && total_hope_only_eue > 1.0
        push!(lines,
            "  EVENT-STRUCTURE: Common hours show negligible EUE difference " *
            "($(fmt(total_common_diff)) MWh).")
        push!(lines,
            "  HOPE-ED has $(total_hope_only_h) extra shortage hours that M3 does not have,")
        push!(lines,
            "  contributing $(fmt(total_hope_only_eue)) MWh of additional EUE.")
    elseif total_hope_only_eue > 1.0 && abs(total_common_diff) > 1.0
        push!(lines,
            "  BOTH: HOPE-ED has $(total_hope_only_h) extra shortage hours " *
            "($(fmt(total_hope_only_eue)) MWh) AND common hours differ " *
            "($(fmt(total_common_diff)) MWh).")
    else
        push!(lines,
            "  MAGNITUDE: No HOPE-only hours; differences occur within shared shortage hours.")
    end
    push!(lines, "")

    # Q4: data mapping / root cause
    push!(lines, "─"^70)
    push!(lines, "Q4. Does this point to a data mapping issue or model formulation difference?")
    push!(lines, "")

    # Examine HOPE-only hours
    if !isempty(hope_only_h)
        mean_load_hope_only = mean(r.load_mw for r in hope_only_h)
        mean_net_avail_hope_only = mean(r.net_available_mw for r in hope_only_h)
        mean_m3soc_hope_only = mean(r.m3_soc_mwh for r in hope_only_h)
        mean_gap = mean(r.load_mw - r.net_available_mw for r in hope_only_h)
        push!(lines, "  HOPE-only shortage hours diagnostic ($(length(hope_only_h)) hour-obs):")
        push!(lines, @sprintf("    Mean load              = %7.1f MW", mean_load_hope_only))
        push!(lines, @sprintf("    Mean net avail (no stor)= %7.1f MW", mean_net_avail_hope_only))
        push!(lines, @sprintf("    Mean generation gap     = %7.1f MW  (>0 means storage could fill)",
                              mean_gap))
        push!(lines, @sprintf("    Mean M3 SOC at these hrs= %7.1f MWh", mean_m3soc_hope_only))
        push!(lines, "")
        # Check if M3 SOC is non-zero at HOPE-only hours (M3 used storage, HOPE didn't)
        nonzero_soc = count(r -> r.m3_soc_mwh > 100.0, hope_only_h)
        if nonzero_soc > 0
            push!(lines,
                "  In $(nonzero_soc)/$(length(hope_only_h)) HOPE-only hours, M3 SOC > 100 MWh.")
            push!(lines, "  → M3 had storage available at these hours but HOPE did not dispatch storage.")
        else
            push!(lines,
                "  In $(nonzero_soc)/$(length(hope_only_h)) HOPE-only hours, M3 SOC > 100 MWh.")
            push!(lines, "  → M3 storage was depleted; HOPE-only hours come from extra HOPE storage depletion.")
        end
    end

    if !isempty(m3_only_h)
        mean_m3soc_m3_only = mean(r.m3_soc_mwh for r in m3_only_h)
        push!(lines, "  M3-only shortage hours: $(length(m3_only_h)) hours,")
        push!(lines, @sprintf("    mean M3 SOC = %.1f MWh (nearly depleted if << 1966)", mean_m3soc_m3_only))
        push!(lines, "")
    end

    # Check HOPE terminal SOC constraint
    push!(lines, "  ROOT CAUSE HYPOTHESIS:")
    push!(lines, "  HOPE enforces both a cyclic SOC and a fixed terminal SOC = 50% capacity")
    push!(lines, "  (PCM.jl lines 2245-2257: SDBe_st_con + SDBe_ed_con).")
    push!(lines, "  HOPE terminal constraint: soc[s, H[end]] = 0.5 × SECAP = 1966 MWh.")
    push!(lines, "  HOPE cyclic constraint:   soc[s, 1] = soc[s, H[end]] = 1966 MWh.")
    push!(lines, "  The cyclic constraint fixes soc[s,1] = 1966 but has NO transition")
    push!(lines, "  equation for hour 1 (SoC_con applies only to h in setdiff(H, [1])).")
    push!(lines, "  This means HOPE storage dispatch in hour 1 is decoupled from the SOC:")
    push!(lines, "  the LP can inject/absorb up to ±983 MW in hour 1 without changing SOC.")
    push!(lines, "  M3 (RAChronoOps) also uses cyclic SOC (config.cyclic_soc=true) with")
    push!(lines, "  initial_soc=1966 MWh, but its hour-1 SOC is constrained by the transition")
    push!(lines, "  equation: soc[1] = initial_soc + eta_ch*charge[1] - discharge[1]/eta_dis.")
    push!(lines, "  RECOMMENDATION: Investigate whether LP degeneracy (multiple optimal solutions)")
    push!(lines, "  at the HOPE-only shortage hours causes different storage dispatch patterns.")
    push!(lines, "  The consistent ~106.6 MWh difference per scenario suggests a systematic")
    push!(lines, "  offset, possibly linked to one generator, or the hour-1 SOC formulation.")
    push!(lines, "")

    push!(lines, "─"^70)
    push!(lines, "HOPE-only shortage hours detail:")
    push!(lines, "─"^70)
    if !isempty(hope_only_h)
        push!(lines, @sprintf("  %-6s %-5s %-10s %-12s %-14s %-12s %-12s %-10s",
                              "Scen", "Hour", "LoadShed", "Load", "Net Avail",
                              "Gap(kW>0)", "M3_SOC", "HOPE_SOC"))
        for r in sort(collect(hope_only_h), by=rr->rr.scenario_id*10000+rr.hour)
            push!(lines, @sprintf("  s%03d  h%05d  %+9.2f  %9.1f  %11.1f  %10.1f  %9.1f  %9s",
                                  r.scenario_id, r.hour,
                                  r.hope_ed_load_shed_mw,
                                  r.load_mw, r.net_available_mw,
                                  r.load_mw - r.net_available_mw,
                                  r.m3_soc_mwh,
                                  isnan(r.hope_soc_mwh) ? "N/A" : string(round(r.hope_soc_mwh, digits=1))))
        end
    else
        push!(lines, "  (none)")
    end
    push!(lines, "")
    push!(lines, "─"^70)
    push!(lines, "M3-only shortage hours detail:")
    push!(lines, "─"^70)
    if !isempty(m3_only_h)
        push!(lines, @sprintf("  %-6s %-5s %-10s %-12s %-14s %-12s %-12s %-10s",
                              "Scen", "Hour", "LoadShed", "Load", "Net Avail",
                              "Gap(kW>0)", "M3_SOC", "HOPE_SOC"))
        for r in sort(collect(m3_only_h), by=rr->rr.scenario_id*10000+rr.hour)
            push!(lines, @sprintf("  s%03d  h%05d  %+9.2f  %9.1f  %11.1f  %10.1f  %9.1f  %9s",
                                  r.scenario_id, r.hour,
                                  r.m3_load_shed_mw,
                                  r.load_mw, r.net_available_mw,
                                  r.load_mw - r.net_available_mw,
                                  r.m3_soc_mwh,
                                  isnan(r.hope_soc_mwh) ? "N/A" : string(round(r.hope_soc_mwh, digits=1))))
        end
    else
        push!(lines, "  (none)")
    end

    summary_path = joinpath(out_dir, "summary.txt")
    open(summary_path, "w") do io
        join(io, lines, "\n")
        println(io)
    end
    println("Written: summary.txt")

    println()
    println("Done.")
end
