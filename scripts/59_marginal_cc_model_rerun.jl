#!/usr/bin/env julia
# 59_marginal_cc_model_rerun.jl
#
# Recomputes normalized marginal storage capacity credit (CC) using explicit
# model reruns for the perfect-resource denominator, replacing the analytical
# post-processing formula Σ_h max(0, shed[h] - δ).
#
# Formula:
#   CC(δ) = [EUE(x) - EUE(x + δ_storage)] / [EUE(x) - EUE(x + δ_perfect)]
#
# EUE(x + δ_perfect) comes from an explicit model rerun with a δ MW
# perfect-firm generator added (FOR=0, always available, zero cost).
#
# CRN-preserving approach for M3:
#   1. Generate scenarios with original system  →  avail_orig [N, n_therm, T]
#   2. Extend:  avail_perf = cat(avail_orig, ones(Int8,N,1,T); dims=2)
#   Thermal outage draws in columns 1..n_therm are identical across all runs.
#
# For HOPE, baseline gen_availability_timeseries.csv already materialises the
# thermal outage draws; inserting G74=1.0 preserves those draws exactly.
#
# The analytical denominator is retained as a diagnostic comparison column.
#
# Models: Full-year ED (M3), HOPE-PCM-ED
# Cases:  VRE120_base (N=20), VRE120_wind_hvy (N=5)
# Deltas: 1, 5, 10 MW
#
# Outputs:
#   results/paper_tables/marginal_cc_model_rerun_validation.csv
#
# Usage:
#   julia --project=. scripts/59_marginal_cc_model_rerun.jl \
#     [--hope-path "D:/MIT Dropbox/Shen Wang/MIT/RA/HOPE_project"]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics, Printf, Dates

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional argument: $arg")
        key = arg[3:end]
        (i + 1 <= length(args) && !startswith(args[i+1], "--")) ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

let kw = parse_cli(ARGS)
    global HOPE_PATH = get(kw, "hope-path",
                           "D:/MIT Dropbox/Shen Wang/MIT/RA/HOPE_project")
    global JULIA_EXE = get(kw, "julia-exe",
                           replace(joinpath(Sys.BINDIR, "julia"), "\\" => "/"))
end

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

const CASES_N    = [("VRE120_base", 20), ("VRE120_wind_hvy", 5)]
const DELTA_MWS  = [1.0, 5.0, 10.0]
const DURATION_H = 4.0    # storage energy-to-power ratio (hours)
const SEED       = 42

const REPO       = abspath(joinpath(@__DIR__, ".."))
const CASES_DIR  = abspath(joinpath(REPO, "exports", "hope_model_cases"))
const DATA_ROOT  = abspath(joinpath(REPO, "data_processed", "cases"))
const TAB_DIR    = abspath(joinpath(REPO, "results", "paper_tables"))

mkpath(TAB_DIR)

HOPE_PATH_FWD = replace(HOPE_PATH, "\\" => "/")
JULIA_EXE_FWD = replace(JULIA_EXE, "\\" => "/")

# ─────────────────────────────────────────────────────────────────────────────
# Helpers — EUE
# ─────────────────────────────────────────────────────────────────────────────

eue_from_shed(shed::Vector{Float64}) = sum(shed)

function eue_analytical_perfect(shed::Vector{Float64}, δ::Float64)::Float64
    total = 0.0
    for v in shed
        d = v - δ
        total += d > 0.0 ? d : 0.0
    end
    return total
end

function eue_mean_m3(results::Vector{DispatchResult})::Float64
    isempty(results) && return 0.0
    return mean(sum(r.load_shed) for r in results)
end

function eue_analytical_perfect_m3(results::Vector{DispatchResult}, δ::Float64)::Float64
    isempty(results) && return 0.0
    return mean(sum(max(0.0, v - δ) for v in r.load_shed) for r in results)
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers — HOPE I/O
# ─────────────────────────────────────────────────────────────────────────────

function load_hope_loadshed(output_dir::String)::Vector{Float64}
    csv_path = joinpath(output_dir, "power_loadshedding.csv")
    isfile(csv_path) || error("Missing HOPE output: $csv_path")
    df  = CSV.read(csv_path, DataFrame)
    row = df[1, :]
    return [Float64(row[Symbol("h$h")]) for h in 1:8760]
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers — M3 system modifications
# ─────────────────────────────────────────────────────────────────────────────

