#!/usr/bin/env julia
# 34_compare_no_storage_classic_vs_ed.jl
#
# Compare three reliability models on no-storage / base case pairs:
#
#   MC-NoStorage   — run_mc_no_storage on <case>_nostorage
#                    classical hourly capacity adequacy, no LP, no storage
#   M3-NoStorage   — run_m3_ed_dispatch on <case>_nostorage
#                    full-year ED LP with no storage
#   M3-WithStorage — run_m3_ed_dispatch on <case>
#                    full-year ED LP with storage (reference)
#
# Outputs (results/no_storage_comparison/):
#   no_storage_aggregate_metrics.csv    — one row per (case, model)
#   no_storage_metrics_by_scenario.csv  — one row per (case, model, scenario)
#   no_storage_errors_vs_m3.csv         — per-scenario MC vs LP discrepancy
#   summary.txt                         — EUE decomposition + Q&A
#
# Prerequisite: run script 33 first to build <case>_nostorage directories.
#
# Usage:
#   julia --project=. scripts/34_compare_no_storage_classic_vs_ed.jl \
#     [--cases VRE120_base,VRE120_wind_hvy] \
#     [--n-scenarios 20] \
#     [--seed 42] \
#     [--out-dir results/no_storage_comparison]

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
        case                         = case,
        model                        = model,
        lolh                         = m.lolh,
        lolp_percent                 = m.lolp * 100.0,
        lole_days                    = m.lole_days,
        eue_mwh                      = m.eue,
        neue_ppm                     = m.neue * 1e6,
        cvar_eue_mwh                 = m.cvar_eue,
        p90_eue_mwh                  = m.p90_scenario_eue,
        p95_eue_mwh                  = m.p95_scenario_eue,
        p99_eue_mwh                  = m.p99_scenario_eue,
        n_shortage_events            = m.n_shortage_events,
        mean_shortage_duration_h     = m.mean_shortage_duration,
        max_shortage_duration_h      = m.max_shortage_duration,
        p95_shortage_duration_h      = m.p95_shortage_duration,
        max_shortfall_mw             = m.max_shortfall,
        mean_shortfall_when_shedding_mw = m.mean_shortfall_when_shedding,
        lolh_ci95_halfwidth          = m.lolh_ci95_halfwidth,
        eue_ci95_halfwidth_mwh       = m.eue_ci95_halfwidth,
        total_runtime_s              = total_rt,
        mean_runtime_s               = total_rt / max(1, n),
    )
end

function scenario_rows(model::String, case::String,
                       results::Vector{DispatchResult})
    map(results) do r
        ls = r.load_shed
        durs = compute_shortage_events(ls)
        (
            case                    = case,
            model                   = model,
            scenario_id             = r.scenario_id,
            lolh                    = compute_lolh(ls),
            eue_mwh                 = compute_eue(ls),
            max_shortfall_mw        = maximum(ls),
            n_shortage_events       = length(durs),
            mean_shortage_duration_h= isempty(durs) ? 0.0 : mean(Float64.(durs)),
            runtime_s               = r.runtime_seconds,
        )
    end
end

# ── Summary helpers ───────────────────────────────────────────────────────────

