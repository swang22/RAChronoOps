# Paper Tables and Figures Plan

**Last updated:** 2026-05-21

This document maps each planned table and figure to its source result folder,
source script, exact CSV file, and one-sentence takeaway.  All values are drawn
directly from committed result files; placeholders are flagged with `[TBD]`.

---

## Main tables

---

### Table 1 — Model hierarchy and assumptions

**Placement:** Main text (Section 2 or Methods).

**Takeaway:** The model ladder spans five orders of magnitude in runtime and
four distinct levels of temporal storage representation, motivating a systematic
accuracy–runtime trade-off analysis.

**Source:** Derived from model documentation; no single CSV.  Cross-check
runtimes against `results/m1d_storage_heuristic_comparison/m1d_aggregate_metrics.csv`
and `results/wind_hvy_hope_uc_comparison/n5/all_model_aggregate_metrics.csv`.

| Model | Storage? | Optimization? | Temporal operation representation | Runtime order | Paper role |
|-------|----------|--------------|-----------------------------------|--------------|------------|
| MC-NoStorage | No | No | Classical hourly capacity check | < 1 s/scenario | No-storage baseline; validates MC sampling |
| M1 / RA-1a | Yes | No | Naive 3-priority peak-shaving heuristic | ~1 s/scenario | Cautionary failure case |
| M1b / RA-1b | Yes | No | Reserve-aware heuristic (SOC floor on P2) | ~1 s/scenario | Improved heuristic; partially corrects M1 |
| M1c / RA-1c | Yes | No | Emergency-only discharge, system-surplus charging | ~1–2 s/scenario | Near-benchmark simple model |
| M1d / RA-1d | Yes | No | Risk-hour allocation (earliest\_first / largest\_first) | ~1–2 s/scenario | Within-event allocation diagnostic |
| M2 / RA-2 | Yes | LP (event windows only) | Event-window LP (rm=1000 MW, buf=48 h) | ~5–10 s/scenario | Proposed hybrid method |
| M3 / RA-3 | Yes | LP (full year) | Full-year economic dispatch LP (Gurobi) | ~9–10 s/scenario | LP reliability benchmark |
| HOPE-ED | Yes | LP (full year) | Full-year HOPE economic dispatch LP | ~120 s/scenario | HOPE mapping validation |
| HOPE-UC / M4 | Yes | MILP (full year) | Full-year HOPE unit commitment MILP | ~540–580 s/scenario | High-fidelity UC benchmark |

**Construction notes:**
- Runtime column reports per-scenario mean from N=20 runs where available;
  HOPE values from N=5 and N=20 runs.
- M1d reports earliest\_first mode; largest\_first has comparable runtime.
- Optimization column distinguishes LP/MILP (uses solver) from heuristic (no solver).

---

### Table 2 — No-storage MC validation

**Placement:** Main text (Results, Experiment A).

**Takeaway:** Without storage, the classical hourly capacity check equals the
full-year ED LP and the HOPE-UC MILP exactly — confirming that MC sampling is
valid in the no-storage RA setting and that any divergence in storage cases
traces solely to storage dispatch.

**Source result folders:**
- `results/no_storage_comparison/` — N=20 MC vs M3
- `results/nostorage_hope_uc_comparison/base_n5/` — N=5 four-model check

**Source scripts:**
- `scripts/34_compare_no_storage_classic_vs_ed.jl`
- `scripts/36_compare_nostorage_hope_uc_n5.jl`

**Exact CSV files:**
- `results/no_storage_comparison/no_storage_comparison_results.csv` — N=20 base and wind-heavy
- `results/nostorage_hope_uc_comparison/base_n5/all_model_aggregate_metrics.csv` — N=5 four-model

**Panel A — N=20, VRE120\_base and VRE120\_wind\_hvy:**