function with_marginal_storage(sys::SystemData, δ::Float64, dur::Float64)::SystemData
    eta   = sqrt(0.90)
    extra = DataFrame(
        storage_id            = ["MARG_$(δ)MW"],
        power_mw              = [δ],
        energy_mwh            = [δ * dur],
        charge_efficiency     = [eta],
        discharge_efficiency  = [eta],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [δ * dur * 0.5],
    )
    return SystemData(sys.generators, vcat(sys.storage, extra),
                      sys.load_mw, sys.wind_cf, sys.solar_cf, sys.n_hours)
end

function with_perfect_firm(sys::SystemData, δ::Float64)::SystemData
    # CSV.jl reads string columns as InlineString (fixed-width, e.g. String7).
    # Widen all string columns to String before vcat so longer names don't overflow.
    gens = copy(sys.generators)
    for col in names(gens)
        if eltype(gens[!, col]) <: AbstractString
            gens[!, col] = String.(gens[!, col])
        end
    end
    perf = copy(gens[1:1, :])
    perf[1, :gen_id]                 = "PERFECT_$(δ)MW"
    perf[1, :gen_type]               = "PerfectFirm"
    perf[1, :fuel]                   = "Other"
    perf[1, :pmax_mw]                = δ
    perf[1, :pmin_mw]                = 0.0
    perf[1, :variable_cost_per_mwh]  = 0.0
    perf[1, :forced_outage_rate]     = 0.0
    perf[1, :mean_repair_time_hours] = 0.0
    perf[1, :is_thermal]             = 1
    perf[1, :is_vre]                 = 0
    perf[1, :vre_type]               = ""
    return SystemData(vcat(gens, perf), sys.storage,
                      sys.load_mw, sys.wind_cf, sys.solar_cf, sys.n_hours)
end

# Append a column of ones after the existing thermal availability columns.
# CRN is preserved: columns 1..n_therm are untouched.
function avail_with_perfect_firm(avail_orig::Array{Int8,3})::Array{Int8,3}
    N, _, T = size(avail_orig)
    return cat(avail_orig, ones(Int8, N, 1, T); dims=2)
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers — HOPE case naming
# ─────────────────────────────────────────────────────────────────────────────

baseline_folder(case::String, s_id::Int) =
    "RAChronoOps_$(case)_s$(lpad(s_id, 3, '0'))_ED"

marginal_folder(case::String, δ::Float64, s_id::Int) =
    "RAChronoOps_$(case)_marg$(round(Int, δ))mw_s$(lpad(s_id, 3, '0'))_ED"

perfect_folder(case::String, δ::Float64, s_id::Int) =
    "RAChronoOps_$(case)_perf$(round(Int, δ))mw_s$(lpad(s_id, 3, '0'))_ED"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers — HOPE perfect-firm case export
# ─────────────────────────────────────────────────────────────────────────────

function _rm_retry(path::String; retries::Int = 8, delay::Float64 = 0.5)
    for attempt in 1:retries
        try
            rm(path; recursive = true, force = true)
            return true
        catch
            attempt < retries && sleep(delay)
        end
    end
    return false
end

