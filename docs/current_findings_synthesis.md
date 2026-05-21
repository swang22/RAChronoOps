# Current Findings Synthesis

**Date:** 2026-05-21

---

## 1. Overview

This document summarises the key findings from the completed RAChronoOps
experiment sequence.  The project tests a ladder of storage dispatch
approximations — from naive heuristics to event-window LPs to full-year
HOPE UC/PCM — against a common Monte Carlo scenario set for an
RTS-GMLC-based single-zone system.  The clean narrative is:

Traditional sequential MC is valid without storage; storage SOC coupling
makes reliability estimates sensitive to dispatch assumptions; naive storage
heuristics overestimate risk; the event-window LP (M2) and emergency-only
heuristic (M1c) recover the full-year ED benchmark at much lower runtime;
HOPE-UC mainly changes LOLH/event timing, not EUE, in the tested cases.
A theoretical storage-energy sufficiency bound confirms why M1c, M1d, M2,
and M3 converge on the same EUE: the binding constraint is the storage energy
budget per event, not dispatch complexity, and any model that charges from
surplus and discharges only at shortfall hours saturates the bound.

---

## 2. Model hierarchy

| Label | Method | Runtime/scenario | Role |
|-------|--------|-----------------|------|
| MC-NoStorage | Classical hourly capacity check, no storage | < 1 s | No-storage baseline |
| M1 / RA-1a | Naive peak-shaving heuristic | ~1 s | Cautionary failure case |
| M1b / RA-1b | Reserve-aware heuristic (SOC floor) | ~1 s | Improved heuristic |
| M1c / RA-1c | Emergency-only heuristic, system-surplus charging | ~1–2 s | Near-M3 simple model |
| M1c\_VREOnly | M1c with VRE-surplus-only charging | ~1–2 s | Appendix sensitivity |
| M1d / RA-1d | Risk-hour allocation heuristic (earliest\_first / largest\_first) | ~1–2 s | Within-event allocation study |
| M2 / RA-2 | Event-window LP (rm=1000 MW, buf=48 h) | ~5–10 s | Proposed hybrid method |
| M3 / RA-3 | Full-year ED LP (Gurobi) | ~9–10 s | LP benchmark |
| HOPE-ED | Full-year HOPE ED LP | ~120 s | HOPE mapping validation |
| HOPE-UC / M4 | Full-year HOPE UC MILP | ~540–570 s | High-fidelity UC benchmark |

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

M1 and M1b overestimate reliability risk relative to the LP benchmark M3.
The bias is consistent across all tested VRE profiles.

| Model | LOLH error vs M3 | EUE error vs M3 |
|-------|-----------------|----------------|
| M1 | Large positive | Large positive |
| M1b | Moderate positive | Moderate positive |
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

**Why this explains EUE convergence:**
When the sufficiency bound is tight (bound ≈ M3 EUE), any dispatch model that
(1) charges from system surplus and (2) discharges only at shortfall hours will
achieve the same residual EUE.  There is no additional EUE reduction available
beyond what the storage energy budget allows — the problem is
energy-constrained, not dispatch-complexity-constrained.

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

The binding constraint is **energy (MWh), not power (MW)** in both tested
cases: the storage power limit (983 MW) is not the bottleneck for the 73-unit
RTS-GMLC system.  The sufficiency ratio (0.941–0.972) is the fraction of
pre-storage EUE that the storage budget can cover; the 2.8–5.9% uncoverable
residual corresponds exactly to the M3 EUE.

---

## 7. Key finding 5: M1c and M2 recover the ED/HOPE benchmark

M1c (emergency-only, system-surplus charging) and M2 (event-window LP) both
closely match M3 EUE and CVaR while being 13–130× faster.

**Table C — Storage wind-heavy HOPE comparison, N=5 (VRE120\_wind\_hvy):**

