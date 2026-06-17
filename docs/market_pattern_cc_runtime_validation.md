# Market-Pattern Capacity Credit and Runtime Validation

**Updated:** 2026-06-16  
**Current RAChronoOps result commit:** `11ddf32`  
**Primary scripts:** `scripts/70_market_pattern_marginal_cc.jl`, `scripts/71_common_runtime_benchmark.jl`, `scripts/72_m2_solver_regression.jl`

## Current status

The energy-balanced market-pattern capacity-credit and common runtime experiments have been completed and pushed. The previous version of this document described them as pending; that language is now superseded.

The manuscript has also already been updated through the `paper` submodule. Those manuscript values are therefore no longer merely hypothetical, but they remain subject to the provenance and consistency checks documented below.

**Current validation decision:**

> **NOT READY — M2 LOLH IS SOLVER-DEPENDENT**

The M2 provenance has been confirmed and the EUE-based capacity credit is solver-independent to machine precision. However, HiGHS and Gurobi produce materially different LOLH values (5.75 vs 7.20 h/year balanced; 1.95 vs 2.25 h/year wind-heavy) due to LP degeneracy: both solvers find optimal solutions with equal total load-shed but different temporal distributions across hours. The manuscript Table IV reports M2 LOLH as 5.8 h/year (balanced) and 2.0 h/year (wind-heavy), derived from HiGHS. No numerical threshold resolves the disagreement (minimum disputed hourly load-shed = 1.64 MW; threshold sensitivity CSV sweeps 0 to 1e-3 MW with no convergence). The manuscript must be updated to reflect that M2 LOLH is not uniquely defined under the current LP formulation. Pending: team review of the Case B recommendation and manuscript edit (see Sections 9–10).

---

## 1. Commit and provenance map

| Item | Source/execution commit recorded in output | Result commit | Current status |
|---|---:|---:|---|
| Market-pattern and M1c CC run | `c88914a` | `e82dbf9` | Complete |
| M2 solver change to Gurobi | — | `e82dbf9` | Code change complete |
| Common runtime benchmark | `e82dbf9` | `c5d785d` | Complete |
| Appended M2 CC rows and final result bundle | rows record `c88914a`; actual code = Gurobi (see §9) | `fb8eaa4` | Complete — provenance documented |
| Run manifest (`market_pattern_run_manifest.csv`) | — | `8e080e8` | Complete |
| N=20 HiGHS vs Gurobi solver regression | `c122c3d` | `8e080e8` | Complete — see §9 |
| M2 LOLH hourly diagnostic + threshold sweep | `8e080e8` | pending | Complete — see §9 |
| Current manuscript submodule | — | `a3a826f` in `RA-assessment` | Updated before final audit |

The `code_commit` field denotes the repository HEAD seen by the script at execution time. It is not necessarily the same as the later commit that adds the generated output file.

For future runs, provenance should distinguish at least:

- model-code commit;
- execution commit;
- result commit;
- solver name and version;
- exact command line;
- whether the working tree was clean.

---

## 2. Capacity-credit definition and experiment protocol

The marginal capacity credit is

```text
CC(δ) = [EUE(x) - EUE(x + ΔS)] / [EUE(x) - EUE(x + ΔF)]
```

where:

- `x` is the baseline system;
- `x + ΔS` adds δ MW of four-hour storage;
- `x + ΔF` adds δ MW of perfect-firm capacity;
- all three cases use common random numbers;
- the perfect-firm denominator is obtained by an explicit model rerun.

### Experiment configuration

| Parameter | Value |
|---|---|
| Portfolios | `VRE120_base`, `VRE120_wind_hvy` |
| Scenario seed | 42 |
| Nested sample sizes | 20, 50, 100, 200, 500, 1000 |
| Marginal increments | 1, 5, 10 MW |
| Bootstrap | 2,000 paired draws, seed 1234 |
| Market-pattern calibration | `pattern_energy_balanced` |
| Market-pattern initial SOC | 0.231 of energy capacity |
| M2 event-window parameters | 1000 MW / 48 h / 24 h merge gap / 24 h minimum window |