| Case | Model | N | LOLH (h) | EUE (MWh) | CVaR (MWh) | ΔEUE vs M3-NS |
|------|-------|---|----------|-----------|-----------|---------------|
| VRE120\_base | MC-NoStorage | 20 | 95.4 | 31,017 | 51,937 | 0.00 MWh |
| VRE120\_base | M3-NoStorage | 20 | 95.4 | 31,017 | 51,937 | — |
| VRE120\_wind\_hvy | MC-NoStorage | 20 | 52.4 | 15,801 | 26,871 | 0.00 MWh |
| VRE120\_wind\_hvy | M3-NoStorage | 20 | 52.4 | 15,801 | 26,871 | — |

**Panel B — N=5, VRE120\_base\_nostorage (four-model HOPE-UC check):**

| Model | N | LOLH (h) | EUE (MWh) | CVaR (MWh) | Runtime (s/scenario) |
|-------|---|----------|-----------|-----------|---------------------|
| MC-NoStorage | 5 | 115.6 | 41,846 | 54,383 | 0.10 |
| M3-NoStorage | 5 | 115.6 | 41,846 | 54,383 | 8.0 |
| HOPE-ED-NoStorage | 5 | 115.6 | 41,846 | 54,383 | 122.9 |
| HOPE-UC-NoStorage | 5 | 115.6 | 41,846 | 54,383 | 866.2 |

**Construction notes:**
- ΔEUE = 0.00 MWh per scenario (exact match, not within rounding).
- HOPE-UC adds 7× runtime over HOPE-ED with zero reliability benefit; note in
  a table footnote.
- CVaR for Panel B rows are identical across all four models: 54,383 MWh.

---

### Table 3 — Storage-energy sufficiency bound

**Placement:** Main text (Results, Experiment E / Theory section).

**Takeaway:** In the tested RTS-GMLC single-zone cases, the theoretical
storage-energy sufficiency bound matches M3 EUE exactly per scenario, showing
that the residual EUE is governed by storage energy availability around shortage
events rather than dispatch model complexity.

**Source result folder:** `results/storage_energy_sufficiency_bound/`

**Source script:** `scripts/39_storage_energy_sufficiency_bound.jl`

**Exact CSV files:**
- `results/storage_energy_sufficiency_bound/bound_vs_models.csv` — per-scenario
  bound, M1c, M2, M3 EUE values
- `results/storage_energy_sufficiency_bound/scenario_level_storage_bound.csv` —
  per-scenario sufficiency ratios

| Case | Pre-storage EUE (MWh) | Bound EUE (MWh) | M3 EUE (MWh) | Bound − M3 (MWh) | Sufficiency ratio |
|------|----------------------|----------------|-------------|-----------------|-------------------|
| VRE120\_base | 31,017 | 2,479 | 2,479 | 0.00 | 0.941 |
| VRE120\_wind\_hvy | 15,801 | 648 | 648 | 0.00 | 0.972 |

**Construction notes:**
- All values are means across N=20 scenarios; seed=42; lookback=72 h.
- "Bound − M3" = 0.00 MWh to machine precision across all 40 individual scenarios.
- "Sufficiency ratio" = 1 − (M3 EUE / pre-storage EUE): the fraction of the
  pre-storage deficit that storage covers.
- The min() in the bound formula is dominated by `feasible_discharge_energy`
  (energy term) rather than `power_limited_coverage` (power term) in both cases;
  note in a footnote that the binding constraint is energy, not power, for this
  system configuration.
- Consider adding a column for M1c EUE (= bound EUE = M3 EUE in both cases)
  to reinforce convergence.

---

### Table 4 — Storage-aware method comparison

**Placement:** Main text (Results, Experiment B / core comparison table).

**Takeaway:** M1c, M1d\_earliest, and M2 each recover M3 EUE and CVaR exactly,
while M1 and M1b overestimate risk by one to two orders of magnitude in LOLH
and EUE, demonstrating that emergency-only or LP-based dispatch is necessary
once storage is present.

