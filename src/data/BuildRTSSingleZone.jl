# ── BuildRTSSingleZone ─────────────────────────────────────────────────────
#
# Reads RTS-GMLC source files (if present) and writes five processed CSVs to
# out_dir.  Falls back to a deterministic synthetic 168-hour system when the
# source data is absent (test/CI use only).
#
# generators.csv   : gen_id, gen_type, fuel, pmax_mw, pmin_mw,
#                    variable_cost_per_mwh, forced_outage_rate,
#                    mean_repair_time_hours, is_thermal, is_vre, vre_type,
#                    min_up_time_hr, min_down_time_hr, ramp_mw_per_min,
#                    startup_cost_dollars
# storage.csv      : storage_id, power_mw, energy_mwh, charge_efficiency,
#                    discharge_efficiency, variable_cost_per_mwh,
#                    initial_soc_mwh
# load_timeseries.csv   : hour, load_mw            (8760 rows from RTS)
# wind_timeseries.csv   : hour, wind_cf             (8760 rows from RTS)
# solar_timeseries.csv  : hour, solar_cf            (8760 rows from RTS)

# ── unit-type classification ──────────────────────────────────────────────
const _WIND_TYPES  = Set(["WIND", "Wind", "wind"])
const _SOLAR_TYPES = Set(["PV", "RTPV", "Solar", "Solar PV", "Solar RTPV",
                           "SOLAR", "pv", "rtpv", "solar"])
# Resource types that are excluded from the single-zone LP framework.
# These are logged as warnings and skipped; they are not modelled as
# thermal or VRE in this release.
const _EXCLUDED_TYPES = Set(["HYDRO", "ROR", "CSP", "STORAGE", "SYNC_COND",
                              "Hydro", "hydro"])

# ── fuel price fallback table ($/MMBTU) ───────────────────────────────────
const _FUEL_PRICE = Dict(
    "Gas"     => 3.0,  "NG"    => 3.0,
    "Coal"    => 2.0,  "Oil"   => 5.0,
    "Nuclear" => 0.5,  "Hydro" => 0.0,
    "Geothermal" => 0.0, "Solar" => 0.0, "Wind" => 0.0,
    "Other"   => 3.0,
)

# ── helper: find first matching column name (case-sensitive) ─────────────
function _col(df::DataFrame, candidates::Vector{String})
    for c in candidates
        c in names(df) && return c
    end
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────
"""
    build_rts_single_zone(rts_dir, out_dir)

Attempt to parse RTS-GMLC CSV files under `rts_dir` and write five processed
CSVs to `out_dir`.  If any required source file is missing, logs a warning
and writes a synthetic 168-hour fallback dataset instead.

Strict post-build validation is run automatically; an error is thrown when
RTS source files are detected but the output fails validation.
"""
function build_rts_single_zone(rts_dir::String, out_dir::String)
    mkpath(out_dir)

    # Support both the cloned layout (rts_dir/RTS_Data/SourceData/gen.csv)
    # and a flat layout (rts_dir/SourceData/gen.csv).
    rts_root = if isdir(joinpath(rts_dir, "RTS_Data"))
        joinpath(rts_dir, "RTS_Data")
    else
        rts_dir
    end

    gen_src = joinpath(rts_root, "SourceData", "gen.csv")

    if isfile(gen_src)
        @info "RTS-GMLC data detected; building full 8760-hour RTS single-zone dataset"
        @info "  gen.csv path: $gen_src"
        _build_from_rts(rts_root, out_dir)
        _validate_processed_data(out_dir; require_8760 = true)
    else
        @warn "RTS-GMLC data not found at $rts_dir — using 168-hour synthetic fallback"
        _build_synthetic(out_dir)
        _validate_processed_data(out_dir; require_8760 = false)
    end
    @info "Processed data written to $out_dir"
end

