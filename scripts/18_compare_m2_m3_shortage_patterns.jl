#!/usr/bin/env julia
# 18_compare_m2_m3_shortage_patterns.jl
#
# Diagnose why RA-2 (M2) matches RA-3 (M3) EUE to machine precision yet
# slightly underestimates LOLH.  For each case × scenario, compares the
# hourly load-shedding vectors from M2 and M3 and classifies every shortage
# hour as "common" (both models shed), "m2_only", or "m3_only".
#
# The core hypothesis being tested:
#   M2 reallocates the same total unserved energy from many small M3 events
#   into fewer, larger events — matching EUE exactly while reducing LOLH.
#
# Outputs (results/ra2_pattern_debug/<subdir>/):
#   shortage_pattern_comparison.csv  — per case/scenario aggregate breakdown
#   shortage_hour_detail.csv         — per case/scenario/hour where any shed > 0
#   summary.txt                      — diagnostic findings
#
# Usage:
#   julia --project=. scripts/18_compare_m2_m3_shortage_patterns.jl [options]
#
# Options:
#   --n-scenarios N    (default: 5)
#   --seed S           (default: 42)
#   --cases C1,C2,...  (default: VRE120_base,VRE120_bal15,VRE120_wind_hvy)
#   --out-subdir DIR   (auto-derived if omitted)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

const DEFAULT_CASES = ["VRE120_base", "VRE120_bal15", "VRE120_wind_hvy"]
const ALL_VRE120    = ["VRE120_base","VRE120_bal15","VRE120_bal20",
                       "VRE120_bal30","VRE120_solar_hvy","VRE120_wind_hvy"]

# threshold below which load-shed is treated as zero (LP numerical noise)
const SHED_THRESHOLD = 1e-3   # MW

function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional arg: $arg")
        key = arg[3:end]
        i + 1 <= length(args) && !startswith(args[i+1], "--") ||
            error("Option $arg requires a value")
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

function auto_subdir(cases::Vector{String}, n::Int)
    abbr = join([replace(c, "VRE120_" => "") for c in cases], "-")
    return "$(abbr)_n$(n)"
end

# ── per-scenario hourly comparison ────────────────────────────────────────────
"""
    compare_scenario(m2_ls, m3_ls, threshold)

Given two load-shed vectors (length T), return a NamedTuple with counts and
EUE totals for common / m2_only / m3_only shortage hours.
"""
function compare_scenario(m2_ls::Vector{Float64},
                           m3_ls::Vector{Float64},
                           threshold::Float64)

    common_h     = 0;  common_eue_m2  = 0.0;  common_eue_m3  = 0.0
    m2_only_h    = 0;  m2_only_eue    = 0.0
    m3_only_h    = 0;  m3_only_eue    = 0.0

    for h in eachindex(m2_ls)
        s2 = m2_ls[h] > threshold
        s3 = m3_ls[h] > threshold
        if s2 && s3
            common_h     += 1
            common_eue_m2 += m2_ls[h]
            common_eue_m3 += m3_ls[h]
        elseif s2
            m2_only_h    += 1
            m2_only_eue  += m2_ls[h]
        elseif s3
            m3_only_h    += 1
            m3_only_eue  += m3_ls[h]
        end
    end

    return (
        common_h      = common_h,
        common_eue_m2 = common_eue_m2,
        common_eue_m3 = common_eue_m3,
        m2_only_h     = m2_only_h,
        m2_only_eue   = m2_only_eue,
        m3_only_h     = m3_only_h,
        m3_only_eue   = m3_only_eue,
    )
end

