# Redesigned Experiment Plan

## 1. Research goal

Bridge probabilistic sequential Monte Carlo resource adequacy assessment
and full production-cost / unit-commitment modelling by testing
RA-compatible dispatch approximations for high-VRE, storage-rich power
systems.

The central question is: **how much operational detail must be embedded
inside each Monte Carlo scenario to obtain reliable estimates of LOLH and
EUE without running a full PCM/UC for every scenario?**

---

## 2. Research questions

**RQ1.** How does the error of simplified sequential-MC dispatch
approximations change as VRE penetration increases?
_(Does adding more solar/wind make simple heuristics worse, because
storage must shift energy across longer time windows?)_

**RQ2.** Can reserve-aware heuristics (RA-1b) approximate full-year ED
reliability metrics better than naive peak-shaving heuristics (RA-1a)?
_(Is reserving an emergency SOC floor sufficient to recover most of the
RA-3 benchmark accuracy at near-zero extra cost?)_

**RQ3.** Can screened event-window LP dispatch (RA-2) recover most of the
full-year ED benchmark accuracy at much lower runtime than RA-3?
_(Does solving LPs only near screened risk periods give most of the
accuracy at a fraction of the cost?)_

**RQ4.** Under which VRE profiles — solar-heavy vs wind-heavy — do
simplified heuristics fail most severely?
_(Does multi-day wind variability create longer energy-depletion risks
than daily solar cycling, making the event-window approximation harder?)_

---

## 3. Method hierarchy

All methods use the same sequential thermal outage Monte Carlo scenarios
(common random numbers).  They differ only in how storage dispatch is
computed inside each scenario.

### RA-0 — Static capacity-balance RA

| Attribute | Detail |
|-----------|--------|
| Mathematical idea | Convolution / LOLE table using effective load-carrying capability (ELCC). No chronology. Storage counted as firm capacity via its ELCC. |
| Expected runtime | Seconds (analytic). |
| Role in paper | Classical baseline. Shows how much the chronological treatment matters. |
| Implementation status | Not yet implemented. |

### RA-1a / M1 — Naive chronological peak-shaving heuristic

| Attribute | Detail |
|-----------|--------|
| Mathematical idea | Three-priority rule per hour: (1) discharge to cover shortfall, (2) proactively discharge at all hours with net load ≥ Q0.75, (3) charge when net load ≤ Q0.25 and surplus exists. No look-ahead. No SOC reservation for emergencies. |
| Expected runtime | ~1 s/scenario (no LP). |
| Role in paper | Cautionary baseline. Demonstrates that naive peak-shaving depletes storage before shortage events, producing reliability metrics insensitive to storage size. |
| Implementation status | Implemented (`src/models/M1RuleBasedStorage.jl`). Diagnosed in `scripts/13_debug_m1_storage_sensitivity.jl`. |

### RA-1b — Reserve-aware chronological heuristic

| Attribute | Detail |
|-----------|--------|
| Mathematical idea | Same three-priority rule as RA-1a, but priority 2 (proactive discharge) is suppressed when SOC < `reserve_fraction × total_energy`. The reserve floor keeps storage available for emergency (priority-1) use during outage events. |
| Expected runtime | ~1 s/scenario (no LP). |
| Role in paper | Practical improved heuristic. Tests whether a simple SOC guard is sufficient to recover most RA-3 accuracy. |
| Implementation status | **Implemented and validated** (Phase B complete). `src/models/M1bReserveAwareStorage.jl`, `configs/m1b.yaml`. Validation: `scripts/14_run_ra1b_validation.jl`; results in `results/ra1b_validation/`. Key finding: P1 fires in 10/10 scenarios; LOLH storage-sensitive; still 3–11× above M3 at reference cases — motivates RA-2. |

### RA-2 — Event-window LP dispatch