# ── read a DAY_AHEAD_*.csv and return hourly summed MW (8760 values) ──────
# Columns 1-4 are Year, Month, Day, Period (date/time metadata, not MW).
# Columns 5+ are per-unit MW values that we sum per hour.
function _read_da_mw(ts_root::String, subdir::String,
                     fname::String, label::String)::Union{Vector{Float64}, Nothing}
    path = joinpath(ts_root, "timeseries_data_files", subdir, fname)
    if !isfile(path)
        @warn "Day-ahead $label file not found: $path — synthetic profile will be used"
        return nothing
    end
    @info "  Reading $label time series: $path"
    df = CSV.read(path, DataFrame)
    # Skip first 4 date/time columns (Year, Month, Day, Period).
    data_cols = names(df)[5:end]
    if isempty(data_cols)
        @warn "No data columns found in $path"
        return nothing
    end
    mw_per_hour = [sum(Float64.(collect(row[data_cols]))) for row in eachrow(df)]
    return _pad_to_8760(mw_per_hour)
end

# ── RTS-GMLC path ─────────────────────────────────────────────────────────
function _build_from_rts(rts_dir::String, out_dir::String)
    gen_raw = CSV.read(joinpath(rts_dir, "SourceData", "gen.csv"), DataFrame)

    # ── column name detection (handles RTS-GMLC standard names) ──────────
    c_uid  = _col(gen_raw, ["GEN UID",   "gen_uid",  "UID"])
    c_type = _col(gen_raw, ["Unit Type", "unit_type","type", "Type"])
    c_fuel = _col(gen_raw, ["Fuel",      "fuel"])
    c_pmax = _col(gen_raw, ["PMax MW",   "Pmax MW",  "pmax_mw",  "MW Inj"])
    c_pmin = _col(gen_raw, ["PMin MW",   "Pmin MW",  "pmin_mw"])
    c_for  = _col(gen_raw, ["FOR",       "for_rate", "Forced Outage Rate"])
    c_mttr = _col(gen_raw, ["MTTR Hr",   "mttr_hr",  "MTTR"])
    c_vom      = _col(gen_raw, ["VOM",       "VOM Cost \$/MWh", "Var OM Cost \$/MWh", "vom_cost"])
    c_hr       = _col(gen_raw, ["HR_avg_0",  "heat_rate_mbtu_mwh", "Heat Rate MBTU/MMBTU"])
    c_fp       = _col(gen_raw, ["Fuel Price \$/MMBTU", "fuel_price"])
    c_min_up   = _col(gen_raw, ["Min Up Time Hr",   "min_up_time_hr",   "MinUpTime"])
    c_min_dn   = _col(gen_raw, ["Min Down Time Hr", "min_down_time_hr", "MinDownTime"])
    c_ramp     = _col(gen_raw, ["Ramp Rate MW/Min", "ramp_rate_mw_per_min", "Ramp Rate"])
    c_nf_start = _col(gen_raw, ["Non Fuel Start Cost \$", "non_fuel_start_cost"])
    c_sh_hot   = _col(gen_raw, ["Start Heat Hot MBTU",   "start_heat_hot_mbtu"])

    for (label, col) in [("GEN UID", c_uid), ("Unit Type", c_type), ("PMax MW", c_pmax)]
        isnothing(col) && error("Cannot find required column '$label' in gen.csv")
    end

    # ── classify and filter generators ────────────────────────────────────
    rows = []
    excluded = Dict{String, Vector{String}}()

    for r in eachrow(gen_raw)
        uid   = string(r[c_uid])
        utype = isnothing(c_type) ? "Other" : string(r[c_type])

        # Skip non-modelled resource types with accumulated warnings.
        if utype in _EXCLUDED_TYPES
            push!(get!(excluded, utype, String[]), uid)
            continue
        end

        fuel  = isnothing(c_fuel) ? "Gas"  : string(r[c_fuel])
        pmax  = isnothing(c_pmax) ? 0.0    : Float64(r[c_pmax])
        pmin  = isnothing(c_pmin) ? 0.0    : Float64(r[c_pmin])
        for_  = isnothing(c_for)  ? 0.04   : Float64(r[c_for])
        mttr  = isnothing(c_mttr) ? 24.0   : Float64(r[c_mttr])
        vom   = isnothing(c_vom)  ? 0.0    : Float64(r[c_vom])
        # HR_avg_0 is in BTU/kWh; divide by 1000 to get MMBTU/MWh.
        hr    = isnothing(c_hr)   ? 8.0    : Float64(r[c_hr]) / 1000.0

        # Prefer the file's fuel price; fall back to lookup table.
        fp = if !isnothing(c_fp)
            raw = r[c_fp]
            ismissing(raw) ? get(_FUEL_PRICE, fuel, 3.0) : Float64(raw)
        else
            get(_FUEL_PRICE, fuel, 3.0)
        end

        is_wind  = utype in _WIND_TYPES
        is_solar = utype in _SOLAR_TYPES
        is_vre   = is_wind || is_solar
        is_therm = !is_vre

        var_cost = is_vre ? 0.0 : vom + hr * fp
        vre_type = is_wind ? "wind" : (is_solar ? "solar" : "")
        for_out  = is_vre ? 0.0 : for_
        mttr_out = is_vre ? 0.0 : mttr

        # UC parameters — zero for VRE (Flag_UC=0 in HOPE)
        min_up = is_vre ? 0.0 : (isnothing(c_min_up) ? 1.0 :
                     Float64(r[c_min_up]))
        min_dn = is_vre ? 0.0 : (isnothing(c_min_dn) ? 1.0 :
                     Float64(r[c_min_dn]))
        ramp   = is_vre ? 0.0 : (isnothing(c_ramp) ? 999.0 :
                     Float64(r[c_ramp]))
        nf_sc  = isnothing(c_nf_start) ? 0.0 : Float64(r[c_nf_start])
        sh_hot = isnothing(c_sh_hot)   ? 0.0 : Float64(r[c_sh_hot])
        suc    = is_vre ? 0.0 : nf_sc + fp * sh_hot   # total hot-start cost ($)

        push!(rows, (
            gen_id                  = uid,
            gen_type                = utype,
            fuel                    = fuel,
            pmax_mw                 = pmax,
            pmin_mw                 = pmin,
            variable_cost_per_mwh   = var_cost,
            forced_outage_rate      = for_out,
            mean_repair_time_hours  = mttr_out,
            is_thermal              = is_therm ? 1 : 0,
            is_vre                  = is_vre   ? 1 : 0,
            vre_type                = vre_type,
            min_up_time_hr          = min_up,
            min_down_time_hr        = min_dn,
            ramp_mw_per_min         = ramp,
            startup_cost_dollars    = suc,
        ))
    end

    # Log excluded resource types.
    for (utype, ids) in sort(collect(excluded))
        sample = join(ids[1:min(3, length(ids))], ", ")
        tail   = length(ids) > 3 ? ", ..." : ""
        @warn "Excluded $(length(ids)) $utype unit(s) — not modelled in this " *
              "single-zone LP framework: $sample$tail"
    end

    gen_df = DataFrame(rows)
    @info "Generator fleet: $(nrow(gen_df)) units written " *
          "($(sum(gen_df.is_thermal)) thermal, $(sum(gen_df.is_vre)) VRE)"
    CSV.write(joinpath(out_dir, "generators.csv"), gen_df)

    # ── load time series ──────────────────────────────────────────────────
    load_path = joinpath(rts_dir, "timeseries_data_files", "Load",
                         "DAY_AHEAD_regional_Load.csv")
    local load_mw
    if isfile(load_path)
        @info "  Reading load time series: $load_path"
        raw_load  = CSV.read(load_path, DataFrame)
        data_cols = names(raw_load)[5:end]   # skip Year,Month,Day,Period
        load_mw   = _pad_to_8760(
            [sum(Float64.(collect(row[data_cols]))) for row in eachrow(raw_load)])
    else
        @warn "Regional load file not found — using synthetic load profile"
        load_mw = _synthetic_load(8760)
    end
    CSV.write(joinpath(out_dir, "load_timeseries.csv"),
              DataFrame(hour = 1:8760, load_mw = load_mw))

    # ── capacity denominators for CF normalisation ─────────────────────────
    wind_cap  = let df = filter(r -> r.is_vre == 1 && r.vre_type == "wind",  gen_df)
        isempty(df) ? 0.0 : sum(df.pmax_mw)
    end
    solar_cap = let df = filter(r -> r.is_vre == 1 && r.vre_type == "solar", gen_df)
        isempty(df) ? 0.0 : sum(df.pmax_mw)
    end
    @info "  Total wind capacity: $(wind_cap) MW, total solar capacity: $(solar_cap) MW"

    # ── wind capacity factor ──────────────────────────────────────────────
    wind_mw = _read_da_mw(rts_dir, "WIND", "DAY_AHEAD_wind.csv", "wind")
    wind_cf = if !isnothing(wind_mw) && wind_cap > 0.0
        clamp.(wind_mw ./ wind_cap, 0.0, 1.0)
    else
        @warn "Wind time series unavailable or zero capacity — using synthetic wind CF"
        _synthetic_wind_cf(8760)
    end
    CSV.write(joinpath(out_dir, "wind_timeseries.csv"),
              DataFrame(hour = 1:8760, wind_cf = wind_cf))

    # ── solar capacity factor (utility PV + rooftop PV) ────────────────────
    pv_mw   = _read_da_mw(rts_dir, "PV",   "DAY_AHEAD_pv.csv",   "utility PV")
    rtpv_mw = _read_da_mw(rts_dir, "RTPV", "DAY_AHEAD_rtpv.csv", "rooftop PV (RTPV)")

    solar_mw = if !isnothing(pv_mw) && !isnothing(rtpv_mw)
        pv_mw .+ rtpv_mw
    elseif !isnothing(pv_mw)
        pv_mw
    elseif !isnothing(rtpv_mw)
        rtpv_mw
    else
        nothing
    end

    solar_cf = if !isnothing(solar_mw) && solar_cap > 0.0
        clamp.(solar_mw ./ solar_cap, 0.0, 1.0)
    else
        @warn "Solar time series unavailable or zero capacity — using synthetic solar CF"
        _synthetic_solar_cf(8760)
    end
    CSV.write(joinpath(out_dir, "solar_timeseries.csv"),
              DataFrame(hour = 1:8760, solar_cf = solar_cf))

    # ── storage: one aggregate 4-hour battery scaled to 10% of peak load ──
    peak_load   = maximum(load_mw)
    stor_power  = round(0.10 * peak_load; digits = 0)
    stor_energy = 4.0 * stor_power
    eta         = sqrt(0.90)   # charge = discharge = √0.90 → round-trip ≈ 90%
    stor_df = DataFrame(
        storage_id            = ["BAT_4H_10PCT"],
        power_mw              = [stor_power],
        energy_mwh            = [stor_energy],
        charge_efficiency     = [eta],
        discharge_efficiency  = [eta],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [0.5 * stor_energy],
    )
    @info "  Storage: $(stor_power) MW / $(stor_energy) MWh " *
          "(10% of peak load $(round(peak_load; digits=1)) MW, 4-hour duration)"
    CSV.write(joinpath(out_dir, "storage.csv"), stor_df)
