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

## 6. Key finding 4 (theoretical): storage-energy sufficiency bound

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
50, 100, and 200 — the EUE convergence result is stable across N.**

**CI95 shrinkage:**

CI95 half-widths shrink approximately as 1/√N from N=20 to N=200.
N=200 gives CI95 ≈ 3.2× narrower than N=20.  N=20 is sufficient for
method comparisons when the EUE error target is ≥ 100 MWh — the method
errors are 0.0 MWh, far below the CI95 at every N tested.

**Method error vs sampling uncertainty:**

At every N, the method errors |M1c−M3| and |M2−M3| are ≪ CI95-EUE.
A statistical test at N=20 cannot distinguish M1c or M2 from M3 on EUE;
the method errors are indistinguishable from zero relative to MC noise.

**Event-shape metrics:**

Mean event duration, p95 event energy, p95 conditional shortfall, and
event count per scenario are consistent across M1c, M2, and M3 at the same
N.  The identical EUE reflects identical event structure, not coincidental
cancellation of opposite errors across scenarios.

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
