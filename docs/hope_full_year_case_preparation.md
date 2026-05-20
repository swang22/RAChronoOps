# HOPE Full-Year Case Preparation

**Date:** 2026-05-18
**Script:** `scripts/25_build_hope_full_year_cases.jl`
**Output:** `exports/hope_model_cases/`

---

## 1. Why we build HOPE cases before running HOPE

RAChronoOps M1–M3 models all run within a single Julia process: they read
the same `SystemData` struct and receive the same `ScenarioSet` availability
matrix.  HOPE is a separate Julia package with its own input conventions (CSV
files, YAML settings, a `DataCase/` folder structure).

The exporter script bridges the two systems:

- It reads the RAChronoOps processed case data (`data_processed/cases/<name>/`).
- It draws one specific Monte Carlo scenario from the `ScenarioSet`.
- It writes a self-contained HOPE case folder that a standalone HOPE invocation
  can consume directly.

Each exported folder is a **deterministic** HOPE run: the thermal outage
schedule for scenario `s` is baked into
`Data_RAChronoOps_PCM/gen_availability_timeseries.csv` as hourly binary
availability factors.  HOPE solves one 8760-hour LP (ED mode) or MILP (UC
mode) over the exact same forced-outage realisation.

This design makes M4 (HOPE full-year) directly comparable to M3 (full-year ED
LP): both operate on the same outage scenario, the same load profile, and the
same installed capacities.

---

## 2. How RAChronoOps maps to HOPE PCM inputs

| HOPE file | Source in RAChronoOps | Notes |
|---|---|---|
| `zonedata.csv` | `SystemData.load_mw` (peak = `Demand (MW)`) | Single zone Z1 |
| `gendata.csv` | `sys.generators` (thermal rows) + aggregated wind + solar | Row order matches ScenarioSet thermal index |
| `load_timeseries_regional.csv` | `sys.load_mw` ÷ peak | Per-unit (0–1); HOPE reconstructs MW via zonedata Demand |
| `gen_availability_timeseries.csv` | `ScenarioSet.availability[s, g, h]` | G1–G_n_therm binary; G_n_therm+1 wind CF; G_n_therm+2 solar CF |
| `wind_timeseries_regional.csv` | `sys.wind_cf` | Per-unit zonal wind CF (fallback; gen_availability takes priority) |
| `solar_timeseries_regional.csv` | `sys.solar_cf` | Per-unit zonal solar CF (fallback) |
| `storagedata.csv` | `sys.storage[1, :]` | Single aggregated battery (BES) |
| `single_parameter.csv` | `SimConfig.voll`; all reserves = 0 | Consistent with M3 |
| `carbonpolicies.csv` | Stub (1 row, large allowance) | Required by HOPE even when `carbon_policy: 0` |
| `rpspolicies.csv` | Stub (1 row, RPS = 0) | Required by HOPE even when `clean_energy_policy: 0` |
| `linedata.csv` | Dummy self-loop | network_model = 0 (copperplate) |
| `Settings/HOPE_model_settings.yml` | Mode-specific | unit_commitment = 0 (ED) or 1 (UC) |
| `Settings/gurobi_settings.yml` | Standard Gurobi tolerances | Required; read by HOPE before checking solver name |

### Generator ordering in gendata.csv

Row order matters because `gen_availability_timeseries.csv` columns G1…GN are
indexed by gendata row number:

```
Row 1 … Row n_therm   — thermal generators (exact order from generators.csv,
                          which matches the ScenarioSet thermal index)
Row n_therm+1         — aggregated wind (Type = WindOn)
Row n_therm+2         — aggregated solar (Type = SolarPV)
```

For the RTS-GMLC single-zone system, n_therm = 73.  The aggregated wind capacity
is the sum of all 4 wind generators' Pmax; the aggregated solar is the sum of all
57 PV/RTPV generators' Pmax.

### Availability representation

HOPE's `gen_availability_timeseries.csv` overrides the static `AF` column in
gendata for each generator at each hour.  For thermal generators the values are
binary {0, 1} from the Markov outage model.  For VRE generators the values are
per-unit capacity factors (0–1), so

```
p_gen_max[g, h] = gen_availability[g, h] × Pmax[g]
```

which gives `p_wind_max[h] = wind_cf[h] × wind_installed_mw` — exactly how M3
models VRE dispatch.

The `FOR` column in gendata is set to 0 for all generators so HOPE does not
apply additional stochastic sampling on top of the imposed scenario.

---

## 3. ED-match mode vs UC-lite mode

### ED-match (unit_commitment = 0)

