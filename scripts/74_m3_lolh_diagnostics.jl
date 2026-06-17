"""
74_m3_lolh_diagnostics.jl

Two-part diagnostic:

Part 1  (fast, ~10 min): Gurobi M2 event-shape statistics for both portfolios.
  The manuscript event-shape table (tab:event_shape) was generated from HiGHS
  M2 dispatch. This part recomputes the same statistics using Gurobi so that
  all manuscript-facing M2 values use a consistent solver.

Part 2  (slow, ~2 h): HiGHS vs Gurobi comparison for M3 full-year ED on N=20
  scenarios. M3 is hard-coded to Gurobi in production; this part checks whether
  HiGHS produces different LOLH (alternative-optimum sensitivity).
  If LOLH differs while EUE is identical, disputed-hour diagnostics are
  produced (same format as script 73).

Outputs
-------
  results/paper_tables/m2_gurobi_event_shape.csv
  results/paper_tables/m3_lolh_comparison.csv
  results/paper_tables/m3_lolh_solver_diagnostics.csv  (if M3 LOLH differs)
  results/paper_tables/m3_lolh_threshold_sensitivity.csv  (if M3 LOLH differs)
"""

using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using RAChronoOps, Statistics, Printf, DataFrames, CSV, Dates
using HiGHS, Gurobi, JuMP
import MathOptInterface as MOI

REPO      = abspath(joinpath(@__DIR__, ".."))
DATA_ROOT = joinpath(REPO, "data_processed", "cases")
CASES     = ["VRE120_base", "VRE120_wind_hvy"]
N         = 20
SEED      = 42
M2_RISK   = 1000.0; M2_BUF = 48; M2_GAP = 24; M2_MIN = 24
THRESHOLDS = [0.0, 1e-10, 1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3]

println("="^72)
println("Script 74: M3 LOLH diagnostics + Gurobi M2 event-shape")
println("Date: ", Dates.now())
println("="^72)

cfg = SimConfig(n_scenarios=N, seed=SEED,
                risk_margin_mw=M2_RISK,
                window_buffer_hours=M2_BUF,
                merge_gap_hours=M2_GAP,
                min_window_length_hours=M2_MIN)

gurobi_env = Gurobi.Env()

