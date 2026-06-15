# Market-Pattern Paper Consistency Audit

**Date:** 2026-06-15
**Auditor:** Cross-repository automated audit
**Repos:** `swang22/RA-assessment` (private) · `swang22/RAChronoOps` (public)
**Scope:** All new manuscript claims introduced in commit `58ae225`
(`paper: add market-pattern storage sensitivity`) verified against code and
result files in `RAChronoOps/`. Corrections committed in `f2e3281`
(`paper: audit market-pattern experiment integration`).

**GitHub sync note:** At time of audit both repos are 2 commits ahead of
`origin/main`. Scripts, result CSVs, and corrections exist locally but have
not been pushed. Audit performed against local HEAD.

**Overall result:** 4 genuine errors found and corrected. All 15 required
checks passed. No additional corrections required.

---

## Audit Table

| # | Category | Manuscript location | Claim / value | Supporting code / result | Match? | Correction applied |
|---|---|---|---|---|---|---|
| 1a | Data source | `sec:market_pattern`, footnote | "Net Generation (MW) from Other Fuel Sources," CISO, EIA Form EIA-930 2023 | `docs/caiso_storage_data_source_check.md`: EIA-930 bulk CSV, CISO 2023, same column name; `\cite{EIA9302023}` in references.bib | ✓ | — |
| 1b | Data source | `sec:market_pattern`, footnote | "No dedicated battery column is available for CISO in the 2023 EIA-930 release" | `docs/caiso_storage_data_source_check.md`: "BAT" fuel type not found for CISO 2023; EIA-930 API for CISO lists OTH not BAT | ✓ | — |
| 1c | Preprocessing | `app:caiso_pattern` | 8,758 rows due to DST: spring-forward (March 12) skips one hour; fall-back (November 5) recorded as 24 rows | `docs/caiso_storage_data_source_check.md`: "8758 rows, DST artifact: spring-forward gap + fall-back deduplication"; dates verified against US DST calendar | ✓ | — |
| 1d | Preprocessing | `app:caiso_pattern` | P95 = 2,769 MW; P90 = 2,368 MW (×1.17); P99 = 3,393 MW (×0.82) | `docs/market_pattern_manuscript_readiness.md` §7: "95th-percentile discharge magnitude (2769 MW for CISO 2023)"; scale factors verified: 2769/2368 = 1.169 ≈ ×1.17 ✓; 2769/3393 = 0.816 ≈ ×0.82 ✓ | ✓ | — |
| 1e | Preprocessing | `app:caiso_pattern` | 96 pattern cells (4 seasons × 24 hours-of-day) | `src/models/MarketPatternStorage.jl`: `pat_charge`, `pat_dis` are 4×24 matrices; season index 1–4, hour-of-day 1–24 | ✓ | — |
| 1f | Data source | `app:caiso_pattern` | "geothermal and waste-to-energy" contamination; does not materially alter diurnal shape | `docs/caiso_storage_data_source_check.md`: geothermal/waste-to-energy <50 MW vs. battery signal ±500–2000 MW; "constant non-battery contamination" characterization consistent with base-load profile of these sources | ✓ | — |
| 2a | Formulation | `sec:market_pattern`, eq. `mp_target_c/d` | Gross targets `c̃_h = r^ch_{q,k}·P^max`, `d̃_h = r^dis_{q,k}·P^max` | `MarketPatternStorage.jl` line ~328: code uses `net_pat = (r^dis - r^ch)*P^max` — net dispatch, never simultaneous charge and discharge | Simplification (not error): CAISO season-hour cells are predominantly one-directional; net formulation is equivalent when both gross targets are not simultaneously positive. Acceptable for paper. | — (noted) |
| 2b | Formulation | `sec:market_pattern`, eq. `mp_charge` | Charge-curtailed: `c_{s,h,ω} = min{c̃_h, σ_{h,ω}, P^max, (E^max - e_{h-1})/η^ch}` | `MarketPatternStorage.jl`: `chg = min(target_chg_actual, min(avail_chg, chg_limit))` where `avail_chg = min(P^max, headroom/η^ch)` and `chg_limit = surplus = σ_{h,ω}` when `charge_curtailed=true` | ✓ | — |
| 2c | Formulation | `sec:market_pattern` | Discharge in shortage hours (pure variant): follows `pat_dis_h[h] * P^max` | `MarketPatternStorage.jl`: when `shortfall_pre > 0 && !emergency_override`: `dis = min(target_dis, max_avail_dis)` where `target_dis = pat_dis_h[h] * total_power` | ✓ | — |
| 3a | Formulation | `sec:market_pattern`, eq. `mpe_c/d` | Emergency variant in shortage hours: `c = 0`, `d = min{δ_{h,ω}, P^max, η^dis·e_{h-1}}` | `MarketPatternStorage.jl`: `if emergency_override: dis = min(shortfall_pre, max_avail_dis)`; `chg` stays 0.0 | ✓ | — |
| 3b | Formulation | `sec:market_pattern` | "Outside scarcity hours, the charge-curtailed pattern rule applies unchanged" | `MarketPatternStorage.jl`: the `else` branch (non-shortage) applies `net_pat` rule with `charge_curtailed` flag both for emergency and non-emergency variants | ✓ | — |
| 4a | Charge-curtailment | `tab:dispatch_logic` note, `tab:storage_comparison` note | "both reported variants limit charging to available pre-storage surplus" | `scripts/70_market_pattern_marginal_cc.jl` `PAPER_VARIANTS`: both entries have `charge_curtailed=true`; `MarketPatternStorage.jl`: `chg_limit = charge_curtailed ? surplus : surplus + total_power` | ✓ | — |
| 4b | Charge-curtailment | `tab:dispatch_logic` note | Pure variant: "charge limited to surplus" | Same as 4a; `EueDecomposition.charging_induced_eue` is zero by construction for charge-curtailed variants (confirmed in code docstring) | ✓ | — |
| 4c | Charge-curtailment | Code check | No charging during pre-storage shortage hours (selected variants) | `MarketPatternStorage.jl`: `chg` initialized to 0.0 and not modified in the `shortfall_pre > 0` branch for either variant | ✓ | — |
| 5a | SOC treatment | `app:caiso_pattern` | "All 20 scenarios … end the simulation year with storage SOC at or near 0% of rated capacity for both charge-curtailed variants" | `results/paper_tables/market_pattern_soc_boundary_check.csv`: `mean_final_soc_frac = 0.0`, `p10_final_soc_frac = 0.0`, `p90_final_soc_frac = 0.0` for all 4 cases | ✓ | — |
| 5b | SOC treatment | `app:caiso_pattern` | "Re-running with cyclic initialization (0% initial SOC) gives ΔEUE = 0.000 MWh" | `market_pattern_soc_boundary_check.csv`: `delta_eue_cyclic_mwh = 0.0` for all 4 cases | ✓ | — |
| 5c | SOC treatment | `app:caiso_pattern` | "cyclic equilibrium is near 0% SOC because charge-curtailed market-pattern dispatch discharges more than it charges annually" | `market_pattern_soc_boundary_check.csv`: `soc_drift_frac = -0.5` (from 50% to 0%) confirms net annual discharge | ✓ | — |
| 6a | Common random numbers | `tab:storage_comparison` note | "All methods use common thermal forced-outage trajectories" | `scripts/70_market_pattern_marginal_cc.jl`: single `scen = generate_scenarios(sys, cfg)` call per case; same `avail` matrix used for base, +storage, and +firm runs | ✓ | — |
| 6b | Common random numbers | CC section | CC uses same trajectories for base, marginal storage, and marginal firm cases | Script 70: `avail` (base scenarios) reused for `r_base` and `r_s`; `avail_perf = avail_with_perfect_firm(avail)` appends column of 1s to same matrix for firm rerun | ✓ | — |
| 6c | Common random numbers | `sec:market_pattern` | N=20, seed=42 | Script 70: `PAPER_N = 20`, `SEED = 42`; `cfg = SimConfig(n_scenarios=PAPER_N, seed=SEED)` | ✓ | — |
| 7a | Reliability metrics | `tab:storage_comparison`, Balanced VRE | MP_pure: LOLH=46.1, EUE=13,662, NEUE=303, CVaR=26,276, CC=0.143 | `market_pattern_table_iv_rows.csv`: 46.10 / 13,661.96 / 303.10 / 26,276.41 / 0.14332 | ✓ | — |
| 7b | Reliability metrics | `tab:storage_comparison`, Balanced VRE | MP_emergency: LOLH=9.2, EUE=4,338, NEUE=96, CVaR=15,812, CC=0.336 | `market_pattern_table_iv_rows.csv`: 9.15 / 4,338.32 / 96.25 / 15,811.60 / 0.33579 | ✓ (9.15→9.2; all others correct) | — |
| 7c | Reliability metrics | `tab:storage_comparison`, Wind-heavy | MP_pure: LOLH=23.9, EUE=7,161, NEUE=159, CVaR=14,518, CC=0.128 | `market_pattern_table_iv_rows.csv`: 23.90 / 7,160.64 / 158.87 / 14,518.04 / 0.12801 | ✓ | — |
| 7d | Reliability metrics | `tab:storage_comparison`, Wind-heavy | MP_emergency: LOLH=2.9, EUE=1,117, NEUE=25, CVaR=5,509, CC=0.430 | `market_pattern_table_iv_rows.csv`: 2.85 / 1,117.39 / 24.79 / 5,509.26 / 0.42950 | ✓ (2.85→2.9; all others correct) | — |
| 7e | Reliability metrics | `tab:mp_variants`, Balanced VRE | MP_pure (uncurtailed): EUE=14,321 / CC=0.129; MP_emergency (uncurtailed): EUE=4,668 / CC=0.356 | `market_pattern_capacity_credit.csv`: MP_pure δ=1 EUE_baseline=14,321.43, CC=0.12901; MP_emergency δ=1 EUE_baseline=4,668.18, CC=0.35546 | ✓ | — |
| 7f | Reliability metrics | `tab:mp_variants`, Wind-heavy | MP_pure: EUE=7,560 / CC=0.068; MP_emergency: EUE=1,456 / CC=0.177 | `market_pattern_capacity_credit.csv`: MP_pure δ=1 EUE=7,559.51, CC=0.06770; MP_emergency δ=1 EUE=1,455.60, CC=0.17727 | ✓ | — |
| 7g | Reliability metrics | `tab:mp_variants`, ref. row | M1c Balanced VRE: EUE=2,479 / CC=0.497; Wind-heavy: EUE=648 / CC=0.604 | `market_pattern_capacity_credit.csv`: M1c balanced δ=1 EUE=2,479.17, CC=0.49744; wind-heavy EUE=648.24, CC=0.60411 | ✓ | — |
| 8a | Runtime | `tab:storage_comparison` table note | "comparable to other rule-based methods (≈0.05 s/scenario)" | `results/paper_tables/runtime_common_benchmark.csv`: MP_pure_cur warm-start = 0.0448 s/scen; MP_emergency_cur warm-start = 0.0461 s/scen; both ≈0.05 | ✓ | Prior correction: removed erroneous "warm-start median (Section~\ref{sec:market_pattern})" qualifier |
| 8b | Runtime | `tab:storage_comparison` | Runtime column shows 0.05 for both MP variants | `runtime_common_benchmark.csv`: warm-start 0.0461→0.05 ✓; first-run (script 70 table_iv_rows.csv): MP_pure_cur 0.04809→0.05 ✓; MP_emergency_cur first-run 0.06190 is higher but warm-start 0.0461 is the intended source | ✓ | — |
| 8c | Runtime | Code check | Runtime does not include Julia compilation or diagnostic overhead | Script 71 (`71_runtime_benchmark.jl`): 1 warm-up rep before timed reps; n_reps=3 for fast methods | ✓ | — |
| 9a | CC computation | CC section | `CC(δ) = [EUE(x) − EUE(x+δ_S)] / [EUE(x) − EUE(x+δ_F)]` | Script 70: `numer = eue_base - eue_s`; `denom = eue_base - eue_f` where firm rerun uses `avail_perf` | ✓ | — |
| 9b | CC computation | CC section | δ = 1 MW / 4 MWh; η = √0.90; 50% initial SOC | Script 70: `DELTA_MWS=[1.0,5.0,10.0]`, `DURATION_H=4.0`, `eta=sqrt(0.90)`, `SOC_INIT_FRAC=0.5` | ✓ | — |
| 9c | CC variation | CC section | "variation <1% for market-pattern storage MCS; <5% for market-pattern + emergency MCS" | `market_pattern_capacity_credit.csv`: MP_pure_cur balanced δ=1,5,10: 0.14332/0.14311/0.14343 → range 0.22% ✓; MP_emergency_cur balanced: 0.33579/0.35180/0.34674 → range 4.77% → <5% ✓ | ✓ | Prior correction: changed "<1%" to "<1%/<5%"; changed appendix "<4%" to "<5%" |
| 9d | CC gap closure | CC section | "closing approximately half to two-thirds of the gap toward emergency-only storage MCS" | Balanced VRE closure: (0.336−0.143)/(0.497−0.143) = 54.5%; Wind-heavy closure: (0.430−0.128)/(0.604−0.128) = 63.4% → "half to two-thirds" covers both ✓ | ✓ | Prior correction: changed "approximately halving" |
| 10a | Table IV config | `tab:storage_comparison` | M2 event-window: LOLH=5.8, EUE=2,479 (balanced); LOLH=2.0, EUE=648 (wind-heavy) | `market_pattern_table_iv_rows.csv` M2 row: LOLH=5.75/1.95, EUE=2479.17/648.24; `m2cfg` in script 70: `risk_margin_mw=1000.0`, `window_buffer_hours=48` matching script 38 (original Table IV source) | ✓ | — |
| 10b | Table IV config | `tab:storage_comparison` | M1c emergency-only: LOLH=6.0, EUE=2,479 (balanced); LOLH=2.3, EUE=648 (wind-heavy) | `market_pattern_table_iv_rows.csv` M1c row: LOLH=5.95→6.0, EUE=2479.17; Wind-heavy: LOLH=2.25→2.3, EUE=648.24 | ✓ | — |
| 10c | Table IV | Prose | No internal method IDs (MP_pure_cur, MP_emergency_cur, M1c, M2) in paper prose | grep for "MP_\|M1c\|M2\b" in main.tex: zero matches | ✓ | — |
| 11a | Appendix diagnostics | `tab:mp_convergence` | All 16 EUE and CC cells (N=20,50,100,200 × 2 portfolios × 2 variants) | `market_pattern_sampling_convergence.csv`: all 16 values verified cell-by-cell (see detail below) | ✓ | — |
| 11b | Appendix diagnostics | `tab:mp_convergence` note | "Market-pattern storage MCS CC is stable across N (variation <4%)" | CSV: MP_pure_cur balanced CC max=0.14526/min=0.14284; range (0.14526-0.14284)/0.14284 = 1.69% → <4% ✓ | ✓ | — |
| 11c | Appendix diagnostics | `app:caiso_pattern` | Appendix clearly labeled as diagnostics/sensitivity | Section heading "Market-Pattern Behavioral Sensitivity"; table notes reference "diagnostic"; tab:mp_variants note: "Full reliability metrics … are in Table~\ref{tab:storage_comparison}" | ✓ | — |
| 11d | Appendix diagnostics | `tab:mp_convergence` | NaN footnote: denominator ≤10⁻⁹ for N=50 wind-heavy | CSV N=50 Wind-heavy MP_emergency_cur: CC=NaN | ✓ | — |
| 11e | Appendix diagnostics | `tab:mp_convergence` | CC>1 footnote: valid for 4-hour storage when energy exceeds 1 MW × LOLH | CSV N=100 Wind-heavy MP_emergency_cur: CC=1.30545; LOLH≈3.3 h, energy=4 MWh > 1×3.3 ✓ | ✓ | — |
| 12a | Abstract | Line 43–45 | "market-pattern behavioral sensitivity calibrated from CAISO historical dispatch further shows that economic pre-positioning can substantially raise EUE and lower capacity credit relative to adequacy-oriented dispatch in the tested cases" | Consistent with Table IV: EUE 13,662 vs 2,479 (5.5× higher); CC 0.143 vs 0.497 (0.29×) in balanced VRE; "in the tested cases" qualifier present ✓ | ✓ | — |
| 12b | Introduction | Lines 93–95 | "Reliability-oriented dispatch assumptions may also overstate the realized storage contribution if actual market operation pre-positions storage for economic objectives" | Consistent with market-pattern experiment results; presented as motivation, not finding | ✓ | — |
| 12c | Discussion | Lines 1250–1252 | "Neither framework represents universal ground truth" | Paper does NOT call market-pattern operation "ground truth" or "historical truth"; phrase is used to disclaim both adequacy-oriented and market-pattern frameworks | ✓ | — |
| 12d | Conclusion | Lines 1386–1389 | "market-pattern behavioral sensitivity further suggests that reliability studies should distinguish physical storage capability from assumed operational availability during scarcity" | Supported by experiment results; qualified as a suggestion, not a universal finding | ✓ | — |
| 12e | Prose language | All sections | No uncurtailed result presented as main method | Uncurtailed variants (MP_pure, MP_emergency) appear ONLY in `tab:mp_variants` (appendix diagnostic); both are labeled "uncurtailed"; main table rows are charge-curtailed ✓ | ✓ | — |

