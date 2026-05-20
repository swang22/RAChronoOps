#!/usr/bin/env julia
# 34_compare_no_storage_classic_vs_ed.jl
#
# Compare three reliability models on no-storage case variants:
#
#   MC-NoStorage  — classical hourly capacity-adequacy MC (run_mc_no_storage)
#   M3-NoStorage  — full-year ED LP without storage (run_m3_ed_dispatch on
#                   _nostorage case, so storage block is skipped internally)
#   M3-WithStorage — M3 on the base case (reference; shows storage contribution)
#
# The difference MC-NoStorage vs M3-NoStorage isolates the effect of
# chronological storage optimisation vs instantaneous capacity check.
# The difference M3-NoStorage vs M3-WithStorage isolates storage value.
#
# Prerequisite: run script 33 first to build the _nostorage case directories.
#
# Usage:
#   julia --project=. scripts/34_compare_no_storage_classic_vs_ed.jl \
#     [--cases VRE120_base,VRE120_wind_hvy] \
#     [--n-scenarios 20] \
#     [--seed 42] \
#     [--out-dir results/no_storage_comparison]
#
# Options:
#   --cases        Comma-separated base case names (default: VRE120_base,VRE120_wind_hvy)
#   --n-scenarios  Monte Carlo scenario count (default: 20)
#   --seed         RNG seed (default: 42)
#   --out-dir      Output directory (default: results/no_storage_comparison)

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

# ── Metrics helpers ───────────────────────────────────────────────────────────

function run_and_measure(f, label::String)
    print("    $(label) … ")
    t0 = time()
    results = f()
    rt = time() - t0
    println(@sprintf("done (%.1f s)", rt))
    return results, rt
end

function metrics_row(model::String, case::String,
                     results::Vector{DispatchResult},
                     system::SystemData, config::SimConfig,
                     total_rt::Float64)
    m = compute_metrics(results, system, config)
    n = length(results)
    (
        model                    = model,
        case                     = case,
        lolh                     = m.lolh,
        eue_mwh                  = m.eue,
        neue_ppm                 = m.neue * 1e6,
        cvar_eue_mwh             = m.cvar_eue,
        p95_eue_mwh              = m.p95_scenario_eue,
        n_shortage_events        = m.n_shortage_events,
        mean_shortage_duration_h = m.mean_shortage_duration,
        total_runtime_s          = total_rt,
        mean_runtime_s           = total_rt / max(1, n),
    )
end

# ── Per-scenario rows ─────────────────────────────────────────────────────────

