"""
scripts/40_build_paper_result_tables.jl

Consolidate scattered experiment result CSVs into paper-ready tables.
No models are rerun; inputs are committed result files only.

Outputs (results/paper_tables/):
  paper_model_hierarchy.csv
  paper_no_storage_validation.csv
  paper_storage_method_comparison.csv
  paper_sufficiency_bound.csv
  paper_hope_validation.csv
  paper_runtime_accuracy.csv
  summary.txt
"""

using DataFrames, CSV, Statistics, Dates

const PROJ_DIR  = joinpath(@__DIR__, "..")
const RESULTS   = joinpath(PROJ_DIR, "results")
const OUT_DIR   = joinpath(RESULTS, "paper_tables")

mkpath(OUT_DIR)

# ── logging helpers ───────────────────────────────────────────────────────────

const WARNINGS  = String[]
const COLLECTED = String[]

function warn!(msg::String)
    push!(WARNINGS, msg)
    @warn msg
end

function note!(msg::String)
    push!(COLLECTED, msg)
end

# ── file I/O helpers ──────────────────────────────────────────────────────────

function try_read(path::String; label::String = "")::Union{DataFrame, Nothing}
    if isfile(path)
        df = CSV.read(path, DataFrame; missingstring = ["", "NA", "NaN"])
        src = isempty(label) ? dirname(path) : label
        note!("Loaded $(basename(path)) from $src ($(nrow(df)) rows)")
        return df
    else
        warn!("MISSING: $path")
        return nothing
    end
end

# ── normalisation helpers ─────────────────────────────────────────────────────

function norm_cols!(df::DataFrame, n_scen::Int)::DataFrame
    # n_scenarios
    hasproperty(df, :n_scenarios) || (df[!, :n_scenarios] .= n_scen)

    # lolh: vre_method_comparison uses lolh_hours
    if !hasproperty(df, :lolh) && hasproperty(df, :lolh_hours)
        df[!, :lolh] = df[!, :lolh_hours]
    end

    # case column: full_model_comparison base files omit it
    if !hasproperty(df, :case) && hasproperty(df, :case_name)
        df[!, :case] = df[!, :case_name]
    end

    # mean_runtime_s: harmonise across file schemas
    if !hasproperty(df, :mean_runtime_s)
        if hasproperty(df, :mean_runtime_per_scenario_s)
            df[!, :mean_runtime_s] = df[!, :mean_runtime_per_scenario_s]
        elseif hasproperty(df, :runtime_s) && hasproperty(df, :n_scenarios)
            df[!, :mean_runtime_s] = df[!, :runtime_s] ./ df[!, :n_scenarios]
        elseif hasproperty(df, :runtime_s)
            df[!, :mean_runtime_s] = df[!, :runtime_s]
        end
    end

    return df
end

function select_core(df::DataFrame, case::String, n_scen::Int)::DataFrame
    norm_cols!(df, n_scen)
    hasproperty(df, :case) || (df[!, :case] .= case)
    return df
end

# ── output helpers ────────────────────────────────────────────────────────────

function round2(x::T)::T where T <: Union{Float64, Missing}
    ismissing(x) || isnan(x) ? x : round(x; digits = 2)
end

function save_table(df::DataFrame, name::String)::String
    path = joinpath(OUT_DIR, name)
    CSV.write(path, df)
    note!("Wrote $name ($(nrow(df)) rows × $(ncol(df)) cols)")
    return path
end

# look up a scalar value from a filtered DataFrame; return NaN if not found
function lookup(df::DataFrame, col::Symbol, filters::Pair...)::Float64
    sub = df
    for (c, v) in filters
        sub = filter(r -> r[c] == v, sub)
    end
    isempty(sub) ? NaN : Float64(first(sub)[col])
end

# ── sort helper (avoids `order()` which requires explicit import) ─────────────

function sort_by_model!(df::DataFrame, order_vec::Vector{String})
    df[!, :sort_key] = [something(findfirst(==(m), order_vec), 99) for m in df.model]
    sort!(df, [:case, :sort_key])
    select!(df, Not(:sort_key))
    return df
end

# ─────────────────────────────────────────────────────────────────────────────
# TABLE 1 — Model hierarchy (static, hand-coded from documentation)
# ─────────────────────────────────────────────────────────────────────────────

