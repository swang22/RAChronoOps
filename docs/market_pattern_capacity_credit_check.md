# Market-Pattern Storage MCS — Capacity Credit Check

**Date:** 2026-06-14
**Script:** `scripts/70_market_pattern_marginal_cc.jl`
**Output:** `results/paper_tables/market_pattern_capacity_credit.csv`

---

## 1. Method

Normalized marginal capacity credit (CC) using the perfect-firm rerun denominator,
consistent with scripts 59 and 61 (M3 and M1/M1b/M1c/M2 benchmarks):

$$CC_m^{\Delta} = \frac{EUE_m(x) - EUE_m(x + \Delta_S)}{EUE_m(x) - EUE_m(x + \Delta_F)}$$

where:
- $\Delta_S$: δ MW of 4-hour storage, 50% initial SOC, eta = √0.90 per direction
- $\Delta_F$: δ MW of always-available (FOR=0) perfect firm capacity, explicitly rerun
- δ tested at 1, 5, 10 MW (main table at δ = 1 MW)
- Pattern for augmented storage scaled by augmented total power: target_dis = r_dis_h × (P + δ)
- N = 20, seed = 42, both cases; M2 with risk=1000 MW, window_buffer=48 h

---

## 2. Results (δ = 1 MW, N = 20, seed = 42)

### Balanced VRE (VRE120_base)

| Method | EUE_base (MWh) | ΔEUE_storage (MWh) | ΔEUE_firm (MWh) | CC |
|---|---|---|---|---|
| MP_pure | 14321.43 | 4.83 | 37.43 | 0.129 |
| MP_pure_cur | 13661.96 | 6.61 | 46.15 | **0.143** |
| MP_emergency | 4668.18 | 7.40 | 20.81 | 0.356 |
| MP_emergency_cur | 4338.32 | 8.51 | 25.35 | **0.336** |
| M1c (benchmark) | 2479.17 | 6.64 | 13.35 | 0.497 |
| M2 (benchmark) | 2479.17 | 6.64 | 13.35 | 0.497 |

### Wind-heavy (VRE120_wind_hvy)

| Method | EUE_base (MWh) | ΔEUE_storage (MWh) | ΔEUE_firm (MWh) | CC |
|---|---|---|---|---|
| MP_pure | 7559.51 | 1.86 | 27.41 | 0.068 |
| MP_pure_cur | 7160.64 | 3.06 | 23.86 | **0.128** |
| MP_emergency | 1455.60 | 1.62 | 9.14 | 0.177 |
| MP_emergency_cur | 1117.40 | 2.97 | 6.92 | **0.430** |
| M1c (benchmark) | 648.24 | 2.48 | 4.10 | 0.604 |
| M2 (benchmark) | 648.24 | 2.48 | 4.10 | 0.604 |

---

## 3. Interpretation

**M1c and M2 give identical CC (as expected):**
Both achieve the same scenario-optimal EUE (2479.17 / 648.24 MWh) from the same scenarios
(same seed), so their CC numerators and denominators are identical. M2's LP optimization
minimizes EUE to the same global optimum as M1c's greedy emergency dispatch for these systems.

**MP methods have substantially lower CC than M1c/M2:**
- MP_pure_cur: CC = 0.143 (balanced) and 0.128 (wind-heavy) — ≈29–79% of M1c
- MP_emergency_cur: CC = 0.336 (balanced) and 0.430 (wind-heavy) — ≈68–71% of M1c
- The CC penalty is larger for balanced VRE where the market pattern is less well-aligned
  with shortage hours

**Pattern calibration does not recover M1c CC:**
Even the recommended MP_emergency_cur variant achieves only 68–71% of M1c's CC at δ=1 MW.
This reflects the fundamental constraint: a calibrated market pattern dispatches storage
for economic objectives (price arbitrage), which only partially overlaps with reliability
objectives (emergency discharge during shortage events).

**δ-invariance:**
CC is approximately constant across δ = 1, 5, 10 MW for all MP variants (variation < 1%),
confirming the linear approximation holds and δ = 1 MW is representative.

**Low CC is explained by full SOC depletion:**
Both paper-facing variants (charge-curtailed) end 100% of scenarios with SOC = 0 MWh.
The market pattern discharges more than it charges annually (net negative energy balance),
causing storage to deplete and remain at zero for much of each year. Once at zero, storage
cannot contribute to reliability, which mechanistically explains the low CC.
See `results/paper_tables/market_pattern_soc_boundary_check.csv`.