| Attribute | Detail |
|-----------|--------|
| Mathematical idea | Screen each scenario for risk windows: hours where (thermal available capacity + VRE) falls within a margin of load. Merge nearby risk hours into contiguous windows with a buffer. Solve a storage dispatch LP only inside each window. Use heuristic dispatch outside windows. |
| Expected runtime | Target: 5–20 s/scenario (much less than RA-3 at ~360 s/scenario). |
| Role in paper | Proposed hybrid method. Tests whether accuracy close to RA-3 is achievable by solving LPs only near scarcity events. |
| Implementation status | Planned (Phase C). |

### RA-3 / M3 — Full-year economic dispatch LP benchmark

| Attribute | Detail |
|-----------|--------|
| Mathematical idea | One 8760-hour storage dispatch LP per scenario (perfect foresight within the scenario). JuMP/HiGHS. Minimise load shedding subject to power balance, storage dynamics, and capacity limits. |
| Expected runtime | ~9–10 s/scenario (Gurobi); ~360 s/scenario (HiGHS). |
| Role in paper | Reliability benchmark. Upper bound on what a storage-aware sequential MC can achieve without unit commitment. |
| Implementation status | Implemented (`src/models/M3EDDispatch.jl`). Out-of-memory fix applied. |

### RA-4 / M4 — HOPE UC/PCM stress-week validation

| Attribute | Detail |
|-----------|--------|
| Mathematical idea | Use RA-3 to identify stress weeks (scenarios and date ranges with concentrated load shedding). Run HOPE (Julia production-cost model with UC) on those stress weeks only. Compare ED vs UC feasibility and metrics. |
| Expected runtime | Minutes to hours per stress week (full UC). |
| Role in paper | High-fidelity validation benchmark. Tests whether ignoring UC constraints in RA-3 materially changes the reliability estimate. |
| Implementation status | Future (Phase E). Interface placeholder in `src/data/ExportHOPECase.jl`. |

---

## 4. Main experiment matrix

### Fixed parameters

| Parameter | Value |
|-----------|-------|
| System | RTS-GMLC single-zone, 8760 h |
| Load scale | 1.20 (calibrated stress case; M3 LOLH ≈ 6–8 h/yr) |
| Storage | 10% of peak load power, 4-hour duration (983 MW / 3,932 MWh) |
| Thermal outage model | Two-state Markov, sequential MC |
| Common random numbers | Single shared `ScenarioSet` per case; all methods use identical outage draws |
| Scenarios | N = 20 for initial VRE sweep; N = 50 for selected cases |
| Seed | 42 |

### VRE penetration / profile cases

| Case label | Wind scale | Solar scale | Notes |
|------------|-----------|-------------|-------|
| VRE-Base | 1.0 | 1.0 | RTS-GMLC as-built (diagnostics used this) |
| VRE-Balanced-1.5x | 1.5 | 1.5 | Modest VRE expansion |
| VRE-Balanced-2x | 2.0 | 2.0 | Moderate VRE expansion |
| VRE-Balanced-3x | 3.0 | 3.0 | High VRE — storage energy shifting increasingly important |
| Solar-heavy | 1.0 | 3.0 | Strong daily cycling; duck-curve stress |
| Wind-heavy | 3.0 | 1.0 | Multi-day wind variability; longer energy depletion risk |

VRE cases are constructed by scaling installed wind and solar capacity:

    P_wind_new  = wind_scale  × P_wind_base
    P_solar_new = solar_scale × P_solar_base

Hourly RTS-GMLC wind and solar capacity-factor profiles are held fixed.
Hourly available VRE generation is therefore:

    wind_avail_h  = wind_cf_h  × P_wind_new
    solar_avail_h = solar_cf_h × P_solar_new

Over-generation is not an artifact; it is part of high-VRE operation and
should be handled through curtailment in dispatch models.  VRE generation
is not clamped to load at the data-building stage; curtailment is an
operational outcome in RA-3 / M3 (and RA-2 outside screened windows).

### VRE penetration metrics to report

Although VRE cases are defined by capacity scaling factors, every VRE case
should report the following penetration metrics so that results can be
interpreted in terms of both installed-capacity share and energy share:

