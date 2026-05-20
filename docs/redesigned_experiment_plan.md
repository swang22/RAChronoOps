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

### RA-1c / M1c — Emergency-only chronological heuristic

| Attribute | Detail |
|-----------|--------|
| Mathematical idea | Priority-1 emergency discharge only: discharge only to cover observed pre-storage shortfall. Charges from any system surplus (thermal headroom included). No priority-2 proactive peak-shaving. Tests whether eliminating proactive discharge removes the M1b SOC-depletion bias. |
| Expected runtime | ~1–2 s/case at N=20 (no LP); ~130× faster than M3. |
| Role in paper | Practice-oriented simple baseline in the M1 → M1b → M1c → M2 → M3 ladder. M1c_VREOnly (appendix): same discharge rule but charges only from VRE surplus — quantifies the charging-source assumption. |
| Implementation status | **Implemented and validated at N=20** (`src/models/M1cEmergencyOnlyStorage.jl`, `src/models/M1cVREOnlyCharge.jl`). M1c matches M3 LOLH exactly at N=20 (case-specific; see caveat in Section 10c of `docs/vre_method_comparison_memo.md`). M1c_VREOnly has +17–77 h LOLH error because p_vre < load at almost all hours in VRE120 cases. See `docs/m1c_charging_assumption_memo.md`. |

### RA-2 — Event-window LP dispatch

| Attribute | Detail |
|-----------|--------|
| Mathematical idea | Screen each scenario for risk windows: hours where (thermal available capacity + VRE) falls within a margin of load. Merge nearby risk hours into contiguous windows with a buffer. Solve a storage dispatch LP only inside each window. Use RA-1b heuristic dispatch outside windows. |
| Expected runtime | 5–10 s/case at N=20 (measured); 20–37× speedup vs M3 (Gurobi). |
| Role in paper | Proposed hybrid method. Tests whether accuracy close to RA-3 is achievable by solving LPs only near scarcity events. |
| Implementation status | **Implemented and validated at N=20** (Phase C complete). `src/models/M2EventWindowLP.jl`. Recommended config: `risk_margin_mw=1000, window_buffer_hours=48`. EUE matches M3 to machine precision; LOLH within 0.18 h mean error. See `docs/ra2_n20_validation_memo.md`. |

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
| RA-1b / M1b | Yes — reserve-aware heuristic |
| RA-1c / M1c | Yes — emergency-only, system-surplus charging |
| RA-1c_VREOnly / M1c_VREOnly | Appendix sensitivity — VRE-surplus-only charging |
| RA-2 / M2 | Yes — event-window LP |
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

**N=20 priority-case run results** (2026-05-17, seed=42, VRE120_base / bal15 / wind_hvy):

| Case | M1b LOLH | M3 LOLH | M1b/M3 | M3 EUE CI95 rel |
|------|:--------:|:-------:|:------:|:---------------:|
| VRE120_base | 83.6 h | 5.95 h | 14× | 60.5% |
| VRE120_bal15 | 36.8 h | 1.35 h | 27× | 107% |
| VRE120_wind_hvy | 25.0 h | 2.25 h | 11× | 77% |

Key finding: N=5 M3 benchmarks were inflated by 47–63%.  The N=20 M1b/M3 ratios (11–27×)
are larger than the N=5 estimates (8–14×), confirming the true bias is worse than initially apparent.
Even at N=20, M3 EUE relative CI95 half-widths are 60–107%, so near-zero LOLH cases need N=50+
for stable benchmarks.  Total runtime: 563.6 s (~9 s/scenario).

**Next step:** Implement RA-2; run N=50 on VRE120_base once RA-2 is available for a stable benchmark.

---

### Task 4 — Implement and validate RA-2 event-window LP ✓ COMPLETE

**Implemented** in `src/models/M2EventWindowLP.jl`.  Config parameters added to `SimConfig`:
`risk_margin_mw`, `window_buffer_hours`, `min_window_length_hours`, `merge_gap_hours`.

