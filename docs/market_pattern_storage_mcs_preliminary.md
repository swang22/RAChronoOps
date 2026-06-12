# Market-Pattern Storage MCS — Preliminary Analysis

**Date:** 2026-06-11
**Status:** Prototype / sensitivity analysis — not yet in manuscript.
**Script:** `scripts/67_run_market_pattern_storage.jl`
**Results:** `results/paper_tables/market_pattern_storage_results.csv`

---

## Summary of Results

| Case | Method | LOLH (h) | EUE (MWh) | CVaR-EUE (MWh) |
|---|---|---|---|---|
| Balanced VRE | Market-pattern storage MCS (pure) | 51.45 | 14 321 | 27 335 |
| Balanced VRE | Market-pattern + emergency MCS | 13.55 | 4 668 | 16 209 |
| Balanced VRE | Emergency-only storage MCS (M1c) | 5.95 | 2 479 | 9 783 |
| Balanced VRE | Event-window storage MCS (M2) | 5.75 | 2 479 | 9 783 |
| Balanced VRE | Full-year ED (M3) | 5.95 | 2 479 | 9 783 |
| Balanced VRE | PCM-UCED | 7.25 | 2 479 | 9 783 |
| Wind-heavy | Market-pattern storage MCS (pure) | 27.45 | 7 560 | 15 264 |
| Wind-heavy | Market-pattern + emergency MCS | 6.00 | 1 456 | 6 267 |
| Wind-heavy | Emergency-only storage MCS (M1c) | 2.25 | 648 | 3 528 |
| Wind-heavy | Event-window storage MCS (M2) | 1.95 | 648 | 3 528 |
| Wind-heavy | Full-year ED (M3) | 2.25 | 648 | 3 528 |
| Wind-heavy | PCM-UCED | 2.65 | 660 | 3 624 |

---

## Pre-Shortage SOC Diagnostics

| Case | Method | Mean SOC/E_max | P10 SOC/E_max | % hours SOC < 25% |
|---|---|---|---|---|
| Balanced VRE | MP pure | 0.732 | 0.549 | 0.9% |
| Balanced VRE | MP + emergency | 0.671 | 0.250 | 10.0% |
| Wind-heavy | MP pure | 0.748 | 0.565 | 0.2% |
| Wind-heavy | MP + emergency | 0.707 | 0.412 | 5.5% |

---

## Discussion

### 1. Does pure market-pattern dispatch increase EUE/LOLH vs emergency-only?

**Yes — dramatically.** Market-pattern storage MCS (pure, Variant 1) produces:
- Balanced VRE: LOLH = 51.45 h, EUE = 14 321 MWh — approximately **8.6× higher LOLH**
  and **5.8× higher EUE** than emergency-only (M1c).
- Wind-heavy: LOLH = 27.45 h, EUE = 7 560 MWh — approximately **12× higher LOLH**
  and **11.7× higher EUE** than emergency-only.

The increase is large but the mechanism has two components:

**Component A — SOC not available at shortage:**
SOC-before-shortage is actually *high* (mean 73–75% of capacity) for the pure variant.
This means the battery has energy but the market pattern **does not call for discharge** at
the hours when shortfalls occur. CAISO batteries charge midday (9am–2pm) and discharge in
the evening ramp (5pm–9pm), and shortage hours in this test system occur at different times.
The pure variant does not deviate from the pattern even during shortfalls — it provides only
pattern-level discharge in shortage hours regardless of how severe the shortfall is.

**Component B — Sub-optimal pre-shortage positioning:**
Market charging patterns differ from emergency-only charging. M1c charges greedily from all
surplus hours, maximizing SOC heading into shortage periods. The market pattern may skip
charging in some surplus hours (when the pattern calls for low charge rates) and discharge
in some non-shortage hours that would otherwise have preserved SOC.

The key finding for Component A is unexpected: the dominant driver of market-pattern failure
in these test cases is **dispatch undersupply in shortage hours** (pattern says low discharge
when the shortfall occurs), not pre-event SOC depletion. This is important nuance for the paper.

### 2. Does the emergency override (Variant 2) recover most EUE benefit?

**Partially.** The emergency-override variant recovers a substantial fraction of the
emergency-only benefit but not all:

- Balanced VRE: LOLH = 13.55 h (vs 5.95 for M1c) — **2.3× higher** despite emergency override
- Wind-heavy: LOLH = 6.00 h (vs 2.25 for M1c) — **2.7× higher** despite emergency override
- EUE: 4 668 vs 2 479 (balanced) — **1.9× higher**; 1 456 vs 648 (wind-heavy) — **2.2× higher**

