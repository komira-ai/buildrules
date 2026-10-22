"""The tools the C/C++ toolchain refuses (rules/cxx/toolchain.bzl): one planted refusal each (ci/runners/BUCK) and one row of the bxl check (ci/negative.bzl).

The names are the `what` of the toolchain's `refuse(what)` calls, which its message prints: `cxx toolchain: <what> is not provided (see rules/cxx/toolchain.bzl)`.
"""

# Fields of CxxInternalTools, then the members of DistLtoToolsInfo, then BinaryUtilitiesInfo: the order of the toolchain's own declaration.
REFUSED = [
    "check_nonempty_output",
    "clang_tidy_wrapper",
    "concatenate_diagnostics",
    "dep_file_processor",
    "dist_lto planner",
    "dist_lto opt",
    "dist_lto prepare",
    "dist_lto copy",
    "dist_lto archive_mapper",
    "dist_lto compiler_stats_merger",
    "filter_argsfile",
    "hmap_wrapper",
    "make_comp_db",
    "remap_cwd",
    "serialized_diagnostics_to_json_wrapper",
    "stderr_to_file",
    "stub_header_unit",
    "nm",
    "objcopy",
    "strip",
]

# The target name of a tool's planted refusal: `refused_dist_lto_planner`.
def refusal_target(what):
    return "refused_" + what.replace(" ", "_")
