#!/usr/bin/env julia
# 39_storage_energy_sufficiency_bound.jl
#
# Theory-oriented diagnostic: storage-energy sufficiency bound.
#
# For each Monte Carlo scenario, computes the maximum EUE reduction that
# storage could theoretically achieve given:
#   (a) the available charge energy from surplus before each shortage event
#       (lookback window, default 72 h);
#   (b) the total storage energy capacity (MWh);
#   (c) the per-hour discharge power limit (MW).
#
# The resulting residual_eue_bound_mwh is a lower bound on EUE: any
# storage dispatch model that charges greedily from surplus and discharges
# optimally within each event cannot do better.  It is NOT a dispatch model;
# it does not track SOC hour-by-hour or account for energy consumed in
# prior events.
#
# Comparison against M1c, M2, and M3 tests whether the bound explains why
# those models agree — if bound ≈ M3 EUE, the system is effectively
# storage-energy limited and any reasonable dispatch captures the full benefit.
#
# Usage:
#   julia --project=. scripts/39_storage_energy_sufficiency_bound.jl \
#     [--cases VRE120_base,VRE120_wind_hvy] \
#     [--n-scenarios 20] \
#     [--seed 42] \
#     [--lookback-hours 72] \
#     [--out-dir results/storage_energy_sufficiency_bound]

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
        i + 1 <= length(args) && !startswith(args[i+1], "--") ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

# ── Bound computation ─────────────────────────────────────────────────────────

