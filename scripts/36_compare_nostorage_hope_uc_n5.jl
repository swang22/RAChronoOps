#!/usr/bin/env julia
# 36_compare_nostorage_hope_uc_n5.jl
#
# Four-model no-storage comparison for VRE120_base_nostorage, scenarios 1–5.
#
#   MC-NoStorage      — run_mc_no_storage (classical hourly capacity check)
#   M3-NoStorage      — run_m3_ed_dispatch (full-year ED LP, no storage)
#   HOPE-ED-NoStorage — HOPE ED LP metrics read from CSV (script 27 output)
#   HOPE-UC-NoStorage — HOPE UC MILP metrics read from CSV (script 27 output)
#
# Key questions:
#   1. Does HOPE-ED match MC and M3 exactly (as expected from Phase G result)?
#   2. Does HOPE-UC increase LOLH or EUE vs HOPE-ED in the no-storage case?
#   3. If UC changes metrics, is it EUE, LOLH, event count, or max shortfall?
#   4. How large is the UC effect without storage?
#   5. Does classic MC miss UC/ramping infeasibility in no-storage systems?
#   6. Should we scale to N=20?
#
# Prerequisites:
#   - scripts/33 has built VRE120_base_nostorage
#   - scripts/25 has exported HOPE cases for VRE120_base_nostorage s001–s005
#   - scripts/29 has run HOPE on those cases
#   - scripts/27 has collected results into <hope-metrics-csv>
#
# Usage:
#   julia --project=. scripts/36_compare_nostorage_hope_uc_n5.jl \
#     [--case VRE120_base_nostorage] \
#     [--scenario-subset 1,2,3,4,5] \
#     [--n-scenarios 20] \
#     [--seed 42] \
#     [--hope-metrics results/hope_nostorage_n5_pilot/hope_metrics_by_scenario.csv] \
#     [--out-dir results/nostorage_hope_uc_comparison/base_n5]

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
        model                        = model,
        case                         = case,
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

function scenario_rows_from_dispatch(model::String, case::String,
                                      results::Vector{DispatchResult})
    map(results) do r
        ls = r.load_shed
        durs = compute_shortage_events(ls)
        (
            model               = model,
            case                = case,
            scenario_id         = r.scenario_id,
            lolh                = compute_lolh(ls),
            eue_mwh             = compute_eue(ls),
            max_shortfall_mw    = maximum(ls),
            n_shortage_events   = length(durs),
            mean_shortage_duration_h = isempty(durs) ? 0.0 : mean(Float64.(durs)),
            runtime_s           = r.runtime_seconds,
        )
    end
end

# ── HOPE metrics reading ──────────────────────────────────────────────────────

"""
Parse scenario_id from HOPE case folder name.
  RAChronoOps_VRE120_base_nostorage_s003_ED → 3
"""
function parse_scenario_id(folder::String)::Int
    m = match(r"_s(\d{3})_", folder)
    isnothing(m) && return -1
    parse(Int, m.captures[1])
end

"""
Parse mode (ED or UC) from HOPE case folder name.
"""
function parse_mode(folder::String)::String
    endswith(uppercase(folder), "_UC") && return "UC"
    endswith(uppercase(folder), "_ED") && return "ED"
    return "UNKNOWN"
end

"""
Read HOPE per-scenario metrics CSV and return per-scenario rows for given
scenario IDs and mode, labeled with `model_label`.
"""
function read_hope_scenario_rows(metrics_csv::String, case::String,
                                  scenario_ids::Vector{Int}, mode::String,
                                  model_label::String)
    isfile(metrics_csv) || error("HOPE metrics CSV not found: $metrics_csv")
    df = CSV.read(metrics_csv, DataFrame)

    rows = NamedTuple[]
    for s_id in scenario_ids
        # Match folder name containing the scenario and mode
        folder_pattern = Regex("_s$(lpad(s_id, 3, '0'))_$(mode)\$", "i")
        sub = filter(r -> occursin(folder_pattern, r.case_folder), eachrow(df))
        isempty(sub) && continue
        r = first(sub)
        push!(rows, (
            model               = model_label,
            case                = case,
            scenario_id         = s_id,
            lolh                = Float64(r.lolh),
            eue_mwh             = Float64(r.eue_mwh),
            max_shortfall_mw    = Float64(r.max_shortfall_mw),
            n_shortage_events   = Float64(r.n_shortage_events),
            mean_shortage_duration_h = Float64(r.mean_shortage_duration_h),
            runtime_s           = Float64(r.runtime_s),
        ))
    end
    return rows