**A. VRE capacity share including storage**

    VRECapShareInclStorage =
        (P_wind + P_solar) /
        (P_thermal + P_wind + P_solar + P_storage)

**B. VRE capacity share excluding storage**

    VRECapShareNoStorage =
        (P_wind + P_solar) /
        (P_thermal + P_wind + P_solar)

**C. Annual available VRE energy share**

    VREEnergyShare =
        sum_h(wind_avail_h + solar_avail_h) / sum_h(load_h)

This is the ratio of total available (pre-curtailment) VRE energy to annual
load.  It uses available generation, not actually dispatched generation, so
it is independent of the dispatch method and can be computed at case-build time.

**D. Net-load statistics**

| Statistic | Definition |
|-----------|-----------|
| net\_load\_min\_mw | min over hours of (load\_h − wind\_avail\_h − solar\_avail\_h) |
| net\_load\_mean\_mw | mean net load (MW) |
| net\_load\_peak\_mw | max net load (MW) |
| negative\_net\_load\_hours | count of hours where net load < 0 |
| vre\_exceeds\_load\_hours | count of hours where wind\_avail\_h + solar\_avail\_h > load\_h |

These statistics are computed at case-build time and stored in
`results/vre_method_comparison/vre_case_summary.csv` (see
`docs/results_index.md`, Section 7).

### Methods compared

| Method | Included in main experiment |
|--------|-----------------------------|
| RA-1a / M1 | Yes — cautionary heuristic baseline |
| RA-1b | Yes — reserve-aware heuristic |
| RA-2 | Yes — event-window LP |
| RA-3 / M3 | Yes — full-year ED benchmark |
| RA-0 | Optional — static capacity-balance classical baseline |
| RA-4 / M4 | Optional — HOPE UC/PCM stress-week validation on selected cases |

---

## 5. Metrics

### Per-run reliability metrics

#### Frequency of shortfall

| Metric | Field name | Definition |
|--------|-----------|-----------|
| LOLH | `lolh` | Loss-of-load hours per year (mean across scenarios) |
| LOLP | `lolp` | Loss-of-load probability = LOLH / n\_hours |
| LOLE days | `lole_days` | Mean days per year with ≥ 1 shortage hour (24-hour windows) |

#### Energy not served

| Metric | Field name | Definition |
|--------|-----------|-----------|
| EUE | `eue` | Expected unserved energy (MWh/yr, mean across scenarios) |
| nEUE | `neue` | Normalised EUE = EUE / annual load energy (fraction; ×10⁶ for ppm) |

#### Shortage event structure

| Metric | Field name | Definition |
|--------|-----------|-----------|
| Event count | `n_shortage_events` | Mean number of distinct contiguous shortage events per scenario |
| Mean duration | `mean_shortage_duration` | Mean duration of shortage events (hours) |
| Max duration | `max_shortage_duration` | Maximum shortage event duration across all scenarios (hours) |
| p95 duration | `p95_shortage_duration` | 95th percentile of event duration pooled across all scenarios (hours) |

#### Shortfall severity

| Metric | Field name | Definition |
|--------|-----------|-----------|
| Max shortfall | `max_shortfall` | Maximum single-hour load shed across all scenario-hours (MW) |
| Mean shortfall | `mean_shortfall_when_shedding` | Mean load shed conditioned on shed > 0 (MW) |

#### Tail risk (scenario distribution)

| Metric | Field name | Definition |
|--------|-----------|-----------|
| p50 scenario EUE | `p50_scenario_eue` | 50th percentile of per-scenario EUE (MWh) |
| p90 scenario EUE | `p90_scenario_eue` | 90th percentile of per-scenario EUE (MWh) |
| p95 scenario EUE | `p95_scenario_eue` | 95th percentile of per-scenario EUE (MWh) |
| p99 scenario EUE | `p99_scenario_eue` | 99th percentile of per-scenario EUE (MWh) |
| CVaR-EUE | `cvar_eue` | Conditional value-at-risk of EUE at 95% (mean of top 5% of scenario EUEs, MWh) |

