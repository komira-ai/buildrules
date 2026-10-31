"""The system libraries a Mojo test is given, held on the real example package (examples/mojo/load_native; rules/mojo/system_libs.bzl, docs/contract.md section 12.11).

The graph of the package is written by hand in format 3: each test unit names the libraries it `loads`, and the graph pins each as `system_libs`. What `mojo_package` must do
with that is held here at analysis, without running anything: the run of each test, its kcov run and its branch run pass `--lib-dir <directory of the library>` once for every
library the test loads, in the order of the graph's list, and for none the test does not load; and the compile of each test (its release build, its coverage build) is given none
of them, and a graph slice of format 2 without `loads` (a compile moves with a pin otherwise, and a mopm that reads formats 1 and 2 stops at a 3). The runs that execute it are the
package's own tests (//ci:mojo) and the stand-in of ci/mojo_syslibs.

The package's `:lib` also hands every library the graph pins to a label that adopts the package (`MojoSystemLibsInfo`, rules/mojo/providers.bzl), so a dependent that runs
its tests through other rules is given the same files: the gated library lists one `mojo_system_lib` for each `system_libs` entry of the graph, and no other. The stand-in of
ci/mojo_syslibs (`run_green_via_lib`, `run_red_via_lib_without`) runs a probe with the directories such a library exports.
"""

load("//examples/mojo/load_native:buildrules.mojo.lock.bzl", "GRAPH", "GRAPHS")

PACKAGE = "//examples/mojo/load_native"

# The steps that run the test binary, and the steps that compile it.
RUNS = ["", "__cov", "__profdata"]
COMPILES = ["__bin", "__cov_bin"]

def _lib_dirs(ctx, node):
    """The arguments that follow each `--lib-dir` of the actions of `node`, in the order they are passed."""
    got = []
    for action in ctx.aquery().all_actions(node):
        if not hasattr(action.attrs, "cmd"):
            continue
        cmd = str(action.attrs.cmd).lstrip("[").rstrip("]").split(", ")
        got += [cmd[i + 1] for i in range(len(cmd) - 1) if cmd[i] == "--lib-dir"]
    return got

def system_libs_problems(ctx, platform):
    """Every way the system libraries of the graph's tests are not what the runs are given: a list of strings, empty when all is as the graph says."""
    problems = []
    tests = [u for u in GRAPH["units"] if u["kind"] == "test"]
    if len(tests) < 2 or len(GRAPHS) < 2:
        problems.append("{}: the graph must hold two tests that load different libraries and a graph for each of two subdirs, so each test's own libraries and each platform's pin are held".format(PACKAGE))
    pinned = sorted([e["name"] for e in GRAPH.get("system_libs", [])])
    if not pinned:
        problems.append("{}: the graph pins no system library, so what `:lib` hands to an adopting label is not held".format(PACKAGE))
    lib = ctx.configured_targets("{}:lib".format(PACKAGE), target_platform = platform)
    exported = sorted([d.name for d in lib.attrs_eager().system_libs.value()])
    if exported != ["syslib_" + n for n in pinned]:
        problems.append("{}:lib lists the system libraries {} for a label that adopts the package; the graph pins {}".format(PACKAGE, exported, ["syslib_" + n for n in pinned]))
    for u in tests:
        stem = u["outputs"][0][:-len(".pass")]
        loads = u["loads"]
        for step in RUNS:
            label = "{}:{}{}".format(PACKAGE, stem, step)
            got = _lib_dirs(ctx, ctx.configured_targets(label, target_platform = platform))
            if len(got) != len(loads) or [n for n, d in zip(loads, got) if "syslib_" + n not in d]:
                problems.append("{}: the run is given the library directories {}, the graph says the test loads {} (one `--lib-dir` each, in this order)".format(label, got, loads))
        for step in COMPILES:
            label = "{}:{}{}".format(PACKAGE, stem, step)
            node = ctx.configured_targets(label, target_platform = platform)
            got = _lib_dirs(ctx, node)
            if got:
                problems.append("{}: the compile is given the library directories {}: a library the test loads is no input of its compiled bytes".format(label, got))
            # The slice is `json.encode`d, so compact (`"unit_graph":3`): it is read as JSON, not searched for a spelling (a search for `"unit_graph": 3` with a space could never find it).
            graph = node.attrs_eager().graph.value()
            slice = json.decode(graph)
            if slice["unit_graph"] != 2:
                problems.append("{}: the unit's graph slice is format {}: `mopm unit build` is given format 2 (the compile must not move with a pin, a `link` or a `provided` it does not use)".format(label, slice["unit_graph"]))
            for bad in ["\"loads\"", "\"link\"", "system_libs"]:
                if bad in graph:
                    problems.append("{}: the unit's graph slice holds {}: `mopm unit build` is given format 2 and no `loads` or `link` (the compile must not move with a pin)".format(label, bad))
    return problems