function export_perfect_case!(case::String, δ::Float64, s_id::Int,
                               cases_dir::String)::String
    src = joinpath(cases_dir, baseline_folder(case, s_id))
    dst = joinpath(cases_dir, perfect_folder(case, δ, s_id))
    isdir(src) || error("Baseline folder not found: $src")

    # A marker file means inputs were fully modified; skip recreation.
    # This preserves valid HOPE outputs from a previous successful run.
    marker = joinpath(dst, ".perf_ready")
    isfile(marker) && return dst

    # Remove any incomplete folder from a prior failed attempt
    if isdir(dst)
        _rm_retry(dst) || error("Cannot remove incomplete folder (locked?): $dst")
    end
    cp(src, dst; force = false)

    # Remove any output copied from the baseline (retry on Windows EBUSY)
    out_dir = joinpath(dst, "output")
    if isdir(out_dir)
        if !_rm_retry(out_dir)
            # Last resort: just delete the file that triggers skip-if-done
            shed = joinpath(out_dir, "power_loadshedding.csv")
            isfile(shed) && rm(shed; force = true)
        end
    end
    for entry in readdir(dst; join = true)
        startswith(basename(entry), "output_tmp") &&
            _rm_retry(entry)
    end

    # ── Modify gendata.csv ────────────────────────────────────────────────────
    # Original: 73 thermal rows + WindOn row + SolarPV row = 75 rows total.
    # After:    73 thermal rows + PerfectFirm row + WindOn row + SolarPV row = 76 rows.
    gd_path = joinpath(dst, "Data_RAChronoOps_PCM", "gendata.csv")
    gd      = CSV.read(gd_path, DataFrame)
    cn      = names(gd)   # 21 column names (may contain special chars)

    # Copy first thermal row as a template, then override every field
    perf_row = copy(gd[1:1, :])
    perf_row[1, cn[1]]  = δ              # Pmax (MW)
    perf_row[1, cn[2]]  = 0.0           # Pmin (MW)
    perf_row[1, cn[3]]  = "Z1"          # Zone
    perf_row[1, cn[4]]  = "Z1"          # Bus_id
    perf_row[1, cn[5]]  = "PerfectFirm" # Type
    perf_row[1, cn[6]]  = 1             # Flag_thermal
    perf_row[1, cn[7]]  = 0             # Flag_RET
    perf_row[1, cn[8]]  = 0             # Flag_VRE
    perf_row[1, cn[9]]  = 0             # Flag_mustrun
    perf_row[1, cn[10]] = 0.0           # Cost ($/MWh)
    perf_row[1, cn[11]] = 0.0           # EF
    perf_row[1, cn[12]] = 1.0           # CC
    perf_row[1, cn[13]] = 1.0           # AF
    perf_row[1, cn[14]] = 0.0           # FOR
    perf_row[1, cn[15]] = 0.0           # RM_SPIN
    perf_row[1, cn[16]] = 1.0           # RU
    perf_row[1, cn[17]] = 1.0           # RD
    perf_row[1, cn[18]] = 0             # Flag_UC
    perf_row[1, cn[19]] = 1             # Min_down_time
    perf_row[1, cn[20]] = 1             # Min_up_time
    perf_row[1, cn[21]] = 0.0           # Start_up_cost ($/MW)

    # Insert: thermal rows (1..end-2) | PerfectFirm | WindOn | SolarPV
    new_gd = vcat(gd[1:end-2, :], perf_row, gd[end-1:end, :])
    CSV.write(gd_path, new_gd)

    # ── Modify gen_availability_timeseries.csv ────────────────────────────────
    # Original columns: Time Period, Month, Day, Hours, G1..G73, G74(wind), G75(solar)
    # After:            Time Period, Month, Day, Hours, G1..G73, G74(1.0), G75(wind), G76(solar)
    ga_path = joinpath(dst, "Data_RAChronoOps_PCM", "gen_availability_timeseries.csv")
    ga      = CSV.read(ga_path, DataFrame)

    # Save wind/solar columns, drop them, then re-append in new order
    wind_col  = ga[:, "G74"]
    solar_col = ga[:, "G75"]
    select!(ga, Not(["G74", "G75"]))  # retain Time Period, Month, Day, Hours, G1..G73
    ga[!, "G74"] = ones(Float64, size(ga, 1))  # perfect-firm: always available
    ga[!, "G75"] = wind_col           # wind CF  (was G74)
    ga[!, "G76"] = solar_col          # solar CF (was G75)

    CSV.write(ga_path, ga)

    # Mark setup as complete so future re-runs don't recreate the folder
    write(marker, "")
    return dst
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers — HOPE runner
# ─────────────────────────────────────────────────────────────────────────────

function run_hope_case(case_path::String; skip_if_done::Bool = true)::Symbol
    shed_csv = joinpath(case_path, "output", "power_loadshedding.csv")
    skip_if_done && isfile(shed_csv) && return :skipped
    cp_fwd = replace(abspath(case_path), "\\" => "/")
    code   = """using HOPE; HOPE.run_hope("$cp_fwd")"""
    cmd    = Cmd([JULIA_EXE_FWD, "--project=$HOPE_PATH_FWD", "-e", code])
    try
        run(cmd; wait = true)
        return :ok
    catch e
        @warn "HOPE failed: $(basename(case_path))\n  $(sprint(showerror, e))"
        return :failed
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Header
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 70)
println("59_marginal_cc_model_rerun.jl")
println("Date:       ", Dates.now())
println("HOPE path:  ", HOPE_PATH_FWD)
println("Julia exe:  ", JULIA_EXE_FWD)
println("Cases:      ", join(first.(CASES_N), ", "))
println("delta (MW): ", join(DELTA_MWS, ", "))
println("=" ^ 70)

# ─────────────────────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────────────────────

all_rows = NamedTuple[]

