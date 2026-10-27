"""The system libraries a Mojo test is given, held on the real example package (examples/mojo/load_native; rules/mojo/system_libs.bzl, docs/contract.md section 12.10).

The graph of the package is written by hand in format 3: each test unit names the libraries it `loads`, and the graph pins each as `system_libs`. What `mojo_package` must do
with that is held here at analysis, without running anything: the run of each test, its kcov run and its branch run pass `--lib-dir <directory of the library>` once for every
library the test loads, in the order of the graph's list, and for none the test does not load; and the compile of each test (its release build, its coverage build) is given none
of them, and a graph slice of format 2 without `loads` (a compile moves with a pin otherwise, and a mopm that reads formats 1 and 2 stops at a 3). The runs that execute it are the
package's own tests (//ci:mojo) and the stand-in of ci/mojo_syslibs.
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
            graph = node.attrs_eager().graph.value()
            for bad in ["\"loads\"", "\"unit_graph\": 3", "system_libs"]:
                if bad in graph:
                    problems.append("{}: the unit's graph slice holds {}: `mopm unit build` is given format 2 and no `loads` (the compile must not move with a pin)".format(label, bad))
    return problems
