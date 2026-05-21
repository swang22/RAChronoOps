#!/usr/bin/env julia
# 38_compare_m1d_storage_heuristics.jl
#
# Compare storage dispatch heuristics including M1d (risk-hour allocation).
#
#   M1c          — emergency-only heuristic (system-surplus charging)
#   M1d_earliest — M1d with earliest_first allocation
#   M1d_largest  — M1d with largest_first allocation
#   M2           — event-window LP (risk_margin_mw=1000, window_buffer_hours=48)
#   M3           — full-year ED LP (Gurobi benchmark)
#
# Key questions:
#   Q1. Does M1d_earliest match M1c EUE (same rule, different implementation path)?
#   Q2. Does M1d_largest reduce CVaR/p95 vs M1d_earliest (tail risk concentration)?
#   Q3. How does M1d compare to M2 and M3 in EUE and LOLH accuracy?
#   Q4. What is the runtime overhead of M1d vs M1c?
#   Q5. Are the findings consistent across VRE profiles (base vs wind-heavy)?
#
# Usage:
#   julia --project=. scripts/38_compare_m1d_storage_heuristics.jl \
#     [--cases VRE120_base,VRE120_wind_hvy] \
#     [--n-scenarios 20] \
#     [--seed 42] \
#     [--m2-risk 1000] \
#     [--m2-buf 48] \
#     [--m1d-lookback 72] \
#     [--m1d-gap 0] \
#     [--out-dir results/m1d_storage_heuristic_comparison]

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

