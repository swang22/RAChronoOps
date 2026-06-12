# ── Market-pattern storage MCS ────────────────────────────────────────────────
#
# Implements behaviorally realistic storage dispatch calibrated from observed
# CAISO aggregate battery operation patterns.  The method replaces the
# reliability-oriented heuristics (M1b, M1c) with a market-like dispatch that
# follows observed charge/discharge patterns (charge midday during solar surplus,
# discharge in the evening ramp), subject to physical SOC feasibility.
#
# Data source: EIA-930 CISO "Net Generation from Other Fuel Sources" 2023.
#   Positive = net discharge, negative = net charge.
#   Patterns are the seasonal × hour-of-day means normalised by the 95th-
#   percentile discharge magnitude (2769 MW for CISO 2023).
#
# Two variants:
#   1. Pure market-pattern — follows observed pattern subject to feasibility.
#      Does NOT increase discharge in scarcity hours beyond the pattern.
#   2. Market-pattern + emergency override — same as (1) outside scarcity;
#      inside scarcity (pre-storage shortfall > 0) switches to emergency
#      discharge (M1c rule): discharge all available SOC up to shortfall.
#
# Research motivation:
#   Emergency-only storage (M1c) may overstate the reliability contribution of
#   storage if real storage is dispatched economically (for price arbitrage or
#   ancillary services) and may be depleted before scarcity hours.  This method
#   tests that hypothesis by applying observed market-like dispatch patterns.
#
# ── Hour→season→pattern mapping ─────────────────────────────────────────────
#
# The simulation uses an 8760-hour year starting 1 Jan.  Month boundaries:
#   Jan: h 1–744  Feb: 745–1416  Mar: 1417–2160  Apr: 2161–2880
#   May: 2881–3624  Jun: 3625–4344  Jul: 4345–5088  Aug: 5089–5832
#   Sep: 5833–6552  Oct: 6553–7296  Nov: 7297–8016  Dec: 8017–8760
# Season (meteorological): winter=DJF, spring=MAM, summer=JJA, fall=SON.

# ── SocBeforeShortage diagnostic struct ─────────────────────────────────────

"""
    SocBeforeShortage

Pre-shortage SOC diagnostics computed from market-pattern dispatch results.

Fields
------
- `mean_soc_frac`          : Mean SOC/E_max in the hour before a shortage hour (all
                             shortage hours, all scenarios)
- `p10_soc_frac`           : 10th-percentile SOC/E_max before shortage
- `pct_low_soc_shortage`   : Fraction of shortage hours where SOC < 25% of E_max
- `n_shortage_hours_total` : Total shortage-hours across all scenarios (raw count)
"""
Base.@kwdef struct SocBeforeShortage
    mean_soc_frac          ::Float64
    p10_soc_frac           ::Float64
    pct_low_soc_shortage   ::Float64
    n_shortage_hours_total ::Int
end

# ────────────────────────────────────────────────────────────────────────────

"""
    load_market_pattern(pattern_csv_path) -> (pat_charge, pat_dis)

Load the season×hour-of-day normalised pattern from the CSV produced by
`build_caiso_storage_patterns.py`.  Returns two 4×24 matrices (season × hour):
  `pat_charge[season_idx, hour+1]`   normalised charge (0-based hour → 1-based col)
  `pat_dis[season_idx, hour+1]`      normalised discharge

Season indices: 1=winter, 2=spring, 3=summer, 4=fall.
"""
function load_market_pattern(pattern_csv_path::String)
    df = CSV.read(pattern_csv_path, DataFrames.DataFrame)
    season_idx = Dict("winter" => 1, "spring" => 2, "summer" => 3, "fall" => 4)

    pat_charge = zeros(Float64, 4, 24)
    pat_dis    = zeros(Float64, 4, 24)

    for row in eachrow(df)
        si = get(season_idx, String(row.season), 0)
        si == 0 && continue
        h  = Int(row.hour) + 1   # 0-based → 1-based column
        pat_charge[si, h] = Float64(row.norm_charge_mean)
        pat_dis[si, h]    = Float64(row.norm_discharge_mean)
    end
    return pat_charge, pat_dis
