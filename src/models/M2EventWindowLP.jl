# ── RA-2 / M2b: Event-window LP dispatch ──────────────────────────────────
#
# Algorithm (per scenario):
#   1. Compute pre-storage margin[h] = thermal_avail[h] + p_vre[h] - load[h].
#   2. Flag risk hours where margin[h] < config.risk_margin_mw.
#   3. build_risk_windows: expand by buffer, merge (gap ≤ merge_gap),
#      enforce min length, clip to [1, T].
#   4. Sequential dispatch:
#        a. RA-1b heuristic for hours OUTSIDE windows (uses SOC reserve floor).
#        b. JuMP LP (HiGHS) for hours INSIDE windows.
#        c. SOC handed off at each window boundary.
#   5. On LP failure: warn and fall back to RA-1b for that window.
#
# LP formulation (aggregated storage, per window W = [ws:we]):
#   min  VOLL·Σ_t load_shed[t] + ε·Σ_t (charge[t] + discharge[t])
#   s.t. p_therm[t] + p_vre[t] + dis[t] - chg[t] + ls[t] - curt[t] = load[t]
#        soc[t]     = soc[t-1] + η_ch·chg[t] − dis[t]/η_dis,  soc[0]=soc_init
#        0 ≤ p_therm[t] ≤ thermal_avail[t]
#        0 ≤ dis[t], chg[t] ≤ total_power_mw
#        0 ≤ soc[t]         ≤ total_energy_mwh
#        ls[t], curt[t] ≥ 0
#
# Gurobi is used with a shared Env() created once per run_m2_with_diagnostics call,
# avoiding per-model license overhead. With risk_margin=1000 MW the windows can span
# several hundred to ~2000 hours, making Gurobi significantly faster than HiGHS.

"""
    Ra2ScenarioDiag

Per-scenario diagnostic fields returned by `run_m2_with_diagnostics`.
"""
struct Ra2ScenarioDiag
    scenario_id    ::Int
    n_risk_hours   ::Int
    n_windows      ::Int
    total_window_h ::Int
    mean_window_len::Float64
    max_window_len ::Int
    n_lp_failures  ::Int
end

"""
    build_risk_windows(margin, n_hours, risk_margin_mw, buffer, merge_gap, min_len)
    -> Vector{Tuple{Int,Int}}

Return a sorted list of `(start, end)` window tuples covering all risk hours.
Each window is:
  - expanded by `buffer` hours on each side of each risk hour
  - merged with neighbours whose gap ≤ `merge_gap` hours
  - padded to at least `min_len` hours
  - clipped to [1, n_hours]
"""
function build_risk_windows(
        margin        ::Vector{Float64},
        n_hours       ::Int,
        risk_margin_mw::Float64,
        buffer        ::Int,
        merge_gap     ::Int,
        min_len       ::Int)::Vector{Tuple{Int,Int}}

    risk_hours = findall(h -> margin[h] < risk_margin_mw, 1:n_hours)
    isempty(risk_hours) && return Tuple{Int,Int}[]

    # expand each risk hour by buffer on both sides
    raw = [(max(1, h - buffer), min(n_hours, h + buffer)) for h in risk_hours]
    sort!(raw)

    # merge windows whose gap ≤ merge_gap (condition: next_start ≤ cur_end + merge_gap + 1)
    merged = Tuple{Int,Int}[]
    ws, we = raw[1]
    for (a, b) in raw[2:end]
        if a <= we + merge_gap + 1
            we = max(we, b)
        else
            push!(merged, (ws, we))
            ws, we = a, b
        end
    end
    push!(merged, (ws, we))

    # enforce minimum window length (expand symmetrically, then clip)
    for i in eachindex(merged)
        a, b = merged[i]
        len  = b - a + 1
        if len < min_len
            extra = min_len - len
            left  = extra ÷ 2
            right = extra - left
            a = max(1, a - left)
            b = min(n_hours, b + right)
            # if clipped on one side, try the other
            if b - a + 1 < min_len
                if a == 1
                    b = min(n_hours, min_len)
                else
                    a = max(1, b - min_len + 1)
                end
            end
            merged[i] = (a, b)
        end
    end

    # final merge — min_len padding can create new overlaps
    result = Tuple{Int,Int}[]
    ws, we = merged[1]
    for (a, b) in merged[2:end]
        if a <= we + 1
            we = max(we, b)
        else
            push!(result, (ws, we))
            ws, we = a, b
        end
    end
    push!(result, (ws, we))

    return result
