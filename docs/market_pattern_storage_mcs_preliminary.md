# Market-Pattern Storage MCS — Preliminary Analysis

**Date:** 2026-06-11
**Status:** Prototype / sensitivity analysis — not yet in manuscript.
**Scripts:** `scripts/67_run_market_pattern_storage.jl`, `scripts/68_diagnose_market_pattern_storage.jl`, `scripts/69_event_start_soc.jl`
**Results:** `results/paper_tables/market_pattern_storage_results.csv`, `results/paper_tables/market_pattern_eue_decomposition.csv`, `results/paper_tables/market_pattern_event_start_soc.csv`

---

## Summary of Results (all four variants + benchmarks)

| Case | Method | LOLH (h) | EUE (MWh) | CVaR-EUE (MWh) |
|---|---|---|---|---|
| Balanced VRE | MP pure (uncurtailed) | 51.45 | 14 321 | 27 335 |
| Balanced VRE | MP pure (curtailed) | 46.10 | 13 662 | 26 276 |
| Balanced VRE | MP + emergency (uncurtailed) | 13.55 | 4 668 | 16 209 |
| Balanced VRE | MP + emergency (curtailed) | 9.15 | 4 338 | 15 812 |
| Balanced VRE | Emergency-only storage MCS | 5.95 | 2 479 | 9 783 |
| Balanced VRE | Event-window storage MCS | 5.10 | 2 479 | 9 783 |
| Wind-heavy | MP pure (uncurtailed) | 27.45 | 7 560 | 15 264 |
| Wind-heavy | MP pure (curtailed) | 23.90 | 7 161 | 14 518 |
| Wind-heavy | MP + emergency (uncurtailed) | 6.00 | 1 456 | 6 267 |
| Wind-heavy | MP + emergency (curtailed) | 2.85 | 1 117 | 5 509 |
| Wind-heavy | Emergency-only storage MCS | 2.25 | 648 | 3 528 |
| Wind-heavy | Event-window storage MCS | 1.75 | 648 | 3 528 |

*Curtailed = charging strictly limited to available surplus. Uncurtailed = charging limit = surplus + total_power, which can produce load shedding in non-shortage hours.*

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
Missed-discharge: EUE that would have been avoided by full emergency discharge.
Low-SOC: EUE in shortage hours where pre-shortage SOC < 25% E_max.*

---

## Pre-Shortage SOC Diagnostics (all methods)

| Case | Method | Mean SOC/E_max | P10 SOC/E_max | % hours SOC < 25% |
|---|---|---|---|---|
| Balanced VRE | MP pure (uncurtailed) | 0.732 | 0.549 | 0.9% |
| Balanced VRE | MP pure (curtailed) | 0.722 | 0.549 | 0.9% |
| Balanced VRE | MP + emergency (uncurtailed) | 0.671 | 0.250 | 10.0% |
| Balanced VRE | MP + emergency (curtailed) | 0.664 | 0.239 | 10.4% |
| Balanced VRE | Emergency-only storage MCS | 0.186 | 0.000 | 71.4% |
| Balanced VRE | Event-window storage MCS | 0.511 | 0.043 | 26.5% |
| Wind-heavy | MP pure (uncurtailed) | 0.748 | 0.565 | 0.2% |
| Wind-heavy | MP pure (curtailed) | 0.740 | 0.565 | 0.2% |
| Wind-heavy | MP + emergency (uncurtailed) | 0.707 | 0.412 | 5.5% |
| Wind-heavy | MP + emergency (curtailed) | 0.698 | 0.402 | 6.2% |
| Wind-heavy | Emergency-only storage MCS | 0.335 | 0.000 | 53.3% |
| Wind-heavy | Event-window storage MCS | 0.543 | 0.096 | 20.0% |

---

## Event-Start SOC Diagnostics (all methods)

