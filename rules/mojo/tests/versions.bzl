"""Checks of the graphs per Mojo version (rules/mojo/versions.bzl) that need no action. Each takes `refuse`, as the checks of subdirs.bzl do; the configured build is held
by ci/mojo_versions.bzl."""

load("//rules/mojo:versions.bzl", "by_mojo", "check_mojos", "table_mojos", "unit_slot", "unsupported_mojo_branches")

def _closure(v):
    return (v.replace(".", "") * 64)[:64]

def graph(v, subdir = "linux-64", extra_unit = None, util_version = "0.1.0", system_libs = None):
    """A graph of format 2 for Mojo `v`: a library that imports a registry package `util` and a test of it."""
    units = [
        {"id": "util@{}#mojo{}/lib".format(util_version, v), "package": "util", "kind": "prebuilt", "deps": [], "outputs": ["util.mojoc"], "natives": []},
        {"id": "p@1.0.0#mojo{}/lib".format(v), "package": "p", "kind": "lib", "deps": ["util@{}#mojo{}/lib".format(util_version, v)], "srcs": [{"path": "src/p/__init__.mojo"}], "outputs": ["p.mojoc"], "natives": []},
        {"id": "p@1.0.0#mojo{}/test:tests/v@2/t.mojo".format(v), "package": "p", "kind": "test", "deps": ["p@1.0.0#mojo{}/lib".format(v)], "srcs": [{"path": "tests/v@2/t.mojo"}], "outputs": ["t.pass"], "natives": []},
    ]
    if extra_unit:
        units.append(extra_unit)
    g = {"unit_graph": 2, "mojo": v, "toolchain": {"mojo": v, "subdir": subdir, "closure_sha256": _closure(v)}, "units": units}
    if system_libs != None:
        g["system_libs"] = system_libs
    return g

def table(mojos, default = "1.0.0"):
    """A table whose default is `default`, and `MOJOS` of `mojos` (`{version: {subdir: graph}}`), each with its graph's closure."""
    base = mojos[default]
    t = {"MOJO": default, "CLOSURE_SHA256": _closure(default), "GRAPH": base["linux-64"]}
    if len(base) > 1:
        t["GRAPHS"] = base
    t["MOJOS"] = {v: {"CLOSURE_SHA256": _closure(v), "GRAPHS": gs} for v, gs in mojos.items()}
    return t

THREE = {v: {"linux-64": graph(v)} for v in ["1.0.0", "1.1.0", "1.2.0"]}

def slots_are_the_id_without_the_versions(refuse = fail):
    """The slot of a unit is the same in the graphs of two Mojo versions, and of two versions of a registry package; a test file with `@`, a binary, a full name and
    a native unit keep what tells them apart."""
    want = {
        "example/json@0.1.0#mojo1.2.0/lib": "example/json#lib",
        "example/json@0.3.1#mojo1.0.0/lib": "example/json#lib",
        "p@1.0.0#mojo1.1.0/test:tests/v@2/t.mojo": "p#test:tests/v@2/t.mojo",
        "p@1.0.0#mojo1.1.0/bin:greet": "p#bin:greet",
        "native:example/app/shim": "native:example/app/shim",
    }
    for uid, slot in want.items():
        if unit_slot(uid) != slot:
            refuse("the slot of {} is {}, not {}".format(uid, unit_slot(uid), slot))

def a_table_without_mojos_has_its_default_alone(refuse = fail):
    """A table made before versions existed (or for one version) has `MOJO` and its graphs, and nothing else."""
    g = graph("1.0.0")
    got = table_mojos({"MOJO": "1.0.0", "CLOSURE_SHA256": _closure("1.0.0"), "GRAPH": g}, refuse)
    if got != {"1.0.0": {"closure": _closure("1.0.0"), "graphs": {"linux-64": g}}}:
        refuse("a table without MOJOS is not its default alone: {}".format(got))

def a_table_of_three_versions_is_read_and_checked(refuse = fail):
    """Three versions of one package, a registry package resolved to another version for one of them, and the subdirs of each: accepted, each with its own closure."""
    mojos = dict(THREE, **{"1.2.0": {"linux-64": graph("1.2.0", util_version = "0.2.0")}})
    got = check_mojos(table(mojos), refuse)
    if sorted(got.keys()) != ["1.0.0", "1.1.0", "1.2.0"] or got["1.1.0"]["closure"] != _closure("1.1.0"):
        refuse("the versions of the table are not its MOJOS: {}".format(got.keys()))
    both = {v: {"linux-64": graph(v), "osx-arm64": graph(v, "osx-arm64")} for v in ["1.0.0", "1.2.0"]}
    check_mojos(table(both), refuse)

