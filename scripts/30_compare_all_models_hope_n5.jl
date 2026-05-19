#!/usr/bin/env julia
# 30_compare_all_models_hope_n5.jl
#
# Full N=5 pilot comparison: M1 / M1b / M1c / M2 / M3 / HOPE-ED / HOPE-UC-lite.
#
# RAChronoOps models are run here for scenarios 1–5 using the same ScenarioSet
# (CRN, seed=42) used to export the HOPE cases.
# HOPE metrics are read from the CSV produced by script 27/29.
#
# Usage:
#   julia --project=. scripts/30_compare_all_models_hope_n5.jl \
#     --case VRE120_base \
#     --scenario-subset 1,2,3,4,5 \
#     --n-scenarios 20 \
#     --seed 42 \
#     --hope-dir results/hope_n5_pilot \
#     --out-dir results/full_model_comparison_with_hope/base_n5
#
# Options:
#   --case             Case name (default: VRE120_base)
#   --scenario-subset  Comma-separated 1-based IDs (default: 1,2,3,4,5)
#   --n-scenarios      Total scenarios in ScenarioSet (default: 20)
#   --seed             RNG seed (default: 42)
#   --m2-risk-margin   risk_margin_mw for M2 (default: 1000)
#   --m2-buffer        window_buffer_hours for M2 (default: 48)
#   --hope-dir         Directory with HOPE metrics CSVs (default: results/hope_n5_pilot)
#   --out-dir          Output directory (default: results/full_model_comparison_with_hope/base_n5)
#   --skip-m3          Skip M3 (saves ~1 min; HOPE-ED is already the LP benchmark)

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
        if key == "skip-m3"
            kw[key] = "true"
            i += 1
            continue
        end
        if i + 1 > length(args) || startswith(args[i+1], "--")
            error("Option $arg requires a value")
        end
        kw[key] = args[i+1]
        i += 2
    end
    return kw
end

# ── Metrics helpers ───────────────────────────────────────────────────────────

"""Return a flat NamedTuple of all MetricsResult fields for one model."""
function metrics_to_row(model::String, metrics::MetricsResult, total_rt::Float64,
                          n_scen::Int)
    (
        model                        = model,
        lolh                         = metrics.lolh,
        lolp_percent                 = metrics.lolp * 100.0,
        lole_days                    = metrics.lole_days,
        eue_mwh                      = metrics.eue,
        neue_ppm                     = metrics.neue * 1e6,
        cvar_eue_mwh                 = metrics.cvar_eue,
        p50_eue_mwh                  = metrics.p50_scenario_eue,
        p90_eue_mwh                  = metrics.p90_scenario_eue,
        p95_eue_mwh                  = metrics.p95_scenario_eue,
        p99_eue_mwh                  = metrics.p99_scenario_eue,
        n_shortage_events            = metrics.n_shortage_events,
        mean_shortage_duration_h     = metrics.mean_shortage_duration,
        max_shortage_duration_h      = metrics.max_shortage_duration,
        p95_shortage_duration_h      = metrics.p95_shortage_duration,
        max_shortfall_mw             = metrics.max_shortfall,
        mean_shortfall_when_shedding_mw = metrics.mean_shortfall_when_shedding,
        lolh_ci95_halfwidth          = metrics.lolh_ci95_halfwidth,
        eue_ci95_halfwidth_mwh       = metrics.eue_ci95_halfwidth,
        total_runtime_s              = total_rt,
        mean_runtime_per_scenario_s  = total_rt / max(1, n_scen),
    )
end

"""Per-scenario flat rows from DispatchResult vector."""
function scenario_rows(model::String, results::Vector{DispatchResult}, rts::Vector{Float64})
    rows = NamedTuple[]
    for (i, r) in enumerate(results)
        ls = r.load_shed
        durs = compute_shortage_events(ls)
        push!(rows, (
            model              = model,
            scenario_id        = r.scenario_id,
            lolh               = compute_lolh(ls),
            eue_mwh            = compute_eue(ls),
            max_shortfall_mw   = maximum(ls),
            n_shortage_events  = length(durs),
            mean_shortage_duration_h = isempty(durs) ? 0.0 : mean(Float64.(durs)),
            runtime_s          = length(rts) >= i ? rts[i] : NaN,
        ))
    end
    return rows
end

# ── HOPE aggregate from per-scenario CSV rows ─────────────────────────────────

