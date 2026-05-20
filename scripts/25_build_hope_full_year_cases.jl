#!/usr/bin/env julia
# 25_build_hope_full_year_cases.jl
#
# Exports HOPE-native full-year 8760-hour PCM/UC model cases from the
# RAChronoOps RTS-GMLC single-zone processed data.
#
# For each (case, scenario, mode) triple, writes:
#   exports/hope_model_cases/RAChronoOps_<case>_s<NNN>_<mode>/
#     Settings/HOPE_model_settings.yml
#     Data_RAChronoOps_PCM/<csv files>
#     README.md
#
# Thermal outages are imposed through gen_availability_timeseries.csv
# (scenario-specific binary availability from the Markov outage model).
# VRE generators use per-unit capacity-factor profiles.
# network_model=0 (copperplate), all reserves = 0.
#
# gendata.csv row order:
#   G1 ... G_n_therm  — thermal generators (same order as ScenarioSet)
#   G_{n_therm+1}     — aggregated wind (sum of all wind Pmax)
#   G_{n_therm+2}     — aggregated solar (sum of all solar Pmax)
#
# Usage:
#   julia --project=. scripts/25_build_hope_full_year_cases.jl \
#     --cases VRE120_base \
#     --n-scenarios 20 \
#     --seed 42 \
#     --scenario-subset 1 \
#     --modes ED,UC \
#     --out-dir exports/hope_model_cases
#
# Options:
#   --cases            Comma-separated case names (default: VRE120_base)
#   --n-scenarios N    Scenarios to generate for CRN (default: 20)
#   --seed S           RNG seed (default: 42)
#   --scenario-subset  Comma-separated 1-based scenario IDs to export (default: 1)
#   --modes            Comma-separated modes: ED, UC (default: ED,UC)
#   --out-dir          Output root directory (default: exports/hope_model_cases)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Printf, Dates

# ── Constants ─────────────────────────────────────────────────────────────────

const DEFAULT_CASES   = ["VRE120_base"]
const VALID_MODES     = ["ED", "UC"]
const DATA_CASE_NAME  = "Data_RAChronoOps_PCM"
const HOPE_VOLL       = 10_000.0          # $/MWh — matches SimConfig default

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

# ── Calendar helpers ──────────────────────────────────────────────────────────

const _MONTH_DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const _MONTH_CUM  = [0; cumsum(_MONTH_DAYS)]   # length 13, 0-based prefix sums

function hour_to_calendar(h::Int)
    # h: 1-indexed hour of year (1 = Jan 1 01:00 … 8760 = Dec 31 24:00)
    doy = div(h - 1, 24) + 1          # day-of-year, 1-indexed
    hod = mod(h - 1, 24) + 1          # hour-of-day, 1–24
    mon = searchsortedlast(_MONTH_CUM, doy - 1)   # month index 1–12
    day = doy - _MONTH_CUM[mon]
    return mon, day, hod
end

# Build calendar columns for 1:n_hours
function make_calendar_cols(n_hours::Int)
    months = Vector{Int}(undef, n_hours)
    days   = Vector{Int}(undef, n_hours)
    hours  = Vector{Int}(undef, n_hours)
    for h in 1:n_hours
        months[h], days[h], hours[h] = hour_to_calendar(h)
    end
    return months, days, hours
end

# ── HOPE type string ──────────────────────────────────────────────────────────

function hope_type_str(gen_type::AbstractString, fuel::AbstractString)::String
    gt = uppercase(gen_type)
    gt == "WIND"         && return "WindOn"
    gt in ("PV", "RTPV") && return "SolarPV"
    gt == "NUCLEAR"      && return "Nuclear"
    gt == "CT"           && return (fuel == "Oil" ? "OilCT" : "NGCT")
    gt == "CC"           && return "NGCC"
    if gt == "STEAM"
        fuel == "Coal" && return "CoalSteam"
        fuel == "Oil"  && return "OilSteam"
        return "Steam"
    end
    return "Thermal"
