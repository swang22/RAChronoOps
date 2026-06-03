# Current Findings Synthesis

**Date:** 2026-05-23

---

## 1. Overview

This document summarises the key findings from the completed RAChronoOps
experiment sequence.  The project builds on prior work showing that storage
dispatch affects adequacy metrics (Gonzato et al. 2023; PRAS/Stephen 2021) and
provides a systematic storage-dispatch fidelity ladder for sequential Monte Carlo
resource adequacy: from naive proactive heuristics, to PRAS/Evans-style
emergency-only dispatch, to event-window LP, full-year ED, PCM-ED, and PCM-UCED.
Using common random numbers on a public RTS-GMLC test system, the project
quantifies which approximations preserve EUE, LOLH, CVaR-EUE, and runtime
performance, and introduces a storage-energy sufficiency-bound diagnostic that
explains when simple storage-aware MC methods recover full-year ED EUE.

The five core contributions are:

1. **Traditional MC baseline validation:** Without storage, Traditional MC reproduces
   Full-Year ED-MC, PCM-ED, and PCM-UCED reliability metrics exactly in the tested
   single-zone system.

2. **Storage-dispatch fidelity ladder:** Naive proactive dispatch, reserve-floor
   dispatch, PRAS/Evans-style emergency-only dispatch, event-window LP, full-year
   ED, PCM-ED, and PCM-UCED are compared under common random numbers.

3. **Error and runtime quantification:** The project quantifies how storage dispatch
   approximations affect LOLH, EUE, CVaR-EUE, event timing, and runtime.

4. **Storage-energy sufficiency diagnostic:** A diagnostic bound shows why
   emergency-only and event-window LP methods recover full-year ED-MC EUE in the
   tested cases.

5. **PCM-UCED validation:** In the tested single-zone RTS-GMLC cases, PCM-UCED
   changes load-shedding timing and LOLH but not EUE, while requiring substantially
   higher runtime.

**Note on Emergency-Only MC (M1c):**
Emergency-Only Storage MC is a PRAS/Evans-style conservative adequacy dispatch rule:
it charges from system surplus and discharges only during pre-storage shortfall.
Its role in this project is not novelty as a standalone dispatch rule — analogous
rules appear in PRAS (Stephen 2021) and Evans et al. (2019) — but as a validated
low-cost baseline within the broader method ladder.

---

## 2. Model hierarchy

| Label | Paper name | Method | Runtime/scenario | Role |
|-------|-----------|--------|-----------------|------|
| MC-NoStorage | Traditional MC | Classical hourly capacity check, no storage | < 1 s | No-storage baseline |
| M1 / RA-1a | Naive Storage MC | Naive peak-shaving heuristic | ~1 s | Cautionary failure case |
| M1b / RA-1b | Reserve-Floor MC | Reserve-aware heuristic (SOC floor) | ~1 s | Improved heuristic |
| M1c / RA-1c | Emergency-Only MC | Emergency-only heuristic, system-surplus charging | ~1–2 s | Near-M3 simple model |
| M1c\_VREOnly | VRE-Surplus MC | M1c with VRE-surplus-only charging | ~1–2 s | Appendix sensitivity |
| M1d / RA-1d | Risk-Hour MC | Risk-hour allocation heuristic (earliest\_first / largest\_first) | ~1–2 s | Within-event allocation study |
| M2 / RA-2 | Event-Window LP-MC | Event-window LP (rm=1000 MW, buf=48 h) | ~5–10 s | Proposed hybrid method |
| M3 / RA-3 | Full-Year ED-MC | Full-year ED LP (Gurobi) | ~9–10 s | LP benchmark |
| HOPE-ED | PCM-ED | Full-year HOPE ED LP | ~120 s | PCM validation (ED mode) |
| HOPE-UC / M4 | PCM-UCED | Full-year HOPE UC MILP | ~540–570 s | High-fidelity UC benchmark |

All methods use identical Monte Carlo outage scenarios (common random numbers).

---

## 3. Key finding 1: traditional MC is valid without storage

When storage is absent, the classical hourly capacity check equals the
full-year ED LP, the HOPE ED LP, and the HOPE UC MILP exactly.

**Table A — No-storage validation, N=20:**

| Case | MC-NoStorage EUE (MWh) | M3-NoStorage EUE (MWh) | ΔEUE |
|------|----------------------|----------------------|------|
| VRE120\_base | 31,017 | 31,017 | 0.00 MWh |
| VRE120\_wind\_hvy | 15,801 | 15,801 | 0.00 MWh |

**Table B — HOPE no-storage validation, N=5 (VRE120\_base\_nostorage):**

| Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | Runtime (s) |
|-------|----------|-----------|-----------|-------------|
| MC-NoStorage | 115.6 | 41,846 | 54,383 | 0.5 |
| M3-NoStorage | 115.6 | 41,846 | 54,383 | 40.0 |
| HOPE-ED-NoStorage | 115.6 | 41,846 | 54,383 | 614.3 |
| HOPE-UC-NoStorage | 115.6 | 41,846 | 54,383 | 4,331.1 |

**Interpretation:** Without storage there is no intertemporal state variable
linking hours together.  Load shedding in any hour is determined entirely by
available thermal and VRE capacity — an exogenous quantity fixed by the Monte
Carlo outage draw before the dispatch problem is formulated.  Whether dispatch
is solved as a simple capacity check, an LP, or a MILP, the total MW served
per hour is identical.  Traditional MC is a valid baseline for the no-storage RA
setting.  UC adds 7× runtime overhead with zero reliability benefit in this case.

---

## 4. Key finding 2: storage introduces intertemporal operation

Once storage is added, the SOC state links hours together.  The storage
dispatch strategy now matters: how the battery is charged and discharged
across the 8760-hour year determines whether energy is available during
shortage events.

The diagnostic sequence showed:
- The naive peak-shaving heuristic (M1) depletes SOC to zero before 100% of
  shortage events; priority-1 emergency discharge fires zero times.  M1 LOLH
  is insensitive to storage size — a heuristic failure, not a data issue.