end

# ── Internal: RA-1b dispatch over hours h_start:h_end ─────────────────────
# Writes into load_shed/st_dis/st_chg/soc/curtailmt; returns final SOC.
function _ra1b_segment!(
        h_start       ::Int,
        h_end         ::Int,
        therm_avail   ::Vector{Float64},
        p_vre         ::Vector{Float64},
        load_mw       ::Vector{Float64},
        net_load      ::Vector{Float64},
        high_nl_thresh::Float64,
        charge_nl_thresh::Float64,
        total_power   ::Float64,
        total_energy  ::Float64,
        eta_ch        ::Float64,
        eta_dis       ::Float64,
        soc_floor     ::Float64,
        init_soc      ::Float64,
        load_shed     ::Vector{Float64},
        st_dis        ::Vector{Float64},
        st_chg        ::Vector{Float64},
        soc           ::Vector{Float64},
        curtailmt     ::Vector{Float64})::Float64

    curr_soc = init_soc
    for h in h_start:h_end
        load_h     = load_mw[h]
        net_supply = therm_avail[h] + p_vre[h]
        shortfall  = max(0.0, load_h - net_supply)

        dis = 0.0
        chg = 0.0

        if shortfall > 0.0 && total_power > 0.0
            # Priority 1: emergency discharge (no reserve floor)
            max_dis  = min(total_power, curr_soc * eta_dis)
            dis      = min(shortfall, max_dis)
            curr_soc -= dis / eta_dis
        elseif net_load[h] >= high_nl_thresh && total_power > 0.0
            # Priority 2: proactive discharge (above reserve floor)
            avail_above = max(0.0, (curr_soc - soc_floor) * eta_dis)
            max_dis     = min(total_power, avail_above)
            if max_dis > 0.0
                dis      = max_dis
                curr_soc -= dis / eta_dis
            end
        end

        if dis == 0.0 && net_load[h] <= charge_nl_thresh && total_power > 0.0
            # Priority 3: charge during surplus
            surplus  = net_supply - load_h
            headroom = total_energy - curr_soc
            if surplus > 0.0 && headroom > 0.0
                max_chg  = min(total_power, surplus, headroom / eta_ch)
                chg      = max(0.0, max_chg)
                curr_soc += chg * eta_ch
            end
        end

        curr_soc = clamp(curr_soc, 0.0, total_energy)

        soc[h]    = curr_soc
        st_dis[h] = dis
        st_chg[h] = chg
        net_bal      = net_supply + dis - chg - load_h
        load_shed[h] = max(0.0, -net_bal)
        curtailmt[h] = max(0.0,  net_bal)
    end

    return curr_soc
end

