# Market-Pattern Storage MCS — Preliminary Analysis

**Date:** 2026-06-11
**Status:** Prototype / sensitivity analysis — not yet in manuscript.
**Scripts:** `scripts/67_run_market_pattern_storage.jl`, `scripts/68_diagnose_market_pattern_storage.jl`
**Results:** `results/paper_tables/market_pattern_storage_results.csv`, `results/paper_tables/market_pattern_eue_decomposition.csv`

---

## Summary of Results (all four variants + benchmarks)

| Case | Method | LOLH (h) | EUE (MWh) | CVaR-EUE (MWh) |
|---|---|---|---|---|
| Balanced VRE | MP pure (uncurtailed) | 51.45 | 14 321 | 27 335 |
| Balanced VRE | MP pure (curtailed) | 46.10 | 13 662 | 26 276 |
| Balanced VRE | MP + emergency (uncurtailed) | 13.55 | 4 668 | 16 209 |
| Balanced VRE | MP + emergency (curtailed) | 9.15 | 4 338 | 15 812 |
| Balanced VRE | Emergency-only storage MCS (M1c) | 5.95 | 2 479 | 9 783 |
| Balanced VRE | Event-window storage MCS (M2) | 5.10 | 2 479 | 9 783 |
| Wind-heavy | MP pure (uncurtailed) | 27.45 | 7 560 | 15 264 |
| Wind-heavy | MP pure (curtailed) | 23.90 | 7 161 | 14 518 |
| Wind-heavy | MP + emergency (uncurtailed) | 6.00 | 1 456 | 6 267 |
| Wind-heavy | MP + emergency (curtailed) | 2.85 | 1 117 | 5 509 |
| Wind-heavy | Emergency-only storage MCS (M1c) | 2.25 | 648 | 3 528 |
| Wind-heavy | Event-window storage MCS (M2) | 1.75 | 648 | 3 528 |

*Curtailed = charging strictly limited to available surplus. Uncurtailed = original bug: charging limit = surplus + total_power.*

---

## EUE Decomposition (market-pattern variants)

| Case | Method | Charging-induced % | Missed-discharge % | Low-SOC % |
|---|---|---|---|---|
| Balanced VRE | MP pure (uncurtailed) | 4.6% | 92.8% | 0.0% |
| Balanced VRE | MP pure (curtailed) | 0.0% | 97.3% | 0.1% |
| Balanced VRE | MP + emergency (uncurtailed) | 11.7% | 0.0% | 84.7% |
| Balanced VRE | MP + emergency (curtailed) | 0.0% | 0.0% | 96.3% |
| Wind-heavy | MP pure (uncurtailed) | 5.3% | 92.2% | 0.0% |
| Wind-heavy | MP pure (curtailed) | 0.0% | 97.4% | 0.0% |
| Wind-heavy | MP + emergency (uncurtailed) | 26.2% | 0.0% | 66.4% |
| Wind-heavy | MP + emergency (curtailed) | 0.0% | 0.0% | 90.3% |

*Charging-induced: EUE in hours with no pre-storage shortfall, caused by charging that exceeded surplus.
Missed-discharge: EUE that would have been avoided by emergency (M1c) discharge.
Low-SOC: EUE in shortage hours where pre-shortage SOC < 25% E_max.*

---

## Pre-Shortage SOC Diagnostics (all methods)

| Case | Method | Mean SOC/E_max | P10 SOC/E_max | % hours SOC < 25% |
|---|---|---|---|---|
| Balanced VRE | MP pure (uncurtailed) | 0.732 | 0.549 | 0.9% |
| Balanced VRE | MP pure (curtailed) | 0.722 | 0.549 | 0.9% |
| Balanced VRE | MP + emergency (uncurtailed) | 0.671 | 0.250 | 10.0% |
| Balanced VRE | MP + emergency (curtailed) | 0.664 | 0.239 | 10.4% |
| Balanced VRE | M1c (emergency-only) | 0.186 | 0.000 | 71.4% |
| Balanced VRE | M2 (event-window LP) | 0.511 | 0.043 | 26.5% |
| Wind-heavy | MP pure (uncurtailed) | 0.748 | 0.565 | 0.2% |
| Wind-heavy | MP pure (curtailed) | 0.740 | 0.565 | 0.2% |
| Wind-heavy | MP + emergency (uncurtailed) | 0.707 | 0.412 | 5.5% |
| Wind-heavy | MP + emergency (curtailed) | 0.698 | 0.402 | 6.2% |
| Wind-heavy | M1c (emergency-only) | 0.335 | 0.000 | 53.3% |
| Wind-heavy | M2 (event-window LP) | 0.543 | 0.096 | 20.0% |

---

## Discussion

### 1. Does pure market-pattern dispatch increase EUE/LOLH vs emergency-only?