The N=1000 scenario set is generated once, and the first N scenarios are used for each smaller sample size. This makes estimates directly comparable across N. It **does not** imply that point estimates must move monotonically as N increases.

### Denominator status

A row is marked `identified` when the paired-bootstrap denominator interval remains positive and at least 90% of bootstrap CC draws are finite.

If the denominator interval contains zero, the ratio is **not statistically resolved for that specific N and δ**. This should not be described as proof of a permanent or structural identification failure.

---

## 3. Output inventory

| File | Contents | Current status |
|---|---|---|
| `results/paper_tables/market_pattern_capacity_credit.csv` | 144 CC rows: 2 portfolios × 4 methods × 6 N values × 3 increments | Complete |
| `results/paper_tables/market_pattern_table_iv_rows.csv` | N=20, δ=1 rows for the two market-pattern methods and M1c | Complete |
| `results/market_pattern_cc/scenario_level_cc_components.csv` | 18,000 scenario-level rows at N=1000 | Complete |
| `results/market_pattern_cc/policy_switching_diagnostics.csv` | N=1000 diagnostics for `MP_emergency_cur` | Complete |
| `results/paper_tables/runtime_common_benchmark.csv` | Common N=20 runtime benchmark with median and IQR | Complete |
| `results/paper_tables/market_pattern_run_manifest.csv` | Execution provenance for all CC and runtime runs | Complete (2026-06-16) |
| `results/paper_tables/m2_solver_regression.csv` | N=20 HiGHS vs Gurobi solver regression output | Complete (2026-06-16) |
| `results/paper_tables/m2_lolh_solver_diagnostics.csv` | Per-scenario, per-hour disputed load-shed with window and dispatch context | Complete (2026-06-16) |
| `results/paper_tables/m2_lolh_threshold_sensitivity.csv` | LOLH at nine thresholds (0 to 1e-3 MW) for both solvers | Complete (2026-06-16) |

The capacity-credit CSV contains four methods:

- `MP_pure_cur`;
- `MP_emergency_cur`;
- `M1c`;
- `M2`.

The Table IV candidate CSV currently contains only the first three. The manuscript M2 row therefore must be traced separately to the M2 reliability and CC outputs.

---

## 4. N=20 reliability consistency

The current N=20 results agree with the authoritative energy-balanced revalidation to rounding:

| Portfolio | Method | LOLH (h) | EUE (MWh) |
|---|---|---:|---:|
| Balanced VRE | Market-pattern | 46.0 | 13,655.1 |
| Balanced VRE | Market-pattern + emergency | 7.7 | 3,596.0 |
| Balanced VRE | Emergency-only | 5.95 | 2,479.2 |
| Wind-heavy | Market-pattern | 23.9 | 7,160.6 |
| Wind-heavy | Market-pattern + emergency | 2.4 | 836.2 |
| Wind-heavy | Emergency-only | 2.25 | 648.2 |

The paper-facing market-pattern methods use `charge_curtailed=true`. The charging-induced EUE invariant is therefore zero by construction, up to numerical tolerance.

---

## 5. Manuscript-facing N=20 capacity credit

The main comparison uses N=20 reliability metrics. Therefore, the internally consistent manuscript-facing CC values are the N=20, δ=1 MW point estimates—not the N=1000 estimates.

| Portfolio | Method | CC | Bootstrap mean | 95% CI | Denominator status |
|---|---|---:|---:|---:|---|
| Balanced VRE | Market-pattern | 0.1438 | 0.1438 | [0.1306, 0.1569] | identified |
| Balanced VRE | Market-pattern + emergency | 0.3583 | 0.3584 | [0.3291, 0.3894] | identified |
| Balanced VRE | Emergency-only | 0.4974 | 0.4980 | [0.4822, 0.5183] | identified |
| Wind-heavy | Market-pattern | 0.1280 | 0.1280 | [0.1144, 0.1409] | identified |
| Wind-heavy | Market-pattern + emergency | 0.4935 | 0.4976 | [0.4412, 0.5760] | identified |
| Wind-heavy | Emergency-only | 0.6041 | 0.6045 | [0.5486, 0.6545] | identified |

