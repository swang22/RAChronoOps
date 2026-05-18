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
| `linedata.csv` | Dummy self-loop | network_model = 0 (copperplate) |
| `Settings/HOPE_model_settings.yml` | Mode-specific | unit_commitment = 0 (ED) or 1 (UC) |

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
| Pmin (thermal) | 0 MW |
| Flag_UC | 0 |
| Start_up_cost | 0 $/MW |

### UC-lite (unit_commitment = 1)

Adds integer unit-commitment constraints using Gurobi's MILP solver.  Thermal
generators receive their actual Pmin values from RAChronoOps data (e.g., CT=8
MW, Coal STEAM=30 MW, CC=170 MW, Nuclear=396 MW).

The nuclear unit is set as `Flag_mustrun=1` (always online) and has 24-hour
minimum up/down times, reflecting its near-must-run operational status.

This is the benchmark for M4: testing whether commitment constraints change
reliability estimates relative to the M3/M4-ED baseline.

| Generator type | Pmin | Min_up_time | Min_down_time | Note |
|---|---|---|---|---|
| CT | data value | 1 h | 1 h | Fast-start peaker |
| CC | data value | 2 h | 2 h | Combined cycle |
| STEAM | data value | 4 h | 4 h | Slow thermal |
| NUCLEAR | data value | 24 h | 24 h | Flag_mustrun=1 |
| Wind / Solar | 0 | 1 h | 1 h | Flag_UC=0 |

Start-up costs are set to 0 $/MW in this initial UC-lite run to isolate the
effect of Pmin constraints from start-up cost economics.

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

---

## 5. Remaining steps to run HOPE

### Step 1 — Install HOPE

```bash
git clone https://github.com/HOPE-Model-Project/HOPE
cd HOPE
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

### Step 2 — Run an exported case

```bash
cd exports/hope_model_cases/RAChronoOps_VRE120_base_s001_ED
julia --project=<HOPE_dir> <HOPE_dir>/run_hope.jl \
    --settings Settings/HOPE_model_settings.yml
```

### Step 3 — Collect reliability metrics

HOPE produces dispatch results in its output directory.  Post-process with
`RAChronoOps.compute_metrics` on the extracted `load_shed` vectors to compute
LOLH/EUE/CVaR-EUE in the same format as M1–M3 results.

This post-processing step is not yet implemented (see Task 8 in
`docs/redesigned_experiment_plan.md`).

### Step 4 — Compare M3-ED vs M4-ED vs M4-UC

| Model | Description | Expected runtime |
|---|---|---|
| M3 (RA-3) | RAChronoOps full-year LP (Gurobi), no UC | ~190 s/scenario |
| M4-ED | HOPE full-year LP (same problem structure), no UC | ~190 s/scenario |
| M4-UC | HOPE full-year MILP (integer commitment) | Minutes to hours/scenario |

M3 and M4-ED should produce near-identical dispatch and reliability metrics if
both are solving the same LP relaxation.  Any differences diagnose
implementation gaps.  M4-UC adds UC constraints; divergence from M3 quantifies
the penalty of ignoring commitment feasibility.

---

## 6. Assumptions and caveats

- **Single-zone copperplate**: network_model = 0. No transmission constraints.
  This is consistent with all M1–M3 models.

- **Reserve requirements = 0**: All spinning/regulation/non-spinning reserves
  are disabled (consistent with M3, which has no reserve constraints).

- **VOLL = 10,000 $/MWh**: Matches `SimConfig.voll` used by M3.

- **Ramp rates**: RU = RD = 1 MW/min for all generators (effectively
  unconstrained for most units; consistent with M3 which has no ramp
  constraints). Should be updated with real RTS-GMLC ramp data for production
  runs.

- **UC start-up costs**: 0 $/MW in this initial UC-lite run. Real RTS-GMLC
  values are O(100–600 $/MW per start) and would penalise frequent cycling.
  Updating start-up costs will increase UC-mode LOLH relative to the 0-cost
  baseline.

- **Scenario representativeness**: Exporting one scenario (scenario 1) gives a
  single deterministic HOPE run. For a probabilistic comparison with M3, export
  all 20 scenarios and average HOPE reliability metrics across them.

---

*Generated: 2026-05-18 | Script: `scripts/25_build_hope_full_year_cases.jl`*