function build_model_hierarchy()::DataFrame
    entries = [
        ("MC-NoStorage", "Classical MC",     "No",  "None",           "Hourly capacity check (no SOC)",             "No-storage baseline",            "main"),
        ("M1",           "RA-1a",            "Yes", "Heuristic",      "Naive 3-priority peak-shaving",              "Cautionary failure case",        "main"),
        ("M1b",          "RA-1b",            "Yes", "Heuristic",      "Reserve-aware heuristic (SOC floor)",        "Improved heuristic",             "main"),
        ("M1c",          "RA-1c",            "Yes", "Heuristic",      "Emergency-only discharge, surplus charging", "Near-benchmark simple model",    "main"),
        ("M1d_earliest", "RA-1d (earliest)", "Yes", "Heuristic",      "Risk-hour allocation, earliest-first",       "Within-event allocation study",  "appendix"),
        ("M1d_largest",  "RA-1d (largest)",  "Yes", "Heuristic",      "Risk-hour allocation, largest-first",        "Within-event allocation study",  "appendix"),
        ("M2",           "RA-2",             "Yes", "LP (windowed)",  "Event-window LP (rm=1000 MW, buf=48 h)",     "Proposed hybrid method",         "main"),
        ("M3",           "RA-3",             "Yes", "LP (full year)", "Full-year economic dispatch LP",             "LP reliability benchmark",       "main"),
        ("HOPE-ED",      "HOPE-ED",          "Yes", "LP (full year)", "Full-year HOPE economic dispatch LP",        "HOPE mapping validation",        "main"),
        ("HOPE-UC",      "HOPE-UC / M4",     "Yes", "MILP (full yr)", "Full-year HOPE unit commitment MILP",        "High-fidelity UC benchmark",     "main"),
    ]
    df = DataFrame(
        model             = [e[1] for e in entries],
        label             = [e[2] for e in entries],
        storage           = [e[3] for e in entries],
        optimization_type = [e[4] for e in entries],
        temporal_detail   = [e[5] for e in entries],
        benchmark_role    = [e[6] for e in entries],
        main_or_appendix  = [e[7] for e in entries],
    )
    save_table(df, "paper_model_hierarchy.csv")
    return df
end

# ─────────────────────────────────────────────────────────────────────────────
# TABLE 2 — No-storage validation
# ─────────────────────────────────────────────────────────────────────────────

function build_no_storage_validation()::Union{DataFrame, Nothing}
    parts = DataFrame[]

    # Panel A: N=20, VRE120_base and VRE120_wind_hvy
    p20 = try_read(
        joinpath(RESULTS, "no_storage_comparison", "no_storage_aggregate_metrics.csv");
        label = "no_storage_comparison (N=20)")
    if !isnothing(p20)
        p20 = select_core(p20, "", 20)
        push!(parts, filter(r -> r.model in ("MC-NoStorage", "M3-NoStorage"), p20))
    end

    # Panel B: N=5, VRE120_base_nostorage — four-model HOPE-UC check
    p5 = try_read(
        joinpath(RESULTS, "nostorage_hope_uc_comparison", "base_n5",
                 "all_model_aggregate_metrics.csv");
        label = "nostorage_hope_uc_comparison/base_n5 (N=5)")
    if !isnothing(p5)
        p5 = select_core(p5, "VRE120_base_nostorage", 5)
        push!(parts, p5)
    end

    isempty(parts) && (warn!("TABLE 2 (no-storage validation): all source files missing — skipped"); return nothing)

    combined = vcat(parts...; cols = :union)
    wanted   = [:case, :n_scenarios, :model, :lolh, :eue_mwh, :cvar_eue_mwh, :mean_runtime_s]
    out      = select(combined, intersect(wanted, propertynames(combined)))
    for c in [:lolh, :eue_mwh, :cvar_eue_mwh, :mean_runtime_s]
        hasproperty(out, c) && (out[!, c] = round2.(out[!, c]))
    end
    save_table(out, "paper_no_storage_validation.csv")
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# TABLE 3 — Storage-aware method comparison
# ─────────────────────────────────────────────────────────────────────────────