These values support retaining the N=20 point estimates in the main table, provided that the manuscript or appendix reports the corresponding uncertainty and clearly states the N=20 sampling basis.

The larger-N estimates should be used for convergence analysis, not silently substituted into the N=20 comparison table.

---

## 6. Convergence and finite-difference interpretation

### Market-pattern storage

The pure market-pattern estimates are comparatively stable across N and δ. For example, balanced-VRE δ=1 MW changes from approximately 0.144 at N=20 to approximately 0.145 at N=1000.

### Market-pattern + emergency

The emergency variant is more sensitive to scenario count and finite-difference size:

- Balanced-VRE δ=1 MW increases from approximately 0.358 at N=20 to approximately 0.401 at N=1000.
- Wind-heavy δ=1 MW increases from approximately 0.494 at N=20 to approximately 0.525 at N=1000.
- At wind-heavy N=1000, the δ=5 and δ=10 point estimates are approximately 0.466 and 0.473, respectively.

This variation does not invalidate the N=20 comparison, but it shows that the emergency-override CC is less locally linear and more sample-sensitive than the pure market-pattern CC. The manuscript should avoid describing it as fully converged based only on the N=20 point estimate.

### Emergency-only and M2

Emergency-only CC also changes with sample composition, especially in the wind-heavy case: the δ=1 estimate declines from approximately 0.604 at N=20 to approximately 0.538 at N=1000.

The current M2 rows numerically match the emergency-only rows. This supports equivalence in aggregate EUE-based CC, but it does not prove identical hourly dispatch. The solver/provenance regression remains required before treating the M2 rows as fully validated.

---

## 7. Policy-switching diagnostics

The `EueDecomposition` fields are **not an additive partition** of total EUE.

Their definitions are:

- `pre_storage_shortfall_eue`: EUE occurring in hours that were already short before storage action;
- `missed_discharge_eue`: a subset calculated only when `emergency_override=false`, measuring additional discharge that the emergency rule could have supplied;
- `charging_induced_eue`: EUE created in previously non-short hours by charging beyond surplus;
- `low_soc_shortfall_eue`: a subset of pre-storage-shortfall EUE occurring when start-of-hour SOC is below 25%.

For `MP_emergency_cur`:

- `missed_discharge_eue = 0` by implementation because the emergency rule is already active;
- `charging_induced_eue = 0` by construction because charging is curtailed to surplus;
- residual EUE remains when storage power or available SOC is insufficient to cover the pre-storage shortfall;
- `low_soc_shortfall_eue` is an overlapping conditional diagnostic, not a separate additive cause.

At N=1000, low-SOC shortage EUE is approximately 95% of total EUE in the balanced case and 91% in the wind-heavy case. This shows a strong association between residual EUE and low start-of-hour SOC, but it should not be interpreted alone as proof that initial SOC or pre-event depletion is the sole causal mechanism. Event duration, within-event depletion, power limits, and the prior market-dispatch trajectory can all contribute.

---

## 8. Runtime benchmark

The current runtime CSV records:

- five timed repetitions for M1a, M1b, M1c, `MP_pure_cur`, `MP_emergency_cur`, and M2;
- three timed repetitions for M3;
- one untimed warm-up before each method;
- scenario generation and case loading outside the timed block;
- median and IQR in seconds per scenario.