The residual gap after emergency override is explained by Component B above: the market
pattern's non-optimal charging strategy leaves the battery at lower SOC at shortage time than
emergency-only charging. For MP + emergency:
- Mean pre-shortage SOC is 67% (balanced) and 71% (wind-heavy) vs 73–75% for pure.
- P10 SOC is 25% (balanced) and 41% (wind-heavy) — a non-trivial fraction of shortage
  hours enter scarcity with low storage reserves.
- 10% of shortage hours (balanced) have SOC < 25% of capacity — these hours experience
  larger shortfalls than they would if the battery had charged from all surplus.

### 3. Average SOC before shortage hours

Pre-shortage SOC (mean across all shortage-hour entries):
- MP pure: 73–75% of energy capacity — **high SOC, but dispatch-constrained**
- MP + emergency: 67–71% — **lower SOC from market activity**, some low-SOC entries

For reference, emergency-only storage (M1c) would approach near-maximum SOC before shortage
events in this test system (since it charges from every surplus hour), though that comparison
requires computing `compute_soc_before_shortage` on M1c results (not currently in the table).

### 4. Does this support the hypothesis about economic storage understating reliability?

**Yes, with an important qualification.**

The result confirms the hypothesis: a battery operated following historical CAISO market
patterns (charge midday, discharge evenings) produces substantially higher EUE/LOLH than a
battery reserved entirely for emergency discharge. The gap is large: 2–12× depending on variant
and portfolio.

However, the dominant mechanism is not (only) SOC depletion before shortfalls — it is also
that the **market dispatch pattern does not provide adequate discharge during shortage hours**
even when SOC is available. This implies:

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
pattern (Variant 1) is a lower bound on realistic behavior. The emergency override (Variant 2)
is closer to reality but likely still conservative. The true behavior lies between them. The
paper's emergency-only and event-window methods can be framed as "upper bounds on reliability
value" in the sense that they assume full dispatch cooperation during shortfalls.

### 5. Is the method stable enough for an appendix sensitivity?

**Conditionally yes.** Practical assessment:

**Strengths:**
- Computationally lightweight: runs in <1 second, same order as M1c
- Produces stable results: no LP solves, no random draws beyond scenario generation
- Uses reproducible, publicly available data (EIA-930 downloadable without API key)
- Results are strongly directionally consistent across both portfolios (large EUE increase)
- Clear and interesting narrative for the paper

**Weaknesses and limitations:**
- Battery proxy ("Other Fuel Sources") includes minor non-battery sources; the contamination
  is small relative to the signal but not zero
- The pattern normalization (95th-percentile of observed CAISO discharge) is an approximation;
  the actual CAISO battery capacity in 2023 was ~2.5 GW but grew significantly during the year
- The pattern represents CAISO aggregate behavior, not RTS-GMLC system conditions; applying
  CAISO patterns to a different system is a deliberate calibration, not a simulation
- The method tests one specific behavioral assumption (follow CAISO-observed pattern); real
  storage behavior would be shaped by the test system's price signals
- Pure variant (Variant 1) is probably too conservative (CAISO batteries do respond to scarcity);
  Variant 2 is more plausible but still understates emergency response

**Recommendation:** Include as an appendix sensitivity framed as "if storage followed CAISO-
observed market dispatch patterns (charge midday, discharge evenings), how would reliability
metrics compare?" Frame Variant 1 as a lower bound and Variant 2 as a more plausible market
dispatch with emergency override. Use this to motivate the emergency-only and event-window
methods as reliability-preserving assumptions.

Do not include in the main results table (PCM-UCED is the benchmark; market-pattern is a
behavioral sensitivity). Report EUE and LOLH for both variants vs M1c in an appendix table.

---

## Files

| File | Description |
|---|---|
| `src/models/MarketPatternStorage.jl` | Julia implementation (two variants + SOC diagnostics) |
| `scripts/build_caiso_storage_patterns.py` | EIA-930 download and pattern extraction |
| `scripts/67_run_market_pattern_storage.jl` | Test runner for both cases |
| `data_processed/caiso_storage_patterns/caiso_storage_hourly.csv` | 8758-row hourly CISO 2023 dataset |
| `data_processed/caiso_storage_patterns/season_hour_pattern.csv` | 96-row season×hour pattern |
| `results/paper_tables/market_pattern_storage_results.csv` | Full results table |
| `results/market_pattern_storage/soc_diagnostics.csv` | Pre-shortage SOC statistics |
| `docs/caiso_storage_data_source_check.md` | Data source investigation report |
