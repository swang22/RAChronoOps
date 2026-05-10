# ── ExportHOPECase — placeholder ──────────────────────────────────────────
#
# M4 will connect to HOPE (written in Julia) with:
#   network_model   = 0   (copper-plate / single-zone, no transmission)
#   unit_commitment = 0   (economic dispatch, consistent with M3)
#                or = 1   (full unit commitment with binary variables)
#
# The HOPE interface expects:
#   - A HOPECase struct populated from SystemData
#   - Scenario availability arrays from SequentialOutages
#   - A results directory for HOPE to write its output
#
# M5 (not yet planned) may extend to multi-zone with network_model > 0.
#
# Implementation notes for future work:
#   1. Instantiate a HOPE model via HOPE.build_model(case)
#   2. Pass availability[scenario, gen, hour] as forced upper bounds on p[g,h]
#   3. Run HOPE.solve! and extract dispatch + reliability metrics
#   4. Use RAChronoOps.compute_metrics on the extracted load_shed vectors

"""
    export_hope_case(system, config, out_dir)

**Placeholder** — not yet implemented.

Writes a HOPEModelCase directory that M4 will consume.  Call this after
running `build_rts_single_zone` and before invoking HOPE.
"""
function export_hope_case(::SystemData, ::SimConfig, ::String)
    error("export_hope_case is not yet implemented. " *
          "M4 (HOPE integration) is planned for a future milestone.")
end