**Yes — dramatically.** Market-pattern storage MCS (pure, uncurtailed) produces:
- Balanced VRE: LOLH = 51.45 h, EUE = 14 321 MWh — approximately **8.6× higher LOLH**
  and **5.8× higher EUE** than emergency-only (M1c).
- Wind-heavy: LOLH = 27.45 h, EUE = 7 560 MWh — approximately **12× higher LOLH**
  and **11.7× higher EUE** than emergency-only.

The EUE decomposition shows the dominant driver is **missed discharge** (92–97% of EUE):
the battery has energy available (mean pre-shortage SOC 73–75%) but the market pattern
does not call for adequate discharge during shortage hours. CAISO batteries charge midday
(9am–2pm) and discharge in the evening ramp (5pm–9pm); shortage hours in this test system
occur at different times and the pure variant does not deviate from the pattern.

Charging beyond surplus (the uncurtailed bug) contributes only 4.6–5.3% of EUE for the pure
variants — it is a secondary factor.

### 2. Does the emergency override (Variant 3) recover most EUE benefit?

**Partially.** The emergency-override (uncurtailed) variant recovers a substantial fraction
of the emergency-only benefit but not all:

- Balanced VRE: LOLH = 13.55 h (vs 5.95 for M1c) — **2.3× higher** despite emergency override
- Wind-heavy: LOLH = 6.00 h (vs 2.25 for M1c) — **2.7× higher** despite emergency override

The EUE decomposition explains the residual gap: with emergency override the missed-discharge
component drops to 0% (the emergency rule fully substitutes for the pattern in shortage hours),
but **low-SOC EUE rises to 66–85%** of total EUE. This means the battery enters many shortage
hours with insufficient SOC — depleted by market-pattern charging and discharging in non-shortage
hours. Furthermore, **11.7–26.2% of EUE is charging-induced** in the uncurtailed emergency
variant: the market pattern charges beyond available surplus in non-shortage hours, directly
creating load shedding in those hours.

### 3. Does storage charging create load shedding?

**Yes, for the uncurtailed variants — but the magnitude depends on the variant.**

The original market-pattern implementation used `chg_limit = surplus + total_power` as the
charging limit, allowing storage to absorb load in hours where load already exceeded supply.
This is a bug: it creates artificial EUE in hours that were not short before storage acted.

**Diagnosis from EUE decomposition:**

- **Pure variants (uncurtailed):** 4.6% (balanced) and 5.3% (wind-heavy) of EUE is
  charging-induced. This is a secondary effect — the dominant problem (92–97% of EUE) is
  that the market pattern simply does not discharge enough during shortage hours. Fixing
  the charging rule (curtailed variant) reduces EUE by ~4–5% of the total.

- **Emergency variants (uncurtailed):** 11.7% (balanced) and 26.2% (wind-heavy) of EUE is
  charging-induced. The effect is much larger here because the emergency rule eliminates
  missed-discharge EUE but exposes the full charging-induced component. The wind-heavy case
  has more surplus hours (more wind generation), so there are more hours where the
  uncurtailed pattern charges beyond what surplus allows.

**Interpretation rule:**
If `charging_induced_pct > 5%`, the uncurtailed charging rule is materially inflating EUE,
and the curtailed variant should be used for fair comparison. For the emergency variants,
this threshold is clearly exceeded (11.7–26.2%).

**The curtailed variants confirm the diagnosis:** charging-induced EUE drops to exactly 0%
in all curtailed variants by construction. The remaining EUE in the curtailed emergency
variants (MP_emergency_cur) is entirely from low-SOC (96.3% of EUE for balanced VRE),
confirming that the residual gap vs M1c is explained by pre-shortage SOC depletion from
market-pattern charging/discharging in non-shortage hours.

### 4. What does M1c's low pre-shortage SOC mean?

**An unexpected finding: M1c enters shortage hours with the LOWEST pre-shortage SOC of
all methods** (mean 18.6% balanced, 33.5% wind-heavy vs 73–75% for pure market-pattern).

This appears paradoxical — M1c charges from all surplus hours, so shouldn't it have high
SOC going into shortage hours? The explanation is **sequential event depletion**: during
multi-hour shortage events (an outage sequence), M1c discharges aggressively at each
shortage hour. By the end of an event, the battery is depleted. The measured SOC is the
average across all shortage hours in all events — including the later hours of long events
where the battery has already been heavily discharged. For M1c, 71.4% (balanced) and
53.3% (wind-heavy) of shortage hours have SOC < 25%.

M2 (event-window LP) has mean pre-shortage SOC of 51.1% (balanced) and 54.3% (wind-heavy),
higher than M1c because the LP optimizes dispatch over the full event window and avoids
front-loading discharge.

The market-pattern variants have high mean pre-shortage SOC (66–75%) because the market
pattern does NOT discharge aggressively in shortage hours — it discharges on the fixed
daily schedule regardless of grid conditions. The high SOC is evidence of dispatch
conservatism, not reliability benefit.