for (case, n_hope) in CASES_N
    println("\n" * "─" ^ 70)
    println("Case: $case  (N=$n_hope)")
    println("─" ^ 70)

    case_dir = joinpath(DATA_ROOT, case)
    isdir(case_dir) || error("Case directory not found: $case_dir")
    sys      = load_system_data(case_dir)
    scen_ids = collect(1:n_hope)

    # ── M3: generate scenarios once for this case ─────────────────────────────
    println("\n  [M3] Generating $n_hope scenarios (seed=$SEED)…")
    cfg        = SimConfig(n_scenarios = n_hope, seed = SEED)
    scen       = generate_scenarios(sys, cfg)
    avail_orig = scen.availability                     # [N, n_therm, 8760]
    avail_perf = avail_with_perfect_firm(avail_orig)   # [N, n_therm+1, 8760]
    N, n_therm, T = size(avail_orig)
    @printf("  availability: [%d scenarios, %d thermal gens, %d hours]\n",
            N, n_therm, T)

    # ── M3: baseline ──────────────────────────────────────────────────────────
    println("\n  [M3] Running baseline…")
    t0 = time()
    res_base_m3 = run_m3_ed_dispatch(sys, avail_orig, cfg)
    eue_base_m3 = eue_mean_m3(res_base_m3)
    @printf("  M3 baseline:  EUE = %.3f MWh  (%.1f s)\n", eue_base_m3, time()-t0)

    # ── M3: per-delta runs ────────────────────────────────────────────────────
    for δ in DELTA_MWS
        @printf("\n  [M3] delta = %.0f MW\n", δ)

        # Analytical denominator from baseline shed (post-processing comparison)
        eue_perf_m3_anal  = eue_analytical_perfect_m3(res_base_m3, δ)
        denom_m3_anal     = eue_base_m3 - eue_perf_m3_anal

        # +Storage: same thermal scenarios (avail_orig)
        sys_stor = with_marginal_storage(sys, δ, DURATION_H)
        t0 = time()
        res_stor_m3 = run_m3_ed_dispatch(sys_stor, avail_orig, cfg)
        eue_stor_m3 = eue_mean_m3(res_stor_m3)
        numer_m3    = eue_base_m3 - eue_stor_m3
        @printf("    +storage: EUE=%.3f  ΔEUEstor=%.4f  (%.1f s)\n",
                eue_stor_m3, numer_m3, time()-t0)

        # +Perfect-firm: extended avail (CRN-preserving; perfect-firm always available)
        sys_perf = with_perfect_firm(sys, δ)
        t0 = time()
        res_perf_m3       = run_m3_ed_dispatch(sys_perf, avail_perf, cfg)
        eue_perf_m3_rerun = eue_mean_m3(res_perf_m3)
        denom_m3_rerun    = eue_base_m3 - eue_perf_m3_rerun
        @printf("    +perfect: EUE=%.3f  ΔEUEperf_rerun=%.4f  ΔEUEperf_anal=%.4f  (%.1f s)\n",
                eue_perf_m3_rerun, denom_m3_rerun, denom_m3_anal, time()-t0)

        cc_m3_rerun = denom_m3_rerun > 1e-9 ? numer_m3 / denom_m3_rerun : NaN
        cc_m3_anal  = denom_m3_anal  > 1e-9 ? numer_m3 / denom_m3_anal  : NaN
        @printf("    CC_rerun=%.5f  CC_anal=%.5f\n",
                isnan(cc_m3_rerun) ? NaN : cc_m3_rerun,
                isnan(cc_m3_anal)  ? NaN : cc_m3_anal)

        push!(all_rows, (
            case                              = case,
            model                             = "Full-year ED (M3)",
            n_scen                            = n_hope,
            delta_mw                          = δ,
            eue_baseline_mwh                  = eue_base_m3,
            eue_plus_storage_mwh              = eue_stor_m3,
            eue_plus_perfect_rerun_mwh        = eue_perf_m3_rerun,
            eue_plus_perfect_analytical_mwh   = eue_perf_m3_anal,
            delta_eue_storage_mwh             = numer_m3,
            delta_eue_perfect_rerun_mwh       = denom_m3_rerun,
            delta_eue_perfect_analytical_mwh  = denom_m3_anal,
            normalized_marginal_cc_rerun      = cc_m3_rerun,
            normalized_marginal_cc_analytical = cc_m3_anal,
            cc_error_rerun_vs_m3              = 0.0,
            cc_error_analytical_vs_m3         = 0.0,
            cc_greater_than_one_rerun         = !isnan(cc_m3_rerun) && cc_m3_rerun > 1.0,
        ))
    end

    # ── HOPE: read existing baseline sheds ────────────────────────────────────
    println("\n  [HOPE] Reading baseline load-shed (N=$n_hope) from script 57 folders…")
    baseline_sheds = Dict{Int, Vector{Float64}}()
    for s_id in scen_ids
        out_dir = joinpath(CASES_DIR, baseline_folder(case, s_id), "output")
        baseline_sheds[s_id] = load_hope_loadshed(out_dir)
    end
    eue_base_hope = mean(eue_from_shed(baseline_sheds[s]) for s in scen_ids)
    @printf("  HOPE baseline EUE = %.3f MWh\n", eue_base_hope)

    # ── HOPE: export perfect-firm cases ───────────────────────────────────────
    println("\n  [HOPE] Exporting perfect-firm case folders…")
    n_exported = 0
    for δ in DELTA_MWS, s_id in scen_ids
        dst = export_perfect_case!(case, δ, s_id, CASES_DIR)
        isdir(joinpath(dst, "output")) || (n_exported += 1)
    end
    @printf("  Exported %d new folders  (total: %d)\n",
            n_exported, length(DELTA_MWS) * n_hope)

    # ── HOPE: run and collect results per delta ───────────────────────────────
    for δ in DELTA_MWS
        @printf("\n  [HOPE] delta = %.0f MW — running perfect-firm cases…\n", δ)
        n_ok = 0; n_skip = 0; n_fail = 0
        for s_id in scen_ids
            folder = joinpath(CASES_DIR, perfect_folder(case, δ, s_id))
            t0     = time()
            status = run_hope_case(folder; skip_if_done = true)
            rt     = time() - t0
            if status == :ok
                n_ok   += 1
                @printf("    s%03d  OK  (%.0f s)\n", s_id, rt)
            elseif status == :skipped
                n_skip += 1
                @printf("    s%03d  skipped\n", s_id)
            else
                n_fail += 1
                @printf("    s%03d  FAILED\n", s_id)
            end
        end
        @printf("  Runs: %d ok, %d skipped, %d failed\n", n_ok, n_skip, n_fail)

        # Read marginal-storage EUE (from script 57 marginal runs)
        marg_eue = Float64[]
        marg_ok  = true
        for s_id in scen_ids
            out_dir = joinpath(CASES_DIR, marginal_folder(case, δ, s_id), "output")
            if !isfile(joinpath(out_dir, "power_loadshedding.csv"))
                @warn "  Missing marginal-storage output: $out_dir  (run script 57 first)"
                marg_ok = false; break
            end
            push!(marg_eue, eue_from_shed(load_hope_loadshed(out_dir)))
        end

        # Read perfect-firm EUE (from runs just above)
        perf_eue = Float64[]
        perf_ok  = true
        for s_id in scen_ids
            out_dir = joinpath(CASES_DIR, perfect_folder(case, δ, s_id), "output")
            if !isfile(joinpath(out_dir, "power_loadshedding.csv"))
                @warn "  Missing perfect-firm output: $out_dir"
                perf_ok = false; break
            end
            push!(perf_eue, eue_from_shed(load_hope_loadshed(out_dir)))
        end

        eue_stor_hope       = marg_ok ? mean(marg_eue) : NaN
        eue_perf_hope_rerun = perf_ok ? mean(perf_eue) : NaN
        eue_perf_hope_anal  = mean(eue_analytical_perfect(baseline_sheds[s], δ) for s in scen_ids)

        numer_hope       = eue_base_hope - eue_stor_hope
        denom_hope_rerun = eue_base_hope - eue_perf_hope_rerun
        denom_hope_anal  = eue_base_hope - eue_perf_hope_anal

        cc_hope_rerun = (!isnan(denom_hope_rerun) && denom_hope_rerun > 1e-9) ?
                         numer_hope / denom_hope_rerun : NaN
        cc_hope_anal  = denom_hope_anal > 1e-9 ?
                         numer_hope / denom_hope_anal  : NaN

        @printf("  eue_base=%.3f  eue_stor=%.3f  eue_perf_rerun=%.3f  eue_perf_anal=%.3f\n",
                eue_base_hope, eue_stor_hope, eue_perf_hope_rerun, eue_perf_hope_anal)
        @printf("  CC_rerun=%.5f  CC_anal=%.5f\n",
                isnan(cc_hope_rerun) ? NaN : cc_hope_rerun,
                isnan(cc_hope_anal)  ? NaN : cc_hope_anal)

        push!(all_rows, (
            case                              = case,
            model                             = "HOPE-PCM-ED",
            n_scen                            = n_hope,
            delta_mw                          = δ,
            eue_baseline_mwh                  = eue_base_hope,
            eue_plus_storage_mwh              = eue_stor_hope,
            eue_plus_perfect_rerun_mwh        = eue_perf_hope_rerun,
            eue_plus_perfect_analytical_mwh   = eue_perf_hope_anal,
            delta_eue_storage_mwh             = numer_hope,
            delta_eue_perfect_rerun_mwh       = denom_hope_rerun,
            delta_eue_perfect_analytical_mwh  = denom_hope_anal,
            normalized_marginal_cc_rerun      = cc_hope_rerun,
            normalized_marginal_cc_analytical = cc_hope_anal,
            cc_error_rerun_vs_m3              = NaN,
            cc_error_analytical_vs_m3         = NaN,
            cc_greater_than_one_rerun         = !isnan(cc_hope_rerun) && cc_hope_rerun > 1.0,
        ))
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Post-process: cc_error_*_vs_m3
# ─────────────────────────────────────────────────────────────────────────────

