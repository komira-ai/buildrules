"""`mojo_package`: the front door of the Mojo rules (docs/contract.md, section 12).

    load(":buildrules.mojo.bzl", "mojo_package")      # written by `buildrules mojo sync`, next to mopm.toml
    mojo_package(path = ".")

One line per package. The targets come from the package's unit graph, which `buildrules mojo sync` committed as
`buildrules.mojo.lock.bzl` (mopm's own output, verbatim): nothing here parses mopm.toml or decides what "build Mojo" means.

    :lib        the package's `.mojoc` (mode `lib`)
    :test       every test file, built once and run: `:<stem>` (the run) behind `:<stem>__bin` (the compile)
    :build      the library and the binaries of `[targets] bins`
    :coverage   every test again as a debug build run under kcov, one Cobertura report per test file
    :ci         `:build` and `:test`

A workspace member (a path dependency) is a package of its own with its own BUCK file; this package's graph names it, and
its `:lib` is what the units here import. A registry dependency is a sha256-pinned `.conda`, matched to the graph's Mojo version
by mopm, fetched and unpacked here. Native libraries are declared inputs: `natives = {"<soname>": "<target>"}`; mopm checks
each against the sha256 in the graph before it compiles anything.

The ISA level of the target platform reaches the test and binary builds as compiler flags (rules/isa.bzl, one table for every
toolchain) and the test runs as the platform's `exec_compatible_with`, so the farm schedules it on a worker that has the level.
"""

load("//rules:isa.bzl", "ISA_LEVELS", "isa_select", "required_isa", "test_exec_compatible_with")
load("//rules/core:pinned_file.bzl", "pinned_file")
load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/core:url_map.bzl", "mapped_url")
load("//rules/mopm:pins.bzl", "vname")
load(":check.bzl", "mojo_check_rule")
load(":unit.bzl", "mojo_cov_run_rule", "mojo_cov_summary_rule", "mojo_group", "mojo_prebuilt_rule", "mojo_test_run_rule", "mojo_unit_rule")

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

TOOLCHAIN_FILE = "mopm-toolchain.toml"

# mopm-toolchain.toml is required: no mopm and no Mojo is chosen for a package that does not name them.
TOOLCHAIN_FILE_HELP = ("{} is required and there is no default. Create it at or above the package directory, for example:\n\n" +
                       "[toolchain]\nmopm = \"0.0.1\"\nmojo = \"1.0.0\"\n\n(an exact release each), then run `buildrules mojo sync`.").format(TOOLCHAIN_FILE)

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

def mojo_package(path = ".", table = None, natives = {}, visibility = ["PUBLIC"]):
    if table == None:
        fail("mojo_package needs its table: load mojo_package from the buildrules.mojo.bzl next to mopm.toml (`buildrules mojo sync` writes it)")
    _check_table(table)
    graph = table["GRAPH"]
    mojo = table["MOJO"]
    project = "" if path == "." else path
    here = native.package_name()
    units = {u["id"]: u for u in graph["units"]}
    root = graph["package"].split("@")[0]
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
    pkg_dir = _join(here, project)
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


    def label_of(uid):
        u = units[uid]
        if u["kind"] == "prebuilt":
            return ":prebuilt_" + u["package"]
        if u["package"] == root:
            return ":lib"
        suffix = "src/" + u["package"]
        r = u["root"]
        if r != suffix and not r.endswith("/" + suffix):
            fail("{}: {} lives in {}, not <dir>/{}: a workspace member's library must be its package directory's src/<name>".format(here, uid, r, suffix))
        member = r[:-len(suffix)].rstrip("/")
        return "//" + _join(here, project, member) + ":lib"

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
        sonames = [n["soname"] for n in u["natives"]]
        for s in sonames:
            if s not in natives:
                fail("{}: {} links the native library {}; add it to mojo_package(natives = {{...}})".format(here, uid, s))
        return dict(
            deps = [label_of(d) for d in u["deps"]],
            graph = slice_of(uid, profile),
            kind = kind,
            mojo = mojo,
            mopm = mopm,
            native_sonames = sonames,
            natives = {s: natives[s] for s in sonames},
            closure_names = [units[c]["package"] for c in cl],
            package = u["package"],
            product = product,
            check = ":check",
            src_paths = [s["path"] for s in u["srcs"]],
            src_root = project,
            srcs = [_join(project, s["path"]) for s in u["srcs"]],
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
                package = u["package"],
                unit_id = uid,
                visibility = visibility,
                exec_compatible_with = LINUX_X86_64,
            )
        elif kind == "lib" and u["package"] == root:
            mojo_unit_rule(name = name_once("lib"), **common(uid, "lib", u["outputs"][0]))
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
            test_src = u["srcs"][0]["path"]
            test_dir = test_src.rpartition("/")[0]
            share = {test_src: _join(project, test_src)}
            maps = [(test_dir + "/=" + _join(here_repo, test_dir) + "/") if test_dir else "=" + here_repo + "/"]
            includes = [test_src]
            if own_lib:
                prefix = own_lib["root"] + "/"
                for s in own_lib["srcs"]:
                    if not s["path"].startswith(prefix):
                        fail("{}: source {} is not under the library root {}".format(here, s["path"], own_lib["root"]))
                    share[root + "/" + s["path"][len(prefix):]] = _join(project, s["path"])
                maps.append(root + "/=" + _join(here_repo, own_lib["root"]) + "/")
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
    # Line coverage of the package from its tests' reports. Fails when a source of the library is in no report.
    mojo_cov_summary_rule(
        name = name_once("coverage"),
        check = ":check",
        expect = [_join(here_repo, own_lib["root"], s["path"][len(own_lib["root"]) + 1:]) for s in own_lib["srcs"]] if own_lib and covs else [],
        reports = covs,
        visibility = visibility,
    )
    mojo_group(name = name_once("build"), deps = builds, check = ":check", visibility = visibility)
    mojo_group(name = name_once("test"), deps = tests, check = ":check", visibility = visibility)
    mojo_group(name = name_once("ci"), deps = [":build", ":test"], check = ":check", visibility = visibility)