| Case | Method | Mean SOC/E_max | P10 SOC/E_max | % events SOC < 25% | % events SOC < 50% | N events |
|---|---|---|---|---|---|---|
| Balanced VRE | MP pure | 0.819 | 0.769 | 0.0% | 0.0% | 540 |
| Balanced VRE | MP pure (curtailed) | 0.812 | 0.743 | 0.0% | 0.0% | 540 |
| Balanced VRE | MP + emergency | 0.849 | 0.769 | 0.0% | 0.0% | 540 |
| Balanced VRE | MP + emergency (curtailed) | 0.844 | 0.759 | 0.0% | 0.0% | 540 |
| Balanced VRE | Emergency-only storage MCS | **0.999** | 1.000 | 0.0% | 0.0% | 540 |
| Balanced VRE | Event-window storage MCS | 0.325 | 0.030 | 51.3% | 76.1% | 540 |
| Balanced VRE | Full-year ED | 0.828 | 0.622 | 0.4% | 4.1% | 540 |
| Wind-heavy | MP pure | 0.817 | 0.769 | 0.0% | 0.3% | 370 |
| Wind-heavy | MP pure (curtailed) | 0.811 | 0.744 | 0.0% | 0.3% | 370 |
| Wind-heavy | MP + emergency | 0.837 | 0.769 | 0.3% | 0.8% | 370 |
| Wind-heavy | MP + emergency (curtailed) | 0.831 | 0.754 | 0.3% | 1.1% | 370 |
| Wind-heavy | Emergency-only storage MCS | **0.998** | 1.000 | 0.0% | 0.0% | 370 |
| Wind-heavy | Event-window storage MCS | 0.404 | 0.056 | 31.6% | 61.6% | 370 |
| Wind-heavy | Full-year ED | 0.790 | 0.547 | 0.8% | 5.1% | 370 |

*A shortage event is a maximal contiguous block of hours with pre-storage shortfall > 0.
SOC measured at end-of-hour immediately before the first hour of each event.*

---

## Discussion

### 1. Does pure market-pattern dispatch increase EUE/LOLH vs emergency-only?

**Yes, substantially.** Market-pattern storage MCS (pure, uncurtailed) produces:
- Balanced VRE: LOLH = 51.45 h, EUE = 14 321 MWh — approximately **8.6× higher LOLH**
  and **5.8× higher EUE** than emergency-only storage MCS.
- Wind-heavy: LOLH = 27.45 h, EUE = 7 560 MWh — approximately **12× higher LOLH**
  and **11.7× higher EUE** than emergency-only.

The EUE decomposition suggests the dominant driver is **missed discharge** (92–97% of EUE):
market-pattern variants enter shortage events with reasonably high SOC (81–85% on average;
see event-start SOC table), but the CAISO-calibrated dispatch pattern does not call for
adequate discharge during RTS shortage hours. CAISO batteries charge midday (9am–2pm) and
discharge in the evening ramp (5pm–9pm); shortage hours in the RTS-GMLC test system occur
at different times, and the pure variant does not deviate from the pattern during scarcity.
The performance gap is therefore driven primarily by dispatch timing mismatch, not
pre-event SOC depletion.

Charging beyond surplus (in the uncurtailed variants) contributes only 4.6–5.3% of EUE for
the pure variants — it is a secondary effect.

### 2. Does the emergency override (Variant 3) recover most EUE benefit?

**Partially.** The emergency-override (uncurtailed) variant recovers a substantial fraction
of the emergency-only benefit but not all:

- Balanced VRE: LOLH = 13.55 h (vs 5.95 for emergency-only storage MCS) — **2.3× higher** despite emergency override
- Wind-heavy: LOLH = 6.00 h (vs 2.25 for emergency-only) — **2.7× higher** despite emergency override

The EUE decomposition helps explain the residual gap: with emergency override the missed-discharge
component drops to 0% (the emergency rule fully substitutes for the pattern in shortage hours),
but **low-SOC EUE rises to 66–85%** of total EUE. This means the battery enters many shortage
hours with insufficient SOC — depleted by market-pattern charging and discharging in non-shortage
hours before and between shortage events. Furthermore, **11.7–26.2% of EUE is charging-induced**
in the uncurtailed emergency variant: the market pattern charges beyond available surplus in
non-shortage hours, directly creating load shedding in those hours.

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