| Portfolio | Method | Median s/scenario | IQR s/scenario |
|---|---|---:|---:|
| Balanced VRE | Emergency-only | 0.04145 | 0.00185 |
| Balanced VRE | Market-pattern | 0.05040 | 0.01460 |
| Balanced VRE | Market-pattern + emergency | 0.05005 | 0.00250 |
| Balanced VRE | M2 event-window | 0.18065 | 0.01605 |
| Balanced VRE | Full-year ED | 9.11720 | 0.03372 |
| Wind-heavy | Emergency-only | 0.04325 | 0.00030 |
| Wind-heavy | Market-pattern | 0.04640 | 0.00020 |
| Wind-heavy | Market-pattern + emergency | 0.04695 | 0.00325 |
| Wind-heavy | M2 event-window | 0.15860 | 0.00460 |
| Wind-heavy | Full-year ED | 8.92105 | 0.06950 |

Any documentation saying that the M2 median is based on only three repetitions is incorrect. The current CSV records five M2 repetitions; only M3 uses three.

---

## 9. M2 provenance resolution and solver regression

### Provenance of the M2 CC rows

The M2 CC rows in `market_pattern_capacity_credit.csv` were generated by the script-70 run that started at 2026-06-16T15:10:19. At that time, `git rev-parse --short HEAD` returned `c88914a` (the HiGHS version), which is recorded in the `code_commit` column. However, the working tree contained the uncommitted Gurobi fix (later committed as `e82dbf9`). The actual solver used for all M2 LP windows was therefore **Gurobi**, matching the `e82dbf9` code. The `code_commit=c88914a` entry is misleading and is corrected by this documentation. The run manifest (`market_pattern_run_manifest.csv`) records the full provenance including `working_tree_clean=false` and `notes` explaining the discrepancy.

### N=20 HiGHS vs Gurobi solver regression (script 72)

A controlled regression was run on 2026-06-16 comparing HiGHS 1.23.0 and Gurobi 13.0.2 on identical N=20 scenarios (seed=42) for both portfolios and all three δ values. Results (from `m2_solver_regression.csv`):

| Metric | Max absolute difference | Tolerance | Result |
|---|---:|---:|---|
| EUE (base, stor, firm) | 9.09 × 10⁻¹³ MWh | 1 × 10⁻⁶ MWh | **PASS** |
| Marginal CC | 3.43 × 10⁻¹⁴ | 1 × 10⁻⁸ | **PASS** |
| LP objective (per-scenario) | 1.82 × 10⁻¹² MWh | 1 × 10⁻⁶ MWh | **PASS** |
| Event-window boundaries | identical | exact | **PASS** |
| LOLH | 5.75 vs 7.20 (VRE120\_base); 1.95 vs 2.25 (wind-heavy) | exact match required | **FAIL** |

**Correction of prior note:** The prior version of this document stated that "LOLH is not reported in the paper." This was incorrect. The manuscript Table IV reports M2 LOLH as 5.8 h/year (balanced VRE) and 2.0 h/year (wind-heavy), matching the HiGHS results rounded to one decimal place. Gurobi gives 7.2 h/year and 2.25 h/year. The regression therefore marks `overall_pass=false` for all six combinations.

### M2 LOLH hourly diagnostic (script 73) — Case B confirmed

Script `73_m2_lolh_diagnostics.jl` ran on 2026-06-16 and produced two output files:
`results/paper_tables/m2_lolh_solver_diagnostics.csv` and
`results/paper_tables/m2_lolh_threshold_sensitivity.csv`.

**Disputed scenario-hours** (hours where one solver has `load_shed > 0` and the other has `load_shed = 0`):

| Portfolio | Disputed hours | Min shed (MW) | Median shed (MW) | Mean shed (MW) | Max shed (MW) | All inside windows? |
|---|---:|---:|---:|---:|---:|---|
| VRE120\_base | 101 | 1.64 | 291 | 355 | 935 | Yes |
| VRE120\_wind\_hvy | 28 | 42.6 | 280 | 336 | 825 | Yes |