function build_storage_method_comparison()::Union{DataFrame, Nothing}
    parts = DataFrame[]

    # VRE120_base: M1, M1b, M1c, M2, M3 at N=20 (full_model_comparison/base_n20)
    base20 = try_read(
        joinpath(RESULTS, "full_model_comparison_with_hope", "base_n20",
                 "all_model_aggregate_metrics.csv");
        label = "full_model_comparison_with_hope/base_n20")
    if !isnothing(base20)
        base20 = select_core(base20, "VRE120_base", 20)
        push!(parts, filter(r -> r.model in ("M1", "M1b", "M1c", "M2", "M3"), base20))
    end

    # VRE120_base + VRE120_wind_hvy: M1c, M1d_earliest, M1d_largest, M2, M3 at N=20
    m1d = try_read(
        joinpath(RESULTS, "m1d_storage_heuristic_comparison", "m1d_aggregate_metrics.csv");
        label = "m1d_storage_heuristic_comparison (N=20)")
    if !isnothing(m1d)
        m1d = select_core(m1d, "", 20)
        hasproperty(m1d, :case) || warn!("m1d_aggregate_metrics.csv: missing 'case' column")
        # add wind_hvy rows and the M1d rows (base M1c/M2/M3 already in base20)
        push!(parts, filter(r -> r.case == "VRE120_wind_hvy" ||
                                 r.model in ("M1d_earliest", "M1d_largest"), m1d))
    end

    # VRE120_wind_hvy: M1, M1b at N=3 (only available sample size)
    vmc = try_read(
        joinpath(RESULTS, "vre_method_comparison", "vre_method_comparison_results.csv");
        label = "vre_method_comparison (M1/M1b pilot N=3)")
    if !isnothing(vmc)
        norm_cols!(vmc, 3)
        hasproperty(vmc, :case) || (vmc[!, :case] = vmc[!, :case_name])
        push!(parts, filter(r -> r.model in ("M1", "M1b") && r.case == "VRE120_wind_hvy", vmc))
    end

    isempty(parts) && (warn!("TABLE 3 (storage method comparison): all source files missing — skipped"); return nothing)

    combined = vcat(parts...; cols = :union)

    # de-duplicate: keep higher-N run for same case+model
    sort!(combined, [:case, :model, :n_scenarios]; rev = [false, false, true])
    unique!(combined, [:case, :model])

    # build M3 reference lookup once
    m3_rows = filter(r -> r.model == "M3", combined)
    m3_lolh = Dict(String(r.case) => r.lolh         for r in eachrow(m3_rows))
    m3_eue  = Dict(String(r.case) => r.eue_mwh      for r in eachrow(m3_rows))
    m3_rt   = Dict(String(r.case) => r.mean_runtime_s for r in eachrow(m3_rows))

    combined[!, :eue_error_vs_m3]  = [r.eue_mwh - get(m3_eue,  String(r.case), NaN) for r in eachrow(combined)]
    combined[!, :lolh_error_vs_m3] = [r.lolh    - get(m3_lolh, String(r.case), NaN) for r in eachrow(combined)]
    combined[!, :runtime_ratio_vs_m3] = [
        let rt_model = r.mean_runtime_s
            rt_m3    = get(m3_rt, String(r.case), NaN)
            (ismissing(rt_model) || isnan(rt_model) || isnan(rt_m3) || rt_model == 0.0) ? NaN :
                round(rt_m3 / rt_model; digits = 1)
        end
        for r in eachrow(combined)
    ]

    sort_by_model!(combined, ["M1", "M1b", "M1c", "M1d_earliest", "M1d_largest", "M2", "M3"])

    wanted   = [:case, :n_scenarios, :model, :lolh, :eue_mwh, :cvar_eue_mwh,
                :mean_runtime_s, :eue_error_vs_m3, :lolh_error_vs_m3, :runtime_ratio_vs_m3]
    out      = select(combined, intersect(wanted, propertynames(combined)))
    for c in [:lolh, :eue_mwh, :cvar_eue_mwh, :mean_runtime_s, :eue_error_vs_m3, :lolh_error_vs_m3]
        hasproperty(out, c) && (out[!, c] = round2.(out[!, c]))
    end
    save_table(out, "paper_storage_method_comparison.csv")
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# TABLE 4 — Storage-energy sufficiency bound
# ─────────────────────────────────────────────────────────────────────────────

function build_sufficiency_bound()::Union{DataFrame, Nothing}
    bvm = try_read(
        joinpath(RESULTS, "storage_energy_sufficiency_bound", "bound_vs_models.csv");
        label = "storage_energy_sufficiency_bound")
    isnothing(bvm) && (warn!("TABLE 4 (sufficiency bound): bound_vs_models.csv missing — skipped"); return nothing)

    agg = combine(groupby(bvm, :case),
        :pre_storage_eue_mwh       => mean => :pre_storage_eue_mwh,
        :residual_eue_bound_mwh    => mean => :bound_residual_eue_mwh,
        :m3_eue_mwh                => mean => :m3_eue_mwh,
        :bound_minus_m3_mwh        => mean => :bound_minus_m3_mwh,
        :storage_sufficiency_ratio => mean => :storage_sufficiency_ratio,
        nrow                       => :n_scenarios,
    )
    agg[!, :seed]       .= 42
    agg[!, :lookback_h] .= 72

    for c in [:pre_storage_eue_mwh, :bound_residual_eue_mwh, :m3_eue_mwh,
              :bound_minus_m3_mwh, :storage_sufficiency_ratio]
        agg[!, c] = round2.(agg[!, c])
    end

    out = select(agg, [:case, :n_scenarios, :seed, :lookback_h,
                        :pre_storage_eue_mwh, :bound_residual_eue_mwh,
                        :m3_eue_mwh, :bound_minus_m3_mwh, :storage_sufficiency_ratio])
    save_table(out, "paper_sufficiency_bound.csv")
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# TABLE 5 — HOPE validation
# ─────────────────────────────────────────────────────────────────────────────

