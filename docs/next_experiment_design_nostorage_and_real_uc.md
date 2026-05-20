# Next Experiment Design: No-Storage Baselines and Real UC Parameters

**Date:** 2026-05-20
**Status:** Phase H complete — no-storage HOPE-UC validation done (2026-05-20)

---

## 1. Motivation

The N=20 validation run (2026-05-19) established that:

- HOPE-ED = M3 (exact EUE match after ramp-rate fix)
- HOPE-UC adds commitment constraints that spread EUE over more events
  (+1.0 h LOLH, unchanged EUE at N=20)

Two questions remain for the next experimental phase:

1. **Storage contribution**: How much of the EUE reduction seen in M3 (vs a
   pure-capacity check) comes from storage, and how much from LP foresight?
   Answering this requires a no-storage baseline: a model that runs the same
   Monte Carlo scenarios but without any storage resource.

2. **UC with real parameters**: Does enforcing real Pmin, real ramp rates, and
   real start-up costs materially increase EUE (not just redistribute it)?
   The N=20 UC run used real Pmin/ramp/startup.  A comparison against
   UC-with-zero-startup-costs would isolate the economic cycling penalty.

---

## 2. No-Storage Case Construction

### Script 33: `scripts/33_build_no_storage_cases.jl`

Creates `<case>_nostorage` variants alongside each source case in
`data_processed/cases/`.  The only change is that `storage.csv` is
overwritten with the column header only (zero rows), so `load_system_data`
returns `n_stor=0` and all dispatch models (M1–M3, HOPE) skip storage
entirely.

All other data (generators, load, wind, solar time series) are copied
unchanged so that the no-storage case uses the same thermal fleet, VRE
profile, and Monte Carlo scenarios as the base case.

**Cases produced:**

| Source case | No-storage variant |
|---|---|
| VRE120_base | VRE120_base_nostorage |
| VRE120_wind_hvy | VRE120_wind_hvy_nostorage |
| VRE120_bal15 | VRE120_bal15_nostorage |

**Run:**
```bash
julia --project=. scripts/33_build_no_storage_cases.jl
```

---

## 3. MC-NoStorage Model

### File: `src/models/McNoStorage.jl`

```
run_mc_no_storage(system, availability, config) -> Vector{DispatchResult}
```

Classical hourly capacity-adequacy check without storage or LP:

```
load_shed[h] = max(0, load[h] − thermal_avail[h] − vre_avail[h])

thermal_avail[h] = Σ_g  pmax[g] × availability[s, g, h]
vre_avail[h]     = wind_cap × wind_cf[h] + solar_cap × solar_cf[h]
```

This is equivalent to the traditional LOLP convolution approach applied
hour-by-hour under a Monte Carlo outage scenario.  It has no chronological
optimisation, no foresight, and no storage.  Runtime is O(n_scen × T × n_gen)
— nearly instantaneous compared to any LP-based model.

Returns `Vector{DispatchResult}` with zero storage fields so that
`compute_metrics` and IO utilities accept the output unchanged.

---

## 4. No-Storage Comparison Experiments

### Script 34: `scripts/34_compare_no_storage_classic_vs_ed.jl`

Runs three models on each no-storage / base case pair and writes results to
`results/no_storage_comparison/`:

| Model | Description |
|---|---|
| MC-NoStorage | `run_mc_no_storage` on `<case>_nostorage` — no storage, no LP |
| M3-NoStorage | `run_m3_ed_dispatch` on `<case>_nostorage` — LP foresight only |
| M3-WithStorage | `run_m3_ed_dispatch` on `<case>` — LP + storage (reference) |

### Decomposition

The three models enable an additive EUE decomposition:

```
ΔEUE(MC-NS − M3-NS)   = LP foresight value  (same no-storage system,
                          MC vs optimised dispatch)
ΔEUE(M3-NS − M3-WS)   = storage value  (same LP, with vs without storage)
ΔEUE(MC-NS − M3-WS)   = total reliability contribution of LP + storage
```

### Expected results

For VRE120_base (N=20, seed=42):

- M3-WithStorage: EUE ≈ 2479 MWh (established baseline)
- M3-NoStorage: EUE expected to be substantially higher — storage provides
  significant buffering in high-VRE systems
- MC-NoStorage: EUE expected to be even higher than M3-NoStorage — LP
  foresight allows optimal pre-positioning before shortage hours

**Run:**
```bash
julia --project=. scripts/34_compare_no_storage_classic_vs_ed.jl \
  --cases VRE120_base,VRE120_wind_hvy \
  --n-scenarios 20 --seed 42 \
  --out-dir results/no_storage_comparison
```

---

## 5. HOPE-UC with Real Parameters

### Current state (as of 2026-05-20)

Script 25 (`25_build_hope_full_year_cases.jl`) already exports UC cases with:

| Parameter | Value |
|---|---|
| Pmin (MW) | Real values from generators.csv |
| RU / RD | Real ramp rates (min(1, ramp_mw_min × 60 / Pmax)) |
| Start_up_cost ($/MW) | Real values from generators.csv |
| Min_up_time / Min_down_time | Real values from generators.csv |
| Flag_UC | 1 for all thermal generators |

The earlier "UC-lite / Pmin=0" constraint has been resolved.  HOPE PCM.jl
implements Pmin through a `pmin[g,h]` JuMP decision variable bounded by
`P_min_unit[g] × o[g,h]`, so real Pmin values are safe with
`operation_reserve_mode: 0`.  See `docs/hope_full_year_case_preparation.md`
Section 3 for the formulation details.

