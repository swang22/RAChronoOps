# Market-Pattern Storage MCS — Manuscript Readiness Report

**Date:** 2026-06-14
**Status:** Ready for appendix sensitivity; NOT recommended for main Table IV

---

## 1. Purpose

This report summarizes all validation experiments completed before the market-pattern storage
MCS method can be incorporated into the manuscript. It documents:
- Resolved discrepancies between current diagnostic files and Table IV
- Capacity credit results for all four variants
- Recommended Table IV values for two paper-facing variants
- SOC boundary sensitivity
- CAISO data quality assessment
- Sampling convergence
- Explicit decisions for the paper

---

## 2. Table IV Discrepancy — RESOLVED

**Status:** Explained and closed. See `docs/market_pattern_table_iv_source_audit.md`.

**Root cause:** Script 68 used `SimConfig` defaults (`risk_margin_mw=500`, `window_buffer_hours=24`)
for the M2 event-window benchmark, while Table IV was generated with `risk_margin_mw=1000`,
`window_buffer_hours=48` (script 38).

| Metric | Table IV | Script 68 (old) | Script 70 (correct) |
|---|---|---|---|
| M2 balanced VRE LOLH | **5.75 h** | 5.10 h | **5.75 h** ✓ |
| M2 wind-heavy LOLH | **1.95 h** | 1.75 h | **1.95 h** ✓ |
| M1c balanced VRE LOLH | 5.95 h | 5.95 h | 5.95 h ✓ |
| EUE (any method) | 2479.17 | 2479.17 | 2479.17 ✓ |

All Table IV source files remain **unmodified**. The new script 70 independently reproduces
the exact M1c and M2 Table IV values with correct parameters.

---

## 3. Table IV Candidate Rows (Paper-Facing Variants)

Source: `results/paper_tables/market_pattern_table_iv_rows.csv`
Script: `scripts/70_market_pattern_marginal_cc.jl`
Config: N=20, seed=42, pattern=CAISO season-hour means (p95 normalization)

### Balanced VRE (VRE120_base)

| Method | LOLH (h) | EUE (MWh) | NEUE (ppm) | CVaR-EUE (MWh) | CC (δ=1 MW) | Runtime (s/scen) |
|---|---|---|---|---|---|---|
| **Market-pattern storage MCS** | **46.10** | **13,661.96** | **303.1** | **26,276.4** | **0.143** | **0.048** |
| **Market-pattern + emergency storage MCS** | **9.15** | **4,338.32** | **96.3** | **15,811.6** | **0.336** | **0.062** |
| Emergency-only storage MCS (M1c, ref) | 5.95 | 2,479.17 | 55.0 | 9,782.9 | 0.497 | — |
| Event-window storage MCS (M2, ref) | 5.75 | 2,479.17 | 55.0 | 9,782.9 | 0.497 | — |

### Wind-heavy (VRE120_wind_hvy)

| Method | LOLH (h) | EUE (MWh) | NEUE (ppm) | CVaR-EUE (MWh) | CC (δ=1 MW) | Runtime (s/scen) |
|---|---|---|---|---|---|---|
| **Market-pattern storage MCS** | **23.90** | **7,160.64** | **158.9** | **14,518.0** | **0.128** | **0.047** |
| **Market-pattern + emergency storage MCS** | **2.85** | **1,117.40** | **24.8** | **5,509.3** | **0.430** | **0.044** |
| Emergency-only storage MCS (M1c, ref) | 2.25 | 648.24 | 14.4 | 3,528.4 | 0.604 | — |
| Event-window storage MCS (M2, ref) | 1.95 | 648.24 | 14.4 | 3,528.4 | 0.604 | — |

Runtime values are from script 70 first-run timing (include JIT overhead for the first dispatch
per case). Warm-start values are in `results/paper_tables/runtime_common_benchmark.csv`.

---

## 4. Capacity Credit Results

Source: `results/paper_tables/market_pattern_capacity_credit.csv`
Full analysis: `docs/market_pattern_capacity_credit_check.md`

**Summary at δ = 1 MW:**

| Method | Balanced VRE CC | Wind-heavy CC | vs M1c (balanced) |
|---|---|---|---|
| MP_pure (uncurtailed) | 0.129 | 0.068 | 26% |
| MP_pure_cur | **0.143** | **0.128** | **29%** |
| MP_emergency (uncurtailed) | 0.356 | 0.177 | 72% |
| MP_emergency_cur | **0.336** | **0.430** | **68%** |
| M1c (benchmark) | 0.497 | 0.604 | 100% |

**Key findings:**
- Both paper-facing variants have substantially lower CC than M1c (29–68% of M1c)
- CC is approximately constant across δ = 1, 5, 10 MW (linear regime holds)
- M1c and M2 give identical CC (same EUE baseline and incremental response)
- The emergency-override flag recovers ~50% of the CC gap between pure MP and M1c

---

## 5. Runtime Benchmark

Source: `results/paper_tables/runtime_common_benchmark.csv` (script 71)
Config: N=20, seed=42, 3 reps (M1/M1b/M1c/MP/M2), 2 reps (M3), 1 warm-up rep before timing