end

# ── Case folder naming ────────────────────────────────────────────────────────

case_folder_name(case_name, scenario_id, mode) =
    @sprintf("RAChronoOps_%s_s%03d_%s", case_name, scenario_id, mode)

# ── Writer: Settings/gurobi_settings.yml ─────────────────────────────────────

function write_gurobi_settings(settings_dir::String)
    content = """# Gurobi Solver Parameters
Feasib_Tol: 1.0e-06
Optimal_Tol: 1.0e-04
TimeLimit: 7200
Pre_Solve: -1
Method: 2
MIPGap: 1.0e-03
BarConvTol: 1.0e-08
NumericFocus: 0
Crossover: -1
AggFill: 10
PreDual: -1
"""
    write(joinpath(settings_dir, "gurobi_settings.yml"), content)
end

# ── Writer: Settings/HOPE_model_settings.yml ──────────────────────────────────

function write_settings(settings_dir::String, data_case::String, mode::String)
    mkpath(settings_dir)
    uc = (mode == "UC") ? 1 : 0
    content = """DataCase: $(data_case)/
model_mode: PCM
resource_aggregation: 0
endogenous_rep_day: 0
external_rep_day: 0
flexible_demand: 0
carbon_policy: 0
clean_energy_policy: 0
operation_reserve_mode: 0
network_model: 0
transmission_loss: 0
unit_commitment: $(uc)
solver: gurobi
debug: 0
summary_table: 1
write_shadow_prices: 0
save_postprocess_snapshot: 0
"""
    write(joinpath(settings_dir, "HOPE_model_settings.yml"), content)
end

# ── Writer: zonedata.csv ──────────────────────────────────────────────────────

function write_zonedata(data_dir::String, peak_load_mw::Float64)
    df = DataFrame(
        "Zone_id"     => ["Z1"],
        "Demand (MW)" => [peak_load_mw],
        "State"       => ["RTS"],
        "Area"        => ["RTS"],
    )
    CSV.write(joinpath(data_dir, "zonedata.csv"), df)
end

# ── Writer: gendata.csv — returns n_therm ─────────────────────────────────────

