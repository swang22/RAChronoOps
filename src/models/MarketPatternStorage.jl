# ── Market-pattern storage MCS ────────────────────────────────────────────────
#
# Implements behaviorally realistic storage dispatch calibrated from observed
# CAISO aggregate battery operation patterns.
#
# Data source: EIA-930 CISO "Net Generation from Other Fuel Sources" 2023.
#   Positive = net discharge, negative = net charge.
#   Patterns are the seasonal × hour-of-day means normalised by the 95th-
#   percentile discharge magnitude (2769 MW for CISO 2023).
#
# Four variants (emergency_override × charge_curtailed):
#   (false, false) Pure market-pattern
#   (false, true)  Pure market-pattern, charge-curtailed
#   (true,  false) Market-pattern + emergency override
#   (true,  true)  Market-pattern + emergency override, charge-curtailed
#
# Charge-curtailed means charging is strictly limited to available surplus
# (sigma_{h,omega}).  This prevents charging from creating load shedding in
# hours that were not short before storage action.  The un-curtailed version
# used surplus + total_power as the limit, which could cause artificial EUE.
#
# Research motivation:
#   Emergency-only storage (M1c) may overstate the reliability contribution of
#   storage if real storage is dispatched economically for price arbitrage or
#   ancillary services.  This method tests that hypothesis.
#
# ── Hour → season → pattern mapping ─────────────────────────────────────────
# Standard 8760-hour year starting 1 Jan.  Month boundaries (1-based hours):
#   Jan: 1–744   Feb: 745–1416  Mar: 1417–2160  Apr: 2161–2880
#   May: 2881–3624  Jun: 3625–4344  Jul: 4345–5088  Aug: 5089–5832
#   Sep: 5833–6552  Oct: 6553–7296  Nov: 7297–8016  Dec: 8017–8760
# Season (meteorological): winter=DJF, spring=MAM, summer=JJA, fall=SON.

# ─────────────────────────────────────────────────────────────────────────────
# Structs
# ─────────────────────────────────────────────────────────────────────────────

"""
    SocBeforeShortage

Pre-shortage SOC diagnostics computed from any dispatch results.
"Shortage hour" is defined as any hour with load_shed > 0.
SOC is measured at end-of-hour h-1 (the hour before each shortage hour).

Fields
------
- `mean_soc_frac`          : Mean SOC / E_max across all (scenario, shortage-hour) pairs
- `p10_soc_frac`           : 10th-percentile SOC / E_max
- `pct_low_soc_shortage`   : Fraction of shortage hours where SOC < 25% E_max
- `n_shortage_hours_total` : Total shortage-hours across all scenarios
"""
Base.@kwdef struct SocBeforeShortage
    mean_soc_frac          ::Float64
    p10_soc_frac           ::Float64
    pct_low_soc_shortage   ::Float64
    n_shortage_hours_total ::Int
end

"""
    EueDecomposition

Decomposition of total EUE into mechanistic components.

Computed at run time by classifying each (scenario, hour) with load_shed > 0:

1. `pre_storage_shortfall_eue` — EUE in hours where the pre-storage balance was
   already short (shortfall_pre > 0).  Storage could help but may not have had
   sufficient SOC or pattern dispatch.

2. `missed_discharge_eue` — Subset of (1): EUE that could have been eliminated
   if full emergency dispatch (M1c rule) had been applied instead of the market
   pattern.  Formally: sum of min(load_shed_h, max(0, emrg_dis - actual_dis))
   over pre-storage-shortfall hours.

3. `charging_induced_eue` — EUE in hours where shortfall_pre = 0 but
   post-storage load shedding > 0 because storage charged beyond surplus.
   This is artificial EUE introduced by the un-curtailed charging rule.
   Zero by construction in the charge-curtailed variants.

4. `low_soc_shortfall_eue` — EUE in pre-storage-shortfall hours where SOC
   at the start of that hour was below 25% of E_max.

All `_pct` fields are the corresponding MWh value divided by `total_eue`.
"""
Base.@kwdef struct EueDecomposition
    total_eue                ::Float64
    pre_storage_shortfall_eue::Float64
    missed_discharge_eue     ::Float64
    charging_induced_eue     ::Float64
    low_soc_shortfall_eue    ::Float64
    pre_storage_pct          ::Float64
    missed_discharge_pct     ::Float64
    charging_induced_pct     ::Float64
    low_soc_pct              ::Float64