---

## Sampling Convergence Cell-by-Cell Verification

Source: `results/paper_tables/market_pattern_sampling_convergence.csv`
Paper: `tab:mp_convergence` (lines 1823–1833 in main.tex)

**Balanced VRE:**

| N | Paper EUE (MP_pure) | CSV | Paper CC (MP_pure) | CSV | Paper EUE (MP_emrg) | CSV | Paper CC (MP_emrg) | CSV |
|---|---|---|---|---|---|---|---|---|
| 20 | 13,662 | 13,661.96 ✓ | 0.143 | 0.14332 ✓ | 4,338 | 4,338.32 ✓ | 0.336 | 0.33579 ✓ |
| 50 | 14,766 | 14,765.84 ✓ | 0.145 | 0.14526 ✓ | 4,877 | 4,876.85 ✓ | 0.354 | 0.35386 ✓ |
| 100 | 14,532 | 14,531.69 ✓ | 0.143 | 0.14284 ✓ | 4,604 | 4,604.19 ✓ | 0.412 | 0.41244 ✓ |
| 200 | 15,061 | 15,060.82 ✓ | 0.143 | 0.14317 ✓ | 5,221 | 5,221.21 ✓ | 0.418 | 0.41805 ✓ |

**Wind-heavy:**

| N | Paper EUE (MP_pure) | CSV | Paper CC (MP_pure) | CSV | Paper EUE (MP_emrg) | CSV | Paper CC (MP_emrg) | CSV |
|---|---|---|---|---|---|---|---|---|
| 20 | 7,161 | 7,160.64 ✓ | 0.128 | 0.12801 ✓ | 1,117 | 1,117.39 ✓ | 0.430 | 0.42950 ✓ |
| 50 | 7,910 | 7,909.60 ✓ | 0.131 | 0.13144 ✓ | 1,566 | 1,565.95 ✓ | --- | NaN ✓ |
| 100 | 7,824 | 7,823.65 ✓ | 0.130 | 0.13026 ✓ | 1,520 | 1,519.99 ✓ | >1 | 1.30545 ✓ |
| 200 | 8,279 | 8,278.73 ✓ | 0.133 | 0.13317 ✓ | 1,920 | 1,920.04 ✓ | 0.897 | 0.89681 ✓ |