#### Monte Carlo uncertainty

| Metric | Field name | Definition |
|--------|-----------|-----------|
| LOLH CI95 half-width | `lolh_ci95_halfwidth` | 1.96 × std(per-scenario LOLH) / √N (hours) |
| LOLH CI95 relative | `lolh_ci95_rel_halfwidth` | CI95 half-width / mean LOLH (NaN when mean = 0) |
| EUE CI95 half-width | `eue_ci95_halfwidth` | 1.96 × std(per-scenario EUE) / √N (MWh) |
| EUE CI95 relative | `eue_ci95_rel_halfwidth` | CI95 half-width / mean EUE (NaN when mean = 0) |

#### Runtime

| Metric | Field name | Definition |
|--------|-----------|-----------|
| Runtime | `runtime_s` | Wall-clock time for all scenarios (seconds) |

### Accuracy vs RA-3 benchmark

| Metric | Formula |
|--------|---------|
| LOLH\_error\_h | LOLH\_method − LOLH\_RA3 |
| LOLH\_rel\_error | (LOLH\_method − LOLH\_RA3) / LOLH\_RA3 (NaN when RA3 = 0) |
| EUE\_error\_mwh | EUE\_method − EUE\_RA3 |
| EUE\_rel\_error | (EUE\_method − EUE\_RA3) / EUE\_RA3 (NaN when RA3 = 0) |
| LOLP\_error | LOLP\_method − LOLP\_RA3 |
| LOLE\_days\_error | LOLE\_days\_method − LOLE\_days\_RA3 |
| nEUE\_rel\_error | (nEUE\_method − nEUE\_RA3) / nEUE\_RA3 (NaN when RA3 = 0) |
| CVaR-EUE\_rel\_error | (CVaR\_method − CVaR\_RA3) / CVaR\_RA3 (NaN when RA3 = 0) |
| runtime\_ratio | runtime\_RA3 / runtime\_method (how many times faster than M3) |

These error metrics are the primary outcome for Figures 2–4.  All relative
errors use `NaN` when the benchmark value is zero (high-VRE near-zero-LOLH
cases) to avoid spurious division artefacts.

---

## 6. Expected figures

**Figure 1 — Method hierarchy concept.**
Schematic showing RA-0 through RA-4 on an accuracy × runtime plane.
RA-1a and RA-0 are fast but inaccurate; RA-3 is accurate but slow; RA-1b
and RA-2 are proposed to lie on an improved accuracy-runtime frontier.

**Figure 2 — Reliability metrics vs VRE penetration by method.**
Line chart with VRE scale factor on x-axis (Base, 1.5×, 2×, 3×, solar-heavy,
wind-heavy).  Separate panels for LOLH and EUE.  One line per method
(RA-1a, RA-1b, RA-2, RA-3).  Illustrates how method error evolves as
VRE increases and storage energy-shifting becomes more important.

**Figure 3 — Relative error vs RA-3 by VRE case.**
Bar chart or line chart of EUE\_rel\_error and LOLH\_rel\_error for RA-1a,
RA-1b, RA-2 across VRE cases.  Answers RQ1–RQ3 directly.

**Figure 4 — Accuracy-runtime frontier.**
Scatter plot: x-axis = runtime per scenario (log scale), y-axis = EUE
relative error.  Each marker is one method × VRE-case combination.
Shows whether RA-1b and RA-2 shift the frontier toward low error at low
runtime.

**Figure 5 — Example stress-week dispatch and SOC comparison.**
Hourly time series for one high-risk week in one scenario under RA-1a,
RA-1b, RA-2, and RA-3.  Shows how each method handles storage during a
multi-day shortage event.  Illustrates why RA-1a fails and how RA-1b and
RA-2 differ.

---

## 7. How completed diagnostic experiments feed into new design

