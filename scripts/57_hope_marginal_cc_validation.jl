#!/usr/bin/env julia
# 57_hope_marginal_cc_validation.jl
#
# Validates normalized marginal storage capacity credit using HOPE-PCM-ED.
#
# For each case and delta, computes under HOPE-ED and M3:
#
#   CC(delta) = [EUE(x) - EUE(x + delta_storage)] /
#               [EUE(x) - EUE(x + delta_perfect)]
#
# where:
#   x             = existing 983 MW / 3932 MWh storage portfolio
#   delta_storage = delta MW / (4*delta MWh)
#   delta_perfect = analytical: shed_after_perfect[h] = max(0, shed[h] - delta)
#
# VRE120_base:     N=20  (uses existing HOPE-ED N=20 baseline; runs 60 new HOPE cases)
# VRE120_wind_hvy: N=5   (uses existing HOPE-ED N=5 baseline; runs 15 new HOPE cases;
#                          re-runs M3 at N=5 for matched comparison)
#
# Storage increment in HOPE: aggregate the existing BES unit to
#   (983 + delta) MW / (3932 + 4*delta) MWh.
# This is equivalent to M3's two-unit formulation when efficiencies are identical.
#
# Outputs:
#   results/paper_tables/hope_pcm_ed_marginal_cc_validation.csv
#
# Usage:
#   julia --project=. scripts/57_hope_marginal_cc_validation.jl \
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
    global HOPE_PATH   = get(kw, "hope-path",
                             joinpath("D:", "MIT Dropbox", "Shen Wang", "MIT", "RA", "HOPE_project"))
    global JULIA_EXE   = get(kw, "julia-exe",
                             replace(joinpath(Sys.BINDIR, "julia"), "\\" => "/"))
end

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

# case => number of HOPE scenarios available
const CASES_N = [("VRE120_base", 20), ("VRE120_wind_hvy", 5)]

const DELTA_MWS   = [1.0, 5.0, 10.0]
const DURATION_H  = 4.0
const SEED        = 42
const RISK_MARGIN = 1000.0
const BUFFER_H    = 48

const REPO        = abspath(joinpath(@__DIR__, ".."))
const CASES_DIR   = abspath(joinpath(REPO, "exports", "hope_model_cases"))
const DATA_ROOT   = abspath(joinpath(REPO, "data_processed", "cases"))
const TAB_DIR     = abspath(joinpath(REPO, "results", "paper_tables"))
const PREV_CC_CSV = joinpath(TAB_DIR, "storage_marginal_capacity_credit.csv")

mkpath(TAB_DIR)

HOPE_PATH_FWD = replace(abspath(HOPE_PATH), "\\" => "/")
JULIA_EXE_FWD = replace(JULIA_EXE,         "\\" => "/")

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

eue_from_shed(shed::Vector{Float64}) = sum(shed)

function eue_after_perfect_shed(shed::Vector{Float64}, δ::Float64)::Float64
    total = 0.0
    for v in shed
        d = v - δ
        total += d > 0.0 ? d : 0.0
    end
    return total
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers — M3
# ─────────────────────────────────────────────────────────────────────────────

function eue_mean_m3(results::Vector{DispatchResult})::Float64
    isempty(results) && return 0.0
    return mean(sum(r.load_shed) for r in results)
end

function eue_after_perfect_m3(results::Vector{DispatchResult}, δ::Float64)::Float64
    n = length(results)
    n == 0 && return 0.0
    total = 0.0
    for r in results, v in r.load_shed
        d = v - δ
        total += d > 0.0 ? d : 0.0
    end
    return total / n
end

function with_marginal_storage(sys::SystemData, δ::Float64)::SystemData
    eta   = sqrt(0.90)
    e_mwh = δ * DURATION_H
    extra = DataFrame(
        storage_id            = ["MARG_$(δ)MW"],
        power_mw              = [δ],
        energy_mwh            = [e_mwh],
        charge_efficiency     = [eta],
        discharge_efficiency  = [eta],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [e_mwh * 0.5],
    )
    return SystemData(sys.generators, vcat(sys.storage, extra),
                      sys.load_mw, sys.wind_cf, sys.solar_cf, sys.n_hours)
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers — HOPE case management
# ─────────────────────────────────────────────────────────────────────────────

baseline_folder(case::String, s_id::Int) =
    "RAChronoOps_$(case)_s$(lpad(s_id, 3, '0'))_ED"

marginal_folder(case::String, δ::Float64, s_id::Int) =
    "RAChronoOps_$(case)_marg$(round(Int, δ))mw_s$(lpad(s_id, 3, '0'))_ED"

