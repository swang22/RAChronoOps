# ── BuildRTSSingleZone ─────────────────────────────────────────────────────
#
# Reads RTS-GMLC source files (if present) and writes five processed CSVs to
# out_dir.  Falls back to a deterministic synthetic 8760-hour system when the
# source data is absent.
#
# generators.csv   : gen_id, gen_type, fuel, pmax_mw, pmin_mw,
#                    variable_cost_per_mwh, forced_outage_rate,
#                    mean_repair_time_hours, is_thermal, is_vre, vre_type
# storage.csv      : storage_id, power_mw, energy_mwh, charge_efficiency,
#                    discharge_efficiency, variable_cost_per_mwh,
#                    initial_soc_mwh
# load_timeseries.csv   : hour, load_mw
# wind_timeseries.csv   : hour, wind_cf
# solar_timeseries.csv  : hour, solar_cf

# ── fuel price table ($/MMBTU) ────────────────────────────────────────────
const _FUEL_PRICE = Dict(
    "Gas"     => 3.0,
    "NG"      => 3.0,
    "Coal"    => 2.0,
    "Oil"     => 5.0,
    "Nuclear" => 0.5,
    "Hydro"   => 0.0,
    "Geothermal" => 0.0,
    "Other"   => 3.0,
)

# ── RTS-GMLC VRE unit-type keywords ──────────────────────────────────────
const _WIND_TYPES  = Set(["WIND", "Wind", "wind"])
const _SOLAR_TYPES = Set(["PV", "RTPV", "Solar", "SOLAR", "pv", "solar"])

# ── helper: find first matching column name ───────────────────────────────
function _col(df::DataFrame, candidates::Vector{String})
    for c in candidates
        c in names(df) && return c
    end
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────
"""
    build_rts_single_zone(rts_dir, out_dir)

Attempt to parse RTS-GMLC CSV files in `rts_dir/SourceData/` and the
matching time-series subdirectories.  Write five processed CSVs to `out_dir`.

If any required source file is missing the function logs a warning and writes
a synthetic fallback dataset instead.
"""
function build_rts_single_zone(rts_dir::String, out_dir::String)
    mkpath(out_dir)
    gen_src = joinpath(rts_dir, "SourceData", "gen.csv")

    if isfile(gen_src)
        @info "RTS-GMLC gen.csv found — building single-zone aggregation"
        _build_from_rts(rts_dir, out_dir)
    else
        @warn "RTS-GMLC source data not found at $rts_dir — using synthetic fallback"
        _build_synthetic(out_dir)
    end
    @info "Processed data written to $out_dir"
end