end

# ─────────────────────────────────────────────────────────────────────────────
# Pattern loading
# ─────────────────────────────────────────────────────────────────────────────

"""
    load_market_pattern(path) -> (pat_charge, pat_dis)

Load the season × hour-of-day normalised pattern from `season_hour_pattern.csv`.
Returns two 4 × 24 matrices (season × 1-based hour-of-day):
  pat_charge[season_idx, hod]   normalised mean charge rate
  pat_dis[season_idx, hod]      normalised mean discharge rate

Season indices: 1=winter, 2=spring, 3=summer, 4=fall.
"""
function load_market_pattern(path::String)
    df = CSV.read(path, DataFrames.DataFrame)
    sidx = Dict("winter" => 1, "spring" => 2, "summer" => 3, "fall" => 4)

    pat_charge = zeros(Float64, 4, 24)
    pat_dis    = zeros(Float64, 4, 24)

    for row in eachrow(df)
        si = get(sidx, String(row.season), 0)
        si == 0 && continue
        h  = Int(row.hour) + 1          # 0-based → 1-based column
        pat_charge[si, h] = Float64(row.norm_charge_mean)
        pat_dis[si, h]    = Float64(row.norm_discharge_mean)
    end
    return pat_charge, pat_dis
end

# ─────────────────────────────────────────────────────────────────────────────
# Hour → (season, hour-of-day) lookup tables
# ─────────────────────────────────────────────────────────────────────────────

const _MONTH_START_HOUR = let
    days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    cumsum([0; days .* 24])        # length 13; _MONTH_START_HOUR[1]=0
end

const _MONTH_OF_HOUR = let
    v = Vector{Int}(undef, 8760)
    for h in 1:8760
        v[h] = findlast(x -> x <= h - 1, _MONTH_START_HOUR)
    end
    v
end

const _SEASON_OF_MONTH = Dict(
    1 => 1, 2 => 1, 12 => 1,
    3 => 2, 4 => 2,  5 => 2,
    6 => 3, 7 => 3,  8 => 3,
    9 => 4, 10 => 4, 11 => 4,
)

@inline function _hour_season_hod(h::Int)
    hc  = clamp(h, 1, 8760)
    si  = _SEASON_OF_MONTH[_MONTH_OF_HOUR[hc]]
    hod = (hc - 1) % 24 + 1
    return si, hod
end

# ─────────────────────────────────────────────────────────────────────────────
# Core dispatch engine
# ─────────────────────────────────────────────────────────────────────────────

