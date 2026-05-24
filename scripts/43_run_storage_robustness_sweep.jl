#!/usr/bin/env julia
# 43_run_storage_robustness_sweep.jl
#
# Storage robustness sweep: run M1c, M2, M3, and the storage-energy
# sufficiency bound across all storage robustness variant cases.
#
# Results:
#   metrics_all.csv          — per-case, per-model aggregate metrics
#   scenario_eue_all.csv     — per-case, per-model, per-scenario EUE
#   bound_comparison_all.csv — per-case, per-scenario bound vs models
#   runtime_all.csv          — per-case, per-model runtime
#   summary.txt              — narrative Q&A on robustness findings
#
# Usage:
#   julia --project=. scripts/43_run_storage_robustness_sweep.jl \
#     --cases VRE120_base,VRE120_wind_hvy \
#     --n-scenarios 20 \
#     --seed 42 \
#     --risk-margin-mw 1000 \
#     --window-buffer-hours 48 \
#     --out-dir results/storage_robustness_sweep
#
# The script resolves variant case directories from:
#   data_processed/storage_robustness_cases/<source_case>_<label>/
# Override with --robustness-dir if cases are in a different location.

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

# ── Storage-energy sufficiency bound (copied from script 39) ──────────────────

function compute_storage_bound(system      ::SystemData,
                                availability::Array{<:Integer, 3},
                                ::SimConfig;
                                lookback_hours::Int = 72)

    therm   = thermal_generators(system)
    n_therm = size(therm, 1)
    n_scen  = size(availability, 1)
    n_hours = system.n_hours

    pmax      = Float64.(therm.pmax_mw)
    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)

    stor = system.storage
    if size(stor, 1) == 0
        stor_power  = 0.0
        stor_energy = 0.0
        init_soc    = 0.0
        eta_ch      = 1.0
        eta_dis     = 1.0
    else
        stor_power  = sum(stor.power_mw)
        stor_energy = sum(stor.energy_mwh)
        init_soc    = sum(stor.initial_soc_mwh)
        eta_ch      = mean(stor.charge_efficiency)
        eta_dis     = mean(stor.discharge_efficiency)
    end

    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h]
             for h in 1:n_hours]

    event_rows    = NamedTuple[]
    scenario_rows = NamedTuple[]

    for s in 1:n_scen
        therm_avail   = Vector{Float64}(undef, n_hours)
        net_surplus   = Vector{Float64}(undef, n_hours)
        pre_shortfall = Vector{Float64}(undef, n_hours)
        surplus       = Vector{Float64}(undef, n_hours)

        for h in 1:n_hours
            ta = zero(Float64)
            for g in 1:n_therm
                ta += pmax[g] * availability[s, g, h]
            end
            therm_avail[h]   = ta
            bal              = ta + p_vre[h] - system.load_mw[h]
            net_surplus[h]   = bal
            pre_shortfall[h] = max(0.0, -bal)
            surplus[h]       = max(0.0,  bal)
        end

        events = Tuple{Int,Int}[]
        in_ev  = false
        ev_s   = 0
        for h in 1:n_hours
            if pre_shortfall[h] > 1e-6
                if !in_ev; ev_s = h; in_ev = true; end
            else
                if in_ev; push!(events, (ev_s, h - 1)); in_ev = false; end
            end
        end
        in_ev && push!(events, (ev_s, n_hours))

        scenario_pre_eue     = sum(pre_shortfall)
        total_coverage_bound = 0.0

        for (ev_start, ev_end) in events
            ev_len  = ev_end - ev_start + 1
            pre_eue = sum(pre_shortfall[h] for h in ev_start:ev_end)
            peak_sf = maximum(pre_shortfall[h] for h in ev_start:ev_end)

            lb_start = max(1, ev_start - lookback_hours)
            lb_end   = ev_start - 1
            soc_lb   = init_soc
            if lb_end >= lb_start
                for lh in lb_start:lb_end
                    sur_lh   = surplus[lh]
                    headroom = stor_energy - soc_lb
                    if sur_lh > 0.0 && headroom > 0.0 && stor_power > 0.0
                        chg    = min(stor_power, sur_lh, headroom / eta_ch)
                        soc_lb = min(stor_energy, soc_lb + chg * eta_ch)
                    end
                end
            end

            feasible_dis_energy   = min(stor_energy, soc_lb) * eta_dis
            power_limited_mwh     = sum(min(pre_shortfall[h], stor_power)
                                        for h in ev_start:ev_end)
            coverage              = min(pre_eue, feasible_dis_energy, power_limited_mwh)
            total_coverage_bound += coverage

            push!(event_rows, (
                scenario_id                          = s,
                event_start_hour                     = ev_start,
                event_end_hour                       = ev_end,
                event_duration_h                     = ev_len,
                pre_storage_eue_mwh                  = pre_eue,
                event_peak_shortfall_mw              = peak_sf,
                storage_coverage_bound_mwh           = coverage,
                residual_eue_bound_mwh               = pre_eue - coverage,
            ))
        end

        residual_bound = max(0.0, scenario_pre_eue - total_coverage_bound)
        suf_ratio = scenario_pre_eue > 0.0 ?
                    total_coverage_bound / scenario_pre_eue : NaN

        push!(scenario_rows, (
            scenario_id                      = s,
            scenario_pre_storage_eue_mwh     = scenario_pre_eue,
            scenario_residual_eue_bound_mwh  = residual_bound,
            n_events                         = length(events),
            total_storage_coverage_bound_mwh = total_coverage_bound,
            storage_sufficiency_ratio        = suf_ratio,
        ))
    end

    return event_rows, scenario_rows
