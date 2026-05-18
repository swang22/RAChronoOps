# M1c Charging-Assumption Sensitivity Memo

**Date:** 2026-05-17  
**N = 20 scenarios, seed = 42**  
**Cases:** VRE120_base, VRE120_bal15, VRE120_wind_hvy  
**Reference:** M3 economic-dispatch (Gurobi LP)

---

## 1. Background

M1c (RA-1c, "emergency-only") is a rule-based storage heuristic that charges
whenever `net_supply > load` (thermal headroom included) and discharges only to
cover observed pre-storage shortfalls.  A stricter interpretation — "storage as
renewable firming" — would restrict charging to hours when VRE output alone
exceeds load, i.e. `p_vre[h] > load[h]`.  We call this variant M1c_VREOnly.

This memo quantifies how much the charging-source assumption affects accuracy.

---

## 2. Model definitions

| Model | Discharge rule | Charging rule |
|---|---|---|
| **M1c_current** | P1 only: cover pre-storage shortfall | Any surplus: `net_supply > load` (thermal headroom included) |
| **M1c_VREOnly** | P1 only: cover pre-storage shortfall | VRE surplus only: `p_vre[h] > load[h]` |
| **M3** | ED LP (Gurobi) with storage cycling cost 0.01 $/MWh | ED LP (Gurobi) |

Both M1c variants share identical P1 discharge logic.  The only difference is
the charging condition.

---

## 3. Results

### 3.1 Aggregate reliability metrics

| Case | Model | LOLH (h) | LOLP (%) | EUE (MWh) | CVaR-EUE | Runtime |
|---|---|---:|---:|---:|---:|---:|
| VRE120_base | M1c_current | **5.95** | 0.068 | **2,479** | 9,783 | 1.5 s |
| VRE120_base | M1c_VREOnly | 82.80 | 0.945 | 28,180 | 49,100 | 1.5 s |
| VRE120_base | M3 | **5.95** | 0.068 | **2,479** | 9,783 | 194 s |
| VRE120_bal15 | M1c_current | **1.35** | 0.015 | **360** | 2,722 | 2.2 s |
| VRE120_bal15 | M1c_VREOnly | 35.45 | 0.405 | 11,186 | 22,184 | 1.4 s |
| VRE120_bal15 | M3 | **1.35** | 0.015 | **360** | 2,722 | 194 s |
| VRE120_wind_hvy | M1c_current | **2.25** | 0.026 | **648** | 3,528 | 1.5 s |
| VRE120_wind_hvy | M1c_VREOnly | 19.25 | 0.220 | 7,392 | 19,195 | 1.2 s |
| VRE120_wind_hvy | M3 | **2.25** | 0.026 | **648** | 3,528 | 188 s |

### 3.2 Error vs M3 benchmark

| Case | Method | LOLH error (h) | Relative error | EUE error (MWh) |
|---|---|---:|---:|---:|
| VRE120_base | M1c_current | **+0.00** | **+0.0%** | **0** |
| VRE120_base | M1c_VREOnly | +76.85 | +1292% | +25,700 |
| VRE120_bal15 | M1c_current | **+0.00** | **+0.0%** | **0** |
| VRE120_bal15 | M1c_VREOnly | +34.10 | +2526% | +10,826 |
| VRE120_wind_hvy | M1c_current | **+0.00** | **+0.0%** | **0** |
| VRE120_wind_hvy | M1c_VREOnly | +17.00 | +756% | +6,744 |

M1c_current matches M3 exactly (LOLH error = 0.00 h) across all three cases at
90–130× speedup.  M1c_VREOnly has mean absolute LOLH error of **42.7 h** —
roughly 10× the M3 LOLH itself in the base case.

### 3.3 Event-structure metrics

| Case | Model | n_events | mean_dur (h) | MaxSF (MW) |
|---|---|---:|---:|---:|
| VRE120_base | M1c_current | 2.0 | 2.98 | 461 |
| VRE120_base | M1c_VREOnly | 22.6 | 3.67 | 1,000 |
| VRE120_base | M3 | 2.0 | 2.98 | 461 |
| VRE120_bal15 | M1c_current | 0.6 | 2.25 | 148 |
| VRE120_bal15 | M1c_VREOnly | 12.7 | 2.79 | 801 |
| VRE120_bal15 | M3 | 0.6 | 2.25 | 148 |
| VRE120_wind_hvy | M1c_current | 0.8 | 2.65 | 226 |
| VRE120_wind_hvy | M1c_VREOnly | 6.0 | 3.21 | 735 |
| VRE120_wind_hvy | M3 | 0.8 | 2.65 | 226 |