function export_marginal_case!(case::String, δ::Float64, s_id::Int,
                                sys::SystemData, cases_dir::String)::String
    src = joinpath(cases_dir, baseline_folder(case, s_id))
    dst = joinpath(cases_dir, marginal_folder(case, δ, s_id))
    isdir(src) || error("Baseline folder not found: $src")
    if isdir(dst)
        return dst
    end
    cp(src, dst; force = false)
    # Remove any copied baseline output so HOPE must run fresh
    out_dir = joinpath(dst, "output")
    isdir(out_dir) && rm(out_dir; recursive = true)
    for entry in readdir(dst; join = true)
        startswith(basename(entry), "output_tmp") && rm(entry; recursive = true)
    end
    # Overwrite storagedata.csv: aggregate (983+delta) MW / (3932+4*delta) MWh
    s_base = sys.storage[1, :]
    storage_df = DataFrame(
        "Zone"                   => ["Z1"],
        "Type"                   => ["BES"],
        "Capacity (MWh)"         => [s_base.energy_mwh + δ * DURATION_H],
        "Max Power (MW)"         => [s_base.power_mw   + δ],
        "Charging efficiency"    => [Float64(s_base.charge_efficiency)],
        "Discharging efficiency" => [Float64(s_base.discharge_efficiency)],
        "Cost (\$/MWh)"          => [Float64(s_base.variable_cost_per_mwh)],
        "EF"                     => [0.0],
        "CC"                     => [0.0],
        "Charging Rate"          => [1.0],
        "Discharging Rate"       => [1.0],
    )
    CSV.write(joinpath(dst, "Data_RAChronoOps_PCM", "storagedata.csv"), storage_df)
    return dst
end

function run_hope_case(case_path::String; skip_if_done::Bool = true)::Symbol
    shed_csv = joinpath(case_path, "output", "power_loadshedding.csv")
    if skip_if_done && isfile(shed_csv)
        return :skipped
    end
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
# Print header
# ─────────────────────────────────────────────────────────────────────────────

println("=" ^ 70)
println("57_hope_marginal_cc_validation.jl")
println("Date:       ", Dates.now())
println("HOPE path:  ", HOPE_PATH_FWD)
println("Julia exe:  ", JULIA_EXE_FWD)
println("Cases:      ", join(first.(CASES_N), ", "))
println("delta (MW): ", join(DELTA_MWS, ", "))
println("=" ^ 70)

# ─────────────────────────────────────────────────────────────────────────────
# Load M3 N=20 reference (from script 55)
# ─────────────────────────────────────────────────────────────────────────────

prev_df = CSV.read(PREV_CC_CSV, DataFrame)

all_rows = NamedTuple[]

# ─────────────────────────────────────────────────────────────────────────────
# Main loop over cases
# ─────────────────────────────────────────────────────────────────────────────