**Warm-start median runtimes (N=20, median over timed reps):**

### Balanced VRE (VRE120_base)

| Method | s/scenario (median) | Relative to M1c |
|---|---|---|
| Naive storage MCS (M1) | 0.0440 | 1.03× |
| SOC-floor storage MCS (M1b) | 0.0427 | 1.00× |
| Emergency-only storage MCS (M1c) | 0.0426 | 1.0× |
| Market-pattern storage MCS (MP_pure_cur) | 0.0448 | 1.05× |
| Market-pattern + emergency storage MCS (MP_emergency_cur) | 0.0461 | 1.08× |
| Event-window storage MCS (M2) | 0.3985 | 9.4× |
| Full-year ED (M3) | **9.405** | **221×** |

### Wind-heavy (VRE120_wind_hvy)

| Method | s/scenario (median) | Relative to M1c |
|---|---|---|
| Naive storage MCS (M1) | 0.0478 | 1.08× |
| SOC-floor storage MCS (M1b) | 0.0470 | 1.06× |
| Emergency-only storage MCS (M1c) | 0.0444 | 1.0× |
| Market-pattern storage MCS (MP_pure_cur) | 0.0481 | 1.08× |
| Market-pattern + emergency storage MCS (MP_emergency_cur) | 0.0469 | 1.06× |
| Event-window storage MCS (M2) | 0.3698 | 8.3× |
| Full-year ED (M3) | **8.758** | **197×** |

Both paper-facing MP variants run at essentially the same speed as M1c (within 5–8%), as
expected: they use the same sequential simulation loop with a closed-form pattern dispatch rule.
M2 is ~9× slower than M1c due to the LP solve per event window. M3 is ~200× slower than M1c
due to a full-year LP dispatch per scenario.

**Decision for paper:** Market-pattern variants have no runtime disadvantage vs M1c. For the
runtime column in the appendix table, use: MP_pure_cur 0.045 s/scen, MP_emergency_cur 0.046 s/scen
(balanced VRE warm-start median; wind-heavy values within 8%).

---

## 6. SOC Boundary Check

Source: `results/paper_tables/market_pattern_soc_boundary_check.csv`

**Finding:** All 20 scenarios in both cases end the year with SOC = 0.0 MWh (0% of E_max).

| Method | Case | init SOC | mean final SOC | drift | ΔEUE (cyclic) |
|---|---|---|---|---|---|
| MP_pure_cur | Balanced VRE | 50% | 0.0% | −50% | 0.000 MWh |
| MP_emergency_cur | Balanced VRE | 50% | 0.0% | −50% | 0.000 MWh |
| MP_pure_cur | Wind-heavy | 50% | 0.0% | −50% | 0.000 MWh |
| MP_emergency_cur | Wind-heavy | 50% | 0.0% | −50% | 0.000 MWh |

**Interpretation:**
- The market-pattern dispatch (charge-curtailed) fully depletes storage by year-end
- The cyclic equilibrium is initial SOC = 0%
- Running with 0% initial SOC gives identical annual EUE (ΔEUE = 0.000 MWh)
- The initial 50% SOC (1966 MWh) provides capacity in the first hours of each scenario
  but has no measurable effect on annual EUE statistics

This is mechanistically expected: with `charge_curtailed=true`, storage charges only from
surplus and follows the market pattern for discharge. The net annual energy balance is
negative (more total discharge than charge because shortage events can discharge beyond
what the pattern charges back). Storage always fully depletes within the year.

**Decision for paper:** Use fixed 50% initial SOC (current default). Note that the market-
pattern method's cyclic equilibrium is near 0% SOC — the method depletes storage annually.
This is qualitatively different from M1c/M2 (which use `cyclic_soc=true`) and should be
disclosed in the appendix.

---

## 7. CAISO Data Quality Assessment

Full analysis: `docs/caiso_storage_data_source_check.md` (updated 2026-06-14)

| Issue | Finding | Severity | Action |
|---|---|---|---|
| 8758 rows (vs 8760 expected) | DST artifact: spring-forward gap + fall-back deduplication | Negligible | Accept as-is; disclose in appendix |
| Non-battery contamination | Geothermal <10% of p95 signal; doesn't alter diurnal shape | Low | Disclose limitation |
| No dedicated battery column 2023 | EIA-930 "Other Fuel Sources" is best available; "BAT" fuel type not available for CISO 2023 | Medium | Disclose; recommend update if 2024 data includes BAT column |
| Normalization sensitivity (p90 vs p99) | ±17–18% effect on pattern rates | Medium | Run sensitivity when CC is finalised |
| Hour-of-day mapping | Build script and Julia dispatch code are consistent (both 0-based) | None | — |

**Decision for paper:** The "Other Fuel Sources" EIA-930 proxy is acceptable for a calibrated
pattern method. The appendix should state: data source, normalization choice (p95), DST gap,
and the 2023 CISO other-source limitation. A sensitivity figure showing CC at p90/p99 normalization
should be included if the appendix has space.