"""
    run_market_pattern_storage(system, availability, config;
                               pattern_csv,
                               emergency_override=false,
                               charge_curtailed=false)
    -> (Vector{DispatchResult}, SocBeforeShortage, EueDecomposition)

Core Market-pattern storage MCS engine.

Parameters
----------
pattern_csv        Path to `season_hour_pattern.csv`.
emergency_override In pre-storage shortage hours, override the market pattern
                   with M1c emergency discharge (discharge up to shortfall
                   and SOC limit).
charge_curtailed   Limit charging to available surplus sigma_{h,omega}.
                   When false, charging is limited by surplus + total_power,
                   which can create load shedding in non-shortage hours.
                   Set true for physically consistent results.

Returns
-------
(Vector{DispatchResult}, SocBeforeShortage, EueDecomposition)
  The DispatchResult vector uses the same interface as all other MCS methods.
  SocBeforeShortage uses load_shed > 0 as the shortage definition.
  EueDecomposition decomposes EUE into pre-storage-shortfall, missed-discharge,
  charging-induced, and low-SOC components.
"""
function run_market_pattern_storage(
        system                 ::SystemData,
        availability           ::Array{<:Integer, 3},
        _config                ::SimConfig;
        pattern_csv            ::String,
        emergency_override     ::Bool              = false,
        charge_curtailed       ::Bool              = false,
        override_init_soc_frac ::Union{Float64,Nothing} = nothing
        )::Tuple{Vector{DispatchResult}, SocBeforeShortage, EueDecomposition}

    pat_charge, pat_dis = load_market_pattern(pattern_csv)

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_scen  = size(availability, 1)
    n_hours = system.n_hours
    pmax    = Float64.(therm.pmax_mw)

    # ── aggregate storage ─────────────────────────────────────────────────────
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
    # Override initial SOC fraction if caller requests a specific boundary condition.
    if !isnothing(override_init_soc_frac)
        init_soc = clamp(override_init_soc_frac, 0.0, 1.0) * total_energy
    end

    e_max_safe = max(total_energy, 1.0)

    # ── VRE output per hour ───────────────────────────────────────────────────
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:n_hours]

    # ── pre-compute pattern for each hour ────────────────────────────────────
    pat_chg_h = Vector{Float64}(undef, n_hours)
    pat_dis_h = Vector{Float64}(undef, n_hours)
    for h in 1:n_hours
        si, hod = _hour_season_hod(h)
        pat_chg_h[h] = pat_charge[si, hod]
        pat_dis_h[h] = pat_dis[si, hod]
    end

    results = Vector{DispatchResult}(undef, n_scen)

    # ── diagnostic accumulators ───────────────────────────────────────────────
    soc_before_shortage_vals = Float64[]

    # EUE decomposition accumulators (summed across scenarios → mean via /n_scen)
    sum_total_eue     = 0.0
    sum_presf_eue     = 0.0
    sum_missed_eue    = 0.0
    sum_chg_ind_eue   = 0.0
    sum_low_soc_eue   = 0.0

    for s in 1:n_scen
        load_shed = zeros(Float64, n_hours)
        st_dis    = zeros(Float64, n_hours)
        st_chg    = zeros(Float64, n_hours)
        soc       = zeros(Float64, n_hours)
        curtailmt = zeros(Float64, n_hours)

        curr_soc = init_soc

        scen_presf_eue   = 0.0
        scen_missed_eue  = 0.0
        scen_chg_ind_eue = 0.0
        scen_low_soc_eue = 0.0

        for h in 1:n_hours
            load_h = system.load_mw[h]

            therm_avail = zero(Float64)
            @inbounds for g in 1:n_therm
                therm_avail += pmax[g] * availability[s, g, h]
            end

            net_supply    = therm_avail + p_vre[h]
            shortfall_pre = max(0.0, load_h - net_supply)
            surplus       = max(0.0, net_supply - load_h)

            soc_entry = curr_soc        # SOC at start of this hour (for diagnostics)
            dis = 0.0
            chg = 0.0

            if shortfall_pre > 0.0 && total_power > 0.0
                # ── Pre-storage shortage hour ─────────────────────────────────
                push!(soc_before_shortage_vals, soc_entry / e_max_safe)

                max_avail_dis = min(total_power, soc_entry * eta_dis)

                if emergency_override
                    # M1c rule: discharge as much as possible up to shortfall
                    dis = min(shortfall_pre, max_avail_dis)
                else
                    # Follow market pattern (may discharge less than available)
                    target_dis = pat_dis_h[h] * total_power
                    dis = min(target_dis, max_avail_dis)
                end
                curr_soc -= dis / eta_dis

                # EUE decomposition for this shortage hour
                ls = max(0.0, shortfall_pre - dis)
                if ls > 0.0
                    scen_presf_eue += ls
                    # Missed discharge: how much more would emergency have given?
                    if !emergency_override
                        emrg_dis = min(shortfall_pre, max_avail_dis)
                        scen_missed_eue += min(ls, max(0.0, emrg_dis - dis))
                    end
                    # Low-SOC contribution
                    if soc_entry / e_max_safe < 0.25
                        scen_low_soc_eue += ls
                    end
                end

            else
                # ── Non-shortage hour: apply market pattern ───────────────────
                # Net-dispatch rule (no simultaneous charge and discharge):
                #   net_pat = r^dis × P^max − r^ch × P^max
                #   net_pat > 0 → discharge-only; net_pat < 0 → charge-only
                # This formulation matches the paper's Eq. for normal-hour dispatch.
                target_dis = pat_dis_h[h] * total_power
                target_chg = pat_chg_h[h] * total_power
                net_pat    = target_dis - target_chg   # + = discharge, - = charge

                if net_pat > 0.0
                    max_dis  = min(total_power, soc_entry * eta_dis)
                    dis      = min(net_pat, max_dis)
                    curr_soc -= dis / eta_dis
                elseif net_pat < 0.0
                    target_chg_actual = -net_pat
                    headroom  = total_energy - soc_entry
                    avail_chg = min(total_power, headroom / eta_ch)
                    # Charge limit: surplus-only (curtailed) vs surplus + power (uncurtailed)
                    chg_limit = charge_curtailed ? surplus : surplus + total_power
                    chg       = min(target_chg_actual, min(avail_chg, chg_limit))
                    chg       = max(0.0, chg)
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

            # Track charging-induced EUE: shortfall_pre == 0 but load_shed > 0
            if shortfall_pre == 0.0 && load_shed[h] > 0.0
                scen_chg_ind_eue += load_shed[h]
            end
        end

        results[s] = DispatchResult(s, load_shed, st_dis, st_chg, soc,
                                    nothing, curtailmt, 0.0)

        scen_total = sum(load_shed)
        sum_total_eue   += scen_total
        sum_presf_eue   += scen_presf_eue
        sum_missed_eue  += scen_missed_eue
        sum_chg_ind_eue += scen_chg_ind_eue
        sum_low_soc_eue += scen_low_soc_eue
    end

    # Invariant: charge-curtailed variants cannot introduce load shedding in
    # hours that had no pre-storage shortfall.  Charging is bounded by surplus
    # (σ_{h,ω} = max(0, net_supply − load_h)), so post-charging net balance
    # is non-negative in non-shortage hours.
    if charge_curtailed && sum_chg_ind_eue > 1e-9
        @warn "charge_curtailed=true invariant violated: " *
              "charging_induced_eue=$(round(sum_chg_ind_eue/n_scen, digits=4)) MWh > 0 " *
              "(expected exactly 0)"
    end
    @assert !charge_curtailed || sum_chg_ind_eue ≤ 1e-6 "charging_induced_eue must be 0 for charge_curtailed=true"

    # ── aggregate diagnostics ─────────────────────────────────────────────────
    soc_diag = if isempty(soc_before_shortage_vals)
        SocBeforeShortage(
            mean_soc_frac=NaN, p10_soc_frac=NaN,
            pct_low_soc_shortage=NaN, n_shortage_hours_total=0)
    else
        v    = soc_before_shortage_vals
        ntot = length(v)
        SocBeforeShortage(
            mean_soc_frac          = mean(v),
            p10_soc_frac           = quantile(v, 0.10),
            pct_low_soc_shortage   = count(x -> x < 0.25, v) / ntot,
            n_shortage_hours_total = ntot,
        )
    end

    safe_pct(a, b) = b > 0.0 ? a / b : NaN
    eue_decomp = EueDecomposition(
        total_eue                = sum_total_eue / n_scen,
        pre_storage_shortfall_eue= sum_presf_eue   / n_scen,
        missed_discharge_eue     = sum_missed_eue  / n_scen,
        charging_induced_eue     = sum_chg_ind_eue / n_scen,
        low_soc_shortfall_eue    = sum_low_soc_eue / n_scen,
        pre_storage_pct  = safe_pct(sum_presf_eue,   sum_total_eue),
        missed_discharge_pct = safe_pct(sum_missed_eue,  sum_total_eue),
        charging_induced_pct = safe_pct(sum_chg_ind_eue, sum_total_eue),
        low_soc_pct      = safe_pct(sum_low_soc_eue, sum_total_eue),
    )

    return results, soc_diag, eue_decomp
