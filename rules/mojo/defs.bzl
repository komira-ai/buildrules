"""`mojo_package`: the front door of the Mojo rules (docs/contract.md, section 12).

    load(":buildrules.mojo.bzl", "mojo_package")      # written by `buildrules mojo sync`, next to mopm.toml
    mojo_package(path = ".")

One line per package. The targets come from the package's unit graph, which `buildrules mojo sync` committed as
`buildrules.mojo.lock.bzl` (mopm's own output, verbatim): nothing here parses mopm.toml or decides what "build Mojo" means.

    :lib        the package's `.mojoc` (mode `lib`), behind the run of every test: it exists only if they all pass (below)
    :lib_ungated  the same `.mojoc` as compiled, which the package's own tests import (what `:lib` waits for)
    :test       every test file, built once and run: `:<stem>` (the run) behind `:<stem>__bin` (the compile)
    :build      the library and the binaries of `[targets] bins`
    :coverage   every test again as a debug build run under kcov, one Cobertura report per test file, and as LLVM bitcode instrumented for branch counts
                (`<stem>__bc`, `__pgo`, `__profdata`, `__ir`, `__info`: rules/coverage/branch/README.md); `coverage.txt` is the per-file count of lines, then of
                branch arms; `:coverage[reports]` is the per-line records of every test (kcov's Cobertura XML in repository paths) and `:coverage[branches]` the
                branch records (lcov `BRDA` lines in repository paths). The instrumented link of a test gets the test's native libraries as its ordinary link does.
                A package whose tests run in the installed layout (`test_layout = "installed"`) has them too: the instrumented binary is run from the installed tree, as the kcov run is.
    :coverage_floor  only if the package has a `coverage_floor.txt` beside its BUCK file: green while `:coverage` is at least that floor (`lines NN.NN`, and
                `branches NN.NN` when `coverage.txt` has branch rows; below it: "coverage fell"; at or above it passes, and above it prints "you may raise the
                floor to X"), the check of every other package's floor (rules/coverage/README.md, "The floor")
    :ci        `:build` and `:test`
    :table      the committed graph is, byte for byte, what the pinned mopm prints now (a check of its own; `:workspace` holds the files it reads)

A workspace member (a path dependency) is a package of its own with its own BUCK file; this package's graph names it, and
its `:lib` is what the units here import. A registry dependency is a sha256-pinned `.conda`, matched to the graph's Mojo version
by mopm, fetched and unpacked here. Native libraries are declared inputs and mopm checks each against the sha256 in the graph before it compiles
anything. The static libraries (`lib<stem>.a`) of a registry package come from the lock: the `.conda` that holds the `.mojoc` holds them too,
`prebuilt_unpack` takes each out after hashing it against the lock's value, and a unit links them in the graph's order (a library before every
library it needs) with nothing written in the BUCK file. A workspace member's own `[native.<id>] kind = "static"` is a native unit of the graph
(`native:<package>/<id>`): its package builds it from its C sources, `:native_<id>_cxx` (a `cxx_library`) and `:native_<id>` (its `native_archive`, rules/cxx/native.bzl),
and every unit that links it has an entry with `built` that this macro maps to that target, again with nothing written in the BUCK file. A package that builds natives
also gets `:conda`, with the archives packed as `lib<id>.a`; `conda = True` gives any package one (a package whose dependencies are workspace members, children or siblings, is packed with each as a versioned dependency: its `mopm.toml` writes `{ path = "../b", version = "0.1" }`). The names `:native_<id>` and `:native_<id>_cxx` are stable: a repository that lists libraries by target can name
them. Any other native library (a shared one) is an entry of `natives = {"<soname>": "<target>"}`; one the lock or the graph provides may not also be named there.
Every library target carries `MojoNativeArchiveInfo` (its natives in link order, and their files), which a label that adopts the package hands to a dependent
that links through other rules.

Test data and variables. A test that reads files (goldens, fixtures, a pinned third-party file, a program it starts) names them in
`test_data = {"<test source or *>": {"<staged path>": "<file or target>"}}`, and one that reads variables in `test_env = {"NAME": "value"}`
(rules/mojo/test_data.bzl, docs/contract.md section 12.9). The files are copied to a directory per test, which is the test's working directory in
its run and in its coverage run and is named by `BUILDRULES_TEST_DATA`; the files and the variables are inputs of both actions, so a change to
either runs the test again.

Test scratch and layout. Every test run and every coverage run gets a fresh, empty, private `TMPDIR` and `TEST_TMPDIR` and `HOME` (absolute, one set per
test, removed after it); the names are the runner's, and `test_env` refuses them. `test_layout = "installed"` runs each test from a fresh root of its own
instead: the binary at `<root>/bin/<exe>` (a copy, so `/proc/self/exe` is there), the `test_data` under `<root>/share` (keys stay relative to `share/`) and
`<root>` as the working directory; `BUILDRULES_TEST_DATA` then names `<root>/share`. The coverage run uses the same layout. `"default"` (the default) is
unchanged. Any other value is refused.

The gate. `:lib` is a copy of `:lib_ungated` made by an action that takes the marker of every test run as an input, and a test run writes
its marker only when the test passed. A failing test therefore leaves `:lib` unbuildable, and so every target that imports it (a
member's units, a binary, `:build`, a conda package made from it). Build `:lib_ungated` to work on a library whose tests are red.

The ISA level of the target platform reaches the test and binary builds as compiler flags (rules/isa.bzl, one table for every
toolchain) and the test runs as the platform's `exec_compatible_with`, so the farm schedules it on a worker that has the level.
"""

