"""The system libraries a Mojo test loads at run time (docs/contract.md, section 12.11).

A package that opens a library by its bare name (`mode = "load"` in `[native-dependencies]`, `dlopen("libsqlite3.so.0")`) links nothing, so the compile never needs it;
the test run does. mopm's unit graph of format 3 pins each such library as an entry of its top-level `system_libs`, and names on every test and binary unit the
libraries it loads, run dependencies included, in `loads`:

    "system_libs": [{"name": "libsqlite", "version": "3.54.1", "build": "h0737f62_101", "url": "...", "sha256": "...", "size": 980491}, ...]
    "units": [{"id": "...", "kind": "test", ..., "loads": ["libsqlite", "libzlib"]}]

`mojo_package` downloads each entry like every other pin (`pinned_file`: the sha256 and size of the graph, the URL through `url_map`), `mojo_system_lib` unpacks the
shared libraries of its `lib/` into a directory (`conda_unpack --all-libs`), and a test run, its coverage run and its branch-coverage run are given those
directories as `--lib-dir` (`lib_dir_args`): on Linux they follow the compiler's lib on `LD_LIBRARY_PATH`, on macOS they come first in `DYLD_FALLBACK_LIBRARY_PATH`.
The compile is not given them: a library a unit loads is no input of its compiled bytes.

A graph of format 1 or 2 has neither key and runs as it always did (the library is whatever the worker has; on macOS, the directories of `macos_library_dirs`). A graph
of a format above 3 is refused: a rules version that did not know a key would run the test without its libraries, which is the defect the key exists to remove.
"""

load("//rules/core:pinned_file.bzl", "check_pinned")

# The formats of mopm's unit graph these rules read. 2 adds the native unit of a member's own library, 3 the system libraries a test loads.
GRAPH_FORMATS = [1, 2, 3]

# The newest of them: the format a graph with `system_libs` or `loads` has.
SYSTEM_LIBS_FORMAT = 3

# What `mopm unit build` of the pinned mopm reads: the slice of a unit it is given says this format when the graph's is newer, because the keys format 3 adds (`system_libs`,
# `loads`) are no part of a compile (nothing of them reaches it), and a compile must not move when a pin does.
COMPILE_FORMAT = 2

_ENTRY_FIELDS = ["name", "version", "build", "url", "sha256", "size"]

MojoSystemLibInfo = provider(fields = {
    "name": provider_field(str),
    # Directory: every shared library of the package's `lib/`, flat (links written as copies).
    "dir": provider_field(typing.Any),
})

def check_graph_format(who, n, refuse = fail):
    """The format number of a unit graph is one these rules read. `refuse` is `fail` in a build; a test passes a recorder (rules/rust/refusal.bzl)."""
    if type(n) != "int" or n < 1:
        refuse("{} has the format {}, which is not a format number: run `buildrules mojo sync`".format(who, repr(n)))
    elif n > SYSTEM_LIBS_FORMAT:
        refuse("{} is format {}; these rules read formats 1 to {}: update buildrules (a rules version that does not know a format would run the tests without what it adds)".format(who, n, SYSTEM_LIBS_FORMAT))

def compile_format(n):
    """The format a unit's slice for `mopm unit build` says: the graph's, but never above `COMPILE_FORMAT`."""
    return n if n <= COMPILE_FORMAT else COMPILE_FORMAT

