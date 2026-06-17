# Market-Pattern Capacity Credit and Runtime Validation

**Updated:** 2026-06-16  
**Current RAChronoOps result commit:** `fb8eaa4`  
**Primary scripts:** `scripts/70_market_pattern_marginal_cc.jl`, `scripts/71_common_runtime_benchmark.jl`, `scripts/72_market_pattern_revalidation.jl`

## Current status

The energy-balanced market-pattern capacity-credit and common runtime experiments have been completed and pushed. The previous version of this document described them as pending; that language is now superseded.

The manuscript has also already been updated through the `paper` submodule. Those manuscript values are therefore no longer merely hypothetical, but they remain subject to the provenance and consistency checks documented below.

**Current validation decision:**

> **NOT READY — M2 PROVENANCE UNRESOLVED**

The market-pattern and emergency-only results are structurally complete and internally consistent. The remaining blocking issue is the provenance of the appended M2 capacity-credit rows after the M2 solver was changed from HiGHS to Gurobi.

---

## 1. Commit and provenance map

| Item | Source/execution commit recorded in output | Result commit | Current status |
|---|---:|---:|---|
| Market-pattern and M1c CC run | `c88914a` | `e82dbf9` | Complete |
| M2 solver change to Gurobi | — | `e82dbf9` | Code change complete |
| Common runtime benchmark | `e82dbf9` | `c5d785d` | Complete |
| Appended M2 CC rows and final result bundle | rows record `c88914a` | `fb8eaa4` | **Provenance requires confirmation** |
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

## 9. Remaining blocking checks

Before final team approval:

1. Establish whether the appended M2 CC rows were generated with the historical HiGHS implementation or the current Gurobi implementation.
2. Run a same-scenario N=20 HiGHS-versus-Gurobi regression for M2 at δ=1, 5, and 10 MW.
3. Record solver name/version and clean-working-tree status in a run manifest.
4. Verify that the M2 N=20 CC and reliability values agree within numerical tolerance under both solvers.
5. Audit the manuscript row-by-row against the current source files and add uncertainty language where appropriate.

A full N=1000 rerun is not necessary unless the N=20 solver regression fails.

---

## 10. Manuscript recommendation

- Keep the corrected N=20 reliability values.
- Keep the market-pattern and emergency-only N=20 CC point estimates, while reporting their bootstrap uncertainty in the appendix or table note.
- Do not replace N=20 CC with N=1000 estimates in the main comparison table.
- Treat the M2 CC values as provisional until solver provenance and the N=20 regression are documented.
- Use the five-repetition M2 runtime medians of approximately 0.18 and 0.16 s/scenario.
- Describe the emergency-override CC as sample- and increment-sensitive rather than fully converged.