load("//rules:isa.bzl", "ISA_LEVELS", "isa_select", "required_isa", "test_exec_compatible_with")
load("//rules/core:pinned_file.bzl", "pinned_file")
load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/core:url_map.bzl", "mapped_url")
load("//rules/cxx:native.bzl", "native_static")
load(":pack.bzl", "mojo_conda")
load("//rules/coverage:zig_cover.bzl", "zig_coverage_floor_rule")
load("//rules/mopm:pins.bzl", "vname")
load(":check.bzl", "mojo_check_rule", "mojo_table_rule", "mojo_workspace_rule")
load(":test_data.bzl", "LAYOUT_INSTALLED", "check_installed_tree", "check_test_env", "check_test_layout", "stage_test_data")
load(":unit.bzl", "mojo_cov_branch_annotate_rule", "mojo_cov_branch_classify_rule", "mojo_cov_branch_run_rule", "mojo_cov_pgo_rule", "mojo_cov_run_rule", "mojo_cov_summary_rule", "mojo_gated_lib_rule", "mojo_group", "mojo_prebuilt_rule", "mojo_test_run_rule", "mojo_unit_rule")

SCHEMA = 1

# What `mopm unit build` reads of a unit it only imports (spec/unit-graph.md, "Running a unit"): the ids, the closure, the .mojoc name.
_DEP_FIELDS = ["id", "package", "version", "kind", "root", "deps", "outputs", "mojoc"]

# The profile of a coverage build: no optimisation, every assertion, debug information (`mopm unit build` passes -g).
_COVERAGE_PROFILE = {"opt": 0, "assert": "all", "debug": True}

# The profile of a test's bitcode for branch coverage: the same program as the coverage build (-O0, every assertion), with line tables instead of
# `-g` (the build arguments below ask for `--debug-level line-tables` and for the bitcode in place of the executable).
_BITCODE_PROFILE = {"opt": 0, "assert": "all", "debug": False}
_BITCODE_ARGS = ["--emit", "llvm-bitcode", "--debug-level", "line-tables"]

def _closure(units, uid):
    """Every unit `uid` imports, directly or not (not itself), as sorted ids."""
    seen = {}
    todo = list(units[uid]["deps"])
    for _ in range(len(units) * len(units) + 1):
        if not todo:
            break
        d = todo.pop()
        if d in seen:
            continue
        seen[d] = True
        todo.extend(units[d]["deps"])
    if todo:
        fail("{}: the dependency graph has a cycle".format(uid))
    return sorted(seen.keys())

def _join(*parts):
    return "/".join([p for p in parts if p and p != "."])

def _norm(path):
    """`a/b/../c` -> `a/c`; a path that leaves the repository is a mistake."""
    out = []
    for p in path.split("/"):
        if p in ("", "."):
            continue
        if p == "..":
            if not out:
                fail("{}: leaves the repository".format(path))
            out.pop()
        else:
            out.append(p)
    return "/".join(out)

def _within(path):
    """`a/b/../c` -> `a/c`; None when the path leaves the repository root."""
    out = []
    for p in path.split("/"):
        if p in ("", "."):
            continue
        if p == "..":
            if not out:
                return None
            out.pop()
        else:
            out.append(p)
    return "/".join(out)

def member_label(here, uid, package, root, base, refuse = fail):
    """The target of a path dependency's library, `//<its directory>:lib`, from the `root` of its unit (the graph's, relative to `base`, the directory
    its paths start at: the package's own for a mopm without --workspace-root, the repository root with it). The directory is derived from the
    repository path of the root, so a package next to this one (a sibling) is named like one below it. A root outside the repository root has no
    target, a library that is not at `<dir>/src/<package>` is not a package's library, and one whose directory is `here`, the package that imports it, would
    be that package's own `:lib` (a cycle through its tests): all refused (`refuse` is `fail` in a build; a test passes a recorder,
    rules/rust/refusal.bzl), with None as the answer."""
    repo_root = _within(_join(base, root)) if not root.startswith("/") else None
    if repo_root == None:
        refuse("{}: {} lives in {}, which is outside the repository root: a path dependency must be a directory below the root that holds .buckconfig".format(here, uid, root))
        return None
    suffix = "src/" + package
    if repo_root != suffix and not repo_root.endswith("/" + suffix):
        refuse("{}: {} lives in {}, not <dir>/{}: a workspace member's library must be its package directory's src/<name>".format(here, uid, repo_root, suffix))
        return None
    directory = repo_root[:-len(suffix)].rstrip("/")
    if directory == here:
        refuse("{}: {} lives in {}, the directory of the package that imports it: its library would be this package's own :lib, which waits for the tests that import it. A path dependency must be a package of its own (a directory with its own BUCK file and mopm.toml), not the importing package itself".format(here, uid, repo_root))
        return None
    return "//" + directory + ":lib"

def _relative(frm, to):
    """The path to the directory `to` from the directory `frm`, both repository paths without a leading slash (`..` for each part of `frm` that `to` does not share)."""
    a = [p for p in frm.split("/") if p]
    b = [p for p in to.split("/") if p]
    i = 0
    for _ in range(min(len(a), len(b))):
        if a[i] != b[i]:
            break
        i += 1
    return "/".join([".."] * (len(a) - i) + b[i:])

