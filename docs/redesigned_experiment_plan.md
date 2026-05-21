# Current Experiment Design

**Last updated:** 2026-05-21

---

## 1. Research goal

Improve probabilistic sequential Monte Carlo resource adequacy (RA)
assessment to incorporate storage temporal operation while retaining
computational scalability.

The central question is: **how much operational detail must be embedded
inside each Monte Carlo scenario to obtain reliable estimates of LOLH and
EUE without running a full production-cost model for every scenario?**

---

## 2. Core hypothesis

Monte Carlo sampling is valid; the missing piece is storage operation inside
each scenario.  Traditional sequential MC (no storage) already matches full
ED/UC LP in the no-storage setting.  Once storage is added, the intertemporal
SOC state links hours together, making reliability estimates sensitive to the
assumed dispatch rule.  Solving LPs only near screened risk periods (RA-2 /
M2) should recover most of the full-year ED benchmark accuracy at a fraction
of the runtime.

---

## 3. Research questions

**RQ1.** Does traditional sequential MC give the same reliability estimate
as ED/UC benchmarks when storage is absent?
_(Establishes that MC sampling is valid before adding storage complexity.)_

**RQ2.** How do simplified storage dispatch rules (M1, M1b, M1c) perform
relative to the full-year ED benchmark?
_(Tests whether heuristic storage heuristics are good enough, or whether
LP-level dispatch is necessary.)_

**RQ3.** Can the event-window LP (M2) recover most of the full-year ED
benchmark accuracy at much lower runtime than M3?
_(Tests the proposed hybrid method.)_

**RQ4.** Does HOPE-UC unit commitment materially change EUE compared to
HOPE-ED in tested cases?
_(Tests whether ignoring UC constraints in RA-3 understates or overstates
reliability risk.)_

---

## 4. Experiment A — No-storage MC validation

**Purpose:** Validate traditional sequential MC against ED/UC when storage
is absent.  If all models agree without storage, any divergence in storage
cases is attributable to storage dispatch, not MC sampling.

**Models:**
- MC-NoStorage: classical hourly capacity check (no LP, no storage)
- M3-NoStorage: full-year ED LP on no-storage case
- PCM-ED-NS (HOPE-ED-NoStorage): PCM in economic dispatch mode, no-storage case
- PCM-UCED-NS (HOPE-UC-NoStorage): PCM with unit commitment, no-storage case

**Cases:** VRE120\_base\_nostorage, VRE120\_wind\_hvy\_nostorage
(built by `scripts/33_build_no_storage_cases.jl`)

**Scripts:**
- `scripts/33_build_no_storage_cases.jl` — build no-storage case variants
- `scripts/34_compare_no_storage_classic_vs_ed.jl` — MC vs M3, N=20
- `scripts/36_compare_nostorage_hope_uc_n5.jl` — four-model HOPE-UC check, N=5

**Key result:** All four models produce identical LOLH and EUE.
MC-NoStorage = M3-NoStorage = PCM-ED-NS = PCM-UCED-NS
(ΔEUE = 0.00 MWh, ΔLOLH = 0.0 h).

Without storage there is no intertemporal state variable linking hours
together, so the LP and MILP feasible sets collapse to the same classical
capacity check.  Traditional MC is valid in the no-storage RA setting.

---

## 5. Experiment B — Storage-aware MC methods

**Purpose:** Test a ladder of storage dispatch rules to identify which
level of operational detail is needed to match the full-year ED benchmark.

**Models (in order of increasing complexity):**

| Label | Rule | Role |
|-------|------|------|
| M1 / RA-1a | Naive peak-shaving heuristic (3-priority) | Cautionary failure case |
| M1b / RA-1b | Reserve-aware heuristic (SOC floor on P2) | Practical improved heuristic |
| M1c / RA-1c | Emergency-only heuristic, system-surplus charging | Near-M3 simple model |
| M1c\_VREOnly | Same as M1c, charges from VRE surplus only | Appendix sensitivity |
| M1d\_earliest / RA-1d | Risk-hour allocation, earliest\_first mode | Within-event allocation study |
| M1d\_largest / RA-1d | Risk-hour allocation, largest\_first mode | Within-event allocation study |
| M2 / RA-2 | Event-window LP (risk\_margin=1000 MW, buffer=48 h) | Proposed hybrid method |
| M3 / RA-3 | Full-year ED LP | Reliability benchmark |

**Case:** VRE120\_base and six VRE penetration cases, N=20, seed=42

**Scripts:**
- `scripts/14_run_ra1b_validation.jl` — M1b validation
- `scripts/16_run_vre_method_comparison.jl` — full M1/M1b/M1c/M2/M3 sweep