end

"""
Aggregate per-scenario rows into a MetricsResult-equivalent NamedTuple.
"""
function aggregate_scenario_rows(rows::Vector{<:NamedTuple},
                                  model::String, case::String,
                                  annual_load_mwh::Float64)
    isempty(rows) && error("No rows to aggregate for $model / $case")
    n = length(rows)
    lolh_v    = [r.lolh    for r in rows]
    eue_v     = [r.eue_mwh for r in rows]
    sf_v      = [r.max_shortfall_mw for r in rows]
    ev_v      = [r.n_shortage_events for r in rows]
    dur_v     = [r.mean_shortage_duration_h for r in rows]
    rt_v      = [r.runtime_s for r in rows]

    lolh_mean = mean(lolh_v)
    eue_mean  = mean(eue_v)
    neue      = annual_load_mwh > 0 ? eue_mean / annual_load_mwh * 1e6 : NaN
    cvar      = isempty(eue_v) ? NaN : begin
        α = 0.95; k = max(1, ceil(Int, (1-α)*n))
        mean(sort(eue_v, rev=true)[1:k])
    end
    p90 = quantile(eue_v, 0.90)
    p95 = quantile(eue_v, 0.95)
    p99 = quantile(eue_v, 0.99)
    total_rt  = sum(isnan(r) ? 0.0 : r for r in rt_v)

    (
        model                           = model,
        case                            = case,
        lolh                            = lolh_mean,
        lolp_percent                    = lolh_mean / 8760 * 100,
        lole_days                       = NaN,
        eue_mwh                         = eue_mean,
        neue_ppm                        = neue,
        cvar_eue_mwh                    = cvar,
        p90_eue_mwh                     = p90,
        p95_eue_mwh                     = p95,
        p99_eue_mwh                     = p99,
        n_shortage_events               = mean(ev_v),
        mean_shortage_duration_h        = mean(dur_v),
        max_shortage_duration_h         = NaN,
        p95_shortage_duration_h         = NaN,
        max_shortfall_mw                = maximum(sf_v),
        mean_shortfall_when_shedding_mw = NaN,
        lolh_ci95_halfwidth             = NaN,
        eue_ci95_halfwidth_mwh          = NaN,
        total_runtime_s                 = total_rt,
        mean_runtime_s                  = total_rt / max(1, n),
    )
end

# ── Error tables ─────────────────────────────────────────────────────────────

