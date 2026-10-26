"""Checks of the graphs per subdir (rules/mojo/subdirs.bzl, rules/mojo/toolchain.bzl) that need no action. Each takes `refuse`, as the checks of siblings.bzl do."""

load("//rules/mojo:subdirs.bzl", "by_subdir", "check_same_units", "table_graphs", "unsupported_branches")
load("//rules/mojo:toolchain.bzl", "split_toolchain_table")

def _graph(subdir, extra_unit = None):
    units = [
        {"id": "p@1.0.0#mojo1.0.0/lib", "deps": []},
        {"id": "p@1.0.0#mojo1.0.0/test:t", "deps": ["p@1.0.0#mojo1.0.0/lib"]},
    ]
    if extra_unit:
        units.append(extra_unit)
    return {"unit_graph": 2, "toolchain": {"subdir": subdir}, "units": units}

LINUX_64 = _graph("linux-64")
LINUX_AARCH64 = _graph("linux-aarch64")
OSX_ARM64 = _graph("osx-arm64")

def a_table_without_graphs_per_subdir_has_the_linux_64_graph_alone(refuse = fail):
    """A table made before graphs per subdir existed has `GRAPH` only, and that is the graph of linux-64."""
    got = table_graphs({"GRAPH": LINUX_64}, refuse)
    if got != {"linux-64": LINUX_64}:
        refuse("a table with GRAPH alone is not the linux-64 graph alone: {}".format(got))

def a_table_with_graphs_per_subdir_is_read_as_it_is(refuse = fail):
    """`GRAPHS` names a graph for each subdir, the linux-64 one included, and nothing is added or dropped."""
    graphs = {"linux-64": LINUX_64, "linux-aarch64": LINUX_AARCH64, "osx-arm64": OSX_ARM64}
    got = table_graphs({"GRAPH": LINUX_64, "GRAPHS": graphs}, refuse)
    if got != graphs:
        refuse("the graphs of the table are not the table's GRAPHS: {}".format(got))

def the_graph_of_a_single_subdir_gives_the_value_itself(refuse = fail):
    """A table with the graph of linux-64 alone has plain values, not selects, for every attribute."""
    graphs = {"linux-64": LINUX_64}
    got = by_subdir(graphs, {"linux-64": "toolchains//:mojo_1_0_0"})
    if got != "toolchains//:mojo_1_0_0":
        refuse("a table with one graph is given a select or another value: {}".format(got))

def a_table_with_the_linux_64_graph_alone_is_refused_on_arm_only(refuse = fail):
    """linux x86_64 (and every platform that is not Arm) is built as it was: the empty refusal is the default and no x86_64 key exists. Both Arm platforms get a
    refusal that says the table has linux-64 only and that `buildrules mojo sync` with a mopm that records the platform is the fix."""
    got = unsupported_branches({"linux-64": LINUX_64}, "//p:check")
    if got.get("DEFAULT") != "":
        refuse("a platform that is not Arm is refused: {}".format(got.get("DEFAULT")))
    if sorted(got.keys()) != ["DEFAULT", "buildrules//platforms:is_linux_aarch64", "buildrules//platforms:is_macos_aarch64"]:
        refuse("the refusals are keyed by {}, not by DEFAULT and the two Arm platforms".format(sorted(got.keys())))
    for key in ["buildrules//platforms:is_linux_aarch64", "buildrules//platforms:is_macos_aarch64"]:
        msg = got[key]
        for want in ["//p:check", "linux-64 only", "Arm", "buildrules mojo sync", "mopm that records"]:
            if want not in msg:
                refuse("the refusal for {} does not say `{}`: {}".format(key, want, msg))

def a_table_with_graphs_per_subdir_refuses_the_platforms_it_has_none_for(refuse = fail):
    """Unchanged: a table with several graphs is built for the platforms of its subdirs, and the others are refused naming the graphs it holds."""
    got = unsupported_branches({"linux-64": LINUX_64, "osx-arm64": OSX_ARM64}, "//p:check")
    if got.get("buildrules//platforms:is_macos_aarch64") != "" or got.get("buildrules//platforms:is_linux_x86_64") != "":
        refuse("a platform with a graph is refused: {}".format(got))
    if "linux-64, osx-arm64" not in got["DEFAULT"]:
        refuse("the refusal does not name the graphs the table holds: {}".format(got["DEFAULT"]))
    if "buildrules//platforms:is_linux_aarch64" in got:
        refuse("linux aarch64 has a branch but the table has no graph for it")

def toolchain_rows_are_told_by_their_key(refuse = fail):
    """`1.0.0` is a linux-64 row; `1.0.0@osx-arm64` is the osx-arm64 row of Mojo 1.0.0."""
    base, others = split_toolchain_table({"1.0.0": "a", "1.0.0@linux-aarch64": "b", "1.0.0@osx-arm64": "c", "1.1.0@osx-arm64": "d"})
    if base != {"1.0.0": "a"}:
        refuse("the linux-64 rows are not the keys without a subdir: {}".format(base))
    if others != {"linux-aarch64": {"1.0.0": "b"}, "osx-arm64": {"1.0.0": "c", "1.1.0": "d"}}:
        refuse("the other rows are not keyed by subdir and version: {}".format(others))

def same_units_in_every_graph(refuse = fail):
    """Graphs that differ only in their toolchain are accepted."""
    check_same_units({"linux-64": LINUX_64, "linux-aarch64": LINUX_AARCH64, "osx-arm64": OSX_ARM64}, refuse)

def graph_with_a_unit_more(refuse = fail):
    """The osx-arm64 graph has a unit the linux-64 one lacks."""
    check_same_units({"linux-64": LINUX_64, "osx-arm64": _graph("osx-arm64", {"id": "extra", "deps": []})}, refuse)

def graph_with_other_dependencies(refuse = fail):
    """The linux-aarch64 graph has the test depend on nothing."""
    other = _graph("linux-aarch64")
    other["units"][1]["deps"] = []
    check_same_units({"linux-64": LINUX_64, "linux-aarch64": other}, refuse)