Closest to M3.  All generators are treated as continuous resources (no on/off
binaries).  Pmin is set to 0 for all thermal generators, matching M3's LP
relaxation which does not enforce minimum stable generation.

This is the primary comparison mode for validating HOPE against M3.

| Parameter | Value |
|---|---|
| unit_commitment | 0 |
| Pmin (MW) in gendata | 0 (all generators) |
| Flag_UC | 0 |
| Start_up_cost | 0 $/MW |

### UC (unit_commitment = 1)

Adds integer unit-commitment constraints using Gurobi's MILP solver.  Thermal
generators have `Flag_UC=1`, real minimum up/down times, real ramp rates, and
real start-up costs from the RTS-GMLC data.

**Pmin is enforced correctly.**  HOPE PCM.jl implements Pmin through a
`pmin[g,h]` JuMP decision variable (not the `P_min` parameter directly):

```
MRL_con:   pmin[g,h]  ≤  (1−FOR_g) × P_min_unit[g] × o[g,h]
           pmin[g,h]  ≥  0                                      (variable lb)
CLeL_con:  pmin[g,h]  ≤  p[g,h] + ReserveUpG[g,h]
```

When a unit is off (`o[g,h]=0`), `MRL_con` forces `pmin[g,h]=0`, so `CLeL_con`
becomes `0 ≤ p[g,h]` — trivially satisfied.  When the unit is on, `pmin` is
bounded by the real `P_min_unit[g]`, enforcing minimum stable generation.
This is safe with `operation_reserve_mode: 0` and no further workaround is
needed.

**`Flag_mustrun` must be 0 for all generators.**  When `Flag_mustrun=1`, HOPE
enforces `p[g,h] = AF×Pmax×o[g,h]` (output equals maximum available capacity);
combined with forced-outage hours where `AF=0`, this creates infeasibility
because the commitment variable `o` can still be 1 under UC scheduling
constraints.

| Generator type | Pmin (gendata) | Flag_UC | Min_up_time | Min_down_time | Flag_mustrun |
|---|---|---|---|---|---|
| CT | real (8 MW) | 1 | 1 h | 1 h | 0 |
| CC | real (≥55 MW) | 1 | 2 h | 2 h | 0 |
| STEAM | real (30 MW) | 1 | 4 h | 8 h | 0 |
| NUCLEAR | real | 1 | 24 h | 24 h | 0 |
| Wind / Solar | 0 | 0 | 1 h | 1 h | 0 |

*Note: earlier documentation (before 2026-05-20) described this mode as
"UC-lite" with `Pmin=0` as a required workaround.  That reflected an
intermediate state before the `pmin` variable formulation was confirmed in
PCM.jl.  The current export (script 25) and all N=20 results use real Pmin.*

---

## 4. Validation checks

The export script runs four checks for each case/scenario/mode exported:

| Check | Criterion | Meaning |
|---|---|---|
| `n_gen` | n_generators == n_thermal + 2 | Exactly two VRE rows appended |
| `max_pu` | 0.999 ≤ max(Z1) ≤ 1.001 | Peak load profile reaches ≈ 1.0 |
| `load_err` | max|reconstructed − original| < 0.001 MW | Round-trip load reconstruction is exact |
| `avail` | 8760 rows, n_thermal+2 columns | Availability file dimensions match |

All four checks passed in the smoke export (2026-05-18).

### Smoke export results (VRE120_base, scenario 1, seed 42)

| Folder | Mode | n_gen | n_therm | Wind (MW) | Solar (MW) | Peak (MW) | max_pu | Load err (MW) | Avail | Status |
|---|---|---|---|---|---|---|---|---|---|---|
| RAChronoOps_VRE120_base_s001_ED | ED | 75 | 73 | 2507.9 | 2715.9 | 9830.2 | 1.000 | 9.1e-13 | 8760×75 | OK |
| RAChronoOps_VRE120_base_s001_UC | UC | 75 | 73 | 2507.9 | 2715.9 | 9830.2 | 1.000 | 9.1e-13 | 8760×75 | OK |

### HOPE run results (VRE120_base, scenario 1, seed 42)

Both cases ran to optimality using Gurobi 13.0.0 on 2026-05-18.

| Mode | Obj ($M) | Op cost ($M) | LoL ($M) | EUE (MWh) | LOLH | Solve time (s) |
|---|---|---|---|---|---|---|
| ED (LP) | 813.5 | 795.7 | 17.8 | 1779.5 | 6 | 12 |
| UC-lite (MILP, Pmin=0) | 813.5 | 795.7 | 17.8 | 1779.5 | 6 | 188 |