end

# ScenarioSet overload — passes all keyword arguments through, including
# override_init_soc_frac for SOC boundary condition studies.
function run_market_pattern_storage(system   ::SystemData,
                                     scenarios::ScenarioSet,
                                     config   ::SimConfig;
                                     kwargs...)
    return run_market_pattern_storage(system, scenarios.availability, config; kwargs...)
end

# ─────────────────────────────────────────────────────────────────────────────
# Named convenience wrappers for the four variants
# ─────────────────────────────────────────────────────────────────────────────

"""
    run_market_pattern_pure(system, availability, config; pattern_csv)

Variant 1: pure market-pattern, no emergency override, charging may exceed surplus.
"""
function run_market_pattern_pure(system      ::SystemData,
                                  availability::Array{<:Integer, 3},
                                  config      ::SimConfig;
                                  pattern_csv ::String)
    return run_market_pattern_storage(system, availability, config;
                                      pattern_csv,
                                      emergency_override=false,
                                      charge_curtailed=false)
end
function run_market_pattern_pure(system   ::SystemData,
                                  scenarios::ScenarioSet,
                                  config   ::SimConfig;
                                  pattern_csv::String)
    return run_market_pattern_pure(system, scenarios.availability, config; pattern_csv)
end

"""
    run_market_pattern_pure_curtailed(system, availability, config; pattern_csv)

Variant 2: pure market-pattern, no emergency override, charging limited to surplus.
"""
function run_market_pattern_pure_curtailed(system      ::SystemData,
                                            availability::Array{<:Integer, 3},
                                            config      ::SimConfig;
                                            pattern_csv ::String)
    return run_market_pattern_storage(system, availability, config;
                                      pattern_csv,
                                      emergency_override=false,
                                      charge_curtailed=true)
