"""
72_m2_solver_regression.jl

Controlled N=20 HiGHS-vs-Gurobi solver regression for M2 event-window LP.

Inputs are identical for both solvers:
  - portfolios:  VRE120_base, VRE120_wind_hvy
  - N=20, seed=42
  - risk_margin=1000 MW, buffer=48 h, merge_gap=24 h, min_window=24 h
  - δ ∈ {1, 5, 10} MW

For each portfolio × δ the script compares per-solver:
  - baseline / storage-increment / firm-increment EUE
  - marginal CC
  - LOLH
  - event-window count and boundaries (solver-independent; verified identical)
  - per-scenario LP objective (sum of load_shed) -- reported as absolute diff

Pass criteria:
  - EUE absolute difference ≤ 1e-6 MWh
  - CC  absolute difference ≤ 1e-8
  - LOLH identical (floating-point equal)
  - window boundaries identical (by construction; confirmed)
  - LP objective max absolute difference ≤ 1e-6 MWh

Output: results/paper_tables/m2_solver_regression.csv
"""

using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using RAChronoOps, Statistics, Printf, DataFrames, CSV, Dates
using HiGHS, Gurobi, JuMP
import MathOptInterface as MOI

REPO      = abspath(joinpath(@__DIR__, ".."))
DATA_ROOT = joinpath(REPO, "data_processed", "cases")
OUT_PATH  = joinpath(REPO, "results", "paper_tables", "m2_solver_regression.csv")

CASES      = ["VRE120_base", "VRE120_wind_hvy"]
N          = 20
SEED       = 42
DELTA_MWS  = [1.0, 5.0, 10.0]
DURATION_H = 4
CYCLIC_SOC = 0.231   # initial SOC fraction

M2_RISK = 1000.0
M2_BUF  = 48
M2_GAP  = 24
M2_MIN  = 24

EUE_TOL = 1e-6   # MWh absolute
CC_TOL  = 1e-8   # absolute
OBJ_TOL = 1e-6   # MWh per-scenario absolute

println("="^72)
println("M2 Solver Regression: HiGHS vs Gurobi")
println("Date: ", Dates.now())
println("N=$(N), seed=$(SEED), δ=$(DELTA_MWS) MW")
println("M2: risk=$(M2_RISK) MW, buf=$(M2_BUF)h, gap=$(M2_GAP)h, min=$(M2_MIN)h")
println("Tolerances: EUE≤$(EUE_TOL) MWh, CC≤$(CC_TOL), OBJ≤$(OBJ_TOL) MWh/scen")
println("="^72)

cfg = SimConfig(n_scenarios=N, seed=SEED,
                risk_margin_mw=M2_RISK,
                window_buffer_hours=M2_BUF,
                merge_gap_hours=M2_GAP,
                min_window_length_hours=M2_MIN)

gurobi_env = Gurobi.Env()

# ── run M2 with a chosen optimizer factory; mirrors run_m2_with_diagnostics ──
function run_m2_opt(sys, avail_arr, config; opt_factory)
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

    for s in 1:n_scen
        therm_avail = [sum(pmax[g] * avail_arr[s, g, h] for g in 1:n_therm) for h in 1:T]
        margin  = therm_avail .+ p_vre .- sys.load_mw
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
                    h_cursor, ws - 1, therm_avail, p_vre, sys.load_mw, net_load,
                    high_nl_thresh, charge_nl_thresh,
                    total_power, total_energy, eta_ch, eta_dis, soc_floor,
                    curr_soc, load_shed, st_dis, st_chg, soc_arr, curtailmt)
            end
            final_soc, ok = RAChronoOps._solve_window_lp!(
                ws, we, therm_avail, p_vre, sys.load_mw,
                total_power, total_energy, eta_ch, eta_dis, curr_soc,
                config.voll, config.epsilon_cycling,
                load_shed, st_dis, st_chg, soc_arr, curtailmt;
                optimizer_factory = opt_factory)
            curr_soc = ok ? final_soc :
                RAChronoOps._ra1b_segment!(
                    ws, we, therm_avail, p_vre, sys.load_mw, net_load,
                    high_nl_thresh, charge_nl_thresh,
                    total_power, total_energy, eta_ch, eta_dis, soc_floor,
                    curr_soc, load_shed, st_dis, st_chg, soc_arr, curtailmt)
            h_cursor = we + 1
        end
        if h_cursor <= T
            RAChronoOps._ra1b_segment!(
                h_cursor, T, therm_avail, p_vre, sys.load_mw, net_load,
                high_nl_thresh, charge_nl_thresh,
                total_power, total_energy, eta_ch, eta_dis, soc_floor,
                curr_soc, load_shed, st_dis, st_chg, soc_arr, curtailmt)
        end
        results[s] = DispatchResult(s, load_shed, st_dis, st_chg, soc_arr,
                                    nothing, curtailmt, 0.0)
    end
    return results, win_data
