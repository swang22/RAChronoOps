# Market-Pattern Capacity Credit and Runtime Validation

**Date:** 2026-06-15
**Scripts:** `scripts/70_market_pattern_marginal_cc.jl`, `scripts/71_common_runtime_benchmark.jl`
**Purpose:** Document the capacity credit (CC) validation protocol and runtime benchmark
for the two paper-facing market-pattern storage methods.

**Constraint:** `RA-assessment/main.tex` has NOT been edited in this task.
Manuscript values are provisional until research team review.

---

## 1. Capacity Credit Protocol

### Formula

```
CC(δ) = [EUE(x) − EUE(x+ΔS)] / [EUE(x) − EUE(x+ΔF)]
```

where:
- `x` = baseline system (VRE120_base or VRE120_wind_hvy)
- `x+ΔS` = system with δ MW marginal storage (4-hour duration, η_rt=0.90)
- `x+ΔF` = system with δ MW perfect-firm capacity (FOR=0, always available)
- `EUE(·)` = Expected Unserved Energy (MWh/year), mean over N scenarios

The denominator uses an **explicit rerun** with perfect-firm capacity and common random numbers (CRN) — the same scenario trajectories as the baseline.

### Calibration and SOC

| Parameter | Value | Source |
|---|---|---|
| Pattern | `pattern_energy_balanced.csv` | `docs/market_pattern_calibration_audit.md` |
| SOC init | 23.1% (cyclic fixed-point) | `docs/market_pattern_calibration_audit.md` §5 |
| Marginal storage SOC init | 23.1% of unit capacity | Same fixed-point assumption |

The cyclic fixed-point (23.1% SOC) is the annual equilibrium for the energy-balanced
pattern on the RTS-GMLC system. Using this for both the baseline and marginal unit
ensures that neither accumulates or depletes SOC systematically over the year.

### Nested Scenario Sequence

N_MAX = 1000 scenarios are generated once (seed=42). The first N scenarios are
used for all N ∈ {20, 50, 100, 200, 500, 1000}. This ensures that:
- CC estimates are nested (adding scenarios never changes earlier results)
- Bootstrap CI at each N reflects only Monte Carlo variance, not scenario selection
- Convergence plots are monotone in N

### Bootstrap Uncertainty

- 2000 paired bootstrap resamples (fixed seed=1234)
- Resample scenario index with replacement; apply same index to base, +ΔS, +ΔF
- Denominator 95% CI computed separately from the same bootstrap draws
- **Status = "unstable/not identified"** if the denominator 95% CI includes zero,
  meaning the firm-increment effect is not reliably separated from Monte Carlo noise
  at the given N. This is a structural identification problem, not simply noise.

### Finite-Difference Check (δ = 1, 5, 10 MW)

CC is reported for all three δ values. Physical consistency requires that CC should
be approximately independent of δ for small δ (linearity of EUE in storage capacity
for the first few MW). Overlapping bootstrap CIs across δ = 1, 5, 10 MW confirm this.

If CIs diverge significantly across δ values, this indicates either:
1. Nonlinear EUE response (system is near a threshold), or
2. Insufficient N to resolve CC at that δ

---

## 2. Methods Included

| Method | Label | emergency_override | charge_curtailed |
|---|---|---|---|
| MP_pure_cur | Market-pattern storage MCS | false | true |
| MP_emergency_cur | Market-pattern + emergency storage MCS | true | true |
| M1c | Emergency-only storage MCS | — | — |

M1c is the reference benchmark (no market-pattern pattern; always uses emergency
discharge in shortage hours). M2 is optional (`--with-m2` flag) due to runtime.

---

## 3. Output Files

### Primary Outputs

| File | Contents |
|---|---|
| `results/paper_tables/market_pattern_capacity_credit.csv` | Aggregate CC + bootstrap CI for all (portfolio, method, N, δ) |
| `results/paper_tables/market_pattern_table_iv_rows.csv` | Table IV rows: LOLH, EUE, NEUE, CVaR, CC, CI, runtime (N=20) |
| `results/market_pattern_cc/scenario_level_cc_components.csv` | Per-scenario base/stor/firm EUE at N_MAX |
| `results/market_pattern_cc/policy_switching_diagnostics.csv` | EueDecomposition for MP_emergency_cur at N_MAX |
| `results/paper_tables/runtime_common_benchmark.csv` | 5-rep warm-start runtime benchmark (script 71) |

### Columns in `market_pattern_capacity_credit.csv`

