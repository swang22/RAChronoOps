# Storage-Energy Sufficiency Bound

**Date:** 2026-05-21

---

## 1. Purpose

The storage-energy sufficiency bound is a per-scenario diagnostic that asks:
**how much of the pre-storage energy deficit could storage theoretically cover,
given the surplus energy available before each shortage event?**

It provides a theoretical ceiling on EUE reduction from storage and explains
why simple dispatch heuristics (M1c, M1d) and the event-window LP (M2) all
converge to the same EUE as the full-year ED LP (M3).

---

## 2. Formula

For each shortage event in each Monte Carlo scenario:

```
pre_storage_eue_mwh        = Σ max(0, load[h] − thermal_avail[h] − VRE[h])
                               for h in [event_start, event_end]

feasible_charge_mwh        = SOC accumulated by greedy charging from surplus
                               in the lookback window [event_start − L, event_start − 1]
                               (default L = 72 h)

feasible_discharge_energy  = min(storage_energy_mwh, feasible_charge_mwh) × η_dis

power_limited_coverage     = Σ min(pre_shortfall[h], storage_power_mw)
                               for h in [event_start, event_end]

storage_coverage_bound     = min(pre_storage_eue_mwh,
                                  feasible_discharge_energy,
                                  power_limited_coverage)

residual_eue_bound         = pre_storage_eue_mwh − storage_coverage_bound
```

The scenario-level residual bound is the sum of residual_eue_bound across all
events in the scenario.

---

## 3. Why it is not a replacement for dispatch

The bound is **optimistic** in one key respect: it resets SOC to `initial_soc`
at the start of each event's lookback window, ignoring energy consumed in prior
events.  In scenarios with multiple shortage events, the actual SOC entering
the second event may be lower than `initial_soc` because some energy was
discharged in the first event.

As a result, the bound may slightly overstate storage coverage when multiple
events occur in the same scenario.  In the tested cases (N=20, seed=42) the
bound matches M3 EUE exactly per scenario, which confirms that either:
(a) scenarios with multiple events have sufficient surplus between events to
    fully recharge before the next one, or
(b) most scenarios have only one dominant event.

The bound is a **diagnostic**, not a dispatch algorithm.  It does not produce
hourly load_shed, SOC, or charge/discharge trajectories.

---

## 4. How it supports the design principle for storage-aware MC

The bound has three terms inside `min()`:

| Term | What it captures |
|------|-----------------|
| `pre_storage_eue_mwh` | Upper ceiling — total energy deficit in the event |
| `feasible_discharge_energy` | Storage energy limit (MWh × η_dis) |
| `power_limited_coverage` | Storage power limit (sum of MW caps per hour) |

When **bound ≈ M3 EUE**, the system is operating near the energy limit.
In the tested RTS-GMLC single-zone cases, any dispatch model that:
1. charges from surplus before shortage events, and
2. discharges only during shortage events,

will approach M3's EUE — because in these tested cases there is no additional
EUE reduction available beyond what the energy budget allows.  This finding is
empirical and scoped to the tested system configurations; it should not be
interpreted as a universal equivalence for all storage configurations or
shortage patterns.

This observation motivates the **M1c design principle**:
_discharge only at shortfall hours, charge from system surplus_.  Proactive
discharge (M1, M1b) depletes SOC before shortage events, moving away from the
bound and introducing a positive LOLH bias without changing the actual energy
budget.

---

## 5. Main findings

**Experiment: VRE120_base and VRE120_wind_hvy, N=20, seed=42, lookback=72h**

| Case | Pre-storage EUE | Bound EUE | M3 EUE | Bound − M3 | Sufficiency ratio |
|------|----------------|-----------|--------|-----------|-------------------|
| VRE120_base | 31,017 MWh | 2,479 MWh | 2,479 MWh | 0.00 MWh | 0.941 |
| VRE120_wind_hvy | 15,801 MWh | 648 MWh | 648 MWh | 0.00 MWh | 0.972 |

**Key observations:**

1. **The bound matches M3 EUE exactly** (per scenario, to machine precision) in
   both cases.  This confirms that M3 achieves the theoretical maximum EUE
   reduction from storage given the pre-storage deficit and the 72-hour charging
   horizon.

2. **M1c and M2 also match the bound**, because both charge from surplus and
   discharge at shortage hours — the minimum conditions for achieving the bound.

3. **VRE120_base is harder** (pre-storage EUE = 31,017 MWh vs 15,801 MWh for
   VRE120_wind_hvy).  Higher wind penetration reduces net load and shortage event
   severity.

4. **VRE120_wind_hvy has a higher sufficiency ratio** (0.972 vs 0.941):
   storage covers a larger fraction of its smaller pre-storage EUE.  This means
   shortage events are more often fully coverable by the storage budget,
   producing a less severe residual EUE distribution.

5. **The binding constraint is energy, not power.**  When the bound is applied,
   the `min()` is dominated by `feasible_discharge_energy` (term b) rather than
   `power_limited_coverage` (term c), indicating that the storage power limit is
   not the bottleneck in the tested system configuration (983 MW / 3,932 MWh).

---

## 6. Output files

All outputs are in `results/storage_energy_sufficiency_bound/`:

| File | Contents |
|------|----------|
| `event_level_storage_bound.csv` | Per-event bound details (all three min-terms) |
| `scenario_level_storage_bound.csv` | Per-scenario aggregates and sufficiency ratio |
| `bound_vs_models.csv` | Side-by-side bound vs M1c/M2/M3 per scenario |
| `summary.txt` | Narrative Q&A and per-scenario tables |

Generated by: `scripts/39_storage_energy_sufficiency_bound.jl`