# ── RTS-GMLC path ─────────────────────────────────────────────────────────
function _build_from_rts(rts_dir::String, out_dir::String)
    gen_raw = CSV.read(joinpath(rts_dir, "SourceData", "gen.csv"), DataFrame)

    # ── map column names robustly ─────────────────────────────────────────
    c_uid   = _col(gen_raw, ["GEN UID", "gen_uid", "UID"])
    c_type  = _col(gen_raw, ["Unit Type", "unit_type", "type", "Type"])
    c_fuel  = _col(gen_raw, ["Fuel", "fuel"])
    c_pmax  = _col(gen_raw, ["Pmax MW", "pmax_mw", "MW Inj"])
    c_pmin  = _col(gen_raw, ["Pmin MW", "pmin_mw"])
    c_for   = _col(gen_raw, ["FOR", "for_rate", "Forced Outage Rate"])
    c_mttr  = _col(gen_raw, ["MTTR Hr", "mttr_hr", "MTTR"])
    c_vom   = _col(gen_raw, ["VOM Cost \$/MWh", "Var OM Cost \$/MWh", "vom_cost"])
    c_hr    = _col(gen_raw, ["HR_avg_0", "heat_rate_mbtu_mwh", "Heat Rate MBTU/MMBTU"])

    for (label, col) in [("GEN UID", c_uid), ("Unit Type", c_type),
                          ("Pmax MW", c_pmax)]
        isnothing(col) && error("Cannot find required column '$label' in gen.csv")
    end

    rows = []
    for r in eachrow(gen_raw)
        uid  = string(r[c_uid])
        utype = isnothing(c_type) ? "Other" : string(r[c_type])
        fuel  = isnothing(c_fuel) ? "Gas"   : string(r[c_fuel])
        pmax  = isnothing(c_pmax) ? 0.0     : Float64(r[c_pmax])
        pmin  = isnothing(c_pmin) ? 0.0     : Float64(r[c_pmin])
        for_  = isnothing(c_for)  ? 0.04    : Float64(r[c_for])
        mttr  = isnothing(c_mttr) ? 24.0    : Float64(r[c_mttr])
        vom   = isnothing(c_vom)  ? 3.0     : Float64(r[c_vom])
        hr    = isnothing(c_hr)   ? 8.0     : Float64(r[c_hr])

        is_wind  = utype in _WIND_TYPES
        is_solar = utype in _SOLAR_TYPES
        is_vre   = is_wind || is_solar
        is_therm = !is_vre && !(occursin("Hydro", utype) || occursin("HYDRO", utype))

        fuel_price = get(_FUEL_PRICE, fuel, get(_FUEL_PRICE, "Other", 3.0))
        var_cost   = vom + hr * fuel_price   # $/MWh

        vre_type = is_wind ? "wind" : (is_solar ? "solar" : "")

        push!(rows, (
            gen_id                  = uid,
            gen_type                = utype,
            fuel                    = fuel,
            pmax_mw                 = pmax,
            pmin_mw                 = pmin,
            variable_cost_per_mwh   = is_vre ? 0.0 : var_cost,
            forced_outage_rate      = is_vre ? 0.0 : for_,
            mean_repair_time_hours  = is_vre ? 0.0 : mttr,
            is_thermal              = is_therm ? 1 : 0,
            is_vre                  = is_vre ? 1 : 0,
            vre_type                = vre_type,
        ))
    end

    gen_df = DataFrame(rows)
    CSV.write(joinpath(out_dir, "generators.csv"), gen_df)

    # ── storage (RTS-GMLC has no battery by default — insert a 100 MW/400 MWh unit)
    stor_df = DataFrame(
        storage_id            = ["S001"],
        power_mw              = [100.0],
        energy_mwh            = [400.0],
        charge_efficiency     = [0.92],
        discharge_efficiency  = [0.92],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [200.0],
    )
    CSV.write(joinpath(out_dir, "storage.csv"), stor_df)

    # ── load time series ──────────────────────────────────────────────────
    load_paths = [
        joinpath(rts_dir, "timeseries_data_files", "Load", "DAY_AHEAD_regional_Load.csv"),
        joinpath(rts_dir, "TimeSeries", "DAY_AHEAD_regional_Load.csv"),
    ]
    load_file = findfirst(isfile, load_paths)
    if !isnothing(load_file)
        raw_load = CSV.read(load_paths[load_file], DataFrame)
        # sum all numeric columns except the first (timestamp / period column)
        num_cols = [c for c in names(raw_load)[2:end]
                    if eltype(raw_load[!, c]) <: Real]
        load_mw = [sum(Float64.(collect(row[num_cols])))
                   for row in eachrow(raw_load)]
        # truncate / pad to 8760
        load_mw = _pad_to_8760(load_mw)
    else
        @warn "RTS-GMLC load time series not found — using synthetic load"
        load_mw = _synthetic_load(8760)
    end
    CSV.write(joinpath(out_dir, "load_timeseries.csv"),
              DataFrame(hour=1:8760, load_mw=load_mw))

    # ── VRE time series (capacity-weighted average CF) ────────────────────
    wind_cap   = sum(filter(r -> r.is_vre == 1 && r.vre_type == "wind",  gen_df).pmax_mw; init=0.0)
    solar_cap  = sum(filter(r -> r.is_vre == 1 && r.vre_type == "solar", gen_df).pmax_mw; init=0.0)

    wind_cf  = _try_load_vre_cf(rts_dir, "WIND",  wind_cap,  8760)
    solar_cf = _try_load_vre_cf(rts_dir, "PV",    solar_cap, 8760)

    CSV.write(joinpath(out_dir, "wind_timeseries.csv"),
              DataFrame(hour=1:8760, wind_cf=wind_cf))
    CSV.write(joinpath(out_dir, "solar_timeseries.csv"),
              DataFrame(hour=1:8760, solar_cf=solar_cf))
end

# ── try to aggregate VRE capacity-factor time series ─────────────────────
function _try_load_vre_cf(rts_dir::String, subdir::String,
                           total_cap::Float64, n::Int)::Vector{Float64}
    ts_root = joinpath(rts_dir, "timeseries_data_files", subdir)
    isdir(ts_root) || return (subdir == "WIND" ? _synthetic_wind_cf(n)
                                               : _synthetic_solar_cf(n))

    csvs = filter(f -> endswith(f, ".csv"), readdir(ts_root))
    isempty(csvs) && return (subdir == "WIND" ? _synthetic_wind_cf(n)
                                              : _synthetic_solar_cf(n))

    weighted_sum = zeros(n)
    cap_sum = 0.0
    for fname in csvs
        df = CSV.read(joinpath(ts_root, fname), DataFrame)
        num_cols = [c for c in names(df)[2:end] if eltype(df[!, c]) <: Real]
        isempty(num_cols) && continue
        # assume each column is one unit; assign equal capacity share
        unit_cap = total_cap / (length(csvs) * length(num_cols))
        for c in num_cols
            vals = _pad_to_8760(Float64.(df[!, c]))
            weighted_sum .+= unit_cap .* vals
            cap_sum += unit_cap
        end
    end
    cap_sum > 0 || return (subdir == "WIND" ? _synthetic_wind_cf(n)
                                            : _synthetic_solar_cf(n))
    return clamp.(weighted_sum ./ cap_sum, 0.0, 1.0)