function write_gendata(data_dir::String, sys::SystemData, mode::String)::Int
    therm     = thermal_generators(sys)
    n_therm   = size(therm, 1)
    wind_cap  = wind_capacity_mw(sys)
    solar_cap = solar_capacity_mw(sys)
    n_total   = n_therm + 2
    is_ed     = (mode == "ED")

    # Check whether the generators DataFrame has UC columns (added in
    # BuildRTSSingleZone v2).  Fall back to safe defaults if absent so the
    # exporter still works with older processed-data snapshots.
    has_uc_cols = all(c -> c in names(therm),
                      ["min_up_time_hr", "min_down_time_hr",
                       "ramp_mw_per_min", "startup_cost_dollars"])

    pmax    = Vector{Float64}(undef, n_total)
    pmin    = Vector{Float64}(undef, n_total)
    zones   = fill("Z1", n_total)
    bus_ids = fill("Z1", n_total)
    types   = Vector{String}(undef, n_total)
    f_thm   = Vector{Int}(undef, n_total)
    f_ret   = zeros(Int, n_total)
    f_vre   = Vector{Int}(undef, n_total)
    f_mr    = zeros(Int, n_total)
    cost    = Vector{Float64}(undef, n_total)
    ef      = zeros(Float64, n_total)
    cc      = Vector{Float64}(undef, n_total)
    af      = ones(Float64, n_total)
    for_r   = zeros(Float64, n_total)    # 0: outages imposed via gen_availability
    rm_spin = zeros(Float64, n_total)
    ru      = Vector{Float64}(undef, n_total)
    rd      = Vector{Float64}(undef, n_total)
    f_uc    = zeros(Int, n_total)
    min_dn  = Vector{Int}(undef, n_total)
    min_up  = Vector{Int}(undef, n_total)
    suc     = Vector{Float64}(undef, n_total)

    for (g, row) in enumerate(eachrow(therm))
        gt = row.gen_type

        # UC parameters: use real data when available, safe defaults otherwise
        up_hr  = has_uc_cols ? Float64(row.min_up_time_hr)   : 1.0
        dn_hr  = has_uc_cols ? Float64(row.min_down_time_hr) : 1.0
        ramp   = has_uc_cols ? Float64(row.ramp_mw_per_min)  : 999.0
        sc_tot = has_uc_cols ? Float64(row.startup_cost_dollars) : 0.0

        # Ramp as fraction of Pmax per hour; cap at 1.0 (unconstrained)
        ru_frac = row.pmax_mw > 0 ? min(1.0, ramp * 60.0 / row.pmax_mw) : 1.0
        # Startup cost in $/MW (HOPE convention)
        sc_mw   = row.pmax_mw > 0 ? sc_tot / row.pmax_mw : 0.0

        pmax[g]   = row.pmax_mw
        # ED: Pmin=0 (matches M3 LP relaxation).
        # UC: use real Pmin — HOPE PCM.jl fix (CLeL_con uses pmin variable,
        #     not P_min parameter) makes this safe with operation_reserve_mode=0.
        pmin[g]   = is_ed ? 0.0 : Float64(row.pmin_mw)
        types[g]  = hope_type_str(gt, row.fuel)
        f_thm[g]  = 1
        f_vre[g]  = 0
        f_mr[g]   = 0    # Flag_mustrun conflicts with forced-outage hours
        cost[g]   = row.variable_cost_per_mwh
        cc[g]     = 1.0
        f_uc[g]   = is_ed ? 0 : 1
        min_up[g] = is_ed ? 1 : max(1, round(Int, up_hr))
        min_dn[g] = is_ed ? 1 : max(1, round(Int, dn_hr))
        suc[g]    = is_ed ? 0.0 : sc_mw
        # ED: RU=RD=1.0 disables effective ramp limits (max ramp = Pmax ≥ any
        # hour-to-hour change).  M3's ED LP (M3EDDispatch.jl) has no ramp
        # constraints at all; passing ru_frac here caused HOPE to shed up to
        # 106.6 MW extra per outage-transition hour (root cause of the +107 MWh
        # N=5 EUE discrepancy; fixed 2026-05-19).  See ramp_constraint_root_cause.txt.
        # UC: keep real ramp rates — ramping is a meaningful constraint in MILP.
        ru[g]     = is_ed ? 1.0 : ru_frac
        rd[g]     = is_ed ? 1.0 : ru_frac
    end

    # Aggregated wind (row n_therm+1)
    gw = n_therm + 1
    pmax[gw] = wind_cap; pmin[gw] = 0.0
    types[gw] = "WindOn"; f_thm[gw] = 0; f_vre[gw] = 1; cc[gw] = 0.0; cost[gw] = 0.0
    min_up[gw] = 1; min_dn[gw] = 1; suc[gw] = 0.0; ru[gw] = 1.0; rd[gw] = 1.0

    # Aggregated solar (row n_therm+2)
    gs = n_therm + 2
    pmax[gs] = solar_cap; pmin[gs] = 0.0
    types[gs] = "SolarPV"; f_thm[gs] = 0; f_vre[gs] = 1; cc[gs] = 0.0; cost[gs] = 0.0
    min_up[gs] = 1; min_dn[gs] = 1; suc[gs] = 0.0; ru[gs] = 1.0; rd[gs] = 1.0

    df = DataFrame(
        "Pmax (MW)"              => pmax,
        "Pmin (MW)"              => pmin,
        "Zone"                   => zones,
        "Bus_id"                 => bus_ids,
        "Type"                   => types,
        "Flag_thermal"           => f_thm,
        "Flag_RET"               => f_ret,
        "Flag_VRE"               => f_vre,
        "Flag_mustrun"           => f_mr,
        "Cost (\$/MWh)"          => cost,
        "EF"                     => ef,
        "CC"                     => cc,
        "AF"                     => af,
        "FOR"                    => for_r,
        "RM_SPIN"                => rm_spin,
        "RU"                     => ru,
        "RD"                     => rd,
        "Flag_UC"                => f_uc,
        "Min_down_time"          => min_dn,
        "Min_up_time"            => min_up,
        "Start_up_cost (\$/MW)"  => suc,
    )
    CSV.write(joinpath(data_dir, "gendata.csv"), df)
    return n_therm