function build_hope_validation()::Union{DataFrame, Nothing}
    parts = DataFrame[]

    # VRE120_base N=20: all models including HOPE-ED, HOPE-UC
    base20 = try_read(
        joinpath(RESULTS, "full_model_comparison_with_hope", "base_n20",
                 "all_model_aggregate_metrics.csv");
        label = "full_model_comparison_with_hope/base_n20")
    hope_models = ("M1c", "M2", "M3", "HOPE-ED", "HOPE-UC")
    if !isnothing(base20)
        base20 = select_core(base20, "VRE120_base", 20)
        push!(parts, filter(r -> r.model in hope_models, base20))
    else
        # fallback to N=5 if N=20 missing
        base5 = try_read(
            joinpath(RESULTS, "full_model_comparison_with_hope", "base_n5",
                     "all_model_aggregate_metrics.csv");
            label = "full_model_comparison_with_hope/base_n5 (fallback)")
        if !isnothing(base5)
            base5 = select_core(base5, "VRE120_base", 5)
            push!(parts, filter(r -> r.model in hope_models, base5))
        end
    end

    # VRE120_wind_hvy N=5
    whvy5 = try_read(
        joinpath(RESULTS, "wind_hvy_hope_uc_comparison", "n5",
                 "all_model_aggregate_metrics.csv");
        label = "wind_hvy_hope_uc_comparison/n5")
    !isnothing(whvy5) && push!(parts, select_core(whvy5, "VRE120_wind_hvy", 5))

    isempty(parts) && (warn!("TABLE 5 (HOPE validation): all source files missing — skipped"); return nothing)

    combined = vcat(parts...; cols = :union)
    # de-duplicate: keep highest-N for same case+model
    sort!(combined, [:case, :model, :n_scenarios]; rev = [false, false, true])
    unique!(combined, [:case, :model])

    # compute errors vs HOPE-UC reference
    hopeuc_rows = filter(r -> r.model == "HOPE-UC", combined)
    hopeuc_lolh = Dict(String(r.case) => r.lolh    for r in eachrow(hopeuc_rows))
    hopeuc_eue  = Dict(String(r.case) => r.eue_mwh for r in eachrow(hopeuc_rows))

    combined[!, :eue_error_vs_hope_uc]  = [r.eue_mwh - get(hopeuc_eue,  String(r.case), NaN) for r in eachrow(combined)]
    combined[!, :lolh_error_vs_hope_uc] = [r.lolh    - get(hopeuc_lolh, String(r.case), NaN) for r in eachrow(combined)]

    sort_by_model!(combined, ["M1c", "M2", "M3", "HOPE-ED", "HOPE-UC"])

    wanted   = [:case, :n_scenarios, :model, :lolh, :eue_mwh, :cvar_eue_mwh,
                :mean_runtime_s, :eue_error_vs_hope_uc, :lolh_error_vs_hope_uc]
    out      = select(combined, intersect(wanted, propertynames(combined)))
    for c in [:lolh, :eue_mwh, :cvar_eue_mwh, :mean_runtime_s,
              :eue_error_vs_hope_uc, :lolh_error_vs_hope_uc]
        hasproperty(out, c) && (out[!, c] = round2.(out[!, c]))
    end
    save_table(out, "paper_hope_validation.csv")
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# TABLE 6 — Runtime vs accuracy frontier
# ─────────────────────────────────────────────────────────────────────────────

