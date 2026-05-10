#!/usr/bin/env julia
# 04_export_hope_cases.jl
#
# PLACEHOLDER — M4 HOPE integration not yet implemented.
#
# When M4 is ready this script will:
#   1. Load the processed single-zone system.
#   2. Generate outage scenarios via SequentialOutages.
#   3. Call export_hope_case() to write HOPEModelCase directories.
#   4. Launch HOPE with network_model=0, unit_commitment=1.
#   5. Collect HOPE output and compute MetricsResult via RAChronoOps.
#
# See src/data/ExportHOPECase.jl for the planned interface.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps

@warn "04_export_hope_cases.jl: M4 HOPE integration is not yet implemented."
@info "See src/data/ExportHOPECase.jl for the planned interface."