end

# ── Writer: load_timeseries_regional.csv — returns max_pu ────────────────────

function write_load_timeseries(data_dir::String,
                                load_mw::Vector{Float64},
                                peak_load_mw::Float64)::Float64
    n = length(load_mw)
    months, days, hours = make_calendar_cols(n)
    z1 = load_mw ./ peak_load_mw
    df = DataFrame(
        "Time Period" => 1:n,
        "Month"       => months,
        "Day"         => days,
        "Hours"       => hours,
        "Z1"          => z1,
        "NI"          => zeros(Float64, n),
    )
    CSV.write(joinpath(data_dir, "load_timeseries_regional.csv"), df)
    return maximum(z1)
end

# ── Writer: gen_availability_timeseries.csv — returns n_avail_cols ───────────

function write_gen_availability(data_dir::String,
                                 sys::SystemData,
                                 scenarios::ScenarioSet,
                                 scenario_id::Int,
                                 n_therm::Int)::Int
    n = sys.n_hours
    months, days, hours = make_calendar_cols(n)

    # Slice this scenario's thermal availability: n_therm × n_hours
    avail = scenarios.availability[scenario_id, :, :]

    df = DataFrame(
        "Time Period" => 1:n,
        "Month"       => months,
        "Day"         => days,
        "Hours"       => hours,
    )
    for g in 1:n_therm
        df[!, "G$g"] = Float64.(avail[g, :])
    end
    df[!, "G$(n_therm + 1)"] = sys.wind_cf    # aggregated wind CF
    df[!, "G$(n_therm + 2)"] = sys.solar_cf   # aggregated solar CF

    CSV.write(joinpath(data_dir, "gen_availability_timeseries.csv"), df)
    return n_therm + 2
end

# ── Writer: wind/solar_timeseries_regional.csv ────────────────────────────────

function write_vre_timeseries(data_dir::String, sys::SystemData)
    n = sys.n_hours
    months, days, hours = make_calendar_cols(n)
    tp = collect(1:n)

    wind_df = DataFrame(
        "Time Period" => tp,
        "Month"       => months,
        "Day"         => days,
        "Hours"       => hours,
        "Z1"          => sys.wind_cf,
    )
    CSV.write(joinpath(data_dir, "wind_timeseries_regional.csv"), wind_df)

    solar_df = DataFrame(
        "Time Period" => tp,
        "Month"       => months,
        "Day"         => days,
        "Hours"       => hours,
        "Z1"          => sys.solar_cf,
    )
    CSV.write(joinpath(data_dir, "solar_timeseries_regional.csv"), solar_df)
end

# ── Writer: storagedata.csv ───────────────────────────────────────────────────

function write_storagedata(data_dir::String, sys::SystemData)
    if size(sys.storage, 1) > 0
        s = sys.storage[1, :]
        df = DataFrame(
            "Zone"                   => ["Z1"],
            "Type"                   => ["BES"],
            "Capacity (MWh)"         => [s.energy_mwh],
            "Max Power (MW)"         => [s.power_mw],
            "Charging efficiency"    => [s.charge_efficiency],
            "Discharging efficiency" => [s.discharge_efficiency],
            "Cost (\$/MWh)"          => [s.variable_cost_per_mwh],
            "EF"                     => [0.0],
            "CC"                     => [0.0],
            "Charging Rate"          => [1.0],
            "Discharging Rate"       => [1.0],
        )
    else
        # No-storage case: write a disabled dummy BES row (Max Power=0, Capacity=0).
        # HOPE requires at least one row; zero power/energy make the unit non-operational.
        df = DataFrame(
            "Zone"                   => ["Z1"],
            "Type"                   => ["BES"],
            "Capacity (MWh)"         => [0.0],
            "Max Power (MW)"         => [0.0],
            "Charging efficiency"    => [1.0],
            "Discharging efficiency" => [1.0],
            "Cost (\$/MWh)"          => [0.0],
            "EF"                     => [0.0],
            "CC"                     => [0.0],
            "Charging Rate"          => [0.0],
            "Discharging Rate"       => [0.0],
        )
    end
    CSV.write(joinpath(data_dir, "storagedata.csv"), df)