function build_error_table(scen_rows::Vector{<:NamedTuple},
                            ref_model::String, test_model::String,
                            case::String)
    ref  = filter(r -> r.model == ref_model  && r.case == case, scen_rows)
    test = filter(r -> r.model == test_model && r.case == case, scen_rows)
    rows = NamedTuple[]
    for (rr, tr) in zip(sort(ref, by=r->r.scenario_id), sort(test, by=r->r.scenario_id))
        rr.scenario_id == tr.scenario_id || continue
        push!(rows, (
            case              = case,
            scenario_id       = rr.scenario_id,
            ref_model         = ref_model,
            test_model        = test_model,
            ref_eue_mwh       = rr.eue_mwh,
            test_eue_mwh      = tr.eue_mwh,
            delta_eue_mwh     = tr.eue_mwh - rr.eue_mwh,
            ref_lolh          = rr.lolh,
            test_lolh         = tr.lolh,
            delta_lolh        = tr.lolh - rr.lolh,
        ))
    end
    return rows
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    case      = get(kw, "case",      "VRE120_base_nostorage")
    subset_s  = get(kw, "scenario-subset", "1,2,3,4,5")
    n_scen    = parse(Int, get(kw, "n-scenarios", "20"))
    seed      = parse(Int, get(kw, "seed", "42"))
    hope_csv  = get(kw, "hope-metrics",
                    joinpath(@__DIR__, "..", "results", "hope_nostorage_n5_pilot",
                             "hope_metrics_by_scenario.csv"))
    out_dir   = get(kw, "out-dir",
                    joinpath(@__DIR__, "..", "results", "nostorage_hope_uc_comparison", "base_n5"))
    hope_csv  = abspath(hope_csv)
    out_dir   = abspath(out_dir)

    scen_ids  = parse.(Int, String.(strip.(split(subset_s, ","))))
    n_sub     = length(scen_ids)
    data_root = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))

    println("=" ^ 70)
    println("36_compare_nostorage_hope_uc_n5.jl")
    println("Date: ", Dates.now())
    println("Case: $case")
    println("Scenarios: ", join(scen_ids, ", "), "  (full set n=$n_scen, seed=$seed)")
    println("HOPE metrics: ", isfile(hope_csv) ? "found" : "NOT FOUND — $(hope_csv)")
    println("=" ^ 70)

    mkpath(out_dir)

    # ── Load system and generate scenarios ────────────────────────────────────
    case_dir  = joinpath(data_root, case)
    isdir(case_dir) || error("Case directory not found: $case_dir")
    sys = load_system_data(case_dir)
    cfg = SimConfig(n_scenarios=n_scen, seed=seed)

    println("\nGenerating ScenarioSet (n=$n_scen, seed=$seed) …")
    full_scen = generate_scenarios(sys, cfg)

    # Extract subset availability matrix for the selected scenarios
    sub_avail = full_scen.availability[scen_ids, :, :]   # n_sub × n_therm × T

    annual_load = sum(sys.load_mw)

    # ── Run inline RAChronoOps models (subset scenarios only) ─────────────────
    all_agg  = NamedTuple[]
    all_scen = NamedTuple[]

    println("\nInline models:")

    res_mc, rt_mc = run_and_measure("run_mc_no_storage") do
        run_mc_no_storage(sys, sub_avail, cfg)
    end
    push!(all_agg, full_metrics_row("MC-NoStorage",  case, res_mc,  sys, cfg, rt_mc))
    append!(all_scen, scenario_rows_from_dispatch("MC-NoStorage",  case, res_mc))

    res_m3, rt_m3 = run_and_measure("run_m3_ed_dispatch") do
        run_m3_ed_dispatch(sys, sub_avail, cfg)
    end
    push!(all_agg, full_metrics_row("M3-NoStorage",  case, res_m3,  sys, cfg, rt_m3))
    append!(all_scen, scenario_rows_from_dispatch("M3-NoStorage",  case, res_m3))

    # ── Read HOPE metrics from CSV ────────────────────────────────────────────
    println("\nHOPE metrics:")
    if isfile(hope_csv)
        for (mode, label) in [("ED", "HOPE-ED-NoStorage"), ("UC", "HOPE-UC-NoStorage")]
            h_scen = read_hope_scenario_rows(hope_csv, case, scen_ids, mode, label)
            if isempty(h_scen)
                println("  $label — no rows found in CSV (check case folder names)")
            else
                println("  $label — $(length(h_scen)) scenarios loaded")
                append!(all_scen, h_scen)
                push!(all_agg, aggregate_scenario_rows(h_scen, label, case, annual_load))
            end
        end
    else
        @warn "HOPE metrics CSV not found: $hope_csv\nSkipping HOPE rows — run scripts 29 and 27 first."
    end

    # ── Save per-scenario CSV ─────────────────────────────────────────────────
    scen_df = DataFrame(all_scen)
    CSV.write(joinpath(out_dir, "all_model_metrics_by_scenario.csv"), scen_df)

    agg_df = DataFrame(all_agg)
    CSV.write(joinpath(out_dir, "all_model_aggregate_metrics.csv"), agg_df)

    # ── Error tables ──────────────────────────────────────────────────────────
    # Compare each model vs MC-NoStorage and vs M3-NoStorage
    err_vs_mc = NamedTuple[]
    err_vs_m3 = NamedTuple[]
    for test_model in ["M3-NoStorage", "HOPE-ED-NoStorage", "HOPE-UC-NoStorage"]
        append!(err_vs_mc, build_error_table(all_scen, "MC-NoStorage", test_model, case))
        append!(err_vs_m3, build_error_table(all_scen, "M3-NoStorage", test_model, case))
    end
    CSV.write(joinpath(out_dir, "errors_vs_mc_nostorage.csv"), DataFrame(err_vs_mc))
    CSV.write(joinpath(out_dir, "errors_vs_m3_nostorage.csv"), DataFrame(err_vs_m3))

    println("\nSaved:")
    println("  all_model_aggregate_metrics.csv")
    println("  all_model_metrics_by_scenario.csv")
    println("  errors_vs_mc_nostorage.csv")
    println("  errors_vs_m3_nostorage.csv")

    # ── Console table ─────────────────────────────────────────────────────────
    println()
    println("=" ^ 70)
    println("Aggregate results (N=$n_sub scenarios, seed=$seed):")
    println("=" ^ 70)
    println(@sprintf("%-25s  %8s  %11s  %11s  %8s",
                     "Model", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)", "RT (s)"))
    println("-" ^ 70)
    for r in all_agg
        @printf("%-25s  %8.1f  %11.2f  %11.2f  %8.1f\n",
                r.model, r.lolh, r.eue_mwh, r.cvar_eue_mwh, r.total_runtime_s)
    end

    # ── Per-scenario error tables (console) ───────────────────────────────────
    println()
    println("Per-scenario EUE deltas vs MC-NoStorage:")
    println(@sprintf("  %-25s  %-4s  %-10s  %-10s  %-10s",
                     "Test model", "s_id", "Test EUE", "Ref EUE", "Δ EUE"))
    for r in err_vs_mc
        abs(r.delta_eue_mwh) > 0.1 &&
            @printf("  %-25s  s%03d  %10.2f  %10.2f  %+10.2f\n",
                    r.test_model, r.scenario_id,
                    r.test_eue_mwh, r.ref_eue_mwh, r.delta_eue_mwh)
    end
    all_zero_mc = all(abs(r.delta_eue_mwh) <= 0.1 for r in err_vs_mc)
    all_zero_mc && println("  (all |Δ| ≤ 0.1 MWh — perfect match across all scenarios and models)")

    # ── Write summary.txt ─────────────────────────────────────────────────────
    sum_path = joinpath(out_dir, "summary.txt")
    open(sum_path, "w") do io
        println(io, "No-Storage HOPE-UC Comparison: MC / M3 / HOPE-ED / HOPE-UC")
        println(io, "Generated: ", Dates.now())
        println(io, "Case: $case  |  Scenarios: $(join(scen_ids, ","))  |  seed=$seed")
        println(io)

        println(io, "─"^70)
        println(io, "Aggregate metrics (mean over $(n_sub) scenarios)")
        println(io, "─"^70)
        println(io, @sprintf("%-25s  %8s  %11s  %11s  %11s  %8s",
                              "Model", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)", "p95 (MWh)", "RT (s)"))
        println(io, "-"^80)
        for r in all_agg
            println(io, @sprintf("%-25s  %8.1f  %11.2f  %11.2f  %11.2f  %8.1f",
                                  r.model, r.lolh, r.eue_mwh, r.cvar_eue_mwh,
                                  r.p95_eue_mwh, r.total_runtime_s))
        end
        println(io)

        println(io, "─"^70)
        println(io, "Per-scenario EUE (MWh)")
        println(io, "─"^70)
        models_in_table = unique([r.model for r in all_scen])
        header = @sprintf("%-4s", "s_id")
        for m in models_in_table
            header *= @sprintf("  %-20s", m)
        end
        println(io, header)
        println(io, "-"^(6 + 22*length(models_in_table)))
        for s_id in sort(scen_ids)
            row_str = @sprintf("s%03d", s_id)
            for m in models_in_table
                r = findfirst(x -> x.model == m && x.scenario_id == s_id, all_scen)
                val = isnothing(r) ? NaN : all_scen[r].eue_mwh
                row_str *= @sprintf("  %20.2f", val)
            end
            println(io, row_str)
        end
        println(io)

        println(io, "─"^70)
        println(io, "Q&A")
        println(io, "─"^70)

        # Pull aggregate rows by model
        get_agg = m -> begin
            idx = findfirst(r -> r.model == m, all_agg)
            isnothing(idx) ? nothing : all_agg[idx]
        end
        mc_a  = get_agg("MC-NoStorage")
        m3_a  = get_agg("M3-NoStorage")
        hed_a = get_agg("HOPE-ED-NoStorage")
        huc_a = get_agg("HOPE-UC-NoStorage")

        # Q1: Does HOPE-ED match MC and M3?
        println(io, "\nQ1. Does HOPE-ED-NoStorage match MC-NoStorage and M3-NoStorage?")
        if !isnothing(mc_a) && !isnothing(hed_a)
            d_mc  = abs(hed_a.eue_mwh - mc_a.eue_mwh)
            match = d_mc < 1.0
            println(io, @sprintf("  HOPE-ED vs MC:  ΔEUE = %.2f MWh,  ΔLOLH = %.1f h",
                                  hed_a.eue_mwh - mc_a.eue_mwh, hed_a.lolh - mc_a.lolh))
            if !isnothing(m3_a)
                println(io, @sprintf("  HOPE-ED vs M3:  ΔEUE = %.2f MWh,  ΔLOLH = %.1f h",
                                      hed_a.eue_mwh - m3_a.eue_mwh, hed_a.lolh - m3_a.lolh))
            end
            if match
                println(io, "  YES — HOPE-ED matches MC and M3 within 1 MWh.")
                println(io, "  Classic hourly capacity adequacy is exact in the no-storage case.")
            else
                println(io, "  NO — HOPE-ED differs from MC/M3. Investigate ramp constraints in HOPE-ED.")
            end
        else
            println(io, "  HOPE-ED data not available.")
        end

        # Q2: Does HOPE-UC increase LOLH or EUE vs HOPE-ED?
        println(io, "\nQ2. Does HOPE-UC-NoStorage increase LOLH or EUE relative to HOPE-ED?")
        if !isnothing(hed_a) && !isnothing(huc_a)
            d_eue  = huc_a.eue_mwh - hed_a.eue_mwh
            d_lolh = huc_a.lolh     - hed_a.lolh
            d_cvar = huc_a.cvar_eue_mwh - hed_a.cvar_eue_mwh
            println(io, @sprintf("  HOPE-UC vs HOPE-ED:  ΔEUE = %.2f MWh,  ΔLOLH = %.1f h,  ΔCVaR = %.2f MWh",
                                  d_eue, d_lolh, d_cvar))
            if abs(d_eue) < 1.0 && abs(d_lolh) < 0.5
                println(io, "  NO — HOPE-UC closely matches HOPE-ED (ΔEUE < 1 MWh, ΔLOLH < 0.5 h).")
                println(io, "  With no storage, LP and MILP see the same feasible set (no intertemporal resource).")
                println(io, "  UC constraints may redistribute shortage hours but do not add net EUE.")
            else
                dominant = abs(d_eue) >= abs(d_lolh)*100 ? "EUE" : "LOLH"
                println(io, "  YES — HOPE-UC increases $dominant vs HOPE-ED.")
            end
        else
            println(io, "  HOPE-ED or HOPE-UC data not available.")
        end

        # Q3: If UC changes metrics, which metric differs most?
        println(io, "\nQ3. Which metric differs most between HOPE-UC and HOPE-ED?")
        if !isnothing(hed_a) && !isnothing(huc_a)
            d_eue  = abs(huc_a.eue_mwh - hed_a.eue_mwh)
            d_lolh = abs(huc_a.lolh     - hed_a.lolh)
            d_cvar = abs(huc_a.cvar_eue_mwh - hed_a.cvar_eue_mwh)
            d_sf   = abs(huc_a.max_shortfall_mw - hed_a.max_shortfall_mw)
            vals = [("EUE", d_eue), ("LOLH", d_lolh*100), ("CVaR-EUE", d_cvar), ("max shortfall", d_sf)]
            dominant = sort(vals, by=x->x[2], rev=true)[1][1]
            println(io, @sprintf("  EUE Δ=%.2f MWh | LOLH Δ=%.1f h | CVaR Δ=%.2f MWh | max-shortfall Δ=%.1f MW",
                                  d_eue, d_lolh, d_cvar, d_sf))
            println(io, "  Dominant metric: $dominant")
        else
            println(io, "  HOPE data not available.")
        end

        # Q4: How large is the UC effect?
        println(io, "\nQ4. How large is the UC effect without storage?")
        if !isnothing(hed_a) && !isnothing(huc_a)
            d_eue  = huc_a.eue_mwh - hed_a.eue_mwh
            d_lolh = huc_a.lolh     - hed_a.lolh
            if abs(d_eue) < 1.0
                println(io, @sprintf("  Small — ΔEUE = %.2f MWh (%.2f%% of HOPE-ED EUE), ΔLOLH = %.1f h.",
                                      d_eue,
                                      hed_a.eue_mwh > 0 ? d_eue / hed_a.eue_mwh * 100 : 0.0,
                                      d_lolh))
                println(io, "  UC constraints add negligible EUE when storage is absent.")
            else
                println(io, @sprintf("  Significant — ΔEUE = %.2f MWh (%.1f%%), ΔLOLH = %.1f h.",
                                      d_eue,
                                      hed_a.eue_mwh > 0 ? d_eue / hed_a.eue_mwh * 100 : 0.0,
                                      d_lolh))
                println(io, "  UC ramp/minimum-stable-generation constraints affect dispatch even without storage.")
            end
        else
            println(io, "  HOPE data not available.")
        end

        # Q5: Does classic MC miss UC/ramping infeasibility in no-storage systems?
        println(io, "\nQ5. Does classic MC miss UC/ramping infeasibility in no-storage systems?")
        if !isnothing(mc_a) && !isnothing(huc_a)
            d_eue  = huc_a.eue_mwh - mc_a.eue_mwh
            d_lolh = huc_a.lolh     - mc_a.lolh
            if abs(d_eue) < 1.0
                println(io, @sprintf("  NO — MC-NoStorage ≈ HOPE-UC-NoStorage (ΔEUE=%.2f MWh, ΔLOLH=%.1f h).", d_eue, d_lolh))
                println(io, "  Classic MC does not miss any EUE from UC/ramping constraints in this system.")
                println(io, "  Implication: hourly capacity adequacy is a valid baseline for no-storage RA.")
            else
                println(io, @sprintf("  YES — HOPE-UC-NoStorage EUE is %.2f MWh higher than MC (ΔLOLH=%.1f h).", d_eue, d_lolh))
                println(io, "  UC/ramp constraints create shortages that classic MC does not detect.")
            end
        else
            println(io, "  Data not available.")
        end

        # Q6: Should we scale to N=20?
        println(io, "\nQ6. Should we scale the no-storage HOPE-UC case to N=20?")
        if !isnothing(hed_a) && !isnothing(huc_a)
            d_eue = abs(huc_a.eue_mwh - hed_a.eue_mwh)
            rt_uc = huc_a.total_runtime_s
            proj_n20 = rt_uc / n_sub * 20
            println(io, @sprintf("  HOPE-UC N=%d total runtime: %.0f s.  Projected N=20: %.0f s (%.1f h).",
                                  n_sub, rt_uc, proj_n20, proj_n20 / 3600))
            if d_eue < 1.0
                println(io, "  ΔEUE at N=$n_sub is < 1 MWh — UC and ED are equivalent without storage.")
                println(io, "  Scaling to N=20 is LOW PRIORITY unless startup costs or Pmin are varied.")
            else
                println(io, "  ΔEUE at N=$n_sub is significant — scaling to N=20 would confirm the UC effect.")
                if proj_n20 < 7200
                    println(io, "  Projected N=20 runtime is manageable on this machine.")
                else
                    println(io, "  Projected N=20 runtime requires a compute node.")
                end
            end
        else
            println(io, "  HOPE data not available.")
        end
    end

    println("\nSaved: $sum_path")
end

main()
