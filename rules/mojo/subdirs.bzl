"""The conda subdirs a Mojo package has a unit graph for, and how a target platform chooses among them (docs/contract.md, section 12).

`buildrules mojo sync` asks mopm for the unit graph of every subdir it plans for and commits them in `buildrules.mojo.lock.bzl`: `GRAPH` is the graph of
`linux-64` (mopm's default, and the only one a table made before graphs per subdir had), `GRAPHS` maps each subdir, `linux-64` too, to its graph. A graph
differs by subdir in its toolchain (the compiler and the zig that link for the platform), in the `.conda` of every registry package it names, and in the
keys; the units, their sources and their dependencies are the same, and `mojo_package` refuses a table where they are not.

`mojo_package` chooses the graph by the target platform: its constraint on the OS and on the CPU, in either vocabulary. A platform states them in this package's own
constraint values (`buildrules//platforms:linux`, `:aarch64`, ...), in the prelude's (`prelude//os/constraints:linux`, `prelude//cpu/constraints:arm64`, ...), which a
repository that does not know buildrules has, or in both; `SUBDIR_PAIRS` names the (OS, CPU) pair of each subdir and rules/core/platform.bzl (`os_cpu_keys`) turns it into
the branches of a `select` for each vocabulary (platforms/BUCK has the config settings). A platform that states neither is in no subdir. A table with the
graph of linux-64 alone is built for every platform exactly as it was before, so a repository that has not synced again keeps building. A table with several
graphs is built for the platforms of its subdirs, and for any other platform the package's `:check` fails analysis and says so.
"""

load("//rules/core:platform.bzl", "os_cpu_keys")

# conda subdir -> the (OS, CPU) pair that a target platform of that subdir states (`os_cpu_keys` has its config settings, one for each vocabulary).
SUBDIR_PAIRS = {
    "linux-64": "linux_x86_64",
    "linux-aarch64": "linux_aarch64",
    "osx-arm64": "macos_aarch64",
}

# conda subdir -> the config settings that a target platform of that OS and CPU matches.
SUBDIR_SETTINGS = {sd: os_cpu_keys(pair) for sd, pair in SUBDIR_PAIRS.items()}

def _branches(subdirs, value):
    """`{config setting: value(subdir)}` for the subdirs, every vocabulary of each."""
    return {key: value(sd) for sd in subdirs for key in SUBDIR_SETTINGS[sd]}

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
    branches = _branches(sorted(graphs.keys()), lambda sd: values[sd])
    branches["DEFAULT"] = values[BASE_SUBDIR]
    return select(branches)

def unsupported_branches(graphs, who):
    """`{config setting or "DEFAULT": refusal}` of `unsupported_platform`. A table with one graph (linux-64) refuses the Arm platforms and nothing else: its x86_64
    toolchain would run on an Arm host. A table with several refuses the platforms that match none of its subdirs."""
    have = sorted(graphs.keys())
    if len(graphs) == 1:
        arm = ("{}: buildrules.mojo.lock.bzl holds a unit graph for linux-64 only, and this target platform is Arm ({{}}). The toolchain of linux-64 is x86_64 and " +
               "would run on an Arm host. The package needs `buildrules mojo sync` with a mopm that records the graph of that platform's subdir.").format(who)
        branches = _branches(["linux-aarch64", "osx-arm64"], arm.format)
        branches["DEFAULT"] = ""
        return branches
    branches = _branches(have, lambda sd: "")
    branches["DEFAULT"] = ("{}: buildrules.mojo.lock.bzl has no unit graph for this target platform. It holds graphs for {}, chosen by the OS and the CPU of " +
                           "the target platform (linux-64: linux x86_64, linux-aarch64: linux aarch64, osx-arm64: macOS aarch64), and this platform is none " +
                           "of those. Build for one of them; mopm plans for no other subdir.").format(who, ", ".join(have))
    return branches

def unsupported_platform(graphs, who):
    """What the package's `:check` is given as `unsupported`: empty on a platform that has a graph, else the refusal."""
    return select(unsupported_branches(graphs, who))