end

# ── synthetic fallback system ─────────────────────────────────────────────
function _build_synthetic(out_dir::String)
    gen_df = DataFrame(
        gen_id                  = ["G001","G002","G003","G004","G005"],
        gen_type                = ["CT","CC","Coal","Wind","PV"],
        fuel                    = ["Gas","Gas","Coal","Wind","Solar"],
        pmax_mw                 = [100.0, 200.0, 300.0, 200.0, 150.0],
        pmin_mw                 = [ 10.0,  40.0, 100.0,   0.0,   0.0],
        variable_cost_per_mwh   = [ 54.0,  38.0,  28.0,   0.0,   0.0],
        forced_outage_rate      = [0.05, 0.04, 0.08, 0.0, 0.0],
        mean_repair_time_hours  = [24.0, 36.0, 48.0, 0.0, 0.0],
        is_thermal              = [1, 1, 1, 0, 0],
        is_vre                  = [0, 0, 0, 1, 1],
        vre_type                = ["", "", "", "wind", "solar"],
    )
    CSV.write(joinpath(out_dir, "generators.csv"), gen_df)

    stor_df = DataFrame(
        storage_id            = ["S001"],
        power_mw              = [100.0],
        energy_mwh            = [400.0],
        charge_efficiency     = [0.92],
        discharge_efficiency  = [0.92],
        variable_cost_per_mwh = [0.0],
        initial_soc_mwh       = [200.0],
    )
    CSV.write(joinpath(out_dir, "storage.csv"), stor_df)

    n = 8760
    CSV.write(joinpath(out_dir, "load_timeseries.csv"),
              DataFrame(hour=1:n, load_mw=_synthetic_load(n)))
    CSV.write(joinpath(out_dir, "wind_timeseries.csv"),
              DataFrame(hour=1:n, wind_cf=_synthetic_wind_cf(n)))
    CSV.write(joinpath(out_dir, "solar_timeseries.csv"),
              DataFrame(hour=1:n, solar_cf=_synthetic_solar_cf(n)))
end

# ── deterministic synthetic time-series generators ────────────────────────

function _synthetic_load(n::Int)::Vector{Float64}
    # Base 400 MW + daily sinusoid + seasonal + small deterministic noise
    load = Vector{Float64}(undef, n)
    for h in 1:n
        day_frac    = (h - 1) % 24 / 24.0
        season_frac = (h - 1) / 8760.0
        daily       = -80.0 * cos(2π * day_frac)          # peak ~18:00
        seasonal    = 50.0  * sin(π * season_frac)         # summer peak
        noise       = 15.0  * sin(7 * 2π * h / 8760)      # deterministic "noise"
        load[h]     = clamp(400.0 + daily + seasonal + noise, 200.0, 620.0)
    end
    return load
end

function _synthetic_wind_cf(n::Int)::Vector{Float64}
    cf = Vector{Float64}(undef, n)
    for h in 1:n
        hour_of_day  = (h - 1) % 24
        season_phase = 2π * (h - 1) / 8760.0
        # higher at night, higher in winter
        cf[h] = clamp(
            0.30 + 0.08 * cos(2π * hour_of_day / 24)
                 + 0.10 * cos(season_phase)
                 + 0.06 * sin(3 * 2π * h / 8760),
            0.0, 1.0)
    end
    return cf
end

function _synthetic_solar_cf(n::Int)::Vector{Float64}
    cf = zeros(Float64, n)
    for h in 1:n
        hour_of_day  = (h - 1) % 24
        day_of_year  = div(h - 1, 24) + 1
        # sunrise ~6, sunset ~20 for summer; shift ±2 h seasonally
        summer_shift = 2.0 * sin(2π * (day_of_year - 80) / 365)
        rise = 6  - summer_shift
        set  = 20 + summer_shift
        if rise < hour_of_day < set
            frac = (hour_of_day - rise) / (set - rise)   # 0..1
            peak_cf = 0.6 + 0.2 * sin(2π * (day_of_year - 80) / 365)
            cf[h] = clamp(peak_cf * sin(π * frac), 0.0, 1.0)
        end
    end
    return cf
end

# ── utility ───────────────────────────────────────────────────────────────
function _pad_to_8760(v::Vector{<:Real})::Vector{Float64}
    n = length(v)
    if n >= 8760
        return Float64.(v[1:8760])
    else
        return vcat(Float64.(v), fill(Float64(v[end]), 8760 - n))
    end
end