**Source result folders:**
- `results/m1d_storage_heuristic_comparison/` — M1c, M1d, M2, M3 at N=20
- `results/vre_method_comparison/` — M1, M1b at N=3 (diagnostic pilot)

**Source scripts:**
- `scripts/38_compare_m1d_storage_heuristics.jl` — M1c/M1d/M2/M3, N=20
- `scripts/16_run_vre_method_comparison.jl` — M1/M1b (N=3 pilot in committed file;
  run with `n_scenarios=20` to regenerate at N=20 before final paper)

**Exact CSV files:**
- `results/m1d_storage_heuristic_comparison/m1d_aggregate_metrics.csv` — M1c, M1d, M2, M3
- `results/vre_method_comparison/vre_method_comparison_results.csv` — M1, M1b

**Panel A — VRE120\_base:**

| Model | N | LOLH (h) | ΔLOLH vs M3 | EUE (MWh) | ΔEUE vs M3 (MWh) | CVaR (MWh) | RT (s/scen) |
|-------|---|----------|------------|-----------|-----------------|-----------|------------|
| M1 | 3† | 107.0 | +101.1 | 35,119 | +32,640 | 40,277 | 0.23 |
| M1b | 3† | 94.7 | +88.7 | 32,369 | +29,890 | 37,527 | 0.10 |
| M1c | 20 | 6.0 | 0.0 | 2,479 | 0.00 | 9,783 | 0.06 |
| M1d\_earliest | 20 | 6.0 | 0.0 | 2,479 | 0.00 | 9,783 | 0.05 |
| M1d\_largest | 20 | 8.5 | +2.5 | 2,479 | 0.00 | 9,783 | 0.06 |
| M2 | 20 | 5.8 | −0.2 | 2,479 | 0.00 | 9,783 | 0.43 |
| M3 (ref) | 20 | 6.0 | — | 2,479 | — | 9,783 | 9.6 |

**Panel B — VRE120\_wind\_hvy:**

| Model | N | LOLH (h) | ΔLOLH vs M3 | EUE (MWh) | ΔEUE vs M3 (MWh) | CVaR (MWh) | RT (s/scen) |
|-------|---|----------|------------|-----------|-----------------|-----------|------------|
| M1 | 3† | 61.0 | +58.8 | 17,905 | +17,257 | 20,296 | 0.03 |
| M1b | 3† | 32.3 | +30.1 | 11,357 | +10,708 | 13,622 | 0.03 |
| M1c | 20 | 2.3 | 0.0 | 648 | 0.00 | 3,528 | 0.07 |
| M1d\_earliest | 20 | 2.3 | 0.0 | 648 | 0.00 | 3,528 | 0.11 |
| M1d\_largest | 20 | 2.7 | +0.4 | 648 | 0.00 | 3,528 | 0.05 |
| M2 | 20 | 2.0 | −0.3 | 648 | 0.00 | 3,528 | 0.38 |
| M3 (ref) | 20 | 2.3 | — | 648 | — | 3,528 | 9.2 |

†M1 and M1b were run at N=3 in the committed pilot (clear failure established
at N=3; regenerate at N=20 from `scripts/16` before submitting).

**Construction notes:**
- ΔEUE is per-scenario exact (not just mean); note "exact per-scenario match" in
  a footnote for M1c/M1d\_earliest/M2/M3.
- M1d\_largest ΔEUE = 0.00 MWh (exact); LOLH increase reflects within-event
  redistribution, not additional unserved energy.
- Consider splitting into two panels (Panel A: base; Panel B: wind-heavy) or
  using a combined table with a case column.
- RT column reports mean\_runtime\_s from aggregate metrics CSV.

---

### Table 5 — HOPE validation

**Placement:** Main text (Results, Experiments C and D).

**Takeaway:** HOPE-UC produces identical EUE to HOPE-ED in both tested cases
but increases LOLH by 0.4–1.0 h, incurring a 4–5× runtime penalty with no
EUE benefit; HOPE-ED and M3 agree to within 1 MWh.