| Diagnostic finding | Implication for new design |
|--------------------|---------------------------|
| **Load calibration:** base RTS-GMLC is too reliable (M3 LOLH ≈ 0). load_scale=1.20 gives M3 LOLH ≈ 6–8 h/yr. | **Fixes load_scale=1.20** as the stressed base case for all main experiments. Avoids floor-effects where even the naive heuristic produces zero LOLH. |
| **Storage validation:** 10%/4h is near (but below) 10 h/yr target; increasing duration from 2h to 4h gives the largest M3 LOLH reduction. | **Fixes storage at 10%/4h** as the reference configuration. It sits in a sensitive region of the reliability curve — close enough to meaningful scarcity that method differences will be detectable. |
| **M1 (RA-1a) diagnosis:** priority-2 proactive discharge fires at 2,190 h/yr and depletes SOC to zero before every shortage event. Priority-1 emergency discharge fires zero times. M1 LOLH is identical across all storage sizes. | **Motivates RA-1b:** add an SOC reserve floor to prevent priority-2 from pre-empting emergency storage. Tests whether this simple guard is sufficient to recover RA-3 accuracy. |
| **M2 slowness:** rolling-window LP solves one LP per hour per scenario (~354–380 s/scenario at 8760 h), comparable to RA-3 but without perfect-foresight coherence. | **Motivates RA-2 event-window LP** instead of M2. Rather than solving an LP every hour, screen for risk windows first and solve LPs only there. Target: 5–20 s/scenario vs 360 s for RA-3. |

---

## 8. Next implementation tasks

### Task 1 — Implement RA-1b reserve-aware heuristic ✓ COMPLETE

**Implemented** in `src/models/M1bReserveAwareStorage.jl`.  Config parameter
`reserve_fraction = 0.50` added to `SimConfig`.  Validated in
`scripts/14_run_ra1b_validation.jl` across three storage cases.

**Key validation results** (N=10, seed=42):

| Case | M1b LOLH | M3 LOLH | M1b/M3 | P1 fired |
|------|:--------:|:-------:|:------:|:--------:|
| p05_d4 | 93.6 h | 31.2 h | 3.0× | 10/10 scen |
| p10_d4 | 88.7 h | 7.7 h | 11.5× | 10/10 scen |
| p20_d4 | 78.2 h | 0.0 h | ∞ | 10/10 scen |

P1 emergency discharge fires in all scenarios (vs 0/10 under RA-1a).
RA-1b preserves correct storage ranking; RA-1a is completely flat.
Remaining 3–11× LOLH overestimation confirms that lookahead (RA-2) is needed.
See `docs/ra1b_validation_memo.md` for full analysis and decision record.

---

### Task 2 — Add VRE case builder

**Where:** `scripts/06_build_experiment_cases.jl` (add VRE120 cases to the
`ALL_CASES` list).

**Cases to add:**
```
VRE120_base       — wind=1.0, solar=1.0, load_scale=1.20
VRE120_bal15      — wind=1.5, solar=1.5, load_scale=1.20
VRE120_bal20      — wind=2.0, solar=2.0, load_scale=1.20
VRE120_bal30      — wind=3.0, solar=3.0, load_scale=1.20
VRE120_solar_hvy  — wind=1.0, solar=3.0, load_scale=1.20
VRE120_wind_hvy   — wind=3.0, solar=1.0, load_scale=1.20
```

VRE scaling is applied by multiplying the base installed capacity of each
generator type by its scale factor.  The hourly capacity-factor profiles
from RTS-GMLC DAY_AHEAD data are held fixed; available generation is
`wind_cf_h × P_wind_new` and `solar_cf_h × P_solar_new`.  No clamping to
load is applied at the data-building stage — over-generation is an
operational outcome handled by curtailment in the dispatch models.

**Script:** extend `scripts/06_build_experiment_cases.jl`; rebuild cases
before Task 3.

---

### Task 3 — Run RA-1a, RA-1b, RA-3 across VRE cases ✓ COMPLETE (N=5 sanity run)