end
function run_market_pattern_pure_curtailed(system   ::SystemData,
                                            scenarios::ScenarioSet,
                                            config   ::SimConfig;
                                            pattern_csv::String)
    return run_market_pattern_pure_curtailed(system, scenarios.availability, config; pattern_csv)
end

"""
    run_market_pattern_emergency(system, availability, config; pattern_csv)

Variant 3: market pattern outside shortage hours; M1c emergency discharge inside
shortage hours.  Charging may exceed surplus in non-shortage hours.
"""
function run_market_pattern_emergency(system      ::SystemData,
                                       availability::Array{<:Integer, 3},
                                       config      ::SimConfig;
                                       pattern_csv ::String)
    return run_market_pattern_storage(system, availability, config;
                                      pattern_csv,
                                      emergency_override=true,
                                      charge_curtailed=false)
end
function run_market_pattern_emergency(system   ::SystemData,
                                       scenarios::ScenarioSet,
                                       config   ::SimConfig;
                                       pattern_csv::String)
    return run_market_pattern_emergency(system, scenarios.availability, config; pattern_csv)
end

"""
    run_market_pattern_emergency_curtailed(system, availability, config; pattern_csv)

Variant 4: market pattern outside shortage hours; M1c rule inside shortage hours;
charging strictly limited to surplus.  Physically the most defensible variant.
"""
function run_market_pattern_emergency_curtailed(system      ::SystemData,
                                                 availability::Array{<:Integer, 3},
                                                 config      ::SimConfig;
                                                 pattern_csv ::String)
    return run_market_pattern_storage(system, availability, config;
                                      pattern_csv,
                                      emergency_override=true,
                                      charge_curtailed=true)
end
function run_market_pattern_emergency_curtailed(system   ::SystemData,
                                                 scenarios::ScenarioSet,
                                                 config   ::SimConfig;
                                                 pattern_csv::String)
    return run_market_pattern_emergency_curtailed(system, scenarios.availability, config; pattern_csv)
end

# ─────────────────────────────────────────────────────────────────────────────
# SOC-before-shortage diagnostic for any DispatchResult
# ─────────────────────────────────────────────────────────────────────────────