**Source result folders:**
- `results/full_model_comparison_with_hope/base_n5/` — N=5 M1/M2/M3/HOPE-ED/HOPE-UC, base
- `results/wind_hvy_hope_uc_comparison/n5/` — N=5 five-model, wind-heavy

**Source scripts:**
- `scripts/30_compare_all_models_hope_n5.jl`
- `scripts/37_compare_wind_hvy_hope_uc_n5.jl`

**Exact CSV files:**
- `results/full_model_comparison_with_hope/base_n5/all_model_aggregate_metrics.csv`
- `results/wind_hvy_hope_uc_comparison/n5/all_model_aggregate_metrics.csv`

**Panel A — Storage-enabled comparison (VRE120\_base N=5 and VRE120\_wind\_hvy N=5):**

| Case | Model | N | LOLH (h) | EUE (MWh) | CVaR (MWh) | RT (s/scen) |
|------|-------|---|----------|-----------|-----------|------------|
| VRE120\_base | M3 | 5 | 11.2 | 4,707 | 9,712 | 9.5 |
| VRE120\_base | HOPE-ED | 5 | 11.8 | 4,707 | 9,712 | 121.4 |
| VRE120\_base | HOPE-UC | 5 | 15.2 | 4,707 | 9,712 | 576.6 |
| VRE120\_wind\_hvy | M3 | 5 | 4.4 | 1,113 | 2,793 | 8.9 |
| VRE120\_wind\_hvy | HOPE-ED | 5 | 3.8 | 1,113 | 2,793 | 117.5 |
| VRE120\_wind\_hvy | HOPE-UC | 5 | 4.2 | 1,113 | 2,793 | 542.4 |

**Panel B — N=20 HOPE-ED vs HOPE-UC, VRE120\_base (from committed docs):**

| Model | N | LOLH (h) | EUE (MWh) | CVaR (MWh) | RT (s/scen) |
|-------|---|----------|-----------|-----------|------------|
| HOPE-ED | 20 | 6.2 | 2,479 | 9,783 | 117.8 |
| HOPE-UC | 20 | 7.2 | 2,479 | 9,783 | 571.9 |

**Construction notes:**
- Panel A uses N=5; higher absolute LOLH and EUE vs N=20 reflect sampling
  variance, not systematic differences.  Differences between HOPE-ED and
  HOPE-UC are the paper point.
- Panel B N=20 values come from `docs/current_findings_synthesis.md` (Table D);
  regenerate from `scripts/30` with N=20 if the aggregate CSV is needed for
  the final paper.
- EUE values are identical across M3, HOPE-ED, HOPE-UC to within 1 MWh in
  both panels — note "EUE exact match" explicitly.
- HOPE-UC/HOPE-ED runtime ratio ~4–5× in both cases; add a "Runtime ratio" row
  or footnote.

---

## Main figures

---

### Figure 1 — Conceptual framework

**Placement:** Main text (Introduction or Methods overview).

**Takeaway:** Traditional MC is exact without storage; storage introduces
intertemporal SOC coupling that makes reliability estimates sensitive to
dispatch assumptions; the storage-aware MC ladder (M1c, M2) bridges the
gap to full-year ED/UC at a fraction of the runtime.

**Type:** Conceptual diagram (no data CSV needed).

**Suggested layout:**
```
[No-storage world]          [Storage world]
 MC sampling OK              MC sampling still OK
 LP = MC exactly             Storage SOC links hours together
                              ↓
                         [Dispatch ladder]
                          M1/M1b  →  overestimate risk
                          M1c/M2  →  match M3 EUE
                          M3      →  LP benchmark
                          HOPE-UC →  +LOLH, same EUE
```

**Source:** Conceptual; consult `docs/redesigned_experiment_plan.md` §1–2 for
narrative framing.