**Algorithm:**
1. Compute hourly margin: `margin[h] = thermal_avail[h] + vre[h] − load[h]`
2. Flag risk hours where `margin[h] < risk_margin_mw`.
3. Expand by `window_buffer_hours` on each side, merge (gap ≤ `merge_gap_hours`), enforce `min_window_length_hours`.
4. Solve a JuMP/HiGHS LP for each window (min VOLL × load_shed, s.t. power balance and storage dynamics).
5. Use RA-1b heuristic outside windows.

**Validation scripts:**
- `scripts/17_run_ra2_priority_validation.jl` — N=5 M3-benchmark validation
- `scripts/18_compare_m2_m3_shortage_patterns.jl` — shortage-hour pattern diagnosis
- `scripts/19_run_ra2_parameter_sensitivity.jl` — N=5 parameter sensitivity (rm × buf grid)
- `scripts/20_run_ra2_n20_selected_params.jl` — N=20 selected-parameter validation ✓

**N=20 selected-parameter validation results** (2026-05-17, seed=42; commit `ab63f99`):

| Config | Mean LOLH abs err | Mean runtime | Mean speedup vs M3 | Mean coverage | LP failures |
|--------|:-----------------:|:------------:|:------------------:|:-------------:|:-----------:|
| rm=1000 / buf=48 | **0.183 h** | 9.3 s | 20.7× | 29.3% | 0 |
| rm=800 / buf=24 | 0.233 h | **5.1 s** | **37.3×** | 23.6% | 0 |

EUE and CVaR-EUE match M3 to machine precision (< 10⁻⁹ MWh) for **both** configurations and
all three priority cases.  M1b LOLH errors (+1000%–+2600%) are reduced to −3% to −13% by RA-2.

**Key finding:** The remaining RA-2 LOLH underestimation (−0.05 to −0.30 h) is smaller in
magnitude than the M3 CI95 half-widths (0.94–1.57 h) at N=20.  The apparent bias cannot
be distinguished from sampling noise with 20 scenarios.

**Recommended main-paper configuration:** `risk_margin_mw=1000, window_buffer_hours=48`.
**Runtime-efficient alternative:** `risk_margin_mw=800, window_buffer_hours=24`.

See `docs/ra2_n20_validation_memo.md` for full analysis and decision record.

---

### Task 5 — Add M1c baseline and charging-assumption sensitivity ✓ COMPLETE

**Status:** Complete (commits `22dd7ff`, `091f0ab`, `142c7f6`).

**M1c (RA-1c):** Implemented in `src/models/M1cEmergencyOnlyStorage.jl`.  Emergency-only
storage: priority-1 discharge to cover shortfalls; charging from any system surplus (thermal
headroom included); no priority-2 proactive discharge.

**N=20 compact comparison** (`scripts/21_run_m1c_comparison.jl`, M1 → M1b → M1c → M2 → M3):
M1c matches M3 LOLH exactly (0.00 h error) across all three priority cases at 90–130× speedup.

**SOC and charging diagnostic** (`scripts/22_diagnose_m1c_m3_soc_and_charging.jl`):
M1c charges 87–100% from thermal headroom (not VRE surplus). SOC trajectories differ from
M3 by 54–58% of battery capacity. The M1c = M3 LOLH match is case/sample-specific.

**Charging-assumption sensitivity** (`scripts/23_compare_m1c_charging_assumptions.jl`):
M1c_VREOnly (`src/models/M1cVREOnlyCharge.jl`) charges only when `p_vre[h] > load[h]`.
In VRE120 cases, p_vre < load at 87–100% of hours, so M1c_VREOnly rarely charges and
reduces to an effective no-storage baseline.  LOLH errors: +17–77 h (755%–2526%).

#### Emergency-only storage and charging-source sensitivity (N=20, seed=42)

