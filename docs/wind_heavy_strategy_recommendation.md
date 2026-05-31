# Wind-Heavy VRE: N=5 vs N=20 Inconsistency — Strategy Recommendation

**Date:** 2026-05-31  
**Status:** RECOMMENDED — Strategy 3 (run N=20 HOPE-UC)

---

## Problem Statement

The wind-heavy VRE portfolio results currently mix scenario counts:

| Method     | N in paper | EUE (MWh) | NEUE (ppm) |
|------------|-----------|-----------|-----------|
| M1c        | 20        | 648.24    | 14.38     |
| M2         | 20        | 648.24    | 14.38     |
| M3         | 20        | 648.24    | 14.38     |
| HOPE-ED    | 5         | 1113.18   | 24.70     |
| HOPE-UC    | 5         | 1113.18   | 24.70     |

The **42% EUE gap** (648 vs 1113 MWh) is not a model difference — it is pure sampling variability
from N=5 vs N=20 with the same seed. The first 5 scenarios (seed=42) happen to include
high-outage draws that push the N=5 mean up. Scenarios 6–20 are less extreme, pulling
the N=20 mean down significantly.

This gap is too large to report in a single table block without explicit, prominent labeling.

---

## Three Options Considered

### Strategy 1: Keep wind-heavy at N=5 throughout with explicit labels
- Relabel all wind-heavy rows "N=5" in Table II and text
- State that wind-heavy is a pilot case with smaller sample
- **Pros:** No new compute; honest about what was run
- **Cons:** N=5 gives 42% higher NEUE (24.7 vs 14.4 ppm); confidence intervals are very wide
  (EUE CI95 ±89% for M1c at N=5 vs ±37% at N=20 from m1c_comparison); wind-heavy at N=5
  is not directly comparable with balanced-VRE at N=20 in the same table
- **Verdict:** Acceptable as a fallback but scientifically weaker; requires heavy caveating

### Strategy 2: Rerun all MCS methods at N=20 wind-heavy; footnote HOPE-UC as pending
- Already done: M1/M1b/M1c/M2/M3 at N=20 exist in paper_storage_method_comparison.csv
- HOPE-UC would be footnoted "N=20 run pending; N=5 value shown"
- **Pros:** MCS methods consistent at N=20; immediate
- **Cons:** Still mixes N for the key PCM-UCED comparison; the whole point of the wind-heavy
  section is to validate HOPE-UC against M1c/M3 — mixing N undermines that comparison
- **Verdict:** Does not resolve the core problem

### Strategy 3: Run HOPE-UC at N=20 wind-heavy (RECOMMENDED)
- Export scenarios 6–20 via `scripts/25_build_hope_full_year_cases.jl` (wind-heavy, UC mode)
- Run HOPE on scenarios 6–20 via `scripts/29_run_hope_model.jl`
- Collect results via scripts 27/37 and combine with existing N=5 (s001–s005) data
- Compute N=20 aggregate metrics; rerun CC if needed (script 61 with N=20 wind-heavy)
- **Time estimate:** export ~15 min + HOPE-UC 542s/scen × 15 scen = 135 min ≈ 2.5 h total
- **Pros:**
  - All wind-heavy results at N=20; fully consistent with balanced-VRE section
  - Eliminates the 42% EUE gap in Table II
  - Only s001–s005 already exist; s006–s020 are a straightforward incremental run
  - EUE expected to decrease substantially (toward the N=20 mean); NEUE stabilizes
- **Cons:** Requires ~2.5 h of compute; cannot run during the current writing session
- **Verdict:** Scientifically cleanest and feasible in one background compute session

---

## Recommendation: Strategy 3

**Immediate actions:**
1. Export scenarios 6–20 for wind-heavy UC:
   ```
   julia --project=. scripts/25_build_hope_full_year_cases.jl \
       --case VRE120_wind_hvy --n-scenarios 20 --seed 42 \
       --scenario-subset 6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 \
       --modes UC
   ```
2. Run HOPE on the new folders:
   ```
   julia --project=. scripts/29_run_hope_model.jl \
       --case VRE120_wind_hvy --scenario-subset 6,...,20 --mode UC
   ```
3. Collect with scripts 27/37; compute N=20 aggregate metrics
4. Optionally rerun CC for HOPE-UC N=20 (script 63 or script 61 extension)
5. Update paper_hope_validation.csv and main_method_comparison_with_runtime_cc.csv

**If the N=20 HOPE-UC run is blocked** (time, access):
- Fall back to Strategy 1: present wind-heavy as a separate N=5 pilot scenario
- Add footnote to Table II: "Wind-heavy results use N=5 scenarios; M1c/M3 at N=20 shown separately"
- Do NOT silently mix N=5 HOPE-UC with N=20 MCS in the same row block

---

## Key Numbers for Context

From `wind_heavy_n5_n20_comparison.csv`:
- M1c EUE: 1113 MWh (N=5) → 648 MWh (N=20); rel diff = −41.8%
- M1c NEUE: 24.70 ppm (N=5) → 14.38 ppm (N=20); rel diff = −41.8%
- M1c CVaR: 2793 MWh (N=5) → 3528 MWh (N=20); rel diff = +26.3% (N=20 tail is worse)
- All methods (M1c/M2/M3) give identical EUE at each N (CRN property)

Expected HOPE-UC EUE at N=20 (rough estimate): 
- If HOPE-UC tracks M1c/M3 (as it does at N=5), expect EUE ≈ 648 MWh, NEUE ≈ 14.4 ppm
- This would make Table II consistent: all wind-heavy methods at N=20 with NEUE ≈ 14 ppm