# ── inlined M2 runner (identical to script 73) ────────────────────────────────
function run_m2_opt_full(sys, avail_arr, config; opt_factory)
    T       = sys.n_hours
    therm   = thermal_generators(sys)
    n_therm = nrow(therm)
    n_scen  = size(avail_arr, 1)
    pmax    = Float64.(therm.pmax_mw)
    stor    = sys.storage

    if nrow(stor) == 0
        total_power = 0.0; total_energy = 0.0
        init_soc = 0.0; eta_ch = 1.0; eta_dis = 1.0
    else
        total_power  = sum(stor.power_mw)
        total_energy = sum(stor.energy_mwh)
        init_soc     = sum(stor.initial_soc_mwh)
        eta_ch       = mean(stor.charge_efficiency)
        eta_dis      = mean(stor.discharge_efficiency)
    end
    soc_floor = config.reserve_fraction * total_energy

    wind_cap  = wind_capacity_mw(sys)
    solar_cap = solar_capacity_mw(sys)
    p_vre = [wind_cap * sys.wind_cf[h] + solar_cap * sys.solar_cf[h] for h in 1:T]
    net_load         = sys.load_mw .- p_vre
    high_nl_thresh   = quantile(net_load, config.high_net_load_quantile)
    charge_nl_thresh = quantile(net_load, config.charge_net_load_quantile)

    results = Vector{DispatchResult}(undef, n_scen)

    for s in 1:n_scen
        ta = [sum(pmax[g] * avail_arr[s, g, h] for g in 1:n_therm) for h in 1:T]
        margin  = ta .+ p_vre .- sys.load_mw
        windows = RAChronoOps.build_risk_windows(margin, T,
                      config.risk_margin_mw, config.window_buffer_hours,
                      config.merge_gap_hours, config.min_window_length_hours)

        load_shed = zeros(T); st_dis = zeros(T); st_chg = zeros(T)
        soc_arr   = zeros(T); curtailmt = zeros(T)
        curr_soc  = init_soc; h_cursor = 1

        for (ws, we) in windows
            if h_cursor < ws
                curr_soc = RAChronoOps._ra1b_segment!(
                    h_cursor, ws - 1, ta, p_vre, sys.load_mw, net_load,
                    high_nl_thresh, charge_nl_thresh,
                    total_power, total_energy, eta_ch, eta_dis, soc_floor,
                    curr_soc, load_shed, st_dis, st_chg, soc_arr, curtailmt)
            end
            final_soc, ok = RAChronoOps._solve_window_lp!(
                ws, we, ta, p_vre, sys.load_mw,
                total_power, total_energy, eta_ch, eta_dis, curr_soc,
                config.voll, config.epsilon_cycling,
                load_shed, st_dis, st_chg, soc_arr, curtailmt;
                optimizer_factory = opt_factory)
            curr_soc = ok ? final_soc :
                RAChronoOps._ra1b_segment!(
                    ws, we, ta, p_vre, sys.load_mw, net_load,
                    high_nl_thresh, charge_nl_thresh,
                    total_power, total_energy, eta_ch, eta_dis, soc_floor,
                    curr_soc, load_shed, st_dis, st_chg, soc_arr, curtailmt)
            h_cursor = we + 1
        end
        if h_cursor <= T
            RAChronoOps._ra1b_segment!(
                h_cursor, T, ta, p_vre, sys.load_mw, net_load,
                high_nl_thresh, charge_nl_thresh,
                total_power, total_energy, eta_ch, eta_dis, soc_floor,
                curr_soc, load_shed, st_dis, st_chg, soc_arr, curtailmt)
        end
        results[s] = DispatchResult(s, load_shed, st_dis, st_chg, soc_arr,
                                    nothing, curtailmt, 0.0)
    end
    return results
end