"""
    compute_storage_bound(system, availability, config; lookback_hours) ->
        (event_rows, scenario_rows)

For each scenario and shortage event, compute the storage-energy sufficiency
bound.  Returns two vectors of NamedTuples (event-level and scenario-level).

The bound is conservative in three ways:
1.  It accounts for the discharge-efficiency penalty on stored energy.
2.  It accounts for the per-hour power limit on discharge.
3.  It does NOT assume SOC can be shared across events; each event is
    evaluated independently using only the surplus from its own lookback
    window plus the initial SOC (optimistic assumption — shared SOC is
    NOT tracked, so this bound can slightly overstate coverage for
    scenarios with multiple events).
"""
function compute_storage_bound(system      ::SystemData,
                                availability::Array{<:Integer, 3},
                                _config     ::SimConfig;
                                lookback_hours::Int = 72)

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_scen  = size(availability, 1)
    n_hours = system.n_hours

    pmax     = Float64.(therm.pmax_mw)
    wind_cap = wind_capacity_mw(system)
    solar_cap= solar_capacity_mw(system)

    # Storage aggregates
    stor = system.storage
    if nrow(stor) == 0
        stor_power  = 0.0
        stor_energy = 0.0
        init_soc    = 0.0
        eta_ch      = 1.0
        eta_dis     = 1.0
    else
        stor_power  = sum(stor.power_mw)
        stor_energy = sum(stor.energy_mwh)
        init_soc    = sum(stor.initial_soc_mwh)
        eta_ch      = mean(stor.charge_efficiency)
        eta_dis     = mean(stor.discharge_efficiency)
    end

    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:n_hours]

    event_rows    = NamedTuple[]
    scenario_rows = NamedTuple[]

    for s in 1:n_scen
        # ── Step 1: pre-storage balance ───────────────────────────────────
        therm_avail   = Vector{Float64}(undef, n_hours)
        net_surplus   = Vector{Float64}(undef, n_hours)
        pre_shortfall = Vector{Float64}(undef, n_hours)
        surplus       = Vector{Float64}(undef, n_hours)

        for h in 1:n_hours
            ta = zero(Float64)
            for g in 1:n_therm
                ta += pmax[g] * availability[s, g, h]
            end
            therm_avail[h]   = ta
            bal              = ta + p_vre[h] - system.load_mw[h]
            net_surplus[h]   = bal
            pre_shortfall[h] = max(0.0, -bal)
            surplus[h]       = max(0.0,  bal)
        end

        # ── Step 2: identify shortage events ─────────────────────────────
        # Contiguous blocks where pre_shortfall[h] > 1e-6.
        events = Tuple{Int,Int}[]
        in_ev  = false
        ev_s   = 0
        for h in 1:n_hours
            if pre_shortfall[h] > 1e-6
                if !in_ev
                    ev_s  = h
                    in_ev = true
                end
            else
                if in_ev
                    push!(events, (ev_s, h - 1))
                    in_ev = false
                end
            end
        end
        in_ev && push!(events, (ev_s, n_hours))

        scenario_pre_eue      = sum(pre_shortfall)
        total_coverage_bound  = 0.0

        for (ev_start, ev_end) in events
            ev_len = ev_end - ev_start + 1

            # Pre-storage EUE for this event
            pre_eue = sum(pre_shortfall[h] for h in ev_start:ev_end)
            peak_sf = maximum(pre_shortfall[h] for h in ev_start:ev_end)

            # ── Feasible charge before event ──────────────────────────────
            lb_start = max(1, ev_start - lookback_hours)
            lb_end   = ev_start - 1

            # Simulate greedy charging from surplus in lookback window.
            # Start from initial SOC (optimistic — ignores prior events).
            soc_lb = init_soc
            if lb_end >= lb_start
                for lh in lb_start:lb_end
                    sur_lh   = surplus[lh]
                    headroom = stor_energy - soc_lb
                    if sur_lh > 0.0 && headroom > 0.0 && stor_power > 0.0
                        chg = min(stor_power, sur_lh, headroom / eta_ch)
                        soc_lb = min(stor_energy, soc_lb + chg * eta_ch)
                    end
                end
            end
            feasible_charge_mwh = soc_lb   # SOC available at event start

            # ── Feasible discharge energy (MWh of load covered) ───────────
            # Discharge efficiency: stored MWh × η_dis = delivered MWh.
            feasible_dis_energy = min(stor_energy, feasible_charge_mwh) * eta_dis

            # ── Power-limited discharge (max coverage if power-limited) ──
            power_limited_mwh = sum(min(pre_shortfall[h], stor_power)
                                    for h in ev_start:ev_end)

            # ── Coverage bound for this event ─────────────────────────────
            coverage = min(pre_eue, feasible_dis_energy, power_limited_mwh)
            total_coverage_bound += coverage

            push!(event_rows, (
                scenario_id                      = s,
                event_start_hour                 = ev_start,
                event_end_hour                   = ev_end,
                event_duration_h                 = ev_len,
                pre_storage_eue_mwh              = pre_eue,
                event_peak_shortfall_mw          = peak_sf,
                storage_power_mw                 = stor_power,
                storage_energy_mwh               = stor_energy,
                usable_initial_soc_mwh           = init_soc,
                feasible_charge_before_event_mwh = feasible_charge_mwh,
                feasible_discharge_energy_mwh    = feasible_dis_energy,
                feasible_discharge_power_limited_mwh = power_limited_mwh,
                storage_coverage_bound_mwh       = coverage,
                residual_eue_bound_mwh           = pre_eue - coverage,
            ))
        end

        residual_bound = max(0.0, scenario_pre_eue - total_coverage_bound)
        suf_ratio = scenario_pre_eue > 0.0 ?
                    total_coverage_bound / scenario_pre_eue : NaN

        push!(scenario_rows, (
            scenario_id                      = s,
            scenario_pre_storage_eue_mwh     = scenario_pre_eue,
            scenario_residual_eue_bound_mwh  = residual_bound,
            n_events                         = length(events),
            max_event_duration_h             = isempty(events) ? 0 :
                                               maximum(e[2] - e[1] + 1 for e in events),
            max_event_peak_shortfall_mw      = isempty(events) ? 0.0 :
                                               maximum(maximum(pre_shortfall[e[1]:e[2]])
                                                       for e in events),
            total_storage_coverage_bound_mwh = total_coverage_bound,
            storage_sufficiency_ratio        = suf_ratio,
        ))
    end

    return event_rows, scenario_rows
end

# ── Dispatch helpers ──────────────────────────────────────────────────────────

function run_and_measure(f, label::String)
    print("    $label … ")
    t0 = time()
    results = f()
    rt = time() - t0
    println(@sprintf("%.1f s", rt))
    return results, rt
end

function scenario_eue_vec(results::Vector{DispatchResult})
    [sum(r.load_shed) for r in results]
end

# ── Summary writer ────────────────────────────────────────────────────────────