# ── Internal: solve a JuMP LP for hours h_start:h_end ─────────────────────
# On success: writes dispatch arrays, returns (final_soc, true).
# On failure: returns (soc_init, false) without touching the arrays.
function _solve_window_lp!(
        h_start          ::Int,
        h_end            ::Int,
        therm_avail      ::Vector{Float64},
        p_vre            ::Vector{Float64},
        load_mw          ::Vector{Float64},
        total_power      ::Float64,
        total_energy     ::Float64,
        eta_ch           ::Float64,
        eta_dis          ::Float64,
        soc_init         ::Float64,
        voll             ::Float64,
        eps_cyc          ::Float64,
        load_shed        ::Vector{Float64},
        st_dis           ::Vector{Float64},
        st_chg           ::Vector{Float64},
        soc              ::Vector{Float64},
        curtailmt        ::Vector{Float64};
        optimizer_factory = HiGHS.Optimizer)::Tuple{Float64, Bool}

    W = h_end - h_start + 1

    mdl = Model(optimizer_factory)
    set_silent(mdl)

    @variable(mdl, p_th[1:W]   >= 0.0)
    @variable(mdl, dis[1:W]    >= 0.0)
    @variable(mdl, chg[1:W]    >= 0.0)
    @variable(mdl, s[1:W]      >= 0.0)
    @variable(mdl, ls[1:W]     >= 0.0)
    @variable(mdl, curt[1:W]   >= 0.0)

    for w in 1:W
        h = h_start + w - 1
        @constraint(mdl, p_th[w] <= therm_avail[h])
        @constraint(mdl, dis[w]  <= total_power)
        @constraint(mdl, chg[w]  <= total_power)
        @constraint(mdl, s[w]    <= total_energy)

        # power balance (equality)
        @constraint(mdl,
            p_th[w] + p_vre[h] + dis[w] - chg[w] + ls[w] - curt[w] == load_mw[h])

        # SOC dynamics
        if w == 1
            @constraint(mdl, s[w] == soc_init + eta_ch * chg[w] - dis[w] / eta_dis)
        else
            @constraint(mdl, s[w] == s[w-1]  + eta_ch * chg[w] - dis[w] / eta_dis)
        end
    end

    obj = JuMP.AffExpr(0.0)
    for w in 1:W
        JuMP.add_to_expression!(obj, voll,    ls[w])
        JuMP.add_to_expression!(obj, eps_cyc, chg[w])
        JuMP.add_to_expression!(obj, eps_cyc, dis[w])
    end
    @objective(mdl, Min, obj)

    optimize!(mdl)

    st = termination_status(mdl)
    if st ∉ (MOI.OPTIMAL, MOI.LOCALLY_SOLVED)
        return (soc_init, false)
    end

    for w in 1:W
        h = h_start + w - 1
        load_shed[h] = max(0.0, value(ls[w]))
        st_dis[h]    = max(0.0, value(dis[w]))
        st_chg[h]    = max(0.0, value(chg[w]))
        soc[h]       = max(0.0, value(s[w]))
        curtailmt[h] = max(0.0, value(curt[w]))
    end

    return (max(0.0, value(s[W])), true)
end