# ── parameterized M3 runner ───────────────────────────────────────────────────
function run_m3_param(system, avail_arr, config; opt_factory)
    therm   = thermal_generators(system)
    stor    = system.storage
    n_therm = nrow(therm)
    n_stor  = nrow(stor)
    n_scen  = size(avail_arr, 1)
    T       = system.n_hours
    VOLL    = config.voll
    cyc_cc  = config.storage_cycling_cost

    pmax     = Float64.(therm.pmax_mw)
    var_cost = Float64.(therm.variable_cost_per_mwh)

    if n_stor > 0
        pow_mw  = Float64.(stor.power_mw)
        eng_mwh = Float64.(stor.energy_mwh)
        eta_ch  = Float64.(stor.charge_efficiency)
        eta_dis = Float64.(stor.discharge_efficiency)
        s_vcost = Float64.(stor.variable_cost_per_mwh)
        soc0    = Float64.(stor.initial_soc_mwh)
    end

    wind_cap  = wind_capacity_mw(system)
    solar_cap = solar_capacity_mw(system)
    p_vre = [wind_cap * system.wind_cf[h] + solar_cap * system.solar_cf[h] for h in 1:T]

    results = Vector{DispatchResult}(undef, n_scen)
    obj_vals = Vector{Float64}(undef, n_scen)
    statuses = Vector{String}(undef, n_scen)

    for s in 1:n_scen
        t_start = time()
        A = Int8.(view(avail_arr, s, :, :))   # n_therm × T

        mdl = Model(opt_factory)
        set_silent(mdl)

        @variable(mdl, p[1:n_therm, 1:T]  >= 0.0)
        @variable(mdl, load_shed[1:T]      >= 0.0)
        @variable(mdl, curtailment[1:T]    >= 0.0)

        if n_stor > 0
            @variable(mdl, charge[1:n_stor, 1:T]       >= 0.0)
            @variable(mdl, discharge_s[1:n_stor, 1:T]  >= 0.0)
            @variable(mdl, soc_var[1:n_stor, 1:T]      >= 0.0)
        end

        for g in 1:n_therm, h in 1:T
            @constraint(mdl, p[g, h] <= A[g, h] * pmax[g])
        end

        if n_stor > 0
            for st in 1:n_stor
                @constraint(mdl, [h=1:T], charge[st, h]      <= pow_mw[st])
                @constraint(mdl, [h=1:T], discharge_s[st, h] <= pow_mw[st])
                @constraint(mdl, [h=1:T], soc_var[st, h]     <= eng_mwh[st])
                @constraint(mdl,
                    soc_var[st, 1] == soc0[st] + eta_ch[st]*charge[st,1]
                                     - discharge_s[st,1]/eta_dis[st])
                for h in 2:T
                    @constraint(mdl,
                        soc_var[st, h] == soc_var[st, h-1] + eta_ch[st]*charge[st,h]
                                         - discharge_s[st,h]/eta_dis[st])
                end
                if config.cyclic_soc
                    @constraint(mdl, soc_var[st, T] == soc0[st])
                end
            end
        end

        for h in 1:T
            gen_sum = sum(p[g, h] for g in 1:n_therm; init=AffExpr(0.0))
            if n_stor > 0
                stor_net = sum(discharge_s[st, h] - charge[st, h]
                               for st in 1:n_stor; init=AffExpr(0.0))
                @constraint(mdl, gen_sum + p_vre[h] + stor_net +
                                 load_shed[h] - curtailment[h] == system.load_mw[h])
            else
                @constraint(mdl, gen_sum + p_vre[h] +
                                 load_shed[h] - curtailment[h] == system.load_mw[h])
            end
        end

        obj = JuMP.AffExpr(0.0)
        for h in 1:T
            for g in 1:n_therm
                JuMP.add_to_expression!(obj, var_cost[g], p[g, h])
            end
            JuMP.add_to_expression!(obj, VOLL, load_shed[h])
        end
        if n_stor > 0
            stor_cost = s_vcost .+ cyc_cc
            for h in 1:T, st in 1:n_stor
                JuMP.add_to_expression!(obj, stor_cost[st], charge[st, h])
                JuMP.add_to_expression!(obj, stor_cost[st], discharge_s[st, h])
            end
        end
        @objective(mdl, Min, obj)

        optimize!(mdl)

        status = termination_status(mdl)
        statuses[s] = string(status)
        if status ∉ (MOI.OPTIMAL, MOI.LOCALLY_SOLVED)
            @warn "M3 scenario=$s: solver status $status"
        end

        ls_vec  = max.(0.0, value.(load_shed))
        cur_vec = max.(0.0, value.(curtailment))
        rt      = time() - t_start
        obj_vals[s] = objective_value(mdl)

        if n_stor > 0
            dis_vec = vec(sum(max.(0.0, value.(discharge_s)), dims=1))
            chg_vec = vec(sum(max.(0.0, value.(charge)),      dims=1))
            soc_vec = vec(value.(soc_var[1, :]))
        else
            dis_vec = zeros(T); chg_vec = zeros(T); soc_vec = zeros(T)
        end

        results[s] = DispatchResult(s, ls_vec, dis_vec, chg_vec, soc_vec,
                                    nothing, cur_vec, rt)
    end
    return results, obj_vals, statuses
end