ED and UC-lite produce identical EUE for scenario 1 (both 1779.5 MWh).
This is expected at zero start-up cost with Pmin=0 — the MILP can commit
every generator at every hour at no penalty, so commitment constraints are
non-binding.  Note: UC-lite uses real ramp rates (RU~0.70 for NGCC); in
scenarios with outage-transition hours, UC ramp constraints can spread the
same total EUE over more shortage events relative to ED.  See Section 3.

---

## 5. Remaining steps to run HOPE

### Step 1 — Install HOPE ✓ (done)

```bash
git clone https://github.com/HOPE-Model-Project/HOPE
cd HOPE
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

Local HOPE project at `D:\MIT Dropbox\Shen Wang\MIT\RA\HOPE_project`.
`Pkg.instantiate()` was run on 2026-05-18 to resolve Julia 1.12.6 compatibility.

### Step 2 — Run an exported case ✓ (done, 2026-05-18)

```julia
using HOPE
HOPE.run_hope(raw"<absolute_path>/RAChronoOps_VRE120_base_s001_ED")
```

Both ED and UC-lite smoke cases ran successfully.  Output written to
`<case_folder>/output/`.

### Step 3 — Collect reliability metrics ✓ (done, 2026-05-19)

`scripts/27_collect_hope_results.jl` reads `output/power_loadshedding.csv`
(wide format: 1 row per zone, columns `AnnTol`, `h1`…`h8760`) and computes
LOLH, EUE, CVaR-EUE, and shortage-event statistics using
`RAChronoOps.compute_metrics`, producing the same output format as M1–M3.

N=5 pilot results written to `results/hope_n5_pilot/hope_metrics_by_scenario.csv`.
N=20 results written to `results/hope_n20_pilot/hope_metrics_by_scenario.csv`.

### Step 4 — Compare M3-ED vs M4-ED vs M4-UC ✓ (done, 2026-05-19)

`scripts/30_compare_all_models_hope_n5.jl` runs M1/M1b/M1c/M2/M3 inline and
reads HOPE metrics from the CSV produced by Step 3.

**N=20 results (VRE120_base, scenarios 1–20, seed=42):**

| Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | Runtime (s) |
|---|---|---|---|---|
| M3 (RA-3) | 6.0 | **2479.17** | 9782.93 | 190.5 |
| M4-ED (HOPE-ED) | 6.2 | **2479.17** | 9782.93 | 2355.5 |
| M4-UC (HOPE-UC) | 7.2 | **2479.17** | 9782.93 | 11438.4 |

HOPE-ED EUE matches M3 exactly (Δ = 0.00 MWh) after the ramp-rate fix.
HOPE-UC adds commitment/ramp constraints that spread the same total EUE
over more, shorter events (+1.2 h LOLH, unchanged EUE).
Full comparison: `results/full_model_comparison_with_hope/base_n20/`.

---

## 6. Assumptions and caveats

- **Single-zone copperplate**: network_model = 0. No transmission constraints.
  This is consistent with all M1–M3 models.

- **Reserve requirements = 0**: All spinning/regulation/non-spinning reserves
  are disabled (consistent with M3, which has no reserve constraints).

- **VOLL = 10,000 $/MWh**: Matches `SimConfig.voll` used by M3.

- **Ramp rates (ED mode)**: RU = RD = 1.0 (fraction of Pmax per hour) for all
  generators, making ramp constraints trivially inactive.  This is intentional:
  M3's ED LP has no ramp constraints, so ED-match mode must also have none.
  Passing real ramp rates in ED mode caused a +107 MWh EUE discrepancy at N=5
  (root cause identified 2026-05-19; see
  `results/hope_n5_pilot_diagnostics/ramp_constraint_root_cause.txt`).

- **Ramp rates (UC mode)**: RU/RD set to actual ramp rates from M3 generator
  data (ramp_mw_per_min, converted to fraction of Pmax per hour, capped at 1.0).
  Example: NGCC 355 MW at 4.14 MW/min → RU = min(1.0, 4.14×60/355) = 0.6997.

- **UC start-up costs**: 0 $/MW in this initial UC-lite run. Real RTS-GMLC
  values are O(100–600 $/MW per start) and would penalise frequent cycling.
  Updating start-up costs will increase UC-mode LOLH relative to the 0-cost
  baseline.

- **Scenario representativeness**: Exporting one scenario (scenario 1) gives a
  single deterministic HOPE run. For a probabilistic comparison with M3, export
  all 20 scenarios and average HOPE reliability metrics across them.

---

*Generated: 2026-05-18 | Script: `scripts/25_build_hope_full_year_cases.jl` | HOPE smoke runs: 2026-05-18*
*Updated: 2026-05-19 — ramp-rate fix applied; N=5 and N=20 validation complete.*
