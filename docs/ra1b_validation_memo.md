# RA-1b Validation Memo

**Date:** 2026-05-16  
**Run:** `scripts/14_run_ra1b_validation.jl --n-scenarios 10 --seed 42`  
**Cases:** storage120_p05_d4 / p10_d4 / p20_d4 (5 % / 10 % / 20 % peak load, 4 h duration)  
**Results file:** `results/ra1b_validation/ra1b_validation_results.csv`

---

## 1. What RA-1b fixed relative to RA-1a

The diagnostic phase showed that RA-1a (M1) fails because Priority-2 proactive
discharge fires at ~25 % of all hours and depletes the battery to zero SOC before
every shortage event.  Priority-1 emergency discharge therefore never has energy
available and fires zero times.

RA-1b adds a single guard: **Priority-2 may not draw SOC below
`reserve_fraction × total_energy` (default 0.50)**.  Priority-1 ignores the floor
and may draw it down unconditionally.

| Behaviour | RA-1a / M1 | RA-1b / M1b |
|-----------|:----------:|:-----------:|
| Priority-1 fires (N=10) | **0 / 10** scenarios, **0 h** | **10 / 10** scenarios |
| Priority-1 total hours (p05_d4) | 0 | 90 |
| Priority-1 total hours (p10_d4) | 0 | 138 |
| Priority-1 total hours (p20_d4) | 0 | 240 |
| Storage-sensitive LOLH | No (flat across all storage sizes) | Yes |
| Correct storage ranking | No | Yes |

The reserve floor prevents peak-shaving from pre-empting genuine emergency
storage capacity.  More storage → more P1 discharge hours, confirming that the
guard is doing what it was designed to do.

---

## 2. RA-1b vs RA-3 benchmark results

All runs: N = 10 scenarios, seed = 42, HiGHS solver.

| Case | M1 LOLH (h) | M1b LOLH (h) | M3 LOLH (h) | M1b/M3 ratio | Interpretation |
|------|------------:|-------------:|------------:|:------------:|----------------|
| storage120_p05_d4 | 100.50 | 93.60 | 31.20 | 3.00× | M1b moves toward M3 but still 3× too high |
| storage120_p10_d4 | 100.50 | 88.70 |  7.70 | 11.5× | Large remaining gap at reference case |
| storage120_p20_d4 | 100.50 | 78.20 |  0.00 | ∞ | M3 fully reliable; M1b still reports 78 h |

**LOLH error vs M3 benchmark:**

| Case | M1 absolute error | M1b absolute error | M1b relative error |
|------|------------------:|-------------------:|-------------------:|
| p05_d4 | +69.3 h (+222 %) | +62.4 h (+200 %) | −6.9 h vs M1 |
| p10_d4 | +92.8 h (+1205 %) | +81.0 h (+1052 %) | −11.8 h vs M1 |
| p20_d4 | +100.5 h (∞) | +78.2 h (∞) | −22.3 h vs M1 |

**Storage ranking** (correct order: p05 > p10 > p20, i.e. more storage → more reliable):

| Method | p05 LOLH | p10 LOLH | p20 LOLH | Ranking correct? |
|--------|:--------:|:--------:|:--------:|:----------------:|
| M1 (RA-1a) | 100.50 | 100.50 | 100.50 | No — flat |
| M1b (RA-1b) | 93.60 | 88.70 | 78.20 | **Yes** |
| M3 (RA-3) | 31.20 | 7.70 | 0.00 | **Yes** |

**Runtime:**

| Model | Runtime per case (s) | Speedup vs M3 |
|-------|---------------------:|:-------------:|
| M1 (RA-1a) | ~1 | ~3,900× |
| M1b (RA-1b) | ~0.5 | **~7,800×** |
| M3 (RA-3, HiGHS) | ~3,900 | 1× |

---

## 3. Interpretation

**RA-1b is a genuine improvement over RA-1a** on every behavioural dimension that
matters for a resource-adequacy study:

1. **Storage-sensitive:** LOLH varies by 15.4 h across storage cases (RA-1a range: 0.0 h).
2. **Correct storage ranking:** p05 > p10 > p20 order is preserved.
3. **Emergency discharge fires:** P1 activates in all scenarios; the reserve floor
   succeeds in keeping energy available for genuine scarcity events.
4. **Near-zero runtime:** ~0.5 s/case — compatible with broad VRE sweeps.

**However, RA-1b still substantially overestimates scarcity relative to RA-3.**
At the calibrated reference case (p10_d4), M1b reports 88.7 h vs M3's 7.7 h — an
11.5× overestimate.  At higher storage (p20_d4), M3 correctly identifies the system
as fully reliable while M1b reports 78.2 h LOLH.  The root cause is that a
single-pass chronological heuristic cannot anticipate multi-day energy depletion
patterns the way a full-year LP can.  No adjustment to `reserve_fraction` can
close this gap without lookahead information.

**Conclusion:** RA-1b is a useful improved heuristic but is not a valid approximate
substitute for RA-3 as a reliability benchmark.  The large remaining accuracy gap
directly motivates RA-2 (event-window LP), which targets solving LPs only near
screened risk windows to recover most of the RA-3 accuracy at a fraction of the
runtime.

---

## 4. Decision

| Item | Decision |
|------|---------|
| RA-1a / M1 | **Keep as cautionary baseline.** Documents the failure mode of naive peak-shaving. |
| RA-1b / M1b | **Include in VRE experiments as fast improved heuristic.** Label clearly; do not treat as substitute for RA-3. |
| RA-3 / M3 | **Primary benchmark** for all VRE cases. Switch solver to Gurobi to reduce per-scenario runtime from ~360 s to ~10–30 s. |
| RA-2 event-window LP | **Proceed to implementation (Phase C).** Needed to close the accuracy gap between RA-1b and RA-3. |
| Next step | **Proceed to VRE case preparation (Task 2 in redesigned_experiment_plan.md).** |

---

*Generated from `results/ra1b_validation/summary.txt` and `ra1b_validation_results.csv`.*  
*All runs use common random numbers (shared `ScenarioSet`, seed=42).*