# ── event-shape helper ────────────────────────────────────────────────────────
function compute_event_shape(results::Vector{DispatchResult}, T::Int)
    events_per_scen = Int[]
    all_durations   = Int[]
    max_shortfalls  = Float64[]

    for r in results
        ls = r.load_shed
        n_ev = 0; ev_len = 0; in_ev = false; max_sf = 0.0
        ev_durations = Int[]
        for h in 1:T
            if ls[h] > 0.0
                max_sf = max(max_sf, ls[h])
                if !in_ev
                    in_ev = true; ev_len = 1
                else
                    ev_len += 1
                end
            else
                if in_ev
                    n_ev += 1
                    push!(ev_durations, ev_len)
                    in_ev = false; ev_len = 0
                end
            end
        end
        if in_ev
            n_ev += 1
            push!(ev_durations, ev_len)
        end
        push!(events_per_scen, n_ev)
        push!(max_shortfalls, max_sf)
        append!(all_durations, ev_durations)
    end
    return (
        events_per_year  = mean(events_per_scen),
        mean_duration_h  = isempty(all_durations) ? 0.0 : mean(Float64.(all_durations)),
        max_duration_h   = isempty(all_durations) ? 0   : maximum(all_durations),
        max_shortfall_mw = isempty(max_shortfalls) ? 0.0 : maximum(max_shortfalls),
    )
end

# ── helper to find containing window (for disputed-hour diagnostics) ──────────
function find_window(h::Int, windows::Vector{Tuple{Int,Int}})
    for (ws, we) in windows
        if ws <= h <= we
            return (ws, we, true)
        end
    end
    return (-1, -1, false)
end

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: Gurobi M2 event-shape
# ─────────────────────────────────────────────────────────────────────────────
println("\n", "="^72)
println("PART 1: Gurobi M2 event-shape statistics")
println("="^72)

shape_rows = DataFrame(
    portfolio=String[], solver=String[],
    lolh=Float64[], events_per_year=Float64[],
    mean_duration_h=Float64[], max_duration_h=Int[],
    max_shortfall_mw=Float64[], eue_mwh=Float64[],
)

for cname in CASES
    println("\n── Portfolio: $cname ──")
    sys  = load_system_data(joinpath(DATA_ROOT, cname))
    scen = generate_scenarios(sys, cfg)
    avail = scen.availability

    println("  Running M2 Gurobi …")
    t0 = time()
    res_g = run_m2_opt_full(sys, avail, cfg;
                opt_factory = () -> Gurobi.Optimizer(gurobi_env))
    @printf("    done in %.1f s\n", time()-t0)

    lolh_g = mean(count(x -> x > 0.0, r.load_shed) for r in res_g)
    eue_g  = mean(sum(r.load_shed) for r in res_g)
    shp_g  = compute_event_shape(res_g, sys.n_hours)

    @printf("  Gurobi M2: LOLH=%.4f h/yr  EUE=%.4f MWh\n", lolh_g, eue_g)
    @printf("    events/yr=%.2f  mean_dur=%.2f h  max_dur=%d h  max_sf=%.1f MW\n",
            shp_g.events_per_year, shp_g.mean_duration_h,
            shp_g.max_duration_h, shp_g.max_shortfall_mw)

    push!(shape_rows, (cname, "Gurobi",
          lolh_g, shp_g.events_per_year, shp_g.mean_duration_h,
          shp_g.max_duration_h, shp_g.max_shortfall_mw, eue_g))
end

OUT_SHAPE = joinpath(REPO, "results", "paper_tables", "m2_gurobi_event_shape.csv")
CSV.write(OUT_SHAPE, shape_rows)
println("\nWrote: $OUT_SHAPE")

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: M3 HiGHS vs Gurobi
# ─────────────────────────────────────────────────────────────────────────────
println("\n", "="^72)
println("PART 2: M3 full-year ED — HiGHS vs Gurobi (N=$N)")
println("="^72)

compare_rows = DataFrame(
    portfolio=String[], scenario=Int[], solver=String[],
    eue_mwh=Float64[], lolh_h=Float64[],
    obj_value=Float64[], status=String[], runtime_s=Float64[],
)

m3_results = Dict{String, Dict{String, Vector{DispatchResult}}}()
m3_objs    = Dict{String, Dict{String, Vector{Float64}}}()