- Adding an SOC floor (M1b) reduces the bias but does not eliminate it.
- Eliminating proactive discharge entirely (M1c) removes the depletion
  mechanism and recovers the LP benchmark.

---

## 5. Key finding 3: naive storage heuristics fail

M1 and M1b substantially overestimate reliability risk relative to the LP
benchmark M3.  Both are evaluated at N=20 (same seed and ScenarioSet as M1c/M2/M3)
via `scripts/41_run_m1_m1b_n20_for_paper.jl`.
The bias is consistent across all tested VRE profiles.

| Model | LOLH error vs M3 | EUE error vs M3 |
|-------|-----------------|----------------|
| M1 | +89.5 h (base), +50.1 h (wind-hvy) | +28,538 MWh (base), +15,153 MWh (wind-hvy) |
| M1b | +77.6 h (base), +22.8 h (wind-hvy) | +25,793 MWh (base), +8,334 MWh (wind-hvy) |
| M1c | Near zero | Near zero |
| M1d\_earliest | Near zero | Near zero (exact match) |
| M1d\_largest | Moderate positive (+2.4 h base) | Near zero (exact match) |
| M2 | < 0.2 h | Near-machine precision |

M1d\_earliest matches M1c and M3 EUE exactly (per-scenario) across all tested
cases.  M1d\_largest produces higher LOLH because within-event reallocation
to the largest shortfall hours leaves smaller shortfall hours partially served,
spreading the same energy deficit across more shedding hours.

M1c\_VREOnly fails for a different reason: at near-unit VRE capacity factors,
VRE capacity factor is below 1 at nearly all hours, so VRE-only charging
leaves storage perpetually undercharged (+17–77 h LOLH error).

---

## 6. Key finding 4 (theoretical): storage-energy sufficiency bound and recharge-window diagnostic

Script 39 computes, per scenario and shortage event, the maximum EUE reduction
that storage could achieve given the surplus energy available in a lookback
window before the event:

```
coverage_bound = min(
    pre_event_EUE,                              -- energy ceiling
    feasible_discharge_energy,                  -- SOC × η_dis after 72 h charging
    Σ min(shortfall[h], storage_power_mw)       -- power-limited coverage
)
residual_eue_bound = pre_event_EUE − coverage_bound
```

**Table E — Sufficiency bound vs dispatch models, N=20, seed=42, lookback=72 h:**

| Case | Pre-storage EUE | Bound EUE | M3 EUE | Bound − M3 | Sufficiency ratio |
|------|----------------|-----------|--------|-----------|-------------------|
| VRE120\_base | 31,017 MWh | 2,479 MWh | 2,479 MWh | 0.00 MWh | 0.941 |
| VRE120\_wind\_hvy | 15,801 MWh | 648 MWh | 648 MWh | 0.00 MWh | 0.972 |

Per-scenario EUE matches exactly across bound, M1c, M2, and M3 in both cases.

**Why this explains EUE convergence in the tested cases:**
When the sufficiency bound is tight (bound ≈ M3 EUE), any dispatch model that
(1) charges from system surplus and (2) discharges only at shortfall hours will
achieve the same residual EUE.  In these tested RTS-GMLC cases, there is no
additional EUE reduction available beyond what the storage energy budget allows —
the residual EUE is governed by storage energy availability rather than dispatch
model complexity.  This finding is empirical and scoped to the tested system
configurations; other systems with different storage-to-load ratios or shortage
patterns may not exhibit the same convergence.

**Why LOLH/event timing can still differ even when EUE matches:**
EUE is determined by the total energy deficit, which is set by the storage
energy budget.  LOLH counts hours with any positive load shed.  Two models
can produce identical total unserved energy but different LOLH if they
distribute that energy differently across hours within an event:
- M1d\_largest allocates storage to the highest-shortfall hours first →
  smaller shortfall hours remain partially served → more hours shed any load.
- LP degeneracy (M2 vs M3, HOPE-ED vs M3) means multiple optimal dispatch
  trajectories achieve the same EUE objective while assigning load shed to
  different subsets of hours.
- HOPE-UC commitment constraints spread the same energy deficit into more
  shortage hours via min-up/down binding on thermal generators.

**Why M1/M1b fail:**
Proactive discharge in non-shortage hours depletes SOC before shortage events.
The storage enters the event with less energy than the bound allows, so
coverage drops below the bound and residual EUE rises above M3.

In both tested RTS-GMLC cases, the binding constraint is **energy (MWh), not
power (MW)**: the storage power limit (983 MW) is not the bottleneck for the
73-unit system.  The sufficiency ratio (0.941–0.972) is the fraction of
pre-storage EUE that the storage budget can cover; the 2.8–5.9% uncoverable
residual corresponds exactly to the M3 EUE.

**Recharge-window diagnostic (script 51/52):**
An additional diagnostic examines how quickly M3 storage accumulates charge
comparable to each shortage event's EUE.  For each M3 residual shortage event, the
cumulative storage charge in lookback windows of 6, 12, 24, 48, 72, and 168 h
before event start is compared to the event EUE.  This is a recharge-window
availability proxy, not a physical feasibility proof.

Key results (N=20, seed=42, `results/paper_tables/recharge_window_diagnostic.csv`):

| Case | Events | EUE (20 scen) | With comparable charge ≤ 12 h | With comparable charge ≤ 24 h | Needs > 168 h |
|------|--------|--------------|------------------------------|------------------------------|--------------|
| VRE120\_base | 40 | 49,583 MWh | 65% events / 51% EUE | 97.5% events / 90.8% EUE | 1 event |
| VRE120\_wind\_hvy | 17 | 12,965 MWh | 53% events / 31% EUE | 100% events / 100% EUE | 0 events |

The vast majority of residual shortage events in both portfolios are associated with
comparable pre-event charge accumulated within 24 h.  This supports the emergency-only
MCS finding by showing that, in the full-year ED benchmark, comparable storage charge
is accumulated shortly before most shortage events.  The diagnostic is not a physical
feasibility proof, but it indicates that the tested cases mostly depend on short
recharge windows rather than long-horizon energy shifting.  One balanced-VRE event
requires > 168 h of pre-event charging — it represents a large, deep shortage where
the entire storage budget must have been charged well in advance; this event is a
candidate where full-year ED optimization provides more value than a simple
emergency-only heuristic (though EUE still matches, because the total budget is the
same regardless of dispatch method).