"""
    run_m2_with_diagnostics(system, availability, config)
    -> (Vector{DispatchResult}, Vector{Ra2ScenarioDiag})

RA-2 event-window LP dispatch with per-scenario diagnostic data.
"""
function run_m2_with_diagnostics(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        config      ::SimConfig)::Tuple{Vector{DispatchResult}, Vector{Ra2ScenarioDiag}}

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_scen  = size(availability, 1)
    T       = system.n_hours

    pmax = Float64.(therm.pmax_mw)

    # ── aggregate storage ──────────────────────────────────────────────────
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
    soc_floor = config.reserve_fraction * total_energy

    # ── VRE output (scenario-independent) ─────────────────────────────────
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:T]

    # RA-1b thresholds from full-year net-load distribution
    net_load         = system.load_mw .- p_vre
    high_nl_thresh   = quantile(net_load, config.high_net_load_quantile)
    charge_nl_thresh = quantile(net_load, config.charge_net_load_quantile)

    # RA-2 window parameters
    risk_margin = config.risk_margin_mw
    buffer      = config.window_buffer_hours
    merge_gap   = config.merge_gap_hours
    min_len     = config.min_window_length_hours

    gurobi_env     = Gurobi.Env()
    opt_factory    = () -> Gurobi.Optimizer(gurobi_env)

    results = Vector{DispatchResult}(undef, n_scen)
    diags   = Vector{Ra2ScenarioDiag}(undef, n_scen)

    for s in 1:n_scen
        t_start = time()

        # pre-storage thermal available per hour for this scenario
        therm_avail = Vector{Float64}(undef, T)
        for h in 1:T
            ta = 0.0
            for g in 1:n_therm
                ta += pmax[g] * availability[s, g, h]
            end
            therm_avail[h] = ta
        end

        # pre-storage margin (used to find risk hours)
        margin = therm_avail .+ p_vre .- system.load_mw

        windows = build_risk_windows(margin, T, risk_margin, buffer, merge_gap, min_len)

        load_shed = zeros(Float64, T)
        st_dis    = zeros(Float64, T)
        st_chg    = zeros(Float64, T)
        soc       = zeros(Float64, T)
        curtailmt = zeros(Float64, T)

        curr_soc  = init_soc
        h_cursor  = 1
        n_lp_fail = 0

        for (ws, we) in windows
            # RA-1b for hours before this window
            if h_cursor < ws
                curr_soc = _ra1b_segment!(
                    h_cursor, ws - 1,
                    therm_avail, p_vre, system.load_mw, net_load,
                    high_nl_thresh, charge_nl_thresh,
                    total_power, total_energy, eta_ch, eta_dis, soc_floor,
                    curr_soc,
                    load_shed, st_dis, st_chg, soc, curtailmt)
            end

            # LP for the window
            final_soc, ok = _solve_window_lp!(
                ws, we,
                therm_avail, p_vre, system.load_mw,
                total_power, total_energy, eta_ch, eta_dis,
                curr_soc,
                config.voll, config.epsilon_cycling,
                load_shed, st_dis, st_chg, soc, curtailmt;
                optimizer_factory = opt_factory)

            if ok
                curr_soc = final_soc
            else
                n_lp_fail += 1
                @warn "RA-2 s=$s window=($ws,$we): LP infeasible/suboptimal, falling back to RA-1b"
                curr_soc = _ra1b_segment!(
                    ws, we,
                    therm_avail, p_vre, system.load_mw, net_load,
                    high_nl_thresh, charge_nl_thresh,
                    total_power, total_energy, eta_ch, eta_dis, soc_floor,
                    curr_soc,
                    load_shed, st_dis, st_chg, soc, curtailmt)
            end

            h_cursor = we + 1
        end

        # RA-1b for remaining hours after the last window
        if h_cursor <= T
            _ra1b_segment!(
                h_cursor, T,
                therm_avail, p_vre, system.load_mw, net_load,
                high_nl_thresh, charge_nl_thresh,
                total_power, total_energy, eta_ch, eta_dis, soc_floor,
                curr_soc,
                load_shed, st_dis, st_chg, soc, curtailmt)
        end

        rt = time() - t_start

        results[s] = DispatchResult(s, load_shed, st_dis, st_chg, soc,
                                    nothing, curtailmt, rt)

        n_win   = length(windows)
        tot_w_h = isempty(windows) ? 0 : sum(we - ws + 1 for (ws, we) in windows)
        mean_wl = n_win == 0 ? 0.0 : tot_w_h / n_win
        max_wl  = isempty(windows) ? 0 : maximum(we - ws + 1 for (ws, we) in windows)
        n_risk  = count(h -> margin[h] < risk_margin, 1:T)

        diags[s] = Ra2ScenarioDiag(s, n_risk, n_win, tot_w_h, mean_wl, max_wl, n_lp_fail)
    end

    return results, diags
end

"""
    run_m2_event_window_lp(system, availability, config) -> Vector{DispatchResult}

RA-2 event-window LP dispatch.
"""
function run_m2_event_window_lp(
        system      ::SystemData,
        availability::Array{<:Integer, 3},
        config      ::SimConfig)::Vector{DispatchResult}
    results, _ = run_m2_with_diagnostics(system, availability, config)
    return results
end

# ── ScenarioSet overloads ──────────────────────────────────────────────────

function run_m2_event_window_lp(system   ::SystemData,
                                 scenarios::ScenarioSet,
                                 config   ::SimConfig)::Vector{DispatchResult}
    return run_m2_event_window_lp(system, scenarios.availability, config)
end

function run_m2_with_diagnostics(system   ::SystemData,
                                  scenarios::ScenarioSet,
                                  config   ::SimConfig)
    return run_m2_with_diagnostics(system, scenarios.availability, config)
end