function build_error_table(scen_rows, ref_model::String, test_models::Vector{String}, case::String)
    ref = filter(r -> r.model == ref_model && r.case == case, scen_rows)
    rows = NamedTuple[]
    for tm in test_models
        test = filter(r -> r.model == tm && r.case == case, scen_rows)
        for (rr, tr) in zip(sort(ref, by=r->r.scenario_id), sort(test, by=r->r.scenario_id))
            rr.scenario_id == tr.scenario_id || continue
            push!(rows, (
                case          = case,
                scenario_id   = rr.scenario_id,
                ref_model     = ref_model,
                test_model    = tm,
                ref_eue_mwh   = rr.eue_mwh,
                test_eue_mwh  = tr.eue_mwh,
                delta_eue_mwh = tr.eue_mwh - rr.eue_mwh,
                ref_lolh      = rr.lolh,
                test_lolh     = tr.lolh,
                delta_lolh    = tr.lolh - rr.lolh,
            ))
        end
    end
    return rows
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    cases_s      = get(kw, "cases",        "VRE120_base,VRE120_wind_hvy")
    n_scen       = parse(Int,     get(kw, "n-scenarios", "20"))
    seed         = parse(Int,     get(kw, "seed",        "42"))
    m2_risk      = parse(Float64, get(kw, "m2-risk",     "1000"))
    m2_buf       = parse(Int,     get(kw, "m2-buf",      "48"))
    m1d_lookback = parse(Int,     get(kw, "m1d-lookback","72"))
    m1d_gap      = parse(Int,     get(kw, "m1d-gap",     "0"))
    out_dir      = abspath(get(kw, "out-dir",
                   joinpath(@__DIR__, "..", "results", "m1d_storage_heuristic_comparison")))

    cases     = String.(strip.(split(cases_s, ",")))
    data_root = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))

    println("=" ^ 70)
    println("38_compare_m1d_storage_heuristics.jl")
    println("Date: ", Dates.now())
    println("Cases: ", join(cases, ", "))
    println("N=$n_scen, seed=$seed")
    println(@sprintf("M2: risk_margin_mw=%.0f, window_buffer_hours=%d", m2_risk, m2_buf))
    println("M1d: lookback=$(m1d_lookback)h, gap=$(m1d_gap)h")
    println("Output: ", out_dir)
    println("=" ^ 70)

    mkpath(out_dir)

    all_agg_rows  = NamedTuple[]
    all_scen_rows = NamedTuple[]
    all_err_rows  = NamedTuple[]

    for case in cases
        println("\n── Case: $case ──────────────────────────────────────────────")

        case_dir = joinpath(data_root, case)
        isdir(case_dir) || error("Case directory not found: $case_dir")

        sys = load_system_data(case_dir)
        base_cfg = SimConfig(n_scenarios=n_scen, seed=seed)
        m2_cfg   = SimConfig(n_scenarios=n_scen, seed=seed,
                             risk_margin_mw=m2_risk, window_buffer_hours=m2_buf)
        m1d_ef_cfg = SimConfig(n_scenarios=n_scen, seed=seed,
                               risk_allocation_mode="earliest_first",
                               event_charge_lookback_hours=m1d_lookback,
                               risk_event_gap_hours=m1d_gap)
        m1d_lf_cfg = SimConfig(n_scenarios=n_scen, seed=seed,
                               risk_allocation_mode="largest_first",
                               event_charge_lookback_hours=m1d_lookback,
                               risk_event_gap_hours=m1d_gap)

        println("\nGenerating ScenarioSet (n=$n_scen, seed=$seed) …")
        scen = generate_scenarios(sys, base_cfg)

        println("\nRunning models:")

        res_m1c, rt_m1c = run_and_measure("M1c  (emergency-only)") do
            run_m1c_emergency_only(sys, scen, base_cfg)
        end
        push!(all_agg_rows, full_metrics_row("M1c", case, res_m1c, sys, base_cfg, rt_m1c))
        append!(all_scen_rows, scenario_rows_from_dispatch("M1c", case, res_m1c))

        res_m1d_ef, rt_m1d_ef = run_and_measure("M1d_earliest (risk-hour, earliest_first)") do
            run_m1d_risk_hour_allocation(sys, scen, m1d_ef_cfg)
        end
        push!(all_agg_rows, full_metrics_row("M1d_earliest", case, res_m1d_ef, sys, m1d_ef_cfg, rt_m1d_ef))
        append!(all_scen_rows, scenario_rows_from_dispatch("M1d_earliest", case, res_m1d_ef))

        res_m1d_lf, rt_m1d_lf = run_and_measure("M1d_largest  (risk-hour, largest_first)") do
            run_m1d_risk_hour_allocation(sys, scen, m1d_lf_cfg)
        end
        push!(all_agg_rows, full_metrics_row("M1d_largest", case, res_m1d_lf, sys, m1d_lf_cfg, rt_m1d_lf))
        append!(all_scen_rows, scenario_rows_from_dispatch("M1d_largest", case, res_m1d_lf))

        res_m2, rt_m2 = run_and_measure("M2   (event-window LP)") do
            first(run_m2_with_diagnostics(sys, scen.availability, m2_cfg))
        end
        push!(all_agg_rows, full_metrics_row("M2", case, res_m2, sys, m2_cfg, rt_m2))
        append!(all_scen_rows, scenario_rows_from_dispatch("M2", case, res_m2))

        res_m3, rt_m3 = run_and_measure("M3   (full-year ED LP)") do
            run_m3_ed_dispatch(sys, scen.availability, base_cfg)
        end
        push!(all_agg_rows, full_metrics_row("M3", case, res_m3, sys, base_cfg, rt_m3))
        append!(all_scen_rows, scenario_rows_from_dispatch("M3", case, res_m3))

        # ── Error tables vs M3 ────────────────────────────────────────────────
        case_err = build_error_table(all_scen_rows,
                                     "M3",
                                     ["M1c", "M1d_earliest", "M1d_largest", "M2"],
                                     case)
        append!(all_err_rows, case_err)
    end

    # ── Save CSVs ─────────────────────────────────────────────────────────────
    agg_df  = DataFrame(all_agg_rows)
    scen_df = DataFrame(all_scen_rows)
    err_df  = DataFrame(all_err_rows)

    CSV.write(joinpath(out_dir, "m1d_aggregate_metrics.csv"),  agg_df)
    CSV.write(joinpath(out_dir, "m1d_metrics_by_scenario.csv"), scen_df)
    CSV.write(joinpath(out_dir, "m1d_errors_vs_m3.csv"),       err_df)

    # ── Summary ───────────────────────────────────────────────────────────────
    summary_path = joinpath(out_dir, "summary.txt")
    open(summary_path, "w") do io
        write_summary(io, all_agg_rows, all_scen_rows, cases, n_scen, seed,
                      m2_risk, m2_buf, m1d_lookback, m1d_gap)
    end

    println("\nOutput written to: ", out_dir)
    println("  m1d_aggregate_metrics.csv")
    println("  m1d_metrics_by_scenario.csv")
    println("  m1d_errors_vs_m3.csv")
    println("  summary.txt")