---

## 7. Key finding 5: emergency-only dispatch and event-window LP recover the ED/PCM benchmark

Emergency-Only MC (M1c, a PRAS/Evans-style conservative dispatch baseline) and
Event-Window LP-MC (M2, the main scalable optimization-assisted method) both
closely match M3 EUE and CVaR while being 13–130× faster.

M2 is particularly important as the proposed scalable method: it bridges the gap
between conservative heuristic dispatch and full-year ED by solving LPs only around
screened scarcity windows, and is the recommended approach when the simple
emergency-only rule may not be sufficient in systems with more complex storage
dynamics.

**Table C — Storage wind-heavy PCM comparison, N=5 (VRE120\_wind\_hvy):**

| Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | Runtime (s) |
|-------|----------|-----------|-----------|-------------|
| M1c | 4.4 | 1,113 | 2,793 | 0.6 |
| M2 | 3.8 | 1,113 | 2,793 | 2.5 |
| M3 | 4.4 | 1,113 | 2,793 | 44.3 |
| PCM-ED | 3.8 | 1,113 | 2,793 | 587.6 |
| PCM-UCED | 4.2 | 1,113 | 2,793 | 2,712.2 |

EUE is identical across all five models (exact per-scenario match).
LOLH varies by up to 0.6 h across models, reflecting LP degeneracy
(multiple optimal dispatch trajectories at the same EUE objective value).

**M2 recommended config:** `risk_margin_mw=1000, window_buffer_hours=48`.
This gives < 0.2 h mean LOLH error and near-machine-precision EUE at
5–10 s/scenario (20–37× faster than M3 with Gurobi).

---

## 8. Key finding 6: PCM-UCED affects timing/LOLH, not EUE in tested cases

**Table D — PCM-ED vs PCM-UCED (storage-enabled):**

| Case | Model | LOLH (h) | EUE (MWh) | Runtime (s) |
|------|-------|----------|-----------|-------------|
| VRE120\_base, N=20 | PCM-ED | 6.2 | 2,479 | 2,356 |
| VRE120\_base, N=20 | PCM-UCED | 7.2 | 2,479 | 11,438 |
| VRE120\_wind\_hvy, N=5 | PCM-ED | 3.8 | 1,113 | 588 |
| VRE120\_wind\_hvy, N=5 | PCM-UCED | 4.2 | 1,113 | 2,712 |

In both tested cases, PCM-UCED (HOPE-UC) and PCM-ED (HOPE-ED) produce
identical EUE.  PCM-UCED increases LOLH by 1.0 h (base) or 0.4 h
(wind-heavy): the same total energy deficit is redistributed into more
shortage hours by min-up/down constraints on committed generators.

**Mechanism:** UC commitment constraints bind intertemporal storage dispatch.
Storage must charge/discharge around the thermal commitment schedule, which
can shift the timing of storage discharge and spread the same energy shortage
across more hours.  Without storage this effect is absent (Phase H result).

**Runtime penalty:** PCM-UCED is 4–5× slower than PCM-ED with zero EUE
benefit in the tested cases.  Running UC for every scenario is not warranted
based on current evidence; UC is recommended only as a sensitivity check on
LOLH/event timing.

---

## 9. Scope and assumptions

The study evaluates **centralized adequacy-oriented storage dispatch** — dispatch
that charges from system surplus and discharges to serve load during shortfall.
The following are explicitly outside scope:

- **Merchant storage behavior:** no bidding, capacity withholding, strategic
  behavior, or decision-dependent storage availability.
- **Operating reserves and ancillary services:** no reserve requirements, no
  frequency regulation, no forecast-error-driven unit commitment.  These go beyond
  the traditional MC adequacy assumptions being extended here.
- **Network constraints:** the current validation uses a single copper-plate zone.
  Transmission-constrained multi-area systems are future work.
- **Imperfect foresight and investment re-optimization:** all dispatch models assume
  full within-scenario foresight; long-run investment dynamics are outside scope.

These exclusions are consistent with traditional RA conventions and do not
invalidate the method comparisons; they define the boundary of applicability.

---

## 10. LOLP note

LOLP (loss-of-load probability) is computed as the fraction of simulated hours with
positive load shedding.  In hourly sequential simulations with 8760 h/yr:

```
LOLP = LOLH / 8760
```

LOLP is therefore a direct normalization of LOLH and carries no additional
information in this setting.  Main paper tables emphasize LOLH, EUE, CVaR-EUE,
and runtime; LOLP is available in all result CSVs via the `lolp` column.

---

## 11. Key caveats

1. **Single-zone RTS-GMLC system.** All conclusions are for a single copper-
   plate zone with 73 thermal units, 983 MW / 3,932 MWh storage, and a
   calibrated load scale of 1.20.  Multi-zone or network-constrained systems
   may show different behaviour.

2. **Storage charging assumption matters.** M1c (system-surplus charging)
   matches M3; M1c\_VREOnly (VRE-surplus-only charging) does not.  The
   charging assumption should be documented carefully when comparing methods.

3. **LOLH/event timing differences should be interpreted cautiously.**
   LOLH differences of 0.4–1.0 h between HOPE-ED and HOPE-UC are within the
   MC sampling uncertainty at N=5–20.  EUE is the more statistically stable
   metric at this sample size.

4. **PCM-UCED EUE invariance is scoped to tested cases.** The finding that
   PCM-UCED does not change EUE applies to the tested single-zone RTS-GMLC
   cases.  Commitment constraints may have a larger effect in systems with
   tighter flexibility, stronger ramping limits, or additional operating
   constraints.

5. **N=5 wind-heavy results are indicative only.** The HOPE-UC wind-heavy
   comparison used 5 scenarios; per-scenario EUE values are exact matches,
   but LOLH statistics have wider confidence intervals than N=20.

---

## 12. Key finding 7: EUE convergence is robust across storage configurations