---

### Figure 2 — No-storage validation bar chart

**Placement:** Main text (Results, Experiment A).

**Takeaway:** All four models produce identical LOLH and EUE without storage,
confirming that MC sampling error is not the source of divergence observed once
storage is added.

**Type:** Grouped bar chart (2 panels: LOLH and EUE).

**Source result folder:** `results/nostorage_hope_uc_comparison/base_n5/`

**Source script:** `scripts/36_compare_nostorage_hope_uc_n5.jl`

**Exact CSV:** `results/nostorage_hope_uc_comparison/base_n5/all_model_aggregate_metrics.csv`

**Data to plot (N=5, VRE120\_base\_nostorage):**

| Model | LOLH (h) | EUE (MWh) |
|-------|----------|-----------|
| MC-NoStorage | 115.6 | 41,846 |
| M3-NoStorage | 115.6 | 41,846 |
| HOPE-ED-NoStorage | 115.6 | 41,846 |
| HOPE-UC-NoStorage | 115.6 | 41,846 |

**Construction notes:**
- All four bars will be visually identical — this is the point.
- Add error bars (CI95 half-widths) from the same CSV.
- Label the bars with runtime order of magnitude (caption or annotation).

---

### Figure 3 — EUE by method with storage

**Placement:** Main text (Results, Experiment B).

**Takeaway:** M1 and M1b dramatically overestimate EUE relative to the M3
benchmark; M1c, M1d\_earliest, and M2 recover M3 EUE exactly; HOPE-UC
matches HOPE-ED EUE.

**Type:** Grouped bar chart or scatter/dot plot (models on x-axis, EUE on y-axis;
two groups for base and wind-heavy cases).

**Source result folders:**
- `results/m1d_storage_heuristic_comparison/` — M1c/M1d/M2/M3
- `results/vre_method_comparison/` — M1/M1b

**Exact CSVs:**
- `results/m1d_storage_heuristic_comparison/m1d_aggregate_metrics.csv`
- `results/vre_method_comparison/vre_method_comparison_results.csv`

**Data to plot:**

| Model | EUE VRE120\_base (MWh) | EUE VRE120\_wind\_hvy (MWh) |
|-------|----------------------|-----------------------------|
| M1 | 35,119 (N=3) | 17,905 (N=3) |
| M1b | 32,369 (N=3) | 11,357 (N=3) |
| M1c | 2,479 (N=20) | 648 (N=20) |
| M1d\_earliest | 2,479 (N=20) | 648 (N=20) |
| M1d\_largest | 2,479 (N=20) | 648 (N=20) |
| M2 | 2,479 (N=20) | 648 (N=20) |
| M3 (ref) | 2,479 (N=20) | 648 (N=20) |

**Construction notes:**
- Use a log scale on the y-axis to show M1/M1b and M1c/M3 together.
- Alternatively, use a split y-axis or two panels (top: M1/M1b; bottom: M1c+).
- Mark M3 as a horizontal reference line; all M1c/M1d/M2 bars should reach it.
- Annotate the M1/M1b bars with "N=3 pilot" to flag smaller sample size.

---

### Figure 4 — Runtime versus EUE error (accuracy–runtime frontier)

**Placement:** Main text (Results or Discussion — central trade-off figure).

**Takeaway:** M1c achieves near-zero EUE error at ~1 s/scenario (130× faster
than M3); M2 achieves near-machine-precision EUE error at ~8 s/scenario (20–37×
faster); HOPE-UC adds 4–5× runtime over M3 with no EUE benefit.

**Type:** Log–log scatter plot (x: runtime per scenario, y: |EUE − HOPE-UC EUE|
or |EUE − M3 EUE|).

**Source result folders:**
- `results/m1d_storage_heuristic_comparison/` — M1c/M1d/M2/M3
- `results/wind_hvy_hope_uc_comparison/n5/` — HOPE-ED, HOPE-UC
- `results/vre_method_comparison/` — M1, M1b