end

# ── Writer: single_parameter.csv ─────────────────────────────────────────────

function write_single_parameter(data_dir::String, voll::Float64)
    df = DataFrame(
        "VOLL"                    => [voll],
        "planning_reserve_margin" => [0.0],
        "BigM"                    => [1.0e13],
        "alpha_storage_anchor"    => [0.5],
        "spin_requirement"        => [0.0],
        "delta_spin"              => [1.0 / 6.0],
        "reg_up_requirement"      => [0.0],
        "reg_dn_requirement"      => [0.0],
        "nspin_requirement"       => [0.0],
        "delta_reg"               => [1.0 / 12.0],
        "delta_nspin"             => [0.5],
    )
    CSV.write(joinpath(data_dir, "single_parameter.csv"), df)
end

# ── Writer: carbonpolicies.csv / rpspolicies.csv (unused stubs) ──────────────
# carbon_policy=0 and clean_energy_policy=0 — HOPE reads these files regardless.

function write_policy_stubs(data_dir::String)
    cbp = DataFrame(
        "State"             => ["Z1"],
        "Time Period"       => [1],
        "Allowance (tons)"  => [1.0e18],
    )
    CSV.write(joinpath(data_dir, "carbonpolicies.csv"), cbp)

    rps = DataFrame(
        "From_state" => ["Z1"],
        "To_state"   => ["Z1"],
        "RPS"        => [0.0],
    )
    CSV.write(joinpath(data_dir, "rpspolicies.csv"), rps)
end

# ── Writer: linedata.csv (dummy for network_model=0) ─────────────────────────

function write_linedata(data_dir::String)
    df = DataFrame(
        "From_zone"     => ["Z1"],
        "To_zone"       => ["Z1"],
        "Capacity (MW)" => [1.0e9],
        "X"             => [1.0],
        "Loss (%)"      => [0.0],
    )
    CSV.write(joinpath(data_dir, "linedata.csv"), df)
end

# ── Writer: README.md ─────────────────────────────────────────────────────────