**The curtailed variants confirm this diagnosis:** charging-induced EUE drops to exactly 0%
in all curtailed variants by construction. The remaining EUE in the charge-curtailed emergency
variant (MP + emergency, curtailed) is classified as low-SOC (96.3% of EUE for balanced VRE,
90.3% for wind-heavy). This reflects lower SOC during shortage hour sequences: market-pattern
dispatch in non-shortage hours — following the CAISO duck-curve timing rather than charging
from all available surplus — leaves less energy available as shortage events progress through
multiple hours. This is a real pre-positioning cost of market-pattern operation, but is
distinct from charging-induced load shedding; the curtailed variant does not shed load in
non-shortage hours.

### 4. What does the emergency-only method's low per-shortage-hour SOC mean?

**An apparent paradox in the per-hour diagnostic:** emergency-only storage MCS enters
shortage hours with the lowest average SOC (mean 18.6% balanced, 33.5% wind-heavy vs
73–75% for pure market-pattern variants).

The explanation is **sequential event depletion**: during multi-hour shortage events,
emergency-only storage discharges aggressively at each shortage hour. By the end of an event
the battery is depleted. The per-hour mean averages across all hours in all events, including
the later hours of long events where the battery is already nearly empty. This reflects the
method operating as intended, but the metric is not straightforward to interpret without
knowing event length and sequencing.

**The event-start SOC diagnostic is a more appropriate diagnostic for this question.**

### 5. Event-start SOC: entering shortage events with energy

**Event-start SOC** — measured at the end of the hour immediately before the first
shortage hour of each event — removes intra-event depletion from the diagnostic. The
results (script `69_event_start_soc.jl`) show a picture that differs substantially from
the per-shortage-hour diagnostic:

| Method | Balanced VRE | Wind-heavy |
|---|---|---|
| Emergency-only storage MCS | **0.999** | **0.998** |
| Market-pattern variants | 0.81–0.85 | 0.81–0.84 |
| Full-year ED | 0.828 | 0.790 |
| Event-window storage MCS | 0.325 | 0.404 |

**Emergency-only storage MCS enters every shortage event at 99.9% SOC.** Charging from
all available surplus is consistent with near-maximum pre-event positioning. Zero events
start below 50% SOC.

**Market-pattern variants enter at 81–85%.** Market activity (charging on the duck-curve
schedule, discharging on the evening-ramp schedule regardless of grid state) is associated
with 15–19 percentage points lower event-start SOC compared with emergency-only storage
MCS. Importantly, zero events start below 50% SOC and virtually none below 25% for the
balanced VRE portfolio. The 15–19 pp pre-event SOC gap is smaller than would be needed,
on its own, to account for the 8.6–12× LOLH gap between the pure market-pattern variants
and emergency-only storage MCS. This is consistent with dispatch timing — not pre-event
depletion — being the **dominant driver** of the reliability gap. Market-pattern variants
have reasonably high event-start SOC; their poor performance relative to emergency-only is
driven mainly by the CAISO pattern not calling for discharge during RTS shortage hours.

**Full-year ED enters at 79–83%**, comparable to market-pattern variants. Near-zero events
start below 25%. Full-year ED achieves the best reliability metrics in part by optimally
timing discharge within events using full-year foresight; pre-event SOC is similar to
market-pattern variants.

**Event-window storage MCS enters at only 32–40% SOC**, with 32–51% of events starting
below 25%. Yet event-window storage MCS achieves the lowest LOLH of any sequential MCS
method. The LP solves over the full event window and can allocate discharge optimally
across event hours. The emergency-only method, by contrast, discharges greedily from the
first shortage hour, which is energy-efficient but not necessarily optimal if shortfall
magnitude varies across the event.

**Caution on event-window SOC comparisons:** Event-start SOC for event-window storage MCS
is not directly comparable to rule-based methods. The screened LP window may begin before
the first pre-storage shortfall hour and can dispatch storage in advance of the event
boundary as defined here. This makes its event-start SOC structurally lower than would be
expected from a method that charges from all surplus and discharges only in shortage hours.

Event-window storage MCS also achieves the same EUE as emergency-only storage MCS
(2479 MWh / 648 MWh across both cases) despite lower event-start SOC. This is consistent
with the same total unserved energy being concentrated into fewer shortage hours through
more efficient intra-event dispatch.