end

# ── Lookup tables for hour → (season_idx, hour_of_day) ──────────────────────

const _MONTH_START_HOUR = let
    # Cumulative hours at start of each month for a standard (non-leap) year.
    days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    cum  = cumsum([0; days .* 24])   # length 13, cum[1]=0, cum[13]=8760
    cum
end

const _MONTH_OF_HOUR = let
    # For each 1-based hour h (1..8760), the month number (1..12).
    v = Vector{Int}(undef, 8760)
    for h in 1:8760
        h0 = h - 1
        m = findlast(x -> x <= h0, _MONTH_START_HOUR)
        v[h] = m
    end
    v
end

const _SEASON_OF_MONTH = Dict(
    1 => 1, 2 => 1, 12 => 1,   # winter
    3 => 2, 4 => 2,  5 => 2,   # spring
    6 => 3, 7 => 3,  8 => 3,   # summer
    9 => 4, 10 => 4, 11 => 4,  # fall
)

"""
    _hour_season_hod(h) -> (season_idx, hour_of_day_1based)

Return (season_idx, hod) for 1-based hour h in an 8760-hour year.
season_idx: 1=winter, 2=spring, 3=summer, 4=fall.
hod: 1-based column into the pattern matrix (1..24).
"""
@inline function _hour_season_hod(h::Int)
    n_hours = length(_MONTH_OF_HOUR)
    h_clamped = clamp(h, 1, n_hours)
    month = _MONTH_OF_HOUR[h_clamped]
    season_idx = _SEASON_OF_MONTH[month]
    hod = (h_clamped - 1) % 24 + 1   # 1-based
    return season_idx, hod
end

# ────────────────────────────────────────────────────────────────────────────