| Case | M3 LOLH (h) | M1c_current LOLH (h) | M1c_VREOnly LOLH (h) | M1c_VREOnly error (h) |
|------|:-----------:|:--------------------:|:--------------------:|:---------------------:|
| VRE120_base | 5.95 | **5.95** | 82.80 | +76.85 |
| VRE120_bal15 | 1.35 | **1.35** | 35.45 | +34.10 |
| VRE120_wind_hvy | 2.25 | **2.25** | 19.25 | +17.00 |

**Caveat:** The exact M1c_current = M3 match should not be interpreted as a structural
equivalence.  The SOC diagnostic shows trajectories differ substantially (mean |SOC_diff|
= 54–58% of battery capacity); the match is case/sample-specific and depends on
charging-access assumptions.

**Model hierarchy confirmed:** M1 → M1b → M1c → M2 → M3, with M1c_VREOnly as appendix.
See `docs/m1c_charging_assumption_memo.md` for full analysis.

**M1c recharge-stress robustness** (`scripts/24_stress_test_m1c_recharge_limits.jl`, commit `2286c2e`):
Six in-memory VRE120_base variants (higher load, smaller/larger storage, higher M3 cycling cost) tested at N=20.
M1c_current matched M3 exactly (0.00 h LOLH error) across all six stress cases, including M3 LOLH up to 27.4 h.
M2 within −0.65 h throughout.  M1c_VREOnly errors: +59.9 to +153.6 h.

| Stress case | M3 LOLH (h) | M1c_current error (h) | M2 error (h) |
|-------------|:-----------:|:---------------------:|:------------:|
| base_reference | 5.95 | **+0.00** | −0.20 |
| load_scale_1225 | 13.25 | **+0.00** | −0.20 |
| load_scale_125 | 24.75 | **+0.00** | −0.65 |
| storage_p05_d4 | 27.40 | **+0.00** | −0.50 |
| storage_p10_d8 | 2.45 | **+0.00** | +0.00 |
| cycling_cost_high | 5.95 | **+0.00** | −0.20 |

**Interpretation:** M1c is a strong fast benchmark under single-zone ED assumptions, conditional on thermal headroom being available for recharging.  Robustness is not structural — it holds in the VRE120_base parameter range where shortage events are thermally driven and charging headroom is ample.  See `docs/vre_method_comparison_memo.md` Section 11 for full analysis.

No further heuristic variants are planned.

---

### Task 6 — Paper/writeup tables and figures (near-term)

**Status:** Active — this is the main near-term priority.

**Purpose:** Produce the tables and figures needed for the paper.  All key
computational experiments are complete (Tasks 1–5 including stress test).

**Target outputs:**
- Table 1: model hierarchy (M1 → M1b → M1c → M2 → M3), runtime, LOLH error
- Table 2: N=20 main results (three priority VRE cases, all models)
- Table 3: M1c stress robustness (six stress cases)
- Figure 1: accuracy-runtime frontier scatter (all methods × three VRE cases)
- Figure 2: reliability metrics vs method (VRE120_base, bar or panel chart)
- Figure 3: example stress-week SOC and dispatch (M1c vs M2 vs M3)
- Appendix table: M1c_VREOnly charging-source sensitivity

---

### Task 7 — N=50 VRE120_base (optional CI tightening)

**Status:** Optional; lower priority than Task 6.

**Purpose:** M3 LOLH CI95 relative half-width is 54.7% at N=20 for VRE120_base.
N=50 reduces this to approximately 35% and would allow a definitive quantification
of any residual RA-2 LOLH bias.  Run only if tighter confidence intervals are
needed to support the paper's claims about M2 accuracy.

**Script:** `scripts/20_run_ra2_n20_selected_params.jl --n-scenarios 50 --seed 42 --cases VRE120_base`

---

### Task 8 — HOPE UC/PCM full-year validation ✓ COMPLETE (N=5 + N=20)