Script 43 ran M1c, M2, M3, and the sufficiency bound across 18 storage
robustness variants (Experiment F: two source cases × duration sweep,
power sweep, and load-stress variants), all at N=20, seed=42.

**Result: M1c and M2 match M3 EUE exactly (ΔEUE = 0.0 MWh) across all
18 variants.**

Selected results (VRE120\_base variants):

| Variant | Storage | Load scale | M1c EUE | M2 EUE | M3 EUE | Suf. ratio |
|---------|---------|-----------|---------|--------|--------|-----------|
| dur2h | 983 MW / 1,966 MWh | 1.20 | 8,501 | 8,501 | 8,501 | 0.768 |
| dur4h (base) | 983 MW / 3,932 MWh | 1.20 | 2,479 | 2,479 | 2,479 | 0.941 |
| dur8h | 983 MW / 7,864 MWh | 1.20 | 359 | 359 | 359 | 0.992 |
| dur12h | 983 MW / 11,796 MWh | 1.20 | 359 | 359 | 359 | 0.992 |
| pwr0p5x | 492 MW / 1,966 MWh | 1.20 | 8,770 | 8,770 | 8,770 | — |
| pwr2p0x | 1,966 MW / 7,864 MWh | 1.20 | 42 | 42 | 42 | 1.000 |
| ls1p225 | 983 MW / 3,932 MWh | 1.225 | 6,185 | 6,185 | 6,185 | — |
| ls1p25 | 983 MW / 3,932 MWh | 1.25 | 12,780 | 12,780 | 12,780 | — |
| dur2h\_ls1p225 | 983 MW / 1,966 MWh | 1.225 | 17,259 | 17,259 | 17,259 | 0.691 |

The sufficiency ratio drops as low as 0.691 (short 2h storage + load stress),
yet EUE convergence still holds.  When the bound is this tight, there is no
additional EUE reduction achievable; any reasonable dispatch that charges from
surplus and discharges at shortfall hours attains the same bound.

**Runtime (mean across 18 variants):**
M1c ×101 speedup vs M3; M2 ×22 speedup vs M3.

M2 LOLH deviation vs M3: ≤ ±1.5 h across all variants (largest for dur2h
+ load stress, where shortage events are longer and more numerous).

**Source:** `results/storage_robustness_sweep/` (scripts 42 + 43).

---

## 13. Key finding 8: sampling convergence validates N=20 baseline

Script 44 ran MC-NoStorage, M1c, M2, and M3 across N=20, 50, 100, and 200
scenarios using a nested scenario design (all N share the first N rows of a
common N=200 parent set, seed=42).  This confirms that the method-error
results from prior experiments are not small-sample artifacts.

**Result: M1c and M2 match M3 EUE exactly (ΔEUE = 0.0 MWh) at N=20,
50, 100, and 200 — the EUE convergence result is stable across N.
M1c also matches M3 LOLH exactly (ΔLOLH = 0.00 h) at all N.**

**CI95 shrinkage (N=20 → N=200):**

| N | LOLH (h) | CI95-LOLH | EUE (MWh) | CI95-EUE |
|---|----------|-----------|-----------|----------|
| 20 | 5.95 | 3.25 h | 2,479 | 1,500 MWh |
| 50 | 6.64 | 2.22 h | 2,889 | 1,091 MWh |
| 100 | 6.25 | 1.46 h | 2,703 | 782 MWh |
| 200 | 7.00 | 1.08 h | 3,180 | 643 MWh |

CI95-LOLH shrinks 3.0× (N=20→200), near the theoretical 1/√N = 3.2×.
CI95-EUE shrinks 2.3× — slower than 1/√N because EUE has a heavy-tailed
distribution; the sample variance itself grows as new extreme scenarios are
included at higher N.

**Method error vs sampling uncertainty:**

At every N, |M1c−M3| EUE = 0.0 MWh vs CI95-EUE = 1,500 MWh (N=20).
M2 EUE error = 0.0 MWh at all N; M2 LOLH is −0.2 to −0.45 h below M3
(LP degeneracy — M2 concentrates the deficit into shorter events).
A statistical test at N=20 cannot distinguish M1c or M2 from M3 on EUE.

**Event-shape metrics (at N=100):**

| Model | LOLH (h) | Mean event dur. (h) | Mean event E (MWh) | Max shortfall (MW) |
|-------|----------|--------------------|--------------------|-------------------|
| MC-NoStorage | 95.7 | 3.59 | 1,202 | 1,063 |
| M1c | 6.2 | 3.03 | 1,312 | 559 |
| M2 | 5.8 | 2.07 | 965 | 651 |
| M3 | 6.2 | 3.03 | 1,312 | 559 |

M1c and M3 produce identical event-shape metrics.  M2's lower LOLH (−0.45 h
vs M3 at N=100) traces to shorter mean event duration (2.07 vs 3.03 h) with
more events — LP degeneracy allows M2 to spread the same energy deficit
across more but shorter events.  EUE is identical because total deficit is
unchanged.

**Source:** `results/sampling_convergence/` (script 44).

---

## 14. Recommended next steps

1. **Paper tables and figures** are the primary remaining deliverable.
   The robustness sweep results from §12 and the sampling convergence
   results from §13 strengthen the main claims and can populate appendices.

2. **Consider N=20 wind-heavy HOPE-UC** if the paper requires a matched
   comparison with the base case N=20 run.  Projected runtime: ~3 h.
   Based on current evidence this is not required for the core claims.

3. **M1d risk-hour allocation heuristic is implemented** (script 38).
   The storage-energy sufficiency bound (script 39) provides the theoretical
   justification for EUE convergence across M1c/M1d/M2/M3.  Both are
   available for inclusion as supporting material.

---

## 15. Multi-metric reporting update (2026-05-25)

Following ESIG (2024) guidance on multi-metric RA reporting, NEUE (normalized
expected unserved energy) and event-shape metrics were added to all main result
tables and a new Appendix B in the paper.

**NEUE definition:**

```
NEUE_ppm = EUE_MWh / annual_load_MWh × 1e6
```

