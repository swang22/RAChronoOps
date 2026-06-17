"""
73_m2_lolh_diagnostics.jl

Diagnose the M2 LOLH discrepancy between HiGHS and Gurobi observed in
script 72 (5.75 vs 7.20 h/year balanced; 1.95 vs 2.25 h/year wind-heavy).

Steps
-----
1. Re-run M2 baseline (N=20, seed=42) for both portfolios under both solvers,
   capturing the full hourly load_shed vectors.
2. Identify every scenario-hour where the solvers disagree on whether
   load_shed > 0, recording full per-hour dispatch context.
3. Compute LOLH at nine thresholds (0 to 1e-3 MW) for both solvers.
4. Report: magnitude distribution of disputed load_shed values, total EUE
   in disputed hours, and smallest threshold at which the solvers agree
   without excluding materially meaningful unserved energy.

Outputs
-------
  results/paper_tables/m2_lolh_solver_diagnostics.csv
  results/paper_tables/m2_lolh_threshold_sensitivity.csv
"""

using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using RAChronoOps, Statistics, Printf, DataFrames, CSV, Dates
using HiGHS, Gurobi
import MathOptInterface as MOI

REPO      = abspath(joinpath(@__DIR__, ".."))
DATA_ROOT = joinpath(REPO, "data_processed", "cases")
OUT_DIAG  = joinpath(REPO, "results", "paper_tables", "m2_lolh_solver_diagnostics.csv")
OUT_THRESH= joinpath(REPO, "results", "paper_tables", "m2_lolh_threshold_sensitivity.csv")

CASES  = ["VRE120_base", "VRE120_wind_hvy"]
N      = 20
SEED   = 42
M2_RISK= 1000.0; M2_BUF = 48; M2_GAP = 24; M2_MIN = 24

THRESHOLDS = [0.0, 1e-10, 1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3]

println("="^72)
println("M2 LOLH Diagnostics: HiGHS vs Gurobi")
println("Date: ", Dates.now())
println("="^72)

cfg = SimConfig(n_scenarios=N, seed=SEED,
                risk_margin_mw=M2_RISK,
                window_buffer_hours=M2_BUF,
                merge_gap_hours=M2_GAP,
                min_window_length_hours=M2_MIN)

gurobi_env = Gurobi.Env()

# ── Reuse run_m2_opt from script 72 (inlined here to be self-contained) ───
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

    results  = Vector{DispatchResult}(undef, n_scen)
    win_data = Vector{Vector{Tuple{Int,Int}}}(undef, n_scen)
    therm_avail_all = Matrix{Float64}(undef, n_scen, T)

    for s in 1:n_scen
        ta = [sum(pmax[g] * avail_arr[s, g, h] for g in 1:n_therm) for h in 1:T]
        therm_avail_all[s, :] = ta
        margin  = ta .+ p_vre .- sys.load_mw
        windows = RAChronoOps.build_risk_windows(margin, T,
                      config.risk_margin_mw, config.window_buffer_hours,
                      config.merge_gap_hours, config.min_window_length_hours)
        win_data[s] = windows

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
    return results, win_data, therm_avail_all, p_vre
end

# ── helper: for a given scenario-hour, find the containing window ──────────
function find_window(h::Int, windows::Vector{Tuple{Int,Int}})
    for (ws, we) in windows
        if ws <= h <= we
            return (ws, we, true)
        end
    end
    return (-1, -1, false)
end

# ── main ──────────────────────────────────────────────────────────────────
diag_rows  = DataFrame(
    portfolio=String[], scenario=Int[], hour=Int[],
    highs_load_shed_mw=Float64[], gurobi_load_shed_mw=Float64[],
    abs_diff_mw=Float64[],
    thermal_avail_mw=Float64[], vre_output_mw=Float64[], load_mw=Float64[],
    highs_storage_discharge_mw=Float64[], highs_storage_charge_mw=Float64[],
    highs_soc_mwh=Float64[],
    gurobi_storage_discharge_mw=Float64[], gurobi_storage_charge_mw=Float64[],
    gurobi_soc_mwh=Float64[],
    window_start=Int[], window_end=Int[], inside_window=Bool[],
    dispute_type=String[],
)