end

# ── Metric helpers ────────────────────────────────────────────────────────────

function run_and_measure(f, label::String)
    print("      $label … ")
    t0 = time()
    r  = f()
    rt = time() - t0
    println(@sprintf("%.1f s", rt))
    return r, rt
end

function full_metrics(results::Vector{DispatchResult}, label::String, case::String, rt::Float64)
    eue_vec  = [sum(r.load_shed) for r in results]
    lolh_vec = [count(x -> x > 1e-6, r.load_shed) for r in results]
    n_scen   = length(results)
    mean_eue = mean(eue_vec)
    mean_lolh = mean(lolh_vec)
    sorted_eue = sort(eue_vec; rev=true)
    n_tail = max(1, ceil(Int, 0.05 * n_scen))
    cvar_eue = mean(sorted_eue[1:n_tail])
    (
        model       = label,
        case        = case,
        n_scenarios = n_scen,
        mean_lolh_h = mean_lolh,
        mean_eue_mwh= mean_eue,
        cvar_eue_mwh= cvar_eue,
        p95_eue_mwh = quantile(eue_vec, 0.95),
        runtime_s   = rt,
    )
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    kw = parse_cli(ARGS)

    src_cases_s  = get(kw, "cases",              "VRE120_base,VRE120_wind_hvy")
    n_scen       = parse(Int,     get(kw, "n-scenarios",        "20"))
    seed         = parse(Int,     get(kw, "seed",               "42"))
    risk_mw      = parse(Float64, get(kw, "risk-margin-mw",     "1000"))
    buf_h        = parse(Int,     get(kw, "window-buffer-hours","48"))
    out_dir      = abspath(get(kw, "out-dir",
                    joinpath(@__DIR__, "..", "results", "storage_robustness_sweep")))
    rob_root     = abspath(get(kw, "robustness-dir",
                    joinpath(@__DIR__, "..", "data_processed", "storage_robustness_cases")))

    src_cases = String.(strip.(split(src_cases_s, ",")))

    println("=" ^ 70)
    println("43_run_storage_robustness_sweep.jl")
    println("Date: ", Dates.now())
    println("Source cases: ", join(src_cases, ", "))
    println("N=$n_scen, seed=$seed")
    println("M2: risk_margin=$(risk_mw) MW, buffer=$(buf_h) h")
    println("Robustness dir: ", rob_root)
    println("Output: ", out_dir)
    println("=" ^ 70)

    mkpath(out_dir)

    # Enumerate available variant directories
    variant_dirs = String[]
    for src_case in src_cases
        if !isdir(rob_root)
            @warn "Robustness directory not found: $rob_root"
            continue
        end
        for entry in sort(readdir(rob_root))
            startswith(entry, src_case * "_") || continue
            d = joinpath(rob_root, entry)
            isdir(d) && push!(variant_dirs, d)
        end
    end

    isempty(variant_dirs) && error("No variant directories found in $rob_root")
    println("\nVariants to run ($(length(variant_dirs))):")
    for d in variant_dirs; println("  ", basename(d)); end

    # Collect results
    all_metrics    = NamedTuple[]
    all_scen_eue   = NamedTuple[]
    all_bound_cmp  = NamedTuple[]
    all_runtimes   = NamedTuple[]

    for case_dir in variant_dirs
        case_name = basename(case_dir)
        println("\n── Case: $case_name ─────────────────────────────────────────────")

        sys      = load_system_data(case_dir)
        base_cfg = SimConfig(n_scenarios=n_scen, seed=seed)
        m2_cfg   = SimConfig(n_scenarios=n_scen, seed=seed,
                             risk_margin_mw=risk_mw, window_buffer_hours=buf_h)

        println("    Generating ScenarioSet …")
        scen = generate_scenarios(sys, base_cfg)

        # M1c
        res_m1c, rt_m1c = run_and_measure("M1c") do
            run_m1c_emergency_only(sys, scen, base_cfg)
        end
        push!(all_metrics, full_metrics(res_m1c, "M1c", case_name, rt_m1c))
        for r in res_m1c
            push!(all_scen_eue, (model="M1c", case=case_name,
                                  scenario_id=r.scenario_id,
                                  eue_mwh=sum(r.load_shed),
                                  lolh_h=count(x->x>1e-6, r.load_shed)))
        end
        push!(all_runtimes, (model="M1c", case=case_name, runtime_s=rt_m1c))

        # M2
        res_m2, rt_m2 = run_and_measure("M2 (event-window LP)") do
            first(run_m2_with_diagnostics(sys, scen.availability, m2_cfg))
        end
        push!(all_metrics, full_metrics(res_m2, "M2", case_name, rt_m2))
        for r in res_m2
            push!(all_scen_eue, (model="M2", case=case_name,
                                  scenario_id=r.scenario_id,
                                  eue_mwh=sum(r.load_shed),
                                  lolh_h=count(x->x>1e-6, r.load_shed)))
        end
        push!(all_runtimes, (model="M2", case=case_name, runtime_s=rt_m2))

        # M3
        res_m3, rt_m3 = run_and_measure("M3 (full-year ED LP)") do
            run_m3_ed_dispatch(sys, scen.availability, base_cfg)
        end
        push!(all_metrics, full_metrics(res_m3, "M3", case_name, rt_m3))
        for r in res_m3
            push!(all_scen_eue, (model="M3", case=case_name,
                                  scenario_id=r.scenario_id,
                                  eue_mwh=sum(r.load_shed),
                                  lolh_h=count(x->x>1e-6, r.load_shed)))
        end
        push!(all_runtimes, (model="M3", case=case_name, runtime_s=rt_m3))

        # Sufficiency bound
        print("      Sufficiency bound … ")
        t0 = time()
        _, sc_rows = compute_storage_bound(sys, scen.availability, base_cfg;
                                            lookback_hours=72)
        rt_bnd = time() - t0
        println(@sprintf("%.1f s", rt_bnd))
        push!(all_runtimes, (model="Bound", case=case_name, runtime_s=rt_bnd))

        # Build per-scenario bound vs model comparison
        m3_eue_dict  = Dict(r.scenario_id => sum(r.load_shed) for r in res_m3)
        m1c_eue_dict = Dict(r.scenario_id => sum(r.load_shed) for r in res_m1c)
        m2_eue_dict  = Dict(r.scenario_id => sum(r.load_shed) for r in res_m2)

        for r in sc_rows
            sid = r.scenario_id
            push!(all_bound_cmp, (
                case                            = case_name,
                scenario_id                     = sid,
                pre_storage_eue_mwh             = r.scenario_pre_storage_eue_mwh,
                residual_eue_bound_mwh          = r.scenario_residual_eue_bound_mwh,
                storage_sufficiency_ratio       = r.storage_sufficiency_ratio,
                m1c_eue_mwh                     = get(m1c_eue_dict, sid, NaN),
                m2_eue_mwh                      = get(m2_eue_dict,  sid, NaN),
                m3_eue_mwh                      = get(m3_eue_dict,  sid, NaN),
                bound_minus_m3_mwh              = r.scenario_residual_eue_bound_mwh -
                                                  get(m3_eue_dict, sid, NaN),
                m1c_minus_m3_mwh                = get(m1c_eue_dict, sid, NaN) -
                                                  get(m3_eue_dict,  sid, NaN),
                m2_minus_m3_mwh                 = get(m2_eue_dict,  sid, NaN) -
                                                  get(m3_eue_dict,  sid, NaN),
            ))
        end
    end

    # ── Save CSVs ─────────────────────────────────────────────────────────────
    CSV.write(joinpath(out_dir, "metrics_all.csv"),       DataFrame(all_metrics))
    CSV.write(joinpath(out_dir, "scenario_eue_all.csv"),  DataFrame(all_scen_eue))
    CSV.write(joinpath(out_dir, "bound_comparison_all.csv"), DataFrame(all_bound_cmp))
    CSV.write(joinpath(out_dir, "runtime_all.csv"),       DataFrame(all_runtimes))

    # ── Summary text ──────────────────────────────────────────────────────────
    summary_path = joinpath(out_dir, "summary.txt")
    open(summary_path, "w") do io
        write_summary(io, all_metrics, all_bound_cmp, all_runtimes,
                      n_scen, seed, risk_mw, buf_h, variant_dirs)
    end

    println("\nOutput written to: ", out_dir)
    for f in ("metrics_all.csv", "scenario_eue_all.csv",
              "bound_comparison_all.csv", "runtime_all.csv", "summary.txt")
        sz = stat(joinpath(out_dir, f)).size
        @printf("  %-35s  %d bytes\n", f, sz)
    end
