"""`mojo_package`: the front door of the Mojo rules (docs/contract.md, section 12).

    load(":buildrules.mojo.bzl", "mojo_package")      # written by `buildrules mojo sync`, next to mopm.toml
    mojo_package(path = ".")

One line per package. The targets come from the package's unit graph, which `buildrules mojo sync` committed as
`buildrules.mojo.lock.bzl` (mopm's own output, verbatim): nothing here parses mopm.toml or decides what "build Mojo" means.

    :lib        the package's `.mojoc` (mode `lib`), behind the run of every test: it exists only if they all pass (below)
    :lib_ungated  the same `.mojoc` as compiled, which the package's own tests import (what `:lib` waits for)
    :test       every test file, built once and run: `:<stem>` (the run) behind `:<stem>__bin` (the compile)
    :build      the library and the binaries of `[targets] bins`
    :coverage   every test again as a debug build run under kcov, one Cobertura report per test file
    :ci         `:build` and `:test`
    :table      the committed graph is, byte for byte, what the pinned mopm prints now (a check of its own; `:workspace` holds the files it reads)

A workspace member (a path dependency) is a package of its own with its own BUCK file; this package's graph names it, and
its `:lib` is what the units here import. A registry dependency is a sha256-pinned `.conda`, matched to the graph's Mojo version
by mopm, fetched and unpacked here. Native libraries are declared inputs and mopm checks each against the sha256 in the graph before it compiles
anything. The static libraries (`lib<stem>.a`) of a registry package come from the lock: the `.conda` that holds the `.mojoc` holds them too,
`prebuilt_unpack` takes each out after hashing it against the lock's value, and a unit links them in the graph's order (a library before every
library it needs) with nothing written in the BUCK file. Any other native library (a shared one, a workspace member's) is an entry of
`natives = {"<soname>": "<target>"}`; one the lock provides may not also be named there.

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
load("//rules/mopm:pins.bzl", "vname")
load(":check.bzl", "mojo_check_rule", "mojo_table_rule", "mojo_workspace_rule")
load(":unit.bzl", "mojo_cov_run_rule", "mojo_cov_summary_rule", "mojo_gated_lib_rule", "mojo_group", "mojo_prebuilt_rule", "mojo_test_run_rule", "mojo_unit_rule")

SCHEMA = 1

# What `mopm unit build` reads of a unit it only imports (spec/unit-graph.md, "Running a unit"): the ids, the closure, the .mojoc name.
_DEP_FIELDS = ["id", "package", "version", "kind", "root", "deps", "outputs", "mojoc"]

# The profile of a coverage build: no optimisation, every assertion, debug information (`mopm unit build` passes -g).
_COVERAGE_PROFILE = {"opt": 0, "assert": "all", "debug": True}

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

def graph_path_in_package(path, pkg_dir, rooted, refuse = fail):
    """A path of the graph as a path below the package's directory. The graph's paths start at the package, or at the repository root when mopm was given
    --workspace-root (`rooted`): then the package's own directory is the first part of every path of its own units."""
    if not rooted or not pkg_dir:
        return path
    if not path.startswith(pkg_dir + "/"):
        refuse("{}: the graph names {}, which is not below the package's directory".format(pkg_dir, path))
        return path
    return path[len(pkg_dir) + 1:]

TOOLCHAIN_FILE = "mopm-toolchain.toml"

# mopm-toolchain.toml is required: no mopm and no Mojo is chosen for a package that does not name them.
TOOLCHAIN_FILE_HELP = ("{} is required and there is no default. Create it at or above the package directory, for example:\n\n" +
                       "[toolchain]\nmopm = \"0.0.20\"\nmojo = \"1.0.0\"\n\n(an exact release each), then run `buildrules mojo sync`.").format(TOOLCHAIN_FILE)

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
    if g["unit_graph"] != 1:
        fail("the committed unit graph is format {}; these rules read format 1".format(g["unit_graph"]))
    if g["mojo"] != t["MOJO"] or g["toolchain"]["mojo"] != t["MOJO"]:
        fail("the table says Mojo {} but its unit graph is for Mojo {}: run `buildrules mojo sync`".format(t["MOJO"], g["mojo"]))
    if g["toolchain"]["closure_sha256"] != t["CLOSURE_SHA256"]:
        fail("the table records toolchain closure {} but its unit graph pins {}: the file was edited by hand; run `buildrules mojo sync`".format(t["CLOSURE_SHA256"], g["toolchain"]["closure_sha256"]))

def own_static_natives(unit):
    """The static native libraries a registry package ships, `{soname: sha256}`, in the order of the unit's `natives` (mopm's link order). The
    unit of a prebuilt package lists its whole closure's natives; these are the ones of `unit["package"]` itself, which come out of its `.conda`."""
    return {n["soname"]: n["sha256"] for n in unit["natives"] if n.get("kind") == "static" and n["package"] == unit["package"]}

