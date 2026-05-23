#!/usr/bin/env julia
# 41_run_m1_m1b_n20_for_paper.jl
#
# Regenerate Naive Storage MC (M1) and Reserve-Floor Storage MC (M1b) at N=20
# so the paper storage-method comparison table is internally consistent.
#
# Rationale: M1 and M1b were originally run at N=3 as a diagnostic pilot.
# This script re-runs them at N=20 with the same seed (42) and the same
# ScenarioSet structure used by M1c / M2 / M3 in script 38.  The resulting
# CSV files replace the N=3 data in the paper-ready table builder (script 40).
#
# Output (results/m1_m1b_n20_paper/):
#   m1_m1b_aggregate_metrics.csv   — one row per model × case
#   m1_m1b_metrics_by_scenario.csv — one row per model × case × scenario
#   m1_m1b_errors_vs_m3.csv        — M1/M1b errors relative to M3 benchmark
#   summary.txt
#
# M3 reference values are read from the committed results at:
#   results/m1d_storage_heuristic_comparison/m1d_aggregate_metrics.csv
#
# Usage:
#   julia --project=. scripts/41_run_m1_m1b_n20_for_paper.jl \
#     [--cases VRE120_base,VRE120_wind_hvy] \
#     [--n-scenarios 20] \
#     [--seed 42] \
#     [--out-dir results/m1_m1b_n20_paper]

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames
using Statistics, Printf, Dates

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

# ── Helpers ───────────────────────────────────────────────────────────────────

function run_and_measure(f, label::String)
    print("    $label … ")
    t0 = time()
    results = f()
    rt = time() - t0
    println(@sprintf("%.1f s", rt))
    return results, rt
end

function full_metrics_row(model::String, case::String,
                           results::Vector{DispatchResult},
                           system::SystemData, config::SimConfig,
                           total_rt::Float64)
    m = compute_metrics(results, system, config)
    n = length(results)
    (
        model                           = model,
        case                            = case,
        lolh                            = m.lolh,
        lolp_percent                    = m.lolp * 100.0,
        lole_days                       = m.lole_days,
        eue_mwh                         = m.eue,
        neue_ppm                        = m.neue * 1e6,
        cvar_eue_mwh                    = m.cvar_eue,
        p90_eue_mwh                     = m.p90_scenario_eue,
        p95_eue_mwh                     = m.p95_scenario_eue,
        p99_eue_mwh                     = m.p99_scenario_eue,
        n_shortage_events               = m.n_shortage_events,
        mean_shortage_duration_h        = m.mean_shortage_duration,
        max_shortage_duration_h         = m.max_shortage_duration,
        p95_shortage_duration_h         = m.p95_shortage_duration,
        max_shortfall_mw                = m.max_shortfall,
        mean_shortfall_when_shedding_mw = m.mean_shortfall_when_shedding,
        lolh_ci95_halfwidth             = m.lolh_ci95_halfwidth,
        eue_ci95_halfwidth_mwh          = m.eue_ci95_halfwidth,
        total_runtime_s                 = total_rt,
        mean_runtime_s                  = total_rt / max(1, n),
    )
end