df = DataFrame(all_rows)

for case_name in unique(df.case)
    for δ in unique(df.delta_mw)
        m3_mask = (df.case .== case_name) .& (df.model .== "Full-year ED (M3)") .&
                  (df.delta_mw .== δ)
        any(m3_mask) || continue
        cc_m3_r = df[m3_mask, :normalized_marginal_cc_rerun][1]
        cc_m3_a = df[m3_mask, :normalized_marginal_cc_analytical][1]
        for i in findall((df.case .== case_name) .& (df.delta_mw .== δ))
            cc_r = df[i, :normalized_marginal_cc_rerun]
            cc_a = df[i, :normalized_marginal_cc_analytical]
            df[i, :cc_error_rerun_vs_m3] =
                (isnan(cc_r) || isnan(cc_m3_r)) ? NaN : cc_r - cc_m3_r
            df[i, :cc_error_analytical_vs_m3] =
                (isnan(cc_a) || isnan(cc_m3_a)) ? NaN : cc_a - cc_m3_a
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 70)
println("Summary — normalized marginal CC (delta = 1 MW)")
println("=" ^ 70)
@printf("  %-24s  %-20s  %6s  %10s  %10s  %12s  %12s\n",
        "Case", "Model", "N", "CC_rerun", "CC_anal", "Err_rerun", "Err_anal")