---

## 4. M1c/M2 Benchmark Cross-Check

From `results/paper_tables/marginal_cc_all_methods_n20.csv` (script 61):
- M1c wind-heavy (N=5): CC_rerun = 0.6041 ✓ (matches new run with N=20: 0.6041)
- M2 wind-heavy (N=5): CC_rerun = 0.6041 ✓

From `results/paper_tables/main_method_comparison_with_runtime_cc.csv` (Table IV):
- M1c balanced VRE: CC = 0.497 ✓ (matches new run: 0.4974)
- M2 balanced VRE: CC = 0.497 ✓

Cross-check passes. The CC framework is internally consistent.

---

## 5. Sampling Stability (Part G)

| N | MP_pure_cur EUE (MWh) | MP_pure_cur CC | MP_emergency_cur EUE (MWh) | MP_emergency_cur CC |
|---|---|---|---|---|
| 20 | 13,661.96 | 0.143 | 4,338.32 | 0.336 |
| 50 | 14,765.84 | 0.145 | 4,876.85 | 0.354 |
| 100 | 14,531.69 | 0.143 | 4,604.19 | 0.412 |
| 200 | 15,060.82 | 0.143 | 5,221.21 | 0.418 |

### Wind-heavy (VRE120_wind_hvy)

| N | MP_pure_cur EUE (MWh) | MP_pure_cur CC | MP_emergency_cur EUE (MWh) | MP_emergency_cur CC |
|---|---|---|---|---|
| 20 | 7,160.64 | 0.128 | 1,117.40 | 0.430 |
| 50 | 7,909.60 | 0.131 | 1,565.95 | NaN* |
| 100 | 7,823.65 | 0.130 | 1,520.00 | 1.305** |
| 200 | 8,278.73 | 0.133 | 1,920.04 | 0.897 |

*NaN: EUE_plus_firm ≈ EUE_base in this N=50 sample (denominator ≤ 1e-9)
**CC > 1 valid: 4h storage can deliver >1 MWh/MW in shortage events

**MP_pure_cur CC is stable at N=20** (variation < 4% across N = 20–200 for both cases).
**MP_emergency_cur balanced VRE CC is less stable** (increases from 0.336 to ≈0.42 at N≥100).
**MP_emergency_cur wind-heavy CC is highly variable** (0.43 → NaN → 1.31 → 0.90 across N).
This instability reflects small absolute EUE (1117–1920 MWh) giving high MC variance in the CC ratio.
For the paper, note that N=20 underestimates MP_emergency_cur balanced VRE CC by ~20%.

---

## 6. Recommended Table IV Values

For the paper appendix, use N=20 values (consistent with existing Table IV):

| Method | Case | LOLH (h) | EUE (MWh) | NEUE (ppm) | CC (δ=1 MW) | Runtime (s/scen) |
|---|---|---|---|---|---|---|
| MP_pure_cur | Balanced VRE | 46.10 | 13,661.96 | 303.1 | 0.143 | 0.048 |
| MP_emergency_cur | Balanced VRE | 9.15 | 4,338.32 | 96.3 | 0.336 | 0.062 |
| MP_pure_cur | Wind-heavy | 23.90 | 7,160.64 | 158.9 | 0.128 | 0.047 |
| MP_emergency_cur | Wind-heavy | 2.85 | 1,117.40 | 24.8 | 0.430 | 0.044 |

Note: NEUE = EUE / annual_load × 1e6. Annual load computed from system.load_mw.
Runtime values are from script 70 first-run timing (not warm-start). See `runtime_common_benchmark.csv` for warm-start values.

**Caveat for MP_emergency_cur CC:** N=20 gives CC ≈ 0.34 (balanced VRE). At N=100 this rises
to ≈ 0.41. The paper should either use N=100 for CC or note the N=20 CC is a lower bound.

---

## 7. Comparison with M1c and M2

Adding δ = 1 MW of storage under the market-pattern dispatch rule reduces EUE by
only 14–43% as much as under the emergency-only (M1c) or event-window (M2) dispatch rule.
This is the quantitative answer to the question "how much does dispatch rule matter for CC?":
the answer is substantial, ranging from a factor of 1.2× (MP_emergency_cur wind-heavy CC 0.43
vs M1c 0.60) to a factor of 4.7× (MP_pure wind-heavy CC 0.068 vs M1c 0.604).

The emergency-override flag (+M1c rule during shortage hours) recovers approximately half the
CC gap between pure market-pattern and optimal dispatch.
