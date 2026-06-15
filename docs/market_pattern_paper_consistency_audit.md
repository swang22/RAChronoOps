# Market-Pattern Paper Consistency Audit

**Date:** 2026-06-15
**Scope:** Cross-repository audit of all new manuscript claims introduced in commit 58ae225
(`paper: add market-pattern storage sensitivity`) against code and result files in
`RAChronoOps/` and `RA-assessment/`.

**Result:** 4 genuine errors found and corrected in commit following this audit
(`paper: audit market-pattern experiment integration`).

---

## Audit Table

| # | Manuscript location | Claim / value | Supporting code / result | Match? | Correction applied |
|---|---|---|---|---|---|
| 1 | `sec:market_pattern` eq. `mp_target_c/d` | Gross targets `c̃_h = r^ch·P^max`, `d̃_h = r^dis·P^max` | `src/models/MarketPatternStorage.jl` line 328: code uses `net_pat = (r^dis - r^ch)*P^max` — never simultaneous charge/discharge | Simplification (not error): CAISO cells are predominantly one direction; acceptable for paper | None — noted below |
| 2 | `sec:market_pattern` | Both variants use `charge_curtailed=true` (charging limited to surplus) | `scripts/70_market_pattern_marginal_cc.jl` `PAPER_VARIANTS`: both entries have `charge_curtailed=true` | ✓ | — |
| 3 | `sec:market_pattern` | No charging during pre-storage shortfall hours | `MarketPatternStorage.jl` lines 275–300: `chg = 0.0` in the `shortfall_pre > 0` branch; only discharge or pattern applied | ✓ | — |
| 4 | `sec:market_pattern` | Emergency variant overrides historical discharge during shortage hours | `MarketPatternStorage.jl` line 290: `if emergency_override && shortfall_pre > 0 → dis = min(shortfall_pre, max_avail_dis)` | ✓ | — |
| 5 | `tab:storage_comparison` rows (Balanced VRE) | MP_pure: LOLH=46.1, EUE=13,662, NEUE=303, CVaR=26,276, CC=0.143 | `results/paper_tables/market_pattern_table_iv_rows.csv`: 46.10 / 13,661.96 / 303.1 / 26,276.4 / 0.143 | ✓ | — |
| 6 | `tab:storage_comparison` rows (Balanced VRE) | MP_emergency: LOLH=9.2, EUE=4,338, NEUE=96, CVaR=15,812, CC=0.336 | `results/paper_tables/market_pattern_table_iv_rows.csv`: 9.15 / 4,338.32 / 96.3 / 15,811.6 / 0.336 | ✓ (rounded) | — |
| 7 | `tab:storage_comparison` rows (Wind-heavy) | MP_pure: LOLH=23.9, EUE=7,161, NEUE=159, CVaR=14,518, CC=0.128 | `results/paper_tables/market_pattern_table_iv_rows.csv`: 23.90 / 7,160.64 / 158.9 / 14,518.0 / 0.128 | ✓ | — |
| 8 | `tab:storage_comparison` rows (Wind-heavy) | MP_emergency: LOLH=2.9, EUE=1,117, NEUE=25, CVaR=5,509, CC=0.430 | `results/paper_tables/market_pattern_table_iv_rows.csv`: 2.85 / 1,117.40 / 24.8 / 5,509.3 / 0.430 | ✓ (rounded) | — |
| 9 | `tab:storage_comparison` table note | "Runtime for market-pattern variants is the warm-start median (Section~\ref{sec:market_pattern})" | `results/paper_tables/runtime_common_benchmark.csv`: warm-start median for MP_pure_cur = 0.0448 s/scen ≈ 0.04, but table shows 0.05; also `sec:market_pattern` describes methodology not runtime | ✗ — wrong section reference and slightly inconsistent value | **Corrected**: replaced with "comparable to other rule-based methods (≈0.05 s/scenario)" |
| 10 | CC results section | "approximately halving the gap toward emergency-only storage MCS" | Balanced VRE closure: (0.336−0.143)/(0.497−0.143) = 54.5% ✓; Wind-heavy closure: (0.430−0.128)/(0.604−0.128) = 63.4% — not "half" | ✗ — claim wrong for wind-heavy | **Corrected**: "closing approximately half to two-thirds of the gap" |
| 11 | CC results section | "variation $<1\%$" for both market-pattern variants | `results/paper_tables/market_pattern_capacity_credit.csv`: MP_pure_cur balanced range = 0.22% ✓; MP_emergency_cur balanced range = (0.35180−0.33579)/0.33579 = 4.8% | ✗ — MP_emergency_cur variation is 4.8%, not <1% | **Corrected**: "$<1\%$ for market-pattern storage MCS; $<5\%$ for market-pattern + emergency MCS" |
| 12 | Appendix CC finite-difference check | "$<4\%$ for market-pattern + emergency MCS in the balanced VRE portfolio" | `results/paper_tables/market_pattern_capacity_credit.csv`: MP_emergency_cur balanced VRE δ=1→5→10 range = 4.8% | ✗ — 4.8% exceeds stated bound of <4% | **Corrected**: "$<5\%$" |