**Key result:**
- M1 and M1b: overestimate reliability risk.  Naive peak-shaving depletes
  storage SOC before shortage events; SOC reserve in M1b reduces but does
  not eliminate the bias.
- M1c: matches M3 EUE and CVaR closely at ~130× speedup.
- M1d\_earliest: matches M1c and M3 EUE exactly per scenario (ΔEUE = 0.00 MWh).
  With a 72-hour lookback, charging and chronological discharge replicate M1c.
- M1d\_largest: same EUE as M3 but higher LOLH (+2.4 h base, +0.4 h wind-heavy)
  because within-event reallocation to largest shortfall hours leaves smaller
  shortfall hours partially served, spreading the same energy deficit.
- M2: matches M3 EUE to near-machine-precision; LOLH within 0.2 h mean error;
  5–10 s/scenario (20–37× faster than M3).
- M1c\_VREOnly: +17–77 h LOLH error because VRE capacity factor is below 1
  at nearly all hours — VRE-only charging fails to fill storage.

Recommended M2 config: `risk_margin_mw=1000, window_buffer_hours=48`.

---

## 6. Experiment C — Full-year PCM validation (PCM-ED and PCM-UCED)

**Purpose:** Validate the M3 ED benchmark against PCM full-year ED, then
test whether PCM-UCED unit commitment changes EUE or mainly reshapes
LOLH/event timing.

**Models:** M3, PCM-ED (HOPE-ED), PCM-UCED (HOPE-UC)

**UC parameters used (real RTS-GMLC values):**

| Parameter | Source |
|-----------|--------|
| Pmin (MW) | generators.csv |
| RU / RD ramp rates | gen.csv, MW/min → fraction of Pmax/hr |
| Startup cost ($/MW) | Non-fuel start cost + fuel price × hot-start heat |
| Min up / down time (h) | gen.csv, integer-rounded |
| Flag\_UC | 1 for all thermal generators |

**Scripts:**
- `scripts/25_build_hope_full_year_cases.jl` — export HOPE ED/UC case folders
- `scripts/29_run_hope_n5_pilot.jl` — run HOPE via subprocess
- `scripts/27_collect_hope_results.jl` — collect load-shedding metrics
- `scripts/30_compare_all_models_hope_n5.jl` — M1c/M2/M3/HOPE-ED comparison

**Key result:**
- PCM-ED (HOPE-ED) matches M3 once ED-mode ramp constraints are disabled (ΔEUE < 1 MWh).
- PCM-UCED (HOPE-UC) raises LOLH by ~1 h relative to PCM-ED but leaves EUE unchanged
  in the VRE120\_base N=20 run (same total energy deficit, redistributed into
  more shortage hours by min-up/down constraints on committed generators and
  storage pre-positioning).
- Runtime: PCM-UCED is ~5× slower than PCM-ED with zero EUE benefit in the
  tested cases.

---

## 7. Experiment D — VRE/net-load profile sensitivity

**Purpose:** Check whether findings from Experiments B and C hold under
different VRE profiles (wind-heavy vs balanced vs solar-heavy).

**Cases:**

| Label | Wind scale | Solar scale | Storage |
|-------|-----------|-------------|---------|
| VRE120\_base | 1.0 | 1.0 | 983 MW / 3,932 MWh |
| VRE120\_wind\_hvy | 3.0 | 1.0 | 983 MW / 3,932 MWh |
| VRE120\_bal15 | 1.5 | 1.5 | 983 MW / 3,932 MWh |
| VRE120\_bal20 | 2.0 | 2.0 | 983 MW / 3,932 MWh |
| VRE120\_bal30 | 3.0 | 3.0 | 983 MW / 3,932 MWh |
| VRE120\_sol\_hvy | 1.0 | 3.0 | 983 MW / 3,932 MWh |

**Wind-heavy HOPE-UC result (N=5):**

| Model | LOLH (h) | EUE (MWh) | Runtime (s) |
|-------|----------|-----------|-------------|
| M1c | 4.4 | 1,113 | 0.6 |
| M2 | 3.8 | 1,113 | 2.5 |
| M3 | 4.4 | 1,113 | 44.3 |
| PCM-ED | 3.8 | 1,113 | 588 |
| PCM-UCED | 4.2 | 1,113 | 2,712 |

EUE identical across all models; PCM-UCED shifts LOLH +0.4 h vs PCM-ED
(same pattern as base case but milder LOLH effect).

Script: `scripts/37_compare_wind_hvy_hope_uc_n5.jl`