"""
    run_market_pattern_storage(system, availability, config;
                               pattern_csv, emergency_override=false)
    -> (Vector{DispatchResult}, SocBeforeShortage)

Run Market-pattern storage MCS for every scenario.

`pattern_csv` must be the path to `season_hour_pattern.csv` produced by
`build_caiso_storage_patterns.py`.

`emergency_override=false` → Pure market-pattern variant (Variant 1).
`emergency_override=true`  → Market-pattern + emergency override (Variant 2):
  in any hour with a pre-storage shortfall, emergency discharge overrides the
  pattern (M1c rule: discharge up to available SOC / shortfall limit).

Returns a tuple of:
  - `Vector{DispatchResult}` (same interface as all other methods)
  - `SocBeforeShortage` diagnostics struct
"""
function run_market_pattern_storage(
        system           ::SystemData,
        availability     ::Array{<:Integer, 3},
        _config          ::SimConfig;
        pattern_csv      ::String,
        emergency_override::Bool = false)::Tuple{Vector{DispatchResult}, SocBeforeShortage}

    pat_charge, pat_dis = load_market_pattern(pattern_csv)

    therm   = thermal_generators(system)
    n_therm = nrow(therm)
    n_scen  = size(availability, 1)
    n_hours = system.n_hours

    pmax = Float64.(therm.pmax_mw)

    # ── aggregate storage ───────────────────────────────────────────────────
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

    # ── pre-compute VRE output per hour ────────────────────────────────────
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:n_hours]

    # ── pre-compute pattern values for each hour (vectorised lookup) ────────
    # pat_chg_h[h], pat_dis_h[h] are the pattern fractions for hour h.
    # These are normalised by the 95th-percentile CAISO discharge; scale to
    # this system's storage power capacity.
    pat_chg_h = Vector{Float64}(undef, n_hours)
    pat_dis_h = Vector{Float64}(undef, n_hours)
    for h in 1:n_hours
        si, hod = _hour_season_hod(h)
        pat_chg_h[h] = pat_charge[si, hod]
        pat_dis_h[h] = pat_dis[si, hod]
    end

    results = Vector{DispatchResult}(undef, n_scen)

    # ── diagnostic accumulators ─────────────────────────────────────────────
    soc_before_shortage_vals = Float64[]

    for s in 1:n_scen
        load_shed = zeros(Float64, n_hours)
        st_dis    = zeros(Float64, n_hours)
        st_chg    = zeros(Float64, n_hours)
        soc       = zeros(Float64, n_hours)
        curtailmt = zeros(Float64, n_hours)

        curr_soc = init_soc

        for h in 1:n_hours
            load_h = system.load_mw[h]

            therm_avail = zero(Float64)
            for g in 1:n_therm
                therm_avail += pmax[g] * availability[s, g, h]
            end

            net_supply    = therm_avail + p_vre[h]
            shortfall_pre = max(0.0, load_h - net_supply)
            surplus       = max(0.0, net_supply - load_h)

            dis = 0.0
            chg = 0.0

            if shortfall_pre > 0.0 && total_power > 0.0
                if emergency_override
                    # ── Variant 2: emergency override in scarcity ───────────
                    # Record SOC entering this shortage hour
                    push!(soc_before_shortage_vals, curr_soc / max(total_energy, 1.0))
                    max_dis = min(total_power, curr_soc * eta_dis)
                    dis     = min(shortfall_pre, max_dis)
                    curr_soc -= dis / eta_dis

                else
                    # ── Variant 1: pure market pattern in scarcity too ──────
                    # Record SOC entering this shortage hour
                    push!(soc_before_shortage_vals, curr_soc / max(total_energy, 1.0))

                    # Pattern may call for discharge; apply and then any
                    # remaining shortfall is unserved.
                    target_dis = pat_dis_h[h] * total_power
                    max_dis    = min(total_power, curr_soc * eta_dis)
                    dis        = min(target_dis, max_dis)
                    curr_soc  -= dis / eta_dis
                end

            else
                # ── Non-shortage hour: apply market pattern ─────────────────
                # The pattern net for this hour: either discharge or charge.
                # Since we split a net signal, at most one of pat_dis/pat_chg
                # is > 0 for a given (season, hour).  Handle rare overlap by
                # taking the net direction.
                target_dis = pat_dis_h[h] * total_power
                target_chg = pat_chg_h[h] * total_power

                net_pat = target_dis - target_chg  # positive = discharge, negative = charge

                if net_pat > 0.0
                    # Pattern calls for discharge
                    max_dis  = min(total_power, curr_soc * eta_dis)
                    dis      = min(net_pat, max_dis)
                    curr_soc -= dis / eta_dis
                elseif net_pat < 0.0
                    # Pattern calls for charge; limit by available surplus and headroom
                    target_chg_actual = -net_pat
                    headroom   = total_energy - curr_soc
                    avail_chg  = min(total_power, headroom / eta_ch)
                    # Only charge from surplus (prevents driving curtailment-free charge
                    # when system is net-short without thermal outage, which would be
                    # unphysical for a market-dispatch battery).
                    # Limit charge to surplus + any avoidable load (market battery charges
                    # when prices are low, i.e., surplus hours or near-surplus hours).
                    # We allow charging from any non-shortage hour surplus regardless of
                    # magnitude (market battery charges opportunistically).
                    chg_limit  = min(avail_chg, surplus + total_power)
                    chg        = min(target_chg_actual, chg_limit)
                    chg        = max(0.0, chg)
                    curr_soc  += chg * eta_ch
                end
            end

            # clamp SOC for floating-point safety
            curr_soc = clamp(curr_soc, 0.0, total_energy)

            soc[h]    = curr_soc
            st_dis[h] = dis
            st_chg[h] = chg

            net_bal      = net_supply + dis - chg - load_h
            load_shed[h] = max(0.0, -net_bal)
            curtailmt[h] = max(0.0,  net_bal)
        end

        results[s] = DispatchResult(s, load_shed, st_dis, st_chg, soc,
                                    nothing, curtailmt, 0.0)
    end

    # ── aggregate pre-shortage SOC diagnostics ─────────────────────────────
    soc_diag = if isempty(soc_before_shortage_vals)
        SocBeforeShortage(
            mean_soc_frac          = NaN,
            p10_soc_frac           = NaN,
            pct_low_soc_shortage   = NaN,
            n_shortage_hours_total = 0,
        )
    else
        v     = soc_before_shortage_vals
        ntot  = length(v)
        SocBeforeShortage(
            mean_soc_frac          = mean(v),
            p10_soc_frac           = quantile(v, 0.10),
            pct_low_soc_shortage   = count(x -> x < 0.25, v) / ntot,
            n_shortage_hours_total = ntot,
        )
    end

    return results, soc_diag
