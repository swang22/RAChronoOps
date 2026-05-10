#!/usr/bin/env julia
# 00_get_rts_gmlc_data.jl
#
# Downloads the official RTS-GMLC dataset into data_raw/RTS-GMLC/.
# Safe to run multiple times — skips the clone if data already exists.
#
# Usage:
#   julia --project=. scripts/00_get_rts_gmlc_data.jl
#
# Requirements:
#   git must be available on your PATH.
#
# After this script completes, run:
#   julia --project=. scripts/01_build_single_zone_rts.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using RAChronoOps

let
    project_root = joinpath(@__DIR__, "..")
    raw_data_dir = joinpath(project_root, "data_raw", "RTS-GMLC")

    ensure_rts_gmlc_data(raw_data_dir)

    # Confirm key files are reachable
    gen_csv = joinpath(raw_data_dir, "RTS_Data", "SourceData", "gen.csv")
    if isfile(gen_csv)
        @info "Verified: $(gen_csv) exists."
    else
        error("Expected file not found after clone: $gen_csv")
    end

    @info "Done. You can now run scripts/01_build_single_zone_rts.jl"
end