**Purpose:** Validate HOPE-ED against M3 (full-year LP benchmark) and
quantify the LOLH/EUE impact of adding unit-commitment constraints (HOPE-UC).

**Scripts:**
- `scripts/25_build_hope_full_year_cases.jl` — export HOPE input cases
- `scripts/29_run_hope_n5_pilot.jl` — run HOPE per scenario
- `scripts/27_collect_hope_results.jl` — collect reliability metrics
- `scripts/30_compare_all_models_hope_n5.jl` — 7-model comparison
- `scripts/32_scale_n20.jl` — full N=20 pipeline (export → run → collect → compare)

**Root-cause finding (2026-05-19):** The initial N=5 HOPE-ED run showed a
+107.28 MWh mean EUE excess over M3.  Investigation found the cause was a
formulation mismatch in the exporter: `scripts/25_build_hope_full_year_cases.jl`
was passing real M3 ramp rates into HOPE for both ED and UC modes.  M3's ED LP
has no ramp constraints; HOPE enforces them.  For an NGCC unit (355 MW,
4.14 MW/min): RU=0.6997, limiting output to 248.4 MW in the hour before a
forced outage and creating a 106.6 MW gap that M3 does not see.

**Fix:** Set `RU=RD=1.0` for ED mode only in the exporter (trivially
inactive constraint = no ramp limit), preserving real ramp rates for UC.
See `results/hope_n5_pilot_diagnostics/ramp_constraint_root_cause.txt`.

**N=20 results (VRE120_base, scenarios 1–20, seed=42, post-fix):**

| Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | Runtime (s) | vs M3 EUE |
|---|---|---|---|---|---|
| M3 | 6.0 | **2479.17** | 9782.93 | 190.5 | — |
| HOPE-ED | 6.2 | **2479.17** | 9782.93 | 2355.5 | 0.00 MWh |
| HOPE-UC | 7.2 | **2479.17** | 9782.93 | 11438.4 | 0.00 MWh |

Key findings:
- HOPE-ED reproduces M3 EUE exactly (Δ = 0.00 MWh) — validates the
  exporter and the HOPE PCM.jl implementation as a faithful M3 reimplementation.
- HOPE-UC adds commitment/ramp constraints that spread the same total EUE
  over more, shorter events (+1.2 h LOLH); total energy unserved unchanged.
- HOPE-UC is 60× slower than M3 (572 s/scenario vs 9.5 s/scenario).
- LOLH differences between models (±0–2 h) are LP degeneracy, not EUE errors.

**Remaining directions (lower-priority):**

**8a. Constrained-charging / transmission tests** — Introduce binding
constraints that reduce thermal headroom (very high VRE penetration,
multi-zone transmission limits, must-run constraints).  Identify the
parameter region where M1c diverges from M3 and M2's LP structure recovers
accuracy.  Script: extend `scripts/24_stress_test_m1c_recharge_limits.jl`.

**8b. Production UC run** — Real Pmin and start-up costs.  Requires either
`operation_reserve_mode: 1` or the upstream HOPE fix for the `CLeL_con`
commitment-variable term.  When: after paper (Task 6) is complete.

---

*Document version: Phase F complete — HOPE N=20 validation done, ramp-rate fix confirmed (2026-05-19).*
*Link to completed diagnostic results: [docs/experiment_archive.md](experiment_archive.md)*
*Link to RA-1b validation memo: [docs/ra1b_validation_memo.md](ra1b_validation_memo.md)*
*Link to VRE method comparison memo: [docs/vre_method_comparison_memo.md](vre_method_comparison_memo.md)*
*Link to RA-2 N=20 validation memo: [docs/ra2_n20_validation_memo.md](ra2_n20_validation_memo.md)*
*Link to M1c charging-assumption memo: [docs/m1c_charging_assumption_memo.md](m1c_charging_assumption_memo.md)*