"""
    compute_soc_before_shortage(results, system) -> SocBeforeShortage

Compute pre-shortage SOC diagnostics from any `Vector{DispatchResult}`.
Shortage hours are defined as load_shed > 0.
SOC measured at end of the preceding hour (hour h-1; falls back to soc[1] at h=1).

Note: this diagnostic is computed per shortage *hour*, not per shortage event.
For a cleaner event-level diagnostic use `compute_event_start_soc`.
"""
function compute_soc_before_shortage(results ::Vector{DispatchResult},
                                      system  ::SystemData)::SocBeforeShortage
    stor         = system.storage
    total_energy = nrow(stor) > 0 ? sum(stor.energy_mwh) : 1.0
    total_energy = max(total_energy, 1.0)

    soc_vals = Float64[]
    for r in results
        n = length(r.load_shed)
        for h in 1:n
            r.load_shed[h] > 0.0 || continue
            prev_soc = h > 1 ? r.soc[h-1] : r.soc[1]
            push!(soc_vals, prev_soc / total_energy)
        end
    end

    isempty(soc_vals) && return SocBeforeShortage(
        mean_soc_frac=NaN, p10_soc_frac=NaN,
        pct_low_soc_shortage=NaN, n_shortage_hours_total=0)

    ntot = length(soc_vals)
    SocBeforeShortage(
        mean_soc_frac          = mean(soc_vals),
        p10_soc_frac           = quantile(soc_vals, 0.10),
        pct_low_soc_shortage   = count(x -> x < 0.25, soc_vals) / ntot,
        n_shortage_hours_total = ntot,
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# Event-start SOC diagnostic
# ─────────────────────────────────────────────────────────────────────────────

"""
    EventStartSoc

SOC diagnostics measured at the start of each shortage event.

A shortage event is a maximal contiguous block of hours with pre-storage
shortfall δ_{h,ω} = max(0, load_h − thermal_avail_{h,ω} − VRE_h) > 0.
SOC is measured at the end of hour h-1 (immediately before the first hour of
each event).  This diagnostic is unaffected by intra-event depletion and
directly shows whether storage entered the event with sufficient energy.

Fields
------
- `mean_soc_frac`           : Mean SOC / E_max across all (scenario, event) pairs
- `p10_soc_frac`            : 10th-percentile SOC / E_max
- `pct_events_low_soc_025`  : Fraction of events starting with SOC < 25% E_max
- `pct_events_low_soc_050`  : Fraction of events starting with SOC < 50% E_max
- `n_shortage_events_total` : Total shortage events across all scenarios
"""
Base.@kwdef struct EventStartSoc
    mean_soc_frac           ::Float64
    p10_soc_frac            ::Float64
    pct_events_low_soc_025  ::Float64
    pct_events_low_soc_050  ::Float64
    n_shortage_events_total ::Int
end

"""
    compute_event_start_soc(results, system, availability) -> EventStartSoc

Compute SOC at the start of each shortage event from any `Vector{DispatchResult}`.

Shortage events are identified from the pre-storage shortfall
δ_{h,ω} = max(0, load_h − Σ_g pmax_g·A_{g,h,ω} − VRE_h),
which requires the generator availability matrix `availability`.
Pass the same array (or `ScenarioSet`) used to generate `results`.

SOC at event start = soc[h−1] (end of preceding hour; soc[1] for h=1).
"""
function compute_event_start_soc(results      ::Vector{DispatchResult},
                                   system       ::SystemData,
                                   availability ::Array{<:Integer, 3})::EventStartSoc
    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    pmax    = Float64.(therm.pmax_mw)

    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    n_hours   = system.n_hours

    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:n_hours]

    stor         = system.storage
    total_energy = nrow(stor) > 0 ? sum(stor.energy_mwh) : 1.0
    total_energy = max(total_energy, 1.0)

    soc_vals = Float64[]

    n_scen = length(results)
    for s in 1:n_scen
        r = results[s]
        isempty(r.soc) && continue

        in_event = false
        for h in 1:n_hours
            therm_avail = 0.0
            @inbounds for g in 1:n_therm
                therm_avail += pmax[g] * availability[s, g, h]
            end
            shortfall_pre = max(0.0, system.load_mw[h] - therm_avail - p_vre[h])

            if shortfall_pre > 0.0 && !in_event
                in_event = true
                prev_soc = h > 1 ? r.soc[h-1] : r.soc[1]
                push!(soc_vals, prev_soc / total_energy)
            elseif shortfall_pre == 0.0
                in_event = false
            end
        end
    end

    isempty(soc_vals) && return EventStartSoc(
        mean_soc_frac=NaN, p10_soc_frac=NaN,
        pct_events_low_soc_025=NaN, pct_events_low_soc_050=NaN,
        n_shortage_events_total=0)

    ntot = length(soc_vals)
    EventStartSoc(
        mean_soc_frac           = mean(soc_vals),
        p10_soc_frac            = quantile(soc_vals, 0.10),
        pct_events_low_soc_025  = count(x -> x < 0.25, soc_vals) / ntot,
        pct_events_low_soc_050  = count(x -> x < 0.50, soc_vals) / ntot,
        n_shortage_events_total = ntot,
    )
end

"""
    compute_event_start_soc(results, system, scenarios::ScenarioSet) -> EventStartSoc

ScenarioSet overload — extracts the availability array and delegates.
"""
function compute_event_start_soc(results   ::Vector{DispatchResult},
                                   system    ::SystemData,
                                   scenarios ::ScenarioSet)::EventStartSoc
    return compute_event_start_soc(results, system, scenarios.availability)
end