def graph_path_in_package(path, pkg_dir, rooted, refuse = fail):
    """A path of the graph as a path below the package's directory. The graph's paths start at the package, or at the repository root when mopm was given
    --workspace-root (`rooted`): then the package's own directory is the first part of every path of its own units."""
    if not rooted or not pkg_dir:
        return path
    if not path.startswith(pkg_dir + "/"):
        refuse("{}: the graph names {}, which is not below the package's directory".format(pkg_dir, path))
        return path
    return path[len(pkg_dir) + 1:]

def native_include_dirs(u, pkg_dir, rooted, refuse = fail):
    """The include directories of a native unit, below the package's directory. mopm prints a unit's `includes` as the manifest wrote them (directories below
    the member) in both graph bases, and when the manifest names none (or an empty list, `len > 0`) it prints the directories of the headers relative to the member (`addNatives` in
    mopm v0.0.42 `src/core/unit_graph.zig`, the `includes` binding: `n.includes` if given, else `dirsOf` of each header's path with `member_rel` cut off).
    So `includes` is used as printed, never rooted again; only the headers of the default carry the repository root when the graph is rooted, and are cut
    to the package first."""
    if len(u.get("includes") or []) > 0:
        return u["includes"]
    hdrs = [graph_path_in_package(h["path"], pkg_dir, rooted, refuse) for h in u.get("hdrs", [])]
    # A header at the member's directory is `.`, as `dirsOf` prints it.
    return sorted({(h.rpartition("/")[0] or "."): True for h in hdrs}.keys())

def stage_package_test_data(where, test_graph_of, lib_names, test_data, installed, refuse = fail):
    """The staged data of each test of a package, `{test source as the package names it: {staged path: label or file}}`. `test_graph_of` maps a test as the
    package names it (`tests/test_x.mojo`) to the path the graph gives it (the same, or below the repository root for a rooted graph); the tree of a
    coverage run holds the test at the graph's name, so that is the name a staged path may not collide with. `lib_names` are the library sources of that
    tree. The installed layout stages the data apart from the sources, so nothing can collide there."""
    tests = sorted(test_graph_of.keys())
    held = {t: ([] if installed else [test_graph_of[t]] + sorted(lib_names)) for t in tests}
    return stage_test_data(where, tests, test_data, held, refuse)

TOOLCHAIN_FILE = "mopm-toolchain.toml"

# mopm-toolchain.toml is required: no mopm and no Mojo is chosen for a package that does not name them.
TOOLCHAIN_FILE_HELP = ("{} is required and there is no default. Create it at or above the package directory, for example:\n\n" +
                       "[toolchain]\nmopm = \"0.0.42\"\nmojo = \"1.0.0\"\n\n(an exact release each), then run `buildrules mojo sync`.").format(TOOLCHAIN_FILE)

def check_toolchain_file_recorded(t, refuse = fail):
    """A table made without mopm-toolchain.toml (or by hand) is refused: the file is what chooses mopm and Mojo. `refuse` is `fail` in a
    build; a test passes a recorder (rules/rust/refusal.bzl)."""
    names = [k for k in t.get("MANIFEST_SHA256", {}).keys() if k.split("/")[-1] == TOOLCHAIN_FILE]
    if not names:
        refuse("buildrules.mojo.lock.bzl records no {}: {}".format(TOOLCHAIN_FILE, TOOLCHAIN_FILE_HELP))

def check_toolchain_file_present(where, present, refuse = fail):
    """The file the table names is not in the checkout (`present` is the result of a glob): refused, naming the file and an example."""
    if not present:
        refuse("{}: {}".format(where, TOOLCHAIN_FILE_HELP))

def _check_table(t):
    check_toolchain_file_recorded(t)
    if t.get("SCHEMA") != SCHEMA:
        fail("buildrules.mojo.lock.bzl has SCHEMA {} but these rules read {}: run `buildrules mojo sync` with a matching buildrules".format(t.get("SCHEMA"), SCHEMA))
    g = t["GRAPH"]
    if g["unit_graph"] not in (1, 2):
        fail("the committed unit graph is format {}; these rules read formats 1 and 2 (2 adds the native unit of a member's own library)".format(g["unit_graph"]))
    if g["mojo"] != t["MOJO"] or g["toolchain"]["mojo"] != t["MOJO"]:
        fail("the table says Mojo {} but its unit graph is for Mojo {}: run `buildrules mojo sync`".format(t["MOJO"], g["mojo"]))
    if g["toolchain"]["closure_sha256"] != t["CLOSURE_SHA256"]:
        fail("the table records toolchain closure {} but its unit graph pins {}: the file was edited by hand; run `buildrules mojo sync`".format(t["CLOSURE_SHA256"], g["toolchain"]["closure_sha256"]))

def own_static_natives(unit):
    """The static native libraries a registry package ships, `{soname: sha256}`, in the order of the unit's `natives` (mopm's link order). The
    unit of a prebuilt package lists its whole closure's natives; these are the ones of `unit["package"]` itself, which come out of its `.conda`."""
    return {n["soname"]: n["sha256"] for n in unit["natives"] if n.get("kind") == "static" and n["package"] == unit["package"]}