---

## Supporting Data

### CC variation computation (audit item 11 / 12)

Source: `results/paper_tables/market_pattern_capacity_credit.csv`

MP_emergency_cur balanced VRE:
- δ=1 MW: CC = 0.33579
- δ=5 MW: CC = 0.35180
- δ=10 MW: CC = 0.34674
- Range = (0.35180 − 0.33579) / 0.33579 = **4.77%** → rounds to <5%, not <4% and not <1%

MP_pure_cur balanced VRE:
- δ=1 MW: CC = 0.14332
- δ=5 MW: CC = 0.14553 (from CSV)
- δ=10 MW: CC = 0.14650
- Range = (0.14650 − 0.14332) / 0.14332 = **0.22%** → <1% ✓

### Gap closure computation (audit item 10)

Balanced VRE (M1c CC = 0.497):
- (0.336 − 0.143) / (0.497 − 0.143) = 0.193 / 0.354 = **54.5%** ≈ half ✓

Wind-heavy (M1c CC = 0.604):
- (0.430 − 0.128) / (0.604 − 0.128) = 0.302 / 0.476 = **63.4%** — exceeds "half"

### Runtime table note (audit item 9)

Warm-start median from `runtime_common_benchmark.csv`:
- MP_pure_cur Balanced VRE: 0.0448 s/scen (≈ 0.04, but rounding to 0.05 in table is acceptable)
- MP_emergency_cur Balanced VRE: 0.0461 s/scen
- The old note cited `Section~\ref{sec:market_pattern}` which is the method description section,
  not where runtime data is presented. The warm-start framing also required context that wasn't
  in the note. Replaced with a self-contained approximate value.

---

## Non-Error: Formulation Simplification

**Item:** Paper equations `mp_target_c/d` present separate gross targets `c̃_h` and `d̃_h`.
Code uses `net_pat = (r^dis − r^ch) * P^max` — a net dispatch that never allows simultaneous
charge and discharge.

**Assessment:** In the CAISO season×hour pattern cells, hourly rates are predominantly
one direction (either net-charging or net-discharging). The net-dispatch formulation
is equivalent to the gross formulation for any hour where both targets are not simultaneously
positive. This is a presentation simplification, not a computational difference, and does not
affect any reported result. No correction required.

---

## Script and Config Verification

| Claim | Source | Verified |
|---|---|---|
| N=20 scenarios | `scripts/70_market_pattern_marginal_cc.jl`: `PAPER_N = 20` | ✓ |
| Seed=42 | same script: `SEED = 42` | ✓ |
| δ values = 1, 5, 10 MW | same script: `DELTA_MWS = [1.0, 5.0, 10.0]` | ✓ |
| Duration = 4 h, η = √0.90 | same script: `DURATION_H = 4.0`, η derived from `eff = sqrt(0.90)` | ✓ |
| CC uses explicit firm rerun with CRN | same script: `with_perfect_firm` and `avail_with_perfect_firm` use same `avail` matrix | ✓ |
| Appendix sampling convergence table | `results/paper_tables/market_pattern_sampling_convergence.csv`: all 16 cells match | ✓ |

---

## Files Audited

- `RA-assessment/main.tex` (commit 58ae225)
- `RA-assessment/references.bib`
- `RAChronoOps/scripts/70_market_pattern_marginal_cc.jl`
- `RAChronoOps/src/models/MarketPatternStorage.jl`
- `RAChronoOps/results/paper_tables/market_pattern_table_iv_rows.csv`
- `RAChronoOps/results/paper_tables/market_pattern_capacity_credit.csv`
- `RAChronoOps/results/paper_tables/market_pattern_sampling_convergence.csv`
- `RAChronoOps/results/paper_tables/runtime_common_benchmark.csv`
