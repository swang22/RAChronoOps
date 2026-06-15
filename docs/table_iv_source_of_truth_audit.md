# Table IV Source-of-Truth Audit — Market-Pattern Revalidation

**Date:** 2026-06-15
**Script:** `scripts/72_market_pattern_revalidation.jl`
**Purpose:** Document the authoritative source for every Table IV value after the
market-pattern calibration revalidation (scripts/72).  Note any changes from prior
provisional values.

**Constraint:** `RA-assessment/main.tex` has NOT been edited in this task.
Manuscript values are provisional until the research team approves these findings.

---

## 1. Script History and Bug Fixes

### Script 67 — RETIRED

`scripts/67_run_market_pattern_storage.jl` called the UNCURTAILED wrappers
`run_market_pattern_pure` / `run_market_pattern_emergency` (charge_curtailed=false)
but labelled the results with the paper-facing names "Market-pattern storage MCS"
and "Market-pattern + emergency MCS", which refer to the CHARGE-CURTAILED variants.

A deprecation notice has been added to the top of script 67.
**Do not use script 67 for paper results.**

### Script 68 — M2 parameter bug corrected

`scripts/68_diagnose_market_pattern_storage.jl` called `run_m2_event_window_lp` with
a default `SimConfig` (risk_margin_mw=500, window_buffer_hours=24) instead of the
paper values (risk_margin_mw=1000, window_buffer_hours=48, merge_gap_hours=24,
min_window_length_hours=24).

The M2 section in script 68 has been corrected. Script 68 is still used for
diagnostics of all four market-pattern variants.

### Script 72 — Authoritative revalidation

`scripts/72_market_pattern_revalidation.jl` is the authoritative replacement for
script 67.  It:
- Calls only charge-curtailed variants (MP_pure_cur, MP_emergency_cur)
- Uses paper M2 parameters (1000/48/24/24)
- Tests three calibration patterns
- Tests two SOC initializations (fixed 50% and cyclic fixed-point)
- Validates charging_induced_eue = 0 for all charge-curtailed runs

---

## 2. MarketPatternStorage.jl Changes

`src/models/MarketPatternStorage.jl` received three changes:

1. **`override_init_soc_frac` parameter:** Optional keyword argument added to
   `run_market_pattern_storage` so scripts can specify initial SOC fraction directly.
   Default `nothing` preserves existing behavior (reads from `system.storage`).

2. **Net-dispatch rule documentation:** An explicit comment block was added to the
   non-shortage hour branch explaining:
   - net_pat = r^dis × P^max − r^ch × P^max
   - net_pat > 0 → discharge-only; net_pat < 0 → charge-only
   - No simultaneous charge and discharge

3. **Charge-curtailed invariant assertion:** An `@assert` was added after the main
   simulation loop that verifies `charging_induced_eue ≤ 1e-6` when
   `charge_curtailed=true`.  A preceding `@warn` provides a diagnostic message if
   violated.  Both paper-facing variants (MP_pure_cur, MP_emergency_cur) pass this
   assertion in all N=20 runs.

---

## 3. Prior vs. Revalidated Values

Configuration for all revalidated values: N=20, seed=42, common scenario trajectories,
pattern_energy_balanced.csv, cyclic SOC initialization.

### VRE120_base (Balanced VRE portfolio)

| Method | Metric | Prior value | Revalidated | Status |
|---|---|---|---|---|
| MP_pure_cur | LOLH (h) | 46.10 | **46.00** | −0.2% — within N=20 noise |
| MP_pure_cur | EUE (MWh) | 13,662 | **13,655** | −0.05% — negligible |
| MP_pure_cur | CVaR-EUE (MWh) | 26,276 | **26,227** | −0.2% — negligible |
| MP_pure_cur | NEUE (ppm) | 303.1 | **303.0** | −0.05% |
| MP_emergency_cur | LOLH (h) | 9.15 | **7.70** | **−16% — calibration effect** |
| MP_emergency_cur | EUE (MWh) | 4,338 | **3,596** | **−17% — calibration effect** |
| MP_emergency_cur | CVaR-EUE (MWh) | 15,812 | **13,429** | **−15% — calibration effect** |
| MP_emergency_cur | NEUE (ppm) | 96.3 | **79.8** | **−17% — calibration effect** |

### VRE120_wind_hvy (Wind-heavy portfolio)

| Method | Metric | Prior value | Revalidated | Status |
|---|---|---|---|---|
| MP_pure_cur | LOLH (h) | 23.90 | **23.90** | Identical |
| MP_pure_cur | EUE (MWh) | 7,161 | **7,161** | Identical |
| MP_pure_cur | CVaR-EUE (MWh) | 14,518 | **14,518** | Identical |
| MP_emergency_cur | LOLH (h) | 2.85 | **2.40** | **−16% — calibration effect** |
| MP_emergency_cur | EUE (MWh) | 1,117 | **836** | **−25% — calibration effect** |
| MP_emergency_cur | CVaR-EUE (MWh) | 5,509 | **4,375** | **−21% — calibration effect** |

### Explanation of calibration effect on MP_emergency_cur

The prior values used `pattern_raw.csv` (raw EIA-930 proxy) with 50% fixed initial SOC.
The raw pattern has a per-unit annual SOC drift of −138 MWh/(MW·year), depleting the
battery to 0% within approximately 4 months (for a 4-hour duration system at 50% init).