function write_readme(case_dir::String, case_name::String, scenario_id::Int,
                       seed::Int, mode::String, sys::SystemData,
                       peak_load_mw::Float64, annual_load_gwh::Float64,
                       n_therm::Int)
    therm = thermal_generators(sys)
    n_stor_readme = size(sys.storage, 1)
    stor_power_mw  = n_stor_readme > 0 ? Float64(sys.storage[1, :power_mw])   : 0.0
    stor_energy_mwh = n_stor_readme > 0 ? Float64(sys.storage[1, :energy_mwh]) : 0.0
    uc    = (mode == "UC") ? 1 : 0
    content = """# RAChronoOps HOPE Export

## Case Information
- **Source case:** $(case_name)
- **Scenario ID:** $(scenario_id) (1-based)
- **RNG seed:** $(seed)
- **Mode:** $(mode) (unit_commitment = $(uc))
- **Hours:** $(sys.n_hours) (full year)

## System Parameters
- **Peak load:** $(@sprintf("%.1f", peak_load_mw)) MW
- **Annual load:** $(@sprintf("%.1f", annual_load_gwh)) GWh
- **Thermal capacity:** $(@sprintf("%.1f", sum(therm.pmax_mw))) MW ($(size(therm, 1)) units)
- **Wind capacity:** $(@sprintf("%.1f", wind_capacity_mw(sys))) MW (aggregated into 1 generator)
- **Solar capacity:** $(@sprintf("%.1f", solar_capacity_mw(sys))) MW (aggregated into 1 generator)
- **Storage power:** $(@sprintf("%.1f", stor_power_mw)) MW$(n_stor_readme == 0 ? " (no storage — disabled dummy BES exported)" : "")
- **Storage energy:** $(@sprintf("%.1f", stor_energy_mwh)) MWh

## Thermal Outage Representation
Thermal generator availability is imposed through `Data_RAChronoOps_PCM/gen_availability_timeseries.csv`.
Columns G1–G$(n_therm) carry the binary availability (0=forced outage, 1=available) for
scenario $(scenario_id) from the RAChronoOps two-state Markov sequential outage model
(seed=$(seed)). Column G$(n_therm+1) carries the aggregated wind CF profile; G$(n_therm+2)
carries the aggregated solar CF profile.

Generator FOR values in gendata.csv are set to 0 so HOPE does not apply additional
stochastic sampling on top of the imposed scenario.

## Model Settings
- network_model = 0 (copperplate / no transmission constraints)
- All reserve requirements = 0 (consistent with RAChronoOps M3 benchmark)
- VOLL = $(@sprintf("%.0f", HOPE_VOLL)) \$/MWh (same as M3)

## Mode-Specific Notes
$(mode == "ED" ?
  "- ED mode: Pmin = 0 for all thermal generators (consistent with M3 LP relaxation)\n- ED mode: RU = RD = 1.0 for all thermal generators (no ramp constraints; M3 LP has none)" :
  "- UC mode: Pmin = RAChronoOps data values\n- UC mode: RU/RD = actual ramp rates from M3 data (fraction of Pmax per hour)\n- Start-up costs from RAChronoOps data")

## gendata.csv Generator Order
- Rows 1–$(n_therm): thermal generators (same order as ScenarioSet thermal index)
- Row $(n_therm+1): aggregated wind (Type=WindOn)
- Row $(n_therm+2): aggregated solar (Type=SolarPV)
"""
    write(joinpath(case_dir, "README.md"), content)
end

# ── Core export function ──────────────────────────────────────────────────────

function export_hope_case(sys::SystemData, scenarios::ScenarioSet,
                           case_name::String, scenario_id::Int, mode::String,
                           out_dir::String, seed::Int)
    folder_name  = case_folder_name(case_name, scenario_id, mode)
    case_dir     = joinpath(out_dir, folder_name)
    settings_dir = joinpath(case_dir, "Settings")
    data_dir     = joinpath(case_dir, DATA_CASE_NAME)
    mkpath(settings_dir)
    mkpath(data_dir)

    peak_load_mw    = maximum(sys.load_mw)
    annual_load_gwh = sum(sys.load_mw) / 1000.0

    write_settings(settings_dir, DATA_CASE_NAME, mode)
    write_gurobi_settings(settings_dir)
    write_zonedata(data_dir, peak_load_mw)
    n_therm      = write_gendata(data_dir, sys, mode)
    max_pu       = write_load_timeseries(data_dir, sys.load_mw, peak_load_mw)
    write_vre_timeseries(data_dir, sys)
    n_avail_cols = write_gen_availability(data_dir, sys, scenarios, scenario_id, n_therm)
    write_storagedata(data_dir, sys)
    write_single_parameter(data_dir, HOPE_VOLL)
    write_policy_stubs(data_dir)
    write_linedata(data_dir)
    write_readme(case_dir, case_name, scenario_id, seed, mode, sys,
                 peak_load_mw, annual_load_gwh, n_therm)

    # Validation: load reconstruction round-trip error
    load_err_max = maximum(abs.((sys.load_mw ./ peak_load_mw) .* peak_load_mw
                                .- sys.load_mw))

    therm = thermal_generators(sys)
    return (
        case_folder                     = folder_name,
        case_name                       = case_name,
        scenario_id                     = scenario_id,
        mode                            = mode,
        n_hours                         = sys.n_hours,
        n_generators                    = n_therm + 2,
        n_thermal                       = n_therm,
        n_wind                          = 1,
        n_solar                         = 1,
        peak_load_mw                    = peak_load_mw,
        annual_load_gwh                 = annual_load_gwh,
        thermal_capacity_mw             = sum(therm.pmax_mw),
        wind_capacity_mw_val            = wind_capacity_mw(sys),
        solar_capacity_mw_val           = solar_capacity_mw(sys),
        storage_power_mw                = size(sys.storage, 1) > 0 ? Float64(sys.storage[1, :power_mw])   : 0.0,
        storage_energy_mwh              = size(sys.storage, 1) > 0 ? Float64(sys.storage[1, :energy_mwh]) : 0.0,
        nostorage_dummy                 = size(sys.storage, 1) == 0,
        max_load_profile_pu             = max_pu,
        reconstructed_load_error_max_mw = load_err_max,
        availability_rows               = sys.n_hours,
        availability_cols               = n_avail_cols,
        status                          = "OK",
    )