for cname in CASES
    m3_results[cname] = Dict{String, Vector{DispatchResult}}()
    m3_objs[cname]    = Dict{String, Vector{Float64}}()
    println("\n── Portfolio: $cname ──")
    sys  = load_system_data(joinpath(DATA_ROOT, cname))
    scen = generate_scenarios(sys, cfg)
    avail = scen.availability
    T = sys.n_hours

    for (solver_name, opt_f) in [
            ("Gurobi", () -> Gurobi.Optimizer(gurobi_env)),
            ("HiGHS",  HiGHS.Optimizer),
        ]
        println("  Running M3 $solver_name …")
        t0 = time()
        res, objs, stats = run_m3_param(sys, avail, cfg; opt_factory = opt_f)
        elapsed = time() - t0
        @printf("    done in %.1f s\n", elapsed)

        m3_results[cname][solver_name] = res
        m3_objs[cname][solver_name]    = objs

        lolh = mean(count(x -> x > 0.0, r.load_shed) for r in res)
        eue  = mean(sum(r.load_shed) for r in res)
        @printf("  %s M3: LOLH=%.4f h/yr  EUE=%.4f MWh\n", solver_name, lolh, eue)

        for s in 1:N
            push!(compare_rows, (
                cname, s, solver_name,
                sum(res[s].load_shed),
                Float64(count(x -> x > 0.0, res[s].load_shed)),
                objs[s], stats[s], res[s].runtime_seconds,
            ))
        end
    end
end

OUT_CMP = joinpath(REPO, "results", "paper_tables", "m3_lolh_comparison.csv")
CSV.write(OUT_CMP, compare_rows)
println("\nWrote: $OUT_CMP")

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: if M3 LOLH differs, produce disputed-hour diagnostics
# ─────────────────────────────────────────────────────────────────────────────
println("\n", "="^72)
println("PART 3: M3 LOLH comparison and disputed-hour diagnostics")
println("="^72)

m3_diag_rows = DataFrame(
    portfolio=String[], scenario=Int[], hour=Int[],
    highs_load_shed_mw=Float64[], gurobi_load_shed_mw=Float64[],
    abs_diff_mw=Float64[], dispute_type=String[],
)
m3_thresh_rows = DataFrame(
    portfolio=String[], solver=String[], threshold_mw=Float64[],
    mean_lolh=Float64[], total_eue_excluded_mwh=Float64[],
)

any_m3_dispute = Ref(false)

