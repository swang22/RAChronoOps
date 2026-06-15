# Table IV Source Audit — Market-Pattern Storage MCS

**Date:** 2026-06-14
**Purpose:** Reconcile the LOLH discrepancy between current market-pattern result files
and the manuscript Table IV before incorporating new rows.

---

## 1. Current Table IV Source Files

| Table IV Row | Source script | Source CSV | Key config |
|---|---|---|---|
| Naive Storage MCS | `scripts/41_run_m1_m1b_n20_for_paper.jl` | `results/m1_m1b_n20_paper/m1_m1b_aggregate_metrics.csv` | N=20, seed=42 |
| Reserve-Floor Storage MCS | same | same | N=20, seed=42 |
| Emergency-Only Storage MCS | `scripts/38_compare_m1d_storage_heuristics.jl` | `results/m1d_storage_heuristic_comparison/m1d_aggregate_metrics.csv` | N=20, seed=42, M2: risk=1000 MW, buf=48 h |
| Risk-Hour Allocation MCS (earliest) | same | same | same |
| Risk-Hour Allocation MCS (largest) | same | same | same |
| Event-Window Storage MCS | same | same | **N=20, seed=42, risk_margin=1000 MW, window_buffer=48 h** |
| Full-Year ED | same | same | N=20, seed=42 |
| PCM-UCED | `scripts/hope_pcm/` series | `results/paper_tables/pcm_uced_marginal_cc.csv`, `paper_hope_validation.csv` | N=20, seed=42, HOPE-UC |

### Exact Table IV values (from source CSVs)

**Balanced VRE (VRE120_base, N=20, seed=42):**

| Method | LOLH (h) | EUE (MWh) | CVaR-EUE (MWh) | Runtime (s/scenario) |
|---|---|---|---|---|
| Emergency-only storage MCS | 5.95 | 2479.17 | 9782.93 | 0.063 |
| Event-window storage MCS | **5.75** | 2479.17 | 9782.93 | 0.434 |
| Full-year ED | 5.95 | 2479.17 | 9782.93 | 9.557 |
| PCM-UCED | 7.25 | 2479.17 | 9782.93 | 571.9 |

**Wind-heavy (VRE120_wind_hvy, N=20, seed=42):**

| Method | LOLH (h) | EUE (MWh) | CVaR-EUE (MWh) | Runtime (s/scenario) |
|---|---|---|---|---|
| Emergency-only storage MCS | 2.25 | 648.24 | 3528.39 | 0.071 |
| Event-window storage MCS | **1.95** | 648.24 | 3528.39 | 0.382 |
| Full-year ED | 2.25 | 648.24 | 3528.39 | 9.219 |
| PCM-UCED | 2.65 | 659.97 | 3624.4 | 2820.0 |

---

## 2. Market-Pattern Diagnostic Files (current)

| File | Source script | Key config |
|---|---|---|
| `results/paper_tables/market_pattern_storage_results.csv` | `scripts/68_diagnose_market_pattern_storage.jl` | N=20, seed=42, **M2: risk=500 MW (default), buf=24 h (default)** |
| `results/paper_tables/market_pattern_eue_decomposition.csv` | same | same |
| `results/market_pattern_storage/soc_diagnostics.csv` | same | same |
| `results/paper_tables/market_pattern_event_start_soc.csv` | `scripts/69_event_start_soc.jl` | N=20, seed=42, **M2: risk=500, buf=24** |

### Current market-pattern M1c and M2 comparison values

| Method | Case | LOLH (h) | EUE (MWh) | Source |
|---|---|---|---|---|
| Emergency-only storage MCS | Balanced VRE | 5.95 | 2479.17 | script 68 (matches Table IV ✓) |
| Event-window storage MCS | Balanced VRE | **5.10** | 2479.17 | script 68 |
| Emergency-only storage MCS | Wind-heavy | 2.25 | 648.24 | script 68 (matches Table IV ✓) |
| Event-window storage MCS | Wind-heavy | **1.75** | 648.24 | script 68 |

---

## 3. Root Cause of the LOLH Discrepancy