Example from scenario 1, VRE120\_base (window 4578–6259):
- Hour 4984: HiGHS = 0 MW, Gurobi = 668.3 MW (`Gurobi_only`)
- Hour 4985: HiGHS = 0 MW, Gurobi = 242.9 MW (`Gurobi_only`)
- Hour 4988: HiGHS = 805.7 MW, Gurobi = 0 MW (`HiGHS_only`)
- Hour 4989: HiGHS = 105.5 MW, Gurobi = 0 MW (`HiGHS_only`)

The per-scenario sums are equal (same total EUE); both solvers place load shedding in different hours within the same window.

**Threshold sensitivity** — LOLH at thresholds from 0 to 1e-3 MW (`m2_lolh_threshold_sensitivity.csv`):

| Solver | VRE120\_base LOLH | VRE120\_wind\_hvy LOLH | Agree at any threshold? |
|---|---:|---:|---|
| HiGHS | 5.75 (all thresholds) | 1.95 (all thresholds) | — |
| Gurobi | 7.20 (all thresholds) | 2.25 (all thresholds) | — |

`total_eue_excluded_mwh = 0.0` at every threshold for both portfolios and both solvers. The minimum disputed load-shed value (1.64 MW) is four orders of magnitude above the maximum threshold tested (1e-3 MW). No threshold in the range tested causes any EUE to be reclassified.

**Case B determination:** The disputed hours contain load-shed values of 1.64–935 MW. These are not LP feasibility residuals. Both solvers achieve the same minimum total EUE (objective value difference ≤ 9e-13 MWh) but assign the fixed total shortfall to different hours within each event window. This is LP degeneracy: within a risk window of 500–2000 hours, the LP objective (minimise total `VOLL × Σ load_shed[h]`) is indifferent to the temporal position of individual load-shed events, since storage can move energy between adjacent hours at no cost to the objective. HiGHS and Gurobi find different optimal bases in this degenerate solution space, producing identical EUE but different LOLH.

**No numerical threshold resolves Case B.** A threshold can suppress feasibility noise (Case A) but cannot choose between equally-optimal temporal allocations. The LOLH disagreement is 1.45 h/year (balanced) and 0.30 h/year (wind-heavy), driven entirely by which solver decides to concentrate load shedding in fewer, larger events vs more, smaller events within the same window.

### Project-wide LOLH definition audit (step 4)

The central LOLH metric is in `src/metrics/ReliabilityMetrics.jl`:

```julia
# line 133
scen_lolh = [Float64(count(ls -> ls > 0.0, r.load_shed)) for r in results]

# line 253 — public helper
compute_lolh(load_shed) = Float64(count(x -> x > 0.0, load_shed))
```

The threshold is exact `> 0.0` (no numerical tolerance) and is applied uniformly by all methods (M1a, M1b, M1c, MP, M2, M3) via `compute_metrics`.

**Assessment:** The `> 0.0` threshold is correct and appropriate for non-LP methods (M1a, M1b, M1c, MP). These methods produce deterministic dispatch per scenario, so LOLH is well-defined and solver-independent. **No change to `ReliabilityMetrics.jl` is warranted** for any non-LP method.

For M2 (event-window LP) and M3 (full-year LP), LOLH is structurally solver-dependent because the LP has degenerate optimal solutions. The source of non-uniqueness is the LP objective itself, not the LOLH counting rule. A more restrictive threshold (e.g., 1e-3 MW) cannot fix degeneracy because the disputed values are in the hundreds of MW. Only a secondary lexicographic objective added to the LP can impose a canonical temporal allocation.

**Recommendation:** Do not change the threshold in `ReliabilityMetrics.jl`. Document that LP-based methods (M2, and potentially M3 over the full year) may produce solver-dependent LOLH when the LP has a degenerate optimal solution space.

### Mixed-solver issue

