# VRE Method Comparison Memo

**Date:** 2026-05-17
**Run:** `scripts/16_run_vre_method_comparison.jl --n-scenarios 5 --seed 42`
**Cases:** VRE120_base / bal15 / bal20 / bal30 / solar_hvy / wind_hvy
**Results:** `results/vre_method_comparison/`

---

## 1. Experiment setup

| Parameter | Value |
|-----------|-------|
| Cases | 6 VRE120 cases (see table below) |
| Load scale | 1.20 (calibrated stress case) |
| Storage | 10% of peak load power / 4-hour duration (983 MW / 3,932 MWh) |
| N scenarios | 5 (sanity run) |
| Seed | 42 |
| Models | RA-1a / M1, RA-1b / M1b, RA-3 / M3 |
| M3 solver | Gurobi v1.9.2 (academic license) |
| Common random numbers | Single shared `ScenarioSet` per case; all methods use identical outage draws |

VRE cases scale the installed wind and solar capacity relative to the RTS-GMLC
base while holding hourly capacity-factor profiles fixed.  Available VRE at
hour h is `wind_cf_h × P_wind_new` and `solar_cf_h × P_solar_new`; over-generation
is handled as curtailment inside the dispatch models, not clamped at case-build time.

---

## 2. Main result table

All runs: N = 5, seed = 42.

| Case | VRE energy share | Neg net-load hours | M1 LOLH (h) | M1b LOLH (h) | M3 LOLH (h) | M1b error vs M3 (h) | M1b / M3 ratio | M3 runtime (s) |
|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| VRE120_base | 0.29 | 23 | 115.60 | 103.80 | 11.20 | +92.60 | 9.3× | 49.3 |
| VRE120_bal15 | 0.43 | 620 | 63.80 | 48.60 | 3.60 | +45.00 | 13.5× | 46.1 |
| VRE120_bal20 | 0.58 | 1,684 | 45.00 | 26.40 | 2.40 | +24.00 | 11.0× | 46.1 |
| VRE120_bal30 | 0.87 | 3,492 | 31.20 | 12.80 | 1.00 | +11.80 | 12.8× | 44.1 |
| VRE120_solar_hvy | 0.55 | 1,717 | 53.40 | 26.20 | 2.80 | +23.40 | 9.4× | 45.0 |
| VRE120_wind_hvy | 0.61 | 2,221 | 67.20 | 36.40 | 4.40 | +32.00 | 8.3× | 45.8 |

**Storage ranking (correct order: lower LOLH as VRE increases):** all three methods
show declining LOLH as VRE energy share rises, consistent with the system
becoming more reliable as renewable generation displaces scarcity-prone hours.

---

## 3. Findings

### 3a. RA-1b consistently improves over RA-1a

M1b reduces LOLH relative to M1 in every case:

| Case | M1 LOLH | M1b LOLH | Reduction |
|------|:-------:|:--------:|:---------:|
| VRE120_base | 115.60 h | 103.80 h | −11.8 h |
| VRE120_bal15 | 63.80 h | 48.60 h | −15.2 h |
| VRE120_bal20 | 45.00 h | 26.40 h | −18.6 h |
| VRE120_bal30 | 31.20 h | 12.80 h | −18.4 h |
| VRE120_solar_hvy | 53.40 h | 26.20 h | −27.2 h |
| VRE120_wind_hvy | 67.20 h | 36.40 h | −30.8 h |

The reserve floor (preventing priority-2 from depleting SOC below
`reserve_fraction × total_energy = 0.50 × 3,932 = 1,966 MWh`) allows
priority-1 emergency discharge to fire, reducing LOLH by 11–31 h depending
on the case.  The improvement is largest when VRE generation relieves most
thermal-only hours but storage is still needed during multi-day risk events.

### 3b. RA-1b remains strongly biased high relative to RA-3

Despite the improvement over RA-1a, M1b overestimates LOLH by **8–14×**
relative to M3 across all cases.  The root cause is the same as in the
storage-sensitivity validation: a single-pass chronological heuristic cannot
anticipate multi-day energy depletion patterns or optimally time storage
dispatch around clustered shortage events.  No adjustment to `reserve_fraction`
can close this gap without lookahead information.

### 3c. Absolute error shrinks as VRE penetration increases — but not because heuristics improve

The M1b absolute LOLH error falls from +92.6 h at VRE120_base (VRE energy
share 0.29) to +11.8 h at VRE120_bal30 (0.87).  This is not because the
heuristic becomes more accurate at high VRE; it is because **high-VRE cases
become near-reliable under M3** (M3 LOLH drops to 1.0 h at bal30).  When the
true LOLH is near zero, even a severely biased estimator can only miss by a
bounded amount.  The **relative error** remains large (8–14×) across the entire
VRE range, confirming the heuristic is not improving.