In shortage hours, MP_emergency_cur overrides to maximum emergency discharge.
If the battery is already depleted (SOC = 0), no discharge is possible → load shedding.
This inflated the prior LOLH and EUE values by systematically depriving the storage of
energy when it was needed most (late in the simulated year).

The energy-balanced pattern (k_ch = 1.099, charge up 9.9%) achieves a stable cyclic
equilibrium at ~23.1% SOC, so some energy is available throughout the year. The result
is a 15–25% reduction in LOLH/EUE for MP_emergency_cur, which is the physically correct
direction.

MP_pure_cur is essentially unaffected (<0.2%) because:
- In shortage hours, it follows the pattern's discharge rate (not maximum emergency)
- Pattern-directed discharge is limited by the pattern value (often near 0% in shortage
  hours at the seasonal timescale)
- The SOC level matters less when discharge is pattern-directed rather than SOC-dependent

---

## 4. Benchmark Methods (unchanged)

The following methods are read from prior result files or freshly computed with
correct parameters. Values match prior Table IV exactly.

### VRE120_base

| Method | LOLH (h) | EUE (MWh) | CVaR-EUE (MWh) | Source |
|---|---|---|---|---|
| M1a (Rule-based) | 95.40 | 31,017 | 51,937 | script 72 (fresh run) |
| M1b (Reserve-aware) | 83.55 | 28,272 | 49,455 | script 72 (fresh run) |
| M1c (Emergency-only) | 5.95 | 2,479 | 9,783 | script 72 (fresh run) |
| M2 (Event-window LP) | **5.75** | 2,479 | 9,783 | script 72 (correct params) |
| M3 (Full-year ED) | 5.95 | 2,479 | 9,783 | prior results (script 38) |

### VRE120_wind_hvy

| Method | LOLH (h) | EUE (MWh) | CVaR-EUE (MWh) | Source |
|---|---|---|---|---|
| M1a (Rule-based) | 52.40 | 15,801 | 26,871 | script 72 (fresh run) |
| M1b (Reserve-aware) | 25.00 | 8,982 | 20,155 | script 72 (fresh run) |
| M1c (Emergency-only) | 2.25 | 648 | 3,528 | script 72 (fresh run) |
| M2 (Event-window LP) | **1.95** | 648 | 3,528 | script 72 (correct params) |
| M3 (Full-year ED) | 2.25 | 648 | 3,528 | prior results (script 38) |

**M2 parameter note:** M2 LOLH values (5.75 h balanced, 1.95 h wind-heavy) match the
prior Table IV values from script 38, which used the same paper parameters (1000/48).
Script 68 previously reported M2 LOLH = 5.10 h (balanced) with wrong parameters (500/24).
The script 72 rerun confirms the correct values match Table IV.

---

## 5. Capacity Credit (MP variants)

Capacity credit requires a separate rerun with explicit firm-increment comparisons.
The prior CC values in `results/paper_tables/market_pattern_capacity_credit.csv` were
computed using the raw pattern and 50% fixed SOC.

**Status:** CC revalidation is a follow-on task. The manuscript CC values for
MP_pure_cur are expected to be nearly unchanged (LOLH differs by <0.2%). The CC for
MP_emergency_cur may shift proportionally to the 17–25% EUE change.

Prior CC values (raw pattern, for reference):
- MP_pure_cur balanced: CC = 0.143
- MP_emergency_cur balanced: CC = 0.336
- MP_pure_cur wind-heavy: CC = 0.128
- MP_emergency_cur wind-heavy: CC = 0.430

---

## 6. Authoritative Source Files

| Table IV row | Script | Output file |
|---|---|---|
| M1a, M1b, M1c | scripts/72_market_pattern_revalidation.jl | results/paper_tables/market_pattern_revalidated_metrics.csv |
| M2 (correct params) | scripts/72_market_pattern_revalidation.jl | same |
| M3 | scripts/38_compare_m1d_storage_heuristics.jl | results/paper_tables/paper_storage_method_comparison.csv |
| MP_pure_cur (provisional) | scripts/72_market_pattern_revalidation.jl | results/paper_tables/market_pattern_revalidated_metrics.csv |
| MP_emergency_cur (provisional) | scripts/72_market_pattern_revalidation.jl | same |

Calibration: `pattern_energy_balanced.csv` (see `docs/market_pattern_calibration_audit.md`).
SOC initialization: cyclic fixed-point (converges to 23.1% for energy-balanced pattern).

---

## 7. Required Actions Before Manuscript Update

1. **Capacity credit revalidation** (separate task): rerun CC with energy-balanced
   pattern and cyclic SOC. MP_pure_cur CC unlikely to change; MP_emergency_cur CC
   may shift by ~15–25%.

2. **Review revalidated MP_emergency_cur values** with research team before updating
   manuscript. The 17% reduction in EUE for balanced VRE and 25% for wind-heavy are
   scientifically meaningful and should be reported accurately.

3. **Appendix update** (separate task): add calibration sensitivity table showing raw
   vs. baseline-corrected vs. energy-balanced LOLH/EUE.

4. **Do not edit main.tex** until the above reviews are complete.