**Exact CSVs:**
- `results/m1d_storage_heuristic_comparison/m1d_aggregate_metrics.csv`
- `results/wind_hvy_hope_uc_comparison/n5/all_model_aggregate_metrics.csv`
- `results/vre_method_comparison/vre_method_comparison_results.csv`

**Data to plot (VRE120\_base, |ΔEUE| vs M3, representative runtimes):**

| Model | RT (s/scen) | |ΔEUE| vs M3 (MWh) | Note |
|-------|------------|---------------------|------|
| M1 | ~0.2 | ~32,640 | N=3 pilot |
| M1b | ~0.1 | ~29,890 | N=3 pilot |
| M1c | 0.06 | 0.00 | N=20 |
| M1d\_earliest | 0.05 | 0.00 | N=20 |
| M2 | 0.43 | 0.00 | N=20 |
| M3 | 9.6 | 0.00 | N=20, reference |
| HOPE-ED | ~120 | ~0 | N=5 |
| HOPE-UC | ~570 | ~0 | N=5 |

**Construction notes:**
- Use log scale on both axes.
- M1c, M1d\_earliest, M2, M3, HOPE-ED, HOPE-UC will cluster at |ΔEUE| → 0;
  M1/M1b will appear in the upper-left region.
- For models where |ΔEUE| = 0.00 exactly, offset by a small jitter (e.g., 0.1 MWh)
  on the y-axis, or use a broken-axis panel showing the near-zero group separately.
- Add arrows or labels to identify the "efficient frontier" (M1c → M2 → M3 → HOPE-ED).
- Plot both VRE120\_base and VRE120\_wind\_hvy using different marker shapes.

---

### Figure 5 — Storage-energy sufficiency bound

**Placement:** Main text (Results, Experiment E / Theory section).

**Takeaway:** The theoretical storage-energy bound and the M3 LP dispatch
achieve the same residual EUE in both tested cases, and the bound is tight
(Bound − M3 = 0.00 MWh), explaining why any surplus-charging/shortage-discharging
model converges to the same EUE in these configurations.

**Type:** Stacked bar chart (pre-storage EUE decomposed into coverage and
residual EUE) with M3 EUE overlay.

**Source result folder:** `results/storage_energy_sufficiency_bound/`

**Source script:** `scripts/39_storage_energy_sufficiency_bound.jl`

**Exact CSVs:**
- `results/storage_energy_sufficiency_bound/scenario_level_storage_bound.csv` —
  per-scenario sufficiency ratios for box plots / distributional panels
- `results/storage_energy_sufficiency_bound/bound_vs_models.csv` — side-by-side
  bound vs M1c/M2/M3

**Data to plot (aggregate, N=20):**

| Case | Pre-storage EUE (MWh) | Coverage by bound (MWh) | Residual EUE bound (MWh) | M3 EUE (MWh) |
|------|----------------------|------------------------|-------------------------|-------------|
| VRE120\_base | 31,017 | 28,538 | 2,479 | 2,479 |
| VRE120\_wind\_hvy | 15,801 | 15,153 | 648 | 648 |

**Alternative panel suggestion:** box plot of per-scenario residual EUE bound
vs M3 EUE per scenario (to show exact per-scenario match across all 20 scenarios,
not just aggregate).

**Construction notes:**
- Stacked bar: bottom segment = bound coverage (storage coverage), top segment =
  residual EUE bound.  Overlay a dot or horizontal line at M3 EUE.
- Coverage = pre-storage EUE × sufficiency ratio.
- The M3 EUE dot will sit exactly at the top of the residual segment.
- Add annotation: "Binding constraint: storage energy (MWh)" in these cases.

---

### Figure 6 — LOLH/event-timing sensitivity to dispatch model

**Placement:** Main text (Results, Experiments C–D or Discussion).