end

# ── post-build validation ─────────────────────────────────────────────────
function _validate_processed_data(out_dir::String; require_8760::Bool = false)
    gen_path   = joinpath(out_dir, "generators.csv")
    stor_path  = joinpath(out_dir, "storage.csv")
    load_path  = joinpath(out_dir, "load_timeseries.csv")
    wind_path  = joinpath(out_dir, "wind_timeseries.csv")
    solar_path = joinpath(out_dir, "solar_timeseries.csv")

    for p in (gen_path, stor_path, load_path, wind_path, solar_path)
        isfile(p) || error("Validation failed: missing file $p")
    end

    gen_df   = CSV.read(gen_path,   DataFrame)
    stor_df  = CSV.read(stor_path,  DataFrame)
    load_df  = CSV.read(load_path,  DataFrame)
    wind_df  = CSV.read(wind_path,  DataFrame)
    solar_df = CSV.read(solar_path, DataFrame)

    n = nrow(load_df)
    if require_8760
        n == 8760 || error(
            "Validation failed: load_timeseries.csv has $n rows (expected 8760). " *
            "RTS-GMLC source files were detected, so this is not expected. " *
            "Check _build_from_rts for errors.")
        nrow(wind_df)  == 8760 || error(
            "Validation failed: wind_timeseries.csv has $(nrow(wind_df)) rows (expected 8760).")
        nrow(solar_df) == 8760 || error(
            "Validation failed: solar_timeseries.csv has $(nrow(solar_df)) rows (expected 8760).")
    end

    all(load_df.load_mw .> 0)           || error("Validation failed: load_mw has non-positive values")
    all(0.0 .<= wind_df.wind_cf .<= 1.0)    || error("Validation failed: wind_cf outside [0,1]")
    all(0.0 .<= solar_df.solar_cf .<= 1.0)  || error("Validation failed: solar_cf outside [0,1]")

    therm = filter(r -> r.is_thermal == 1, gen_df)
    nrow(therm) > 0         || error("Validation failed: no thermal generators found")
    sum(therm.pmax_mw) > 0  || error("Validation failed: total thermal capacity is 0 MW")

    vre = filter(r -> r.is_vre == 1, gen_df)
    nrow(vre) > 0 || @warn "Validation warning: no VRE generators found"

    nrow(stor_df) > 0                   || error("Validation failed: storage.csv is empty")
    all(stor_df.power_mw  .> 0)         || error("Validation failed: storage power_mw ≤ 0")
    all(stor_df.energy_mwh .> 0)        || error("Validation failed: storage energy_mwh ≤ 0")

    @info "Validation passed: $n hours | " *
          "$(nrow(therm)) thermal ($(round(sum(therm.pmax_mw); digits=0)) MW) | " *
          "$(nrow(vre)) VRE | " *
          "$(nrow(stor_df)) storage unit(s)"