end

function mean_eue(results)
    return mean(sum(r.load_shed) for r in results)
end
function mean_lolh(results)
    return mean(count(x -> x > 0.0, r.load_shed) for r in results)
end
function per_scenario_obj(results)
    return [sum(r.load_shed) for r in results]
end
function marginal_cc(eue_base, eue_stor, eue_firm)
    denom = eue_base - eue_firm
    return denom > 1e-9 ? (eue_base - eue_stor) / denom : NaN
end

function extend_avail_firm(avail::Array{<:Integer, 3})
    n_s, _, T = size(avail)
    return cat(avail, ones(Int8, n_s, 1, T); dims=2)
end

function firm_system(sys_base::SystemData, delta_mw::Float64)
    gens = copy(sys_base.generators)
    for col in names(gens)
        if eltype(gens[!, col]) <: AbstractString
            gens[!, col] = String.(gens[!, col])
        end
    end
    perf = copy(gens[1:1, :])
    perf[1, :gen_id]                 = "PERFECT_$(delta_mw)MW"
    perf[1, :gen_type]               = "PerfectFirm"
    perf[1, :fuel]                   = "Other"
    perf[1, :pmax_mw]                = delta_mw
    perf[1, :pmin_mw]                = 0.0
    perf[1, :variable_cost_per_mwh]  = 0.0
    perf[1, :forced_outage_rate]     = 0.0
    perf[1, :mean_repair_time_hours] = 0.0
    perf[1, :is_thermal]             = 1
    perf[1, :is_vre]                 = 0
    perf[1, :vre_type]               = ""
    return SystemData(vcat(gens, perf), sys_base.storage,
                      sys_base.load_mw, sys_base.wind_cf, sys_base.solar_cf,
                      sys_base.n_hours)
end

function stor_system(sys_base::SystemData, delta_mw::Float64)
    eta = sqrt(0.90)
    extra = DataFrame(
        storage_id            = ["MARG_$(delta_mw)MW"],
        power_mw              = [delta_mw],
        energy_mwh            = [delta_mw * DURATION_H],
        charge_efficiency     = [eta],
        discharge_efficiency  = [eta],
        variable_cost_per_mwh = [0.01],
        initial_soc_mwh       = [delta_mw * DURATION_H * CYCLIC_SOC],
    )
    return SystemData(sys_base.generators, vcat(sys_base.storage, extra),
                      sys_base.load_mw, sys_base.wind_cf, sys_base.solar_cf,
                      sys_base.n_hours)
end

# ── main ──────────────────────────────────────────────────────────────────
reg_rows = DataFrame(
    portfolio          = String[],
    delta_mw           = Float64[],
    eue_base_highs     = Float64[],
    eue_base_gurobi    = Float64[],
    eue_base_absdiff   = Float64[],
    eue_stor_highs     = Float64[],
    eue_stor_gurobi    = Float64[],
    eue_stor_absdiff   = Float64[],
    eue_firm_highs     = Float64[],
    eue_firm_gurobi    = Float64[],
    eue_firm_absdiff   = Float64[],
    cc_highs           = Float64[],
    cc_gurobi          = Float64[],
    cc_absdiff         = Float64[],
    lolh_base_highs    = Float64[],
    lolh_base_gurobi   = Float64[],
    lolh_match         = Bool[],
    windows_identical  = Bool[],
    lp_obj_max_absdiff = Float64[],
    eue_pass           = Bool[],
    cc_pass            = Bool[],
    lolh_pass          = Bool[],
    obj_pass           = Bool[],
    overall_pass       = Bool[],
)

solvers = [
    ("HiGHS",  HiGHS.Optimizer),
    ("Gurobi", () -> Gurobi.Optimizer(gurobi_env)),
]