def is_native_unit(uid):
    """A native unit of the graph (`native:<package>/<id>`): a static library a workspace member builds from its own C sources."""
    return uid.startswith("native:")

def native_unit_id(uid):
    """The id of the native in its member's manifest (`[native.<id>]`) out of the unit id `native:<package>/<id>`."""
    return uid[len("native:"):].partition("/")[2]

def native_wiring(unit, prebuilt_packages, user_natives, here, refuse = fail, built = {}):
    """Where each native library of `unit` comes from: `(sonames, labels)`, `sonames` in the order mopm's graph lists them (a library before every
    library it needs: the order of the link line) and `labels` the target for each. A static library of a registry package of the graph is the
    sub-target `:prebuilt_<package>[<soname>]` of the unpacked `.conda`, so the lock alone gives it; a library a workspace member builds (an entry
    with `built`, the id of a native unit) is `built[<that id>]`, the target of the member's `native_static`; every other native (a shared library)
    is a user's `natives = {soname: target}` entry. A library the lock or the graph provides that `user_natives` also names is refused: two sources
    for one file. `refuse` is `fail` in a build; a test passes a recorder (rules/rust/refusal.bzl)."""
    sonames = []
    labels = {}
    for n in unit["natives"]:
        soname = n["soname"]
        sonames.append(soname)
        owner = n["package"]
        if n.get("built"):
            if n["built"] not in built:
                refuse("{}: {} links the native library {}, built by {}, and the graph has no such native unit".format(here, unit["id"], soname, n["built"]))
            elif soname in user_natives:
                refuse("{}: the native library {} is built by the member {} ({}); remove it from mojo_package(natives = {{...}})".format(here, soname, owner, n["built"]))
            else:
                labels[soname] = built[n["built"]]
        elif n.get("kind") == "static" and owner in prebuilt_packages:
            if soname in user_natives:
                refuse("{}: the native library {} comes from the lock (the registry package {}); remove it from mojo_package(natives = {{...}})".format(here, soname, owner))
            labels[soname] = ":prebuilt_{}[{}]".format(owner, soname)
        elif soname in user_natives:
            labels[soname] = user_natives[soname]
        else:
            refuse("{}: {} links the native library {}; add it to mojo_package(natives = {{...}})".format(here, unit["id"], soname))
    return sonames, labels

COVERAGE_FLOOR_FILE = "coverage_floor.txt"

def mojo_coverage_floor(name, coverage, floor, visibility = ["PUBLIC"]):
    """Green only while the `coverage.txt` of `coverage` (a mojo_package's `:coverage`) is at least the figures of the file `floor` (`lines NN.NN`):
    lower fails with "coverage fell", at or above passes, and above prints "you may raise the floor to NN.NN" (rules/coverage/tools/cov_floor.zig). `mojo_package` makes
    `:coverage_floor` itself when `coverage_floor.txt` is beside the BUCK file; this is for a check of the same coverage against another file."""
    zig_coverage_floor_rule(
        name = name,
        coverage = coverage,
        floor = floor,
        exec_compatible_with = LINUX_X86_64,
        visibility = visibility,
    )