for (case, n_hope) in CASES_N
    println("\n" * "─" ^ 70)
    println("Case: $case  (HOPE N=$n_hope)")
    println("─" ^ 70)

    case_dir = joinpath(DATA_ROOT, case)
    isdir(case_dir) || error("Case directory not found: $case_dir")
    sys = load_system_data(case_dir)

    scen_ids = collect(1:n_hope)

    # ── 1. Read HOPE baseline load-shed ──────────────────────────────────────
    println("\n  [1/4] Reading HOPE-ED baseline load-shed (N=$n_hope)…")
    baseline_sheds = Dict{Int, Vector{Float64}}()
    for s_id in scen_ids
        folder  = joinpath(CASES_DIR, baseline_folder(case, s_id))
        out_dir = joinpath(folder, "output")
        baseline_sheds[s_id] = load_hope_loadshed(out_dir)
    end
    eue_base_hope = mean(eue_from_shed(baseline_sheds[s]) for s in scen_ids)
    @printf("  EUE_baseline (HOPE-ED, N=%d) = %.3f MWh\n", n_hope, eue_base_hope)

    # ── 2. Export marginal-storage HOPE cases ─────────────────────────────────
    println("\n  [2/4] Exporting marginal-storage HOPE cases…")
    n_exported = 0
    for δ in DELTA_MWS, s_id in scen_ids
        dst = export_marginal_case!(case, δ, s_id, sys, CASES_DIR)
        if !isdir(joinpath(dst, "output"))
            n_exported += 1
        end
    end
    n_total_cases = length(DELTA_MWS) * n_hope
    @printf("  Exported %d new case folders (total: %d)\n",
            n_exported, n_total_cases)

    # ── 3. Run HOPE for marginal-storage cases ────────────────────────────────
    println("\n  [3/4] Running HOPE-ED for marginal-storage cases…")
    n_ok = 0; n_skip = 0; n_fail = 0
    for δ in DELTA_MWS
        for s_id in scen_ids
            folder = joinpath(CASES_DIR, marginal_folder(case, δ, s_id))
            t0     = time()
            status = run_hope_case(folder; skip_if_done = true)
            rt     = time() - t0
            if status == :ok
                n_ok   += 1
                @printf("    delta=%.0f MW  s%03d  OK  (%.0f s)\n", δ, s_id, rt)
            elseif status == :skipped
                n_skip += 1
                @printf("    delta=%.0f MW  s%03d  skipped (already solved)\n", δ, s_id)
            else
                n_fail += 1
                @printf("    delta=%.0f MW  s%03d  FAILED\n", δ, s_id)
            end
        end
    end
    @printf("  HOPE runs: %d ok, %d skipped, %d failed\n", n_ok, n_skip, n_fail)

    # ── 4. Compute HOPE-ED CC ─────────────────────────────────────────────────
    println("\n  [4/4] Computing HOPE-ED normalized marginal CC…")
    for δ in DELTA_MWS
        # Perfect-firm denominator (analytical from baseline load-shed)
        eue_perf_hope = mean(eue_after_perfect_shed(baseline_sheds[s], δ)
                             for s in scen_ids)
        denom = eue_base_hope - eue_perf_hope

        # Marginal-storage numerator (from HOPE runs)
        shed_vals = Float64[]
        ok_flag   = true
        for s_id in scen_ids
            folder  = joinpath(CASES_DIR, marginal_folder(case, δ, s_id))
            out_dir = joinpath(folder, "output")
            if !isfile(joinpath(out_dir, "power_loadshedding.csv"))
                ok_flag = false
                break
            end
            push!(shed_vals, eue_from_shed(load_hope_loadshed(out_dir)))
        end
        if !ok_flag
            @warn "  Missing HOPE output for delta=$δ MW — skipping CC computation"
            continue
        end
        eue_stor_hope = mean(shed_vals)
        numer         = eue_base_hope - eue_stor_hope
        cc_hope       = denom > 1e-9 ? numer / denom : NaN

        @printf("  delta=%.0f MW:  ΔEUEstor=%8.4f  ΔEUEperf=%8.4f  CC=%8.5f\n",
                δ, numer, denom, isnan(cc_hope) ? NaN : cc_hope)

        push!(all_rows, (
            case                   = case,
            model                  = "HOPE-PCM-ED",
            n_scen                 = n_hope,
            delta_mw               = δ,
            eue_baseline_mwh       = eue_base_hope,
            eue_plus_storage_mwh   = eue_stor_hope,
            eue_plus_perfect_mwh   = eue_perf_hope,
            delta_eue_storage_mwh  = numer,
            delta_eue_perfect_mwh  = denom,
            normalized_marginal_cc = cc_hope,
            cc_error_vs_full_year_ed = NaN,
            cc_greater_than_one    = !isnan(cc_hope) && cc_hope > 1.0,
        ))
    end

    # ── 5. M3 matched comparison ──────────────────────────────────────────────
    # VRE120_base (N=20): pull from script 55 CSV.
    # VRE120_wind_hvy (N=5): re-run M3 at N=5 for a matched comparison.
    if n_hope == 20
        println("\n  Pulling M3 N=20 reference from script 55 CSV…")
        for δ in DELTA_MWS
            row_m3 = filter(r -> r.case == case && r.method == "M3" &&
                                 r.delta_mw == δ, prev_df)
            isempty(row_m3) && continue
            r = row_m3[1, :]
            push!(all_rows, (
                case                   = case,
                model                  = "Full-year ED (M3)",
                n_scen                 = 20,
                delta_mw               = δ,
                eue_baseline_mwh       = r.eue_baseline_mwh,
                eue_plus_storage_mwh   = r.eue_plus_storage_mwh,
                eue_plus_perfect_mwh   = r.eue_plus_perfect_mwh,
                delta_eue_storage_mwh  = r.delta_eue_storage_mwh,
                delta_eue_perfect_mwh  = r.delta_eue_perfect_mwh,
                normalized_marginal_cc = r.normalized_marginal_cc,
                cc_error_vs_full_year_ed = 0.0,
                cc_greater_than_one    = r.normalized_marginal_cc > 1.0,
            ))
        end
    else
        println("\n  Running M3 at N=$n_hope for matched comparison…")
        base_cfg = SimConfig(n_scenarios = n_hope, seed = SEED)
        m2_cfg   = SimConfig(n_scenarios = n_hope, seed = SEED,
                             risk_margin_mw = RISK_MARGIN,
                             window_buffer_hours = BUFFER_H)
        scen   = generate_scenarios(sys, base_cfg)
        avail  = scen.availability

        t0 = time()
        res_base = run_m3_ed_dispatch(sys, avail, base_cfg)
        eue_base_m3 = eue_mean_m3(res_base)
        @printf("  M3 baseline (N=%d): EUE = %.3f MWh  (%.1f s)\n",
                n_hope, eue_base_m3, time() - t0)

        for δ in DELTA_MWS
            eue_perf_m3 = eue_after_perfect_m3(res_base, δ)
            denom_m3    = eue_base_m3 - eue_perf_m3

            sys_m    = with_marginal_storage(sys, δ)
            t0       = time()
            res_m    = run_m3_ed_dispatch(sys_m, avail, base_cfg)
            eue_m_m3 = eue_mean_m3(res_m)
            numer_m3 = eue_base_m3 - eue_m_m3
            cc_m3    = denom_m3 > 1e-9 ? numer_m3 / denom_m3 : NaN

            @printf("  delta=%.0f MW (M3 N=%d):  ΔEUEstor=%8.4f  ΔEUEperf=%8.4f  CC=%8.5f  (%.1f s)\n",
                    δ, n_hope, numer_m3, denom_m3,
                    isnan(cc_m3) ? NaN : cc_m3, time() - t0)

            push!(all_rows, (
                case                   = case,
                model                  = "Full-year ED (M3)",
                n_scen                 = n_hope,
                delta_mw               = δ,
                eue_baseline_mwh       = eue_base_m3,
                eue_plus_storage_mwh   = eue_m_m3,
                eue_plus_perfect_mwh   = eue_perf_m3,
                delta_eue_storage_mwh  = numer_m3,
                delta_eue_perfect_mwh  = denom_m3,
                normalized_marginal_cc = cc_m3,
                cc_error_vs_full_year_ed = 0.0,
                cc_greater_than_one    = !isnan(cc_m3) && cc_m3 > 1.0,
            ))
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Post-process: fill cc_error_vs_full_year_ed
# ─────────────────────────────────────────────────────────────────────────────

