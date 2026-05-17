#!/usr/bin/env julia
# 22_diagnose_m1c_m3_soc_and_charging.jl
#
# Diagnoses why M1c (emergency-only) matches M3 (full-year ED LP) exactly in
# LOLH and EUE at N=20 for the three priority VRE cases.
#
# Hypotheses tested:
#   A. Storage is full (or nearly full) before every scarcity event.
#   B. M1c relies materially on charging from thermal headroom (not just VRE surplus).
#   C. M1c and M3 have nearly identical SOC trajectories, not just matching outcomes.
#   D. The match is a fragile artifact of the current scenarios/assumptions.
#
# Outputs (results/m1c_diagnostics/<subdir>/):
#   m1c_m3_soc_comparison.csv         — per case/scenario SOC difference stats
#   m1c_charging_source_proxy.csv     — per case/scenario charging source breakdown
#   shortage_event_soc_detail.csv     — per shortage event SOC at start/during
#   summary.txt
#   run_<timestamp>.log
#
# Usage:
#   julia --project=. scripts/22_diagnose_m1c_m3_soc_and_charging.jl [options]
#
# Options:
#   --n-scenarios N      Number of MC scenarios   (default: 20)
#   --seed S             RNG seed                 (default: 42)
#   --cases C1,C2,...    Comma-separated cases
#   --out-subdir DIR     Subdirectory name

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

const PRIORITY_CASES = ["VRE120_base", "VRE120_bal15", "VRE120_wind_hvy"]
const ALL_VRE120_CASES = [
    "VRE120_base", "VRE120_bal15", "VRE120_bal20",
    "VRE120_bal30", "VRE120_solar_hvy", "VRE120_wind_hvy",
]

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional argument: $arg")
        key = arg[3:end]
        i + 1 <= length(args) && !startswith(args[i+1], "--") ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]; i += 2
    end
    return kw
end

# ── helpers ───────────────────────────────────────────────────────────────────

function find_shortage_events(load_shed::Vector{Float64})::Vector{Tuple{Int,Int}}
    events   = Tuple{Int,Int}[]
    in_event = false
    start_h  = 0
    for h in 1:length(load_shed)
        if load_shed[h] > 0.0
            if !in_event
                in_event = true
                start_h  = h
            end
        else
            if in_event
                push!(events, (start_h, h - 1))
                in_event = false
            end
        end
    end
    in_event && push!(events, (start_h, length(load_shed)))
    return events
end