**This reframes the pre-shortage SOC diagnostic:** for methods that dispatch optimally,
low pre-shortage SOC is expected (and correct) — the battery is doing its job. High
pre-shortage SOC for market-pattern variants indicates the opposite: the battery is
*not* responding to shortage conditions.

### 5. Does this support the hypothesis about economic storage understating reliability?

**Yes, with an important qualification.**

The result confirms the hypothesis: a battery operated following historical CAISO market
patterns (charge midday, discharge evenings) produces substantially higher EUE/LOLH than a
battery reserved entirely for emergency discharge. The gap is large: 2–12× depending on variant
and portfolio.

The dominant mechanism, however, is **dispatch undersupply in shortage hours** (pattern says
low discharge when the shortfall occurs, even though SOC is available), not SOC depletion.
This implies:

1. For reliability assessment, it matters not just *whether* storage energy is available at
   shortage time but *whether the dispatch rule uses it* to cover shortfalls.
2. A behaviorally realistic model of CAISO batteries that assumes "batteries will dispatch to
   serve shortage needs automatically" would substantially overstate battery's reliability value
   if real batteries follow market patterns.
3. This is an argument for why the emergency-only and event-window methods (M1c, M2) —
   which reserve both energy *and* dispatch capacity for shortage hours — are appropriate
   upper-bound reliability estimates.

**Important caveat:** CAISO batteries do respond to shortage conditions in real grid operations
via ancillary services, emergency dispatch procedures, and price signals. The pure market
pattern is a lower bound on realistic behavior. The emergency override is closer to reality
but likely still conservative. The true behavior lies between them. The paper's emergency-only
and event-window methods can be framed as "upper bounds on reliability value" in the sense
that they assume full dispatch cooperation during shortfalls.

### 6. Which variant is most defensible for paper use?

**MP_emergency_curtailed (Variant 4)** is the most physically defensible:
- Emergency override in shortage hours (batteries do respond to scarcity signals)
- Charging strictly limited to surplus (no artificial load shedding)
- All residual EUE vs M1c is from genuine pre-shortage SOC depletion from market activity

**MP_pure_curtailed (Variant 2)** is the most conservative lower bound:
- No emergency response even during observed shortfalls
- Charging limited to surplus
- 97% of EUE from genuine missed dispatch in shortage hours

### 7. Is the method stable enough for an appendix sensitivity?

**Conditionally yes.** Practical assessment:

**Strengths:**
- Computationally lightweight: runs in <1 second, same order as M1c
- Produces stable results: no LP solves, no random draws beyond scenario generation
- Uses reproducible, publicly available data (EIA-930 downloadable without API key)
- Results are strongly directionally consistent across both portfolios (large EUE increase)
- EUE decomposition provides clear mechanistic narrative

**Weaknesses and limitations:**
- Battery proxy ("Other Fuel Sources") includes minor non-battery sources; the contamination
  is small relative to the signal but not zero
- The pattern normalization (95th-percentile of observed CAISO discharge) is an approximation;
  the actual CAISO battery capacity in 2023 was ~2.5 GW but grew significantly during the year
- The pattern represents CAISO aggregate behavior, not RTS-GMLC system conditions; applying
  CAISO patterns to a different system is a deliberate calibration, not a simulation
- The method tests one specific behavioral assumption (follow CAISO-observed pattern); real
  storage behavior would be shaped by the test system's price signals

**Recommendation:** Include as an appendix sensitivity using MP_pure_curtailed as the lower
bound and MP_emergency_curtailed as the more realistic market-dispatch scenario. Frame both
vs M1c and M2. Use the EUE decomposition to explain the mechanism. Do not include in the
main results table (PCM-UCED is the benchmark; market-pattern is a behavioral sensitivity).

---

## Files

| File | Description |
|---|---|
| `src/models/MarketPatternStorage.jl` | Julia implementation (four variants + SOC diagnostics + EUE decomposition) |
| `scripts/build_caiso_storage_patterns.py` | EIA-930 download and pattern extraction |
| `scripts/67_run_market_pattern_storage.jl` | Initial two-variant test runner |
| `scripts/68_diagnose_market_pattern_storage.jl` | Full diagnostic runner (all 4 variants + M1c/M2) |
| `data_processed/caiso_storage_patterns/caiso_storage_hourly.csv` | 8758-row hourly CISO 2023 dataset |
| `data_processed/caiso_storage_patterns/season_hour_pattern.csv` | 96-row season×hour pattern |
| `results/paper_tables/market_pattern_storage_results.csv` | Full results table (4 MP variants + benchmarks) |
| `results/paper_tables/market_pattern_eue_decomposition.csv` | EUE decomposition for MP variants |
| `results/market_pattern_storage/soc_diagnostics.csv` | Pre-shortage SOC statistics (all 6 methods) |
| `docs/caiso_storage_data_source_check.md` | Data source investigation report |