println("  " * "─" ^ 100)
for row in eachrow(sort(filter(r -> r.delta_mw == 1.0, df), [:case, :model]))
    @printf("  %-24s  %-20s  %6d  %10.5f  %10.5f  %+12.5f  %+12.5f\n",
            row.case, row.model, row.n_scen,
            isnan(row.normalized_marginal_cc_rerun)       ? 0.0 : row.normalized_marginal_cc_rerun,
            isnan(row.normalized_marginal_cc_analytical)   ? 0.0 : row.normalized_marginal_cc_analytical,
            isnan(row.cc_error_rerun_vs_m3)                ? 0.0 : row.cc_error_rerun_vs_m3,
            isnan(row.cc_error_analytical_vs_m3)           ? 0.0 : row.cc_error_analytical_vs_m3)
end

println("\nSensitivity (delta = 5, 10 MW):")
@printf("  %-24s  %-20s  %6s  %6s  %10s  %10s  %12s\n",
        "Case", "Model", "N", "dMW", "CC_rerun", "CC_anal", "Err_rerun")
println("  " * "─" ^ 90)
for row in eachrow(sort(filter(r -> r.delta_mw in [5.0, 10.0], df), [:case, :model, :delta_mw]))
    @printf("  %-24s  %-20s  %6d  %6.0f  %10.5f  %10.5f  %+12.5f\n",
            row.case, row.model, row.n_scen, row.delta_mw,
            isnan(row.normalized_marginal_cc_rerun)      ? 0.0 : row.normalized_marginal_cc_rerun,
            isnan(row.normalized_marginal_cc_analytical)  ? 0.0 : row.normalized_marginal_cc_analytical,
            isnan(row.cc_error_rerun_vs_m3)               ? 0.0 : row.cc_error_rerun_vs_m3)
end

# ─────────────────────────────────────────────────────────────────────────────
# Save
# ─────────────────────────────────────────────────────────────────────────────

csv_path = joinpath(TAB_DIR, "marginal_cc_model_rerun_validation.csv")
CSV.write(csv_path, df)
println("\nSaved: $csv_path")
println("Done.")