end

# ── Summary writer ────────────────────────────────────────────────────────────

function write_summary(io, all_metrics, all_bound_cmp, all_runtimes,
                       n_scen, seed, risk_mw, buf_h, variant_dirs)
    println(io, "Storage Robustness Sweep — Summary")
    println(io, "Generated: ", Dates.now())
    println(io, "N=$n_scen, seed=$seed")
    println(io, "M2 config: risk_margin=$(risk_mw) MW, buffer=$(buf_h) h")
    println(io, "Variants run: $(length(variant_dirs))")
    println(io)

    # Helper: get mean metric for (model, case)
    get_m(model, case, field) = begin
        sub = filter(r -> r.model == model && r.case == case, all_metrics)
        isempty(sub) ? NaN : getfield(first(sub), field)
    end
    get_rt(model, case) = begin
        sub = filter(r -> r.model == model && r.case == case, all_runtimes)
        isempty(sub) ? NaN : first(sub).runtime_s
    end
    get_bnd(case) = begin
        sub = filter(r -> r.case == case, all_bound_cmp)
        isempty(sub) ? NaN : mean(r.residual_eue_bound_mwh for r in sub)
    end
    get_suf(case) = begin
        sub = filter(r -> r.case == case && !isnan(r.storage_sufficiency_ratio),
                     all_bound_cmp)
        isempty(sub) ? NaN : mean(r.storage_sufficiency_ratio for r in sub)
    end

    cases = unique(r.case for r in all_metrics)

    # ── Per-case table ─────────────────────────────────────────────────────────
    println(io, "─"^90)
    println(io, "Per-case results (mean across $n_scen scenarios)")
    println(io, "─"^90)
    @printf(io, "  %-40s  %8s  %9s  %9s  %9s  %8s  %8s\n",
            "Case", "Model", "LOLH(h)", "EUE(MWh)", "CVaR(MWh)", "Bound", "RT(s)")
    println(io, "  " * "-"^88)

    for case in sort(cases)
        for model in ("M1c", "M2", "M3")
            lolh = get_m(model, case, :mean_lolh_h)
            eue  = get_m(model, case, :mean_eue_mwh)
            cvar = get_m(model, case, :cvar_eue_mwh)
            rt   = get_rt(model, case)
            bnd  = model == "M3" ? get_bnd(case) : NaN
            bnd_s = isnan(bnd) ? "      —" : @sprintf("%9.1f", bnd)
            @printf(io, "  %-40s  %8s  %9.1f  %9.1f  %9.1f  %s  %8.1f\n",
                    case, model, lolh, eue, cvar, bnd_s, rt)
        end
    end
    println(io)

    # ── Q&A ───────────────────────────────────────────────────────────────────
    println(io, "─"^90)
    println(io, "Q&A")
    println(io, "─"^90)
    println(io)

    # Q1: Does M1c track M3 EUE across all duration variants?
    println(io, "Q1. Does Emergency-Only MC (M1c) track Full-Year ED-MC (M3) EUE")
    println(io, "    across all storage duration variants (Exp A)?")
    dur_cases = filter(c -> occursin("_dur", c), cases)
    if isempty(dur_cases)
        println(io, "  No Exp A cases found.")
    else
        all_match = true
        for case in sort(dur_cases)
            m1c_eue = get_m("M1c", case, :mean_eue_mwh)
            m3_eue  = get_m("M3",  case, :mean_eue_mwh)
            delta   = m1c_eue - m3_eue
            match   = abs(delta) < 10.0
            all_match = all_match && match
            @printf(io, "  %-42s  M1c−M3 = %+7.1f MWh  %s\n",
                    case, delta, match ? "OK" : "MISMATCH")
        end
        println(io, all_match ?
            "  YES — M1c matches M3 EUE across all duration variants." :
            "  Some duration variants show M1c−M3 EUE divergence > 10 MWh.")
    end
    println(io)

    # Q2: Does M2 match M3 EUE and LOLH across all duration variants?
    println(io, "Q2. Does Event-Window LP-MC (M2) match M3 EUE and LOLH")
    println(io, "    across all storage duration variants (Exp A)?")
    if isempty(dur_cases)
        println(io, "  No Exp A cases found.")
    else
        for case in sort(dur_cases)
            m2_eue  = get_m("M2", case, :mean_eue_mwh)
            m3_eue  = get_m("M3", case, :mean_eue_mwh)
            m2_lolh = get_m("M2", case, :mean_lolh_h)
            m3_lolh = get_m("M3", case, :mean_lolh_h)
            @printf(io, "  %-42s  EUE Δ=%+6.1f MWh  LOLH Δ=%+5.1f h\n",
                    case, m2_eue - m3_eue, m2_lolh - m3_lolh)
        end
    end
    println(io)

    # Q3: Does M1c break for very short storage (2h)?
    println(io, "Q3. Does M1c accuracy hold for short-duration storage (2h)?")
    dur2_cases = filter(c -> occursin("_dur2h", c), cases)
    if isempty(dur2_cases)
        println(io, "  No dur2h cases found.")
    else
        for case in sort(dur2_cases)
            m1c_eue = get_m("M1c", case, :mean_eue_mwh)
            m3_eue  = get_m("M3",  case, :mean_eue_mwh)
            suf     = get_suf(case)
            @printf(io, "  %-42s  M1c−M3=%+7.1f MWh  suf_ratio=%.3f\n",
                    case, m1c_eue - m3_eue, suf)
        end
    end
    println(io)

    # Q4: Does the sufficiency ratio drop for short-duration storage?
    println(io, "Q4. Does the storage-energy sufficiency ratio drop as duration decreases?")
    dur_cases_sorted = sort(filter(c -> any(occursin("_dur$(d)h", c)
                                            for d in (2, 4, 8, 12)), cases))
    for case in dur_cases_sorted
        suf = get_suf(case)
        @printf(io, "  %-42s  suf_ratio = %.4f\n", case, suf)
    end
    println(io)

    # Q5: Does M1c track M3 EUE across power variants (Exp B)?
    println(io, "Q5. Does M1c track M3 EUE across all power variants (Exp B)?")
    pwr_cases = filter(c -> occursin("_pwr", c), cases)
    if isempty(pwr_cases)
        println(io, "  No Exp B cases found.")
    else
        for case in sort(pwr_cases)
            m1c_eue = get_m("M1c", case, :mean_eue_mwh)
            m3_eue  = get_m("M3",  case, :mean_eue_mwh)
            @printf(io, "  %-42s  M1c−M3 = %+7.1f MWh\n", case, m1c_eue - m3_eue)
        end
    end
    println(io)

    # Q6: Under load stress (Exp C), do M1c / M2 still match M3?
    println(io, "Q6. Under load stress (Exp C), do M1c and M2 still match M3 EUE?")
    ls_cases = filter(c -> occursin("_ls", c), cases)
    if isempty(ls_cases)
        println(io, "  No Exp C cases found.")
    else
        for case in sort(ls_cases)
            m1c_eue = get_m("M1c", case, :mean_eue_mwh)
            m2_eue  = get_m("M2",  case, :mean_eue_mwh)
            m3_eue  = get_m("M3",  case, :mean_eue_mwh)
            @printf(io, "  %-42s  M1c−M3=%+7.1f  M2−M3=%+7.1f MWh\n",
                    case, m1c_eue - m3_eue, m2_eue - m3_eue)
        end
    end
    println(io)

    # Q7: Runtime speedup of M1c and M2 vs M3 across all variants
    println(io, "Q7. Runtime speedup of M1c and M2 vs M3 (per scenario, mean across variants)?")
    m1c_rts = [get_rt("M1c", c) for c in cases if !isnan(get_rt("M1c", c))]
    m2_rts  = [get_rt("M2",  c) for c in cases if !isnan(get_rt("M2",  c))]
    m3_rts  = [get_rt("M3",  c) for c in cases if !isnan(get_rt("M3",  c))]
    if !isempty(m3_rts)
        @printf(io, "  Mean M3 total runtime:  %.1f s / case (%d scenarios)\n",
                mean(m3_rts), n_scen)
        isempty(m1c_rts) || @printf(io, "  Mean M1c total runtime: %.1f s (×%.0f speedup vs M3)\n",
                mean(m1c_rts), mean(m3_rts) / mean(m1c_rts))
        isempty(m2_rts)  || @printf(io, "  Mean M2 total runtime:  %.1f s (×%.0f speedup vs M3)\n",
                mean(m2_rts),  mean(m3_rts) / mean(m2_rts))
    end
    println(io)

    # Q8: Overall robustness verdict
    println(io, "Q8. Overall: are the main paper conclusions robust across storage configurations?")
    all_eue_deltas_m1c = [get_m("M1c", c, :mean_eue_mwh) - get_m("M3", c, :mean_eue_mwh)
                          for c in cases if !isnan(get_m("M1c", c, :mean_eue_mwh))]
    all_eue_deltas_m2  = [get_m("M2",  c, :mean_eue_mwh) - get_m("M3", c, :mean_eue_mwh)
                          for c in cases if !isnan(get_m("M2",  c, :mean_eue_mwh))]
    if !isempty(all_eue_deltas_m1c)
        @printf(io, "  M1c−M3 EUE: max |Δ| = %.1f MWh (across %d variants)\n",
                maximum(abs.(all_eue_deltas_m1c)), length(all_eue_deltas_m1c))
    end
    if !isempty(all_eue_deltas_m2)
        @printf(io, "  M2−M3  EUE: max |Δ| = %.1f MWh (across %d variants)\n",
                maximum(abs.(all_eue_deltas_m2)), length(all_eue_deltas_m2))
    end
    suf_vals = [get_suf(c) for c in cases if !isnan(get_suf(c))]
    if !isempty(suf_vals)
        @printf(io, "  Sufficiency ratio range: %.3f – %.3f\n",
                minimum(suf_vals), maximum(suf_vals))
        if minimum(suf_vals) > 0.80
            println(io, "  All variants have suf_ratio > 0.80 — storage-energy bound is tight")
            println(io, "  across the tested parameter space.  The EUE-convergence result is robust.")
        elseif minimum(suf_vals) < 0.50
            println(io, "  Some variants have suf_ratio < 0.50 — storage is insufficient in those")
            println(io, "  configurations; larger EUE differences between models may appear.")
        end
    end
end

main()
