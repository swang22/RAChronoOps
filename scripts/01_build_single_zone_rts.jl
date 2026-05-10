#!/usr/bin/env julia
# 01_build_single_zone_rts.jl
#
# Reads RTS-GMLC source files and writes five processed CSVs to
# data_processed/rts_single_zone/.
#
# Usage:
#   julia --project scripts/01_build_single_zone_rts.jl
#
# If RTS-GMLC files are absent a synthetic 8760-hour fallback is written
# automatically so that all tests can run without external data.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps
using Logging

const PROJECT_ROOT = joinpath(@__DIR__, "..")
const RTS_RAW_DIR  = joinpath(PROJECT_ROOT, "data_raw",       "RTS-GMLC")
const OUT_DIR      = joinpath(PROJECT_ROOT, "data_processed",  "rts_single_zone")

@info "Building single-zone RTS dataset..."
@info "  Source : $RTS_RAW_DIR"
@info "  Output : $OUT_DIR"

build_rts_single_zone(RTS_RAW_DIR, OUT_DIR)

# Quick sanity check
sys = load_system_data(OUT_DIR)
therm = thermal_generators(sys)
@info "Done."
@info "  Thermal generators : $(nrow(therm))"
@info "  VRE generators     : $(nrow(vre_generators(sys)))"
@info "  Storage units      : $(nrow(sys.storage))"
@info "  Hours              : $(sys.n_hours)"
@info "  Peak load          : $(round(maximum(sys.load_mw), digits=1)) MW"
@info "  Peak VRE output    : $(round(maximum(wind_capacity_mw(sys) .* sys.wind_cf .+
                                              solar_capacity_mw(sys) .* sys.solar_cf),
                                       digits=1)) MW"