def system_libs_of(who, graph, refuse = fail):
    """`{name: entry}` of the graph's `system_libs` (empty for a graph that has none). Refused: the key in a graph older than format 3, an entry that is not an object with
    every field (`name`, `version`, `build`, `url`, `sha256`, `size`), an unpinned one (`check_pinned`) or a name twice."""
    entries = graph.get("system_libs")
    if entries == None:
        return {}
    if graph["unit_graph"] < SYSTEM_LIBS_FORMAT:
        refuse("{}: a graph of format {} has `system_libs`, which is a format {} key: run `buildrules mojo sync`".format(who, graph["unit_graph"], SYSTEM_LIBS_FORMAT))
        return {}
    got = {}
    for e in entries:
        missing = [f for f in _ENTRY_FIELDS if type(e) != "dict" or f not in e]
        if missing:
            refuse("{}: a `system_libs` entry lacks {}: {}".format(who, ", ".join(missing), repr(e)))
            continue
        if type(e["name"]) != "string" or not e["name"] or "/" in e["name"] or e["name"].startswith("."):
            refuse("{}: a `system_libs` entry has the name {}, which is not a package name".format(who, repr(e["name"])))
            continue
        if e["name"] in got:
            refuse("{}: `system_libs` pins {} twice".format(who, e["name"]))
            continue
        if type(e["sha256"]) != "string" or type(e["size"]) != "int":
            refuse("{}: the `system_libs` entry {} has a sha256 that is not text or a size that is not a number".format(who, e["name"]))
            continue
        check_pinned("{}: system_libs {}".format(who, e["name"]), e["sha256"], e["size"], refuse)
        got[e["name"]] = e
    return got

def check_loads(who, graph, libs, refuse = fail):
    """Every library a unit loads is one the graph pins: `libs` is `system_libs_of(graph)`. A graph older than format 3 has no `loads`. `refuse` as above."""
    for u in graph["units"]:
        loads = u.get("loads")
        if loads == None:
            continue
        if graph["unit_graph"] < SYSTEM_LIBS_FORMAT:
            refuse("{}: {} has `loads` in a graph of format {}; it is a format {} key: run `buildrules mojo sync`".format(who, u["id"], graph["unit_graph"], SYSTEM_LIBS_FORMAT))
            continue
        for name in loads:
            if name not in libs:
                refuse("{}: {} loads the system library {}, which the graph's `system_libs` does not pin (a lock without it: run `mopm lock`, then `buildrules mojo sync`)".format(who, u["id"], name))

def check_same_system_libs(graphs, base, refuse = fail):
    """Every graph pins the same libraries and every unit loads the same ones in each: a subdir changes the file of a library, never which libraries a package needs.
    `graphs` is `{subdir: graph}`, `base` the subdir the others are held to."""
    names = sorted([e["name"] for e in graphs[base].get("system_libs", [])])
    loads = {u["id"]: u.get("loads", []) for u in graphs[base]["units"]}
    for sd in sorted(graphs.keys()):
        got = sorted([e["name"] for e in graphs[sd].get("system_libs", [])])
        if got != names:
            refuse("the unit graph of {} pins the system libraries {} and the graph of {} pins {}: run `buildrules mojo sync`".format(sd, got, base, names))
        if {u["id"]: u.get("loads", []) for u in graphs[sd]["units"]} != loads:
            refuse("the unit graph of {} names other system libraries for a unit than the graph of {}: run `buildrules mojo sync`".format(sd, base))

def lib_dir_args(libs):
    """`--lib-dir <dir>` for each of `libs` (targets with `MojoSystemLibInfo`), in the order given: the option of `check run|marker`, `cov_run` and `cov_branch run`. No
    library, no argument: the command is what it was before."""
    args = []
    for l in libs:
        args += ["--lib-dir", l[MojoSystemLibInfo].dir]
    return args

def _impl(ctx):
    out = ctx.actions.declare_output("lib", dir = True)
    tool = ctx.attrs.unpacker[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(tool, "--all-libs", ctx.attrs.archive[DefaultInfo].default_outputs[0], out.as_output()),
        category = "mojo_system_lib",
        identifier = ctx.attrs.package,
    )
    return [DefaultInfo(default_output = out), MojoSystemLibInfo(name = ctx.attrs.package, dir = out)]

mojo_system_lib_rule = rule(
    impl = _impl,
    doc = "The shared libraries of one pinned conda package (a `system_libs` entry), unpacked into a directory: what a test run puts on its library path.",
    attrs = {
        # The sha256-pinned `.conda` of the entry (its subdir's).
        "archive": attrs.dep(),
        "package": attrs.string(),
        "unpacker": attrs.exec_dep(default = "buildrules//rules/mojo:conda_unpack"),
    },
)