---

## 8. Sampling Convergence

Source: `results/paper_tables/market_pattern_sampling_convergence.csv`

### Balanced VRE

| N | MP_pure_cur EUE (MWh) | MP_pure_cur CC | MP_emergency_cur EUE (MWh) | MP_emergency_cur CC |
|---|---|---|---|---|
| 20 | 13,661.96 | 0.143 | 4,338.32 | 0.336 |
| 50 | 14,765.84 | 0.145 | 4,876.85 | 0.354 |
| 100 | 14,531.69 | 0.143 | 4,604.19 | 0.412 |
| 200 | 15,060.82 | 0.143 | 5,221.21 | 0.418 |

### Wind-heavy

| N | MP_pure_cur EUE (MWh) | MP_pure_cur CC | MP_emergency_cur EUE (MWh) | MP_emergency_cur CC |
|---|---|---|---|---|
| 20 | 7,160.64 | 0.128 | 1,117.40 | 0.430 |
| 50 | 7,909.60 | 0.131 | 1,565.95 | NaN* |
| 100 | 7,823.65 | 0.130 | 1,520.00 | 1.305** |
| 200 | 8,278.73 | 0.133 | 1,920.04 | 0.897 |

*NaN: denom ≤ 1e-9 (EUE_plus_firm ≈ EUE_base for this N sample)
**CC > 1 is valid for 4-hour storage when storage has more energy than 1 MW × LOLH

**Findings:**
- **MP_pure_cur EUE and CC converge well at N=20** for balanced VRE (CC stable at 0.143–0.145)
- **MP_pure_cur wind-heavy** shows higher variance but CC is stable at 0.128–0.133
- **MP_emergency_cur balanced VRE CC is less stable at N=20** (0.336 at N=20 vs 0.41–0.42 at N≥100). The N=200 estimate (0.418) appears to be the reliable value.
- **MP_emergency_cur wind-heavy CC is highly variable** at N=20–200, ranging from NaN to 1.31. This is because EUE is small (~1100–1920 MWh) relative to the variance, making CC ratios unstable.

**Decision for paper:**
- Report N=20 CC values for MP_pure_cur (stable; consistent across N)
- Report N=200 CC value for MP_emergency_cur balanced VRE (0.418 vs 0.336 at N=20; include a note)
- Wind-heavy MP_emergency_cur CC: report the N=200 value (0.897) with a caveat that the estimate is noisy
- Alternatively: add a footnote stating "CC for market-pattern + emergency at wind-heavy is sensitive to N; reported value may understate/overstate by 2×"

---

## 9. Explicit Decisions for the Manuscript

### What to include in the paper

**Main Table IV:** No market-pattern variants. The MP variants have EUE 2–11× higher than M1c
(for balanced VRE) and CC 29–68% of M1c. They are not competitive with existing methods.

**Appendix (sensitivity):** Include both paper-facing variants as a benchmark against M1c,
demonstrating the cost of realistic dispatch constraints on reliability:
1. Market-pattern storage MCS (MP_pure_cur): worst-case / pure dispatch constraint
2. Market-pattern + emergency storage MCS (MP_emergency_cur): best-case / mixed rule

### Narrative

The market-pattern method quantifies the reliability penalty from dispatch constraints:
economically-motivated storage dispatch (CAISO 2023 pattern) delivers only 29–43% of the
capacity credit of optimally-dispatched storage (M1c). Adding an emergency override during
shortage hours (the mixed rule) recovers half the gap (68% of M1c CC for balanced VRE).

### Items NOT resolved yet

1. **Normalization sensitivity (p90/p99):** Quantified but not simulated. One more script run
   needed if the appendix includes a sensitivity figure.
2. ~~Runtime benchmark: Script 71 in progress.~~ **RESOLVED.** Values in `runtime_common_benchmark.csv`;
   see Section 5.
3. **CC at N=200 for wind-heavy MP_emergency_cur:** Highly variable (0.90 at N=200); decide whether
   to include or suppress this value in the paper.

---

## 10. Source File Map

| Output | Script | Decision |
|---|---|---|
| `results/paper_tables/market_pattern_capacity_credit.csv` | `70_market_pattern_marginal_cc.jl` | Include in appendix |
| `results/paper_tables/market_pattern_table_iv_rows.csv` | same | Candidate rows for appendix Table IV |
| `results/paper_tables/market_pattern_soc_boundary_check.csv` | same | Supplementary; disclose SOC boundary issue |
| `results/paper_tables/market_pattern_sampling_convergence.csv` | same | Supplementary; use to justify N choice |
| `results/paper_tables/runtime_common_benchmark.csv` | `71_runtime_benchmark.jl` | Use for Table IV runtime column |
| `docs/market_pattern_table_iv_source_audit.md` | — | Internal reference; close the discrepancy |
| `docs/caiso_storage_data_source_check.md` | — | Appendix data-source section |
| `docs/market_pattern_capacity_credit_check.md` | — | Internal; verify CC methodology |
| `docs/market_pattern_storage_mcs_preliminary.md` | — | Source for appendix narrative |