end

# ── Summary writer ────────────────────────────────────────────────────────────

function write_summary(io, agg_rows, scen_rows, cases, n_scen, seed,
                       m2_risk, m2_buf, m1d_lookback, m1d_gap)
    println(io, "M1d Risk-Hour Allocation: Heuristic Comparison")
    println(io, "Generated: ", Dates.now())
    println(io, "Cases: ", join(cases, ", "), "  |  N=$n_scen, seed=$seed")
    println(io, @sprintf("M1d config: lookback=%dh, gap=%dh", m1d_lookback, m1d_gap))
    println(io, @sprintf("M2 config: risk_margin_mw=%.0f, window_buffer_hours=%d",
                         m2_risk, m2_buf))

    model_order = ["M1c", "M1d_earliest", "M1d_largest", "M2", "M3"]

    for case in cases
        println(io, "\n", "─"^70)
        println(io, "Case: $case")
        println(io, "─"^70)
        println(io, @sprintf("%-16s  %8s  %12s  %12s  %12s  %9s",
                             "Model", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)",
                             "p95 (MWh)", "RT (s)"))
        println(io, "-"^70)

        for model in model_order
            row = findfirst(r -> r.model == model && r.case == case, agg_rows)
            isnothing(row) && continue
            r = agg_rows[row]
            println(io, @sprintf("%-16s  %8.1f  %12.2f  %12.2f  %12.2f  %9.1f",
                                 model, r.lolh, r.eue_mwh, r.cvar_eue_mwh,
                                 r.p95_eue_mwh, r.total_runtime_s))
        end

        # ── per-scenario EUE table ─────────────────────────────────────────────
        println(io, "\nPer-scenario EUE (MWh):")
        case_scen = filter(r -> r.case == case, scen_rows)
        m3_rows   = sort(filter(r -> r.model == "M3", case_scen), by=r->r.scenario_id)
        isempty(m3_rows) && continue

        hdr = @sprintf("%-6s", "s_id")
        for model in model_order
            hdr *= @sprintf("  %-20s", model)
        end
        println(io, hdr)
        println(io, "-"^(6 + length(model_order)*22))

        for m3r in m3_rows
            sid = m3r.scenario_id
            line = @sprintf("s%03d  ", sid)
            for model in model_order
                sub = filter(r -> r.model == model && r.scenario_id == sid, case_scen)
                if isempty(sub)
                    line *= @sprintf("  %20s", "—")
                else
                    line *= @sprintf("  %20.2f", first(sub).eue_mwh)
                end
            end
            println(io, line)
        end

        # ── Q&A ───────────────────────────────────────────────────────────────
        println(io, "\n", "─"^70)
        println(io, "Q&A")
        println(io, "─"^70)

        m3_agg  = filter(r -> r.model == "M3"           && r.case == case, agg_rows)
        ef_agg  = filter(r -> r.model == "M1d_earliest" && r.case == case, agg_rows)
        lf_agg  = filter(r -> r.model == "M1d_largest"  && r.case == case, agg_rows)
        m1c_agg = filter(r -> r.model == "M1c"          && r.case == case, agg_rows)
        m2_agg  = filter(r -> r.model == "M2"           && r.case == case, agg_rows)

        if !isempty(m3_agg) && !isempty(ef_agg)
            m3r = first(m3_agg); efr = first(ef_agg)
            delta_eue  = efr.eue_mwh - m3r.eue_mwh
            delta_lolh = efr.lolh   - m3r.lolh
            println(io, "\nQ1. Does M1d_earliest match M1c EUE and M3 EUE?")
            if !isempty(m1c_agg)
                m1cr = first(m1c_agg)
                d_m1c = efr.eue_mwh - m1cr.eue_mwh
                println(io, @sprintf("  M1d_earliest vs M1c:  ΔEUE = %.2f MWh,  ΔLOLH = %.1f h",
                                     d_m1c, efr.lolh - m1cr.lolh))
            end
            println(io, @sprintf("  M1d_earliest vs M3:   ΔEUE = %.2f MWh,  ΔLOLH = %.1f h",
                                 delta_eue, delta_lolh))
            close = abs(delta_eue) < 5.0
            println(io, "  ", close ? "YES" : "DIVERGES",
                    " — |ΔEUE| = $(round(abs(delta_eue), digits=2)) MWh vs M3.")
        end

        if !isempty(m3_agg) && !isempty(ef_agg) && !isempty(lf_agg)
            efr = first(ef_agg); lfr = first(lf_agg); m3r = first(m3_agg)
            println(io, "\nQ2. Does M1d_largest reduce CVaR/p95 vs M1d_earliest?")
            println(io, @sprintf("  M1d_earliest:  CVaR = %.2f MWh,  p95 = %.2f MWh",
                                 efr.cvar_eue_mwh, efr.p95_eue_mwh))
            println(io, @sprintf("  M1d_largest:   CVaR = %.2f MWh,  p95 = %.2f MWh",
                                 lfr.cvar_eue_mwh, lfr.p95_eue_mwh))
            if lfr.cvar_eue_mwh <= efr.cvar_eue_mwh + 1e-3
                println(io, "  YES — largest_first reduces CVaR (concentrates discharge on worst hours).")
            else
                println(io, "  NO — largest_first does not reduce CVaR in this case.")
            end
            println(io, @sprintf("  M3 reference:  CVaR = %.2f MWh,  p95 = %.2f MWh",
                                 m3r.cvar_eue_mwh, m3r.p95_eue_mwh))
        end

        if !isempty(m3_agg) && !isempty(ef_agg) && !isempty(m2_agg)
            m3r = first(m3_agg); efr = first(ef_agg); m2r = first(m2_agg)
            println(io, "\nQ3. How does M1d compare to M2 and M3 in EUE accuracy?")
            println(io, @sprintf("  M1d_earliest vs M3:  ΔEUE = %+.2f MWh,  ΔLOLH = %+.1f h",
                                 efr.eue_mwh - m3r.eue_mwh, efr.lolh - m3r.lolh))
            println(io, @sprintf("  M2           vs M3:  ΔEUE = %+.2f MWh,  ΔLOLH = %+.1f h",
                                 m2r.eue_mwh - m3r.eue_mwh, m2r.lolh - m3r.lolh))
        end

        if !isempty(m1c_agg) && !isempty(ef_agg)
            m1cr = first(m1c_agg); efr = first(ef_agg)
            println(io, "\nQ4. What is the runtime overhead of M1d vs M1c?")
            ratio = m1cr.total_runtime_s > 0 ?
                    efr.total_runtime_s / m1cr.total_runtime_s : NaN
            println(io, @sprintf("  M1c:          %.1f s", m1cr.total_runtime_s))
            println(io, @sprintf("  M1d_earliest: %.1f s  (%.1f× M1c)", efr.total_runtime_s, ratio))
        end
    end

    # ── Cross-case consistency ─────────────────────────────────────────────────
    if length(cases) >= 2
        println(io, "\n", "─"^70)
        println(io, "Q5. Are findings consistent across VRE profiles?")
        println(io, "─"^70)
        for case in cases
            m3r  = filter(r -> r.model == "M3"           && r.case == case, agg_rows)
            efr  = filter(r -> r.model == "M1d_earliest" && r.case == case, agg_rows)
            m2r  = filter(r -> r.model == "M2"           && r.case == case, agg_rows)
            isempty(m3r) || isempty(efr) || isempty(m2r) && continue
            m3v = first(m3r); efv = first(efr); m2v = first(m2r)
            println(io, @sprintf("  %s:  M1d ΔEUE = %+.2f MWh,  M2 ΔEUE = %+.2f MWh",
                                 case,
                                 efv.eue_mwh - m3v.eue_mwh,
                                 m2v.eue_mwh - m3v.eue_mwh))
        end
    end
end

main()
