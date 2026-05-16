#!/usr/bin/env julia
# 14_run_ra1b_validation.jl
#
# Compare RA-1a (M1), RA-1b (M1b), and RA-3 (M3) on three calibrated storage
# cases that differ only in storage penetration level:
#
#   storage120_p05_d4   5 % of peak load, 4 h duration
#   storage120_p10_d4  10 % of peak load, 4 h duration   (reference case)
#   storage120_p20_d4  20 % of peak load, 4 h duration
#
# All three methods use a single shared ScenarioSet (CRN) per case.
#
# Research questions answered in summary.txt:
#   Q1. Is RA-1b storage-sensitive? (unlike RA-1a which was flat across cases)
#   Q2. Does RA-1b reduce LOLH overestimation relative to RA-1a?
#   Q3. How close is RA-1b LOLH to the RA-3 benchmark?
#   Q4. Does Priority-1 emergency discharge fire at all under RA-1b?
#
# Outputs (written under results/ra1b_validation/):
#   ra1b_validation_results.csv   — per-model, per-case aggregate metrics
#   ra1b_validation_errors.csv    — cases skipped due to missing data/errors
#   summary.txt                   — human-readable findings
#
# Usage:
#   julia --project=. scripts/14_run_ra1b_validation.jl [options]
#
# Options:
#   --n-scenarios N     Number of MC scenarios (default: 10)
#   --seed S            RNG seed                (default: 42)
#   --cases A,B,C       Comma-separated case dirs under data_processed/cases/
#                       (default: storage120_p05_d4,storage120_p10_d4,storage120_p20_d4)
#   --skip-m3           Omit RA-3 (fast run; useful when M3 is slow)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

# ── argument parsing ──────────────────────────────────────────────────────────
function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") ||
            error("Unexpected positional argument: $arg")
        key = arg[3:end]
        if key == "skip-m3"
            kw["skip-m3"] = "true"
            i += 1
        else
            i + 1 <= length(args) && !startswith(args[i+1], "--") ||
                error("Option $arg requires a value")
            kw[key] = args[i+1]
            i += 2
        end
    end
    return kw
end

# ── count Priority-1 emergency discharge fires ────────────────────────────
#
# Recomputes the pre-storage shortfall hour-by-hour from the raw availability
# matrix, avoiding the false-positive proxy of "any load_shed AND any discharge".
#
# An hour h in scenario s is a Priority-1 fire when:
#   shortfall_pre_h > 1e-6  AND  result.storage_discharge[h] > 1e-6
# where shortfall_pre_h = max(0, load_h - thermal_available_h - p_vre_h).
#
# Returns (p1_scenarios, total_p1_hours):
#   p1_scenarios  — number of scenarios with at least one P1 discharge hour
#   total_p1_hours — total count of P1 discharge hours across all scenarios
function count_p1_fires(sys      ::SystemData,
                         scenarios::ScenarioSet,
                         results  ::Vector{DispatchResult})
    therm     = thermal_generators(sys)
    n_therm   = nrow(therm)
    n_hours   = sys.n_hours
    pmax      = Float64.(therm.pmax_mw)
    wind_cap  = wind_capacity_mw(sys)
    solar_cap = solar_capacity_mw(sys)
    avail     = scenarios.availability

    p1_scenarios   = 0
    total_p1_hours = 0

    for (s, r) in enumerate(results)
        fired_this_scen = false
        for h in 1:n_hours
            therm_avail = 0.0
            for g in 1:n_therm
                therm_avail += pmax[g] * avail[s, g, h]
            end
            p_vre_h       = wind_cap * sys.wind_cf[h] + solar_cap * sys.solar_cf[h]
            shortfall_pre = max(0.0, sys.load_mw[h] - therm_avail - p_vre_h)
            if shortfall_pre > 1e-6 && r.storage_discharge[h] > 1e-6
                total_p1_hours += 1
                fired_this_scen = true
            end
        end
        fired_this_scen && (p1_scenarios += 1)
    end

    return p1_scenarios, total_p1_hours
end

