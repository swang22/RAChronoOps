#!/usr/bin/env julia
# 24_stress_test_m1c_recharge_limits.jl
#
# Stress tests M1c_current to identify when it stops matching M3.
# Uses VRE120_base under 6 in-memory stress conditions; all conditions share
# the same ScenarioSet (common random numbers) for fair comparison.
#
# Stress cases (all built in-memory, no files written to data_processed/):
#   1. base_reference      — VRE120_base as-is (N=20 reference)
#   2. load_scale_1225     — load scaled from 1.20 to 1.225 (+2.1%)
#   3. load_scale_125      — load scaled from 1.20 to 1.25  (+4.2%)
#   4. storage_p05_d4      — storage power 5% of peak load, 4h duration
#   5. storage_p10_d8      — storage power 10% of peak load, 8h duration
#   6. cycling_cost_high   — base_reference, M3 storage_cycling_cost=5 $/MWh
#
# Models: M1c_current, M1c_VREOnly, M2 (rm=1000/buf=48), M3
#
# Outputs (results/m1c_recharge_stress/base_n20/):
#   m1c_recharge_stress_results.csv
#   m1c_recharge_stress_errors.csv
#   summary.txt
#
# Usage:
#   julia --project=. scripts/24_stress_test_m1c_recharge_limits.jl [options]
#
# Options:
#   --n-scenarios N    MC scenarios  (default: 20)
#   --seed S           RNG seed      (default: 42)
#   --skip-m3          Omit M3 runs (fast testing; no error table produced)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using CSV, DataFrames, Statistics
using Printf, Dates, Logging

# ── CLI ───────────────────────────────────────────────────────────────────────
function parse_cli(args::Vector{String})
    kw = Dict{String,String}()
    i  = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected positional argument: $arg")
        key = arg[3:end]
        if key == "skip-m3"
            kw["skip-m3"] = "true"; i += 1
        else
            i + 1 <= length(args) && !startswith(args[i+1], "--") ||
                error("Option $arg requires a value")
            kw[key] = args[i+1]; i += 2
        end
    end
    return kw
end

# ── In-memory storage variant builder ────────────────────────────────────────
function make_storage_variant(base_sys::SystemData;
                               power_mw::Float64,
                               duration_h::Float64)::SystemData
    bs       = base_sys.storage
    energy   = power_mw * duration_h
    new_stor = DataFrame(
        storage_id            = [bs.storage_id[1]],
        power_mw              = [power_mw],
        energy_mwh            = [energy],
        charge_efficiency     = [bs.charge_efficiency[1]],
        discharge_efficiency  = [bs.discharge_efficiency[1]],
        variable_cost_per_mwh = [bs.variable_cost_per_mwh[1]],
        initial_soc_mwh       = [energy * 0.5],
    )
    return SystemData(
        base_sys.generators, new_stor,
        base_sys.load_mw, base_sys.wind_cf, base_sys.solar_cf, base_sys.n_hours,
    )
end