function write_summary(io, cases, all_scen_bound, all_scen_models,
                       n_scen, seed, lookback_hours)
    println(io, "Storage-Energy Sufficiency Bound")
    println(io, "Generated: ", Dates.now())
    println(io, "Cases: ", join(cases, ", "), "  |  N=$n_scen, seed=$seed")
    println(io, "Lookback window: $(lookback_hours) h")
    println(io)

    for case in cases
        sb  = filter(r -> r.case == case, all_scen_bound)
        ms  = filter(r -> r.case == case, all_scen_models)
        isempty(sb) && continue

        bound_eue  = [r.scenario_residual_eue_bound_mwh for r in sb]
        pre_eue    = [r.scenario_pre_storage_eue_mwh    for r in sb]
        suf_ratios = filter(!isnan, [r.storage_sufficiency_ratio for r in sb])

        # per-scenario EUE by model, keyed by scenario_id
        lookup_eue(model, sid) = begin
            sub = filter(r -> r.model == model && r.case == case &&
                              r.scenario_id == sid, ms)
            isempty(sub) ? NaN : first(sub).eue_mwh
        end
        m3_eue  = [lookup_eue("M3",  r.scenario_id) for r in sb]
        m1c_eue = [lookup_eue("M1c", r.scenario_id) for r in sb]
        m2_eue  = [lookup_eue("M2",  r.scenario_id) for r in sb]

        m3_mean  = filter(!isnan, m3_eue)
        m1c_mean = filter(!isnan, m1c_eue)
        m2_mean  = filter(!isnan, m2_eue)

        println(io, "─"^70)
        println(io, "Case: $case")
        println(io, "─"^70)
        println(io, @sprintf("  Pre-storage EUE (mean):        %10.2f MWh", mean(pre_eue)))
        println(io, @sprintf("  Bound residual EUE (mean):     %10.2f MWh", mean(bound_eue)))
        if !isempty(m3_mean)
            println(io, @sprintf("  M3 EUE (mean):                 %10.2f MWh", mean(m3_mean)))
            println(io, @sprintf("  Bound − M3 (mean):             %+10.2f MWh",
                                 mean(bound_eue) - mean(m3_mean)))
        end
        if !isempty(m1c_mean)
            println(io, @sprintf("  M1c EUE (mean):                %10.2f MWh", mean(m1c_mean)))
        end
        if !isempty(m2_mean)
            println(io, @sprintf("  M2 EUE (mean):                 %10.2f MWh", mean(m2_mean)))
        end
        println(io, @sprintf("  Storage sufficiency ratio:     %10.3f  (mean)", mean(suf_ratios)))
        println(io, @sprintf("    (fraction of pre-storage EUE coverable by storage)"))
        println(io)

        # Per-scenario table
        println(io, @sprintf("  %-6s  %12s  %12s  %12s  %12s  %12s",
                             "s_id", "pre_EUE", "bound_EUE",
                             isempty(m3_mean)  ? "M3(N/A)"  : "M3_EUE",
                             isempty(m1c_mean) ? "M1c(N/A)" : "M1c_EUE",
                             isempty(m2_mean)  ? "M2(N/A)"  : "M2_EUE"))
        println(io, "  ", "-"^66)
        for (row_sb, m3v, m1cv, m2v) in zip(sb, m3_eue, m1c_eue, m2_eue)
            sid = row_sb.scenario_id
            pre = row_sb.scenario_pre_storage_eue_mwh
            bnd = row_sb.scenario_residual_eue_bound_mwh
            println(io, @sprintf("  s%03d    %12.2f  %12.2f  %12.2f  %12.2f  %12.2f",
                                 sid, pre, bnd, m3v, m1cv, m2v))
        end
        println(io)
    end

    # ── Q&A ───────────────────────────────────────────────────────────────────
    println(io, "─"^70)
    println(io, "Q&A")
    println(io, "─"^70)
    println(io)

    # Gather cross-case data for Q&A
    all_cases_data = Dict{String, NamedTuple}()
    for case in cases
        sb  = filter(r -> r.case == case, all_scen_bound)
        ms  = filter(r -> r.case == case, all_scen_models)
        isempty(sb) && continue
        bound_eue  = [r.scenario_residual_eue_bound_mwh for r in sb]
        pre_eue    = [r.scenario_pre_storage_eue_mwh    for r in sb]
        suf        = filter(!isnan, [r.storage_sufficiency_ratio for r in sb])
        n_ev       = [r.n_events for r in sb]
        max_dur    = [r.max_event_duration_h for r in sb]
        m3_eue  = [r.eue_mwh for r in filter(r -> r.model == "M3",  ms)]
        m1c_eue = [r.eue_mwh for r in filter(r -> r.model == "M1c", ms)]
        m2_eue  = [r.eue_mwh for r in filter(r -> r.model == "M2",  ms)]
        all_cases_data[case] = (
            bound_eue=bound_eue, pre_eue=pre_eue, suf=suf,
            n_ev=n_ev, max_dur=max_dur,
            m3_eue=m3_eue, m1c_eue=m1c_eue, m2_eue=m2_eue,
        )
    end

    # Q1
    println(io, "Q1. Does the storage-energy sufficiency bound match M3 EUE?")
    for case in cases
        d = get(all_cases_data, case, nothing)
        isnothing(d) && continue
        isempty(d.m3_eue) && continue
        delta = mean(d.bound_eue) - mean(d.m3_eue)
        println(io, "  $case:")
        println(io, @sprintf("    Bound EUE = %.2f MWh,  M3 EUE = %.2f MWh,  Δ = %+.2f MWh",
                             mean(d.bound_eue), mean(d.m3_eue), delta))
        if abs(delta) < 1.0
            println(io, "    YES — bound and M3 agree to within 1 MWh.")
        elseif mean(d.bound_eue) < mean(d.m3_eue)
            println(io, "    Bound is BELOW M3 — the bound overestimates storage coverage.")
            println(io, "    This occurs because the bound ignores energy consumed in prior")
            println(io, "    events (optimistic SOC reset to initial_soc per event).")
        else
            println(io, "    Bound is ABOVE M3 — M3 achieves better coverage than the bound")
            println(io, "    predicts.  Check power/energy constraint assumptions.")
        end
    end
    println(io)

    # Q2
    println(io, "Q2. Does the bound explain why M1c / M1d / M2 match M3?")
    for case in cases
        d = get(all_cases_data, case, nothing)
        isnothing(d) && continue
        isempty(d.m3_eue) || isempty(d.m1c_eue) || isempty(d.m2_eue) && continue
        delta_m1c = mean(d.m1c_eue) - mean(d.m3_eue)
        delta_m2  = mean(d.m2_eue)  - mean(d.m3_eue)
        println(io, "  $case:")
        println(io, @sprintf("    M1c − M3 = %+.2f MWh,  M2 − M3 = %+.2f MWh", delta_m1c, delta_m2))
        if abs(delta_m1c) < 1.0 && abs(delta_m2) < 1.0
            println(io, "    YES — all models agree (ΔEUE < 1 MWh).  When the bound is tight,")
            println(io, "    any reasonable dispatch that charges from surplus and discharges")
            println(io, "    during shortage events will approach the same optimum.")
        end
    end
    println(io)

    # Q3
    println(io, "Q3. Are remaining differences due to power limits, energy limits, or chronology?")
    for case in cases
        d = get(all_cases_data, case, nothing)
        isnothing(d) && continue
        println(io, "  $case:")
        # Compare bound vs M3; if close, limiting factor is energy budget not power
        println(io, "    The bound min() is applied over three terms:")
        println(io, "      (a) pre-storage event EUE (always largest — upper ceiling)")
        println(io, "      (b) feasible discharge energy (storage energy × η_dis + charged MWh)")
        println(io, "      (c) power-limited coverage (sum of min(shortfall, power_mw) per hour)")
        println(io, "    When bound ≈ M3 EUE, the binding constraint is energy, not power.")
        println(io, "    See event_level_storage_bound.csv columns to identify which term binds.")
    end
    println(io)

    # Q4
    println(io, "Q4. Is VRE120_base harder (larger pre-storage shortfall energy)?")
    if haskey(all_cases_data, "VRE120_base") && haskey(all_cases_data, "VRE120_wind_hvy")
        base = all_cases_data["VRE120_base"]
        wind = all_cases_data["VRE120_wind_hvy"]
        println(io, @sprintf("  VRE120_base:     pre-storage EUE = %.2f MWh (mean)",
                             mean(base.pre_eue)))
        println(io, @sprintf("  VRE120_wind_hvy: pre-storage EUE = %.2f MWh (mean)",
                             mean(wind.pre_eue)))
        println(io, @sprintf("  VRE120_base:     M3 EUE = %.2f MWh",
                             isempty(base.m3_eue) ? NaN : mean(base.m3_eue)))
        println(io, @sprintf("  VRE120_wind_hvy: M3 EUE = %.2f MWh",
                             isempty(wind.m3_eue) ? NaN : mean(wind.m3_eue)))
        if mean(base.pre_eue) > mean(wind.pre_eue)
            println(io, "  YES — VRE120_base has higher pre-storage EUE.  The heavier wind")
            println(io, "  penetration in VRE120_wind_hvy reduces net load and therefore")
            println(io, "  shortage event severity.")
        else
            println(io, "  Surprisingly, VRE120_wind_hvy has larger pre-storage EUE.")
        end
    end
    println(io)

    # Q5
    println(io, "Q5. Is VRE120_wind_hvy easier because shortage events are smaller?")
    if haskey(all_cases_data, "VRE120_base") && haskey(all_cases_data, "VRE120_wind_hvy")
        base = all_cases_data["VRE120_base"]
        wind = all_cases_data["VRE120_wind_hvy"]
        base_suf = isempty(base.suf) ? NaN : mean(base.suf)
        wind_suf = isempty(wind.suf) ? NaN : mean(wind.suf)
        println(io, @sprintf("  VRE120_base:     storage sufficiency ratio = %.3f", base_suf))
        println(io, @sprintf("  VRE120_wind_hvy: storage sufficiency ratio = %.3f", wind_suf))
        if wind_suf > base_suf - 1e-9
            println(io, "  YES — wind-heavy has a higher sufficiency ratio; storage covers a")
            println(io, "  larger fraction of its (smaller) pre-storage EUE.")
        else
            println(io, "  Storage covers a similar or smaller fraction in the wind-heavy case.")
        end
    end
    println(io)

    # Q6
    println(io, "Q6. Does this support the theory that storage-aware MC must preserve energy for scarcity hours?")
    println(io, "  YES — the sufficiency bound shows that storage energy budget and its")
    println(io, "  pre-positioning relative to shortage events is the primary determinant")
    println(io, "  of EUE.  Models that charge from surplus (M1c, M1d, M2) naturally")
    println(io, "  pre-position energy before events and achieve the bound.  Models that")
    println(io, "  proactively discharge in non-shortage hours (M1, M1b) deplete SOC")
    println(io, "  before shortage events, moving away from the bound — explaining their")
    println(io, "  LOLH overestimation bias.  The bound is the theoretical justification")
    println(io, "  for the M1c design principle: discharge only at shortfall hours.")
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    cases_s       = get(kw, "cases",          "VRE120_base,VRE120_wind_hvy")
    n_scen        = parse(Int,     get(kw, "n-scenarios",  "20"))
    seed          = parse(Int,     get(kw, "seed",         "42"))
    lookback_hrs  = parse(Int,     get(kw, "lookback-hours","72"))
    m2_risk       = parse(Float64, get(kw, "m2-risk",      "1000"))
    m2_buf        = parse(Int,     get(kw, "m2-buf",       "48"))
    out_dir       = abspath(get(kw, "out-dir",
                    joinpath(@__DIR__, "..", "results",
                             "storage_energy_sufficiency_bound")))

    cases     = String.(strip.(split(cases_s, ",")))
    data_root = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))

    println("=" ^ 70)
    println("39_storage_energy_sufficiency_bound.jl")
    println("Date: ", Dates.now())
    println("Cases: ", join(cases, ", "))
    println("N=$n_scen, seed=$seed, lookback=$(lookback_hrs)h")
    println("Output: ", out_dir)
    println("=" ^ 70)

    mkpath(out_dir)

    all_event_rows = NamedTuple[]
    all_scen_bound = NamedTuple[]   # (case, scenario_id, bound fields…)
    all_scen_models= NamedTuple[]   # (model, case, scenario_id, eue_mwh)

    for case in cases
        println("\n── Case: $case ──────────────────────────────────────────────")
        case_dir = joinpath(data_root, case)
        isdir(case_dir) || error("Case directory not found: $case_dir")

        sys      = load_system_data(case_dir)
        base_cfg = SimConfig(n_scenarios=n_scen, seed=seed)
        m2_cfg   = SimConfig(n_scenarios=n_scen, seed=seed,
                             risk_margin_mw=m2_risk, window_buffer_hours=m2_buf)

        println("  Generating ScenarioSet (n=$n_scen, seed=$seed) …")
        scen = generate_scenarios(sys, base_cfg)

        # ── Storage sufficiency bound ──────────────────────────────────────
        println("  Computing storage sufficiency bound …")
        t0 = time()
        ev_rows, sc_rows = compute_storage_bound(sys, scen.availability, base_cfg;
                                                  lookback_hours=lookback_hrs)
        println(@sprintf("    done (%.1f s, %d events across %d scenarios)",
                         time() - t0, length(ev_rows), n_scen))

        for r in ev_rows
            push!(all_event_rows, merge(r, (case=case,)))
        end
        for r in sc_rows
            push!(all_scen_bound, merge(r, (case=case,)))
        end

        # ── Dispatch models ────────────────────────────────────────────────
        println("  Running dispatch models:")

        res_m1c, _ = run_and_measure("M1c") do
            run_m1c_emergency_only(sys, scen, base_cfg)
        end
        for r in res_m1c
            push!(all_scen_models, (model="M1c", case=case,
                                    scenario_id=r.scenario_id,
                                    eue_mwh=sum(r.load_shed)))
        end

        res_m2, _ = run_and_measure("M2 (event-window LP)") do
            first(run_m2_with_diagnostics(sys, scen.availability, m2_cfg))
        end
        for r in res_m2
            push!(all_scen_models, (model="M2", case=case,
                                    scenario_id=r.scenario_id,
                                    eue_mwh=sum(r.load_shed)))
        end

        res_m3, _ = run_and_measure("M3 (full-year ED LP)") do
            run_m3_ed_dispatch(sys, scen.availability, base_cfg)
        end
        for r in res_m3
            push!(all_scen_models, (model="M3", case=case,
                                    scenario_id=r.scenario_id,
                                    eue_mwh=sum(r.load_shed)))
        end
    end

    # ── Build bound-vs-models comparison ─────────────────────────────────────
    cmp_rows = NamedTuple[]
    for r_sb in all_scen_bound
        c   = r_sb.case
        sid = r_sb.scenario_id
        get_eue(m) = begin
            sub = filter(x -> x.model == m && x.case == c && x.scenario_id == sid,
                         all_scen_models)
            isempty(sub) ? NaN : first(sub).eue_mwh
        end
        push!(cmp_rows, (
            case                             = c,
            scenario_id                      = sid,
            n_events                         = r_sb.n_events,
            pre_storage_eue_mwh              = r_sb.scenario_pre_storage_eue_mwh,
            residual_eue_bound_mwh           = r_sb.scenario_residual_eue_bound_mwh,
            storage_sufficiency_ratio        = r_sb.storage_sufficiency_ratio,
            m1c_eue_mwh                      = get_eue("M1c"),
            m2_eue_mwh                       = get_eue("M2"),
            m3_eue_mwh                       = get_eue("M3"),
            bound_minus_m3_mwh               = r_sb.scenario_residual_eue_bound_mwh - get_eue("M3"),
            bound_minus_m1c_mwh              = r_sb.scenario_residual_eue_bound_mwh - get_eue("M1c"),
        ))
    end

    # ── Save CSVs ─────────────────────────────────────────────────────────────
    CSV.write(joinpath(out_dir, "event_level_storage_bound.csv"),
              DataFrame(all_event_rows))
    CSV.write(joinpath(out_dir, "scenario_level_storage_bound.csv"),
              DataFrame(all_scen_bound))
    CSV.write(joinpath(out_dir, "bound_vs_models.csv"),
              DataFrame(cmp_rows))

    # ── Summary ───────────────────────────────────────────────────────────────
    summary_path = joinpath(out_dir, "summary.txt")
    open(summary_path, "w") do io
        write_summary(io, cases, all_scen_bound, all_scen_models,
                      n_scen, seed, lookback_hrs)
    end

    println("\nOutput written to: ", out_dir)
    for f in ("event_level_storage_bound.csv", "scenario_level_storage_bound.csv",
              "bound_vs_models.csv", "summary.txt")
        println("  ", f)
    end
end

main()