"""
Build a MetricsResult-equivalent row for HOPE from per-scenario CSV data.
Shortage durations are reconstructed from hourly data if available.
"""
function hope_aggregate_row(model::String,
                              scen_rows  ::Vector{<:NamedTuple},
                              hourly_df  ::Union{DataFrame, Nothing},
                              case_folders::Vector{String},
                              load_mw    ::Vector{Float64})

    n_scen      = length(scen_rows)
    n_hours     = length(load_mw)
    annual_load = sum(load_mw)

    scen_lolh      = [Float64(r.lolh)      for r in scen_rows]
    scen_eue       = [Float64(r.eue_mwh)   for r in scen_rows]
    scen_lole_days = [Float64(r.lole_days) for r in scen_rows]

    lolh      = mean(scen_lolh)
    lolp      = n_hours > 0 ? lolh / n_hours : 0.0
    eue       = mean(scen_eue)
    neue      = annual_load > 0.0 ? eue / annual_load : 0.0
    lole_days = mean(scen_lole_days)

    # Shortage durations from hourly data
    all_durations = Int[]
    n_events_vec  = Int[]
    max_sf_vec    = Float64[]
    all_pos_shed  = Float64[]

    for (i, cf) in enumerate(case_folders)
        if !isnothing(hourly_df)
            rows_s = filter(r -> r.case_folder == cf, eachrow(hourly_df))
            ls = zeros(Float64, n_hours)
            for hr in rows_s
                h = Int(hr.hour)
                1 <= h <= n_hours && (ls[h] = Float64(hr.load_shed_mw))
            end
            d = compute_shortage_events(ls)
            append!(all_durations, d)
            push!(n_events_vec, length(d))
            push!(max_sf_vec, maximum(ls))
            for v in ls
                v > 0.0 && push!(all_pos_shed, v)
            end
        else
            # Fall back to CSV summary stats
            push!(n_events_vec, Int(scen_rows[i].n_shortage_events))
            push!(max_sf_vec, Float64(scen_rows[i].max_shortfall_mw))
            # Approximate durations from mean
            md = Float64(scen_rows[i].mean_shortage_duration_h)
            ne = Int(scen_rows[i].n_shortage_events)
            append!(all_durations, fill(max(1, round(Int, md)), ne))
        end
    end

    dur_float = Float64.(all_durations)
    mean_dur  = isempty(dur_float) ? 0.0 : mean(dur_float)
    max_dur   = isempty(dur_float) ? 0.0 : Float64(maximum(dur_float))
    p95_dur   = isempty(dur_float) ? 0.0 : quantile(dur_float, 0.95)
    n_ev_mean = isempty(n_events_vec) ? 0.0 : mean(Float64.(n_events_vec))
    max_sf_m  = isempty(max_sf_vec) ? 0.0 : mean(max_sf_vec)
    mean_sf_sh = isempty(all_pos_shed) ? 0.0 : mean(all_pos_shed)

    cvar_val   = compute_cvar(scen_eue)
    p50 = n_scen >= 1 ? quantile(scen_eue, 0.50) : 0.0
    p90 = n_scen >= 1 ? quantile(scen_eue, 0.90) : 0.0
    p95 = n_scen >= 1 ? quantile(scen_eue, 0.95) : 0.0
    p99 = n_scen >= 1 ? quantile(scen_eue, 0.99) : 0.0

    lolh_ci95 = compute_ci95(scen_lolh)
    eue_ci95  = compute_ci95(scen_eue)

    rts = [Float64(r.runtime_s) for r in scen_rows]
    total_rt = all(isnan, rts) ? NaN : sum(filter(!isnan, rts))

    return (
        model                        = model,
        lolh                         = lolh,
        lolp_percent                 = lolp * 100.0,
        lole_days                    = lole_days,
        eue_mwh                      = eue,
        neue_ppm                     = neue * 1e6,
        cvar_eue_mwh                 = cvar_val,
        p50_eue_mwh                  = p50,
        p90_eue_mwh                  = p90,
        p95_eue_mwh                  = p95,
        p99_eue_mwh                  = p99,
        n_shortage_events            = n_ev_mean,
        mean_shortage_duration_h     = mean_dur,
        max_shortage_duration_h      = max_dur,
        p95_shortage_duration_h      = p95_dur,
        max_shortfall_mw             = max_sf_m,
        mean_shortfall_when_shedding_mw = mean_sf_sh,
        lolh_ci95_halfwidth          = lolh_ci95,
        eue_ci95_halfwidth_mwh       = eue_ci95,
        total_runtime_s              = total_rt,
        mean_runtime_per_scenario_s  = isnan(total_rt) ? NaN : total_rt / n_scen,
    )
