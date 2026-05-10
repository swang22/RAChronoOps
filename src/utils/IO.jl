# ── IO helpers ────────────────────────────────────────────────────────────

"""
    save_metrics(metrics, path)

Write scalar reliability metrics to a two-column CSV (metric, value).
"""
function save_metrics(metrics::MetricsResult, path::String)
    mkpath(dirname(path))
    open(path, "w") do f
        println(f, "metric,value")
        println(f, "lolh,$(metrics.lolh)")
        println(f, "eue_mwh,$(metrics.eue)")
        println(f, "neue,$(metrics.neue)")
        println(f, "n_shortage_events,$(metrics.n_shortage_events)")
        println(f, "max_shortfall_mw,$(metrics.max_shortfall)")
        println(f, "cvar_eue_mwh,$(metrics.cvar_eue)")
    end
end

"""
    save_dispatch(results, path)

Write hourly dispatch vectors for all scenarios to a CSV.
Columns: scenario, hour, load_shed, discharge, charge, soc, curtailment.
"""
function save_dispatch(results::Vector{DispatchResult}, path::String)
    mkpath(dirname(path))
    rows = NamedTuple[]
    for r in results
        n = length(r.load_shed)
        for h in 1:n
            push!(rows, (
                scenario    = r.scenario_id,
                hour        = h,
                load_shed   = r.load_shed[h],
                discharge   = r.storage_discharge[h],
                charge      = r.storage_charge[h],
                soc         = r.soc[h],
                curtailment = r.curtailment[h],
            ))
        end
    end
    CSV.write(path, DataFrame(rows))
end

"""
    save_scenario_eue(metrics, path)

Write per-scenario EUE to a CSV (scenario, eue_mwh).
"""
function save_scenario_eue(metrics::MetricsResult, path::String)
    mkpath(dirname(path))
    n = length(metrics.scenario_eue)
    CSV.write(path, DataFrame(
        scenario = 1:n,
        eue_mwh  = metrics.scenario_eue,
    ))
end