thresh_rows = DataFrame(
    portfolio=String[], solver=String[], threshold_mw=Float64[],
    mean_lolh=Float64[], total_positive_scenario_hours=Int[],
    total_eue_excluded_mwh=Float64[], max_excluded_hourly_shed_mw=Float64[],
)

for cname in CASES
    println("\n" * "─"^72)
    println("Portfolio: $cname")
    sys = load_system_data(joinpath(DATA_ROOT, cname))
    scen = generate_scenarios(sys, cfg)
    avail = scen.availability

    println("  Running HiGHS …")
    t0 = time()
    res_h, wins_h, ta_all, p_vre_vec = run_m2_opt_full(sys, avail, cfg;
        opt_factory = HiGHS.Optimizer)
    println("    done in $(round(time()-t0, digits=1)) s")

    println("  Running Gurobi …")
    t0 = time()
    res_g, wins_g, _,      _        = run_m2_opt_full(sys, avail, cfg;
        opt_factory = () -> Gurobi.Optimizer(gurobi_env))
    println("    done in $(round(time()-t0, digits=1)) s")

    T = sys.n_hours

    # ── disputed hours ─────────────────────────────────────────────────────
    n_disputed     = 0
    disputed_eue   = 0.0
    disputed_sheds = Float64[]

    for s in 1:N
        h_ls = res_h[s].load_shed
        g_ls = res_g[s].load_shed
        windows = wins_h[s]   # identical for both solvers by construction

        for h in 1:T
            h_pos = h_ls[h] > 0.0
            g_pos = g_ls[h] > 0.0
            if h_pos != g_pos
                # disagreement on whether load shedding is positive
                ws, we, in_win = find_window(h, windows)
                diff = abs(h_ls[h] - g_ls[h])
                positive_shed = max(h_ls[h], g_ls[h])
                dispute_type = h_pos ? "HiGHS_only" : "Gurobi_only"

                push!(diag_rows, (
                    cname, s, h,
                    h_ls[h], g_ls[h], diff,
                    ta_all[s, h], p_vre_vec[h], sys.load_mw[h],
                    res_h[s].storage_discharge[h], res_h[s].storage_charge[h],
                    res_h[s].soc[h],
                    res_g[s].storage_discharge[h], res_g[s].storage_charge[h],
                    res_g[s].soc[h],
                    ws, we, in_win, dispute_type,
                ))
                n_disputed += 1
                disputed_eue += positive_shed
                push!(disputed_sheds, positive_shed)
            end
        end
    end

    # ── print diagnostic summary ──────────────────────────────────────────
    @printf("  Disputed scenario-hours (one solver positive, other zero): %d\n", n_disputed)
    @printf("  Total EUE in disputed hours (max of the two):  %.4e MWh\n", disputed_eue)
    if !isempty(disputed_sheds)
        @printf("  Disputed load-shed  min=%.4e  median=%.4e  mean=%.4e  max=%.4e MW\n",
            minimum(disputed_sheds), median(disputed_sheds),
            mean(disputed_sheds), maximum(disputed_sheds))
    end

    # ── threshold sensitivity ─────────────────────────────────────────────
    println("  LOLH threshold sensitivity:")
    @printf("    %-15s  %-8s  %-8s\n", "threshold (MW)", "HiGHS", "Gurobi")
    for thr in THRESHOLDS
        lolh_h = mean(count(x -> x > thr, res_h[s].load_shed) for s in 1:N)
        lolh_g = mean(count(x -> x > thr, res_g[s].load_shed) for s in 1:N)
        scen_hrs_h = sum(count(x -> x > thr, res_h[s].load_shed) for s in 1:N)
        scen_hrs_g = sum(count(x -> x > thr, res_g[s].load_shed) for s in 1:N)
        # EUE excluded: hours that had positive shed at > 0.0 but now fall below thr
        eue_excl_h = sum(ls for s in 1:N for ls in res_h[s].load_shed
                         if 0.0 < ls <= thr; init=0.0)
        eue_excl_g = sum(ls for s in 1:N for ls in res_g[s].load_shed
                         if 0.0 < ls <= thr; init=0.0)
        max_excl_h = maximum((ls for s in 1:N for ls in res_h[s].load_shed
                               if 0.0 < ls <= thr); init=0.0)
        max_excl_g = maximum((ls for s in 1:N for ls in res_g[s].load_shed
                               if 0.0 < ls <= thr); init=0.0)
        @printf("    %-15s  %.4f   %.4f%s\n", "$(thr)",
                lolh_h, lolh_g, lolh_h ≈ lolh_g ? "  ← AGREE" : "")
        push!(thresh_rows, (cname, "HiGHS",  thr, lolh_h, scen_hrs_h, eue_excl_h, max_excl_h))
        push!(thresh_rows, (cname, "Gurobi", thr, lolh_g, scen_hrs_g, eue_excl_g, max_excl_g))
    end