function scenario_rows_from_dispatch(model::String, case::String,
                                      results::Vector{DispatchResult})
    map(results) do r
        ls = r.load_shed
        durs = compute_shortage_events(ls)
        (
            model                    = model,
            case                     = case,
            scenario_id              = r.scenario_id,
            lolh                     = compute_lolh(ls),
            eue_mwh                  = compute_eue(ls),
            max_shortfall_mw         = maximum(ls),
            n_shortage_events        = length(durs),
            mean_shortage_duration_h = isempty(durs) ? 0.0 : mean(Float64.(durs)),
            runtime_s                = r.runtime_seconds,
        )
    end
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    cases_s = get(kw, "cases",        "VRE120_base,VRE120_wind_hvy")
    n_scen  = parse(Int, get(kw, "n-scenarios", "20"))
    seed    = parse(Int, get(kw, "seed",        "42"))
    out_dir = abspath(get(kw, "out-dir",
                joinpath(@__DIR__, "..", "results", "m1_m1b_n20_paper")))

    cases     = String.(strip.(split(cases_s, ",")))
    data_root = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))
    m3_ref_path = abspath(joinpath(@__DIR__, "..",
                    "results", "m1d_storage_heuristic_comparison",
                    "m1d_aggregate_metrics.csv"))

    println("=" ^ 70)
    println("41_run_m1_m1b_n20_for_paper.jl")
    println("Date: ", Dates.now())
    println("Cases: ", join(cases, ", "))
    println("N=$n_scen, seed=$seed")
    println("Output: ", out_dir)
    println("M3 reference: ", m3_ref_path)
    println("=" ^ 70)

    mkpath(out_dir)

    all_agg_rows  = NamedTuple[]
    all_scen_rows = NamedTuple[]

    for case in cases
        println("\n── Case: $case ──────────────────────────────────────────────")

        case_dir = joinpath(data_root, case)
        isdir(case_dir) || error("Case directory not found: $case_dir")

        sys      = load_system_data(case_dir)
        base_cfg = SimConfig(n_scenarios=n_scen, seed=seed)

        println("\nGenerating ScenarioSet (n=$n_scen, seed=$seed) …")
        scen = generate_scenarios(sys, base_cfg)

        println("\nRunning models:")

        res_m1, rt_m1 = run_and_measure("M1  (naive peak-shaving)") do
            run_m1_rule_based(sys, scen, base_cfg)
        end
        push!(all_agg_rows, full_metrics_row("M1", case, res_m1, sys, base_cfg, rt_m1))
        append!(all_scen_rows, scenario_rows_from_dispatch("M1", case, res_m1))

        res_m1b, rt_m1b = run_and_measure("M1b (reserve-floor heuristic)") do
            run_m1b_reserve_aware(sys, scen, base_cfg)
        end
        push!(all_agg_rows, full_metrics_row("M1b", case, res_m1b, sys, base_cfg, rt_m1b))
        append!(all_scen_rows, scenario_rows_from_dispatch("M1b", case, res_m1b))
    end

    # ── Save scenario and aggregate CSVs ─────────────────────────────────────
    agg_df  = DataFrame(all_agg_rows)
    scen_df = DataFrame(all_scen_rows)

    CSV.write(joinpath(out_dir, "m1_m1b_aggregate_metrics.csv"),   agg_df)
    CSV.write(joinpath(out_dir, "m1_m1b_metrics_by_scenario.csv"), scen_df)

    println("\nAggregates written.")

    # ── Build errors-vs-M3 table ─────────────────────────────────────────────
    err_rows = NamedTuple[]

    if isfile(m3_ref_path)
        m3_ref = CSV.read(m3_ref_path, DataFrame)
        m3_ref = filter(r -> r.model == "M3", m3_ref)

        for row in eachrow(agg_df)
            m3_case = filter(r -> r.case == row.case, m3_ref)
            if isempty(m3_case)
                @warn "No M3 reference found for case $(row.case) — skipping error row"
                continue
            end
            m3 = first(m3_case)
            rt_ratio = (m3.mean_runtime_s > 0 && row.mean_runtime_s > 0) ?
                round(m3.mean_runtime_s / row.mean_runtime_s; digits=1) : NaN
            push!(err_rows, (
                case_name            = row.case,
                model                = row.model,
                m3_lolh              = m3.lolh,
                model_lolh           = row.lolh,
                lolh_error_vs_m3     = row.lolh - m3.lolh,
                m3_eue               = m3.eue_mwh,
                model_eue            = row.eue_mwh,
                eue_error_vs_m3      = row.eue_mwh - m3.eue_mwh,
                m3_cvar              = m3.cvar_eue_mwh,
                model_cvar           = row.cvar_eue_mwh,
                cvar_error_vs_m3     = row.cvar_eue_mwh - m3.cvar_eue_mwh,
                runtime_ratio_vs_m3  = rt_ratio,
            ))
        end
    else
        @warn "M3 reference file not found ($m3_ref_path) — m1_m1b_errors_vs_m3.csv will be empty"
    end

    err_df = DataFrame(err_rows)
    CSV.write(joinpath(out_dir, "m1_m1b_errors_vs_m3.csv"), err_df)

    # ── Summary ───────────────────────────────────────────────────────────────
    summary_path = joinpath(out_dir, "summary.txt")
    open(summary_path, "w") do io
        write_summary(io, all_agg_rows, err_rows, cases, n_scen, seed)
    end

    println("\nOutput written to: ", out_dir)
    println("  m1_m1b_aggregate_metrics.csv")
    println("  m1_m1b_metrics_by_scenario.csv")
    println("  m1_m1b_errors_vs_m3.csv")
    println("  summary.txt")
end

# ── Summary writer ────────────────────────────────────────────────────────────

function write_summary(io, agg_rows, err_rows, cases, n_scen, seed)
    println(io, "M1 / M1b Naive and Reserve-Floor Storage MC at N=$n_scen")
    println(io, "Generated: ", Dates.now())
    println(io, "Cases: ", join(cases, ", "), "  |  N=$n_scen, seed=$seed")
    println(io, "Purpose: paper consistency run — replace N=3 diagnostic pilot data")

    model_order = ["M1", "M1b"]

    for case in cases
        println(io, "\n", "─"^70)
        println(io, "Case: $case")
        println(io, "─"^70)
        println(io, @sprintf("%-6s  %8s  %12s  %12s  %12s  %9s",
                             "Model", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)",
                             "p95 (MWh)", "RT (s)"))
        println(io, "-"^70)

        for model in model_order
            row = findfirst(r -> r.model == model && r.case == case, agg_rows)
            isnothing(row) && continue
            r = agg_rows[row]
            println(io, @sprintf("%-6s  %8.1f  %12.2f  %12.2f  %12.2f  %9.1f",
                                 model, r.lolh, r.eue_mwh, r.cvar_eue_mwh,
                                 r.p95_eue_mwh, r.total_runtime_s))
        end
    end

    # ── Errors vs M3 ──────────────────────────────────────────────────────────
    if !isempty(err_rows)
        println(io, "\n", "─"^70)
        println(io, "Errors vs Full-Year ED-MC (M3) benchmark")
        println(io, "─"^70)
        println(io, @sprintf("%-25s  %-6s  %10s  %10s  %10s  %10s",
                             "Case", "Model",
                             "ΔLOLH (h)", "ΔEUE (MWh)", "ΔCVaR (MWh)", "RT ratio"))
        println(io, "-"^70)
        for r in err_rows
            println(io, @sprintf("%-25s  %-6s  %+10.1f  %+10.1f  %+10.1f  %10.1f×",
                                 r.case_name, r.model,
                                 r.lolh_error_vs_m3, r.eue_error_vs_m3,
                                 r.cvar_error_vs_m3, r.runtime_ratio_vs_m3))
        end
        println(io, "\nInterpretation:")
        println(io, "  M1 (naive peak-shaving) and M1b (reserve-floor) substantially")
        println(io, "  overestimate reliability risk relative to Full-Year ED-MC (M3).")
        println(io, "  Both are retained as diagnostic failure cases showing the")
        println(io, "  consequence of proactive storage discharge before shortage events.")
    end
end

main()
