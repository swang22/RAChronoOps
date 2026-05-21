# Current Experiment Design

**Last updated:** 2026-05-20

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
- HOPE-ED-NoStorage: HOPE ED LP on no-storage case
- HOPE-UC-NoStorage: HOPE UC MILP on no-storage case

**Cases:** VRE120\_base\_nostorage, VRE120\_wind\_hvy\_nostorage
(built by `scripts/33_build_no_storage_cases.jl`)

**Scripts:**
- `scripts/33_build_no_storage_cases.jl` — build no-storage case variants
- `scripts/34_compare_no_storage_classic_vs_ed.jl` — MC vs M3, N=20
- `scripts/36_compare_nostorage_hope_uc_n5.jl` — four-model HOPE-UC check, N=5

**Key result:** All four models produce identical LOLH and EUE.
MC-NoStorage = M3-NoStorage = HOPE-ED-NoStorage = HOPE-UC-NoStorage
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
- M2: matches M3 EUE to near-machine-precision; LOLH within 0.2 h mean error;
  5–10 s/scenario (20–37× faster than M3).
- M1c\_VREOnly: +17–77 h LOLH error because VRE capacity factor is below 1
  at nearly all hours — VRE-only charging fails to fill storage.

Recommended M2 config: `risk_margin_mw=1000, window_buffer_hours=48`.

---

## 6. Experiment C — Full-year HOPE UC validation

**Purpose:** Validate the M3 ED benchmark against HOPE full-year ED, then
test whether HOPE-UC unit commitment changes EUE or mainly reshapes
LOLH/event timing.

**Models:** M3, HOPE-ED, HOPE-UC

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
- HOPE-ED matches M3 once ED-mode ramp constraints are disabled (ΔEUE < 1 MWh).
- HOPE-UC raises LOLH by ~1 h relative to HOPE-ED but leaves EUE unchanged
  in the VRE120\_base N=20 run (same total energy deficit, redistributed into
  more shortage hours by min-up/down constraints on committed generators and
  storage pre-positioning).
- Runtime: HOPE-UC is ~5× slower than HOPE-ED with zero EUE benefit in the
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
| HOPE-ED | 3.8 | 1,113 | 588 |
| HOPE-UC | 4.2 | 1,113 | 2,712 |

EUE identical across all models; HOPE-UC shifts LOLH +0.4 h vs HOPE-ED
(same pattern as base case but milder LOLH effect).

Script: `scripts/37_compare_wind_hvy_hope_uc_n5.jl`

---

## 8. Core metrics

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

## 9. Out-of-scope for core experiments

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

## 10. Status summary

| Experiment | Status |
|------------|--------|
| A: no-storage MC validation (N=20 + N=5 HOPE) | Complete |
| B: storage-aware MC methods (VRE sweep N=20) | Complete |
| C: HOPE-ED/UC base case validation (N=20) | Complete |
| D: wind-heavy HOPE-UC profile check (N=5) | Complete |
| D: full VRE sweep HOPE-UC (N=20) | Optional — feasible (~3 h) |
| Paper tables and figures | Next step |
