# ── RA-1d / M1d: Risk-hour allocation storage dispatch heuristic ─────────────
#
# Charges storage from surplus in a lookback window before each shortage event,
# then allocates the stored energy across the event hours using one of two rules:
#
#   "earliest_first"  — discharge chronologically; fills the earliest shortfall
#                       hours first.  Matches M1c behaviour when the lookback
#                       window covers the whole year.
#
#   "largest_first"   — sort event hours by pre-storage shortfall descending;
#                       allocate to the largest shortfall first.  Minimises the
#                       maximum hourly shortfall in the event window (useful for
#                       studying EUE concentration).
#
# Algorithm per scenario
# ──────────────────────
# 1.  Compute pre-storage net surplus / shortfall for every hour.
# 2.  Identify contiguous shortage events; optionally merge events separated
#     by fewer than `risk_event_gap_hours` zero-shortfall hours.
# 3.  Process events in chronological order.  For each event:
#     a.  Simulate charging from surplus in the lookback window
#         (respecting power, energy, and efficiency limits; SOC carries
#         over from the previous event's end state).
#     b.  Compute available discharge energy entering the event.
#     c.  Allocate discharge across event hours according to the mode.
#     d.  Track SOC hour-by-hour through the event.
# 4.  Fill non-event hours with surplus charging (no discharge).
# 5.  Reconstruct full hourly vectors and return a DispatchResult.
#
# Config parameters (SimConfig fields)
# ─────────────────────────────────────
#   risk_event_gap_hours        = 0    (no merging by default)
#   event_charge_lookback_hours = 72
#   risk_allocation_mode        = "earliest_first"

"""
    run_m1d_risk_hour_allocation(system, availability, config) -> Vector{DispatchResult}

Run RA-1d (M1d) for every scenario in `availability[scenario, gen, hour]`.

Storage is charged from surplus in a lookback window before each shortage event,
then discharged within the event according to `config.risk_allocation_mode`
("earliest_first" or "largest_first").
"""
function run_m1d_risk_hour_allocation(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        config      ::SimConfig)::Vector{DispatchResult}

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_scen  = size(availability, 1)
    n_hours = system.n_hours

    pmax = Float64.(therm.pmax_mw)

    # ── aggregate storage parameters ─────────────────────────────────────
    stor = system.storage
    if nrow(stor) == 0
        total_power  = 0.0
        total_energy = 0.0
        init_soc     = 0.0
        eta_ch       = 1.0
        eta_dis      = 1.0
    else
        total_power  = sum(stor.power_mw)
        total_energy = sum(stor.energy_mwh)
        init_soc     = sum(stor.initial_soc_mwh)
        eta_ch       = mean(stor.charge_efficiency)
        eta_dis      = mean(stor.discharge_efficiency)
    end

    # ── VRE output per hour ───────────────────────────────────────────────
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:n_hours]

    gap      = config.risk_event_gap_hours
    lookback = config.event_charge_lookback_hours
    mode     = config.risk_allocation_mode

    results = Vector{DispatchResult}(undef, n_scen)

    for s in 1:n_scen

        # ── Step 1: pre-storage balance ───────────────────────────────────
        therm_avail = Vector{Float64}(undef, n_hours)
        net_surplus = Vector{Float64}(undef, n_hours)
        pre_shortfall = Vector{Float64}(undef, n_hours)
        surplus     = Vector{Float64}(undef, n_hours)

        for h in 1:n_hours
            ta = zero(Float64)
            for g in 1:n_therm
                ta += pmax[g] * availability[s, g, h]
            end
            therm_avail[h] = ta
            bal = ta + p_vre[h] - system.load_mw[h]
            net_surplus[h]  = bal
            pre_shortfall[h] = max(0.0, -bal)
            surplus[h]       = max(0.0,  bal)
        end

        # ── Step 2: identify shortage events ─────────────────────────────
        events = _find_shortage_events(pre_shortfall, n_hours, gap)

        # ── Steps 3–4: process events, fill non-event hours ──────────────
        load_shed = zeros(Float64, n_hours)
        st_dis    = zeros(Float64, n_hours)
        st_chg    = zeros(Float64, n_hours)
        soc       = zeros(Float64, n_hours)
        curtailmt = zeros(Float64, n_hours)

        # Track which hours have been processed (inside or lookback of an event)
        processed = falses(n_hours)

        curr_soc = init_soc   # SOC state carried across events

        # ── last SOC state after a processed block; updated as we go ─────
        # We simulate hour-by-hour in order, so we need to carry soc forward.
        # Between events we use a simple surplus-charging pass.

        # Build a sorted list of event boundaries for the main loop below
        # (events is already chronological from _find_shortage_events)

        # We'll do a single forward pass over all hours:
        # - at event starts, run the lookback charging sim then allocate
        # - at non-event hours, do surplus charging

        # For each event we need to know the SOC entering the lookback window.
        # Since events are non-overlapping and ordered, we track curr_soc
        # through the lookback simulation, then through the event itself.

        # Build a set of event-hour sets for quick lookup
        event_set = falses(n_hours)
        for (ev_start, ev_end) in events
            for h in ev_start:ev_end
                event_set[h] = true
            end
        end

        # Forward pass: for each hour h, decide action
        # We track curr_soc continuously.  For event groups, we handle
        # the entire event (including its lookback) as a unit.

        h = 1
        while h <= n_hours
            if event_set[h]
                # Find which event this is
                ev_idx = findfirst(ev -> ev[1] == h, events)
                if isnothing(ev_idx)
                    # h is inside an event but not its start — skip
                    # (shouldn't happen if we always enter events at their start)
                    h += 1
                    continue
                end
                ev_start, ev_end = events[ev_idx]

                # ── Simulate lookback charging ────────────────────────────
                lb_start = max(1, ev_start - lookback)
                lb_end   = ev_start - 1

                soc_entering_event = curr_soc
                if lb_end >= lb_start
                    soc_lb = curr_soc
                    for lh in lb_start:lb_end
                        if !event_set[lh]
                            sur_lh   = surplus[lh]
                            headroom = total_energy - soc_lb
                            if sur_lh > 0.0 && headroom > 0.0 && total_power > 0.0
                                chg_lh = min(total_power, sur_lh, headroom / eta_ch)
                                soc_lb = min(total_energy, soc_lb + chg_lh * eta_ch)
                            end
                        end
                    end
                    soc_entering_event = soc_lb
                end

                avail_energy = soc_entering_event   # MWh available for discharge

                # ── Allocate discharge across event hours ─────────────────
                event_len = ev_end - ev_start + 1
                dis_alloc = zeros(Float64, event_len)  # MW per event hour

                if total_power > 0.0 && avail_energy > 0.0
                    shortfalls = [pre_shortfall[h2] for h2 in ev_start:ev_end]

                    if mode == "largest_first"
                        order = sortperm(shortfalls, rev=true)
                    else
                        order = 1:event_len
                    end

                    rem_energy = avail_energy
                    for idx in order
                        sf = shortfalls[idx]
                        if sf > 0.0 && rem_energy > 0.0
                            max_dis_mw  = min(total_power, rem_energy * eta_dis)
                            d           = min(sf, max_dis_mw)
                            dis_alloc[idx] = d
                            rem_energy -= d / eta_dis
                            rem_energy   = max(0.0, rem_energy)
                        end
                    end
                end

                # ── Replay event hour-by-hour to fill soc/chg arrays ─────
                # Do NOT charge during event hours (emergency-only within event)
                ev_soc = soc_entering_event
                for (i, h2) in enumerate(ev_start:ev_end)
                    d = dis_alloc[i]
                    if d > 0.0
                        ev_soc    -= d / eta_dis
                        ev_soc     = max(0.0, ev_soc)
                    end
                    ev_soc = clamp(ev_soc, 0.0, total_energy)
                    soc[h2]    = ev_soc
                    st_dis[h2] = d
                    st_chg[h2] = 0.0
                    net_bal    = therm_avail[h2] + p_vre[h2] + d - system.load_mw[h2]
                    load_shed[h2] = max(0.0, -net_bal)
                    curtailmt[h2] = max(0.0,  net_bal)
                    processed[h2] = true
                end

                # Update curr_soc to end-of-event SOC
                curr_soc = ev_soc

                h = ev_end + 1
            else
                # Non-event hour: surplus charging, no discharge
                if !processed[h]
                    sur_h    = surplus[h]
                    headroom = total_energy - curr_soc
                    chg_h    = 0.0
                    if sur_h > 0.0 && headroom > 0.0 && total_power > 0.0
                        chg_h    = min(total_power, sur_h, headroom / eta_ch)
                        curr_soc = min(total_energy, curr_soc + chg_h * eta_ch)
                    end
                    curr_soc   = clamp(curr_soc, 0.0, total_energy)
                    soc[h]     = curr_soc
                    st_chg[h]  = chg_h
                    st_dis[h]  = 0.0
                    net_bal    = therm_avail[h] + p_vre[h] + 0.0 - chg_h - system.load_mw[h]
                    load_shed[h] = max(0.0, -net_bal)
                    curtailmt[h] = max(0.0,  net_bal)
                    processed[h] = true
                end
                h += 1
            end
        end

        results[s] = DispatchResult(s, load_shed, st_dis, st_chg, soc,
                                    nothing, curtailmt, 0.0)
    end

    return results