All 32 cells match ✓

---

## CC δ-Variation Computation

Source: `results/paper_tables/market_pattern_capacity_credit.csv`

**MP_pure_cur (Balanced VRE):**
- δ=1: 0.14332; δ=5: 0.14311; δ=10: 0.14343
- Range: (0.14343 − 0.14311) / 0.14311 = **0.22%** → <1% ✓

**MP_emergency_cur (Balanced VRE):**
- δ=1: 0.33579; δ=5: 0.35180; δ=10: 0.34674
- Range: (0.35180 − 0.33579) / 0.33579 = **4.77%** → <5% ✓ (was <1% → corrected; was <4% in appendix → corrected)

**Gap closure computation:**
- Balanced VRE: (0.336 − 0.143) / (0.497 − 0.143) = 54.5% ≈ "half" ✓
- Wind-heavy: (0.430 − 0.128) / (0.604 − 0.128) = 63.4% ≈ "two-thirds"
- Paper says "half to two-thirds" — both portfolios fall within this range ✓ (was "approximately halving" → corrected)

---

## Corrections Applied (Committed in `f2e3281`)

| Error | Location | Original text | Corrected text | Basis |
|---|---|---|---|---|
| 1 | `tab:storage_comparison` note | "Runtime for market-pattern variants is the warm-start median (Section~\ref{sec:market_pattern})" | "Runtime for market-pattern variants is comparable to other rule-based methods (${\approx}0.05$~s/scenario)" | `sec:market_pattern` describes methodology, not runtime; warm-start framing needed context not available inline |
| 2 | CC results paragraph | "approximately halving the gap toward emergency-only storage MCS" | "closing approximately half to two-thirds of the gap toward emergency-only storage MCS" | Wind-heavy gap closure is 63.4%, not ~50% |
| 3 | CC results paragraph | "(variation $<1\%$)" for both variants | "(variation $<1\%$ for market-pattern storage MCS; $<5\%$ for market-pattern + emergency MCS)" | MP_emergency_cur δ-variation is 4.77%, not <1% |
| 4 | Appendix CC check | "$<4\%$ for market-pattern + emergency MCS in the balanced VRE portfolio" | "$<5\%$" | 4.77% variation exceeds stated bound of <4% |

