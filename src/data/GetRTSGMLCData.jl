# ── GetRTSGMLCData ────────────────────────────────────────────────────────
#
# Helper to clone the official RTS-GMLC dataset into data_raw/RTS-GMLC/.
# Safe to call multiple times — skips if data already present.
#
# After cloning, the directory layout is:
#   data_raw/RTS-GMLC/
#     RTS_Data/
#       SourceData/
#         gen.csv   bus.csv   ...
#       timeseries_data_files/
#         Load/   WIND/   PV/   ...
#
# BuildRTSSingleZone.jl detects the RTS_Data/ subdirectory automatically.

const _RTS_GMLC_REPO = "https://github.com/GridMod/RTS-GMLC.git"
const _RTS_DATA_SUBDIR = "RTS_Data"

"""
    ensure_rts_gmlc_data(raw_data_dir="data_raw/RTS-GMLC") -> String

Ensure the RTS-GMLC dataset is present at `raw_data_dir`.

- If `raw_data_dir/RTS_Data/` already exists, prints a message and returns
  the path immediately (idempotent).
- Otherwise, runs `git clone` to download the dataset from GitHub.
- Throws an error if cloning fails or the expected `RTS_Data/` subdirectory
  is missing after the clone.

Returns `raw_data_dir` on success.
"""
function ensure_rts_gmlc_data(raw_data_dir::String = "data_raw/RTS-GMLC")::String
    rts_data_path = joinpath(raw_data_dir, _RTS_DATA_SUBDIR)

    if isdir(rts_data_path)
        @info "RTS-GMLC data already present at $raw_data_dir — skipping clone."
        return raw_data_dir
    end

    @info "RTS-GMLC data not found. Cloning from $_RTS_GMLC_REPO ..."

    # Ensure the parent of raw_data_dir exists (e.g. data_raw/)
    mkpath(dirname(abspath(raw_data_dir)))

    # git must be available on PATH
    run(Cmd(["git", "clone", _RTS_GMLC_REPO, raw_data_dir]))

    # Verify expected subdirectory is present
    if !isdir(rts_data_path)
        error(
            "Clone of RTS-GMLC appeared to succeed, but expected directory " *
            "is missing:\n  $rts_data_path\n" *
            "Check the clone output above for errors."
        )
    end

    @info "RTS-GMLC data successfully cloned to $raw_data_dir"
    return raw_data_dir
end