# ── main ──────────────────────────────────────────────────────────────────────
let
    kw = parse_cli(ARGS)

    n_scenarios = parse(Int, get(kw, "n-scenarios", "10"))
    seed        = parse(Int, get(kw, "seed",         "42"))
    skip_m3     = get(kw, "skip-m3", "false") == "true"

    default_cases = "storage120_p05_d4,storage120_p10_d4,storage120_p20_d4"
    case_names    = String.(strip.(split(get(kw, "cases", default_cases), ",")))

    project_root = joinpath(@__DIR__, "..")
    cases_root   = joinpath(project_root, "data_processed", "cases")
    out_dir      = joinpath(project_root, "results", "ra1b_validation")
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "RA-1b validation | n_scenarios=$n_scenarios | seed=$seed"
    @info "Cases: $(join(case_names, ", "))"
    @info "Skip M3: $skip_m3"

    results_rows = NamedTuple[]
    errors_rows  = NamedTuple[]

    model_labels = skip_m3 ? ["M1", "M1b"] : ["M1", "M1b", "M3"]

    for cname in case_names
        cdir = joinpath(cases_root, cname)
        if !isdir(cdir)
            @warn "Case directory not found — skipping: $cdir"
            push!(errors_rows, (
                case_name = cname,
                error     = "directory not found: $cdir",
            ))
            continue
        end

        try
            @info "── Case: $cname ──────────────────────────────────────────"
            sys = load_system_data(cdir)
            sys.n_hours == 8760 ||
                @warn "$cname: expected 8760 h, got $(sys.n_hours)"

            stor         = sys.storage
            total_energy = nrow(stor) > 0 ? sum(stor.energy_mwh)  : 0.0
            total_power  = nrow(stor) > 0 ? sum(stor.power_mw)    : 0.0

            @info "  storage: $(nrow(stor)) units | " *
                  "$(round(total_power, digits=1)) MW / " *
                  "$(round(total_energy, digits=1)) MWh"

            # ── shared scenario set (CRN) ─────────────────────────────────
            crn_cfg = SimConfig(; n_scenarios, seed)
            @info "  generating $n_scenarios scenarios (seed=$seed)..."
            scenarios = generate_scenarios(sys, crn_cfg)

            # ── RA-1a (M1) ────────────────────────────────────────────────
            if "M1" in model_labels
                @info "  running M1 (RA-1a)..."
                t0   = time()
                r_m1 = run_m1_rule_based(sys, scenarios, crn_cfg)
                rt   = time() - t0
                m_m1 = compute_metrics(r_m1, sys, crn_cfg)
                p1_scen_m1, p1_hrs_m1 = count_p1_fires(sys, scenarios, r_m1)

                push!(results_rows, (
                    case_name         = cname,
                    model             = "M1",
                    n_scenarios       = n_scenarios,
                    seed              = seed,
                    lolh_hours        = m_m1.lolh,
                    eue_mwh           = m_m1.eue,
                    neue_ppm          = m_m1.neue * 1e6,
                    n_shortage_events = m_m1.n_shortage_events,
                    max_shortfall_mw  = m_m1.max_shortfall,
                    cvar_eue_mwh      = m_m1.cvar_eue,
                    p1_fire_scenarios = p1_scen_m1,
                    p1_fire_hours     = p1_hrs_m1,
                    runtime_s         = round(rt, digits=1),
                ))
                @info "  M1:  LOLH=$(round(m_m1.lolh, digits=2)) h  " *
                      "EUE=$(round(m_m1.eue, digits=1)) MWh  " *
                      "($(round(rt, digits=1))s)"
            end

            # ── RA-1b (M1b) ───────────────────────────────────────────────
            if "M1b" in model_labels
                m1b_cfg = SimConfig(; n_scenarios, seed, reserve_fraction=0.50)
                @info "  running M1b (RA-1b, reserve_fraction=0.50)..."
                t0    = time()
                r_m1b = run_m1b_reserve_aware(sys, scenarios, m1b_cfg)
                rt    = time() - t0
                m_m1b = compute_metrics(r_m1b, sys, m1b_cfg)
                p1_scen_m1b, p1_hrs_m1b = count_p1_fires(sys, scenarios, r_m1b)

                push!(results_rows, (
                    case_name         = cname,
                    model             = "M1b",
                    n_scenarios       = n_scenarios,
                    seed              = seed,
                    lolh_hours        = m_m1b.lolh,
                    eue_mwh           = m_m1b.eue,
                    neue_ppm          = m_m1b.neue * 1e6,
                    n_shortage_events = m_m1b.n_shortage_events,
                    max_shortfall_mw  = m_m1b.max_shortfall,
                    cvar_eue_mwh      = m_m1b.cvar_eue,
                    p1_fire_scenarios = p1_scen_m1b,
                    p1_fire_hours     = p1_hrs_m1b,
                    runtime_s         = round(rt, digits=1),
                ))
                @info "  M1b: LOLH=$(round(m_m1b.lolh, digits=2)) h  " *
                      "EUE=$(round(m_m1b.eue, digits=1)) MWh  " *
                      "($(round(rt, digits=1))s)"
            end

            # ── RA-3 (M3) ─────────────────────────────────────────────────
            if "M3" in model_labels && !skip_m3
                m3_cfg = SimConfig(; n_scenarios, seed)
                @info "  running M3 (RA-3, full-year ED LP) — may be slow..."
                t0   = time()
                r_m3 = run_m3_ed_dispatch(sys, scenarios, m3_cfg)
                rt   = time() - t0
                m_m3 = compute_metrics(r_m3, sys, m3_cfg)

                push!(results_rows, (
                    case_name         = cname,
                    model             = "M3",
                    n_scenarios       = n_scenarios,
                    seed              = seed,
                    lolh_hours        = m_m3.lolh,
                    eue_mwh           = m_m3.eue,
                    neue_ppm          = m_m3.neue * 1e6,
                    n_shortage_events = m_m3.n_shortage_events,
                    max_shortfall_mw  = m_m3.max_shortfall,
                    cvar_eue_mwh      = m_m3.cvar_eue,
                    p1_fire_scenarios = -1,    # not applicable to LP
                    p1_fire_hours     = -1,    # not applicable to LP
                    runtime_s         = round(rt, digits=1),
                ))
                @info "  M3:  LOLH=$(round(m_m3.lolh, digits=2)) h  " *
                      "EUE=$(round(m_m3.eue, digits=1)) MWh  " *
                      "($(round(rt, digits=1))s)"
            end

        catch e
            @error "Case $cname failed" exception=(e, catch_backtrace())
            push!(errors_rows, (
                case_name = cname,
                error     = sprint(showerror, e),
            ))
        end
    end

    # ── write CSVs ────────────────────────────────────────────────────────────
    results_path = joinpath(out_dir, "ra1b_validation_results.csv")
    errors_path  = joinpath(out_dir, "ra1b_validation_errors.csv")

    CSV.write(results_path, DataFrame(results_rows))
    CSV.write(errors_path,  DataFrame(errors_rows))
    @info "Results → $results_path"
    @info "Errors  → $errors_path"

    # ── write summary.txt ─────────────────────────────────────────────────────
    summary_path = joinpath(out_dir, "summary.txt")
    open(summary_path, "w") do io
        println(io, "=" ^ 72)
        println(io, "RA-1b Validation Summary")
        @printf io "Generated: %s\n" Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
        @printf io "n_scenarios: %d  |  seed: %d\n" n_scenarios seed
        println(io, "=" ^ 72)
        println(io)

        if isempty(results_rows)
            println(io, "No results available (all cases failed or were skipped).")
        else
            df = DataFrame(results_rows)

            # ── table ─────────────────────────────────────────────────────
            println(io, "Aggregate reliability metrics")
            println(io, "-" ^ 72)
            @printf(io, "  %-28s %-6s %10s %12s %14s\n",
                "Case", "Model", "LOLH (h)", "EUE (MWh)", "CVaR-EUE")
            println(io, "  " * "-" ^ 68)
            for r in eachrow(df)
                @printf(io, "  %-28s %-6s %10.2f %12.1f %14.1f\n",
                    r.case_name, r.model, r.lolh_hours, r.eue_mwh, r.cvar_eue_mwh)
            end
            println(io)

            # ── Q1: storage sensitivity ───────────────────────────────────
            println(io, "Q1. Is RA-1b storage-sensitive?")
            m1b_df  = filter(r -> r.model == "M1b", df)
            m1_df   = filter(r -> r.model == "M1",  df)
            if nrow(m1b_df) >= 2
                lolh_range = maximum(m1b_df.lolh_hours) - minimum(m1b_df.lolh_hours)
                m1_range   = nrow(m1_df) >= 2 ?
                    maximum(m1_df.lolh_hours) - minimum(m1_df.lolh_hours) : NaN
                if lolh_range > 0.1
                    println(io, "  YES — RA-1b LOLH varies by $(round(lolh_range, digits=2)) h " *
                               "across cases (RA-1a range: $(round(m1_range, digits=2)) h).")
                else
                    println(io, "  MARGINAL — RA-1b LOLH range is only " *
                               "$(round(lolh_range, digits=2)) h across cases.")
                end
            else
                println(io, "  Insufficient cases to assess storage sensitivity.")
            end
            println(io)

            # ── Q2: does M1b reduce overestimation vs M1? ─────────────────
            println(io, "Q2. Does RA-1b reduce LOLH overestimation relative to RA-1a?")
            has_m3 = "M3" in model_labels && !skip_m3
            m3_df  = has_m3 ? filter(r -> r.model == "M3", df) : DataFrame()

            for cname in case_names
                m1_row  = filter(r -> r.case_name == cname && r.model == "M1",  df)
                m1b_row = filter(r -> r.case_name == cname && r.model == "M1b", df)
                isempty(m1_row) || isempty(m1b_row) && continue
                lolh_m1  = m1_row[1, :lolh_hours]
                lolh_m1b = m1b_row[1, :lolh_hours]
                delta    = lolh_m1 - lolh_m1b
                direction = delta > 0.01 ? "↓ reduced by $(round(delta, digits=2)) h" :
                            delta < -0.01 ? "↑ increased by $(round(-delta, digits=2)) h" :
                            "unchanged (Δ < 0.01 h)"
                @printf(io, "  %-28s  M1=%.2f h → M1b=%.2f h  %s\n",
                    cname, lolh_m1, lolh_m1b, direction)
            end
            println(io)

            # ── Q3: how close is M1b to M3? ───────────────────────────────
            println(io, "Q3. How close is RA-1b LOLH to the RA-3 benchmark?")
            if has_m3 && nrow(m3_df) > 0
                for cname in case_names
                    m1b_row = filter(r -> r.case_name == cname && r.model == "M1b", df)
                    m3_row  = filter(r -> r.case_name == cname && r.model == "M3",  df)
                    isempty(m1b_row) || isempty(m3_row) && continue
                    lolh_m1b = m1b_row[1, :lolh_hours]
                    lolh_m3  = m3_row[1,  :lolh_hours]
                    ratio    = lolh_m3 > 0.0 ? lolh_m1b / lolh_m3 : NaN
                    @printf(io, "  %-28s  M1b=%.2f h  M3=%.2f h  ratio=%.2f\n",
                        cname, lolh_m1b, lolh_m3, ratio)
                end
            else
                println(io, "  RA-3 not run (--skip-m3 flag set or all M3 cases failed).")
            end
            println(io)

            # ── Q4: does P1 fire under M1 and M1b? ───────────────────────
            println(io, "Q4. Does Priority-1 emergency discharge fire under RA-1b?")
            println(io, "  (Exact count: hours where pre-storage shortfall > 0 AND discharge > 0)")
            for cname in case_names
                for mlabel in ("M1", "M1b")
                    mrow = filter(r -> r.case_name == cname && r.model == mlabel, df)
                    isempty(mrow) && continue
                    p1s = mrow[1, :p1_fire_scenarios]
                    p1h = mrow[1, :p1_fire_hours]
                    n   = mrow[1, :n_scenarios]
                    @printf(io, "  %-28s  %-5s  Priority-1 fired in %d / %d scenarios and %d total hours\n",
                        cname, mlabel, p1s, n, p1h)
                end
            end
            println(io)
        end

        if !isempty(errors_rows)
            println(io, "Errors / skipped cases:")
            for e in errors_rows
                @printf io "  %s: %s\n" e.case_name e.error
            end
            println(io)
        end

        println(io, "=" ^ 72)
        println(io, "Full results: ra1b_validation_results.csv")
        println(io, "Log:          $(basename(log_path))")
    end

    @info "Summary → $summary_path"

    # ── console output ────────────────────────────────────────────────────────
    println()
    println("=" ^ 72)
    println("RA-1b Validation  |  n_scenarios=$n_scenarios  |  seed=$seed")
    println("=" ^ 72)

    if !isempty(results_rows)
        df = DataFrame(results_rows)
        @printf("  %-28s %-6s %10s %12s\n", "Case", "Model", "LOLH (h)", "EUE (MWh)")
        println("  " * "-" ^ 58)
        for r in eachrow(df)
            @printf("  %-28s %-6s %10.2f %12.1f\n",
                r.case_name, r.model, r.lolh_hours, r.eue_mwh)
        end
    end

    println("=" ^ 72)
    println("Output directory: $out_dir")
    println()

    if !isempty(errors_rows)
        println("Skipped / errors:")
        for e in errors_rows
            println("  $(e.case_name): $(e.error)")
        end
        println()
    end

    println("Summary written to: $summary_path")
end