function build_runtime_accuracy(storage_df::Union{DataFrame, Nothing},
                                hope_df::Union{DataFrame, Nothing})::Union{DataFrame, Nothing}
    parts = DataFrame[]

    # Storage ladder (benchmark = M3)
    if !isnothing(storage_df)
        sub = select(storage_df,
            intersect([:case, :n_scenarios, :model, :lolh, :eue_mwh,
                       :mean_runtime_s, :eue_error_vs_m3, :lolh_error_vs_m3,
                       :runtime_ratio_vs_m3],
                      propertynames(storage_df)))
        sub[!, :benchmark]        .= "M3"
        sub[!, :abs_eue_error_mwh] = round2.(abs.(Float64.(coalesce.(
            hasproperty(sub, :eue_error_vs_m3)  ? sub[!, :eue_error_vs_m3]  : fill(NaN, nrow(sub)), NaN))))
        sub[!, :abs_lolh_error_h]  = round2.(abs.(Float64.(coalesce.(
            hasproperty(sub, :lolh_error_vs_m3) ? sub[!, :lolh_error_vs_m3] : fill(NaN, nrow(sub)), NaN))))
        sub[!, :speedup_vs_benchmark] = hasproperty(sub, :runtime_ratio_vs_m3) ?
            sub[!, :runtime_ratio_vs_m3] : fill(NaN, nrow(sub))
        push!(parts, sub)
    end

    # HOPE models (benchmark = HOPE-UC)
    if !isnothing(hope_df)
        hope_only = filter(r -> r.model in ("HOPE-ED", "HOPE-UC"), hope_df)
        if nrow(hope_only) > 0
            hopeuc_rt = Dict(String(r.case) => r.mean_runtime_s
                             for r in eachrow(filter(r -> r.model == "HOPE-UC", hope_only)))
            hope_only[!, :benchmark]           .= "HOPE-UC"
            hope_only[!, :abs_eue_error_mwh]    = round2.(abs.(hope_only[!, :eue_error_vs_hope_uc]))
            hope_only[!, :abs_lolh_error_h]     = round2.(abs.(hope_only[!, :lolh_error_vs_hope_uc]))
            hope_only[!, :speedup_vs_benchmark] = [
                let rt_ref = get(hopeuc_rt, String(r.case), NaN)
                    (ismissing(r.mean_runtime_s) || isnan(rt_ref) || r.mean_runtime_s == 0.0) ? NaN :
                        round(rt_ref / r.mean_runtime_s; digits = 1)
                end
                for r in eachrow(hope_only)
            ]
            push!(parts, hope_only)
        end
    end

    isempty(parts) && (warn!("TABLE 6 (runtime/accuracy): no source data — skipped"); return nothing)

    combined = vcat(parts...; cols = :union)
    sort!(combined, [:case, :model])

    wanted   = [:case, :n_scenarios, :model, :benchmark,
                :abs_eue_error_mwh, :abs_lolh_error_h,
                :mean_runtime_s, :speedup_vs_benchmark]
    out      = select(combined, intersect(wanted, propertynames(combined)))
    save_table(out, "paper_runtime_accuracy.csv")
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

function write_summary(start_time::DateTime)
    elapsed = round(Dates.value(now() - start_time) / 1000; digits = 1)
    lines = String[
        "Paper Table Builder Summary",
        "Generated: $(now())",
        "Elapsed: $(elapsed) s",
        "",
        "── Collected ────────────────────────────────────────────────",
    ]
    append!(lines, ["  OK  $m" for m in COLLECTED])
    push!(lines, "")
    if isempty(WARNINGS)
        push!(lines, "No warnings.")
    else
        push!(lines, "── Warnings / Missing files ─────────────────────────────────")
        append!(lines, ["  WARN  $w" for w in WARNINGS])
    end
    push!(lines, "")
    push!(lines, "── Output files ─────────────────────────────────────────────")
    for f in sort(readdir(OUT_DIR))
        endswith(f, ".csv") || continue
        df_out = CSV.read(joinpath(OUT_DIR, f), DataFrame)
        push!(lines, "  $(rpad(f, 44)) $(nrow(df_out)) rows × $(ncol(df_out)) cols")
    end
    txt  = join(lines, "\n")
    path = joinpath(OUT_DIR, "summary.txt")
    write(path, txt)
    println(txt)
end

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

function main()
    t0 = now()
    println("Building paper tables → $OUT_DIR")

    build_model_hierarchy()
    build_no_storage_validation()
    storage_cmp = build_storage_method_comparison()
    build_sufficiency_bound()
    hope_val    = build_hope_validation()
    build_runtime_accuracy(storage_cmp, hope_val)

    write_summary(t0)

    if isempty(WARNINGS)
        println("\nAll tables built successfully.")
    else
        println("\nCompleted with $(length(WARNINGS)) warning(s) — see summary.txt.")
    end
end

main()