**Script:** `scripts/16_run_vre_method_comparison.jl --n-scenarios 5 --seed 42`

**Output:** `results/vre_method_comparison/` — results CSV, errors CSV,
summary.txt.  See `docs/vre_method_comparison_memo.md` for full analysis.

**Key finding — non-monotonic operational-detail error:**
The initial N=5 sweep shows that M1b absolute LOLH error vs M3 is *largest
at low VRE penetration* (VRE120_base: +92.6 h) and shrinks at high VRE
(VRE120_bal30: +11.8 h).  This is not because heuristics improve at high VRE;
it is because high-VRE cases become near-reliable under M3 (M3 LOLH → 1 h),
leaving little room for absolute error regardless of heuristic quality.
Relative error (M1b/M3 ratio) remains 8–14× throughout.

**Revised hypothesis:** Operational detail matters most when adequacy risk is
governed by intertemporal energy management (storage depletion, renewable
drought/ramp structure, scarcity-window timing).  The relationship between VRE
penetration and operational-detail error is non-monotonic.

**Runtime finding:** M3 with Gurobi runs ~9–10 s/scenario (vs ~360 s with
HiGHS — ~35× speedup).  N=20 benchmark runs are now tractable (~3–4 min/case).

**RA-2 priority cases** (ranked by M1b absolute LOLH error):
1. `VRE120_base` (+92.6 h) — highest scarcity risk, largest absolute error
2. `VRE120_bal15` (+45.0 h)
3. `VRE120_wind_hvy` (+32.0 h) — multi-day wind variability hardest for heuristic

**Next step:** Run N=20 on priority cases only; then implement RA-2.

---

### Task 4 — Implement RA-2 event-window LP

**Where:** new file `src/models/M2EventWindowLP.jl`
(replaces the current rolling-window M2).

**Algorithm sketch:**

1. For each scenario, compute the hourly margin:
   `margin[h] = thermal_available[h] + vre[h] - load[h]`
2. Flag risk hours: `margin[h] < risk_margin_mw` (config parameter,
   e.g. `risk_margin_mw = 500.0`).
3. Expand each risk hour by a buffer (`window_buffer_hours`, e.g. 6 h
   before and after).
4. Merge overlapping expanded windows.
5. Solve a storage dispatch LP for each window (minimise load shed,
   subject to storage dynamics and power balance, with SOC boundary
   conditions passed from the heuristic baseline outside the window).
6. Outside windows: use RA-1b heuristic dispatch.

**Config parameters:** `risk_margin_mw`, `window_buffer_hours`.

**Script:** `scripts/16_run_ra2_validation.jl` — single-case sanity check
before broad sweep.

---

### Task 5 — Rerun selected VRE cases with RA-2

**Script:** extend `scripts/15_run_vre_experiment.jl` to include RA-2, or
create `scripts/17_run_vre_all_methods.jl`.

**Purpose:** answers RQ3, RQ4; completes data for all four main figures.

---

### Task 6 — HOPE UC/PCM stress-week validation (future)

**When:** after RA-2 results are available and the paper framing is
confirmed.

**Approach:**
1. For the highest-stress VRE case, extract stress weeks from RA-3
   dispatch (weeks containing the most scenario-hours of load shedding).
2. Export those weeks as HOPE input cases via `ExportHOPECase.jl`.
3. Run HOPE with `unit_commitment = 1`.
4. Compare ED (RA-3) vs UC (RA-4) reliability and dispatch for the
   selected weeks.

**Script:** `scripts/18_run_hope_stress_weeks.jl`.

---

*Document version: Phase C in progress (initial VRE sweep complete, 2026-05-17).*
*Link to completed diagnostic results: [docs/experiment_archive.md](experiment_archive.md)*
*Link to RA-1b validation memo: [docs/ra1b_validation_memo.md](ra1b_validation_memo.md)*
*Link to VRE method comparison memo: [docs/vre_method_comparison_memo.md](vre_method_comparison_memo.md)*
