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

---

## Event-Start SOC Diagnostics (all methods)

| Case | Method | Mean SOC/E_max | P10 SOC/E_max | % events SOC < 25% | % events SOC < 50% | N events |
|---|---|---|---|---|---|---|
| Balanced VRE | MP pure | 0.819 | 0.769 | 0.0% | 0.0% | 540 |
| Balanced VRE | MP pure (curtailed) | 0.812 | 0.743 | 0.0% | 0.0% | 540 |
| Balanced VRE | MP + emergency | 0.849 | 0.769 | 0.0% | 0.0% | 540 |
| Balanced VRE | MP + emergency (curtailed) | 0.844 | 0.759 | 0.0% | 0.0% | 540 |
| Balanced VRE | M1c | **0.999** | 1.000 | 0.0% | 0.0% | 540 |
| Balanced VRE | M2 | 0.325 | 0.030 | 51.3% | 76.1% | 540 |
| Balanced VRE | M3 | 0.828 | 0.622 | 0.4% | 4.1% | 540 |
| Wind-heavy | MP pure | 0.817 | 0.769 | 0.0% | 0.3% | 370 |
| Wind-heavy | MP pure (curtailed) | 0.811 | 0.744 | 0.0% | 0.3% | 370 |
| Wind-heavy | MP + emergency | 0.837 | 0.769 | 0.3% | 0.8% | 370 |
| Wind-heavy | MP + emergency (curtailed) | 0.831 | 0.754 | 0.3% | 1.1% | 370 |
| Wind-heavy | M1c | **0.998** | 1.000 | 0.0% | 0.0% | 370 |
| Wind-heavy | M2 | 0.404 | 0.056 | 31.6% | 61.6% | 370 |
| Wind-heavy | M3 | 0.790 | 0.547 | 0.8% | 5.1% | 370 |

*A shortage event is a maximal contiguous block of hours with pre-storage shortfall > 0.
SOC measured at end-of-hour immediately before the first hour of each event.*

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

### 4. What does M1c's low per-shortage-hour SOC mean?

**An unexpected finding in the per-hour diagnostic: M1c enters shortage hours with the
LOWEST average SOC** (mean 18.6% balanced, 33.5% wind-heavy vs 73–75% for pure
market-pattern).

The explanation is **sequential event depletion**: during multi-hour shortage events,
M1c discharges aggressively at each shortage hour. By the end of an event the battery is
depleted. The per-hour mean averages across all hours in all events, including the later
hours of long events where the battery is already nearly empty. This is correct behaviour —
M1c is doing its job — but the metric is misleading without this context.

**The event-start SOC diagnostic resolves the apparent paradox.**

### 5. Event-start SOC: entering shortage events with energy

**Event-start SOC** — measured at the end of the hour immediately before the first
shortage hour of each event — removes intra-event depletion from the diagnostic. The
results (script `69_event_start_soc.jl`) show a sharply different picture:

| Method | Balanced VRE | Wind-heavy |
|---|---|---|
| M1c | **0.999** | **0.998** |
| MP variants | 0.81–0.85 | 0.81–0.84 |
| M3 | 0.828 | 0.790 |
| M2 | 0.325 | 0.404 |

**M1c enters every shortage event at 99.9% SOC.** Charging from all available surplus
guarantees near-maximum pre-event positioning. Zero events start below 50% SOC.

**Market-pattern variants enter at 81–85%.** Market activity (charging on the duck-curve
schedule, discharging on the evening-ramp schedule regardless of grid state) costs 15–19
percentage points of pre-event SOC compared with M1c. However, zero events start below
50% SOC and virtually none below 25%. This is important: the 15–19 pp pre-event SOC gap
is much too small to explain the 8.6–12× LOLH gap between MP pure and M1c. It confirms
that **dispatch pattern is the dominant driver**, not pre-event depletion.