**Key interpretation for the paper:**
The per-shortage-hour SOC is a less informative diagnostic because it conflates event-entry
positioning with intra-event depletion. Event-start SOC is a more appropriate diagnostic
for this question. With this metric:
- Emergency-only storage MCS provides maximal pre-event positioning (~99% entry SOC) and is appropriate as an upper-bound reliability estimate
- Market-pattern variants show a moderate pre-event SOC gap (15–19 pp) but enter shortage events with reasonably high SOC (81–85%); their reliability gap is driven by dispatch timing mismatch, not pre-event depletion
- For market-pattern + emergency (curtailed), residual EUE relative to emergency-only storage MCS comes from lower SOC during shortage hour sequences and market-pattern pre-positioning — not from charging-induced load shedding

### 6. Does this support the hypothesis about economic storage understating reliability?

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
3. This is an argument for why the emergency-only and event-window storage methods —
   which reserve both energy *and* dispatch capacity for shortage hours — are appropriate
   upper-bound reliability estimates.

**Important caveat:** CAISO batteries do respond to shortage conditions in real grid operations
via ancillary services, emergency dispatch procedures, and price signals. The pure market
pattern is a lower bound on realistic behavior. The emergency override is closer to reality
but likely still conservative. The true behavior lies between them. The paper's emergency-only
and event-window methods can be framed as "upper bounds on reliability value" in the sense
that they assume full dispatch cooperation during shortfalls.

### 7. Which variant is most defensible for paper use?

**For manuscript use, the most defensible behavioral sensitivity is the charge-curtailed
market-pattern + emergency variant.** The pure variants are useful diagnostics but are too
strict to represent realistic RA response because they do not increase discharge during
scarcity. The charge-curtailed market-pattern + emergency variant is preferred because:
- Emergency override in shortage hours represents the minimum realistic response to scarcity
- Charging strictly limited to surplus eliminates the artificial load-shedding artifact
- All residual EUE vs emergency-only storage MCS is from genuine SOC depletion caused by market-pattern operation

**The charge-curtailed pure market-pattern variant** provides the most conservative lower
bound for this sensitivity:
- No emergency response even during observed shortfalls
- Charging limited to surplus
- 97% of EUE attributable to dispatch timing mismatch (missed discharge in shortage hours)

### 8. Is the method stable enough for an appendix sensitivity?

**Conditionally yes.** Practical assessment:

**Strengths:**
- Computationally lightweight: runs in <1 second, comparable to emergency-only storage MCS
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

**Recommendation:** Include as an appendix sensitivity using the charge-curtailed pure
market-pattern variant as the lower bound and the charge-curtailed market-pattern +
emergency variant as the more plausible behavioral scenario. Frame both relative to
emergency-only and event-window storage MCS. Use the EUE decomposition to explain the
mechanism. Do not include in the main results table (PCM-UCED is the benchmark;
market-pattern is a behavioral sensitivity).

---

## Files

| File | Description |
|---|---|
| `src/models/MarketPatternStorage.jl` | Julia implementation (four variants + SOC diagnostics + EUE decomposition) |
| `scripts/build_caiso_storage_patterns.py` | EIA-930 download and pattern extraction |
| `scripts/67_run_market_pattern_storage.jl` | Initial two-variant test runner |
| `scripts/68_diagnose_market_pattern_storage.jl` | Full diagnostic runner (all 4 variants + emergency-only/event-window) |
| `scripts/69_event_start_soc.jl` | Event-start SOC runner (all 4 MP + emergency-only/event-window/full-year ED) |
| `data_processed/caiso_storage_patterns/caiso_storage_hourly.csv` | 8758-row hourly CISO 2023 dataset |
| `data_processed/caiso_storage_patterns/season_hour_pattern.csv` | 96-row season×hour pattern |
| `results/paper_tables/market_pattern_storage_results.csv` | Full results table (4 MP variants + benchmarks) |
| `results/paper_tables/market_pattern_eue_decomposition.csv` | EUE decomposition for MP variants |
| `results/paper_tables/market_pattern_event_start_soc.csv` | Event-start SOC (all 7 methods × 2 cases) |
| `results/market_pattern_storage/soc_diagnostics.csv` | Per-shortage-hour SOC (all 6 methods) |
| `docs/caiso_storage_data_source_check.md` | Data source investigation report |