---

## 8. Experiment E — M1d risk-hour allocation and storage-energy sufficiency bound

**Purpose:** (1) Characterise the within-event storage allocation mode as a
research diagnostic; (2) derive a theoretical bound that explains why M1c,
M1d, M2, and M3 converge on the same EUE.

### E1 — M1d within-event allocation comparison

**Models:** M1c, M1d\_earliest, M1d\_largest, M2, M3

**Key finding (N=20, VRE120\_base and VRE120\_wind\_hvy):**

| Model | LOLH (h) | EUE (MWh) | RT (s) | Case |
|-------|----------|-----------|--------|------|
| M1c | 6.0 | 2,479 | 1.3 | base |
| M1d\_earliest | 6.0 | 2,479 | 1.0 | base |
| M1d\_largest | 8.4 | 2,479 | 1.2 | base |
| M2 | 5.8 | 2,479 | 8.7 | base |
| M3 | 6.0 | 2,479 | 191 | base |

EUE is identical across all modes (exact per-scenario match).
The allocation mode affects only within-event LOLH, not total unserved energy.

Script: `scripts/38_compare_m1d_storage_heuristics.jl`

### E2 — Storage-energy sufficiency bound

The bound quantifies the maximum EUE reduction achievable by storage given
the surplus energy available in a lookback window before each shortage event:

```
coverage_bound = min(pre_event_EUE,
                     feasible_discharge_energy,  -- SOC × η_dis after 72 h charging
                     power_limited_coverage)      -- Σ min(shortfall[h], power_mw)
residual_eue_bound = pre_event_EUE − coverage_bound
```

**Key finding (N=20, seed=42, lookback=72 h):**

| Case | Pre-storage EUE | Bound EUE | M3 EUE | Bound − M3 | Sufficiency ratio |
|------|----------------|-----------|--------|-----------|-------------------|
| VRE120\_base | 31,017 MWh | 2,479 MWh | 2,479 MWh | 0.00 MWh | 0.941 |
| VRE120\_wind\_hvy | 15,801 MWh | 648 MWh | 648 MWh | 0.00 MWh | 0.972 |

The bound matches M3 EUE exactly per scenario.  In both tested cases,
the binding constraint is storage energy (MWh) rather than power (MW).

**Empirical implication (tested RTS-GMLC cases):** When the bound is tight,
any dispatch model that charges from surplus and discharges only at shortage
hours approaches M3 EUE in these tested configurations.  M1/M1b violate this
by discharging proactively, depleting SOC before shortage events and moving
away from the bound.

Script: `scripts/39_storage_energy_sufficiency_bound.jl`

Documentation: `docs/storage_energy_sufficiency_bound.md`

---

## 9. Core metrics

| Category | Metrics |
|----------|---------|
| Frequency | LOLH, LOLP, LOLE days |
| Energy | EUE, nEUE (ppm) |
| Tail risk | CVaR-EUE, p90/p95/p99 scenario EUE |
| Event structure | n\_shortage\_events, mean/max/p95 shortage duration |
| Severity | max\_shortfall\_mw, mean\_shortfall\_when\_shedding\_mw |
| MC uncertainty | LOLH CI95, EUE CI95 half-widths |
| Runtime | total\_runtime\_s, mean\_runtime\_s |

Primary paper tables show LOLH, EUE, CVaR-EUE, and runtime.

---

## 10. Out-of-scope for core experiments

The following are explicitly **not** part of the core RA benchmark:

| Topic | Rationale |
|-------|-----------|
| Operating reserves | Ancillary service markets; separate from RA adequacy |
| Network congestion | Single copper-plate zone by design |
| Imperfect foresight | LP models assume perfect within-year foresight; relaxing this is a future extension |
| Investment re-optimization | Static capacity study; installed capacity is fixed |
| Demand response | Not modelled in RTS-GMLC base data |

These align with traditional RA conventions and keep the benchmark
comparable to published LOLP/EUE studies.

---

## 11. Status summary

| Experiment | Status |
|------------|--------|
| A: no-storage MC validation (N=20 + N=5 HOPE) | Complete |
| B: storage-aware MC methods (VRE sweep N=20) | Complete |
| C: PCM-ED / PCM-UCED base case validation (N=20) | Complete |
| D: wind-heavy PCM-UCED profile check (N=5) | Complete |
| D: full VRE sweep PCM-UCED (N=20) | Optional — feasible (~3 h) |
| E1: M1d within-event allocation comparison | Complete |
| E2: storage-energy sufficiency bound | Complete |
| Paper tables and figures | Next step |