Annual load for VRE120 cases: 45,073,588 MWh/yr (load_scale=1.2 × RTS-GMLC
base 37,561 GWh).  Back-computed from M3 N=20 row in
`results/sampling_convergence/convergence_aggregate_metrics.csv`.

**Key NEUE values (N=20):**

| Case / method | EUE (MWh) | NEUE (ppm) |
|---------------|-----------|-----------|
| Balanced VRE, no-storage MC | 31,017 | 688 |
| Balanced VRE, SOC-floor MCS | 28,272 | 627 |
| Balanced VRE, M1c / M2 / M3 | 2,479 | 55 |
| Wind-heavy VRE, no-storage MC | 15,801 | 351 |
| Wind-heavy VRE, M1c / M2 / M3 | 1,113 | 25 |
| Balanced VRE, PCM check (no storage) | 41,812 | 928 |

**Event-shape finding (Appendix B):**

Across M1c, M2, M3, HOPE-ED, and HOPE-UC, EUE and NEUE are identical (55 ppm
balanced / 25 ppm wind-heavy), but LOLH, event count, mean duration, and maximum
shortfall differ.  PCM methods (HOPE-ED/HOPE-UC) fragment the same energy deficit
into more, shorter events with higher maximum shortfall than MCS methods.  This
illustrates why EUE equivalence should not be interpreted as equivalence across all
reliability dimensions, motivating multi-metric reporting.

**New result CSVs generated by `scripts/46_make_multimetric_tables.py`:**

- `results/paper_tables/multimetric_main_results.csv` — LOLH, EUE, NEUE, CVaR-EUE,
  runtime for all main paper cases (no-storage validation, storage comparison, PCM validation)
- `results/paper_tables/event_shape_summary.csv` — events/yr, mean/max/p95 duration,
  mean event energy, max shortfall, mean shortfall when shedding for M1c/M2/M3/HOPE-ED/HOPE-UC
  in both VRE portfolios

**Wind-heavy PCM event-shape correction:**

The pre-computed `all_model_aggregate_metrics.csv` for wind-heavy N=5 reported
incorrect mean_event_duration for HOPE-ED (1.4 h, should be 1.58 h) and HOPE-UC
(1.767 h, should be 2.1 h).  These were fixed by computing event shape from the
raw hourly load-shedding CSV
(`results/hope_wind_hvy_n5_pilot/hope_load_shed_hourly.csv`) in script 46.

---

## 16. Key finding 9: normalized marginal storage capacity-credit diagnostic (2026-05-26)

**Deprecated:** The previous 100 MW average reliability-value diagnostic has been deprecated.
The revised diagnostic computes normalized marginal CC using a 1 MW storage and 1 MW
perfect-resource increment.

Script 55 computes normalized marginal capacity credit for each storage-aware MCS method,
case, and increment δ using the existing-storage baseline with analytical CRN:

```
CC_m(δ) = [EUE_m(x) − EUE_m(x + δ_storage)] / [EUE_m(x) − EUE_m(x + δ_perfect)]
```

where x = existing 983 MW / 3932 MWh storage portfolio; δ_storage = δ MW / 4δ MWh;
δ_perfect = analytical CRN: shed_after_perfect[h] = max(0, shed_base[h] − δ).

**Key results — primary metric δ = 1 MW (N=20, seed=42):**

| Case | Method | EUE_base (MWh) | Norm. marg. CC | Error vs M3 |
|------|--------|---------------|---------------|------------|
| VRE120\_base | M1c | 2,479 | 1.116 | +0.000 |
| VRE120\_base | M2  | 2,479 | 1.155 | +0.039 |
| VRE120\_base | M3  | 2,479 | 1.116 | 0.000 |
| VRE120\_wind\_hvy | M1c | 648 | 1.101 | +0.000 |
| VRE120\_wind\_hvy | M2  | 648 | 1.270 | +0.169 |
| VRE120\_wind\_hvy | M3  | 648 | 1.101 | 0.000 |

Sensitivity check at δ = 10 MW: CC values differ from δ = 1 MW by < 0.007 (balanced)
and < 0.006 (wind-heavy), confirming the finite-difference approximation is stable.

**Key finding:** M1c and M3 produce essentially identical normalized marginal capacity
credit (marginal reliability contribution relative to 1 MW perfect firm capacity).
M2 overestimates CC by +0.039 (balanced VRE) and +0.169 (wind-heavy VRE), because the
event-window dispatch conserves more energy for the marginal storage unit during
identified scarcity events.  CC > 1 for all methods reflects that a 1 MW / 4 MWh
four-hour storage unit reduces EUE more than a 1 MW perfect-firm resource, consistent
with the multi-hour duration advantage.

**Source:**
- Script 55: `scripts/55_marginal_capacity_credit.jl`
- Script 56: `scripts/56_make_marginal_cc_figure.py`
- CSV: `results/paper_tables/storage_marginal_capacity_credit.csv`
- Figure: `figures/storage_marginal_capacity_credit.pdf/.png`

---

## 17. Key finding 10: HOPE-PCM-ED confirms CC > 1 (2026-05-27)

Script 57 validates the normalized marginal CC result from script 55 using HOPE-PCM-ED
as an independent LP solver, running 75 new HOPE-ED scenarios (60 base N=20, 15 wind-heavy N=5).

**Results (δ = 1 MW, primary):**

| Case | Model | N | EUE_base (MWh) | ΔEUEstor (MWh) | ΔEUEperf (MWh) | CC | CC > 1? |
|------|-------|---|---------------|----------------|----------------|------|---------|
| VRE120\_base | M3 (Full-year ED) | 20 | 2,479 | 6.641 | 5.950 | 1.116 | YES |
| VRE120\_base | HOPE-PCM-ED | 20 | 2,479 | 6.641 | 6.250 | 1.063 | YES |
| VRE120\_wind\_hvy | M3 (Full-year ED) | 5 | 1,113 | 5.154 | 4.400 | 1.171 | YES |
| VRE120\_wind\_hvy | HOPE-PCM-ED | 5 | 1,113 | 5.154 | 3.800 | 1.356 | YES |