function scenario_rows(model::String, case::String,
                       results::Vector{DispatchResult})
    map(results) do r
        ls = r.load_shed
        (
            model       = model,
            case        = case,
            scenario_id = r.scenario_id,
            lolh        = compute_lolh(ls),
            eue_mwh     = compute_eue(ls),
        )
    end
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    cases_str  = get(kw, "cases",       "VRE120_base,VRE120_wind_hvy")
    n_scen     = parse(Int, get(kw, "n-scenarios", "20"))
    seed       = parse(Int, get(kw, "seed",         "42"))
    out_dir    = get(kw, "out-dir",  joinpath(@__DIR__, "..", "results", "no_storage_comparison"))
    out_dir    = abspath(out_dir)

    cases      = strip.(split(cases_str, ","))
    data_root  = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))

    println("=" ^ 70)
    println("34_compare_no_storage_classic_vs_ed.jl")
    println("Date: ", Dates.now())
    println("Cases: ", join(cases, ", "))
    println("N scenarios: $n_scen  seed: $seed")
    println("=" ^ 70)

    mkpath(out_dir)

    all_agg_rows  = NamedTuple[]
    all_scen_rows = NamedTuple[]

    for base_case in cases
        println("\nCase: $base_case")

        ns_case = base_case * "_nostorage"
        ns_dir  = joinpath(data_root, ns_case)
        base_dir = joinpath(data_root, base_case)

        if !isdir(ns_dir)
            @warn "No-storage case not found at $ns_dir — run script 33 first. Skipping."
            continue
        end

        # ── Load data ─────────────────────────────────────────────────────────
        sys_ns   = load_system_data(ns_dir)
        sys_base = isdir(base_dir) ? load_system_data(base_dir) : nothing

        cfg = SimConfig(n_scenarios=n_scen, seed=seed)

        # Shared scenario set so all models see the same outage realisations
        scenarios = generate_scenarios(sys_ns, cfg)

        # ── MC-NoStorage ──────────────────────────────────────────────────────
        println("  MC-NoStorage:")
        res_mc, rt_mc = run_and_measure("run_mc_no_storage") do
            run_mc_no_storage(sys_ns, scenarios, cfg)
        end
        push!(all_agg_rows,  metrics_row("MC-NoStorage",  base_case, res_mc,  sys_ns, cfg, rt_mc))
        append!(all_scen_rows, scenario_rows("MC-NoStorage", base_case, res_mc))

        # ── M3-NoStorage (ED LP, no storage) ──────────────────────────────────
        println("  M3-NoStorage (ED LP):")
        res_m3ns, rt_m3ns = run_and_measure("run_m3_ed_dispatch") do
            run_m3_ed_dispatch(sys_ns, scenarios, cfg)
        end
        push!(all_agg_rows,  metrics_row("M3-NoStorage",  base_case, res_m3ns, sys_ns, cfg, rt_m3ns))
        append!(all_scen_rows, scenario_rows("M3-NoStorage", base_case, res_m3ns))

        # ── M3-WithStorage (base case with storage) ────────────────────────────
        if !isnothing(sys_base)
            println("  M3-WithStorage (base, reference):")
            # Re-generate scenarios on the base system (same seed → same outages)
            scenarios_base = generate_scenarios(sys_base, cfg)
            res_m3ws, rt_m3ws = run_and_measure("run_m3_ed_dispatch") do
                run_m3_ed_dispatch(sys_base, scenarios_base, cfg)
            end
            push!(all_agg_rows,  metrics_row("M3-WithStorage", base_case, res_m3ws, sys_base, cfg, rt_m3ws))
            append!(all_scen_rows, scenario_rows("M3-WithStorage", base_case, res_m3ws))
        end
    end

    # ── Save results ──────────────────────────────────────────────────────────
    agg_df  = DataFrame(all_agg_rows)
    scen_df = DataFrame(all_scen_rows)

    agg_path  = joinpath(out_dir, "no_storage_comparison_aggregate.csv")
    scen_path = joinpath(out_dir, "no_storage_comparison_by_scenario.csv")
    CSV.write(agg_path,  agg_df)
    CSV.write(scen_path, scen_df)

    println("\n", "=" ^ 70)
    println("Aggregate results:")
    println("=" ^ 70)
    println(@sprintf("%-22s  %-25s  %7s  %10s  %10s  %8s",
                     "Model", "Case", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)", "RT (s)"))
    println("-" ^ 90)
    for r in all_agg_rows
        @printf("%-22s  %-25s  %7.1f  %10.2f  %10.2f  %8.1f\n",
                r.model, r.case, r.lolh, r.eue_mwh, r.cvar_eue_mwh, r.total_runtime_s)
    end

    println()
    println("Storage contribution (MC-NoStorage − M3-WithStorage EUE, per case):")
    for case_name in unique(agg_df.case)
        sub = filter(r -> r.case == case_name, all_agg_rows)
        mc_eue = get(filter(r -> r.model == "MC-NoStorage",  sub), 1, nothing)
        ws_eue = get(filter(r -> r.model == "M3-WithStorage", sub), 1, nothing)
        if !isnothing(mc_eue) && !isnothing(ws_eue)
            delta = mc_eue.eue_mwh - ws_eue.eue_mwh
            @printf("  %s: ΔEUE = %.2f MWh (%.1f%% reduction from storage)\n",
                    case_name, delta,
                    ws_eue.eue_mwh > 0 ? delta / ws_eue.eue_mwh * 100 : NaN)
        end
    end

    println()
    println("Saved: $agg_path")
    println("Saved: $scen_path")
    println()

    # ── Write summary.txt ─────────────────────────────────────────────────────
    sum_path = joinpath(out_dir, "summary.txt")
    open(sum_path, "w") do io
        println(io, "No-Storage Comparison: MC-NoStorage vs M3-NoStorage vs M3-WithStorage")
        println(io, "Generated: ", Dates.now())
        println(io, "Cases: ", join(cases, ", "))
        println(io, "N scenarios: $n_scen  seed: $seed")
        println(io)
        println(io, @sprintf("%-22s  %-25s  %7s  %10s  %10s",
                              "Model", "Case", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)"))
        println(io, "-" ^ 78)
        for r in all_agg_rows
            println(io, @sprintf("%-22s  %-25s  %7.1f  %10.2f  %10.2f",
                                  r.model, r.case, r.lolh, r.eue_mwh, r.cvar_eue_mwh))
        end
        println(io)
        println(io, "Key:")
        println(io, "  MC-NoStorage:   instantaneous capacity check, no storage, no LP")
        println(io, "  M3-NoStorage:   full-year ED LP, no storage (shows LP foresight value)")
        println(io, "  M3-WithStorage: full-year ED LP with storage (reference)")
        println(io, "  ΔEUE(MC-NS − M3-WS): total storage + LP foresight contribution")
        println(io, "  ΔEUE(MC-NS − M3-NS): LP foresight alone (no storage in either model)")
        println(io, "  ΔEUE(M3-NS − M3-WS): storage contribution alone (same LP foresight)")
    end
    println("Saved: $sum_path")
end

main()