def one_version_leaves_every_attribute_a_plain_value(refuse = fail):
    """A table of one version gives the value itself, not a select, so its targets are what they were."""
    got = by_mojo({"1.0.0": {}}, "1.0.0", lambda v: "toolchains//:mojo_" + v)
    if got != "toolchains//:mojo_1.0.0":
        refuse("a table of one version is given a select or another value: {}".format(got))

def platforms_of_the_versions_of_a_table_are_accepted(refuse = fail):
    """No refusal on a platform without the constraint or for a version the table has; the default's own constraint is one of those."""
    for mojos in [{"1.0.0": {}}, {"1.0.0": {}, "1.2.0": {}}]:
        got = unsupported_mojo_branches(mojos, "1.0.0", "//p:check")
        for key in ["DEFAULT"] + ["buildrules//platforms:mojo_is_" + v.replace(".", "_") for v in mojos.keys()]:
            if got.get(key) != "":
                refuse("{} is refused for a table of {}: {}".format(key, sorted(mojos.keys()), got.get(key)))

def refusal_of_a_version(mojos, version, refuse = fail):
    """The refusal of a platform that asks for `version` (rules/rust/refusal.bzl `refuses` reads what is recorded)."""
    refuse(unsupported_mojo_branches(mojos, "1.0.0", "examples/p:check")["buildrules//platforms:mojo_is_" + version.replace(".", "_")])

def edited_default(refuse = fail):
    """The MOJOS entry of the default names other graphs than GRAPH."""
    t = table(THREE)
    t["MOJOS"] = dict(t["MOJOS"], **{"1.0.0": {"CLOSURE_SHA256": _closure("1.0.0"), "GRAPHS": {"linux-64": graph("1.1.0")}}})
    table_mojos(t, refuse)

def mojos_without_the_default(refuse = fail):
    t = table(THREE)
    t["MOJO"] = "1.3.0"
    table_mojos(t, refuse)

def a_version_no_platform_can_ask_for(refuse = fail):
    table_mojos(table({"1.0.0": {"linux-64": graph("1.0.0")}, "1.3.0": {"linux-64": graph("1.3.0")}}), refuse)

def a_version_with_a_unit_more(refuse = fail):
    extra = {"id": "p@1.0.0#mojo1.1.0/bin:greet", "package": "p", "kind": "bin", "deps": [], "srcs": [{"path": "bin/greet.mojo"}], "outputs": ["greet"], "natives": []}
    check_mojos(table(dict(THREE, **{"1.1.0": {"linux-64": graph("1.1.0", extra_unit = extra)}})), refuse)

def a_version_with_other_dependencies(refuse = fail):
    g = graph("1.2.0")
    g["units"][1]["deps"] = []
    check_mojos(table(dict(THREE, **{"1.2.0": {"linux-64": g}})), refuse)

def a_version_with_other_subdirs(refuse = fail):
    check_mojos(table({"1.0.0": {"linux-64": graph("1.0.0")}, "1.2.0": {"linux-64": graph("1.2.0"), "osx-arm64": graph("1.2.0", "osx-arm64")}}), refuse)

def a_version_with_other_system_libs(refuse = fail):
    lib = {"name": "libz", "version": "1", "build": "0", "url": "https://example.org/r/libz.conda", "sha256": "0" * 64, "size": 1}
    a, b = graph("1.0.0", system_libs = []), graph("1.2.0", system_libs = [lib])
    a["unit_graph"], b["unit_graph"] = 3, 3
    check_mojos(table({"1.0.0": {"linux-64": a}, "1.2.0": {"linux-64": b}}), refuse)

def a_version_whose_closure_is_not_its_graphs(refuse = fail):
    t = table(THREE)
    t["MOJOS"] = dict(t["MOJOS"], **{"1.1.0": {"CLOSURE_SHA256": _closure("1.2.0"), "GRAPHS": THREE["1.1.0"]}})
    check_mojos(t, refuse)

def a_version_holding_the_graph_of_another(refuse = fail):
    check_mojos(table(dict(THREE, **{"1.1.0": {"linux-64": graph("1.2.0")}})), refuse)