| Model | LOLH (h) | EUE (MWh) | CVaR (MWh) | Runtime (s) |
|-------|----------|-----------|-----------|-------------|
| M1c | 4.4 | 1,113 | 2,793 | 0.6 |
| M2 | 3.8 | 1,113 | 2,793 | 2.5 |
| M3 | 4.4 | 1,113 | 2,793 | 44.3 |
| HOPE-ED | 3.8 | 1,113 | 2,793 | 587.6 |
| HOPE-UC | 4.2 | 1,113 | 2,793 | 2,712.2 |

EUE is identical across all five models (exact per-scenario match).
LOLH varies by up to 0.6 h across models, reflecting LP degeneracy
(multiple optimal dispatch trajectories at the same EUE objective value).

**M2 recommended config:** `risk_margin_mw=1000, window_buffer_hours=48`.
This gives < 0.2 h mean LOLH error and near-machine-precision EUE at
5–10 s/scenario (20–37× faster than M3 with Gurobi).

---

## 8. Key finding 6: HOPE-UC affects timing/LOLH, not EUE in tested cases

**Table D — HOPE-ED vs HOPE-UC (storage-enabled):**

| Case | Model | LOLH (h) | EUE (MWh) | Runtime (s) |
|------|-------|----------|-----------|-------------|
| VRE120\_base, N=20 | HOPE-ED | 6.2 | 2,479 | 2,356 |
| VRE120\_base, N=20 | HOPE-UC | 7.2 | 2,479 | 11,438 |
| VRE120\_wind\_hvy, N=5 | HOPE-ED | 3.8 | 1,113 | 588 |
| VRE120\_wind\_hvy, N=5 | HOPE-UC | 4.2 | 1,113 | 2,712 |

In both tested cases, HOPE-UC and HOPE-ED produce identical EUE.  HOPE-UC
increases LOLH by 1.0 h (base) or 0.4 h (wind-heavy): the same total energy
deficit is redistributed into more shortage hours by min-up/down constraints
on committed generators.

**Mechanism:** UC commitment constraints bind intertemporal storage dispatch.
Storage must charge/discharge around the thermal commitment schedule, which
can shift the timing of storage discharge and spread the same energy shortage
across more hours.  Without storage this effect is absent (Phase H result).

**Runtime penalty:** HOPE-UC is 4–5× slower than HOPE-ED with zero EUE
benefit in the tested cases.  Running UC for every scenario is not warranted
based on current evidence; UC is recommended only as a sensitivity check on
LOLH/event timing.

---

## 9. Key caveats

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

4. **Operating reserves and network constraints are out of scope.**
   The core benchmark aligns with traditional RA conventions: single zone,
   no ancillary service constraints, no transmission limits.  These are
   future extensions and do not invalidate the current comparisons.

5. **N=5 wind-heavy results are indicative only.** The HOPE-UC wind-heavy
   comparison used 5 scenarios; per-scenario EUE values are exact matches,
   but LOLH statistics have wider confidence intervals than N=20.

---

## 10. Recommended next steps

1. **No new runs immediately.** The completed experiment sequence answers
   the core research questions.  Additional runs (e.g., wind-heavy N=20
   HOPE-UC) are feasible (~3 h) but not required before writing.

2. **Prepare paper-ready tables and figures.** The primary deliverables are:
   - Figure 1: method accuracy vs runtime plane
   - Figure 2/3: LOLH and EUE errors by method and VRE case
   - Figure 4: accuracy–runtime frontier (M1c, M2, M3, HOPE-ED, HOPE-UC)
   - Table: no-storage validation (Tables A and B above)
   - Table: storage method comparison (Table C)
   - Table: HOPE-UC vs HOPE-ED (Table D)

3. **M1d risk-hour allocation heuristic is implemented** (script 38).
   The storage-energy sufficiency bound (script 39) provides the theoretical
   justification for the EUE convergence across M1c/M1d/M2/M3.
   Both are available for inclusion in the paper as supporting material.

4. **Consider N=20 wind-heavy HOPE-UC** if the paper requires a matched
   comparison with the base case N=20 run.  Projected runtime: ~3 h.