end

"""
    run_market_pattern_storage(system, scenarios::ScenarioSet, config; kwargs...)

ScenarioSet overload.
"""
function run_market_pattern_storage(system   ::SystemData,
                                     scenarios::ScenarioSet,
                                     config   ::SimConfig;
                                     kwargs...)
    return run_market_pattern_storage(system, scenarios.availability, config; kwargs...)
end

# ── Convenience wrappers ────────────────────────────────────────────────────

"""
    run_market_pattern_pure(system, availability, config; pattern_csv)
    -> (Vector{DispatchResult}, SocBeforeShortage)

Variant 1: pure market-pattern dispatch (no emergency override in scarcity).
"""
function run_market_pattern_pure(system      ::SystemData,
                                  availability,
                                  config      ::SimConfig;
                                  pattern_csv ::String)
    return run_market_pattern_storage(system, availability, config;
                                      pattern_csv, emergency_override=false)
end

function run_market_pattern_pure(system   ::SystemData,
                                  scenarios::ScenarioSet,
                                  config   ::SimConfig;
                                  pattern_csv::String)
    return run_market_pattern_pure(system, scenarios.availability, config;
                                    pattern_csv)
end

"""
    run_market_pattern_emergency(system, availability, config; pattern_csv)
    -> (Vector{DispatchResult}, SocBeforeShortage)

Variant 2: market pattern outside shortage hours; emergency discharge inside
shortage hours (SOC-limited, shortfall-limited discharge, M1c rule).
"""
function run_market_pattern_emergency(system      ::SystemData,
                                       availability,
                                       config      ::SimConfig;
                                       pattern_csv ::String)
    return run_market_pattern_storage(system, availability, config;
                                      pattern_csv, emergency_override=true)
end

function run_market_pattern_emergency(system   ::SystemData,
                                       scenarios::ScenarioSet,
                                       config   ::SimConfig;
                                       pattern_csv::String)
    return run_market_pattern_emergency(system, scenarios.availability, config;
                                         pattern_csv)
end

# ── SOC-before-shortage diagnostic for any DispatchResult ──────────────────

"""
    compute_soc_before_shortage(results, system) -> SocBeforeShortage

Compute pre-shortage SOC diagnostics from any `Vector{DispatchResult}`.
Uses SOC at the end of the hour immediately before each shortage hour.

For hour h=1 (no previous hour), uses initial SOC (first hour's SOC if that
hour is itself not a shortage hour, else the SOC[1] value).
"""
function compute_soc_before_shortage(results    ::Vector{DispatchResult},
                                      system     ::SystemData)::SocBeforeShortage
    stor = system.storage
    total_energy = nrow(stor) > 0 ? sum(stor.energy_mwh) : 1.0
    if total_energy <= 0.0
        total_energy = 1.0
    end

    soc_vals = Float64[]
    for r in results
        n = length(r.load_shed)
        for h in 1:n
            r.load_shed[h] > 0.0 || continue
            # SOC in the hour before shortage (h-1); for h=1 use SOC[1] as fallback
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