for cname in CASES
    sys  = load_system_data(joinpath(DATA_ROOT, cname))
    T    = sys.n_hours
    res_h = m3_results[cname]["HiGHS"]
    res_g = m3_results[cname]["Gurobi"]

    lolh_h = mean(count(x -> x > 0.0, r.load_shed) for r in res_h)
    lolh_g = mean(count(x -> x > 0.0, r.load_shed) for r in res_g)
    eue_h  = mean(sum(r.load_shed) for r in res_h)
    eue_g  = mean(sum(r.load_shed) for r in res_g)
    eue_diff = abs(eue_h - eue_g)

    @printf("\n%s:\n", cname)
    @printf("  HiGHS  LOLH=%.4f h/yr  EUE=%.6f MWh\n", lolh_h, eue_h)
    @printf("  Gurobi LOLH=%.4f h/yr  EUE=%.6f MWh\n", lolh_g, eue_g)
    @printf("  EUE diff = %.4e MWh   LOLH diff = %.4f h/yr\n", eue_diff, abs(lolh_h - lolh_g))

    if abs(lolh_h - lolh_g) < 1e-9
        println("  → LOLH identical: M3 is NOT sensitive to solver choice.")
        continue
    end

    println("  → LOLH differs: computing disputed-hour diagnostics …")
    any_m3_dispute[] = true
    disputed_sheds = Float64[]

    for s in 1:N
        h_ls = res_h[s].load_shed
        g_ls = res_g[s].load_shed
        for h in 1:T
            h_pos = h_ls[h] > 0.0
            g_pos = g_ls[h] > 0.0
            if h_pos != g_pos
                dt = h_pos ? "HiGHS_only" : "Gurobi_only"
                push!(m3_diag_rows, (
                    cname, s, h,
                    h_ls[h], g_ls[h],
                    abs(h_ls[h] - g_ls[h]),
                    dt,
                ))
                push!(disputed_sheds, max(h_ls[h], g_ls[h]))
            end
        end
    end

    if !isempty(disputed_sheds)
        @printf("  Disputed hours: %d   min=%.2e  median=%.2e  max=%.2e MW\n",
                length(disputed_sheds), minimum(disputed_sheds),
                median(disputed_sheds), maximum(disputed_sheds))
        if maximum(disputed_sheds) < 1e-6
            println("  Case A: all disputed values < 1e-6 MW (LP feasibility residuals).")
        else
            println("  Case B: disputed values include >1e-6 MW (genuine redistribution).")
        end
    end

    for thr in THRESHOLDS
        lolh_ht = mean(count(x -> x > thr, r.load_shed) for r in res_h)
        lolh_gt = mean(count(x -> x > thr, r.load_shed) for r in res_g)
        excl_h  = sum(ls for s in 1:N for ls in res_h[s].load_shed
                       if 0.0 < ls <= thr; init=0.0)
        excl_g  = sum(ls for s in 1:N for ls in res_g[s].load_shed
                       if 0.0 < ls <= thr; init=0.0)
        push!(m3_thresh_rows, (cname, "HiGHS",  thr, lolh_ht, excl_h))
        push!(m3_thresh_rows, (cname, "Gurobi", thr, lolh_gt, excl_g))
    end
end

if any_m3_dispute[]
    OUT_MDIAG  = joinpath(REPO, "results", "paper_tables", "m3_lolh_solver_diagnostics.csv")
    OUT_MTHRESH = joinpath(REPO, "results", "paper_tables", "m3_lolh_threshold_sensitivity.csv")
    CSV.write(OUT_MDIAG,   m3_diag_rows)
    CSV.write(OUT_MTHRESH, m3_thresh_rows)
    println("\nWrote: $OUT_MDIAG")
    println("Wrote: $OUT_MTHRESH")
end

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
println("\n", "="^72)
println("SUMMARY")
println("="^72)

println("\nGurobi M2 event-shape:")
for r in eachrow(shape_rows)
    @printf("  %-22s  LOLH=%.2f h/yr  events=%.1f/yr  mean_dur=%.1f h  max_dur=%d h  max_sf=%.0f MW\n",
            r.portfolio, r.lolh, r.events_per_year, r.mean_duration_h,
            r.max_duration_h, r.max_shortfall_mw)
end

println("\nM3 LOLH comparison (N=$N):")
for cname in CASES
    rows_h = filter(r -> r.portfolio == cname && r.solver == "HiGHS",  compare_rows)
    rows_g = filter(r -> r.portfolio == cname && r.solver == "Gurobi", compare_rows)
    lolh_h = mean(rows_h.lolh_h)
    lolh_g = mean(rows_g.lolh_h)
    eue_h  = mean(rows_h.eue_mwh)
    eue_g  = mean(rows_g.eue_mwh)
    @printf("  %-22s  HiGHS LOLH=%.4f  Gurobi LOLH=%.4f  EUE diff=%.2e MWh\n",
            cname, lolh_h, lolh_g, abs(eue_h - eue_g))
end

if any_m3_dispute[]
    println("\nM3 exhibits solver-dependent LOLH (Case B confirmed or suspected).")
    println("Disputed-hour diagnostics written to paper_tables/.")
else
    println("\nM3 LOLH is solver-independent at N=$N  (no dispute detected).")
end

println("\nDone: ", Dates.now())