The N=20 UC results already reflect real Pmin, real ramp rates, and real
startup costs:

| Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | Runtime (s) |
|---|---|---|---|---|
| HOPE-ED | 6.2 | 2479.17 | 9782.93 | 2355.5 |
| HOPE-UC | 7.2 | 2479.17 | 9782.93 | 11438.4 |

### Remaining UC comparison (future work)

To isolate the **economic cycling penalty** from **commitment-scheduling
constraints**, export a "UC-zero-startup" variant (same Pmin/ramp, but
`Start_up_cost = 0`) and compare against the current real-startup-cost UC.
In the N=20 run, start-up costs are non-zero but EUE is unchanged vs ED,
suggesting cycling penalties are mild at N=20.  A longer run (N=100) or a
system with tighter margins may show a difference.

---

## 6. Implementation Status

| Item | Script / File | Status |
|---|---|---|
| No-storage case builder | `scripts/33_build_no_storage_cases.jl` | ✓ complete |
| MC-NoStorage model | `src/models/McNoStorage.jl` | ✓ complete |
| No-storage comparison | `scripts/34_compare_no_storage_classic_vs_ed.jl` | ✓ complete |
| HOPE-UC real params | `scripts/25_build_hope_full_year_cases.jl` | ✓ already done |
| Pmin formulation fix | `HOPE_project/src/PCM.jl` (pmin variable) | ✓ confirmed in PCM.jl |
| Documentation update | `docs/hope_full_year_case_preparation.md` | ✓ updated 2026-05-20 |

---

## 7. No-Storage HOPE-UC Validation (Phase H — 2026-05-20)

### Result

N=5 pilot comparing MC-NoStorage, M3-NoStorage, HOPE-ED-NoStorage, and
HOPE-UC-NoStorage on `VRE120_base_nostorage` (scenarios 1–5, seed=42).

| Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | RT (s) |
|---|---|---|---|---|
| MC-NoStorage | 115.6 | 41846.40 | 54383.21 | 0.5 |
| M3-NoStorage | 115.6 | 41846.40 | 54383.21 | 40.0 |
| HOPE-ED-NoStorage | 115.6 | 41846.40 | 54383.21 | 614.3 |
| HOPE-UC-NoStorage | 115.6 | 41846.40 | 54383.21 | 4331.1 |

ΔEUE = 0.00 MWh and ΔLOLH = 0.0 h across all scenario/model pairs.

### Interpretation

**UC constraints add no reliability effect without storage.**  In the
absence of storage there is no intertemporal state variable linking hours
together.  Load shedding in any hour is determined entirely by available
thermal and VRE capacity — an exogenous quantity fixed by the Monte Carlo
outage draw before the dispatch problem is even formulated.  Whether the
dispatch is solved as an LP (HOPE-ED) or a MILP with binary commitment
variables (HOPE-UC), the total MW served per hour is identical, and
therefore LOLH and EUE are identical.

**Unit-level dispatch differs; system-level outcomes do not.**  An
inspection of `power_hourly.csv` shows:
- Total system generation per hour: identical (0 MW difference, all 8760 h).
- Thermal output by technology type: identical.
- Individual unit dispatch within a type: differs (LP bang-bang vs UC
  min-up/down redistribution).
- VRE curtailment: differs by up to ~260 MW in surplus hours, where UC
  locks thermal units at Pmin and spills more wind/solar.  This affects
  neither cost nor reliability since curtailment has zero marginal cost.

**Implication for paper narrative.**  Storage SOC — not UC commitment
constraints alone — is the reason operation-aware modelling becomes
important for reliability assessment.  UC's binary commitment variables
create binding inter-hour constraints only when generators must be kept
on/off to protect an intertemporal energy resource (storage).  Without
storage there is nothing to pre-position, so the LP and MILP collapse to
the same feasible set.

**Runtime note.**  HOPE-UC averages ~850 s/scenario vs ~120 s/scenario
for HOPE-ED — a 7× MILP penalty with zero reliability benefit in the
no-storage case.  UC is only warranted when storage is present.

### Scripts and outputs

| Item | Path |
|---|---|
| Case export (n_stor=0 fix) | `scripts/25_build_hope_full_year_cases.jl` |
| HOPE runner | `scripts/29_run_hope_n5_pilot.jl` |
| Metric collection | `scripts/27_collect_hope_results.jl` |
| Four-model comparison | `scripts/36_compare_nostorage_hope_uc_n5.jl` |
| Run status | `results/hope_nostorage_n5_pilot/hope_run_status.csv` |
| Per-scenario metrics | `results/hope_nostorage_n5_pilot/hope_metrics_by_scenario.csv` |
| Aggregate + summary | `results/nostorage_hope_uc_comparison/base_n5/` |

---

## 8. Suggested Next Run Order

```
# 1. Build no-storage case directories (fast, pure file I/O)
julia --project=. scripts/33_build_no_storage_cases.jl

# 2. Run the three-model no-storage comparison (N=20, ~35 min for M3 × 2 cases)
julia --project=. scripts/34_compare_no_storage_classic_vs_ed.jl \
  --cases VRE120_base,VRE120_wind_hvy --n-scenarios 20 --seed 42

# 3. (Optional) Extend HOPE-UC to N=100 for tighter reliability margin test
#    Requires a compute node (~32 h at 570 s/scenario × 100 scenarios × 2 modes)
```

---

*Generated: 2026-05-20 | Context: Phase G — no-storage baselines and UC parameter confirmation*