for cname in CASES
    println("\n" * "─"^72)
    println("Portfolio: $cname")
    sys_base = load_system_data(joinpath(DATA_ROOT, cname))
    scen     = generate_scenarios(sys_base, cfg)
    avail    = scen.availability
    avail_f  = extend_avail_firm(avail)   # shared across δ (perfect firm is 1 unit)

    for δ in DELTA_MWS
        @printf("  δ = %.0f MW\n", δ)
        sys_s = stor_system(sys_base, δ)
        sys_f = firm_system(sys_base, δ)

        res = Dict{String, NamedTuple}()
        for (sname, ofac) in solvers
            @printf("    %-8s … ", sname)
            t0 = time()
            r_base, w_base = run_m2_opt(sys_base, avail,   cfg; opt_factory=ofac)
            r_stor, _      = run_m2_opt(sys_s,    avail,   cfg; opt_factory=ofac)
            r_firm, _      = run_m2_opt(sys_f,    avail_f, cfg; opt_factory=ofac)
            elapsed = time() - t0

            eb = mean_eue(r_base)
            es = mean_eue(r_stor)
            ef = mean_eue(r_firm)
            cc = marginal_cc(eb, es, ef)
            lh = mean_lolh(r_base)
            n_wins   = mean(length(w) for w in w_base)
            tot_wh   = mean(isempty(w) ? 0 : sum(we - ws + 1 for (ws,we) in w) for w in w_base)

            @printf("EUE=%.4f  CC=%.6f  LOLH=%.2f  wins=%.1f/scen  (%.1f s)\n",
                    eb, cc, lh, n_wins, elapsed)
            res[sname] = (r_base=r_base, w_base=w_base,
                          eue_base=eb, eue_stor=es, eue_firm=ef, cc=cc, lolh=lh,
                          n_wins=n_wins, tot_wh=tot_wh)
        end

        h = res["HiGHS"]
        g = res["Gurobi"]

        eue_b_diff = abs(h.eue_base - g.eue_base)
        eue_s_diff = abs(h.eue_stor - g.eue_stor)
        eue_f_diff = abs(h.eue_firm - g.eue_firm)
        cc_diff    = abs(h.cc - g.cc)
        lolh_match = h.lolh == g.lolh

        # Window boundary identity (solver-independent by construction)
        wins_id = all(h.w_base[i] == g.w_base[i] for i in 1:N)

        # Per-scenario LP objective (≈ EUE per scenario under VOLL=1)
        obj_h = per_scenario_obj(h.r_base)
        obj_g = per_scenario_obj(g.r_base)
        obj_max_adiff = maximum(abs(obj_h[i] - obj_g[i]) for i in 1:N)

        eue_pass  = eue_b_diff ≤ EUE_TOL && eue_s_diff ≤ EUE_TOL && eue_f_diff ≤ EUE_TOL
        cc_pass   = cc_diff ≤ CC_TOL
        lolh_pass = lolh_match
        obj_pass  = obj_max_adiff ≤ OBJ_TOL
        overall   = eue_pass && cc_pass && lolh_pass && obj_pass

        @printf("\n  [%s | δ=%.0f MW]  HiGHS vs Gurobi:\n", cname, δ)
        @printf("    EUE_base diff : %.2e MWh  %s\n", eue_b_diff, eue_b_diff ≤ EUE_TOL ? "PASS" : "FAIL")
        @printf("    EUE_stor diff : %.2e MWh  %s\n", eue_s_diff, eue_s_diff ≤ EUE_TOL ? "PASS" : "FAIL")
        @printf("    EUE_firm diff : %.2e MWh  %s\n", eue_f_diff, eue_f_diff ≤ EUE_TOL ? "PASS" : "FAIL")
        @printf("    CC diff       : %.2e      %s\n", cc_diff,    cc_pass  ? "PASS" : "FAIL")
        @printf("    LOLH match    : %s          %s\n", string(lolh_match), lolh_pass ? "PASS" : "FAIL")
        @printf("    Wins identical: %s          PASS (solver-indep.)\n", string(wins_id))
        @printf("    LP obj max abs: %.2e MWh  %s\n", obj_max_adiff, obj_pass ? "PASS" : "FAIL")
        @printf("    OVERALL       : %s\n", overall ? "PASS ✓" : "FAIL ✗")

        push!(reg_rows, (cname, δ,
            h.eue_base, g.eue_base, eue_b_diff,
            h.eue_stor, g.eue_stor, eue_s_diff,
            h.eue_firm, g.eue_firm, eue_f_diff,
            h.cc,       g.cc,       cc_diff,
            h.lolh,     g.lolh,     lolh_match,
            wins_id,    obj_max_adiff,
            eue_pass, cc_pass, lolh_pass, obj_pass, overall))
    end
end

println("\n" * "="^72)
println("SUMMARY")
println("="^72)
all_pass = all(reg_rows.overall_pass)
@printf("Overall regression: %s\n", all_pass ? "ALL PASS ✓" : "SOME FAIL ✗")
for r in eachrow(reg_rows)
    @printf("  %-20s δ=%4.0f  EUE:%s CC:%s LOLH:%s OBJ:%s  → %s\n",
            r.portfolio, r.delta_mw,
            r.eue_pass  ? "✓" : "✗",
            r.cc_pass   ? "✓" : "✗",
            r.lolh_pass ? "✓" : "✗",
            r.obj_pass  ? "✓" : "✗",
            r.overall_pass ? "PASS" : "FAIL")
end

println("\nWriting: $OUT_PATH")
CSV.write(OUT_PATH, reg_rows)
println("Done.")