# ── main ─────────────────────────────────────────────────────────────────────
let
    kw          = parse_cli(ARGS)
    n_scenarios = parse(Int, get(kw, "n-scenarios", "20"))
    seed        = parse(Int, get(kw, "seed",        "42"))
    skip_m3     = get(kw, "skip-m3", "false") == "true"

    project_root = joinpath(@__DIR__, "..")
    cases_root   = joinpath(project_root, "data_processed", "cases")
    out_dir      = joinpath(project_root, "results", "m1c_recharge_stress",
                            "base_n$(n_scenarios)")
    mkpath(out_dir)

    log_path = joinpath(out_dir,
                        "run_$(Dates.format(now(), "yyyymmdd_HHMMSS")).log")
    logger   = SimpleLogger(open(log_path, "w"))
    global_logger(logger)

    @info "M1c recharge-limits stress test"
    @info "n=$n_scenarios | seed=$seed | skip_m3=$skip_m3"
    @info "Output: $out_dir"

    results_path = joinpath(out_dir, "m1c_recharge_stress_results.csv")
    errors_path  = joinpath(out_dir, "m1c_recharge_stress_errors.csv")
    summary_path = joinpath(out_dir, "summary.txt")

    # ── load base system ─────────────────────────────────────────────────────
    base_cdir = joinpath(cases_root, "VRE120_base")
    isdir(base_cdir) || error("VRE120_base case not found: $base_cdir")
    base_sys  = load_system_data(base_cdir)
    peak_load = maximum(base_sys.load_mw)
    @info "Base system loaded. Peak load = $(round(peak_load; digits=1)) MW"

    # ── shared ScenarioSet (CRN) ─────────────────────────────────────────────
    crn_cfg       = SimConfig(; n_scenarios, seed)
    crn_scenarios = generate_scenarios(base_sys, crn_cfg)
    @info "Generated $n_scenarios scenarios (seed=$seed, CRN shared across all stress cases)"

    # ── build stress cases ───────────────────────────────────────────────────
    lf_1225 = 1.225 / 1.20   # ≈ 1.02083
    lf_125  = 1.25  / 1.20   # ≈ 1.04167

    sys_ls1225 = SystemData(
        base_sys.generators, base_sys.storage,
        base_sys.load_mw .* lf_1225,
        base_sys.wind_cf, base_sys.solar_cf, base_sys.n_hours)

    sys_ls125 = SystemData(
        base_sys.generators, base_sys.storage,
        base_sys.load_mw .* lf_125,
        base_sys.wind_cf, base_sys.solar_cf, base_sys.n_hours)

    p05_power = round(0.05 * peak_load; digits=1)
    p10_power = round(0.10 * peak_load; digits=1)   # same MW as base, double duration

    sys_p05d4 = make_storage_variant(base_sys;
                    power_mw=p05_power, duration_h=4.0)
    sys_p10d8 = make_storage_variant(base_sys;
                    power_mw=p10_power, duration_h=8.0)

    # Each stress case: (label, description, system, M3 cycling cost)
    stress_cases = [
        (label = "base_reference",
         desc  = "VRE120_base as-is (load_scale=1.20)",
         sys   = base_sys,
         m3_cc = 0.01),
        (label = "load_scale_1225",
         desc  = "load scale 1.20→1.225  (+2.1% load)",
         sys   = sys_ls1225,
         m3_cc = 0.01),
        (label = "load_scale_125",
         desc  = "load scale 1.20→1.25  (+4.2% load)",
         sys   = sys_ls125,
         m3_cc = 0.01),
        (label = "storage_p05_d4",
         desc  = "storage $(p05_power) MW / $(p05_power*4) MWh (5%/4h)",
         sys   = sys_p05d4,
         m3_cc = 0.01),
        (label = "storage_p10_d8",
         desc  = "storage $(p10_power) MW / $(p10_power*8) MWh (10%/8h)",
         sys   = sys_p10d8,
         m3_cc = 0.01),
        (label = "cycling_cost_high",
         desc  = "base_reference; M3 storage_cycling_cost=5 \$/MWh",
         sys   = base_sys,
         m3_cc = 5.0),
    ]
    stress_labels = [sc.label for sc in stress_cases]

    # ── result-row builder ───────────────────────────────────────────────────
    nan = NaN

    function make_row(stress_lbl, model_lbl, m, rt)
        (
            stress_case                     = stress_lbl,
            model_label                     = model_lbl,
            lolh_hours                      = isnothing(m) ? nan : m.lolh,
            lolp_percent                    = isnothing(m) ? nan : 100.0 * m.lolp,
            lole_days                       = isnothing(m) ? nan : m.lole_days,
            eue_mwh                         = isnothing(m) ? nan : m.eue,
            neue_ppm                        = isnothing(m) ? nan : m.neue * 1e6,
            cvar_eue_mwh                    = isnothing(m) ? nan : m.cvar_eue,
            n_shortage_events               = isnothing(m) ? nan : m.n_shortage_events,
            mean_shortage_duration_h        = isnothing(m) ? nan : m.mean_shortage_duration,
            p95_shortage_duration_h         = isnothing(m) ? nan : m.p95_shortage_duration,
            max_shortfall_mw                = isnothing(m) ? nan : m.max_shortfall,
            mean_shortfall_when_shedding_mw = isnothing(m) ? nan : m.mean_shortfall_when_shedding,
            lolh_ci95_halfwidth_h           = isnothing(m) ? nan : m.lolh_ci95_halfwidth,
            lolh_ci95_rel_halfwidth         = isnothing(m) ? nan : m.lolh_ci95_rel_halfwidth,
            eue_ci95_halfwidth_mwh          = isnothing(m) ? nan : m.eue_ci95_halfwidth,
            eue_ci95_rel_halfwidth          = isnothing(m) ? nan : m.eue_ci95_rel_halfwidth,
            runtime_s                       = round(rt; digits=1),
        )
    end

    results_rows     = NamedTuple[]
    m3_metrics_map   = Dict{String,Any}()
    m3_runtimes_map  = Dict{String,Float64}()
    heuristic_labels = ["M1c_current", "M1c_VREOnly", "M2"]

    total_t0 = time()

    # ── main loop ─────────────────────────────────────────────────────────────
    for sc in stress_cases
        slabel = sc.label
        ssys   = sc.sys

        @info "── Stress case: $slabel ($(sc.desc)) ──"

        base_cfg = SimConfig(; n_scenarios, seed)
        m2_cfg   = SimConfig(; n_scenarios, seed,
                              risk_margin_mw        = 1000.0,
                              window_buffer_hours   = 48,
                              min_window_length_hours = 24,
                              merge_gap_hours       = 24)
        m3_cfg   = SimConfig(; n_scenarios, seed,
                              storage_cycling_cost  = sc.m3_cc)

        # M1c_current
        try
            t0 = time()
            r  = run_m1c_emergency_only(ssys, crn_scenarios, base_cfg)
            rt = time() - t0
            m  = compute_metrics(r, ssys, base_cfg)
            push!(results_rows, make_row(slabel, "M1c_current", m, rt))
            @info "  M1c_current: LOLH=$(round(m.lolh;digits=2)) h  EUE=$(round(m.eue;digits=0)) MWh  ($(round(rt;digits=1)) s)"
        catch e
            @error "M1c_current failed for $slabel" exception=(e, catch_backtrace())
            push!(results_rows, make_row(slabel, "M1c_current", nothing, 0.0))
        end

        # M1c_VREOnly
        try
            t0 = time()
            r  = run_m1c_vre_only_charge(ssys, crn_scenarios, base_cfg)
            rt = time() - t0
            m  = compute_metrics(r, ssys, base_cfg)
            push!(results_rows, make_row(slabel, "M1c_VREOnly", m, rt))
            @info "  M1c_VREOnly: LOLH=$(round(m.lolh;digits=2)) h  EUE=$(round(m.eue;digits=0)) MWh  ($(round(rt;digits=1)) s)"
        catch e
            @error "M1c_VREOnly failed for $slabel" exception=(e, catch_backtrace())
            push!(results_rows, make_row(slabel, "M1c_VREOnly", nothing, 0.0))
        end

        # M2
        try
            t0 = time()
            r  = run_m2_event_window_lp(ssys, crn_scenarios, m2_cfg)
            rt = time() - t0
            m  = compute_metrics(r, ssys, m2_cfg)
            push!(results_rows, make_row(slabel, "M2", m, rt))
            @info "  M2:          LOLH=$(round(m.lolh;digits=2)) h  EUE=$(round(m.eue;digits=0)) MWh  ($(round(rt;digits=1)) s)"
        catch e
            @error "M2 failed for $slabel" exception=(e, catch_backtrace())
            push!(results_rows, make_row(slabel, "M2", nothing, 0.0))
        end

        # M3
        if !skip_m3
            try
                t0 = time()
                r  = run_m3_ed_dispatch(ssys, crn_scenarios, m3_cfg)
                rt = time() - t0
                m  = compute_metrics(r, ssys, m3_cfg)
                m3_metrics_map[slabel]  = m
                m3_runtimes_map[slabel] = rt
                push!(results_rows, make_row(slabel, "M3", m, rt))
                @info "  M3:          LOLH=$(round(m.lolh;digits=2)) h  EUE=$(round(m.eue;digits=0)) MWh  ($(round(rt;digits=1)) s)"
            catch e
                @error "M3 failed for $slabel" exception=(e, catch_backtrace())
                push!(results_rows, make_row(slabel, "M3", nothing, 0.0))
            end
        end

        CSV.write(results_path, DataFrame(results_rows))
        @info "  Intermediate results saved → $results_path"
    end

    total_rt = time() - total_t0
    @info "Total runtime: $(round(total_rt;digits=1)) s"

    df    = DataFrame(results_rows)
    ok_df = filter(r -> !isnan(r.lolh_hours), df)

    # ── build error table ─────────────────────────────────────────────────────
    error_rows = NamedTuple[]
    safe_rel(a, b) = (b != 0.0 && !isnan(b)) ? (a - b) / b : nan

    if !skip_m3
        for slabel in stress_labels
            haskey(m3_metrics_map, slabel) || continue
            m3    = m3_metrics_map[slabel]
            m3_rt = get(m3_runtimes_map, slabel, 0.0)
            for lbl in heuristic_labels
                mrow = filter(r -> r.stress_case == slabel &&
                                   r.model_label  == lbl &&
                                   !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                push!(error_rows, (
                    stress_case           = slabel,
                    method_label          = lbl,
                    m3_lolh               = m3.lolh,
                    method_lolh           = r.lolh_hours,
                    lolh_error            = r.lolh_hours - m3.lolh,
                    lolh_abs_error        = abs(r.lolh_hours - m3.lolh),
                    lolh_rel_error        = safe_rel(r.lolh_hours, m3.lolh),
                    m3_eue                = m3.eue,
                    method_eue            = r.eue_mwh,
                    eue_error             = r.eue_mwh - m3.eue,
                    eue_rel_error         = safe_rel(r.eue_mwh, m3.eue),
                    m3_cvar_eue           = m3.cvar_eue,
                    method_cvar_eue       = r.cvar_eue_mwh,
                    cvar_eue_error        = r.cvar_eue_mwh - m3.cvar_eue,
                    m3_max_shortfall      = m3.max_shortfall,
                    method_max_shortfall  = r.max_shortfall_mw,
                    max_shortfall_error   = r.max_shortfall_mw - m3.max_shortfall,
                    m3_runtime_s          = round(m3_rt; digits=1),
                    method_runtime_s      = r.runtime_s,
                    runtime_speedup_vs_m3 = m3_rt > 0.0 ? m3_rt / r.runtime_s : nan,
                ))
            end
        end
    end

    CSV.write(results_path, df)
    CSV.write(errors_path, DataFrame(error_rows))

    # ── summary.txt ────────────────────────────────────────────────────────────
    all_labels = vcat(heuristic_labels, skip_m3 ? [] : ["M3"])
    err_df     = DataFrame(error_rows)

    open(summary_path, "w") do io
        sep = "=" ^ 84
        println(io, sep)
        println(io, "M1c Recharge-Limits Stress Test Summary")
        @printf(io, "Generated: %s\n", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
        @printf(io, "n_scenarios: %d  |  seed: %d\n", n_scenarios, seed)
        println(io, "Base case: VRE120_base | Models: M1c_current, M1c_VREOnly, M2, M3")
        println(io, sep)
        println(io)

        println(io, "Stress case descriptions")
        println(io, "-" ^ 84)
        for sc in stress_cases
            @printf(io, "  %-22s  %s\n", sc.label, sc.desc)
            if sc.m3_cc != 0.01
                @printf(io, "  %-22s    (M3 cycling cost = %.2f \$/MWh)\n", "", sc.m3_cc)
            end
        end
        println(io)

        # ── aggregate metrics ──────────────────────────────────────────────────
        println(io, "Aggregate reliability metrics")
        println(io, "-" ^ 100)
        @printf(io, "  %-22s %-16s %8s %7s %7s %10s %10s %10s %8s\n",
                "Stress case", "Model",
                "LOLH(h)", "LOLP%", "LOLE_d",
                "EUE(MWh)", "CVaR-EUE", "MaxSF(MW)", "rt(s)")
        println(io, "  " * "-" ^ 95)
        for lbl in all_labels
            for slabel in stress_labels
                mrow = filter(r -> r.stress_case == slabel &&
                                   r.model_label  == lbl &&
                                   !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                @printf(io, "  %-22s %-16s %8.2f %7.3f %7.2f %10.1f %10.1f %10.1f %8.1f\n",
                        slabel, lbl,
                        r.lolh_hours, r.lolp_percent, r.lole_days,
                        r.eue_mwh, r.cvar_eue_mwh, r.max_shortfall_mw, r.runtime_s)
            end
        end
        println(io)

        # ── event structure ────────────────────────────────────────────────────
        println(io, "Event-structure metrics")
        println(io, "-" ^ 100)
        @printf(io, "  %-22s %-16s %8s %8s %8s %10s %10s\n",
                "Stress case", "Model",
                "n_evts", "mean_dur", "p95_dur", "MaxSF(MW)", "MeanSF(MW)")
        println(io, "  " * "-" ^ 95)
        for lbl in all_labels
            for slabel in stress_labels
                mrow = filter(r -> r.stress_case == slabel &&
                                   r.model_label  == lbl &&
                                   !isnan(r.lolh_hours), ok_df)
                isempty(mrow) && continue
                r = mrow[1, :]
                @printf(io, "  %-22s %-16s %8.1f %8.2f %8.2f %10.1f %10.1f\n",
                        slabel, lbl,
                        r.n_shortage_events, r.mean_shortage_duration_h,
                        r.p95_shortage_duration_h,
                        r.max_shortfall_mw, r.mean_shortfall_when_shedding_mw)
            end
        end
        println(io)

        # ── error table ────────────────────────────────────────────────────────
        if !isempty(err_df)
            println(io, "Method error vs M3 benchmark")
            println(io, "-" ^ 100)
            @printf(io, "  %-22s %-16s %9s %9s %9s %9s %10s %10s\n",
                    "Stress case", "Method",
                    "M3_LOLH", "Meth_LOLH", "err_h", "rel_err%",
                    "M3_EUE", "EUE_err")
            println(io, "  " * "-" ^ 95)
            for slabel in stress_labels
                sub = filter(r -> r.stress_case == slabel, err_df)
                isempty(sub) && continue
                for r in eachrow(sub)
                    rel_pct = isnan(r.lolh_rel_error) ? "n/a" :
                              @sprintf("%+.1f%%", 100.0 * r.lolh_rel_error)
                    @printf(io, "  %-22s %-16s %9.2f %9.2f %+9.2f %9s %10.1f %+10.1f\n",
                            slabel, r.method_label,
                            r.m3_lolh, r.method_lolh, r.lolh_error,
                            rel_pct, r.m3_eue, r.eue_error)
                end
            end
            println(io)

            # runtime
            println(io, "Runtime and speedup vs M3")
            println(io, "-" ^ 84)
            @printf(io, "  %-22s %-16s %10s %10s %12s\n",
                    "Stress case", "Method", "rt(s)", "M3_rt(s)", "speedup")
            println(io, "  " * "-" ^ 78)
            for slabel in stress_labels
                sub = filter(r -> r.stress_case == slabel, err_df)
                isempty(sub) && continue
                for r in eachrow(sub)
                    spd = isnan(r.runtime_speedup_vs_m3) ? "n/a" :
                          @sprintf("%.1fx", r.runtime_speedup_vs_m3)
                    @printf(io, "  %-22s %-16s %10.1f %10.1f %12s\n",
                            slabel, r.method_label,
                            r.method_runtime_s, r.m3_runtime_s, spd)
                end
            end
            println(io)
        end

        # ── research questions ─────────────────────────────────────────────────
        println(io, sep)
        println(io, "Research questions")
        println(io, sep)
        println(io)

        # Q1: Does M1c match M3 under higher load?
        println(io, "Q1. Does M1c_current still match M3 under higher load stress?")
        println(io)
        for slabel in ["base_reference", "load_scale_1225", "load_scale_125"]
            sub = filter(r -> r.stress_case == slabel && r.method_label == "M1c_current", err_df)
            isempty(sub) && continue
            r   = sub[1, :]
            tag = abs(r.lolh_error) < 0.5 ? "MATCH" : abs(r.lolh_error) < 5.0 ? "CLOSE" : "BROKEN"
            @printf(io, "  %-22s  M3=%.2f h  M1c=%.2f h  err=%+.2f h  → %s\n",
                    slabel, r.m3_lolh, r.method_lolh, r.lolh_error, tag)
        end
        println(io)

        # Q2: Does M1c fail when storage power/duration changes?
        println(io, "Q2. Does M1c_current fail when storage power/duration changes?")
        println(io)
        for slabel in ["base_reference", "storage_p05_d4", "storage_p10_d8"]
            sub = filter(r -> r.stress_case == slabel && r.method_label == "M1c_current", err_df)
            isempty(sub) && continue
            r   = sub[1, :]
            tag = abs(r.lolh_error) < 0.5 ? "MATCH" : abs(r.lolh_error) < 5.0 ? "CLOSE" : "BROKEN"
            @printf(io, "  %-22s  M3=%.2f h  M1c=%.2f h  err=%+.2f h  → %s\n",
                    slabel, r.m3_lolh, r.method_lolh, r.lolh_error, tag)
        end
        println(io)

        # Q3: Does M1c_VREOnly remain poor?
        println(io, "Q3. Does M1c_VREOnly remain poor across all stress cases?")
        println(io)
        for slabel in stress_labels
            sub = filter(r -> r.stress_case == slabel && r.method_label == "M1c_VREOnly", err_df)
            isempty(sub) && continue
            r = sub[1, :]
            @printf(io, "  %-22s  M3=%.2f h  VREOnly=%.2f h  err=%+.2f h\n",
                    slabel, r.m3_lolh, r.method_lolh, r.lolh_error)
        end
        println(io)

        # Q4: Does M2 remain close to M3 when M1c fails?
        println(io, "Q4. Does M2 remain close to M3 when M1c_current fails?")
        println(io)
        for slabel in stress_labels
            m1c_sub = filter(r -> r.stress_case == slabel && r.method_label == "M1c_current", err_df)
            m2_sub  = filter(r -> r.stress_case == slabel && r.method_label == "M2",          err_df)
            (isempty(m1c_sub) || isempty(m2_sub)) && continue
            m1c_r = m1c_sub[1, :]
            m2_r  = m2_sub[1, :]
            @printf(io, "  %-22s  M3=%.2f h  M1c_err=%+.2f h  M2_err=%+.2f h\n",
                    slabel, m1c_r.m3_lolh, m1c_r.lolh_error, m2_r.lolh_error)
        end
        println(io)

        # Q5: Which stress condition most clearly shows M1c is case-specific?
        println(io, "Q5. Which stress condition most clearly demonstrates M1c is case-specific?")
        println(io)
        if !isempty(err_df)
            m1c_errors = filter(r -> r.method_label == "M1c_current", err_df)
            if !isempty(m1c_errors)
                sorted_idx = sortperm(m1c_errors.lolh_abs_error, rev=true)
                for idx in sorted_idx
                    r = m1c_errors[idx, :]
                    @printf(io, "  %-22s  |err| = %.2f h  (M3=%.2f h  M1c=%.2f h)\n",
                            r.stress_case, r.lolh_abs_error, r.m3_lolh, r.method_lolh)
                end
            end
        end
        println(io)

        # Q6: Should M1c be described as useful heuristic rather than general benchmark?
        println(io, "Q6. Should M1c be described as a useful heuristic baseline rather than a general benchmark?")
        println(io)
        if !isempty(err_df)
            m1c_errors = filter(r -> r.method_label == "M1c_current", err_df)
            if !isempty(m1c_errors)
                max_err  = maximum(m1c_errors.lolh_abs_error)
                mean_err = mean(m1c_errors.lolh_abs_error)
                n_bad    = sum(m1c_errors.lolh_abs_error .> 2.0)
                n_total  = size(m1c_errors, 1)
                @printf(io, "  Max |LOLH error|   = %.2f h\n", max_err)
                @printf(io, "  Mean |LOLH error|  = %.2f h\n", mean_err)
                @printf(io, "  Stress cases with |err| > 2 h: %d / %d\n", n_bad, n_total)
                if n_bad > 0
                    println(io, """
  → YES. M1c_current matches M3 under the specific N=20 VRE120_base conditions
    but fails under stress. It should be presented as a practice-oriented
    heuristic baseline, not a general benchmark. Its accuracy is case/sample-
    specific and depends on the interplay of thermal headroom, charging rate,
    and storage capacity relative to shortage event depth.""")
                else
                    println(io, """
  → ROBUST. M1c_current error is < 2 h across all stress cases.
    Caveats still apply (SOC trajectories differ; accuracy is not structural),
    but within this VRE120_base stress range, M1c is a useful quick benchmark.""")
                end
            end
        end
        println(io)

        @printf(io, "Total runtime: %.1f s\n", total_rt)
        println(io, sep)
        println(io, "Files: m1c_recharge_stress_results.csv")
        println(io, "       m1c_recharge_stress_errors.csv")
    end

    # ── console output ─────────────────────────────────────────────────────────
    sep = "=" ^ 84
    println()
    println(sep)
    @printf("M1c Recharge-Limits Stress Test  |  N=%d  |  seed=%d\n",
            n_scenarios, seed)
    println(sep)

    # compact error summary per stress case
    @printf("  %-22s  %9s  %9s  %9s  %9s\n",
            "Stress case", "M3_LOLH", "M1c_err", "M2_err", "M3_rt(s)")
    println("  " * "-" ^ 64)

    if !skip_m3 && !isempty(err_df)
        for slabel in stress_labels
            m3_row  = filter(r -> r.stress_case == slabel && r.model_label == "M3" && !isnan(r.lolh_hours), ok_df)
            m1c_sub = filter(r -> r.stress_case == slabel && r.method_label == "M1c_current", err_df)
            m2_sub  = filter(r -> r.stress_case == slabel && r.method_label == "M2",          err_df)
            isempty(m3_row) && continue
            m3_lolh  = m3_row[1, :lolh_hours]
            m3_rt    = m3_row[1, :runtime_s]
            m1c_err  = isempty(m1c_sub) ? nan : m1c_sub[1, :lolh_error]
            m2_err   = isempty(m2_sub)  ? nan : m2_sub[1, :lolh_error]
            m1c_str  = isnan(m1c_err) ? "  n/a  " : @sprintf("%+.2f h", m1c_err)
            m2_str   = isnan(m2_err)  ? "  n/a  " : @sprintf("%+.2f h", m2_err)
            @printf("  %-22s  %9.2f  %9s  %9s  %9.1f\n",
                    slabel, m3_lolh, m1c_str, m2_str, m3_rt)
        end
    else
        for slabel in stress_labels
            m1c_row = filter(r -> r.stress_case == slabel && r.model_label == "M1c_current" && !isnan(r.lolh_hours), ok_df)
            isempty(m1c_row) && continue
            @printf("  %-22s  LOLH=%.2f h  (M3 skipped)\n",
                    slabel, m1c_row[1, :lolh_hours])
        end
    end

    @printf("\nTotal runtime: %.1f s\n", total_rt)
    @printf("Output: %s\n", abspath(out_dir))
    @printf("Summary: %s\n", abspath(summary_path))
    println()
end
