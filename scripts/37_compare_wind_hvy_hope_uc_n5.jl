#!/usr/bin/env julia
# 37_compare_wind_hvy_hope_uc_n5.jl
#
# Five-model storage-enabled UC comparison for VRE120_wind_hvy, scenarios 1–5.
#
#   M1c     — run_m1c_emergency_only (classical, no LP, no storage optimisation)
#   M2      — run_m2_with_diagnostics (risk_margin_mw=1000, window_buffer_hours=48)
#   M3      — run_m3_ed_dispatch (full-year ED LP with storage)
#   HOPE-ED — HOPE ED LP metrics read from CSV (script 27 output)
#   HOPE-UC — HOPE UC MILP metrics read from CSV (script 27 output)
#
# Key questions:
#   Q1. Does HOPE-ED match M3 (ED LP equivalence with storage)?
#   Q2. Does HOPE-UC increase EUE vs HOPE-ED (commitment cycling penalty)?
#   Q3. Does HOPE-UC change LOLH or shortage event count vs HOPE-ED?
#   Q4. How do M1c/M2 compare to HOPE-UC (the most detailed model)?
#   Q5. Is the UC reliability effect larger with storage than in Phase H (no storage)?
#   Q6. Does UC cause additional VRE curtailment in surplus hours?
#   Q7. Should we scale to N=20?
#
# Prerequisites:
#   - scripts/25 has exported HOPE cases for VRE120_wind_hvy s001–s005 (ED + UC)
#   - scripts/29 has run HOPE on those cases
#   - scripts/27 has collected results into <hope-metrics-csv>
#
# Usage:
#   julia --project=. scripts/37_compare_wind_hvy_hope_uc_n5.jl \
#     [--case VRE120_wind_hvy] \
#     [--scenario-subset 1,2,3,4,5] \
#     [--n-scenarios 20] \
#     [--seed 42] \
#     [--m2-risk 1000] \
#     [--m2-buf 48] \
#     [--hope-metrics results/hope_wind_hvy_n5_pilot/hope_metrics_by_scenario.csv] \
#     [--out-dir results/wind_hvy_hope_uc_comparison/n5]

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
Aggregate per-scenario rows into a summary NamedTuple matching full_metrics_row schema.
"""
function aggregate_scenario_rows(rows::Vector{<:NamedTuple},
                                  model::String, case::String,
                                  annual_load_mwh::Float64)
    isempty(rows) && error("No rows to aggregate for $model / $case")
    n = length(rows)
    lolh_v = [r.lolh    for r in rows]
    eue_v  = [r.eue_mwh for r in rows]
    sf_v   = [r.max_shortfall_mw for r in rows]
    ev_v   = [r.n_shortage_events for r in rows]
    dur_v  = [r.mean_shortage_duration_h for r in rows]
    rt_v   = [r.runtime_s for r in rows]

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
    total_rt = sum(isnan(r) ? 0.0 : r for r in rt_v)

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
            case          = case,
            scenario_id   = rr.scenario_id,
            ref_model     = ref_model,
            test_model    = test_model,
            ref_eue_mwh   = rr.eue_mwh,
            test_eue_mwh  = tr.eue_mwh,
            delta_eue_mwh = tr.eue_mwh - rr.eue_mwh,
            ref_lolh      = rr.lolh,
            test_lolh     = tr.lolh,
            delta_lolh    = tr.lolh - rr.lolh,
        ))
    end
    return rows
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    case     = get(kw, "case",      "VRE120_wind_hvy")
    subset_s = get(kw, "scenario-subset", "1,2,3,4,5")
    n_scen   = parse(Int,     get(kw, "n-scenarios", "20"))
    seed     = parse(Int,     get(kw, "seed",        "42"))
    m2_risk  = parse(Float64, get(kw, "m2-risk",     "1000"))
    m2_buf   = parse(Int,     get(kw, "m2-buf",      "48"))
    hope_csv = get(kw, "hope-metrics",
                   joinpath(@__DIR__, "..", "results", "hope_wind_hvy_n5_pilot",
                            "hope_metrics_by_scenario.csv"))
    out_dir  = get(kw, "out-dir",
                   joinpath(@__DIR__, "..", "results", "wind_hvy_hope_uc_comparison", "n5"))
    hope_csv = abspath(hope_csv)
    out_dir  = abspath(out_dir)

    scen_ids  = parse.(Int, String.(strip.(split(subset_s, ","))))
    n_sub     = length(scen_ids)
    data_root = abspath(joinpath(@__DIR__, "..", "data_processed", "cases"))

    println("=" ^ 70)
    println("37_compare_wind_hvy_hope_uc_n5.jl")
    println("Date: ", Dates.now())
    println("Case: $case")
    println("Scenarios: ", join(scen_ids, ", "), "  (full set n=$n_scen, seed=$seed)")
    println("M2 config: risk_margin_mw=$m2_risk, window_buffer_hours=$m2_buf")
    println("HOPE metrics: ", isfile(hope_csv) ? "found" : "NOT FOUND — $(hope_csv)")
    println("=" ^ 70)

    mkpath(out_dir)

    # ── Load system and generate scenarios ────────────────────────────────────
    case_dir = joinpath(data_root, case)
    isdir(case_dir) || error("Case directory not found: $case_dir")
    sys      = load_system_data(case_dir)
    base_cfg = SimConfig(n_scenarios=n_scen, seed=seed)
    m2_cfg   = SimConfig(n_scenarios=n_scen, seed=seed,
                         risk_margin_mw=m2_risk, window_buffer_hours=m2_buf)

    println("\nGenerating ScenarioSet (n=$n_scen, seed=$seed) …")
    full_scen = generate_scenarios(sys, base_cfg)

    sub_avail = full_scen.availability[scen_ids, :, :]   # n_sub × n_therm × T

    annual_load = sum(sys.load_mw)

    # ── Run inline RAChronoOps models ─────────────────────────────────────────
    all_agg  = NamedTuple[]
    all_scen = NamedTuple[]

    println("\nInline models:")

    res_m1c, rt_m1c = run_and_measure("run_m1c_emergency_only") do
        run_m1c_emergency_only(sys, sub_avail, base_cfg)
    end
    push!(all_agg, full_metrics_row("M1c", case, res_m1c, sys, base_cfg, rt_m1c))
    append!(all_scen, scenario_rows_from_dispatch("M1c", case, res_m1c))

    res_m2, rt_m2 = run_and_measure("run_m2_with_diagnostics") do
        first(run_m2_with_diagnostics(sys, sub_avail, m2_cfg))
    end
    push!(all_agg, full_metrics_row("M2", case, res_m2, sys, m2_cfg, rt_m2))
    append!(all_scen, scenario_rows_from_dispatch("M2", case, res_m2))

    res_m3, rt_m3 = run_and_measure("run_m3_ed_dispatch") do
        run_m3_ed_dispatch(sys, sub_avail, base_cfg)
    end
    push!(all_agg, full_metrics_row("M3", case, res_m3, sys, base_cfg, rt_m3))
    append!(all_scen, scenario_rows_from_dispatch("M3", case, res_m3))

    # ── Read HOPE metrics from CSV ────────────────────────────────────────────
    println("\nHOPE metrics:")
    if isfile(hope_csv)
        for (mode, label) in [("ED", "HOPE-ED"), ("UC", "HOPE-UC")]
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

    # ── Save CSVs ─────────────────────────────────────────────────────────────
    CSV.write(joinpath(out_dir, "all_model_metrics_by_scenario.csv"), DataFrame(all_scen))
    CSV.write(joinpath(out_dir, "all_model_aggregate_metrics.csv"),   DataFrame(all_agg))

    # ── Error tables ──────────────────────────────────────────────────────────
    err_vs_m3      = NamedTuple[]
    err_vs_hope_ed = NamedTuple[]
    for test_model in ["M1c", "M2", "HOPE-ED", "HOPE-UC"]
        append!(err_vs_m3, build_error_table(all_scen, "M3", test_model, case))
    end
    for test_model in ["M1c", "M2", "M3", "HOPE-UC"]
        append!(err_vs_hope_ed, build_error_table(all_scen, "HOPE-ED", test_model, case))
    end
    CSV.write(joinpath(out_dir, "errors_vs_m3.csv"),      DataFrame(err_vs_m3))
    CSV.write(joinpath(out_dir, "errors_vs_hope_ed.csv"), DataFrame(err_vs_hope_ed))

    println("\nSaved:")
    println("  all_model_aggregate_metrics.csv")
    println("  all_model_metrics_by_scenario.csv")
    println("  errors_vs_m3.csv")
    println("  errors_vs_hope_ed.csv")

    # ── Console table ─────────────────────────────────────────────────────────
    println()
    println("=" ^ 70)
    println("Aggregate results (N=$n_sub scenarios, seed=$seed):")
    println("=" ^ 70)
    println(@sprintf("%-10s  %8s  %11s  %11s  %8s",
                     "Model", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)", "RT (s)"))
    println("-" ^ 60)
    for r in all_agg
        @printf("%-10s  %8.1f  %11.2f  %11.2f  %8.1f\n",
                r.model, r.lolh, r.eue_mwh, r.cvar_eue_mwh, r.total_runtime_s)
    end

    # ── Write summary.txt ─────────────────────────────────────────────────────
    sum_path = joinpath(out_dir, "summary.txt")
    open(sum_path, "w") do io
        println(io, "Wind-Heavy HOPE-UC Comparison: M1c / M2 / M3 / HOPE-ED / HOPE-UC")
        println(io, "Generated: ", Dates.now())
        println(io, "Case: $case  |  Scenarios: $(join(scen_ids, ","))  |  seed=$seed")
        println(io, "M2 config: risk_margin_mw=$m2_risk, window_buffer_hours=$m2_buf")
        println(io)

        println(io, "─"^70)
        println(io, "Aggregate metrics (mean over $(n_sub) scenarios)")
        println(io, "─"^70)
        println(io, @sprintf("%-10s  %8s  %11s  %11s  %11s  %8s",
                              "Model", "LOLH (h)", "EUE (MWh)", "CVaR (MWh)", "p95 (MWh)", "RT (s)"))
        println(io, "-"^70)
        for r in all_agg
            println(io, @sprintf("%-10s  %8.1f  %11.2f  %11.2f  %11.2f  %8.1f",
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

        get_agg = m -> begin
            idx = findfirst(r -> r.model == m, all_agg)
            isnothing(idx) ? nothing : all_agg[idx]
        end
        m1c_a = get_agg("M1c")
        m2_a  = get_agg("M2")
        m3_a  = get_agg("M3")
        hed_a = get_agg("HOPE-ED")
        huc_a = get_agg("HOPE-UC")

        # Q1: Does HOPE-ED match M3?
        println(io, "\nQ1. Does HOPE-ED match M3 (ED LP with storage)?")
        if !isnothing(m3_a) && !isnothing(hed_a)
            d_eue  = hed_a.eue_mwh - m3_a.eue_mwh
            d_lolh = hed_a.lolh    - m3_a.lolh
            println(io, @sprintf("  HOPE-ED vs M3:  ΔEUE = %.2f MWh,  ΔLOLH = %.1f h",
                                  d_eue, d_lolh))
            if abs(d_eue) < 5.0 && abs(d_lolh) < 0.5
                println(io, "  YES — HOPE-ED and M3 agree within 5 MWh / 0.5 h.")
                println(io, "  Both solve the same ED LP; small differences trace to solver tolerance or horizon effects.")
            else
                println(io, "  NO — HOPE-ED and M3 diverge by >5 MWh or >0.5 h. Check horizon or ramp-rate handling.")
            end
        else
            println(io, "  HOPE-ED or M3 data not available.")
        end

        # Q2: Does HOPE-UC increase EUE vs HOPE-ED?
        println(io, "\nQ2. Does HOPE-UC increase EUE vs HOPE-ED (commitment cycling penalty)?")
        if !isnothing(hed_a) && !isnothing(huc_a)
            d_eue  = huc_a.eue_mwh - hed_a.eue_mwh
            d_cvar = huc_a.cvar_eue_mwh - hed_a.cvar_eue_mwh
            println(io, @sprintf("  HOPE-UC vs HOPE-ED:  ΔEUE = %.2f MWh,  ΔCVaR = %.2f MWh",
                                  d_eue, d_cvar))
            if d_eue > 5.0
                println(io, "  YES — UC commitment constraints increase EUE by $(round(d_eue, digits=1)) MWh.")
                println(io, "  With storage, UC min-up/down constraints bind intertemporal storage dispatch.")
            elseif d_eue < -5.0
                println(io, "  NO — HOPE-UC EUE is lower than HOPE-ED (unexpected; verify storage pre-positioning).")
            else
                println(io, "  NO — |ΔEUE| < 5 MWh; UC cycling penalty is mild at N=5 for this system.")
            end
        else
            println(io, "  HOPE-ED or HOPE-UC data not available.")
        end

        # Q3: Does HOPE-UC change LOLH or event count vs HOPE-ED?
        println(io, "\nQ3. Does HOPE-UC change LOLH or shortage event count vs HOPE-ED?")
        if !isnothing(hed_a) && !isnothing(huc_a)
            d_lolh = huc_a.lolh - hed_a.lolh
            d_ev   = huc_a.n_shortage_events - hed_a.n_shortage_events
            println(io, @sprintf("  HOPE-UC vs HOPE-ED:  ΔLOLH = %.1f h,  Δevents = %.1f",
                                  d_lolh, d_ev))
            if abs(d_lolh) < 0.5 && abs(d_ev) < 1.0
                println(io, "  No material change — shortage hours and event count unchanged by UC constraints.")
            elseif d_lolh > 0.5
                println(io, "  UC increases LOLH: commitment constraints fragment load shed into more hours.")
                println(io, "  Storage pre-positioning is constrained by thermal min-up/down times.")
            else
                println(io, "  UC changes event structure without materially affecting total LOLH.")
            end
        else
            println(io, "  HOPE data not available.")
        end

        # Q4: How do M1c/M2 compare to HOPE-UC?
        println(io, "\nQ4. How do M1c and M2 compare to HOPE-UC (most detailed model)?")
        if !isnothing(m1c_a) && !isnothing(m2_a) && !isnothing(huc_a)
            d_m1c = m1c_a.eue_mwh - huc_a.eue_mwh
            d_m2  = m2_a.eue_mwh  - huc_a.eue_mwh
            dir_m1c = d_m1c > 0 ? "overestimates" : "underestimates"
            dir_m2  = d_m2  > 0 ? "overestimates" : "underestimates"
            println(io, @sprintf("  M1c  vs HOPE-UC: ΔEUE = %+.2f MWh  (%s)", d_m1c, dir_m1c))
            println(io, @sprintf("  M2   vs HOPE-UC: ΔEUE = %+.2f MWh  (%s)", d_m2,  dir_m2))
            best = abs(d_m1c) < abs(d_m2) ? "M1c" : "M2"
            println(io, "  Closest to HOPE-UC: $best")
        elseif !isnothing(m3_a) && !isnothing(huc_a)
            d_m3 = m3_a.eue_mwh - huc_a.eue_mwh
            println(io, @sprintf("  M3  vs HOPE-UC: ΔEUE = %+.2f MWh", d_m3))
        else
            println(io, "  Data not available.")
        end

        # Q5: Is the UC effect larger with storage vs Phase H (no storage)?
        println(io, "\nQ5. Is the UC reliability effect larger with storage than without (Phase H)?")
        if !isnothing(hed_a) && !isnothing(huc_a)
            d_eue_here  = abs(huc_a.eue_mwh - hed_a.eue_mwh)
            d_lolh_here = abs(huc_a.lolh    - hed_a.lolh)
            phase_h_eue  = 0.00   # Phase H result: VRE120_base_nostorage, N=5
            phase_h_lolh = 0.0
            println(io, @sprintf("  VRE120_wind_hvy (with storage):     |ΔEUE| = %.2f MWh,  |ΔLOLH| = %.1f h",
                                  d_eue_here, d_lolh_here))
            println(io, @sprintf("  VRE120_base_nostorage (Phase H):    |ΔEUE| = %.2f MWh,  |ΔLOLH| = %.1f h",
                                  phase_h_eue, phase_h_lolh))
            if d_eue_here > phase_h_eue + 1.0
                println(io, "  YES — storage amplifies the UC effect.")
                println(io, "  UC min-up/down constraints bind intertemporal SOC dispatch, raising EUE.")
            else
                println(io, "  NO — UC effect comparable to Phase H (≤1 MWh difference).")
                println(io, "  Storage does not materially amplify the UC cycling penalty at N=5.")
            end
        else
            println(io, "  HOPE data not available.")
        end

        # Q6: Does UC cause additional VRE curtailment in surplus hours?
        println(io, "\nQ6. Does UC cause additional VRE curtailment in surplus hours?")
        println(io, "  Requires dispatch-level output from HOPE (power_hourly.csv); not computed here.")
        println(io, "  In Phase H (no storage), UC curtailed up to 260 MW more VRE in surplus hours")
        println(io, "  due to thermal Pmin locking — a zero-cost, zero-reliability effect.")
        println(io, "  With storage, UC may additionally constrain battery charging in low-net-load hours,")
        println(io, "  potentially reducing SOC available for shortage pre-positioning.")
        println(io, "  → Check exports/hope_model_cases/<folder>/power_hourly.csv for verification.")

        # Q7: Should we scale to N=20?
        println(io, "\nQ7. Should we scale to N=20?")
        if !isnothing(hed_a) && !isnothing(huc_a)
            d_eue    = abs(huc_a.eue_mwh - hed_a.eue_mwh)
            rt_uc    = huc_a.total_runtime_s
            proj_n20 = rt_uc / n_sub * 20
            println(io, @sprintf("  HOPE-UC N=%d total runtime: %.0f s.  Projected N=20: %.0f s (%.1f h).",
                                  n_sub, rt_uc, proj_n20, proj_n20 / 3600))
            if d_eue < 5.0
                println(io, "  |ΔEUE| at N=$n_sub is < 5 MWh — UC and ED give similar adequacy estimates.")
                if proj_n20 < 14400
                    println(io, "  Scaling to N=20 is feasible (~$(round(Int, proj_n20/3600)) h); recommended for paper baseline.")
                else
                    println(io, "  Scaling to N=20 requires a compute node (>4 h).")
                    println(io, "  LOW PRIORITY unless UC effect grows with sample size.")
                end
            else
                println(io, "  |ΔEUE| at N=$n_sub is significant — N=20 would confirm whether UC effect persists.")
                if proj_n20 < 14400
                    println(io, "  Scaling is feasible on this machine.")
                else
                    println(io, "  Scaling requires a compute node.")
                end
            end
        else
            println(io, "  HOPE data not available.")
        end
    end

    println("\nSaved: $sum_path")
end

main()