Finite-difference stability (δ = 5, 10 MW): CC varies by < 0.014 across increments for
both models and both cases — the result is not finite-difference noise.

**Key finding:** CC > 1 is confirmed by HOPE-PCM-ED in both cases.  The marginal
reliability contribution of a 1 MW / 4 MWh four-hour storage unit exceeds that of
a 1 MW perfect-firm resource, consistent with the multi-hour duration effect.

**Discrepancy between HOPE and M3:**
ΔEUEstor is identical across models (HOPE-ED and M3 agree on EUE for any system
configuration — the LP objective is the same).  ΔEUEperf differs because it depends
on the hourly concentration of baseline load-shedding: `Σ_h max(0, shed[h] − δ)`.
HOPE uses barrier without crossover (interior-point solution), while M3 uses barrier
with crossover (vertex solution).  These reach different LP optima with the same total
EUE but different hourly load-shed distributions.  The CC magnitude therefore differs
across models, but the CC > 1 conclusion is robust.

**Diagnosis checklist:**
1. Baseline EUE matches: M3 = HOPE = 2,479 MWh (base) / 1,113 MWh (wind-heavy N=5) ✓
2. ΔEUEperf > 1e-9 (denominator not degenerate): min = 3.800 MWh ✓
3. ΔEUEstor and ΔEUEperf reported explicitly ✓
4. Finite-difference stable across δ = 1, 5, 10 MW ✓
5. CC > 1 in both models: YES ✓
6. LP degeneracy explanation for HOPE vs M3 discrepancy: documented ✓

**Source:**
- Script 57: `scripts/57_hope_marginal_cc_validation.jl`
- Script 58: `scripts/58_make_hope_marginal_cc_figure.py`
- CSV: `results/paper_tables/hope_pcm_ed_marginal_cc_validation.csv`
- Figure: `figures/hope_pcm_ed_marginal_cc_validation.pdf/.png`

---

## 18. Key finding 11: Model-rerun denominator resolves LP-degeneracy spread (2026-05-27)

Script 59 replaces the analytical perfect-resource denominator `Σ_h max(0, shed[h] − δ)`
with one computed from an explicit model rerun (CRN-preserving insertion of a δ MW
perfect-firm generator, FOR=0, zero cost).  The corrected formula is:

```
CC_m(δ) = [EUE_m(x) − EUE_m(x + δ_storage)] / [EUE_m(x) − EUE_m(x + δ_perfect)]
```

This is the ED-mode equivalent of HOPE's built-in EREC method (which is GTEP-mode only).

**Results (δ = 1 MW):**

| Case | Model | CC_rerun | CC_analytical | HOPE−M3 (rerun) | HOPE−M3 (analytical) |
|------|-------|----------|--------------|-----------------|----------------------|
| VRE120_base | M3 | 0.4974 | 1.116 | −0.00000 | −0.054 |
| VRE120_base | HOPE-PCM-ED | 0.4974 | 1.063 | | |
| VRE120_wind_hvy | M3 | 0.6285 | 1.171 | −0.00000 | +0.185 |
| VRE120_wind_hvy | HOPE-PCM-ED | 0.6285 | 1.356 | | |

Key observations:
1. **CC_rerun < 1 for both models and both cases**: the marginal 1 MW / 4 MWh storage
   unit contributes *less* reliability than a perfect-firm 1 MW resource, not more.
   The CC > 1 result from script 57 was an artefact of the analytical denominator
   underestimating the perfect-firm EUE reduction (by ~2×).
2. **M3 and HOPE agree to machine precision** (|diff| < 5×10⁻¹⁴) once the same
   model-rerun denominator is used — the LP-degeneracy spread in the analytical
   denominator is eliminated entirely.
3. **Analytical denominator is biased by LP degeneracy**: `Σ_h max(0, shed[h] − δ)`
   depends on hourly load-shed concentration, which differs between barrier+crossover
   (M3, vertex solution) and barrier-only (HOPE, interior-point solution) at the same
   total EUE.  The rerun denominator is immune to this.
4. **Finite-difference stability**: CC_rerun varies by < 0.005 across δ = 1, 5, 10 MW
   for both models and cases.

**Why CC < 1 makes physical sense:** The baseline already contains storage.  Adding
more storage at the margin displaces some perfect-firm capacity value (the storage is
redundant during events where storage is already fully charged), so the per-MW
reliability value of additional storage is below that of a perfect-firm resource.

**Source:**
- Script 59: `scripts/59_marginal_cc_model_rerun.jl`
- Script 60: `scripts/60_make_model_rerun_figure.py`
- CSV: `results/paper_tables/marginal_cc_model_rerun_validation.csv`
- Figure: `figures/marginal_cc_model_rerun_validation.pdf/.png`

---

## 19. Key finding 12: PCM-UCED marginal storage CC matches MCS/ED methods (2026-05-31)

Script 63 computes normalized marginal storage CC for PCM-UCED using a fixed-UC
redispatch LP.  For each baseline HOPE PCM-UCED scenario:
1. Commitment status u[g,h,ω] is inferred from HOPE dispatch output (threshold 0.01 MW).
2. A fixed-commitment LP re-solves continuous dispatch + storage SOC with pmin lower
   bounds for committed generators and zero dispatch for decommitted generators.
3. CC(δ) = mean(ΔEUE_storage) / mean(ΔEUE_perfect_rerun), using the same model-rerun
   denominator as scripts 59 and 61.

**Note on full MILP reoptimisation:** A full MILP rerun (~570 s/scenario × 20 scenarios
× 6 runs per delta × 3 deltas) would require ~19 hours — computationally infeasible for
routine analysis.  The fixed-UC LP is the practical diagnostic.

**Key results (δ = 1 MW, model-rerun denominator):**

| Case | N | EUE fixed-UC (MWh) | HOPE UCED EUE (MWh) | |diff| | CC_fixed_UC |
|------|---|-------------------|---------------------|--------|-------------|
| VRE120_base | 20 | 2,479.17 | 2,479.17 | 0.0% | **0.497** |
| VRE120_wind_hvy | 5 | 1,113.18 | 1,113.18 | 0.0% | **0.628** |