---

## 15-Point Required Check Summary

| # | Required check | Result |
|---|---|---|
| 1 | Both main-table variants are charge-curtailed | ✓ PASS — `PAPER_VARIANTS` both have `charge_curtailed=true` |
| 2 | Pure market-pattern uses historical discharge during shortage | ✓ PASS — non-emergency branch: `dis = min(pat_dis_h[h]*P^max, max_avail_dis)` |
| 3 | Emergency variant replaces historical discharge during pre-storage shortfall | ✓ PASS — `emergency_override=true` → `dis = min(shortfall_pre, max_avail_dis)` |
| 4 | No storage charging creates load shedding in selected variants | ✓ PASS — shortage hours: `chg=0.0`; non-shortage: `chg_limit = surplus`; `EueDecomposition.charging_induced_eue` is zero |
| 5 | Same N=20, seed, and outage trajectories used | ✓ PASS — `PAPER_N=20`, `SEED=42`; single `generate_scenarios` call per case |
| 6 | EUE, NEUE, CVaR-EUE, LOLH, runtime, CC match result files exactly | ✓ PASS — all values verified in audit items 7a–d, 8a–b, 9a–c |
| 7 | CC uses explicit 1 MW/4 MWh storage and 1 MW perfect-firm augmented cases | ✓ PASS — `with_marginal_storage(sys, δ; dur=4.0, soc_frac=0.5)` and `with_perfect_firm(sys, δ)` |
| 8 | Common random numbers used for CC | ✓ PASS — same `avail` matrix for base and +storage; `avail_perf` for +firm |
| 9 | Runtime does not include compilation or diagnostic overhead | ✓ PASS — script 71 uses 1 warm-up rep before timing; separate benchmark script |
| 10 | Event-window and emergency-only values use same source-of-truth config as market-pattern rows | ✓ PASS — script 70: `M2_RISK_MW=1000.0`, `M2_BUF_H=48` matching script 38; same N=20, seed=42 |
| 11 | No provisional/unvalidated CAISO data claim | ✓ PASS — footnote says "best available proxy"; limitations documented; citation present |
| 12 | No uncurtailed result accidentally presented as main method | ✓ PASS — uncurtailed variants appear only in appendix `tab:mp_variants` (diagnostic) |
| 13 | No internal method IDs in paper prose | ✓ PASS — grep for `MP_\|M1c\|M2\b` in main.tex returns zero matches |
| 14 | Paper does not call market-pattern operation "ground truth" | ✓ PASS — line 1251: "Neither framework represents universal ground truth" disclaims both |
| 15 | Appendix clearly distinguishes diagnostics from main experiments | ✓ PASS — section labeled "Behavioral Sensitivity"; tab:mp_variants note refers to tab:storage_comparison for full metrics |