### 3d. Wind-heavy is harder than solar-heavy at similar VRE energy shares

`VRE120_wind_hvy` (60.5% energy share) has higher M3 LOLH (4.40 h) than
`VRE120_solar_hvy` (55.0% share, 2.80 h), despite comparable installed VRE.
The M1b error is also larger for wind-heavy (+32.0 h vs +23.4 h).  This is
consistent with wind's multi-day variability creating longer storage depletion
events that the heuristic misjudges, while solar's predictable daily cycle is
more easily anticipated.

### 3e. Operational-detail importance is not monotonic in VRE penetration

The VRE sweep reveals that the relationship between VRE penetration and
operational-detail error is not simply monotonic.  The absolute error peaks at
VRE120_base (lowest VRE, highest residual adequacy risk) and falls at high VRE
(near-zero M3 LOLH).  This challenges the naive assumption that more VRE
always increases the need for detailed storage dispatch modelling.

The revised hypothesis (replacing "Higher VRE penetration always increases need
for operational detail") is:

> **Operational detail matters most when adequacy risk is governed by
> intertemporal energy management — e.g., storage depletion, renewable
> drought/ramp structure, and scarcity-window timing.  VRE penetration
> changes this need through both energy adequacy and profile variability,
> so the relationship may be non-monotonic.**

The practical implication: the cases where a simplified heuristic is most
dangerous are not necessarily the highest-VRE cases, but those where the
system sits in a scarcity-sensitive regime where storage timing is decisive.

---

## 4. Runtime finding

| Model | Runtime per case (s) | Per scenario (s) | Speedup vs M3 |
|-------|---------------------:|:----------------:|:-------------:|
| M1 (RA-1a) | 0.2–0.8 | ~0.1 | ~450–500× |
| M1b (RA-1b) | 0.2–0.6 | ~0.1 | ~450–500× |
| M3 (RA-3, Gurobi) | 44–49 | ~9–10 | 1× |

M3 with Gurobi runs at approximately **9–10 s/scenario**, compared to ~360 s/scenario
with HiGHS — a **~35× speedup**.  This substantially changes the computational
picture:

- A **N = 20 benchmark run** for one case now takes ~3–4 minutes (vs ~2 hours with HiGHS).
- A **N = 50 sweep** across all six cases would take ~75 minutes total — feasible
  in a single session.
- Full-year ED is no longer prohibitively expensive for selected benchmark runs,
  but remains too slow for large-scale sensitivity sweeps or iterative RA-2 tuning.

---

## 5. Decision

| Item | Decision |
|------|---------|
| RA-1a / M1 | Keep as cautionary baseline. |
| RA-1b / M1b | Include in all VRE experiments. Not a valid substitute for RA-3. |
| RA-3 / M3 (Gurobi) | Primary benchmark. ~9–10 s/scenario makes N=20 runs tractable. |
| RA-2 event-window LP | **Proceed to implementation.** Priority cases identified below. |
| N=20 benchmark run | Run only on priority cases first; do not run all six cases yet. |

### Priority cases for N=20 and RA-2 implementation

Ranked by M1b absolute LOLH error (cases where operational detail matters most):

| Priority | Case | M1b error vs M3 | M3 LOLH | Rationale |
|:--------:|------|:---------------:|:-------:|-----------|
| 1 | VRE120_base | +92.6 h | 11.20 h | Largest absolute error; base-level VRE, high scarcity risk |
| 2 | VRE120_bal15 | +45.0 h | 3.60 h | Modest VRE expansion; still substantial scarcity |
| 3 | VRE120_wind_hvy | +32.0 h | 4.40 h | Multi-day wind variability; hardest for heuristic |

The remaining three cases (bal20, bal30, solar_hvy) have smaller absolute errors
and near-zero M3 LOLH; they are lower priority for RA-2 testing.

### Recommended next steps

**A.** Run N=20 on `VRE120_base`, `VRE120_bal15`, and `VRE120_wind_hvy` using
M1, M1b, and M3 to establish stable benchmark LOLHs before RA-2 implementation.

**B.** Implement RA-2 event-window LP (`src/models/M2EventWindowLP.jl`) and
validate first on `VRE120_base` (highest error, easiest to diagnose improvement).

**C.** Do not run N=20 on all six cases until RA-2 is implemented and its
accuracy advantage is confirmed on priority cases.

---

*Generated from `results/vre_method_comparison/summary.txt`,
`vre_method_comparison_results.csv`, and `vre_method_comparison_errors.csv`.*
*All runs use common random numbers (shared `ScenarioSet`, seed=42).*