end

# ── synthetic fallback system (168 hours, test/CI only) ──────────────────
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
        min_up_time_hr          = [1.0, 2.0, 4.0, 0.0, 0.0],
        min_down_time_hr        = [1.0, 2.0, 4.0, 0.0, 0.0],
        ramp_mw_per_min         = [3.0, 4.0, 2.0, 0.0, 0.0],
        startup_cost_dollars    = [50.0, 5000.0, 3000.0, 0.0, 0.0],
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

    n = 168   # 1-week horizon — fast for tests; not for formal RA studies
    CSV.write(joinpath(out_dir, "load_timeseries.csv"),
              DataFrame(hour = 1:n, load_mw  = _synthetic_load(n)))
    CSV.write(joinpath(out_dir, "wind_timeseries.csv"),
              DataFrame(hour = 1:n, wind_cf  = _synthetic_wind_cf(n)))
    CSV.write(joinpath(out_dir, "solar_timeseries.csv"),
              DataFrame(hour = 1:n, solar_cf = _synthetic_solar_cf(n)))
end

# ── deterministic synthetic time-series generators ────────────────────────

function _synthetic_load(n::Int)::Vector{Float64}
    load = Vector{Float64}(undef, n)
    for h in 1:n
        day_frac    = (h - 1) % 24 / 24.0
        season_frac = (h - 1) / 8760.0
        daily       = -80.0 * cos(2π * day_frac)
        seasonal    = 50.0  * sin(π * season_frac)
        noise       = 15.0  * sin(7 * 2π * h / 8760)
        load[h]     = clamp(400.0 + daily + seasonal + noise, 200.0, 620.0)
    end
    return load
end

function _synthetic_wind_cf(n::Int)::Vector{Float64}
    cf = Vector{Float64}(undef, n)
    for h in 1:n
        hour_of_day  = (h - 1) % 24
        season_phase = 2π * (h - 1) / 8760.0
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
        hour_of_day = (h - 1) % 24
        day_of_year = div(h - 1, 24) + 1
        summer_shift = 2.0 * sin(2π * (day_of_year - 80) / 365)
        rise = 6  - summer_shift
        set  = 20 + summer_shift
        if rise < hour_of_day < set
            frac    = (hour_of_day - rise) / (set - rise)
            peak_cf = 0.6 + 0.2 * sin(2π * (day_of_year - 80) / 365)
            cf[h]   = clamp(peak_cf * sin(π * frac), 0.0, 1.0)
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