function find_row(rows, case::String, model::String)
    idx = findfirst(r -> r.case == case && r.model == model, rows)
    isnothing(idx) ? nothing : rows[idx]
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    cases_str = get(kw, "cases",        "VRE120_base,VRE120_wind_hvy")
    n_scen    = parse(Int, get(kw, "n-scenarios", "20"))
    seed      = parse(Int, get(kw, "seed",         "42"))
    out_dir   = get(kw, "out-dir",
                    joinpath(@__DIR__, "..", "results", "no_storage_comparison"))
    out_dir   = abspath(out_dir)
    cases     = String.(strip.(split(cases_str, ",")))
    data_root = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))

    println("=" ^ 70)
    println("34_compare_no_storage_classic_vs_ed.jl")
    println("Date: ", Dates.now())
    println("Cases: ", join(cases, ", "))
    println("N scenarios: $n_scen  seed: $seed")
    println("=" ^ 70)

    mkpath(out_dir)

    all_agg   = NamedTuple[]
    all_scen  = NamedTuple[]

    for base_case in cases
        println("\nCase: $base_case")
        ns_case  = base_case * "_nostorage"
        ns_dir   = joinpath(data_root, ns_case)
        base_dir = joinpath(data_root, base_case)

        if !isdir(ns_dir)
            @warn "No-storage case not found: $ns_dir — run script 33 first. Skipping."
            continue
        end

        sys_ns   = load_system_data(ns_dir)
        sys_base = isdir(base_dir) ? load_system_data(base_dir) : nothing
        cfg      = SimConfig(n_scenarios=n_scen, seed=seed)
        scen_ns  = generate_scenarios(sys_ns, cfg)

        # MC-NoStorage
        println("  MC-NoStorage:")
        res_mc, rt_mc = run_and_measure("run_mc_no_storage") do
            run_mc_no_storage(sys_ns, scen_ns, cfg)
        end
        push!(all_agg, full_metrics_row("MC-NoStorage", base_case, res_mc, sys_ns, cfg, rt_mc))
        append!(all_scen, scenario_rows("MC-NoStorage", base_case, res_mc))

        # M3-NoStorage
        println("  M3-NoStorage:")
        res_m3ns, rt_m3ns = run_and_measure("run_m3_ed_dispatch") do
            run_m3_ed_dispatch(sys_ns, scen_ns, cfg)
        end
        push!(all_agg, full_metrics_row("M3-NoStorage", base_case, res_m3ns, sys_ns, cfg, rt_m3ns))
        append!(all_scen, scenario_rows("M3-NoStorage", base_case, res_m3ns))

        # M3-WithStorage
        if !isnothing(sys_base)
            println("  M3-WithStorage:")
            scen_base = generate_scenarios(sys_base, cfg)
            res_m3ws, rt_m3ws = run_and_measure("run_m3_ed_dispatch") do
                run_m3_ed_dispatch(sys_base, scen_base, cfg)
            end
            push!(all_agg, full_metrics_row("M3-WithStorage", base_case, res_m3ws, sys_base, cfg, rt_m3ws))
            append!(all_scen, scenario_rows("M3-WithStorage", base_case, res_m3ws))
        end
    end

    # ── Save aggregate and per-scenario CSVs ─────────────────────────────────
    agg_df  = DataFrame(all_agg)
    scen_df = DataFrame(all_scen)
    CSV.write(joinpath(out_dir, "no_storage_aggregate_metrics.csv"), agg_df)
    CSV.write(joinpath(out_dir, "no_storage_metrics_by_scenario.csv"), scen_df)
    println("\nSaved: no_storage_aggregate_metrics.csv")
    println("Saved: no_storage_metrics_by_scenario.csv")

    # ── MC-vs-M3 per-scenario error table ─────────────────────────────────────
    # Shows per-scenario discrepancy between MC-NoStorage and M3-NoStorage.
    # A non-zero delta reveals where hourly capacity check diverges from LP.
    err_rows = NamedTuple[]
    for base_case in cases
        mc_rows = filter(r -> r.case == base_case && r.model == "MC-NoStorage", all_scen)
        m3_rows = filter(r -> r.case == base_case && r.model == "M3-NoStorage", all_scen)
        for (mc, m3) in zip(mc_rows, m3_rows)
            mc.scenario_id == m3.scenario_id || continue
            push!(err_rows, (
                case              = base_case,
                scenario_id       = mc.scenario_id,
                mc_eue_mwh        = mc.eue_mwh,
                m3_eue_mwh        = m3.eue_mwh,
                delta_eue_mwh     = mc.eue_mwh - m3.eue_mwh,
                mc_lolh           = mc.lolh,
                m3_lolh           = m3.lolh,
                delta_lolh        = mc.lolh - m3.lolh,
            ))
        end
    end
    err_df = DataFrame(err_rows)
    CSV.write(joinpath(out_dir, "no_storage_errors_vs_m3.csv"), err_df)
    println("Saved: no_storage_errors_vs_m3.csv")

    # ── Console aggregate table ────────────────────────────────────────────────
    println()
    println("=" ^ 70)
    println("Aggregate results (N=$n_scen, seed=$seed):")
    println("=" ^ 70)
    println(@sprintf("%-20s  %-25s  %8s  %11s  %11s  %8s",
                     "Model", "Case", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)", "RT (s)"))
    println("-" ^ 90)
    for r in all_agg
        @printf("%-20s  %-25s  %8.1f  %11.2f  %11.2f  %8.1f\n",
                r.model, r.case, r.lolh, r.eue_mwh, r.cvar_eue_mwh, r.total_runtime_s)
    end

    # ── EUE decomposition ─────────────────────────────────────────────────────
    println()
    println("EUE decomposition (per case):")
    println(@sprintf("%-25s  %11s  %11s  %11s  %11s  %11s  %11s",
                     "Case",
                     "MC-NS", "M3-NS", "M3-WS",
                     "MC-NS−M3-NS", "M3-NS−M3-WS", "MC-NS−M3-WS"))
    println("-" ^ 100)

    decomp_rows = NamedTuple[]
    for base_case in cases
        mc_r = find_row(all_agg, base_case, "MC-NoStorage")
        ns_r = find_row(all_agg, base_case, "M3-NoStorage")
        ws_r = find_row(all_agg, base_case, "M3-WithStorage")
        mc_eue = isnothing(mc_r) ? NaN : mc_r.eue_mwh
        ns_eue = isnothing(ns_r) ? NaN : ns_r.eue_mwh
        ws_eue = isnothing(ws_r) ? NaN : ws_r.eue_mwh
        @printf("%-25s  %11.2f  %11.2f  %11.2f  %11.2f  %11.2f  %11.2f\n",
                base_case, mc_eue, ns_eue, ws_eue,
                mc_eue - ns_eue, ns_eue - ws_eue, mc_eue - ws_eue)
        push!(decomp_rows, (
            case                       = base_case,
            mc_nostorage_eue           = mc_eue,
            m3_nostorage_eue           = ns_eue,
            m3_withstorage_eue         = ws_eue,
            lp_foresight_delta_mwh     = mc_eue - ns_eue,
            storage_value_delta_mwh    = ns_eue - ws_eue,
            total_delta_mwh            = mc_eue - ws_eue,
            lp_foresight_pct           = (ns_eue > 0 && isfinite(mc_eue)) ? (mc_eue - ns_eue) / mc_eue * 100 : NaN,
            storage_value_pct_of_ns    = (ns_eue > 0 && isfinite(ws_eue)) ? (ns_eue - ws_eue) / ns_eue * 100 : NaN,
        ))
    end

    # ── Write summary.txt ─────────────────────────────────────────────────────
    sum_path = joinpath(out_dir, "summary.txt")
    open(sum_path, "w") do io
        println(io, "No-Storage Comparison: MC-NoStorage vs M3-NoStorage vs M3-WithStorage")
        println(io, "Generated: ", Dates.now())
        println(io, "Cases: ", join(cases, ", "))
        println(io, "N scenarios: $n_scen  seed: $seed")
        println(io)
        println(io, "─"^70)
        println(io, "Aggregate metrics")
        println(io, "─"^70)
        println(io, @sprintf("%-20s  %-25s  %8s  %11s  %11s  %11s  %8s",
                              "Model", "Case", "LOLH (h)", "EUE (MWh)",
                              "CVaR (MWh)", "p95 (MWh)", "RT (s)"))
        println(io, "-"^98)
        for r in all_agg
            println(io, @sprintf("%-20s  %-25s  %8.1f  %11.2f  %11.2f  %11.2f  %8.1f",
                                  r.model, r.case, r.lolh, r.eue_mwh,
                                  r.cvar_eue_mwh, r.p95_eue_mwh, r.total_runtime_s))
        end
        println(io)
        println(io, "─"^70)
        println(io, "EUE decomposition (MWh)")
        println(io, "─"^70)
        println(io, @sprintf("%-25s  %11s  %11s  %11s  %13s  %13s  %13s",
                              "Case", "MC-NS", "M3-NS", "M3-WS",
                              "MC-NS−M3-NS", "M3-NS−M3-WS", "MC-NS−M3-WS"))
        println(io, "-"^103)
        for d in decomp_rows
            println(io, @sprintf("%-25s  %11.2f  %11.2f  %11.2f  %13.2f  %13.2f  %13.2f",
                                  d.case,
                                  d.mc_nostorage_eue, d.m3_nostorage_eue, d.m3_withstorage_eue,
                                  d.lp_foresight_delta_mwh,
                                  d.storage_value_delta_mwh,
                                  d.total_delta_mwh))
        end
        println(io, """
Key:
  MC-NS   = MC-NoStorage  (hourly capacity check, no LP, no storage)
  M3-NS   = M3-NoStorage  (full-year ED LP, no storage)
  M3-WS   = M3-WithStorage (full-year ED LP with storage, reference)
  MC-NS − M3-NS  : LP foresight value (both no storage; LP pre-positions vs MC reacts)
  M3-NS − M3-WS  : storage reliability value (same LP; with vs without storage)
  MC-NS − M3-WS  : total gain from LP foresight + storage""")
        println(io)

        # ── Per-scenario MC vs LP error summary ──────────────────────────────
        println(io, "─"^70)
        println(io, "Per-scenario MC-NoStorage vs M3-NoStorage EUE discrepancy")
        println(io, "─"^70)
        for base_case in cases
            sub = filter(r -> r.case == base_case, err_rows)
            isempty(sub) && continue
            deltas = [r.delta_eue_mwh for r in sub]
            println(io, "  $base_case:")
            println(io, @sprintf("    mean Δ = %.2f MWh   max Δ = %.2f MWh   min Δ = %.2f MWh",
                                  mean(deltas), maximum(deltas), minimum(deltas)))
            n_nonzero = count(abs(d) > 0.1 for d in deltas)
            println(io, @sprintf("    scenarios with |Δ| > 0.1 MWh: %d / %d",
                                  n_nonzero, length(deltas)))
        end
        println(io)

        # ── Q&A section ───────────────────────────────────────────────────────
        println(io, "─"^70)
        println(io, "Q&A")
        println(io, "─"^70)

        for base_case in cases
            mc_r = find_row(all_agg, base_case, "MC-NoStorage")
            ns_r = find_row(all_agg, base_case, "M3-NoStorage")
            ws_r = find_row(all_agg, base_case, "M3-WithStorage")
            isnothing(mc_r) || isnothing(ns_r) && continue

            mc_eue = mc_r.eue_mwh; ns_eue = ns_r.eue_mwh
            ws_eue = isnothing(ws_r) ? NaN : ws_r.eue_mwh
            d = findfirst(r -> r.case == base_case, decomp_rows)
            dec = isnothing(d) ? nothing : decomp_rows[d]

            eue_match = abs(mc_eue - ns_eue) < 1.0
            lolh_match = abs(mc_r.lolh - ns_r.lolh) < 0.5

            println(io, "\n--- $base_case ---")

            # Q1: Does MC-NoStorage match M3-NoStorage?
            println(io, "Q1. Does MC-NoStorage match M3-NoStorage?")
            if eue_match && lolh_match
                println(io, @sprintf("  YES — EUE Δ=%.2f MWh, LOLH Δ=%.1f h (well within MC noise).",
                                      mc_eue - ns_eue, mc_r.lolh - ns_r.lolh))
                println(io, "  Classic hourly capacity adequacy matches ED LP when storage is absent.")
            else
                println(io, @sprintf("  NO — EUE Δ=%.2f MWh (%.1f%%), LOLH Δ=%.1f h.",
                                      mc_eue - ns_eue,
                                      ns_eue > 0 ? abs(mc_eue-ns_eue)/ns_eue*100 : 0.0,
                                      mc_r.lolh - ns_r.lolh))
                # Q2: Which metric differs most?
                max_metric = "EUE"
                max_val = abs(mc_eue - ns_eue)
                if abs(mc_r.lolh - ns_r.lolh) > max_val / 1000
                    max_metric = "LOLH"
                end
                println(io, "Q2. Metric that differs most: $max_metric")
                println(io, @sprintf("  EUE Δ=%.2f MWh, LOLH Δ=%.1f h, CVaR Δ=%.2f MWh.",
                                      mc_eue - ns_eue, mc_r.lolh - ns_r.lolh,
                                      mc_r.cvar_eue_mwh - ns_r.cvar_eue_mwh))
            end
            !eue_match && println(io, "Q2. Metric that differs most: EUE (Δ=$(round(mc_eue - ns_eue, digits=2)) MWh)")

            # Q3: Storage reliability value
            if !isnan(ws_eue) && !isnothing(dec)
                stor_val = dec.storage_value_delta_mwh
                stor_pct = dec.storage_value_pct_of_ns
                println(io, @sprintf("Q3. Storage reliability value (M3-NS − M3-WS): %.2f MWh (%.1f%% reduction in EUE).",
                                      stor_val, stor_pct))
            end
        end

        # Q4: Storage value comparison across cases
        if length(decomp_rows) >= 2
            d1 = decomp_rows[1]; d2 = decomp_rows[2]
            println(io, @sprintf("\nQ4. Storage value larger in: %s (Δ=%.2f MWh) vs %s (Δ=%.2f MWh).",
                                  d1.storage_value_delta_mwh >= d2.storage_value_delta_mwh ? d1.case : d2.case,
                                  max(d1.storage_value_delta_mwh, d2.storage_value_delta_mwh),
                                  d1.storage_value_delta_mwh >= d2.storage_value_delta_mwh ? d2.case : d1.case,
                                  min(d1.storage_value_delta_mwh, d2.storage_value_delta_mwh)))
        end

        # Q5: Wind-heavy scarcity without storage
        base_ns_r = find_row(all_agg, "VRE120_base",     "MC-NoStorage")
        wind_ns_r = find_row(all_agg, "VRE120_wind_hvy", "MC-NoStorage")
        if !isnothing(base_ns_r) && !isnothing(wind_ns_r)
            base_eue = base_ns_r.eue_mwh; wind_eue = wind_ns_r.eue_mwh
            more_severe   = base_eue >= wind_eue ? "VRE120_base"     : "VRE120_wind_hvy"
            less_severe   = base_eue >= wind_eue ? "VRE120_wind_hvy" : "VRE120_base"
            more_eue      = max(base_eue, wind_eue)
            less_eue      = min(base_eue, wind_eue)
            println(io, @sprintf("\nQ5. More severe scarcity without storage: %s (MC-NS EUE=%.2f MWh) vs %s (%.2f MWh).",
                                  more_severe, more_eue, less_severe, less_eue))
        end

        # Q6: Paper story support
        all_match = all(begin
            mc_r = find_row(all_agg, c, "MC-NoStorage")
            ns_r = find_row(all_agg, c, "M3-NoStorage")
            !isnothing(mc_r) && !isnothing(ns_r) && abs(mc_r.eue_mwh - ns_r.eue_mwh) < 1.0
        end for c in cases if isdir(joinpath(data_root, c * "_nostorage")))

        println(io)
        println(io, "Q6. Paper story support:")
        if all_match
            println(io, "  YES — MC-NoStorage ≈ M3-NoStorage across all cases (EUE within 1 MWh).")
            println(io, "  Interpretation: classic hourly capacity adequacy is exact when no storage")
            println(io, "  is present (LP dispatch collapses to the same feasible set as MC).")
            println(io, "  Any discrepancy between M1/M3 and MC-NoStorage then traces entirely to")
            println(io, "  storage operation: LP foresight enables optimal pre-dispatch of storage")
            println(io, "  before shortage hours, while rule-based M1 cannot. This supports the")
            println(io, "  paper narrative that operation-aware modelling is needed only because")
            println(io, "  of storage (and VRE integration), not for thermal-only systems.")
        else
            println(io, "  PARTIAL — some cases show MC-NoStorage ≠ M3-NoStorage. Investigate")
            println(io, "  curtailment handling: if VRE can be curtailed optimally in LP but not")
            println(io, "  in MC, a mismatch is expected even without storage.")
        end
    end

    println()
    println("Saved: $sum_path")
    println()
    println("Next steps:")
    println("  Commit results/no_storage_comparison/ to the repository.")
    println("  Run HOPE-ED/UC on the _nostorage cases for full M4 comparison.")
end

main()