| Column | Description |
|---|---|
| portfolio | Case name (VRE120_base / VRE120_wind_hvy) |
| method | MP_pure_cur / MP_emergency_cur / M1c |
| N | Scenario count (20/50/100/200/500/1000) |
| seed | RNG seed (42) |
| delta_mw | Marginal capacity increment (1/5/10 MW) |
| eue_base_mwh | Mean EUE of baseline system |
| eue_storage_increment_mwh | Mean EUE with δ MW storage |
| eue_firm_increment_mwh | Mean EUE with δ MW perfect-firm |
| delta_eue_storage | EUE reduction from storage (numerator) |
| delta_eue_firm | EUE reduction from firm (denominator) |
| cc | Point CC estimate |
| cc_bootstrap_mean | Bootstrap mean CC |
| cc_ci_lo / cc_ci_hi | 95% CI on CC |
| denom_ci_lo / denom_ci_hi | 95% CI on denominator |
| denominator_status | "identified" or "unstable/not identified" |
| n_bootstrap_valid | Number of bootstrap samples with finite CC |
| calibration_version | pattern_energy_balanced |
| code_commit | Git short SHA at time of run |

### Note on `runtime_median` and `runtime_IQR` in Table IV rows

`market_pattern_table_iv_rows.csv` is generated by script 70.
The `runtime_median` column contains a rough estimate (total N_MAX runtime / N_MAX).
The `runtime_IQR` column is NaN.

**For paper-quality runtime figures**, run script 71 and join on (portfolio, method):
```
runtime_common_benchmark.csv → median_rt_s_per_scenario, iqr_rt_s_per_scenario
```

---

## 4. Policy Switching Diagnostics (MP_emergency_cur)

`policy_switching_diagnostics.csv` records the `EueDecomposition` struct from
`run_market_pattern_storage` for MP_emergency_cur at N_MAX scenarios.

Key fields:

| Field | Meaning |
|---|---|
| pre_storage_shortfall_eue | EUE in hours where emergency override could trigger |
| missed_discharge_eue | EUE remaining after emergency override (SOC constraint binding) |
| charging_induced_eue | EUE from charging beyond surplus (0 by construction for charge_curtailed=true) |
| low_soc_shortfall_eue | EUE in shortage hours where SOC < 25% E_max |

`missed_discharge_eue > 0` indicates that even with emergency override, the battery
could not eliminate all EUE because the SOC was depleted at the time of shortage.
With the energy-balanced pattern and cyclic SOC init = 23.1%, the battery maintains
some stored energy throughout the year, reducing missed discharge compared to the
raw pattern (which depletes to 0% by month 4).

---

## 5. Runtime Benchmark Protocol (script 71)

Script `71_common_runtime_benchmark.jl` times 7 methods on both portfolios:

1. Load case data and generate N=20 scenarios **outside** the timed block.
2. Run each method once as a warm-up (JIT compilation + first scenario set).
3. Time dispatch-only for **5 repetitions** using wall-clock time.
4. Report **median and IQR** (Q3 − Q1) per scenario.

The IQR captures garbage-collection and OS scheduling jitter without contamination
from JIT compilation (warm-up is excluded). Median is preferred over mean for the
paper table because it is robust to occasional slow outlier runs.

M2 and M3 use the same number of reps as fast methods (5) unless `--skip-m3` is
passed (M3 is included but takes longer; 3 reps default for M3).

---

## 6. Provisional CC Estimates

Prior CC values (raw pattern, 50% fixed SOC, N=20) for reference:

| Portfolio | Method | Prior CC | Expected direction of change |
|---|---|---|---|
| VRE120_base | MP_pure_cur | 0.143 | ~unchanged (robust to calibration) |
| VRE120_base | MP_emergency_cur | 0.336 | Likely higher (calibration increases SOC) |
| VRE120_wind_hvy | MP_pure_cur | 0.128 | ~unchanged |
| VRE120_wind_hvy | MP_emergency_cur | 0.430 | Likely higher |

MP_pure_cur CC is expected to be nearly unchanged because EUE is robust to
calibration (<2% variation in Table IV). MP_emergency_cur CC may shift up because
the energy-balanced calibration increases available SOC in shortage hours, reducing
base EUE more than storage-augmented EUE (widening the numerator).

**Run script 70 to obtain validated CC values before updating the manuscript.**

---

## 7. Required Actions Before Manuscript Update

1. Run `scripts/70_market_pattern_marginal_cc.jl` (N_MAX=1000 run takes ~5–15 min).
2. Run `scripts/71_common_runtime_benchmark.jl` for calibrated timing.
3. Join `market_pattern_table_iv_rows.csv` with `runtime_common_benchmark.csv` on
   (portfolio, method) to fill in `runtime_median` and `runtime_IQR`.
4. Review CC denominator status: any "unstable/not identified" at N=20 means CC
   should be reported with wider CIs or at larger N for the paper.
5. Review with research team before editing `RA-assessment/main.tex`.