The discrepancy is entirely explained by a single configuration difference in the
event-window storage MCS parameters:

| Parameter | Table IV value (script 38) | Script 68 value | Effect |
|---|---|---|---|
| `risk_margin_mw` | **1000 MW** | 500 MW (default) | Wider risk window with 1000 MW → more hours flagged |
| `window_buffer_hours` | **48 h** | 24 h (default) | Larger buffer → larger LP windows |
| `merge_gap_hours` | 24 h | 24 h | Same |
| `min_window_length_hours` | 24 h | 24 h | Same |

With `risk_margin = 1000 MW` and `window_buffer = 48 h`, the LP windows are larger and
more conservative, leading to higher LOLH (5.75 h vs 5.10 h for balanced VRE) while
maintaining identical EUE (the LP always finds the same minimum total unserved energy).

This is consistent with the documented event-window parameter sensitivity:
`results/paper_tables/event_window_parameter_sensitivity.csv` shows that
(risk=1000, buf=48) gives balanced VRE LOLH = 11.2 h at N=5, and
(risk=500, buf=24) gives LOLH = 9.6 h at N=5 — the same directional effect.

**No bug exists. The two scripts simply use different M2 configuration parameters.**

---

## 4. EUE Values — No Discrepancy

EUE values are identical across Table IV and script 68 for M1c and M2:
- Balanced VRE: 2479.17 MWh in both sources
- Wind-heavy: 648.24 MWh in both sources

EUE is configuration-independent for these methods because:
- M1c and M2 both achieve the same scenario-optimal total unserved energy
- The LP finds optimal EUE regardless of window configuration
- LOLH varies because window config affects which hours load shedding concentrates into

---

## 5. Source File for Each Table IV Number

**NEUE denominator:** Computed inline from `system.load_mw` vector sum.
From calibration: balanced VRE annual load ≈ 45,047 GWh → NEUE = EUE / 45,047e3 × 1e6 ppm.
(Exact value computed by `compute_metrics()` using the loaded system data.)

**Capacity credit:** `results/paper_tables/marginal_cc_all_methods_n20.csv` (script 61).
For wind-heavy: M1c CC = 0.604, M2 CC = 0.604, M3 CC = 0.604.
For balanced VRE: `results/paper_tables/storage_marginal_capacity_credit.csv` (different
script); CC = 1.116 for M1c — this value uses a different firm-increment convention
and should be confirmed before using in Table IV.

**Runtimes:** From source CSVs listed above. Note: these are NOT warm-start runtimes —
they include Julia JIT time in some early scripts. See Part D runtime benchmark.

---

## 6. Recommended Common Source of Truth

**For all Table IV experiments (including new market-pattern rows):**

Use `risk_margin_mw = 1000.0, window_buffer_hours = 48` for event-window storage MCS.
This is the configuration used in script 38 and reflected in the published Table IV values.

**Action items before running new experiments:**
1. Rerun script 68 with `m2_risk=1000, m2_buf=48` to regenerate M1c and M2 comparison
   values with correct M2 configuration.
2. Use the same N=20, seed=42 for all new market-pattern rows.
3. Use the same scenario trajectories (same ScenarioSet generated from seed=42).
4. Do NOT use runtimes from script 68 in Table IV — see Part D runtime benchmark.

**Do not overwrite existing Table IV source files** until the new market-pattern rows
are validated and approved for the manuscript.

---

## 7. Mapping of New Market-Pattern Rows to Source

| New Table IV row | Method | Paper-facing variant |
|---|---|---|
| Market-pattern storage MCS | MP_pure_cur (charge-curtailed, no emergency) | Paper-facing (lower bound) |
| Market-pattern + emergency MCS | MP_emergency_cur (charge-curtailed + emergency) | Paper-facing (recommended) |

Internal/diagnostic only (not in Table IV):
- MP_pure (uncurtailed) — artificial load shedding artifact
- MP_emergency (uncurtailed) — artificial load shedding artifact

Source script for new rows: `scripts/70_market_pattern_marginal_cc.jl`
Output: `results/paper_tables/market_pattern_table_iv_rows.csv`