**M3 (full-year LP) enters at 79–83%**, similar to market-pattern variants but with
perfect foresight. Near-zero events start below 25%. M3 achieves the best reliability
metrics in part by optimally timing discharge within events; pre-event SOC is comparable
to the market-pattern variants.

**M2 (event-window LP) enters at only 32–40% SOC**, with 32–51% of events starting
below 25%. Yet M2 achieves the lowest LOLH of any sequential MCS method. This seems
paradoxical but is explained by how M2 uses its available energy: the LP solves over the
full event window and allocates discharge optimally across event hours. M2 can recover
from a low-SOC event start by timing its discharge to the highest-impact hours within
the event. M1c, by contrast, discharges greedily from the first shortage hour, which is
efficient but not necessarily optimal if the event contains variation in shortfall magnitude.

The M2 result also reveals that M2 depletes storage proactively in non-shortage hours
within its event window, accepting lower event-start SOC in exchange for more efficient
dispatch during the event. The fact that M2 achieves lower or equal LOLH and identical
EUE to M1c (same 2479 MWh / 648 MWh across both cases) confirms that this trade-off is
efficient: the same total unserved energy is covered in fewer shortage hours.

**Key interpretation for the paper:**
The per-shortage-hour SOC is a misleading diagnostic because it reflects intra-event
depletion as well as pre-event positioning. Event-start SOC is the correct diagnostic for
the question "did the battery enter shortage events with enough energy?" With this metric:
- M1c is maximally conservative (99% entry SOC) — appropriate for an upper-bound reliability estimate
- MP variants show a moderate SOC gap vs M1c (15–19 pp) — not the primary failure mode
- The primary failure mode for MP pure is dispatch pattern: 93–97% of EUE is from missed discharge despite high entry SOC
- For MP + emergency, the failure is low SOC at shortage hours *within* events (intra-event depletion from market-pattern non-event discharge)

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
3. This is an argument for why the emergency-only and event-window methods (M1c, M2) —
   which reserve both energy *and* dispatch capacity for shortage hours — are appropriate
   upper-bound reliability estimates.

**Important caveat:** CAISO batteries do respond to shortage conditions in real grid operations
via ancillary services, emergency dispatch procedures, and price signals. The pure market
pattern is a lower bound on realistic behavior. The emergency override is closer to reality
but likely still conservative. The true behavior lies between them. The paper's emergency-only
and event-window methods can be framed as "upper bounds on reliability value" in the sense
that they assume full dispatch cooperation during shortfalls.

### 7. Which variant is most defensible for paper use?

**MP_emergency_curtailed (Variant 4)** is the most physically defensible:
- Emergency override in shortage hours (batteries do respond to scarcity signals)
- Charging strictly limited to surplus (no artificial load shedding)
- All residual EUE vs M1c is from genuine pre-shortage SOC depletion from market activity

**MP_pure_curtailed (Variant 2)** is the most conservative lower bound:
- No emergency response even during observed shortfalls
- Charging limited to surplus
- 97% of EUE from genuine missed dispatch in shortage hours

### 8. Is the method stable enough for an appendix sensitivity?

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
| `scripts/69_event_start_soc.jl` | Event-start SOC runner (all 4 MP + M1c/M2/M3) |
| `data_processed/caiso_storage_patterns/caiso_storage_hourly.csv` | 8758-row hourly CISO 2023 dataset |
| `data_processed/caiso_storage_patterns/season_hour_pattern.csv` | 96-row season×hour pattern |
| `results/paper_tables/market_pattern_storage_results.csv` | Full results table (4 MP variants + benchmarks) |
| `results/paper_tables/market_pattern_eue_decomposition.csv` | EUE decomposition for MP variants |
| `results/paper_tables/market_pattern_event_start_soc.csv` | Event-start SOC (all 7 methods × 2 cases) |
| `results/market_pattern_storage/soc_diagnostics.csv` | Per-shortage-hour SOC (all 6 methods) |
| `docs/caiso_storage_data_source_check.md` | Data source investigation report |