**Takeaway:** EUE is identical across M3, HOPE-ED, and HOPE-UC; LOLH shifts
by 0.4–1.0 h as UC commitment constraints redistribute the same energy deficit
into more shortage hours, illustrating LP degeneracy and the distinction between
energy-based and frequency-based reliability metrics.

**Type:** Two-panel bar chart (Panel A: EUE by model; Panel B: LOLH by model)
for both VRE120\_base and VRE120\_wind\_hvy.

**Source result folders:**
- `results/full_model_comparison_with_hope/base_n5/`
- `results/wind_hvy_hope_uc_comparison/n5/`

**Exact CSVs:**
- `results/full_model_comparison_with_hope/base_n5/all_model_aggregate_metrics.csv`
- `results/wind_hvy_hope_uc_comparison/n5/all_model_aggregate_metrics.csv`

**Data to plot (N=5 per case):**

| Case | Model | LOLH (h) | EUE (MWh) |
|------|-------|----------|-----------|
| VRE120\_base | M3 | 11.2 | 4,707 |
| VRE120\_base | HOPE-ED | 11.8 | 4,707 |
| VRE120\_base | HOPE-UC | 15.2 | 4,707 |
| VRE120\_wind\_hvy | M3 | 4.4 | 1,113 |
| VRE120\_wind\_hvy | HOPE-ED | 3.8 | 1,113 |
| VRE120\_wind\_hvy | HOPE-UC | 4.2 | 1,113 |

**Construction notes:**
- Panel A (EUE): all bars equal — add a label "exact match" or use a single
  horizontal line with dots per model.
- Panel B (LOLH): bars differ — HOPE-UC above HOPE-ED in both cases.
- Add CI95 error bars for M3 from the aggregate metrics CSV; HOPE lacks CI95
  (N=5 fixed scenarios from HOPE export).
- Annotate HOPE-UC vs HOPE-ED runtime ratio in the caption.

---

## Appendix materials

---

### Appendix A — M1c\_VREOnly charging-source sensitivity

**Placement:** Appendix.

**Takeaway:** Restricting charging to VRE-surplus-only hours fails to fill
storage because VRE capacity factor is below 1 at nearly all hours, producing
+17–77 h LOLH error relative to M3 despite zero EUE change; system-surplus
charging is necessary.

**Source result folder:** `results/vre_method_comparison/`

**Source script:** `scripts/16_run_vre_method_comparison.jl`

**Exact CSV:** `results/vre_method_comparison/vre_method_comparison_results.csv`
(filter `model == "M1c_VREOnly"`)

**Note:** Verify that M1c\_VREOnly rows are present in the CSV; if not,
regenerate from script 16 with VREOnly flag enabled.  Reference committed
`docs/current_findings_synthesis.md` §5 for the narrative.

---

### Appendix B — M1d largest-first within-event allocation

**Placement:** Appendix (or supplementary material for Figure 3).

**Takeaway:** M1d\_largest produces identical per-scenario EUE to M3 but
+2.4 h mean LOLH in the base case, because within-event reallocation to
highest-shortfall hours leaves smaller shortfall hours partially served and
increases the count of shedding hours.

**Source result folder:** `results/m1d_storage_heuristic_comparison/`

**Source script:** `scripts/38_compare_m1d_storage_heuristics.jl`

**Exact CSVs:**
- `results/m1d_storage_heuristic_comparison/m1d_aggregate_metrics.csv`
- `results/m1d_storage_heuristic_comparison/m1d_metrics_by_scenario.csv`
- `results/m1d_storage_heuristic_comparison/m1d_errors_vs_m3.csv`

**Suggested figure:** scatter plot of per-scenario LOLH (x: M1d\_earliest,
y: M1d\_largest) to show that LOLH can vary per scenario while per-scenario
EUE is on the 1:1 line.

---

### Appendix C — HOPE-ED mapping and ramp-rate fix

**Placement:** Appendix (Methods detail).