# ── main ──────────────────────────────────────────────────────────────────────
let
    kw = parse_cli(ARGS)

    n_scenarios  = parse(Int, get(kw, "n-scenarios", "20"))
    seed         = parse(Int, get(kw, "seed",         "42"))

    cases_to_run = if haskey(kw, "cases")
        requested = split(kw["cases"], ",")
        for c in requested
            c in ALL_VRE120_CASES ||
                error("Unknown case: $c (valid: $(join(ALL_VRE120_CASES, ", ")))")
        end
        String.(requested)
    else
        PRIORITY_CASES
    end

    project_root = joinpath(@__DIR__, "..")
    cases_root   = joinpath(project_root, "data_processed", "cases")
    base_out_dir = joinpath(project_root, "results", "m1c_diagnostics")
    abbr         = join([replace(c, "VRE120_" => "") for c in cases_to_run], "-")
    subdir       = get(kw, "out-subdir", "$(abbr)_n$(n_scenarios)")
    out_dir      = joinpath(base_out_dir, subdir)
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "M1c vs M3 SOC and charging diagnostics"
    @info "n=$n_scenarios | seed=$seed"
    @info "Cases: $(join(cases_to_run, ", "))"
    @info "Output: $out_dir"

    soc_rows     = NamedTuple[]
    charge_rows  = NamedTuple[]
    event_rows   = NamedTuple[]

    nan = NaN

    total_t0 = time()

    for cname in cases_to_run
        cdir = joinpath(cases_root, cname)
        if !isdir(cdir)
            @warn "Case directory not found — skipping: $cdir"
            continue
        end

        @info "── Case: $cname ──────────────────────────────────────────────"
        sys       = load_system_data(cdir)
        crn_cfg   = SimConfig(; n_scenarios, seed)
        scenarios = generate_scenarios(sys, crn_cfg)
        avail     = scenarios.availability   # [scenario, gen, hour]

        n_hours      = sys.n_hours
        total_energy = sum(sys.storage.energy_mwh)

        # ── pre-compute VRE and p_vre per hour ────────────────────────────────
        wind_cap  = wind_capacity_mw(sys)
        solar_cap = solar_capacity_mw(sys)
        p_vre = [wind_cap * sys.wind_cf[h] + solar_cap * sys.solar_cf[h]
                 for h in 1:n_hours]

        # ── thermal pmax vector ───────────────────────────────────────────────
        therm   = thermal_generators(sys)
        n_therm = size(therm, 1)
        pmax    = Float64.(therm.pmax_mw)

        # ── run M1c ───────────────────────────────────────────────────────────
        @info "  running M1c..."
        t0       = time()
        m1c_cfg  = SimConfig(; n_scenarios, seed)
        r_m1c    = run_m1c_emergency_only(sys, scenarios, m1c_cfg)
        m1c_rt   = time() - t0
        @info "  M1c done in $(round(m1c_rt, digits=1)) s"

        # ── run M3 ────────────────────────────────────────────────────────────
        @info "  running M3..."
        t0       = time()
        m3_cfg   = SimConfig(; n_scenarios, seed)
        r_m3     = run_m3_ed_dispatch(sys, scenarios, m3_cfg)
        m3_rt    = time() - t0
        @info "  M3 done in $(round(m3_rt, digits=1)) s"

        # ── per-scenario analysis ──────────────────────────────────────────────
        for s in 1:n_scenarios
            rc = r_m1c[s]
            rm = r_m3[s]

            # ── SOC comparison ────────────────────────────────────────────────
            soc_diff = abs.(rc.soc .- rm.soc)
            max_soc_diff  = maximum(soc_diff)
            mean_soc_diff = mean(soc_diff)

            # shortage hours: union of M1c and M3 positive-shed hours
            shed_hours = findall(h -> rc.load_shed[h] > 0.0 || rm.load_shed[h] > 0.0, 1:n_hours)
            soc_diff_at_shortage = isempty(shed_hours) ? nan :
                                   mean(soc_diff[h] for h in shed_hours)

            # minimum SOC before first shortage event (M1c perspective)
            m1c_events = find_shortage_events(rc.load_shed)
            m3_events  = find_shortage_events(rm.load_shed)

            first_short_m1c = isempty(m1c_events) ? n_hours + 1 : m1c_events[1][1]
            first_short_m3  = isempty(m3_events)  ? n_hours + 1 : m3_events[1][1]

            m1c_soc_min_before = first_short_m1c > 1 ?
                minimum(rc.soc[h] for h in 1:(first_short_m1c - 1)) : nan
            m3_soc_min_before  = first_short_m3  > 1 ?
                minimum(rm.soc[h] for h in 1:(first_short_m3  - 1)) : nan

            m1c_soc_at_first = isempty(m1c_events) ? nan : rc.soc[m1c_events[1][1]]
            m3_soc_at_first  = isempty(m3_events)  ? nan : rm.soc[m3_events[1][1]]

            hours_m1c_full   = count(h -> rc.soc[h] >= total_energy - 1e-6, 1:n_hours)
            hours_m3_full    = count(h -> rm.soc[h] >= total_energy - 1e-6, 1:n_hours)
            hours_m1c_empty  = count(h -> rc.soc[h] <= 1e-6, 1:n_hours)
            hours_m3_empty   = count(h -> rm.soc[h] <= 1e-6, 1:n_hours)

            push!(soc_rows, (
                case_name                      = cname,
                scenario_id                    = s,
                m1c_lolh                       = Float64(count(ls -> ls > 0.0, rc.load_shed)),
                m3_lolh                        = Float64(count(ls -> ls > 0.0, rm.load_shed)),
                m1c_eue                        = sum(rc.load_shed),
                m3_eue                         = sum(rm.load_shed),
                max_abs_soc_diff_mwh           = max_soc_diff,
                mean_abs_soc_diff_mwh          = mean_soc_diff,
                soc_diff_at_shortage_hours_mean_mwh = soc_diff_at_shortage,
                m1c_soc_min_before_shortage_mwh    = m1c_soc_min_before,
                m3_soc_min_before_shortage_mwh     = m3_soc_min_before,
                m1c_soc_at_first_shortage_mwh      = m1c_soc_at_first,
                m3_soc_at_first_shortage_mwh       = m3_soc_at_first,
                hours_m1c_full_soc             = hours_m1c_full,
                hours_m3_full_soc              = hours_m3_full,
                hours_m1c_empty_soc            = hours_m1c_empty,
                hours_m3_empty_soc             = hours_m3_empty,
            ))

            # ── charging source proxy ─────────────────────────────────────────
            # Compute thermal_available per hour for this scenario
            m1c_chg  = rc.storage_charge
            m3_chg   = rm.storage_charge

            m1c_total_chg  = sum(m1c_chg)
            m3_total_chg   = sum(m3_chg)

            m1c_vre_surplus_chg      = 0.0
            m1c_therm_headroom_chg   = 0.0
            m3_vre_surplus_chg       = 0.0
            m3_vre_not_surplus_chg   = 0.0

            for h in 1:n_hours
                load_h = sys.load_mw[h]
                vre_h  = p_vre[h]

                # thermal available this scenario/hour
                therm_avail = zero(Float64)
                for g in 1:n_therm
                    therm_avail += pmax[g] * avail[s, g, h]
                end

                vre_surplus        = vre_h > load_h
                thermal_headroom   = !vre_surplus && (therm_avail + vre_h) > load_h

                if m1c_chg[h] > 1e-9
                    if vre_surplus
                        m1c_vre_surplus_chg    += m1c_chg[h]
                    elseif thermal_headroom
                        m1c_therm_headroom_chg += m1c_chg[h]
                    end
                end

                if m3_chg[h] > 1e-9
                    if vre_surplus
                        m3_vre_surplus_chg     += m3_chg[h]
                    else
                        m3_vre_not_surplus_chg += m3_chg[h]
                    end
                end
            end

            share_therm = m1c_total_chg > 1e-9 ?
                          m1c_therm_headroom_chg / m1c_total_chg : nan

            push!(charge_rows, (
                case_name                              = cname,
                scenario_id                            = s,
                total_m1c_charge_mwh                   = m1c_total_chg,
                m1c_charge_when_vre_surplus_mwh        = m1c_vre_surplus_chg,
                m1c_charge_when_thermal_headroom_mwh   = m1c_therm_headroom_chg,
                share_charge_thermal_headroom_proxy    = share_therm,
                total_m3_charge_mwh                    = m3_total_chg,
                m3_charge_when_vre_surplus_mwh         = m3_vre_surplus_chg,
                m3_charge_when_vre_not_surplus_mwh     = m3_vre_not_surplus_chg,
            ))

            # ── shortage event detail ─────────────────────────────────────────
            # Detect events from M3 (benchmark) and report both M1c and M3 metrics
            for (ev_start, ev_end) in m3_events
                soc_m1c_start = ev_start > 1 ? rc.soc[ev_start - 1] : sum(sys.storage.initial_soc_mwh)
                soc_m3_start  = ev_start > 1 ? rm.soc[ev_start - 1] : sum(sys.storage.initial_soc_mwh)
                soc_m1c_min   = minimum(rc.soc[h] for h in ev_start:ev_end)
                soc_m3_min    = minimum(rm.soc[h] for h in ev_start:ev_end)
                eue_m1c_ev    = sum(rc.load_shed[h] for h in ev_start:ev_end)
                eue_m3_ev     = sum(rm.load_shed[h] for h in ev_start:ev_end)

                push!(event_rows, (
                    case_name              = cname,
                    scenario_id            = s,
                    event_start_hour       = ev_start,
                    event_end_hour         = ev_end,
                    event_duration_h       = ev_end - ev_start + 1,
                    m1c_soc_at_event_start = soc_m1c_start,
                    m3_soc_at_event_start  = soc_m3_start,
                    m1c_soc_min_during     = soc_m1c_min,
                    m3_soc_min_during      = soc_m3_min,
                    m1c_eue_event          = eue_m1c_ev,
                    m3_eue_event           = eue_m3_ev,
                ))
            end

            # Also capture M1c-only events (events M1c has that M3 doesn't)
            for (ev_start, ev_end) in m1c_events
                # skip if this event overlaps any M3 event
                overlaps = any(ev_start <= e[2] && ev_end >= e[1] for e in m3_events)
                overlaps && continue

                soc_m1c_start = ev_start > 1 ? rc.soc[ev_start - 1] : sum(sys.storage.initial_soc_mwh)
                soc_m3_start  = ev_start > 1 ? rm.soc[ev_start - 1] : sum(sys.storage.initial_soc_mwh)
                soc_m1c_min   = minimum(rc.soc[h] for h in ev_start:ev_end)
                soc_m3_min    = minimum(rm.soc[h] for h in ev_start:ev_end)
                eue_m1c_ev    = sum(rc.load_shed[h] for h in ev_start:ev_end)
                eue_m3_ev     = sum(rm.load_shed[h] for h in ev_start:ev_end)

                push!(event_rows, (
                    case_name              = cname,
                    scenario_id            = s,
                    event_start_hour       = ev_start,
                    event_end_hour         = ev_end,
                    event_duration_h       = ev_end - ev_start + 1,
                    m1c_soc_at_event_start = soc_m1c_start,
                    m3_soc_at_event_start  = soc_m3_start,
                    m1c_soc_min_during     = soc_m1c_min,
                    m3_soc_min_during      = soc_m3_min,
                    m1c_eue_event          = eue_m1c_ev,
                    m3_eue_event           = eue_m3_ev,
                ))
            end
        end # scenarios

        @info "  Case $cname complete."
    end # cases

    total_rt = time() - total_t0
    @info "Total runtime: $(round(total_rt, digits=1)) s"

    soc_df    = DataFrame(soc_rows)
    charge_df = DataFrame(charge_rows)
    event_df  = isempty(event_rows) ? DataFrame() : DataFrame(event_rows)

    soc_path    = joinpath(out_dir, "m1c_m3_soc_comparison.csv")
    charge_path = joinpath(out_dir, "m1c_charging_source_proxy.csv")
    event_path  = joinpath(out_dir, "shortage_event_soc_detail.csv")
    summary_path = joinpath(out_dir, "summary.txt")

    CSV.write(soc_path,    soc_df)
    CSV.write(charge_path, charge_df)
    isempty(event_df) || CSV.write(event_path, event_df)

    # ── summary.txt ────────────────────────────────────────────────────────────
    open(summary_path, "w") do io
        sep = "=" ^ 80
        println(io, sep)
        println(io, "M1c vs M3 SOC and Charging Diagnostic Summary")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d\n", n_scenarios, seed)
        @printf(io, "Cases: %s\n", join(cases_to_run, ", "))
        println(io, sep)
        println(io)

        # ── SOC comparison summary ─────────────────────────────────────────────
        println(io, "SOC trajectory comparison (M1c vs M3)")
        println(io, "-" ^ 80)
        @printf(io, "  %-22s %12s %12s %12s %12s\n",
                "Case", "mean_soc_diff", "max_soc_diff", "pct_m1c_full", "pct_m3_full")
        println(io, "  " * "-" ^ 74)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, soc_df)
            isempty(sub) && continue
            mean_diff = mean(sub.mean_abs_soc_diff_mwh)
            max_diff  = mean(sub.max_abs_soc_diff_mwh)
            pct_m1c_full = mean(sub.hours_m1c_full_soc) / 8760 * 100
            pct_m3_full  = mean(sub.hours_m3_full_soc)  / 8760 * 100
            @printf(io, "  %-22s %12.3f %12.3f %11.1f%% %11.1f%%\n",
                    cname, mean_diff, max_diff, pct_m1c_full, pct_m3_full)
        end
        println(io)

        # ── SOC at first shortage event ────────────────────────────────────────
        println(io, "SOC at first shortage event (M1c vs M3)")
        println(io, "-" ^ 80)
        @printf(io, "  %-22s %14s %14s %14s\n",
                "Case", "m1c_soc_first_h", "m3_soc_first_h", "total_energy")
        println(io, "  " * "-" ^ 68)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname && !isnan(r.m1c_soc_at_first_shortage_mwh), soc_df)
            isempty(sub) && continue
            cdir   = joinpath(cases_root, cname)
            isdir(cdir) || continue
            sys_te = load_system_data(cdir)
            te     = sum(sys_te.storage.energy_mwh)
            mean_m1c = mean(sub.m1c_soc_at_first_shortage_mwh)
            mean_m3  = mean(sub.m3_soc_at_first_shortage_mwh)
            @printf(io, "  %-22s %14.1f %14.1f %14.1f\n",
                    cname, mean_m1c, mean_m3, te)
        end
        println(io)

        # ── charging source proxy ──────────────────────────────────────────────
        println(io, "Charging source proxy (M1c)")
        println(io, "-" ^ 80)
        @printf(io, "  %-22s %14s %14s %14s %14s\n",
                "Case", "total_chg_MWh", "vre_surplus_%", "therm_hdroom_%", "other_%")
        println(io, "  " * "-" ^ 74)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, charge_df)
            isempty(sub) && continue
            total   = mean(sub.total_m1c_charge_mwh)
            vre_pct = total > 0 ? 100.0 * mean(sub.m1c_charge_when_vre_surplus_mwh)      / total : nan
            thm_pct = total > 0 ? 100.0 * mean(sub.m1c_charge_when_thermal_headroom_mwh) / total : nan
            oth_pct = isnan(vre_pct) || isnan(thm_pct) ? nan : max(0.0, 100.0 - vre_pct - thm_pct)
            @printf(io, "  %-22s %14.1f %14.1f %14.1f %14.1f\n",
                    cname, total, vre_pct, thm_pct, oth_pct)
        end
        println(io)

        # M3 charging source
        println(io, "Charging source proxy (M3)")
        println(io, "-" ^ 80)
        @printf(io, "  %-22s %14s %14s %14s\n",
                "Case", "total_chg_MWh", "vre_surplus_%", "no_surplus_%")
        println(io, "  " * "-" ^ 64)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, charge_df)
            isempty(sub) && continue
            total   = mean(sub.total_m3_charge_mwh)
            vre_pct = total > 0 ? 100.0 * mean(sub.m3_charge_when_vre_surplus_mwh)     / total : nan
            nov_pct = total > 0 ? 100.0 * mean(sub.m3_charge_when_vre_not_surplus_mwh) / total : nan
            @printf(io, "  %-22s %14.1f %14.1f %14.1f\n",
                    cname, total, vre_pct, nov_pct)
        end
        println(io)

        # ── shortage event SOC analysis ────────────────────────────────────────
        if !isempty(event_df)
            println(io, "Shortage event SOC at event start (M3-detected events)")
            println(io, "-" ^ 80)
            @printf(io, "  %-22s %10s %14s %14s %10s %10s\n",
                    "Case", "n_events", "m1c_soc_start", "m3_soc_start", "m1c_soc%", "m3_soc%")
            println(io, "  " * "-" ^ 74)
            for cname in cases_to_run
                sub  = filter(r -> r.case_name == cname, event_df)
                isempty(sub) && continue
                cdir = joinpath(cases_root, cname)
                isdir(cdir) || continue
                sys_te = load_system_data(cdir)
                te     = sum(sys_te.storage.energy_mwh)
                n_ev   = size(sub, 1)
                ms     = mean(sub.m1c_soc_at_event_start)
                m3s    = mean(sub.m3_soc_at_event_start)
                @printf(io, "  %-22s %10d %14.1f %14.1f %9.1f%% %9.1f%%\n",
                        cname, n_ev, ms, m3s, 100.0 * ms / te, 100.0 * m3s / te)
            end
            println(io)
        end

        # ── Research questions ─────────────────────────────────────────────────
        println(io, sep)
        println(io, "Research questions")
        println(io, sep)
        println(io)

        # Q1: Is M1c storage full before shortage events?
        println(io, "Q1. Is M1c storage full (or near-full) before shortage events?")
        println(io)
        if !isempty(event_df)
            for cname in cases_to_run
                sub  = filter(r -> r.case_name == cname, event_df)
                isempty(sub) && continue
                cdir = joinpath(cases_root, cname)
                isdir(cdir) || continue
                sys_te = load_system_data(cdir)
                te     = sum(sys_te.storage.energy_mwh)
                mean_soc_start = mean(sub.m1c_soc_at_event_start)
                frac           = mean_soc_start / te
                @printf(io, "  %s: mean M1c SOC at event start = %.1f MWh / %.1f MWh (%.1f%%)\n",
                        cname, mean_soc_start, te, 100.0 * frac)
                if frac >= 0.95
                    println(io, "    → Storage is nearly full (≥95%) before events. Hypothesis A SUPPORTED.")
                elseif frac >= 0.75
                    println(io, "    → Storage is mostly full (75–95%) before events. Hypothesis A PARTIALLY supported.")
                else
                    println(io, "    → Storage is NOT full (<75%) before events. Hypothesis A NOT supported.")
                end
            end
        else
            println(io, "  No shortage events found in any scenario.")
        end
        println(io)

        # Q2: Does M1c rely materially on thermal-headroom charging?
        println(io, "Q2. Does M1c rely materially on thermal-headroom charging?")
        println(io)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, charge_df)
            isempty(sub) && continue
            thm_shares = filter(!isnan, sub.share_charge_thermal_headroom_proxy)
            isempty(thm_shares) && continue
            thm_mean = mean(thm_shares)
            @printf(io, "  %s: thermal-headroom charging share = %.1f%%\n",
                    cname, 100.0 * thm_mean)
            if thm_mean >= 0.20
                println(io, "    → Thermal headroom is a material charging source (≥20%). Hypothesis B SUPPORTED.")
            elseif thm_mean >= 0.05
                println(io, "    → Thermal headroom is a minor charging source (5–20%). Hypothesis B WEAKLY supported.")
            else
                println(io, "    → M1c charges almost entirely from VRE surplus (<5% thermal headroom). Hypothesis B NOT supported.")
            end
        end
        println(io)

        # Q3: Are M1c and M3 SOC trajectories similar or only shortage outcomes similar?
        println(io, "Q3. Are M1c and M3 SOC trajectories similar, or only shortage outcomes similar?")
        println(io)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, soc_df)
            isempty(sub) && continue
            mean_diff = mean(sub.mean_abs_soc_diff_mwh)
            max_diff  = mean(sub.max_abs_soc_diff_mwh)
            cdir = joinpath(cases_root, cname)
            isdir(cdir) || continue
            sys_te = load_system_data(cdir)
            te     = sum(sys_te.storage.energy_mwh)
            @printf(io, "  %s: mean |soc_m1c - soc_m3| = %.2f MWh  max = %.2f MWh  (total_energy=%.1f MWh)\n",
                    cname, mean_diff, max_diff, te)
            rel = mean_diff / te
            if rel < 0.02
                println(io, "    → Trajectories are nearly identical (<2% of capacity difference). Hypothesis C SUPPORTED.")
            elseif rel < 0.10
                println(io, "    → Moderate trajectory difference (2–10%). Hypothesis C PARTIALLY supported.")
            else
                println(io, "    → Large trajectory difference (>10%) — outcomes match despite divergent paths. Hypothesis C NOT supported.")
            end
        end
        println(io)

        # Q4: Does M3 also charge in hours without VRE surplus?
        println(io, "Q4. Does M3 also charge in hours without VRE surplus?")
        println(io)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, charge_df)
            isempty(sub) && continue
            total_m3 = mean(sub.total_m3_charge_mwh)
            no_surp  = mean(sub.m3_charge_when_vre_not_surplus_mwh)
            pct      = total_m3 > 0 ? 100.0 * no_surp / total_m3 : nan
            @printf(io, "  %s: M3 charges %.1f MWh without VRE surplus (%.1f%% of total M3 charging)\n",
                    cname, no_surp, pct)
            if !isnan(pct) && pct >= 10.0
                println(io, "    → M3 materially charges from non-VRE surplus hours (≥10%). M3 uses thermal headroom too.")
            elseif !isnan(pct) && pct >= 2.0
                println(io, "    → M3 charges occasionally without VRE surplus (2–10%).")
            else
                println(io, "    → M3 charges almost exclusively during VRE surplus hours (<2% otherwise).")
            end
        end
        println(io)

        # Q5: Structural or case-specific?
        println(io, "Q5. Is the exact M1c = M3 LOLH match likely structural or case-specific?")
        println(io)

        # Gather evidence
        all_mean_diffs  = Float64[]
        all_thm_shares  = Float64[]
        all_soc_fracs   = Float64[]

        for cname in cases_to_run
            sub_s = filter(r -> r.case_name == cname, soc_df)
            if !isempty(sub_s)
                push!(all_mean_diffs, mean(sub_s.mean_abs_soc_diff_mwh))
            end
            sub_c = filter(r -> r.case_name == cname, charge_df)
            if !isempty(sub_c)
                thm_vals = filter(!isnan, sub_c.share_charge_thermal_headroom_proxy)
                isempty(thm_vals) || push!(all_thm_shares, mean(thm_vals))
            end
            if !isempty(event_df)
                sub_e = filter(r -> r.case_name == cname, event_df)
                if !isempty(sub_e)
                    cdir = joinpath(cases_root, cname)
                    if isdir(cdir)
                        sys_te = load_system_data(cdir)
                        te     = sum(sys_te.storage.energy_mwh)
                        push!(all_soc_fracs, mean(sub_e.m1c_soc_at_event_start) / te)
                    end
                end
            end
        end

        full_before  = !isempty(all_soc_fracs)  && mean(all_soc_fracs)  >= 0.90
        traj_similar = !isempty(all_mean_diffs)  && mean(all_mean_diffs) < 100.0  # liberal threshold
        no_thm_dep   = !isempty(all_thm_shares)  && mean(all_thm_shares) < 0.10

        println(io, "  Evidence summary:")
        @printf(io, "    A. Storage full before events:  %s (mean SOC frac = %.1f%%)\n",
                full_before ? "YES" : "NO/PARTIAL",
                isempty(all_soc_fracs) ? nan : 100.0 * mean(all_soc_fracs))
        @printf(io, "    B. Thermal headroom critical:   %s (mean share = %.1f%%)\n",
                !isempty(all_thm_shares) && mean(all_thm_shares) >= 0.10 ? "YES" : "NO",
                isempty(all_thm_shares) ? nan : 100.0 * mean(all_thm_shares))
        @printf(io, "    C. SOC trajectories similar:    %s (mean diff = %.2f MWh)\n",
                traj_similar ? "YES" : "NO",
                isempty(all_mean_diffs) ? nan : mean(all_mean_diffs))
        println(io)
        if full_before && traj_similar
            println(io, "  → Structural explanation: M1c's unconditional charging from any surplus")
            println(io, "    keeps storage at maximum capacity before shortage events.")
            println(io, "    The LP (M3) arrives at the same SOC trajectory because the system has")
            println(io, "    sufficient non-shortage surplus to fill storage anyway — the LP optimal")
            println(io, "    solution and the M1c greedy solution coincide when storage is small")
            println(io, "    relative to surplus hours.")
            println(io, "    Prediction: the match would break if storage were larger, surplus hours")
            println(io, "    fewer, or if there were opportunity costs to charging (e.g. expensive")
            println(io, "    thermal cycling, cycling costs, or a tighter VRE penetration scenario).")
        elseif full_before && !traj_similar
            println(io, "  → Outcome match despite divergent trajectories: M1c and M3 take different")
            println(io, "    charging paths but both arrive with sufficient SOC to cover every shortfall.")
            println(io, "    The match is more fragile — a slightly different scenario draw could produce")
            println(io, "    a case where M1c has depleted SOC before a shortage that M3 anticipates.")
        else
            println(io, "  → The exact match at N=20 appears coincidental (storage not reliably full")
            println(io, "    before events). With more scenarios or different VRE profiles the match")
            println(io, "    would likely not hold.")
        end
        println(io)

        @printf(io, "Total runtime: %.1f s\n", total_rt)
        println(io, sep)
        println(io, "Files: m1c_m3_soc_comparison.csv")
        println(io, "       m1c_charging_source_proxy.csv")
        println(io, "       shortage_event_soc_detail.csv")
    end

    # ── console output ─────────────────────────────────────────────────────────
    println()
    sep = "=" ^ 80
    println(sep)
    @printf("M1c vs M3 Diagnostic  |  N=%d  |  seed=%d\n", n_scenarios, seed)
    println(sep)
    println()

    soc_df_ok = filter(r -> !isnan(r.mean_abs_soc_diff_mwh), soc_df)
    for cname in cases_to_run
        sub = filter(r -> r.case_name == cname, soc_df_ok)
        isempty(sub) && continue
        mean_diff = mean(sub.mean_abs_soc_diff_mwh)
        max_diff  = mean(sub.max_abs_soc_diff_mwh)
        m1c_full_pct = mean(sub.hours_m1c_full_soc) / 8760 * 100
        m1c_emp_pct  = mean(sub.hours_m1c_empty_soc) / 8760 * 100
        @printf("  %s  mean|soc_diff|=%.2f MWh  max|soc_diff|=%.2f MWh  m1c_full=%.1f%%  m1c_empty=%.1f%%\n",
                cname, mean_diff, max_diff, m1c_full_pct, m1c_emp_pct)
    end
    println()

    if !isempty(event_df)
        println("Shortage event SOC at start (M3-detected events):")
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, event_df)
            isempty(sub) && continue
            @printf("  %s  n_events=%d  m1c_soc_at_start=%.1f MWh  m3_soc_at_start=%.1f MWh\n",
                    cname, size(sub, 1), mean(sub.m1c_soc_at_event_start), mean(sub.m3_soc_at_event_start))
        end
        println()
    end

    for cname in cases_to_run
        sub = filter(r -> r.case_name == cname, charge_df)
        isempty(sub) && continue
        thm_shares = filter(!isnan, sub.share_charge_thermal_headroom_proxy)
        isempty(thm_shares) && continue
        @printf("  %s  M1c thermal-headroom share=%.1f%%  M3 non-VRE-surplus share=%.1f%%\n",
                cname,
                100.0 * mean(thm_shares),
                100.0 * mean(sub.m3_charge_when_vre_not_surplus_mwh) / max(mean(sub.total_m3_charge_mwh), 1e-9))
    end

    @printf("\nTotal runtime: %.1f s\n", total_rt)
    @printf("Output: %s\n", abspath(out_dir))
    @printf("Summary: %s\n", abspath(summary_path))
    println()
end