def mojo_package(path = ".", table = None, natives = {}, test_data = {}, test_env = {}, test_layout = "default", conda = False, visibility = ["PUBLIC"]):
    if table == None:
        fail("mojo_package needs its table: load mojo_package from the buildrules.mojo.bzl next to mopm.toml (`buildrules mojo sync` writes it)")
    _check_table(table)
    graph = table["GRAPH"]
    mojo = table["MOJO"]
    project = "" if path == "." else path
    here = native.package_name()

    # Where the graph's paths start. A mopm that was given --workspace-root (the table says so: `MOPM.workspace_root`) printed them relative to the
    # repository root; an older one relative to the package's directory.
    pkg_dir = _join(here, project)
    rooted = table["MOPM"].get("workspace_root", False)
    graph_from = "" if rooted else pkg_dir
    units = {u["id"]: u for u in graph["units"]}
    root = graph["package"].split("@")[0]
    prebuilt_packages = {u["package"]: True for u in graph["units"] if u["kind"] == "prebuilt"}
    toolchain = "toolchains//:mojo_" + vname(mojo)
    mopm = "toolchains//:mopm_" + vname(table["MOPM"]["version"])
    build_args = isa_select(lambda l: list(ISA_LEVELS[l]["mojo"]), [])
    taken = {}

    def name_once(n):
        if n in taken:
            fail("{}: two units want the target name {}".format(here, n))
        taken[n] = True
        return n

    # :check, the validation of every step: the files the table was made from, as targets (this package exports its own mopm.toml and
    # mopm.lock, which a package that imports it as a member refers to; the toolchain file is exported by the BUCK file of its directory,
    # which `buildrules mojo sync` writes), compared with the table's hashes, and the toolchain pins with the table's graph.
    native.export_file(name = name_once("mopm.toml"), src = _join(project, "mopm.toml"), visibility = ["PUBLIC"])
    native.export_file(name = name_once("mopm.lock"), src = _join(project, "mopm.lock"), visibility = ["PUBLIC"])
    check_files, check_hashes, check_names = [], [], []
    for key, h in sorted(table["MANIFEST_SHA256"].items()):
        full = _norm(_join(pkg_dir, key))
        d, _, base = full.rpartition("/")
        if base in ("mopm.toml", "mopm.lock") and d == pkg_dir:
            label = ":" + base
        elif d == here:
            label = ":" + base
            if base != "mopm-toolchain.toml":
                fail("{}: the table names {}, which this package does not export".format(here, key))
            own = full[len(here) + 1:] if here else full
            check_toolchain_file_present(here, glob([own]))
            native.export_file(name = name_once(base), src = own, visibility = ["PUBLIC"])
        else:
            label = "//" + d + ":" + base
        check_files.append(label)
        check_hashes.append(h)
        check_names.append(full)
    mojo_check_rule(
        name = name_once("check"),
        expect_toolchain = {k: v for k, v in graph["toolchain"].items() if k != "mojo"},
        files = check_files,
        hashes = check_hashes,
        mojo = mojo,
        names = check_names,
        toolchain = toolchain,
        exec_compatible_with = LINUX_X86_64,
        visibility = visibility,
    )

    # The path dependencies of the graph (libraries of other packages that mopm read from a directory): the target of each one's library. A dependency
    # may be below this package or next to it; the directory comes from its root, a path from the repository root (`graph_from` is where the graph's paths
    # start: the root when mopm was given --workspace-root, else the package).
    member_libs = {}
    for mu in graph["units"]:
        if mu["kind"] == "lib" and mu["package"] != root and not is_native_unit(mu["id"]):
            member_libs[mu["id"]] = member_label(here, mu["id"], mu["package"], mu["root"], graph_from)

    # :table, the check that the committed graph is what the pinned mopm prints now (rules/mojo/check.bzl). mopm reads the whole workspace, so `:workspace`
    # lays out this package's files with the workspace of every path dependency, flat, each file at its path from the repository root.
    mojo_workspace_rule(
        name = name_once("workspace"),
        files = glob([_join(project, "**/*")], exclude = [_join(project, n) for n in ["BUCK", "buildrules.mojo.bzl", "buildrules.mojo.lock.bzl", COVERAGE_FLOOR_FILE]]),
        members = sorted({l[:-len(":lib")] + ":workspace": True for l in member_libs.values() if l != None}.keys()),
        visibility = ["PUBLIC"],
    )
    mojo_table_rule(
        name = name_once("table"),
        mojo = mojo,
        mopm = mopm,
        package_dir = pkg_dir,
        table = _join(project, "buildrules.mojo.lock.bzl"),
        workspace = ":workspace",
        workspace_root = rooted,
        exec_compatible_with = LINUX_X86_64,
        visibility = visibility,
    )

    def label_of(uid, own = ":lib"):
        # `own` is the target of this package's own library: `:lib`, the one behind the tests, for everything but the tests, which
        # import the compiled `:lib_ungated` (they are what `:lib` waits for).
        u = units[uid]
        if u["kind"] == "prebuilt":
            return ":prebuilt_" + u["package"]
        if u["package"] == root:
            return own
        return member_libs[uid]

    def in_package(path):
        # A path of the graph below this package's directory (what the BUCK file's labels are relative to).
        return graph_path_in_package(path, pkg_dir, rooted)

    def slice_of(uid, profile = None):
        # The unit's own entry, whole but for its `key`; every unit it imports reduced to what `mopm unit build` reads of a dependency
        # (its identity, its place in the graph and the name of its .mojoc). A dependency's sources, key and profile are not inputs
        # of this unit: they change when the dependency changes, and what this unit is built from is the dependency's `.mojoc`, an input
        # of the action by its digest. mopm's `key` hashes every dependency's key, so it moves with any edit below the unit; Buck2's own
        # action key replaces it, and a rebuild that leaves a dependency's `.mojoc` as it was stops there (docs/contract.md, section 12).
        # The native units a `built` entry of the unit names stay whole (but for their `key`): the archive is the unit's input, and the
        # entry has to name a unit of the graph it is given.
        cut = []
        wanted = {n["built"]: True for n in units[uid]["natives"] if n.get("built")}
        for i in sorted(_closure(units, uid) + [uid] + [b for b in wanted.keys() if b in units]):
            u = units[i]
            if i == uid or is_native_unit(i):
                u = {k: v for k, v in u.items() if k != "key"}
                if profile and i == uid:
                    u["profile"] = profile
            else:
                u = {k: v for k, v in u.items() if k in _DEP_FIELDS}
            cut.append(u)
        return json.encode({
            "unit_graph": graph["unit_graph"],
            "package": graph["package"],
            "mojo": graph["mojo"],
            "toolchain": graph["toolchain"],
            "units": cut,
        })

    def member_package_label(package):
        # The package (`//<dir>`) of the workspace member `package`, from the target of its library (`member_label` has refused a root it cannot name).
        for mid in sorted(member_libs.keys()):
            if units[mid]["package"] == package and member_libs[mid] != None:
                return member_libs[mid][:-len(":lib")]
        fail("{}: the graph has no library of the package {}".format(here, package))

    def native_label(uid):
        # The archive target of a native unit: this package's own (`:native_<id>`), or the member's (its `native_static`, in the member's package).
        # The names are the contract with a repository that lists a library by its target (docs/contract.md, section 12).
        nid = native_unit_id(uid)
        u = units[uid]
        if u["package"] == root:
            return ":native_" + nid
        return member_package_label(u["package"]) + ":native_" + nid

    native_units = [uid for uid in sorted(units.keys()) if is_native_unit(uid)]
    built_labels = {uid: native_label(uid) for uid in native_units}

    def target_of_soname(soname):
        # The target that provides `soname` to a native unit that needs it: a member's archive, a registry package's, or a library of `natives = {...}`.
        for uid in sorted(units.keys()):
            for n in units[uid].get("natives", []):
                if n["soname"] != soname:
                    continue
                if n.get("built"):
                    return built_labels.get(n["built"])
                if n.get("kind") == "static" and n["package"] in prebuilt_packages:
                    return ":prebuilt_{}[{}]".format(n["package"], soname)
                if soname in natives:
                    return natives[soname]
        return None

    def common(uid, kind, product, profile = None):
        u = units[uid]
        cl = _closure(units, uid)
        sonames, native_labels = native_wiring(u, prebuilt_packages, natives, here, built = built_labels)
        return dict(
            deps = [label_of(d, ":lib_ungated" if kind == "test" else ":lib") for d in u["deps"]],
            graph = slice_of(uid, profile),
            kind = kind,
            mojo = mojo,
            mopm = mopm,
            native_sonames = sonames,
            natives = native_labels,
            closure_ids = {units[c]["package"]: c for c in cl},
            graph_base = graph_from,
            package = u["package"],
            product = product,
            check = ":check",
            src_paths = [s["path"] for s in u["srcs"]],
            srcs = [_join(project, in_package(s["path"])) for s in u["srcs"]],
            toolchain = toolchain,
            unit_id = uid,
            exec_compatible_with = LINUX_X86_64,
            visibility = visibility,
        )

    # The package's own native libraries (`[native.<id>]` of its manifest, a native unit of the graph): the sources compiled by the pinned zig at the
    # platform baseline into `:native_<id>_cxx`, and the archive of it, `:native_<id>`, behind the checks of rules/cxx/archive. Every unit that links the
    # library (this package's, and every dependent member's) lists it in `natives` with `built`, and `native_wiring` maps that to the target.
    own_native_ids = {}
    here_repo = _join(here, project)
    for uid in native_units:
        u = units[uid]
        if u["package"] != root:
            continue
        nid = native_unit_id(uid)
        if u.get("kind") == "shared":
            fail("{}: {} is a shared library; a member's native library is static".format(here, uid))
        # The files of the native unit are named as the graph names every file: from the repository root when it is rooted, so below the package like the
        # Mojo sources. Its `includes` are directories below the package whichever base the graph prints (`native_include_dirs`: mopm prints them
        # package-relative, so they are not rooted again).
        srcs = [in_package(s["path"]) for s in u.get("srcs", [])]
        if not srcs:
            fail("{}: the native unit {} has no source".format(here, uid))
        hdrs = [in_package(h["path"]) for h in u.get("hdrs", [])]
        dirs = native_include_dirs(u, pkg_dir, rooted)
        needs = []
        for s in u.get("needs", []):
            t = target_of_soname(s)
            if t == None:
                fail("{}: {} needs the library {}, which no unit of the graph and no entry of natives = {{...}} provides".format(here, uid, s))
            needs.append(t)
        soname = u.get("soname") or "lib{}.a".format(nid)
        own_native_ids[nid] = soname
        name_once("native_" + nid + "_cxx")
        native_static(
            name = name_once("native_" + nid),
            srcs = [_join(project, p) for p in srcs],
            hdrs = [_join(project, p) for p in hdrs],
            includes = [_join(here_repo, d) or "." for d in dirs],
            cflags = u.get("cflags", []),
            cflags_by_os = u.get("cflags_by_os", {}),
            soname = soname,
            needs = needs,
            file_prefix = here_repo,
            visibility = visibility,
        )

    libs = []
    builds = []
    tests = []
    covs = []
    # The package's own library: the sources kcov measures, at the names the line tables of a test give them (`<import>/<file>`).
    own_lib = None
    for uid in sorted(units.keys()):
        if units[uid]["kind"] == "lib" and units[uid]["package"] == root and not is_native_unit(uid):
            own_lib = units[uid]
    branches = []
    branch_tc = "toolchains//:mojo_{}_cov_branch".format(vname(mojo))
    # Branch coverage of the package's tests (rules/coverage/branch/README.md): bitcode, an instrumented binary, its run, the annotated IR and
    # the classified records, five actions after the compile. A test that links native libraries is instrumented too: its instrumented link is given
    # the same libraries in the same order (`__pgo`), and its run finds the shared ones through the library path. A package with `test_layout = "installed"`
    # runs the instrumented binary in the installed layout too (`__profdata` is given the layout), so it has branch rows like any other.
    branches_on = own_lib != None and bool([x for x in units.values() if x["kind"] == "test"])

    # The library's sources: in the coverage tree at the names its `.mojoc` gives them (`<import>/<file>`), and for the classifier by the name relative
    # to the library root.
    lib_share = {}
    lib_srcs = {}
    if own_lib:
        prefix = own_lib["root"] + "/"
        for s in own_lib["srcs"]:
            if not s["path"].startswith(prefix):
                fail("{}: source {} is not under the library root {}".format(here, s["path"], own_lib["root"]))
            lib_share[root + "/" + s["path"][len(prefix):]] = _join(project, in_package(s["path"]))
            lib_srcs[s["path"][len(prefix):]] = _join(project, in_package(s["path"]))

    # What the tests are given besides their binaries (rules/mojo/test_data.bzl): `test_data` per test file, `test_env` for all. The coverage run's
    # working directory holds the test's source and the library's sources, so a staged path may not be one of those.
    # `test_data` names a test as the package does (below its directory, `tests/test_x.mojo`), whatever base the graph prints; the tree of a run holds the
    # test at the name the graph gives it (`test_graph_of`), which is what a staged path may not collide with.
    test_graph_of = {in_package(units[u]["srcs"][0]["path"]): units[u]["srcs"][0]["path"] for u in sorted(units.keys()) if units[u]["kind"] == "test"}
    test_sources = sorted(test_graph_of.keys())
    check_test_env(here, test_env)
    check_test_layout(here, test_layout)
    installed = test_layout == LAYOUT_INSTALLED

    # In the installed layout the data is staged under `<root>/share`, apart from the sources the coverage run's root holds beside it, so no staged path can
    # collide with one of them; but those sources may not be in `bin/` or `share/`.
    if installed:
        check_installed_tree(here, sorted(test_graph_of.values()) + sorted(lib_share.keys()))
    staged_by_test = stage_package_test_data(here, test_graph_of, lib_share.keys(), test_data, installed)

    # What the rules below look a test's data up by: the path the graph gives the test.
    staged = {test_graph_of[t]: staged_by_test[t] for t in test_sources}
    for uid in sorted(units.keys()):
        u = units[uid]
        kind = u["kind"]
        if is_native_unit(uid):
            continue
        if kind == "prebuilt":
            if u["package"] == root:
                fail("{}: the graph holds a prebuilt unit for the root package itself".format(uid))
            a = u["artifact"]
            pinned_file(name = name_once("prebuilt_" + u["package"] + ".conda"), url = mapped_url(a["url"]), sha256 = a["sha256"], size_bytes = a["size"])
            mojo_prebuilt_rule(
                name = name_once("prebuilt_" + u["package"]),
                archive = ":prebuilt_" + u["package"] + ".conda",
                deps = [label_of(d) for d in u["deps"]],
                natives = own_static_natives(u),
                package = u["package"],
                unit_id = uid,
                visibility = visibility,
                exec_compatible_with = LINUX_X86_64,
            )
        elif kind == "lib" and u["package"] == root:
            mojo_unit_rule(name = name_once("lib_ungated"), **common(uid, "lib", u["outputs"][0]))
            libs.append(":lib")
            builds.append(":lib")
        elif kind == "bin":
            n = u["outputs"][0]
            mojo_unit_rule(name = name_once("bin_" + n), build_args = build_args, **common(uid, "bin", n))
            builds.append(":bin_" + n)
        elif kind == "test":
            out0 = u["outputs"][0]
            stem = out0[:-len(".pass")] if out0.endswith(".pass") else out0
            mojo_unit_rule(name = name_once(stem + "__bin"), build_args = build_args, **common(uid, "test", stem))
            mojo_test_run_rule(
                name = name_once(stem),
                bin = ":" + stem + "__bin",
                check = ":check",
                data = staged[units[uid]["srcs"][0]["path"]],
                test_env = test_env,
                test_layout = test_layout,
                required_isa = required_isa(),
                toolchain = toolchain,
                exec_compatible_with = test_exec_compatible_with(),
                visibility = visibility,
            )
            tests.append(":" + stem)
            # The coverage build of the same test: the unit's profile replaced by a debug build (-O0, line tables), so
            # kcov can map what ran to source lines. Its own graph slice, so its own key; the library under test stays
            # the release unit (docs/contract.md, section 12).
            mojo_unit_rule(
                name = name_once(stem + "__cov_bin"),
                build_args = build_args,
                zig_override = "toolchains//:mojo_{}_cov_link".format(vname(mojo)),
                **common(uid, "test", stem, _COVERAGE_PROFILE)
            )
            # The test file is compiled under the path the graph names (from the package, or from the repository root when the table is rooted), and
            # that is the name in the line tables: the tree kcov runs in, what it measures and the first half of the map use it; the repository path
            # (below the package, then from the repository root) is the other half.
            test_graph = u["srcs"][0]["path"]
            graph_dir = test_graph.rpartition("/")[0]
            test_src = in_package(test_graph)
            test_dir = test_src.rpartition("/")[0]
            share = {test_graph: _join(project, test_src)}
            maps = [(graph_dir + "/=" + _join(here_repo, test_dir) + "/") if graph_dir else "=" + here_repo + "/"]
            includes = [test_graph]
            if own_lib:
                share.update(lib_share)
                maps.append(root + "/=" + _join(here_repo, in_package(own_lib["root"])) + "/")
                includes.append(root)
            mojo_cov_run_rule(
                name = name_once(stem + "__cov"),
                bin = ":" + stem + "__cov_bin",
                check = ":check",
                data = staged[test_graph],
                test_env = test_env,
                test_layout = test_layout,
                includes = includes,
                maps = maps,
                must_contain = _join(here_repo, test_src),
                required_isa = required_isa(),
                share = share,
                toolchain = toolchain,
                exec_compatible_with = test_exec_compatible_with(),
                visibility = visibility,
            )
            covs.append(":" + stem + "__cov")
            if branches_on:
                # The test as bitcode (`mojo build --emit llvm-bitcode`), compiled as the coverage build is; then the five actions.
                mojo_unit_rule(
                    name = name_once(stem + "__bc"),
                    build_args = build_args + _BITCODE_ARGS,
                    **common(uid, "test", stem, _BITCODE_PROFILE)
                )
                # The instrumented link gets the test's native libraries as its ordinary link does (the graph's order and the same targets).
                pgo_sonames, pgo_natives = native_wiring(u, prebuilt_packages, natives, here, built = built_labels)
                mojo_cov_pgo_rule(
                    name = name_once(stem + "__pgo"),
                    bc = ":" + stem + "__bc",
                    branch = branch_tc,
                    check = ":check",
                    native_needs = {n["soname"]: n["needs"] for n in u["natives"] if n.get("needs")},
                    native_sonames = pgo_sonames,
                    natives = pgo_natives,
                    toolchain = toolchain,
                    exec_compatible_with = LINUX_X86_64,
                    visibility = visibility,
                )
                mojo_cov_branch_run_rule(
                    name = name_once(stem + "__profdata"),
                    branch = branch_tc,
                    check = ":check",
                    # The test's staged data and variables, as in its run and its kcov run: it must find the same files here.
                    data = staged[test_graph],
                    pgo = ":" + stem + "__pgo",
                    required_isa = required_isa(),
                    share = share,
                    test_env = test_env,
                    test_layout = test_layout,
                    toolchain = toolchain,
                    exec_compatible_with = test_exec_compatible_with(),
                    visibility = visibility,
                )
                mojo_cov_branch_annotate_rule(
                    name = name_once(stem + "__ir"),
                    bc = ":" + stem + "__bc",
                    branch = branch_tc,
                    check = ":check",
                    pgo = ":" + stem + "__pgo",
                    profdata = ":" + stem + "__profdata",
                    exec_compatible_with = LINUX_X86_64,
                    visibility = visibility,
                )
                mojo_cov_branch_classify_rule(
                    name = name_once(stem + "__info"),
                    check = ":check",
                    # The packages the test imports other than the library are named in the IR by their import names and are not measured.
                    excludes = [units[c]["package"] + "/" for c in _closure(units, uid) if units[c]["package"] != root],
                    exclude_files = [test_graph],
                    ir = ":" + stem + "__ir",
                    map = root + "/=" + _join(here_repo, in_package(own_lib["root"])) + "/",
                    srcs = lib_srcs,
                    exec_compatible_with = LINUX_X86_64,
                    visibility = visibility,
                )
                branches.append(":" + stem + "__info")
    # `:lib`, the library as every other target sees it, exists only if every test of the package passed: its `.mojoc` is made by an
    # action that takes each test run's marker as an input (mojo_gated_lib_rule). The package's own tests import `:lib_ungated`.
    if libs:
        mojo_gated_lib_rule(
            name = name_once("lib"),
            lib = ":lib_ungated",
            test_runs = tests,
            package = own_lib["package"],
            check = ":check",
            exec_compatible_with = LINUX_X86_64,
            visibility = visibility,
        )

    # Line coverage of the package from its tests' reports. Fails when a source of the library is in no report.
    mojo_cov_summary_rule(
        name = name_once("coverage"),
        branches = branches,
        check = ":check",
        expect = [_join(here_repo, in_package(own_lib["root"]), s["path"][len(own_lib["root"]) + 1:]) for s in own_lib["srcs"]] if own_lib and covs else [],
        reports = covs,
        srcs = {_join(here_repo, in_package(own_lib["root"]), s["path"][len(own_lib["root"]) + 1:]): _join(project, in_package(s["path"])) for s in own_lib["srcs"]} if own_lib and covs else {},
        visibility = visibility,
    )
    # `:conda`, the package as a registry would serve it, for a package that builds native libraries of its own: `mopm pack` of the gated `:lib`, with each
    # archive packed as `lib<id>.a` beside the `.mojoc` (rules/mojo/pack.bzl). Its sha256 goes into the lock of a consumer, which gets the archive as a
    # prebuilt: the archive that was tested is the archive that ships.
    if own_native_ids or conda:
        mojo_conda(
            name = name_once("conda"),
            lib = ":lib",
            dir = pkg_dir,
            manifest = ":mopm.toml",
            members = {_relative(pkg_dir, l[2:-len(":lib")]): l[:-len(":lib")] + ":mopm.toml" for l in member_libs.values() if l != None},
            mojo = mojo,
            mopm = mopm,
            natives = {nid: ":native_" + nid for nid in own_native_ids.keys()},
            package = root,
            version = graph["package"].partition("@")[2],
            visibility = visibility,
        )
    # The floor, if the package has one: `coverage_floor.txt` beside the BUCK file (the file every other package's floor is, rules/coverage/README.md).
    # No file, no target: a package without one is as it was.
    floor = _join(project, COVERAGE_FLOOR_FILE)
    if glob([floor]):
        mojo_coverage_floor(name = name_once("coverage_floor"), coverage = ":coverage", floor = floor, visibility = visibility)
    mojo_group(name = name_once("build"), deps = builds, check = ":check", visibility = visibility)
    mojo_group(name = name_once("test"), deps = tests, check = ":check", visibility = visibility)
    mojo_group(name = name_once("ci"), deps = [":build", ":test"], check = ":check", visibility = visibility)