end

# ── write outputs ─────────────────────────────────────────────────────────
println("\nWriting: $OUT_DIAG")
CSV.write(OUT_DIAG, diag_rows)
println("Writing: $OUT_THRESH")
CSV.write(OUT_THRESH, thresh_rows)

# ── summary assessment ─────────────────────────────────────────────────────
println("\n" * "="^72)
println("SUMMARY ASSESSMENT")
println("="^72)

if nrow(diag_rows) > 0
    max_disputed_shed = maximum(diag_rows.abs_diff_mw)
    total_disputed_eue = sum(max.(diag_rows.highs_load_shed_mw,
                                   diag_rows.gurobi_load_shed_mw))
    @printf("Total disputed scenario-hours:  %d\n", nrow(diag_rows))
    @printf("Max disputed hourly load shed:  %.4e MW\n", max_disputed_shed)
    @printf("Total EUE in disputed hours:    %.4e MWh\n", total_disputed_eue)

    # Find smallest threshold at which HiGHS and Gurobi agree for ALL cases
    for thr in THRESHOLDS
        agree_all = true
        for cname in CASES
            hrows = filter(r -> r.portfolio == cname && r.solver == "HiGHS",  thresh_rows)
            grows = filter(r -> r.portfolio == cname && r.solver == "Gurobi", thresh_rows)
            lh = first(filter(r -> r.threshold_mw == thr, hrows)).mean_lolh
            lg = first(filter(r -> r.threshold_mw == thr, grows)).mean_lolh
            if !(lh ≈ lg)
                agree_all = false
                break
            end
        end
        if agree_all
            @printf("Solvers agree at threshold:     %.1e MW\n", thr)
            excl = maximum(thresh_rows.total_eue_excluded_mwh[thresh_rows.threshold_mw .== thr])
            @printf("Max EUE excluded at this thr:   %.4e MWh\n", excl)
            max_excl_h = maximum(thresh_rows.max_excluded_hourly_shed_mw[
                                  (thresh_rows.threshold_mw .== thr) .& (thresh_rows.solver .== "HiGHS")])
            max_excl_g = maximum(thresh_rows.max_excluded_hourly_shed_mw[
                                  (thresh_rows.threshold_mw .== thr) .& (thresh_rows.solver .== "Gurobi")])
            @printf("Max excluded single-hour shed:  HiGHS=%.4e MW  Gurobi=%.4e MW\n",
                    max_excl_h, max_excl_g)
            break
        end
    end

    if max_disputed_shed < 1e-6
        println("\nCase A: ALL disputed load-shed values are below 1e-6 MW.")
        println("  → LP feasibility residuals only. A numerical threshold is justified.")
    else
        println("\nCase B: At least one disputed value exceeds 1e-6 MW.")
        println("  → Nontrivial redistribution detected. Cannot claim solver independence for LOLH.")
    end
end
println("\nDone.")