end

"""
    run_m1d_risk_hour_allocation(system, scenarios::ScenarioSet, config) -> Vector{DispatchResult}

ScenarioSet overload — extracts the availability array and delegates.
"""
function run_m1d_risk_hour_allocation(system   ::SystemData,
                                       scenarios::ScenarioSet,
                                       config   ::SimConfig)::Vector{DispatchResult}
    return run_m1d_risk_hour_allocation(system, scenarios.availability, config)
end

# ── helpers ──────────────────────────────────────────────────────────────────

"""
    _find_shortage_events(pre_shortfall, n_hours, gap) -> Vector{Tuple{Int,Int}}

Return a list of (start, end) pairs for contiguous shortage periods.
Events separated by at most `gap` zero-shortfall hours are merged.
"""
function _find_shortage_events(pre_shortfall::Vector{Float64},
                                n_hours::Int,
                                gap::Int)::Vector{Tuple{Int,Int}}
    events = Tuple{Int,Int}[]
    in_event  = false
    ev_start  = 0
    ev_end    = 0
    gap_count = 0

    for h in 1:n_hours
        if pre_shortfall[h] > 1e-9
            if !in_event
                if !isempty(events) && gap > 0 && gap_count <= gap
                    # merge: extend the last event
                    ev_start, _ = events[end]
                    pop!(events)
                else
                    ev_start = h
                end
                in_event  = true
                gap_count = 0
            end
            ev_end    = h
            gap_count = 0
        else
            if in_event
                gap_count += 1
                if gap_count > gap
                    push!(events, (ev_start, ev_end))
                    in_event  = false
                    gap_count = 0
                end
            end
        end
    end
    if in_event
        push!(events, (ev_start, ev_end))
    end
    return events
end