Finite-difference stability (δ = 1, 5, 10 MW): CC varies by < 0.004 (balanced) and
< 0.004 (wind-heavy) — stable across increment sizes.

**Interpretation:**
1. **Fixed-UC LP validates exactly:** The fixed-commitment LP reproduces HOPE UCED EUE
   to numerical precision in every scenario, confirming that the commitment inference
   and LP formulation are correct.
2. **UC constraints do not affect marginal CC:** PCM-UCED CC = 0.497 (balanced) and
   0.628 (wind-heavy) — matching M1c, M2, M3, and HOPE-PCM-ED to 3 decimal places.
   Unit commitment constraints change LOLH and event timing but not the marginal
   reliability value of storage.
3. **Consistent with prior results:** All methods — emergency-only MCS, event-window
   MCS, full-year ED, PCM-ED, and PCM-UCED — yield the same marginal CC under the
   model-rerun denominator.  The marginal reliability value of storage is determined
   by the energy budget and shortage timing, not by the dispatch model's intertemporal
   constraints.

**Mean commitment rate:** 26.7% (balanced) / 18.1% (wind-heavy) of generator-hour
slots are committed (i.e., generator dispatches > 0.01 MW in that scenario-hour).

**Runtime:** ~112 s (N=20 baseline) + ~360 s (N=20 × 3 δ) = ~470 s total for balanced
VRE; ~25 s + ~90 s = ~115 s for wind-heavy.  Total wall time ≈ 10 minutes (after Julia
startup).

**Source:**
- Script 63: `scripts/63_pcm_uced_marginal_cc.jl`
- CSV: `results/paper_tables/pcm_uced_marginal_cc.csv`

---

## 20. Key finding 13: Wind-heavy N=5 sampling inconsistency resolved — N=20 HOPE-UC run (2026-06-01)

The wind-heavy portfolio previously mixed scenario counts: MCS methods (M1c/M2/M3) at N=20
and HOPE-ED/HOPE-UC at N=5.  The N=5 mean EUE was 1113 MWh vs N=20 mean of 648 MWh (42% gap),
making any same-table comparison misleading.

**Root cause:** With CRN seed=42, scenarios 1–5 happen to be high-outage draws that push
the N=5 mean up.  Scenarios 6–20 are less extreme, and the N=20 mean correctly converges
toward the true reliability level.

**Resolution (Strategy 3):** HOPE PCM-UCED and HOPE PCM-ED were re-run for wind-heavy
scenarios 6–20.  All wind-heavy results are now at N=20 (consistent with balanced-VRE).

**N=20 wind-heavy results (seed=42):**

| Method | LOLH (h) | EUE (MWh) | NEUE (ppm) | CVaR (MWh) | Runtime (s/scen) |
|--------|----------|-----------|-----------|-----------|-----------------|
| M1c (emergency-only MCS) | 2.25 | 648.24 | 14.38 | 3528.39 | 0.06 |
| M2 (event-window MCS) | 1.95 | 648.24 | 14.38 | 3528.39 | 0.43 |
| M3 (full-year ED) | 2.25 | 648.24 | 14.38 | 3528.39 | 9.37 |
| HOPE-PCM-ED | 1.95 | 648.24 | 14.38 | 3528.39 | 118.90 |
| HOPE-PCM-UCED | 2.65 | 660.30 | 14.65 | 3624.39 | 2819.95 |

Key observations:
1. **HOPE-ED EUE = M1c/M2/M3 EUE** (648.24 MWh, exact match under CRN).
2. **HOPE-UC EUE is only 1.85% above M1c/M3** (660 vs 648 MWh) — no qualitative change
   in conclusion; UC constraints cause minor additional shedding from commitment cycling.
3. **HOPE-UC LOLH is 18% higher** (2.65 vs 2.25 h) — commitment cycling causes more frequent
   but shorter events.
4. **HOPE-UC runtime 2820 s/scen at N=20** (vs 542 s at N=5) — scenarios 6–20 are harder
   MILP instances (more generator outage configurations to optimise over).
5. **All methods now at N=20 for both portfolios** — the paper table inconsistency is fully
   resolved.

**N=5 → N=20 EUE comparison (to document sampling effect):**

| Method | EUE N=5 | EUE N=20 | Change |
|--------|---------|---------|-------|
| M1c    | 1113 MWh | 648 MWh | −42% |
| M2     | 1113 MWh | 648 MWh | −42% |
| M3     | 1113 MWh | 648 MWh | −42% |
| HOPE-ED | 1113 MWh | 648 MWh | −42% |
| HOPE-UC | 1113 MWh | 660 MWh | −41% |

All methods show the same convergence direction: the N=5 scenarios were unrepresentatively severe.

**Marginal CC for wind-heavy N=20:** Re-computed; see Section 21 below.

**Sources:**
- Script 25: export of s006–s020 UC+ED cases
- Script 29 (run as 29_run_hope_n5_pilot.jl): HOPE run for s006–s020
- Script 27: result collection for s006–s020
- Script 37: N=20 aggregate metrics for wind-heavy
- CSVs: `results/wind_hvy_hope_uc_comparison/n20/all_model_aggregate_metrics.csv`
- Updated: `results/paper_tables/paper_hope_validation.csv` (N=5 → N=20 for wind-heavy)
- Updated: `results/paper_tables/main_method_comparison_with_runtime_cc.csv`
- Diagnostics: `results/paper_tables/wind_heavy_result_inventory.csv`
         `results/paper_tables/wind_heavy_n5_n20_comparison.csv`
         `docs/wind_heavy_strategy_recommendation.md`

---

## 21. Key finding 14: Wind-heavy marginal CC recomputed at N=20 (2026-06-01)

**Context:** After resolving the N=5/N=20 scenario-count inconsistency (Section 20), the
wind-heavy marginal CC values in the main comparison table still came from N=5 runs (scripts
59/61/63).  This section documents the N=20 recomputation (script 64) and the N=5 vs N=20
comparison.