end

# ── Error table helper ────────────────────────────────────────────────────────

function build_error_table(agg_df::DataFrame, baseline_model::String)
    baseline = filter(r -> r.model == baseline_model, eachrow(agg_df))
    isempty(baseline) && return DataFrame()
    b = baseline[1]
    rows = NamedTuple[]
    for r in eachrow(agg_df)
        r.model == baseline_model && continue
        push!(rows, (
            model                  = r.model,
            lolh_diff              = r.lolh - b.lolh,
            lolh_rel_pct           = b.lolh > 0 ? (r.lolh - b.lolh) / b.lolh * 100 : NaN,
            eue_diff_mwh           = r.eue_mwh - b.eue_mwh,
            eue_rel_pct            = b.eue_mwh > 0 ? (r.eue_mwh - b.eue_mwh) / b.eue_mwh * 100 : NaN,
            cvar_eue_diff_mwh      = r.cvar_eue_mwh - b.cvar_eue_mwh,
            cvar_eue_rel_pct       = b.cvar_eue_mwh > 0 ? (r.cvar_eue_mwh - b.cvar_eue_mwh) / b.cvar_eue_mwh * 100 : NaN,
            max_shortfall_diff_mw  = r.max_shortfall_mw - b.max_shortfall_mw,
            n_events_diff          = r.n_shortage_events - b.n_shortage_events,
        ))
    end
    isempty(rows) ? DataFrame() : DataFrame(rows)
end

# ── Main ──────────────────────────────────────────────────────────────────────