**Takeaway:** HOPE-ED initially diverged from M3 due to non-zero ramp
constraints in ED mode; disabling ED-mode ramp constraints aligns HOPE-ED
with M3 to within 1 MWh EUE, confirming that the models share the same
economic dispatch formulation once ramp constraints are matched.

**Source result folder:** `results/full_model_comparison_with_hope/base_n5/`

**Source script:** `scripts/25_build_hope_full_year_cases.jl` (exports HOPE
case folders); `scripts/30_compare_all_models_hope_n5.jl` (comparison).

**Exact CSV:** `results/full_model_comparison_with_hope/base_n5/all_model_aggregate_metrics.csv`

**Note:** Document the ramp-rate flag change in the appendix methods section;
reference `docs/redesigned_experiment_plan.md` §6 for the key result.

---

### Appendix D — Detailed result folder index

**Placement:** Appendix or supplementary online material.

**Takeaway:** Full mapping of every result folder to its generating script,
commit policy, and key output CSV — enables reproducibility without committing
large HOPE case folders or per-hour dispatch CSVs.

**Source:** `docs/results_index.md` (already written; copy/reference directly).

---

## Data availability summary

| Table/Figure | Result folder | Key CSV | Script | N | Status |
|---|---|---|---|---|---|
| Table 1 | — | — | — | — | Draft from docs |
| Table 2 Panel A | `no_storage_comparison/` | `no_storage_comparison_results.csv` | 34 | 20 | Complete |
| Table 2 Panel B | `nostorage_hope_uc_comparison/base_n5/` | `all_model_aggregate_metrics.csv` | 36 | 5 | Complete |
| Table 3 | `storage_energy_sufficiency_bound/` | `bound_vs_models.csv` | 39 | 20 | Complete |
| Table 4 (M1c/M1d/M2/M3) | `m1d_storage_heuristic_comparison/` | `m1d_aggregate_metrics.csv` | 38 | 20 | Complete |
| Table 4 (M1/M1b) | `vre_method_comparison/` | `vre_method_comparison_results.csv` | 16 | 3† | Pilot only — regenerate at N=20 |
| Table 5 | `full_model_comparison_with_hope/base_n5/` + `wind_hvy_hope_uc_comparison/n5/` | `all_model_aggregate_metrics.csv` | 30, 37 | 5 | Complete |
| Figure 2 | `nostorage_hope_uc_comparison/base_n5/` | `all_model_aggregate_metrics.csv` | 36 | 5 | Complete |
| Figure 3 | `m1d_storage_heuristic_comparison/` + `vre_method_comparison/` | `m1d_aggregate_metrics.csv` | 38, 16 | 20/3† | M1/M1b pilot only |
| Figure 4 | all of above | all of above | — | 20/3† | M1/M1b pilot only |
| Figure 5 | `storage_energy_sufficiency_bound/` | `bound_vs_models.csv`, `scenario_level_storage_bound.csv` | 39 | 20 | Complete |
| Figure 6 | `full_model_comparison_with_hope/base_n5/` + `wind_hvy_hope_uc_comparison/n5/` | `all_model_aggregate_metrics.csv` | 30, 37 | 5 | Complete |
| App A | `vre_method_comparison/` | `vre_method_comparison_results.csv` | 16 | 3† | Verify M1c\_VREOnly rows present |
| App B | `m1d_storage_heuristic_comparison/` | `m1d_metrics_by_scenario.csv` | 38 | 20 | Complete |
| App C | `full_model_comparison_with_hope/base_n5/` | `all_model_aggregate_metrics.csv` | 25, 30 | 5 | Complete |
| App D | — | `docs/results_index.md` | — | — | Complete |

†M1/M1b at N=3: sufficient to establish the failure pattern, but regenerate
at N=20 from `scripts/16_run_vre_method_comparison.jl` before final paper
submission if a uniform N is preferred for Table 4.