**Methods:** M1, M1b, M1c, M2, M3 (Julia dispatch), PCM-UCED (fixed-UC redispatch LP from
N=20 HOPE-UC outputs, s001–s020).  No new HOPE runs required.

**N=5 vs N=20 CC comparison (δ = 1 MW, wind-heavy, model-rerun denominator):**

| Method | CC (N=5) | CC (N=20) | ΔCC | Assessment |
|--------|----------|----------|-----|------------|
| M1 (naive) | 0.000 | 0.000 | 0.000 | similar across N=5 and N=20 |
| M1b (SOC-floor) | 0.102 | 0.113 | +0.011 | similar across N=5 and N=20 |
| M1c (emergency-only) | 0.628 | 0.604 | −0.024 | modest change; see note |
| M2 (event-window) | 0.628 | 0.604 | −0.024 | modest change; same as M1c |
| M3 (full-year ED) | 0.628 | 0.604 | −0.024 | modest change; same as M1c |
| PCM-UCED (fixed-UC) | 0.628 | 0.612 | −0.016 | similar across N=5 and N=20 |

**Notes:**
- M1c/M2/M3: CC dropped from 0.628 to 0.604 (−3.9% relative).  The N=5 scenarios (1–5) were
  high-outage draws where the 1 MW storage provided proportionally more relief; at N=20, the
  average scenario is milder, reducing the marginal storage benefit relative to the perfect-firm
  denominator.  The change is modest and not a sign of instability — it reflects sampling
  variation in the marginal storage benefit across scenario sets.
- PCM-UCED: CC = 0.612 (vs M1c/M3 = 0.604, difference = +0.008).  The fixed-UC baseline EUE
  is 648.43 MWh (vs HOPE-UC MILP = 660.30 MWh, |diff| = 1.8%).  For 3 of 20 scenarios (s011,
  s013, s015), the fixed-UC LP gives 4–9% lower EUE than the MILP, because the LP relaxes
  MILP commitment constraints.  The mean fixed-UC EUE (648.43 MWh) is very close to M1c/M3
  (648.24 MWh).  The +0.008 CC difference vs M3 reflects the slightly different baseline EUE.
- M1 CC = 0 at N=20 (as at N=5): naive storage never discharges optimally, so adding 1 MW
  marginal storage provides zero EUE reduction.

**Updated main comparison table (wind-heavy N=20):**

| Method | CC (N=20) |
|--------|----------|
| M1c | 0.604 |
| M2 | 0.604 |
| M3 | 0.604 |
| PCM-UCED | 0.612 |

Balanced VRE CC values are unchanged (all N=20 from scripts 61/59/63): M1c/M2/M3 = 0.497,
PCM-UCED = 0.497 (now filled in, was NaN previously).

**Script:** `scripts/64_wind_hvy_marginal_cc_n20.jl`

**Output CSVs:**
- `results/paper_tables/marginal_cc_all_methods_n20.csv` — wind-heavy N=20, M1/M1b/M1c/M2/M3 (15 rows)
- `results/paper_tables/pcm_uced_marginal_cc.csv` — updated with wind-heavy N=20 row (9 rows total)
- `results/paper_tables/main_method_comparison_with_runtime_cc.csv` — rebuilt with N=20 CC


---

## Future Diagnostic: PCM-UCED Storage Operation — Wind-Heavy Event

**Date checked:** 2026-06-02

**Finding:** PCM-UCED hourly storage and load-shedding data is available for all 20
wind-heavy scenarios in .

**Top scenario by EUE (wind-heavy):** s015 (PCM-UCED EUE = 4456.1 MWh in that single trajectory;
mean across 20 scenarios = 660 MWh). The event at h4934 shows:
- Battery fully charged (3932 MWh) at first shedding hour
- PCM-UCED does NOT discharge at rel=0 (first shed) — sheds 220.5 MW instead
- Then discharges 653 MW at rel=+1 (no shedding that hour)
- Alternating discharge/shed pattern continues, consistent with commitment constraints

**What is needed:** Run script 48 for VRE120_wind_hvy s015 to obtain M1c/M2/M3 dispatch
for the same event window. Then create 
comparing all four methods.

**Recommended action (future):** Once M1c/M2/M3 wind-heavy hourly dispatch is generated,
create the wind-heavy event figure and add to appendix as supporting evidence that
commitment constraints affect event timing in both portfolio types.

**Context:** The balanced VRE Scenario 15 event figure (Fig. 4 in the main paper) already
shows this effect clearly and includes all four methods. The wind-heavy event would
provide additional evidence but is not required for the main narrative.

---

## Fig. 2 Annotation Offsets (runtime_accuracy_frontier) — 2026-06-02

Label placement in `scripts/45_make_paper_figures.py` → `make_fig3()`:

| Method      | dx (pts) | dy (pts) | va       | ha     | Note                                 |
|-------------|----------|----------|----------|--------|--------------------------------------|
| Naive       | +10      | +18      | bottom   | left   | right AND above red X                |
| SOC-floor   | +8       | −28      | top      | left   | below AND right of orange square     |
| Emergency   | +6       | +10      | bottom   | left   | above/right of green circle          |
| Event-window| +6       | +9       | bottom   | left   | above/right of blue diamond          |
| Full-year ED| +6       | +9       | bottom   | left   | above/right of dark gray triangle    |
| PCM-UCED    | +6       | −12      | top      | left   | below marker, clear of green note    |

Zero-error floor annotation: `ax.text(80, FLOOR*5, ...)` at data coordinates
x=80 s (between Full-year ED at 9.56 s and PCM-UCED at 571.9 s), y=0.25 MWh.
All labels use `bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.80)`
to prevent visual bleed through markers and grid lines.

Global method color/marker scheme (METHOD_STYLE in script 45):
- Naive: red `#C62828`, marker X
- SOC-floor: orange `#EF6C00`, marker s
- Emergency: green `#388E3C`, marker o, solid line
- Event-window: blue `#1565C0`, marker D, solid line
- Full-year ED: dark gray `#555555`, marker ^, dashed line
- PCM-UCED: purple `#6A1B9A`, marker P, dash-dot line
