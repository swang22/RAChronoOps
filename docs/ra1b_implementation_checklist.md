# RA-1b Implementation Checklist

Pre-implementation specification for the reserve-aware chronological
storage heuristic (RA-1b / M1b).  Work through this checklist before
writing model code to catch design questions early.

Related files:
- Placeholder: `src/models/M1bReserveAwareStorage.jl`
- Config: `configs/m1b.yaml`
- Reference implementation (RA-1a): `src/models/M1RuleBasedStorage.jl`
- Experiment plan: `docs/redesigned_experiment_plan.md`, Section 8, Task 1

---

## 1. Purpose

RA-1b is a sequential Monte Carlo resource adequacy method with no
optimization.  It improves on RA-1a / M1 by preventing proactive
peak-shaving from depleting storage before genuine shortage events.

**Key insight from RA-1a diagnosis:** the RA-1a Priority-2 rule fires at
roughly 25% of hours (all hours where net load ≥ Q0.75) and exhausts
storage SOC before every shortage event.  Priority-1 emergency discharge
fires zero times in practice.  RA-1b adds a SOC reserve floor that
suppresses Priority-2 when SOC is too low, keeping energy available for
Priority-1 emergencies.

---

## 2. Inputs

| Input | Source | Notes |
|-------|--------|-------|
| `system::SystemData` | `load_system_data(case_dir)` | generators, storage, hourly profiles |
| `scenarios::ScenarioSet` | `generate_scenarios(system, config)` | shared with RA-1a and RA-3 (CRN) |
| `config::SimConfig` | `load_config("configs/m1b.yaml")` | see parameters below |

**Config parameters used by RA-1b** (from `configs/m1b.yaml`):

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `reserve_fraction` | 0.50 | Fraction of `total_energy_mwh` held in reserve for Priority-1 emergency use.  Priority-2 cannot discharge below this floor. |
| `high_net_load_quantile` | 0.75 | Quantile of the net-load distribution that defines the Priority-2 trigger threshold. |
| `charge_net_load_quantile` | 0.25 | Quantile of the net-load distribution that defines the Priority-3 charge trigger. |
| `save_dispatch` | false | Whether to write hourly dispatch to CSV. |

Note: `reserve_fraction` is not yet a field of `SimConfig`.  It must be
added to `src/utils/Config.jl` before implementing the dispatch loop.

---

## 3. Algorithm

### 3.1 Pre-scenario setup (same as RA-1a)

1. Aggregate storage parameters from `system.storage`:
   - `total_power  = sum(stor.power_mw)`
   - `total_energy = sum(stor.energy_mwh)`
   - `init_soc     = sum(stor.initial_soc_mwh)`
   - `eta_ch       = mean(stor.charge_efficiency)`
   - `eta_dis      = mean(stor.discharge_efficiency)`

2. Pre-compute hourly VRE output:
   ```
   p_vre[h] = wind_cf[h] × wind_capacity_mw + solar_cf[h] × solar_capacity_mw
   ```

3. Pre-compute hourly net load:
   ```
   net_load[h] = load_mw[h] - p_vre[h]
   ```

4. Compute rule thresholds from the unconditional net-load distribution:
   ```
   high_nl_thresh   = quantile(net_load, high_net_load_quantile)   # P2 discharge trigger
   charge_nl_thresh = quantile(net_load, charge_net_load_quantile) # P3 charge trigger
   ```

5. Compute the SOC reserve floor (scalar, constant across hours):
   ```
   soc_floor = reserve_fraction × total_energy
   ```

### 3.2 Per-scenario dispatch loop

For each scenario `s` in `1:n_scenarios`:

Initialize: `curr_soc = init_soc`

For each hour `h` in `1:n_hours`:

#### Step A — Compute available supply

```
therm_avail[h] = sum over thermal generators g:
                    pmax[g] × availability[s, g, h]

net_supply[h]  = therm_avail[h] + p_vre[h]

shortfall_pre  = max(0, load_mw[h] - net_supply[h])
```

#### Step B — Priority 1: emergency discharge

If `shortfall_pre > 0` and `total_power > 0`:

```
max_dis = min(total_power, curr_soc × eta_dis)
dis     = min(shortfall_pre, max_dis)
curr_soc -= dis / eta_dis
```

Priority 1 **may** discharge below `soc_floor` because it is an
emergency.  The reserve floor does not apply here.

`chg = 0`

#### Step C — Priority 2: reserve-aware proactive discharge

Else if `net_load[h] >= high_nl_thresh` and `curr_soc > soc_floor`
and `total_power > 0`:

```
# Only energy above the reserve floor is available for P2
available_above_floor = (curr_soc - soc_floor) × eta_dis
max_dis = min(total_power, available_above_floor)
dis     = max_dis       # discharge as much as allowed
curr_soc -= dis / eta_dis
```

Do not discharge below `soc_floor`.  If `curr_soc <= soc_floor`,
Priority-2 fires zero discharge (effectively skipped).

`chg = 0`

#### Step D — Priority 3: charge during low net-load / surplus hours

If `dis == 0` and `net_load[h] <= charge_nl_thresh` and `total_power > 0`:

```
surplus  = net_supply[h] - load_mw[h]    # >= 0 when net_load ≤ thresh
headroom = total_energy - curr_soc
if surplus > 0 and headroom > 0:
    max_chg = min(total_power, surplus, headroom / eta_ch)
    chg     = max(0, max_chg)
    curr_soc += chg × eta_ch
```

#### Step E — SOC clamp and power balance

```
curr_soc    = clamp(curr_soc, 0, total_energy)   # floating-point safety
soc[h]      = curr_soc
st_dis[h]   = dis
st_chg[h]   = chg
net_bal     = net_supply[h] + dis - chg - load_mw[h]
load_shed[h]  = max(0, -net_bal)
curtailment[h] = max(0,  net_bal)
```

### 3.3 Return value

Return `Vector{DispatchResult}` (one per scenario), identical struct to
RA-1a.  `thermal_dispatch` field should be `nothing` (no per-unit
breakdown).

---

## 4. Behavioral contracts

These are the invariants the implementation must satisfy.  They map
directly to the validation tests in Section 6.

| Contract | Notes |
|----------|-------|
| SOC is always in `[0, total_energy]` after every hour | Enforced by clamp in Step E |
| Priority-2 never discharges below `soc_floor` | Enforced by `available_above_floor` in Step C |
| Priority-1 **can** discharge below `soc_floor` | No floor in Step B |
| If `reserve_fraction = 0`, RA-1b behavior ≈ RA-1a | `soc_floor = 0`; P2 identical to M1 |
| If `reserve_fraction = 1`, Priority-2 is disabled | `soc_floor = total_energy`; `available_above_floor ≤ 0` always |
| Storage parameters read correctly per case | `total_power`, `total_energy` must differ across `p05_d4` vs `p20_d4` cases |
| RA-1b LOLH ≤ RA-1a LOLH (same scenarios, same case) | Reserve floor should reduce unnecessary P2 depletion |
| RA-1b LOLH ≥ RA-3 LOLH (same scenarios, same case) | RA-3 has perfect foresight; heuristic cannot beat it |

---

## 5. Implementation steps

- [ ] **5.1** Add `reserve_fraction::Float64 = 0.50` to `SimConfig` in
  `src/utils/Config.jl`.  Confirm `load_config("configs/m1b.yaml")` reads
  it correctly.

- [ ] **5.2** Replace the throwing body of `run_m1b_reserve_aware` in
  `src/models/M1bReserveAwareStorage.jl` with the dispatch loop above.
  Copy the M1 outer structure (scenario loop, hour loop, result struct)
  and change only the Priority-2 block.

- [ ] **5.3** Add a `ScenarioSet` overload (same pattern as M1):
  ```julia
  run_m1b_reserve_aware(system, scenarios::ScenarioSet, config) =
      run_m1b_reserve_aware(system, scenarios.availability, config)
  ```

- [ ] **5.4** Run `Pkg.test()`.  All existing 23,051 tests must still pass
  (no regressions from adding `reserve_fraction` to `SimConfig`).

- [ ] **5.5** Write `scripts/14_run_ra1b_validation.jl` to compare RA-1a,
  RA-1b, and RA-3 on `storage120_p10_d4` at N=50.

---

## 6. Validation tests to add

These should become `@testset` blocks in `test/test_storage.jl` or a new
`test/test_ra1b.jl`.  Do not implement yet — implement alongside the model.

| # | Test | Pass condition |
|---|------|----------------|
| 1 | Storage parameters read correctly | `total_power` and `total_energy` differ between `p05_d4` (492 MW / 1,968 MWh) and `p20_d4` (1,966 MW / 7,864 MWh) synthetic cases |
| 2 | SOC bounds never violated | `all(0 ≤ soc[h] ≤ total_energy)` across all scenarios and hours |
| 3 | Priority-2 never discharges below `soc_floor` | For each hour where `dis > 0` and `shortfall_pre == 0`: `soc_before_dis - dis/eta_dis ≥ soc_floor - ε` |
| 4 | Priority-1 can discharge below `soc_floor` | Inject a forced-shortage scenario; confirm `soc` drops below `reserve_fraction × total_energy` during that hour |
| 5 | Storage-sensitive reliability | LOLH differs between `p05_d4` and `p20_d4` synthetic cases (unlike RA-1a which is insensitive) |
| 6 | RA-1b improves on RA-1a | RA-1b LOLH < RA-1a LOLH on the reference case `storage120_p10_d4` at N=50 |
| 7 | RA-1b does not beat RA-3 | RA-1b LOLH ≥ RA-3 LOLH on the reference case at N=50 |

---

## 7. Edge cases to handle

| Edge case | Correct behavior |
|-----------|-----------------|
| No storage (`n_stor == 0`) | `total_power = total_energy = 0`; all three priorities are no-ops; behavior identical to M1 |
| `curr_soc = 0` at P1 | `max_dis = 0`; `dis = 0`; no crash |
| `curr_soc = soc_floor` at P2 | `available_above_floor = 0`; `dis = 0`; no discharge |
| Surplus but SOC full | `headroom = 0`; P3 charge is zero |
| Simultaneous shortfall and VRE surplus | P1 fires (shortfall_pre > 0); P3 does not fire in same hour |

---

*Document version: pre-implementation specification.*
*Link to algorithm source of truth: `src/models/M1RuleBasedStorage.jl` (RA-1a reference).*