# ── main ──────────────────────────────────────────────────────────────────────
let
    kw = parse_cli(ARGS)

    n_scenarios = parse(Int, get(kw, "n-scenarios", "5"))
    seed        = parse(Int, get(kw, "seed",         "42"))

    cases_to_run = if haskey(kw, "cases")
        req = split(kw["cases"], ",")
        for c in req
            c in ALL_VRE120 ||
                error("Unknown case: $c (valid: $(join(ALL_VRE120, ", ")))")
        end
        String.(req)
    else
        DEFAULT_CASES
    end

    project_root = joinpath(@__DIR__, "..")
    cases_root   = joinpath(project_root, "data_processed", "cases")
    base_out_dir = joinpath(project_root, "results", "ra2_pattern_debug")
    subdir       = get(kw, "out-subdir", auto_subdir(cases_to_run, n_scenarios))
    out_dir      = joinpath(base_out_dir, subdir)
    mkpath(out_dir)

    log_path = joinpath(out_dir, "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "Shortage pattern comparison | n=$n_scenarios | seed=$seed"
    @info "Cases: $(join(cases_to_run, ", "))"
    @info "Shed threshold: $(SHED_THRESHOLD) MW"

    pattern_rows = NamedTuple[]
    detail_rows  = NamedTuple[]

    total_t0 = time()

    for cname in cases_to_run
        cdir = joinpath(cases_root, cname)
        if !isdir(cdir)
            @warn "Case dir not found — skipping: $cdir"
            continue
        end

        @info "── $cname ──"
        sys = load_system_data(cdir)
        cfg = SimConfig(; n_scenarios, seed, reserve_fraction=0.50)
        scenarios = generate_scenarios(sys, cfg)

        # ── run M2 ────────────────────────────────────────────────────────────
        @info "  M2..."
        t0   = time()
        r_m2 = run_m2_event_window_lp(sys, scenarios, cfg)
        @info "  M2 done ($(round(time()-t0, digits=1)) s)"

        # ── run M3 ────────────────────────────────────────────────────────────
        @info "  M3 (may be slow)..."
        t0   = time()
        r_m3 = run_m3_ed_dispatch(sys, scenarios, cfg)
        @info "  M3 done ($(round(time()-t0, digits=1)) s)"

        # ── per-scenario comparison ───────────────────────────────────────────
        for s in 1:n_scenarios
            m2_ls = r_m2[s].load_shed
            m3_ls = r_m3[s].load_shed

            # raw per-scenario metrics
            m2_lolh = count(x -> x > SHED_THRESHOLD, m2_ls)
            m3_lolh = count(x -> x > SHED_THRESHOLD, m3_ls)
            m2_eue  = sum(m2_ls)
            m3_eue  = sum(m3_ls)

            cmp = compare_scenario(m2_ls, m3_ls, SHED_THRESHOLD)

            push!(pattern_rows, (
                case_name              = cname,
                scenario_id            = s,
                m2_lolh                = m2_lolh,
                m3_lolh                = m3_lolh,
                lolh_diff              = m2_lolh - m3_lolh,
                m2_eue                 = m2_eue,
                m3_eue                 = m3_eue,
                eue_diff               = m2_eue - m3_eue,
                common_shortage_hours  = cmp.common_h,
                m2_only_shortage_hours = cmp.m2_only_h,
                m3_only_shortage_hours = cmp.m3_only_h,
                common_eue_mwh         = cmp.common_eue_m2,  # M2's EUE at common hours
                common_eue_m3_mwh      = cmp.common_eue_m3,  # M3's EUE at same hours
                m2_only_eue_mwh        = cmp.m2_only_eue,
                m3_only_eue_mwh        = cmp.m3_only_eue,
                # intensity per shortage hour (mean shortfall MW)
                m2_intensity_common    = cmp.common_h  > 0 ? cmp.common_eue_m2 / cmp.common_h  : 0.0,
                m3_intensity_common    = cmp.common_h  > 0 ? cmp.common_eue_m3 / cmp.common_h  : 0.0,
                m2_intensity_m2only    = cmp.m2_only_h > 0 ? cmp.m2_only_eue   / cmp.m2_only_h : 0.0,
                m3_intensity_m3only    = cmp.m3_only_h > 0 ? cmp.m3_only_eue   / cmp.m3_only_h : 0.0,
                m2_max_shortfall_mw    = maximum(m2_ls),
                m3_max_shortfall_mw    = maximum(m3_ls),
            ))

            # ── per-hour detail for any hour where either model sheds ─────────
            for h in 1:sys.n_hours
                s2 = m2_ls[h] > SHED_THRESHOLD
                s3 = m3_ls[h] > SHED_THRESHOLD
                (s2 || s3) || continue

                cls = if s2 && s3
                    "common"
                elseif s2
                    "m2_only"
                else
                    "m3_only"
                end

                push!(detail_rows, (
                    case_name           = cname,
                    scenario_id         = s,
                    hour                = h,
                    m2_load_shed_mw     = m2_ls[h],
                    m3_load_shed_mw     = m3_ls[h],
                    difference_m2_minus_m3 = m2_ls[h] - m3_ls[h],
                    classification      = cls,
                ))
            end
        end

        @info "  $cname done: $(n_scenarios) scenarios compared"
    end

    total_rt = time() - total_t0

    # ── write CSVs ─────────────────────────────────────────────────────────────
    pat_path    = joinpath(out_dir, "shortage_pattern_comparison.csv")
    detail_path = joinpath(out_dir, "shortage_hour_detail.csv")
    summary_path= joinpath(out_dir, "summary.txt")

    CSV.write(pat_path,    DataFrame(pattern_rows))
    CSV.write(detail_path, DataFrame(detail_rows))
    @info "Pattern CSV  → $pat_path  ($(length(pattern_rows)) rows)"
    @info "Detail CSV   → $detail_path  ($(length(detail_rows)) rows)"

    # ── aggregate for summary ──────────────────────────────────────────────────
    pdf = DataFrame(pattern_rows)
    ddf = DataFrame(detail_rows)

    # ── write summary.txt ──────────────────────────────────────────────────────
    open(summary_path, "w") do io
        sep = "=" ^ 78
        println(io, sep)
        println(io, "M2 vs M3 Shortage Pattern Diagnostic")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d  |  shed_threshold: %.3f MW\n",
                n_scenarios, seed, SHED_THRESHOLD)
        @printf(io, "Cases: %s\n", join(cases_to_run, ", "))
        println(io, sep)
        println(io)

        # ── per-scenario summary table ─────────────────────────────────────────
        println(io, "Per-scenario shortage hour breakdown")
        println(io, "-" ^ 90)
        @printf(io, "  %-16s %4s %6s %6s %6s %7s %7s %7s\n",
                "Case", "Scen", "M2_h", "M3_h", "Δh",
                "Comm_h", "M2only", "M3only")
        println(io, "  " * "-" ^ 84)
        for r in eachrow(pdf)
            @printf(io, "  %-16s %4d %6d %6d %+6d %7d %7d %7d\n",
                    r.case_name, r.scenario_id,
                    r.m2_lolh, r.m3_lolh, r.lolh_diff,
                    r.common_shortage_hours,
                    r.m2_only_shortage_hours,
                    r.m3_only_shortage_hours)
        end
        println(io)

        # ── per-scenario EUE breakdown ─────────────────────────────────────────
        println(io, "Per-scenario EUE breakdown (MWh)")
        println(io, "-" ^ 100)
        @printf(io, "  %-16s %4s %10s %10s %10s %10s %10s %10s\n",
                "Case", "Scen", "M2_EUE", "M3_EUE", "EUE_diff",
                "Comm_M2", "M2only", "M3only")
        println(io, "  " * "-" ^ 94)
        for r in eachrow(pdf)
            @printf(io, "  %-16s %4d %10.2f %10.2f %+10.6f %10.2f %10.2f %10.2f\n",
                    r.case_name, r.scenario_id,
                    r.m2_eue, r.m3_eue, r.eue_diff,
                    r.common_eue_mwh,
                    r.m2_only_eue_mwh,
                    r.m3_only_eue_mwh)
        end
        println(io)

        # ── aggregate by case ──────────────────────────────────────────────────
        println(io, "Case-level aggregates (means across scenarios)")
        println(io, "-" ^ 100)
        @printf(io, "  %-16s %6s %6s %6s %7s %7s %7s %10s %10s\n",
                "Case", "M2_h", "M3_h", "Δh", "Comm_h", "M2only", "M3only",
                "M2only_MW", "M3only_MW")
        println(io, "  " * "-" ^ 94)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, pdf)
            isempty(sub) && continue
            @printf(io, "  %-16s %6.1f %6.1f %+6.1f %7.1f %7.1f %7.1f %10.2f %10.2f\n",
                    cname,
                    mean(sub.m2_lolh),
                    mean(sub.m3_lolh),
                    mean(sub.lolh_diff),
                    mean(sub.common_shortage_hours),
                    mean(sub.m2_only_shortage_hours),
                    mean(sub.m3_only_shortage_hours),
                    mean(sub.m2_intensity_m2only),
                    mean(sub.m3_intensity_m3only))
        end
        println(io)

        # ── Q1: EUE reallocation ───────────────────────────────────────────────
        println(io, "Q1. Does M2 match M3 EUE by reallocating shortage energy across fewer hours?")
        println(io)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, pdf)
            isempty(sub) && continue
            mean_eue_diff = mean(sub.eue_diff)
            mean_m2only   = mean(sub.m2_only_eue_mwh)
            mean_m3only   = mean(sub.m3_only_eue_mwh)
            mean_comm_m2  = mean(sub.common_eue_mwh)
            mean_comm_m3  = mean(sub.common_eue_m3_mwh)
            mean_total    = mean(sub.m2_eue)
            pct_comm = mean_total > 0 ? 100.0 * mean_comm_m2 / mean_total : 0.0
            pct_m2only = mean_total > 0 ? 100.0 * mean_m2only / mean_total : 0.0
            println(io, "  $cname:")
            @printf(io, "    Mean EUE: M2=%.2f  M3=%.2f  diff=%+.6f MWh\n",
                    mean_total, mean(sub.m3_eue), mean_eue_diff)
            @printf(io, "    M2 EUE breakdown:  common=%.2f MWh (%.1f%%)  m2_only=%.2f MWh (%.1f%%)\n",
                    mean_comm_m2, pct_comm, mean_m2only, pct_m2only)
            @printf(io, "    M3 EUE at common:  %.2f MWh  (M2 excess at common: %+.2f MWh)\n",
                    mean_comm_m3, mean_comm_m2 - mean_comm_m3)
            @printf(io, "    M3-only EUE:       %.2f MWh  M2-only EUE: %.2f MWh\n",
                    mean_m3only, mean_m2only)
            # compensation check: M2 must cover M3-only energy somewhere
            # if m3_only_eue > m2_only_eue then the deficit appears as larger common events
            println(io)
        end

        # ── Q2: intensity comparison ────────────────────────────────────────────
        println(io, "Q2. Are M2-only shortage hours larger (more intense) than M3-only hours?")
        println(io)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, pdf)
            isempty(sub) && continue
            rows_with_m2only = filter(r -> r.m2_only_shortage_hours > 0, sub)
            rows_with_m3only = filter(r -> r.m3_only_shortage_hours > 0, sub)
            m2_int = isempty(rows_with_m2only) ? NaN : mean(rows_with_m2only.m2_intensity_m2only)
            m3_int = isempty(rows_with_m3only) ? NaN : mean(rows_with_m3only.m3_intensity_m3only)
            m2_comm = mean(sub.m2_intensity_common)
            m3_comm = mean(sub.m3_intensity_common)
            println(io, "  $cname:")
            @printf(io, "    M2-only hours intensity: %.2f MW/h  |  M3-only hours intensity: %.2f MW/h\n",
                    isnan(m2_int) ? 0.0 : m2_int,
                    isnan(m3_int) ? 0.0 : m3_int)
            @printf(io, "    Common hours intensity:  M2=%.2f MW/h  M3=%.2f MW/h\n",
                    m2_comm, m3_comm)
            ratio = (!isnan(m2_int) && !isnan(m3_int) && m3_int > 0) ? m2_int/m3_int : NaN
            isnan(ratio) || @printf(io, "    M2-only vs M3-only intensity ratio: %.2fx\n", ratio)
            println(io)
        end

        # ── Q3: which scenarios drive LOLH gap ─────────────────────────────────
        println(io, "Q3. Which cases/scenarios drive the LOLH difference?")
        println(io)
        # sort by lolh_diff ascending (most negative first)
        sorted = pdf[sortperm(pdf.lolh_diff), :]
        for r in eachrow(sorted)
            r.lolh_diff == 0 && continue
            @printf(io, "  %-16s scen %d:  M2=%2d h  M3=%2d h  Δ=%+d h  (m2_only=%d h, m3_only=%d h)\n",
                    r.case_name, r.scenario_id,
                    r.m2_lolh, r.m3_lolh, r.lolh_diff,
                    r.m2_only_shortage_hours, r.m3_only_shortage_hours)
        end
        println(io)

        # ── Q4: materiality for EUE / CVaR ────────────────────────────────────
        println(io, "Q4. Is the LOLH difference material for EUE or mainly an event-frequency artifact?")
        println(io)
        for cname in cases_to_run
            sub = filter(r -> r.case_name == cname, pdf)
            isempty(sub) && continue
            total_eue = mean(sub.m2_eue)
            frac_m3only = total_eue > 0 ? mean(sub.m3_only_eue_mwh) / total_eue : 0.0
            frac_m2only = total_eue > 0 ? mean(sub.m2_only_eue_mwh) / total_eue : 0.0
            println(io, "  $cname:")
            @printf(io, "    M3-only EUE fraction of total: %.2f%%  (%.2f MWh / %.2f MWh)\n",
                    100*frac_m3only, mean(sub.m3_only_eue_mwh), total_eue)
            @printf(io, "    M2-only EUE fraction of total: %.2f%%  (%.2f MWh / %.2f MWh)\n",
                    100*frac_m2only, mean(sub.m2_only_eue_mwh), total_eue)
            if frac_m3only < 0.05
                println(io, "    → EUE impact is small (<5%); difference is mainly event-frequency artifact.")
            else
                println(io, "    → EUE impact is non-trivial (≥5%); difference may affect CVaR/tail metrics.")
            end
            println(io)
        end

        # ── detail: small intensity events missed by M2 ────────────────────────
        if !isempty(ddf)
            m3only_rows = filter(r -> r.classification == "m3_only", ddf)
            if !isempty(m3only_rows)
                println(io, "M3-only shortage events (hours M2 misses; sorted by shed size)")
                println(io, "-" ^ 70)
                @printf(io, "  %-16s %4s %5s %10s %10s\n",
                        "Case", "Scen", "Hour", "M3_MW", "M2_MW")
                println(io, "  " * "-" ^ 64)
                n3 = size(m3only_rows, 1)
                top = m3only_rows[sortperm(m3only_rows.m3_load_shed_mw, rev=true)[1:min(20, n3)], :]
                for r in eachrow(top)
                    @printf(io, "  %-16s %4d %5d %10.4f %10.4f\n",
                            r.case_name, r.scenario_id, r.hour,
                            r.m3_load_shed_mw, r.m2_load_shed_mw)
                end
                println(io)
                @printf(io, "  Total M3-only events: %d  |  Max M3 shed: %.4f MW  |  Mean M3 shed: %.4f MW\n",
                        n3,
                        maximum(m3only_rows.m3_load_shed_mw),
                        mean(m3only_rows.m3_load_shed_mw))
            end
            println(io)

            m2only_rows = filter(r -> r.classification == "m2_only", ddf)
            if !isempty(m2only_rows)
                println(io, "M2-only shortage events (hours M3 misses; sorted by shed size)")
                println(io, "-" ^ 70)
                @printf(io, "  %-16s %4s %5s %10s %10s\n",
                        "Case", "Scen", "Hour", "M2_MW", "M3_MW")
                println(io, "  " * "-" ^ 64)
                n2 = size(m2only_rows, 1)
                top2 = m2only_rows[sortperm(m2only_rows.m2_load_shed_mw, rev=true)[1:min(20, n2)], :]
                for r in eachrow(top2)
                    @printf(io, "  %-16s %4d %5d %10.4f %10.4f\n",
                            r.case_name, r.scenario_id, r.hour,
                            r.m2_load_shed_mw, r.m3_load_shed_mw)
                end
                println(io)
                @printf(io, "  Total M2-only events: %d  |  Max M2 shed: %.4f MW  |  Mean M2 shed: %.4f MW\n",
                        n2,
                        maximum(m2only_rows.m2_load_shed_mw),
                        mean(m2only_rows.m2_load_shed_mw))
            end
        end

        println(io)
        @printf(io, "Total runtime: %.1f s\n", total_rt)
        println(io, sep)
        println(io, "Files: shortage_pattern_comparison.csv  |  shortage_hour_detail.csv")
    end

    # ── console output ─────────────────────────────────────────────────────────
    println()
    println("=" ^ 78)
    println("M2 vs M3 Shortage Pattern Diagnostic")
    @printf("n=%d  seed=%d  threshold=%.3f MW\n", n_scenarios, seed, SHED_THRESHOLD)
    println("=" ^ 78)
    println()

    println("Per-scenario breakdown:")
    @printf("  %-16s %4s %6s %6s %6s  %6s %6s %6s\n",
            "Case", "Scen", "M2_h", "M3_h", "Δh", "Comm", "M2only", "M3only")
    println("  " * "-" ^ 70)
    for r in eachrow(pdf)
        @printf("  %-16s %4d %6d %6d %+6d  %6d %6d %6d\n",
                r.case_name, r.scenario_id,
                r.m2_lolh, r.m3_lolh, r.lolh_diff,
                r.common_shortage_hours,
                r.m2_only_shortage_hours,
                r.m3_only_shortage_hours)
    end

    println()
    println("Intensity comparison (mean MW per shortage hour):")
    @printf("  %-16s %14s %14s %14s %14s\n",
            "Case", "Comm(M2)", "Comm(M3)", "M2only", "M3only")
    println("  " * "-" ^ 70)
    for cname in cases_to_run
        sub = filter(r -> r.case_name == cname, pdf)
        isempty(sub) && continue
        rows_m2 = filter(r -> r.m2_only_shortage_hours > 0, sub)
        rows_m3 = filter(r -> r.m3_only_shortage_hours > 0, sub)
        @printf("  %-16s %14.2f %14.2f %14.2f %14.2f\n",
                cname,
                mean(sub.m2_intensity_common),
                mean(sub.m3_intensity_common),
                isempty(rows_m2) ? 0.0 : mean(rows_m2.m2_intensity_m2only),
                isempty(rows_m3) ? 0.0 : mean(rows_m3.m3_intensity_m3only))
    end

    println()
    println("EUE breakdown (means across scenarios, MWh):")
    @printf("  %-16s %10s %10s %10s %10s %12s\n",
            "Case", "Common(M2)", "Common(M3)", "M2only", "M3only", "EUE_diff")
    println("  " * "-" ^ 70)
    for cname in cases_to_run
        sub = filter(r -> r.case_name == cname, pdf)
        isempty(sub) && continue
        @printf("  %-16s %10.2f %10.2f %10.2f %10.2f %+12.6f\n",
                cname,
                mean(sub.common_eue_mwh),
                mean(sub.common_eue_m3_mwh),
                mean(sub.m2_only_eue_mwh),
                mean(sub.m3_only_eue_mwh),
                mean(sub.eue_diff))
    end

    println()
    @printf("Total runtime: %.1f s\n", total_rt)
    @printf("Output: %s\n", abspath(out_dir))
    @printf("Summary: %s\n", abspath(summary_path))
    println()
end