M1c_current reproduces M3 event count and severity exactly.  M1c_VREOnly
produces 7–11× more shortage events with higher max shortfalls.

---

## 4. Why does charging source matter so much?

In the VRE120 cases at current load scale, VRE output alone rarely exceeds
system load: the wind and solar profiles were sized to contribute roughly 30–50%
of energy on average, not to cover peak demand.  As confirmed in script 22
diagnostics:

- **VRE120_base/bal15:** 100% of M1c's charging comes from thermal headroom
  hours; p_vre < load at virtually every hour.
- **VRE120_wind_hvy:** ~87% of M1c charging is from thermal headroom; only
  ~13% from genuine VRE curtailment.

M1c_VREOnly therefore finds almost no charging opportunities and arrives at
shortage events with near-zero SOC.  The battery never stores energy, so it
cannot discharge during outages — effectively reducing to a no-storage baseline.

The wind-heavy case improves relative to base (error 17 h vs. 77 h) because the
higher wind penetration creates slightly more hours with `p_vre > load`, but
this is still grossly insufficient.

---

## 5. Comparison with M1b

From script 21 (N=20, same seed):

| Case | M1b LOLH error | M1c_VREOnly LOLH error |
|---|---:|---:|
| VRE120_base | +77.60 h | +76.85 h |
| VRE120_bal15 | +35.40 h | +34.10 h |
| VRE120_wind_hvy | +22.75 h | +17.00 h |

M1c_VREOnly performs marginally better than M1b across all three cases (by
0.75–5.75 h).  Both are far from M3 and far from M1c_current.  The marginal
advantage of VRE-only over M1b does not justify the complexity of tracking
wind/solar capacity factors separately from the rule-based dispatch.

---

## 6. Research questions answered

**Q1. Does VRE-only charging break the exact M1c = M3 LOLH match?**  
Yes, decisively.  Error jumps from 0.00 h to 17–77 h depending on case.

**Q2. How much worse is VRE-only?**  
755–2526% relative LOLH error; 11–28× higher EUE.  The match is completely
destroyed.

**Q3. Which cases are most sensitive?**  
VRE120_base is most sensitive (76.85 h error), then bal15 (34.10 h), then
wind_hvy (17.00 h).  Sensitivity decreases as wind penetration increases,
because more hours have genuine VRE surplus.

**Q4. Does VRE-only M1c outperform M1b?**  
Marginally (by <6 h in LOLH), but both are unusable as reliability benchmarks
at this VRE penetration level.

**Q5. Which formulation to present in the paper?**  
**M1c_current** (thermal-headroom-inclusive charging) is the only viable
candidate.  Its charging behavior is consistent with M3's economic dispatch,
which also charges predominantly from non-VRE-surplus hours (87–100% in
VRE120, per script 22 diagnostics).  M1c_VREOnly should appear as an appendix
sensitivity to explain why the charging-source assumption is not arbitrary.

---

## 7. Interpretation and paper guidance

The correct interpretation of M1c's charging rule is not "storage-as-renewable-
firming" but rather **"storage fills whenever the system has surplus capacity"**
— which is what a cost-minimizing ED dispatch also does when cycling cost is
near zero.  In VRE120 cases:

- M3 charges ~97% of the time from non-VRE-surplus hours (thermal arbitrage).
- M1c_current charges ~100% from thermal headroom.
- Both end up with high SOC at shortage event starts, enabling P1 discharge.

The match between M1c and M3 is thus not an accident of VRE surplus but a
consequence of **both models filling storage from the same dominant surplus
source (thermal headroom)**, even though their strategies differ entirely.

For the paper, this result is evidence that:
1. The charging-source assumption in rule-based heuristics matters enormously.
2. A "renewable firming" heuristic is inappropriate for systems where VRE
   rarely curtails (current load scale).
3. M1c_current is a legitimate fast approximation because it implicitly mimics
   the ED charging pattern that dominates in thermally-heavy systems.

---

## 8. Files

| File | Description |
|---|---|
| `results/m1c_charging_assumptions/base-bal15-wind_hvy_n20/m1c_charging_assumption_results.csv` | Full metrics table |
| `results/m1c_charging_assumptions/base-bal15-wind_hvy_n20/m1c_charging_assumption_errors.csv` | Error vs M3 |
| `results/m1c_charging_assumptions/base-bal15-wind_hvy_n20/summary.txt` | Full text summary with Q&A |
| `src/models/M1cVREOnlyCharge.jl` | M1c_VREOnly implementation |
| `scripts/23_compare_m1c_charging_assumptions.jl` | Comparison script |