let
    kw = parse_cli(ARGS)

    case_name   = get(kw, "case", "VRE120_base")
    scen_ids    = parse.(Int, split(get(kw, "scenario-subset", "1,2,3,4,5"), ","))
    n_scenarios = parse(Int, get(kw, "n-scenarios", "20"))
    seed        = parse(Int, get(kw, "seed", "42"))
    m2_risk     = parse(Float64, get(kw, "m2-risk-margin", "1000"))
    m2_buf      = parse(Int,     get(kw, "m2-buffer",      "48"))
    hope_dir    = get(kw, "hope-dir",
                      joinpath(@__DIR__, "..", "results", "hope_n5_pilot"))
    out_dir     = get(kw, "out-dir",
                      joinpath(@__DIR__, "..", "results",
                               "full_model_comparison_with_hope", "base_n5"))
    skip_m3     = get(kw, "skip-m3", "false") == "true"

    mkpath(out_dir)

    println("="^72)
    println("Full Model Comparison: M1/M1b/M1c/M2/M3 vs HOPE-ED/UC  (N=$(length(scen_ids)))")
    println("="^72)
    println("  Case        : $case_name")
    println("  Scenarios   : $(join(scen_ids, ", "))")
    println("  N total     : $n_scenarios  (seed=$seed)")
    println("  M2 config   : risk_margin=$(m2_risk) MW, buffer=$(m2_buf) h")
    println("  HOPE dir    : $hope_dir")
    println("  Output dir  : $out_dir")
    skip_m3 && println("  Note        : M3 skipped (--skip-m3)")
    println()

    # ── 1. Load system & generate scenarios ──────────────────────────────────
    data_dir = joinpath(@__DIR__, "..", "data_processed", "cases", case_name)
    isdir(data_dir) || error("Case data not found: $data_dir")

    println("Loading system …")
    system = load_system_data(data_dir)
    println("  $(system.n_hours) hours, $(size(thermal_generators(system), 1)) thermal generators")

    println("Generating $n_scenarios scenarios (seed=$seed) …")
    scenarios = generate_scenarios(system, n_scenarios, seed)

    # Select the target scenario slice: keep all 20 availability rows but run only subset
    1 <= minimum(scen_ids) && maximum(scen_ids) <= n_scenarios ||
        error("scenario-subset out of [1,$n_scenarios]")
    avail = scenarios.availability[scen_ids, :, :]   # n_scen × n_therm × n_hours
    n_scen = length(scen_ids)

    println("  Selected $(n_scen) scenarios: $(join(scen_ids, ", "))")
    println()

    # ── 2. Shared configs ─────────────────────────────────────────────────────
    base_cfg = SimConfig(n_scenarios = n_scen, seed = seed)
    m2_cfg   = SimConfig(n_scenarios = n_scen, seed = seed,
                         risk_margin_mw = m2_risk, window_buffer_hours = m2_buf)

    # ── 3. Run RAChronoOps models ─────────────────────────────────────────────
    model_results  = Dict{String, Vector{DispatchResult}}()
    model_runtimes = Dict{String, Float64}()

    function run_model(name::String, f::Function, cfg::SimConfig)
        print("  Running $(name) …")
        t0 = time()
        res = f(system, avail, cfg)
        rt = time() - t0
        # scenario_id fields are 1-indexed within the slice; for scen_ids=[1,2,...,5]
        # they already match the original scenario IDs.
        model_results[name]  = res
        model_runtimes[name] = rt
        @printf("  %.1f s\n", rt)
        return res
    end

    println("Running RAChronoOps models on $(n_scen) scenarios …")
    run_model("M1",  run_m1_rule_based,       base_cfg)
    run_model("M1b", run_m1b_reserve_aware,   base_cfg)
    run_model("M1c", run_m1c_emergency_only,  base_cfg)
    run_model("M2",  (s, a, c) -> first(run_m2_with_diagnostics(s, a, c)), m2_cfg)
    if !skip_m3
        run_model("M3", run_m3_ed_dispatch, base_cfg)
    end
    println()

    # Per-scenario runtimes (from DispatchResult.runtime_seconds when available)
    function per_scen_rts(name::String)
        res = model_results[name]
        map(r -> r.runtime_seconds, res)
    end

    # ── 4. Load HOPE metrics ──────────────────────────────────────────────────
    hope_metrics_path = joinpath(hope_dir, "hope_metrics_by_scenario.csv")
    hope_hourly_path  = joinpath(hope_dir, "hope_load_shed_hourly.csv")

    has_hope = isfile(hope_metrics_path)
    if !has_hope
        @warn "HOPE metrics not found at $hope_metrics_path\n" *
              "  HOPE columns will be absent from comparison.\n" *
              "  Run script 29 then script 27 first."
    end

    hope_df     = has_hope ? CSV.read(hope_metrics_path, DataFrame) : nothing
    hope_hourly = isfile(hope_hourly_path) ?
                      CSV.read(hope_hourly_path, DataFrame) : nothing

    # Build per-scenario HOPE rows for each mode
    hope_modes_found = String[]
    hope_scen_rows   = Dict{String, Vector{NamedTuple}}()
    hope_case_folders = Dict{String, Vector{String}}()

    if has_hope
        for mode in ["ED", "UC"]
            folders = ["RAChronoOps_$(case_name)_s$(lpad(s, 3, '0'))_$(mode)"
                       for s in scen_ids]
            rows_m = NamedTuple[]
            found_all = true
            for (s_idx, s_id) in enumerate(scen_ids)
                f = folders[s_idx]
                matches = filter(r -> r.case_folder == f, eachrow(hope_df))
                if isempty(matches)
                    found_all = false
                    break
                end
                r = matches[1]
                push!(rows_m, (
                    scenario_id          = s_id,
                    lolh                 = Float64(r.lolh),
                    lole_days            = Float64(r.lole_days),
                    eue_mwh              = Float64(r.eue_mwh),
                    max_shortfall_mw     = Float64(r.max_shortfall_mw),
                    n_shortage_events    = Float64(r.n_shortage_events),
                    mean_shortage_duration_h = Float64(r.mean_shortage_duration_h),
                    p95_shortage_duration_h  = Float64(r.p95_shortage_duration_h),
                    runtime_s            = ismissing(r.runtime_s) ? NaN : Float64(r.runtime_s),
                ))
            end
            if found_all
                push!(hope_modes_found, mode)
                hope_scen_rows[mode]   = rows_m
                hope_case_folders[mode] = folders
            else
                @warn "HOPE-$(mode): not all $(n_scen) scenarios found in metrics CSV"
            end
        end
    end

    # ── 5. Build per-scenario output DataFrame ────────────────────────────────
    scen_rows_all = NamedTuple[]

    for (name, res) in model_results
        rts = per_scen_rts(name)
        append!(scen_rows_all, scenario_rows(name, res, collect(rts)))
    end

    for mode in hope_modes_found
        model_name = "HOPE-$(mode)"
        for sr in hope_scen_rows[mode]
            push!(scen_rows_all, (
                model              = model_name,
                scenario_id        = sr.scenario_id,
                lolh               = sr.lolh,
                eue_mwh            = sr.eue_mwh,
                max_shortfall_mw   = sr.max_shortfall_mw,
                n_shortage_events  = sr.n_shortage_events,
                mean_shortage_duration_h = sr.mean_shortage_duration_h,
                runtime_s          = sr.runtime_s,
            ))
        end
    end

    scen_df = DataFrame(scen_rows_all)
    CSV.write(joinpath(out_dir, "all_model_metrics_by_scenario.csv"), scen_df)
    println("Written: all_model_metrics_by_scenario.csv  ($(size(scen_df, 1)) rows)")

    # ── 6. Build aggregate output DataFrame ──────────────────────────────────
    agg_rows = NamedTuple[]

    model_order = ["M1", "M1b", "M1c", "M2", "M3",
                   "HOPE-ED", "HOPE-UC"]

    for name in model_order
        if haskey(model_results, name)
            res = model_results[name]
            met = compute_metrics(res, system, base_cfg)
            rt  = model_runtimes[name]
            push!(agg_rows, metrics_to_row(name, met, rt, n_scen))
        elseif name in ("HOPE-ED", "HOPE-UC")
            mode = name == "HOPE-ED" ? "ED" : "UC"
            mode in hope_modes_found || continue
            row = hope_aggregate_row(
                name,
                hope_scen_rows[mode],
                hope_hourly,
                hope_case_folders[mode],
                system.load_mw
            )
            push!(agg_rows, row)
        end
    end

    agg_df = DataFrame(agg_rows)
    CSV.write(joinpath(out_dir, "all_model_aggregate_metrics.csv"), agg_df)
    println("Written: all_model_aggregate_metrics.csv")

    # ── 7. Runtime summary ────────────────────────────────────────────────────
    rt_rows = NamedTuple[]
    for r in eachrow(agg_df)
        push!(rt_rows, (
            model                       = r.model,
            total_runtime_s             = r.total_runtime_s,
            mean_runtime_per_scenario_s = r.mean_runtime_per_scenario_s,
        ))
    end
    CSV.write(joinpath(out_dir, "all_model_runtime_summary.csv"), DataFrame(rt_rows))
    println("Written: all_model_runtime_summary.csv")

    # ── 8. Error tables ───────────────────────────────────────────────────────
    for (baseline, fname) in [("M3",     "errors_vs_m3.csv"),
                               ("HOPE-ED","errors_vs_hope_ed.csv"),
                               ("HOPE-UC","errors_vs_hope_uc.csv")]
        t = build_error_table(agg_df, baseline)
        if !isempty(t)
            CSV.write(joinpath(out_dir, fname), t)
            println("Written: $fname")
        end
    end

    # ── 9. Print console summary ──────────────────────────────────────────────
    println()
    println("─"^72)
    println("Aggregate metrics (N=$(n_scen) scenarios, $(case_name)):")
    println("─"^72)
    @printf("%-10s  %6s  %9s  %9s  %8s  %7s\n",
            "Model", "LOLH", "EUE MWh", "CVaR MWh", "max SF", "rt(s)")
    println("─"^72)
    for r in eachrow(agg_df)
        rt_str = isnan(r.total_runtime_s) ? "  N/A" :
                 @sprintf("%7.1f", r.total_runtime_s)
        @printf("%-10s  %6.1f  %9.2f  %9.2f  %8.1f  %s\n",
                r.model, r.lolh, r.eue_mwh, r.cvar_eue_mwh,
                r.max_shortfall_mw, rt_str)
    end
    println()

    # ── 10. Summary text ──────────────────────────────────────────────────────
    m3_row   = isempty(agg_df) ? nothing :
               findfirst(r -> r.model == "M3",      eachrow(agg_df))
    hed_row  = isempty(agg_df) ? nothing :
               findfirst(r -> r.model == "HOPE-ED", eachrow(agg_df))
    huc_row  = isempty(agg_df) ? nothing :
               findfirst(r -> r.model == "HOPE-UC", eachrow(agg_df))
    m1c_row  = isempty(agg_df) ? nothing :
               findfirst(r -> r.model == "M1c",     eachrow(agg_df))
    m2_row   = isempty(agg_df) ? nothing :
               findfirst(r -> r.model == "M2",      eachrow(agg_df))

    get_f(df, idx, col) =
        isnothing(idx) ? NaN : Float64(df[idx, col])

    m3_lolh  = get_f(agg_df, m3_row,  :lolh)
    m3_eue   = get_f(agg_df, m3_row,  :eue_mwh)
    hed_lolh = get_f(agg_df, hed_row, :lolh)
    hed_eue  = get_f(agg_df, hed_row, :eue_mwh)
    huc_lolh = get_f(agg_df, huc_row, :lolh)
    huc_eue  = get_f(agg_df, huc_row, :eue_mwh)
    huc_rt   = get_f(agg_df, huc_row, :total_runtime_s)
    hed_rt   = get_f(agg_df, hed_row, :total_runtime_s)
    m3_rt    = get_f(agg_df, m3_row,  :total_runtime_s)
    m1c_lolh = get_f(agg_df, m1c_row, :lolh)
    m1c_eue  = get_f(agg_df, m1c_row, :eue_mwh)
    m2_lolh  = get_f(agg_df, m2_row,  :lolh)
    m2_eue   = get_f(agg_df, m2_row,  :eue_mwh)
    m2_rt    = get_f(agg_df, m2_row,  :total_runtime_s)
    m1c_rt   = get_f(agg_df, m1c_row, :total_runtime_s)

    function fmt(x::Float64, digits::Int=2)
        isnan(x) ? "N/A" : string(round(x, digits=digits))
    end

    lines = String[]
    push!(lines, "Full N=$(n_scen) Model Comparison — $(case_name)")
    push!(lines, "Generated: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
    push!(lines, "Scenarios: $(join(scen_ids, ", ")) from n_scenarios=$n_scenarios, seed=$seed")
    push!(lines, "M2 config: risk_margin=$(round(Int,m2_risk)) MW, window_buffer=$(m2_buf) h")
    push!(lines, "")

    for (q_num, question, answer) in [
        (1, "Does HOPE-ED match M3 across all five scenarios?",
         if isnan(hed_eue) || isnan(m3_eue)
             "HOPE-ED or M3 data missing."
         elseif abs(hed_eue - m3_eue) <= 1.0 && abs(hed_lolh - m3_lolh) <= 0.5
             "YES — mean LOLH: M3=$(fmt(m3_lolh,1))h HOPE-ED=$(fmt(hed_lolh,1))h Δ=$(fmt(hed_lolh-m3_lolh,1))h. " *
             "Mean EUE: M3=$(fmt(m3_eue))MWh HOPE-ED=$(fmt(hed_eue))MWh Δ=$(fmt(hed_eue-m3_eue))MWh."
         else
             "NO — notable difference. M3 LOLH=$(fmt(m3_lolh,1))h EUE=$(fmt(m3_eue))MWh; " *
             "HOPE-ED LOLH=$(fmt(hed_lolh,1))h EUE=$(fmt(hed_eue))MWh. Δ(ED−M3): " *
             "LOLH=$(fmt(hed_lolh-m3_lolh,1))h EUE=$(fmt(hed_eue-m3_eue))MWh."
         end),
        (2, "Does HOPE-UC-lite increase LOLH relative to HOPE-ED?",
         if isnan(huc_lolh) || isnan(hed_lolh)
             "HOPE-UC data missing."
         elseif huc_lolh > hed_lolh + 0.5
             "YES — HOPE-UC mean LOLH=$(fmt(huc_lolh,1))h vs HOPE-ED=$(fmt(hed_lolh,1))h " *
             "(Δ=+$(fmt(huc_lolh-hed_lolh,1))h). UC constraints spread outages over more hours."
         else
             "No significant difference: HOPE-UC=$(fmt(huc_lolh,1))h, HOPE-ED=$(fmt(hed_lolh,1))h."
         end),
        (3, "Does HOPE-UC-lite change EUE or mainly event structure?",
         if isnan(huc_eue) || isnan(hed_eue)
             "HOPE-UC data missing."
         elseif abs(huc_eue - hed_eue) <= 1.0
             "Mainly event structure — EUE is unchanged (UC=$(fmt(huc_eue))MWh vs ED=$(fmt(hed_eue))MWh, " *
             "Δ=$(fmt(huc_eue-hed_eue))MWh). Same total energy unserved, redistributed."
         else
             "EUE also changes — UC=$(fmt(huc_eue))MWh vs ED=$(fmt(hed_eue))MWh (Δ=$(fmt(huc_eue-hed_eue))MWh)."
         end),
        (4, "How close are M1c and M2 to HOPE-UC-lite, not just M3?",
         if isnan(huc_eue)
             "HOPE-UC data missing; compare M1c/M2 against HOPE-ED instead: " *
             "M1c EUE=$(fmt(m1c_eue))MWh vs HOPE-ED=$(fmt(hed_eue))MWh " *
             "(Δ=$(fmt(m1c_eue-hed_eue))MWh). " *
             "M2 EUE=$(fmt(m2_eue))MWh vs HOPE-ED=$(fmt(hed_eue))MWh " *
             "(Δ=$(fmt(m2_eue-hed_eue))MWh)."
         else
             "M1c LOLH=$(fmt(m1c_lolh,1))h EUE=$(fmt(m1c_eue))MWh vs HOPE-UC=$(fmt(huc_lolh,1))h/$(fmt(huc_eue))MWh " *
             "(ΔLOLH=$(fmt(m1c_lolh-huc_lolh,1))h ΔEUE=$(fmt(m1c_eue-huc_eue))MWh). " *
             "M2 LOLH=$(fmt(m2_lolh,1))h EUE=$(fmt(m2_eue))MWh vs HOPE-UC " *
             "(ΔLOLH=$(fmt(m2_lolh-huc_lolh,1))h ΔEUE=$(fmt(m2_eue-huc_eue))MWh)."
         end),
        (5, "How much slower is HOPE-UC-lite than M3, M2, and M1c?",
         let parts = String[]
             !isnan(huc_rt) && !isnan(m3_rt) && m3_rt > 0 &&
                 push!(parts, "vs M3: $(fmt(huc_rt/m3_rt,1))×")
             !isnan(huc_rt) && !isnan(m2_rt) && m2_rt > 0 &&
                 push!(parts, "vs M2: $(fmt(huc_rt/m2_rt,1))×")
             !isnan(huc_rt) && !isnan(m1c_rt) && m1c_rt > 0 &&
                 push!(parts, "vs M1c: $(fmt(huc_rt/m1c_rt,1))×")
             isempty(parts) ? "Runtime data missing." :
                 "HOPE-UC total $(fmt(huc_rt,1))s — " * join(parts, ", ") * "."
         end),
        (6, "Should we scale to N=20 for VRE120_base?",
         let parts = String[]
             !isnan(hed_rt) && push!(parts,
                 "HOPE-ED N=20 ≈ $(fmt((hed_rt/n_scen)*20/60,1)) min")
             !isnan(huc_rt) && push!(parts,
                 "HOPE-UC N=20 ≈ $(fmt((huc_rt/n_scen)*20/3600,1)) h")
             !isnan(m3_rt) && push!(parts,
                 "M3 N=20 ≈ $(fmt((m3_rt/n_scen)*20/60,1)) min")
             base = isempty(parts) ? "" : "Projected: " * join(parts, " | ") * ". "
             if !isnan(hed_eue) && !isnan(m3_eue) && abs(hed_eue - m3_eue) <= 1.0
                 base * "HOPE-ED validates M3; scaling to N=20 is appropriate. " *
                 "HOPE-UC needs a compute node for N=20."
             else
                 base * "Investigate HOPE-ED vs M3 discrepancy before scaling."
             end
         end),
        (7, "Should we run HOPE-UC-lite for other priority cases yet?",
         if !isnan(huc_rt)
             "HOPE-UC runtime is $(fmt(huc_rt/n_scen,0))s/scenario. " *
             "Run VRE120_base N=20 first to validate LOLH increase. " *
             "Extend to VRE120_bal15 and VRE120_wind_hvy only after confirming " *
             "consistent UC vs ED LOLH pattern and agreeing on UC model as the standard."
         else
             "HOPE-UC results pending. Complete N=5 pilot first."
         end),
    ]
        push!(lines, "─"^70)
        push!(lines, "Q$(q_num). $question")
        push!(lines, "")
        push!(lines, "  $answer")
        push!(lines, "")
    end

    summary_path = joinpath(out_dir, "summary.txt")
    open(summary_path, "w") do io
        join(io, lines, "\n")
        println(io)
    end
    println("Written: summary.txt")

    println()
    println("Done.")
end