end

# ── Main ──────────────────────────────────────────────────────────────────────

let
    kw = parse_cli(ARGS)

    cases_to_run  = String.(split(get(kw, "cases", "VRE120_base"), ","))
    n_scenarios   = parse(Int, get(kw, "n-scenarios", "20"))
    seed          = parse(Int, get(kw, "seed", "42"))
    scenario_ids  = parse.(Int, split(get(kw, "scenario-subset", "1"), ","))
    modes         = String.(split(get(kw, "modes", "ED,UC"), ","))
    out_dir       = get(kw, "out-dir",
                        joinpath(@__DIR__, "..", "exports", "hope_model_cases"))

    project_root = joinpath(@__DIR__, "..")
    cases_root   = joinpath(project_root, "data_processed", "cases")

    # Validate
    for m in modes
        m in VALID_MODES ||
            error("Unknown mode: $m  (valid: $(join(VALID_MODES, ", ")))")
    end
    for s in scenario_ids
        1 <= s <= n_scenarios ||
            error("scenario-subset $s out of range [1, $n_scenarios]")
    end

    mkpath(out_dir)

    println("="^72)
    println("HOPE Full-Year Case Export")
    println("="^72)
    println("  Cases:           $(join(cases_to_run, ", "))")
    println("  N scenarios:     $n_scenarios  (seed=$seed)")
    println("  Scenario subset: $(join(scenario_ids, ", "))")
    println("  Modes:           $(join(modes, ", "))")
    println("  Output dir:      $out_dir")
    println()

    all_summaries = NamedTuple[]
    t0 = time()

    for case_name in cases_to_run
        case_dir = joinpath(cases_root, case_name)
        isdir(case_dir) || error("Case folder not found: $case_dir")

        print("  Loading $case_name ... ")
        sys = load_system_data(case_dir)
        println("$(sys.n_hours)h  |  therm=$(size(thermal_generators(sys),1))"  *
                "  wind=$(@sprintf("%.0f",wind_capacity_mw(sys))) MW"  *
                "  solar=$(@sprintf("%.0f",solar_capacity_mw(sys))) MW")

        print("  Generating scenarios (n=$n_scenarios, seed=$seed) ... ")
        scenarios = generate_scenarios(sys, n_scenarios, seed)
        println("done  [$(scenarios.n_thermal) thermal × $(scenarios.n_hours) h]")

        for s_id in scenario_ids
            for mode in modes
                folder = case_folder_name(case_name, s_id, mode)
                print("  Exporting $(folder) ... ")
                t1 = time()
                row = export_hope_case(sys, scenarios, case_name, s_id, mode,
                                       out_dir, seed)
                dt = time() - t1
                push!(all_summaries, row)
                @printf("done  (%.1f s)\n", dt)
            end
        end
        println()
    end

    # ── Write export_summary.csv ──────────────────────────────────────────────

    summary_df = DataFrame(
        case_folder                     = [r.case_folder                     for r in all_summaries],
        case_name                       = [r.case_name                       for r in all_summaries],
        scenario_id                     = [r.scenario_id                     for r in all_summaries],
        mode                            = [r.mode                            for r in all_summaries],
        n_hours                         = [r.n_hours                         for r in all_summaries],
        n_generators                    = [r.n_generators                    for r in all_summaries],
        n_thermal                       = [r.n_thermal                       for r in all_summaries],
        n_wind                          = [r.n_wind                          for r in all_summaries],
        n_solar                         = [r.n_solar                         for r in all_summaries],
        peak_load_mw                    = [r.peak_load_mw                    for r in all_summaries],
        annual_load_gwh                 = [r.annual_load_gwh                 for r in all_summaries],
        thermal_capacity_mw             = [r.thermal_capacity_mw             for r in all_summaries],
        wind_capacity_mw                = [r.wind_capacity_mw_val            for r in all_summaries],
        solar_capacity_mw               = [r.solar_capacity_mw_val           for r in all_summaries],
        storage_power_mw                = [r.storage_power_mw                for r in all_summaries],
        storage_energy_mwh              = [r.storage_energy_mwh              for r in all_summaries],
        max_load_profile_pu             = [r.max_load_profile_pu             for r in all_summaries],
        reconstructed_load_error_max_mw = [r.reconstructed_load_error_max_mw for r in all_summaries],
        availability_rows               = [r.availability_rows               for r in all_summaries],
        availability_cols               = [r.availability_cols               for r in all_summaries],
        status                          = [r.status                          for r in all_summaries],
    )
    summary_path = joinpath(out_dir, "export_summary.csv")
    CSV.write(summary_path, summary_df)

    total_time = time() - t0

    # ── Print summary table ───────────────────────────────────────────────────

    println("="^72)
    println("Export Summary")
    println("="^72)
    println("  $(lpad("Case folder", 45))  $(rpad("Mode",3))  $(rpad("Therm",5))  " *
            "$(rpad("Wind MW",8))  $(rpad("Solar MW",9))  $(rpad("Peak MW",8))  Status")
    println("-"^72)
    for r in all_summaries
        @printf("  %-45s  %-3s  %5d  %8.1f  %9.1f  %8.1f  %s\n",
            r.case_folder, r.mode, r.n_thermal,
            r.wind_capacity_mw_val, r.solar_capacity_mw_val,
            r.peak_load_mw, r.status)
    end
    println()
    println("  Validation checks:")
    for r in all_summaries
        n_ok   = (r.n_generators == r.n_thermal + 2)
        pu_ok  = (0.999 <= r.max_load_profile_pu <= 1.001)
        err_ok = (r.reconstructed_load_error_max_mw < 0.001)
        av_ok  = (r.availability_rows == 8760 && r.availability_cols == r.n_thermal + 2)
        mark(b) = b ? "✓" : "✗"
        @printf("    %-45s  n_gen=%s  max_pu=%s  load_err=%s  avail=%s\n",
            r.case_folder,
            mark(n_ok), mark(pu_ok), mark(err_ok), mark(av_ok))
    end
    println()
    @printf("  Total runtime: %.1f s\n", total_time)
    println("  Summary CSV:   $summary_path")
    println()
    println("  Exported folders:")
    for r in all_summaries
        println("    $(joinpath(out_dir, r.case_folder))/")
    end
    println()
    println("  Remaining steps to run HOPE:")
    println("    1. Install HOPE: git clone https://github.com/HOPE-Model-Project/HOPE")
    println("    2. cd <exported_case_folder>")
    println("    3. julia --project=<HOPE_dir> <HOPE_dir>/run_hope.jl \\")
    println("         --settings Settings/HOPE_model_settings.yml")
    println("="^72)
end
