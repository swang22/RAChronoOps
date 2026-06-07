# Method–Code Consistency Audit

**Date:** 2026-06-06 (initial); 2026-06-07 (follow-up pass)
**Manuscript commit before fixes:** `a50998a` (paper: remove code-style method labels)
**Manuscript commit after initial fixes:** `e188a11` (paper: align methods with implementation)
**Manuscript commit after follow-up fixes:** `ee31530` (paper: finalize method-code consistency wording)
**Code base:** `RAChronoOps/` (no code changes required — all inconsistencies were in the manuscript)

---

## Audit Table

| # | Paper section | Manuscript claim (before fix) | Code / result | Consistent? | Source of truth | Action taken | Rerun? |
|---|---|---|---|---|---|---|---|
| 1 | II-A Thermal model | Two-state Markov chain, FOR/MTTR calibration | `generate_scenarios` in Julia: two-state Markov, FOR/MTTR | ✓ | Either | None | No |
| 2 | II-A CRN | All methods share identical outage trajectories | Script 20: same `ScenarioSet` passed to all dispatch variants | ✓ | Either | None | No |
| 3 | II-B Emergency-only dispatch | Discharge only for pre-storage shortfall; charge only from surplus | `_ra1c_segment!`: confirmed | ✓ | Either | None | No |
| 4 | II-C SOC-floor heuristic | Three-priority rule; SOC floor = 0.5 × E^max | `_ra1b_segment!`: confirmed | ✓ | Either | None | No |
| 5 | II-C Outside-window dispatch | SOC-floor heuristic; SOC carried across boundaries | `run_m2_with_diagnostics`: calls `_ra1b_segment!` on non-window hours | ✓ | Either | None | No |
| **6** | **II-C Event-window parameters** | **ρ=500 MW, τ=24 h** | `script 20` default: `"1000:48,800:24"`; `model_hierarchy` table: `rm=1000, buf=48` | **✗ CRITICAL** | Code/results | Fixed: ρ=1000 MW, τ=48 h throughout | No |
| **7** | **II-C LP balance equation** | **P^F_{h,ω} used directly as a generation term** | Code: thermal dispatch variable `p_th[w] ≤ therm_avail[h]` | **Notation gap** | Code (more general) | Fixed: introduced p^F_h variable and bound; added equivalence note | No |
| 8 | II-C Outside-window rule | SOC-floor heuristic outside windows | `_ra1b_segment!` called between windows | ✓ | Either | None | No |
| **9** | **II-E CVaR definition** | **Ω^top = largest ⌈0.05\|Ω\|⌉ scenarios → 1 scenario at N=20** | `_cvar`: `cutoff=ceil(0.95*N)=19`; tail=indices 19:20 → **2 scenarios** | **✗ IMPORTANT** | Code | Fixed: Ω^top defined as scenarios at or above ⌈α\|Ω\|⌉-th order statistic; note "2 scenarios at N=20" | No |
| **10** | **II-B Load notation** | **L_{h,ω} used in capacity-balance and emergency-only equations** | Load is a fixed vector (scenario-independent) | **Notation inconsistency** | Code (deterministic load) | Fixed: L_{h,ω}→L_h in all equations; added explicit "L_h is deterministic" statement | No |
| **11** | **II-B Storage set notation** | **Set S used throughout; no note about numerical study** | Single aggregate battery (\|S\|=1) in all MCS heuristics and LP | **Notation gap** | Implementation | Fixed: added \|S\|=1 statement in primitives; note on allocation rule for heterogeneous fleets | No |
| **12** | **Table I / LP section: cycling cost** | **"0.01/cyc" → "ε=10^-3 $/MWh used in event-window LP and full-year ED"** | Event-window LP: `eps_cyc=1e-3`; full-year ED: separate `storage_cycling_cost` config (not necessarily the same value) | **Partially fixed → refined** | Code | Initial fix changed "0.01/cyc" to ε (tie-break) and stated ε=10^-3 for both methods. Follow-up: Table I entry is now "tie-break penalty"; flushleft note now states ε=10^-3 for event-window LP only, and notes full-year ED uses its own configuration value. No claim that both methods use the same ε. | No |
| **13** | **Results: "companion-code diagnostic"** | **"a companion-code diagnostic traces it to..."** | Documentation-style language; not appropriate for journal prose | **Documentation language** | — | Fixed: replaced with "per-scenario analysis traces it to..." | No |
| **14** | **Appendix sensitivity: main result params** | **"main results use ρ=500 MW, τ=24 h"** | Script 20 default; model hierarchy: rm=1000, buf=48 | **✗ CRITICAL (same as #6)** | Code/results | Fixed: "main results use ρ=1000 MW, τ=48 h" | No |
| **15** | **Appendix sensitivity: LOLH-matching and SOC-floor EUE claims** | (a) "τ=48 h, ρ=500 MW matches M3 LOLH on wind-heavy" (incomplete); (b) "SOC-floor heuristic … also preserves aggregate EUE" (incorrect — SOC-floor overestimates EUE in main results) | Sensitivity CSV: ρ=500/τ=48 matches wind-heavy; ρ=1000/τ=48 matches balanced. SOC-floor EUE is materially higher than M3 in Table II. | **✗ Two errors** | Results / main text | Fixed (a): Added "In the N=5 sensitivity study" qualifier; stated both which param pair matches each portfolio. Fixed (b): Replaced SOC-floor EUE claim with scoped explanation — windows cover the hours that matter for EUE, and outside-window decisions do not change aggregate EUE within the tested event-window parameter range. No general claim that SOC-floor preserves EUE. | No |
| 16 | II-D Full-year ED | Year-long LP; cyclic terminal SOC | Script 20 `run_m3_ed_dispatch`: confirmed | ✓ | Either | None | No |
| 17 | II-E PCM-UCED | MILP with commitment; fixed-commitment marginal CC | HOPE framework; CC via fixed-commitment LP redispatch | ✓ | Either | None | No |
| 18 | II-E NEUE definition | EUE × 10^6 / annual load | `neue = eue / annual_load` (fraction), reported × 10^6 | ✓ | Either | None | No |
| 19 | II-E CC diagnostic | N=20, both portfolios | `paper_hope_validation.csv`: N=20 for both | ✓ | Either | None | No |

---

## Prioritized Action Summary

### Priority 1 — Must fix before submission (DONE)

| Issue | Fix applied | Files changed |
|---|---|---|
| Event-window parameters stated as ρ=500/τ=24 (methodology body and appendix) | Changed to ρ=1000 MW, τ=48 h throughout | `main.tex` |
| CVaR tail size: paper implied 1 scenario at N=20; code uses 2 | Redefined Ω^top using code's index formula; noted "2 scenarios at N=20" | `main.tex` |
| Appendix SOC-floor EUE claim: "SOC-floor also preserves aggregate EUE" | Replaced with scoped explanation tied to event-window window coverage | `main.tex` |

### Priority 2 — Should fix (DONE)

| Issue | Fix applied | Files changed |
|---|---|---|
| LP balance uses P^F directly; code has thermal dispatch variable p_th ≤ P^F | Introduced p^F_h variable and bound; added equivalence note | `main.tex` |
| Load notation: L_{h,ω} in equations where load is deterministic | L_{h,ω}→L_h; added "load is deterministic" statement | `main.tex` |
| Storage set notation with no numerical-study clarification | Added \|S\|=1 statement at start of primitives section | `main.tex` |
| Table I "0.01/cyc" → claimed ε=10^-3 for both methods | Table I: "tie-break penalty"; note: ε=10^-3 for event-window LP only; full-year ED uses separate config value | `main.tex` |
| "companion-code diagnostic" documentation language in Results | Replaced with "per-scenario analysis traces it to..." | `main.tex` |
| Appendix LOLH-match sentence missing N=5 qualifier and covering both portfolios | Added "In the N=5 sensitivity study" and stated both matching pairs | `main.tex` |

### Priority 3 — Optional (not addressed)

| Issue | Status | Note |
|---|---|---|
| No-storage table "Balanced VRE, all methods" case definition | Not verified | Caption explains it's a separate N=5 consistency case; acceptable as-is |
| Fig. 2 axis scale type ("axis floor" wording) | Not verified | Requires inspecting the saved figure |

---

## Code Changes

**None required.** All inconsistencies were on the manuscript side. The code (implementation) was the ground truth in all cases:

- `M2EventWindowLP.jl`: correct (thermal dispatch variable; SOC-floor outside windows)
- `ReliabilityMetrics.jl`: correct (CVaR formula; paper definition was wrong)
- `scripts/20_run_ra2_n20_selected_params.jl`: correct (ρ=1000, τ=48 as default)

---

## Result Files Unchanged

No numerical table values in the manuscript were modified. The existing `paper_hope_validation.csv`, `event_window_parameter_sensitivity.csv`, and related CSVs remain the authoritative source of all reported numbers.

The CVaR values in Table II were already computed with the code's formula (2-scenario tail at N=20); only the text definition was wrong.

---

## Verification Checklist

- [x] `\rho=500` and `\tau=24` removed from main body and appendix
- [x] `L_{h,\omega}` removed from all equations
- [x] `companion-code` removed
- [x] `0.01/cyc` removed from Table I
- [x] Ω^top definition matches `_cvar` function behavior
- [x] `p^F_h` variable introduced in LP balance and bounds
- [x] No claim that full-year ED uses ε=10^-3 $/MWh
- [x] No claim that SOC-floor heuristic generally preserves aggregate EUE
- [x] LOLH-match statement qualified to N=5 sensitivity study
- [x] begin/end environment balance preserved
- [ ] Full pdflatex compile: not available locally; verify on Overleaf