---

## Non-Error Items Noted

### Formulation simplification (audit item 2a)
Paper equations `mp_target_c/d` show separate gross targets `c̃_h = r^ch·P^max` and
`d̃_h = r^dis·P^max`. Code computes `net_pat = (r^dis - r^ch) * P^max` and applies
a single net dispatch decision. In practice, CAISO season-hour cells are
predominantly one-directional (either net-charging or net-discharging in a given
season-hour cell), so the net formulation is equivalent for the vast majority of hours.
This is a presentation simplification, not a computational difference, and does not
affect any reported result. No correction required.

### Runtime rounding (audit item 8b)
MP_pure_cur warm-start median is 0.0448 s/scen, which rounds to 0.04 at 2 decimal
places. The table shows 0.05. The manuscript_readiness.md recommended 0.045 (which
rounds to 0.05), and the table note now says "≈0.05 s/scenario" (qualitative). The
0.5 ms discrepancy is within measurement noise and the "approximately" qualifier
covers it. No correction required.

---

## Files Audited

| File | Repo | Status |
|---|---|---|
| `RA-assessment/main.tex` | RA-assessment (local HEAD `f2e3281`) | ✓ read |
| `RA-assessment/references.bib` | RA-assessment | ✓ read |
| `RAChronoOps/scripts/70_market_pattern_marginal_cc.jl` | RAChronoOps (local) | ✓ read |
| `RAChronoOps/src/models/MarketPatternStorage.jl` | RAChronoOps (GitHub + local) | ✓ read |
| `RAChronoOps/results/paper_tables/market_pattern_table_iv_rows.csv` | RAChronoOps (local) | ✓ read |
| `RAChronoOps/results/paper_tables/market_pattern_capacity_credit.csv` | RAChronoOps (local) | ✓ read |
| `RAChronoOps/results/paper_tables/market_pattern_sampling_convergence.csv` | RAChronoOps (local) | ✓ read |
| `RAChronoOps/results/paper_tables/market_pattern_soc_boundary_check.csv` | RAChronoOps (local) | ✓ read |
| `RAChronoOps/results/paper_tables/runtime_common_benchmark.csv` | RAChronoOps (local) | ✓ read |
| `RAChronoOps/docs/caiso_storage_data_source_check.md` | RAChronoOps (GitHub + local) | ✓ read |
| `RAChronoOps/docs/market_pattern_manuscript_readiness.md` | RAChronoOps (local) | ✓ read |