The manuscript Table IV currently mixes two solver implementations for M2:
- **LOLH** (5.8 h/year balanced, 2.0 h/year wind-heavy): from the HiGHS run recorded in the June 14 log at commit `c88914a` (the original production run before the Gurobi fix was committed).
- **Capacity credit** (0.497 balanced, 0.604 wind-heavy at N=20 δ=1 MW): from Gurobi, which was the actual solver in the working tree during the June 16 script-70 run.
- **Runtime** (0.18 s/scenario balanced, 0.16 s/scenario wind-heavy): from the Gurobi benchmark (`71_common_runtime_benchmark.jl`, commit `e82dbf9`).

EUE and CC are solver-independent, so the CC and runtime values are unaffected by the solver choice. LOLH is solver-dependent. The manuscript LOLH values therefore reflect HiGHS, while all other M2 values in Table IV reflect Gurobi. This is the mixed-solver issue to be resolved before final approval.

---

## 10. Case B recommendation and manuscript action

### Recommended action: report M2 LOLH as solver-dependent with an em-dash

The four options from the user's instructions are:

1. **Retain 5.8 / 2.0 h/year with an explicit HiGHS note.** Technically accurate but inconsistent with the Gurobi-based CC and runtime values in the same table row. A footnote distinguishing the LOLH solver from the CC solver would be unusual and may confuse readers.

2. **Replace with threshold-stabilized values.** Not possible under Case B: no threshold in [0, 1e-3 MW] produces agreement. The disputed values are hundreds of MW above any reasonable LP feasibility tolerance.

3. **Report a range: "5.75–7.20 h/year (balanced), 1.95–2.25 h/year (wind-heavy)".** Accurately communicates the uncertainty but introduces a solver-dependent interval into a table whose other columns are point estimates. The range conveys the right message but may require explanation in the text.

4. **Omit M2 LOLH with an em-dash, retain EUE and CC.** The cleanest scientific choice: the em-dash signals that M2 LOLH is not uniquely determined by the model formulation, which is the true finding. EUE and CC remain in the table and are validated to machine precision. A footnote or methods note can state that M2 LOLH is not uniquely defined for the current LP because the EUE-minimizing LP has multiple degenerate optima differing in temporal allocation.

**Recommendation: use option 4 (em-dash for M2 LOLH)**, with a table footnote stating approximately:

> *M2 LOLH is not reported because the event-window LP has multiple degenerate optima with equal total load-shed but different temporal distributions (HiGHS: 5.8 h/year; Gurobi: 7.2 h/year for the balanced-VRE portfolio). EUE and CC are identical across solvers to machine precision.*

If the team prefers option 3 (range), the values are 5.75–7.20 h/year (balanced VRE, HiGHS–Gurobi) and 1.95–2.25 h/year (wind-heavy).

**Do NOT edit `RA-assessment/main.tex`** until this recommendation has been reviewed by the team.

### N=20 metric rerun

Under Case B, no rerun is required for EUE or CC (both are solver-independent). A rerun would only be needed if a lexicographic secondary objective were added to the M2 LP to impose a canonical temporal allocation of load shedding — this would change the LOLH values and potentially alter the dispatch within windows. No such change to the LP is recommended here; it would be a non-trivial modification requiring its own validation.

### Other manuscript items (unchanged)

- Keep the corrected N=20 reliability values for MP and M1c methods.
- Keep the market-pattern and emergency-only N=20 CC point estimates; report bootstrap uncertainty in the appendix or a table note.
- Do not replace N=20 CC with N=1000 estimates in the main comparison table.
- The M2 CC values (0.497 balanced, 0.604 wind-heavy at N=20 δ=1 MW) are validated: solver-independent to machine precision, consistent with the June 14 HiGHS log, and identical to the M1c (emergency-only) values as expected.
- Use the five-repetition M2 runtime medians of approximately 0.18 s/scenario (balanced VRE) and 0.16 s/scenario (wind-heavy), from `runtime_common_benchmark.csv` commit `c5d785d`.
- Describe the emergency-override CC as sample- and increment-sensitive rather than fully converged.
