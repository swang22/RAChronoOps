# ── RA-1b / M1b: Reserve-aware chronological storage heuristic ────────────
#
# Purpose:
#   Sequential Monte Carlo resource adequacy assessment using a rule-based
#   storage dispatch heuristic that reserves an emergency SOC floor.
#   Fixes the core failure of RA-1a / M1: naive peak-shaving depletes storage
#   before shortage events.  The SOC guard suppresses proactive discharge when
#   storage is below the reserve threshold, keeping energy available for
#   genuine scarcity events.
#
# Intended dispatch priority order (applied each hour sequentially):
#   Priority 1 — Emergency discharge: if thermal + VRE cannot cover load,
#     discharge storage up to the shortfall (irrespective of SOC floor).
#   Priority 2 — Optional peak-shaving discharge: if net load exceeds the
#     high_net_load_quantile threshold AND current SOC > reserve_fraction ×
#     total_energy, discharge at full power.  The SOC guard is the key
#     difference from RA-1a / M1: priority-2 is silenced when SOC is low.
#   Priority 3 — Valley-filling charge: if net load is below the
#     charge_net_load_quantile threshold and surplus generation exists,
#     charge storage.
#
# Planned configuration parameter:
#   reserve_fraction  — fraction of total storage energy (MWh) to hold in
#                       reserve for emergency (Priority 1) use.
#                       Default: 0.50.
#                       Priority 2 discharge is suppressed when
#                       SOC < reserve_fraction × total_energy.
#
# Placeholder function signature:
#   run_m1b_reserve_aware(system, scenarios, config) -> Vector{DispatchResult}
#
# Status: NOT YET IMPLEMENTED.  This file is a structural placeholder.
# Implementation is Phase B of the experiment plan.
# See docs/redesigned_experiment_plan.md, Section 8, Task 1.

"""
    run_m1b_reserve_aware(system, scenarios, config)

RA-1b reserve-aware chronological storage heuristic.

**Not yet implemented.**  This is a structural placeholder.  Calling this
function raises an error.  Implementation is Phase B of the experiment plan.

See `docs/redesigned_experiment_plan.md` for the intended algorithm and
`configs/m1b.yaml` for the planned configuration parameters.
"""
function run_m1b_reserve_aware(_system, _scenarios, _config)
    error("RA-1b reserve-aware heuristic is not implemented yet.")
end