def native_wiring(unit, prebuilt_packages, user_natives, here, refuse = fail):
    """Where each native library of `unit` comes from: `(sonames, labels)`, `sonames` in the order mopm's graph lists them (a library before every
    library it needs: the order of the link line) and `labels` the target for each. A static library of a registry package of the graph is the
    sub-target `:prebuilt_<package>[<soname>]` of the unpacked `.conda`, so the lock alone gives it; every other native (a shared library,
    a workspace member's) is a user's `natives = {soname: target}` entry. A library the lock provides that `user_natives` also names is refused:
    two sources for one file. `refuse` is `fail` in a build; a test passes a recorder (rules/rust/refusal.bzl)."""
    sonames = []
    labels = {}
    for n in unit["natives"]:
        soname = n["soname"]
        sonames.append(soname)
        owner = n["package"]
        if n.get("kind") == "static" and owner in prebuilt_packages:
            if soname in user_natives:
                refuse("{}: the native library {} comes from the lock (the registry package {}); remove it from mojo_package(natives = {{...}})".format(here, soname, owner))
            labels[soname] = ":prebuilt_{}[{}]".format(owner, soname)
        elif soname in user_natives:
            labels[soname] = user_natives[soname]
        else:
            refuse("{}: {} links the native library {}; add it to mojo_package(natives = {{...}})".format(here, unit["id"], soname))
    return sonames, labels

def mojo_package(path = ".", table = None, natives = {}, visibility = ["PUBLIC"]):
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
        if mu["kind"] == "lib" and mu["package"] != root:
            member_libs[mu["id"]] = member_label(here, mu["id"], mu["package"], mu["root"], graph_from)

    # :table, the check that the committed graph is what the pinned mopm prints now (rules/mojo/check.bzl). mopm reads the whole workspace, so `:workspace`
    # lays out this package's files with the workspace of every path dependency, flat, each file at its path from the repository root.
    mojo_workspace_rule(
        name = name_once("workspace"),
        files = glob([_join(project, "**/*")], exclude = [_join(project, n) for n in ["BUCK", "buildrules.mojo.bzl", "buildrules.mojo.lock.bzl"]]),
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
        cut = []
        for i in sorted(_closure(units, uid) + [uid]):
            u = units[i]
            if i == uid:
                u = {k: v for k, v in u.items() if k != "key"}
                if profile:
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

    def common(uid, kind, product, profile = None):
        u = units[uid]
        cl = _closure(units, uid)
        sonames, native_labels = native_wiring(u, prebuilt_packages, natives, here)
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

    libs = []
    builds = []
    tests = []
    covs = []
    # The package's own library: the sources kcov measures, at the names the line tables of a test give them (`<import>/<file>`).
    own_lib = None
    for uid in sorted(units.keys()):
        if units[uid]["kind"] == "lib" and units[uid]["package"] == root:
            own_lib = units[uid]
    here_repo = _join(here, project)
    for uid in sorted(units.keys()):
        u = units[uid]
        kind = u["kind"]
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
            test_src = in_package(u["srcs"][0]["path"])
            test_dir = test_src.rpartition("/")[0]
            share = {test_src: _join(project, test_src)}
            maps = [(test_dir + "/=" + _join(here_repo, test_dir) + "/") if test_dir else "=" + here_repo + "/"]
            includes = [test_src]
            if own_lib:
                prefix = own_lib["root"] + "/"
                for s in own_lib["srcs"]:
                    if not s["path"].startswith(prefix):
                        fail("{}: source {} is not under the library root {}".format(here, s["path"], own_lib["root"]))
                    share[root + "/" + s["path"][len(prefix):]] = _join(project, in_package(s["path"]))
                maps.append(root + "/=" + _join(here_repo, in_package(own_lib["root"])) + "/")
                includes.append(root)
            mojo_cov_run_rule(
                name = name_once(stem + "__cov"),
                bin = ":" + stem + "__cov_bin",
                check = ":check",
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
        check = ":check",
        expect = [_join(here_repo, in_package(own_lib["root"]), s["path"][len(own_lib["root"]) + 1:]) for s in own_lib["srcs"]] if own_lib and covs else [],
        reports = covs,
        srcs = {_join(here_repo, in_package(own_lib["root"]), s["path"][len(own_lib["root"]) + 1:]): _join(project, in_package(s["path"])) for s in own_lib["srcs"]} if own_lib and covs else {},
        visibility = visibility,
    )
    mojo_group(name = name_once("build"), deps = builds, check = ":check", visibility = visibility)
    mojo_group(name = name_once("test"), deps = tests, check = ":check", visibility = visibility)
    mojo_group(name = name_once("ci"), deps = [":build", ":test"], check = ":check", visibility = visibility)