df = DataFrame(all_rows)
df[!, :cc_error_vs_full_year_ed] = fill(NaN, size(df, 1))

for case_name in unique(df.case)
    for δ in unique(df.delta_mw)
        # Reference = Full-year ED (M3) for this (case, delta)
        m3_mask = (df.case .== case_name) .& (df.model .== "Full-year ED (M3)") .&
                  (df.delta_mw .== δ)
        any(m3_mask) || continue
        cc_ref = df[m3_mask, :normalized_marginal_cc][1]
        isnan(cc_ref) && continue

        mask = (df.case .== case_name) .& (df.delta_mw .== δ)
        for i in findall(mask)
            cc_i = df[i, :normalized_marginal_cc]
            df[i, :cc_error_vs_full_year_ed] = isnan(cc_i) ? NaN : cc_i - cc_ref
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

println("\n" * "=" ^ 70)
println("Summary — normalized marginal CC (delta = 1 MW)")
println("=" ^ 70)
@printf("  %-24s  %-20s  %6s  %10s  %12s  %s\n",
        "Case", "Model", "N", "CC", "Err vs M3", "CC>1?")
println("  " * "─" ^ 78)
df1 = filter(r -> r.delta_mw == 1.0, df)
for row in eachrow(sort(df1, [:case, :model]))
    @printf("  %-24s  %-20s  %6d  %10.5f  %+12.5f  %s\n",
            row.case, row.model, row.n_scen,
            isnan(row.normalized_marginal_cc) ? 0.0 : row.normalized_marginal_cc,
            isnan(row.cc_error_vs_full_year_ed) ? 0.0 : row.cc_error_vs_full_year_ed,
            row.cc_greater_than_one ? "YES" : "no")
end

println("\nSensitivity (delta = 5, 10 MW):")
@printf("  %-24s  %-20s  %6s  %6s  %10s  %12s\n",
        "Case", "Model", "N", "dMW", "CC", "Err vs M3")
println("  " * "─" ^ 78)
df_sens = filter(r -> r.delta_mw in [5.0, 10.0], df)
for row in eachrow(sort(df_sens, [:case, :model, :delta_mw]))
    @printf("  %-24s  %-20s  %6d  %6.0f  %10.5f  %+12.5f\n",
            row.case, row.model, row.n_scen, row.delta_mw,
            isnan(row.normalized_marginal_cc) ? 0.0 : row.normalized_marginal_cc,
            isnan(row.cc_error_vs_full_year_ed) ? 0.0 : row.cc_error_vs_full_year_ed)
end

# ─────────────────────────────────────────────────────────────────────────────
# Save
# ─────────────────────────────────────────────────────────────────────────────

csv_path = joinpath(TAB_DIR, "hope_pcm_ed_marginal_cc_validation.csv")
CSV.write(csv_path, df)
println("\nSaved: $csv_path")
println("Done.")
