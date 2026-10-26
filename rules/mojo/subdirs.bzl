"""The conda subdirs a Mojo package has a unit graph for, and how a target platform chooses among them (docs/contract.md, section 12).

`buildrules mojo sync` asks mopm for the unit graph of every subdir it plans for and commits them in `buildrules.mojo.lock.bzl`: `GRAPH` is the graph of
`linux-64` (mopm's default, and the only one a table made before graphs per subdir had), `GRAPHS` maps each subdir, `linux-64` too, to its graph. A graph
differs by subdir in its toolchain (the compiler and the zig that link for the platform), in the `.conda` of every registry package it names, and in the
keys; the units, their sources and their dependencies are the same, and `mojo_package` refuses a table where they are not.

`mojo_package` chooses the graph by the target platform: its constraint on the OS and on the CPU (`buildrules//platforms:is_<os>_<cpu>`). A table with the
graph of linux-64 alone is built for every platform exactly as it was before, so a repository that has not synced again keeps building. A table with several
graphs is built for the platforms of its subdirs, and for any other platform the package's `:check` fails analysis and says so.
"""

# conda subdir -> the config setting that a target platform of that OS and CPU matches.
SUBDIR_SETTINGS = {
    "linux-64": "buildrules//platforms:is_linux_x86_64",
    "linux-aarch64": "buildrules//platforms:is_linux_aarch64",
    "osx-arm64": "buildrules//platforms:is_macos_aarch64",
}

# The subdir whose graph is `GRAPH`, and the toolchains `toolchains//:mojo_<v>` (the others are `mojo_<v>_<subdir with _>`).
BASE_SUBDIR = "linux-64"

def subdir_suffix(subdir):
    """`linux-aarch64` -> `linux_aarch64`: the part of a target name that tells the subdir."""
    return subdir.replace("-", "_")

def table_graphs(table, refuse = fail):
    """`{subdir: graph}` of a table. A table made before graphs per subdir existed has `GRAPH` alone, which is the graph of linux-64."""
    graphs = table.get("GRAPHS")
    if graphs == None:
        return {BASE_SUBDIR: table["GRAPH"]}
    for sd in graphs.keys():
        if sd not in SUBDIR_SETTINGS:
            refuse("buildrules.mojo.lock.bzl holds a graph for {}, a subdir these rules do not know (they know {}): run `buildrules mojo sync` with a matching buildrules".format(sd, ", ".join(sorted(SUBDIR_SETTINGS.keys()))))
    if BASE_SUBDIR not in graphs:
        refuse("buildrules.mojo.lock.bzl holds graphs for {} and none for {}: run `buildrules mojo sync`".format(", ".join(sorted(graphs.keys())), BASE_SUBDIR))
    return graphs

def check_same_units(graphs, refuse = fail):
    """Every graph names the units of the linux-64 one, and the same dependencies between them: a subdir changes how a unit is built, never what the package is."""
    base = {u["id"]: u["deps"] for u in graphs[BASE_SUBDIR]["units"]}
    for sd in sorted(graphs.keys()):
        got = {u["id"]: u["deps"] for u in graphs[sd]["units"]}
        if got != base:
            refuse("the unit graph of {} does not name the units of the graph of {} (or their dependencies): run `buildrules mojo sync`".format(sd, BASE_SUBDIR))

def by_subdir(graphs, values):
    """`values[subdir]` for the one target platform of a table with a single graph, else a `select` over the subdirs the table has graphs for. A platform
    that matches none gets the linux-64 value: `unsupported_platform` is what refuses it, in the package's `:check`, which every target waits for."""
    if len(graphs) == 1:
        return values[BASE_SUBDIR]
    branches = {SUBDIR_SETTINGS[sd]: values[sd] for sd in sorted(graphs.keys())}
    branches["DEFAULT"] = values[BASE_SUBDIR]
    return select(branches)

def unsupported_platform(graphs, who):
    """What the package's `:check` is given as `unsupported`: empty on a platform that has a graph, else the refusal."""
    if len(graphs) == 1:
        return ""
    have = sorted(graphs.keys())
    branches = {SUBDIR_SETTINGS[sd]: "" for sd in have}
    branches["DEFAULT"] = ("{}: buildrules.mojo.lock.bzl has no unit graph for this target platform. It holds graphs for {}, chosen by the OS and the CPU of " +
                           "the target platform (linux-64: linux x86_64, linux-aarch64: linux aarch64, osx-arm64: macOS aarch64), and this platform is none " +
                           "of those. Build for one of them; mopm plans for no other subdir.").format(who, ", ".join(have))
    return select(branches)
