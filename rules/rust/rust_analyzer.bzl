"""Code intelligence as a build product: `rust_analyzer_inputs`, the files rust-analyzer needs that only a build makes.

rust-analyzer reads a workspace's sources itself; what it cannot make without a build is (1) the sources of registry and git crates,
(2) what build scripts write (OUT_DIR, and the `--cfg` and `rustc-env` they print), (3) proc-macros compiled to shared objects
it can load, and (4) the standard library: a sysroot whose proc-macro server is the release that compiled those shared objects,
and its sources. This target builds all of them on the farm and gathers them into one directory; `buildrules rust-project develop`
(cli/src/rust_project.zig) builds it, downloads the directory and writes rust-project.json from the generated table and the
directory's `index.json`. Nothing reads a host rustc, cargo or rust-analyzer: the three come from the pinned toolchain
(rules/rust/pins.bzl, `rust_src` and `rust_analyzer` of the version row).

The directory, relative to its root:

    index.json                      what is where (below), the unit ids rust-project.json has a row for, and each member's
                                    directories outside its package that its sources read (`extra_srcs`)
    sysroot/                        the pinned sysroot: bin/rustc, lib/, libexec/rust-analyzer-proc-macro-srv, and the pinned
                                    rust-analyzer as bin/rust-analyzer (it loads rustc's libraries from ../lib)
    rust-src/library/               the pinned standard library sources (rust-src)
    crates/<name>-<version>/        each registry crate's sources, as its units compile them (patched, for a `crate_src` patch); for a
                                    git crate, the archive of its commit (the package is the unit's `subdir` in it)
    build/<unit>/                   each build-script run: OUT_DIR/, rustc_args, rustc_env (rules/rust/bs_runner.zig)
    proc-macro/<unit>/lib<n>.so     each proc-macro, compiled by the pinned rustc

`<unit>` is a unit id with `_` for `:` (the unit's target name). The rows are the units `cargo build` and `cargo test` of the
members reach, except what only a registry or git crate's build script uses: the IDE never opens it, and an override in
third_party/buildrules/overrides.json may drop that script, and with it every target only it needed.
"""

load(":pins.bzl", "RUST_VERSIONS")
load(":providers.bzl", "BuildScriptInfo", "RustCrateInfo")

# The version of index.json, which `buildrules rust-project develop` checks. The format changes additively only (a new key is optional to the
# reader); anything else is a new version, which a CLI of the old version refuses by name.
_INDEX_VERSION = 1

def _tname(uid):
    return uid.replace(":", "_")

def _impl(ctx):
    files = {}
    index = {
        "version": _INDEX_VERSION,
        "rustc": ctx.attrs.rustc,
        "sysroot": "sysroot",
        "sysroot_src": "rust-src/library",
        "rust_analyzer": "sysroot/bin/rust-analyzer",
        "units": list(ctx.attrs.units),
        "crates": {},
        "runs": {},
        "proc_macros": {},
        "extra_dirs": {},
    }
    # The sysroot rust-analyzer runs from: rustc (which it asks for cfgs and the target's data layout), the libraries, the proc-macro
    # server in libexec/, and rust-analyzer itself in bin/, beside rustc: it loads librustc_driver from ../lib.
    sysroot = ctx.attrs.sysroot[DefaultInfo].default_outputs[0]
    for part in ["bin/rustc", "lib", "libexec", ".rustc_version"]:
        files["sysroot/" + part] = sysroot.project(part)
    ra = ctx.attrs.rust_analyzer[DefaultInfo].default_outputs[0]
    files["sysroot/bin/rust-analyzer"] = ra.project("bin/rust-analyzer")
    src = ctx.attrs.rust_src[DefaultInfo].default_outputs[0]
    files["rust-src"] = src.project("lib/rustlib/src/rust")

    def add_run(bs):
        path = "build/" + bs.unit
        files[path] = bs.dir
        index["runs"][bs.unit] = path

    def add_proc_macro(uid, info):
        path = "proc-macro/{}/{}".format(_tname(uid), info.lib.basename)
        files[path] = info.lib
        index["proc_macros"][uid] = path

    # Registry crates: the provider holds the sources, and says whether the unit was compiled with a build-script run (an override may
    # have dropped it).
    for uid, dep in ctx.attrs.registry.items():
        info = dep[RustCrateInfo]
        key = uid.split(":")[0]
        if info.src == None:
            fail("{}: {} is not a registry or git crate (it has no sources)".format(ctx.label, uid))
        files["crates/" + key] = info.src
        index["crates"][key] = "crates/" + key
        if info.is_proc_macro:
            add_proc_macro(uid, info)
        if info.build_script != None:
            add_run(info.build_script)

    # The workspace's own crates: their runs and proc-macros are always declared (an override applies to registry crates only).
    for _uid, dep in ctx.attrs.runs.items():
        add_run(dep[BuildScriptInfo])
    for uid, dep in ctx.attrs.proc_macros.items():
        add_proc_macro(uid, dep[RustCrateInfo])

    # A member's sources outside its package (`extra_srcs`): their directories, which rust-analyzer must read as the member's own.
    for pkg, dep in ctx.attrs.members.items():
        dirs = {}
        for p in dep[RustCrateInfo].extra_srcs:
            dirs[p.rsplit("/", 1)[0] if "/" in p else "."] = True
        index["extra_dirs"][pkg] = sorted(dirs)

    files["index.json"] = ctx.actions.write_json("index.json", index, pretty = True)
    out = ctx.actions.copied_dir(ctx.label.name, files)
    info = [DefaultInfo(default_output = out)]
    if ctx.attrs.check:
        info.append(ValidationInfo(validations = [
            ValidationSpec(name = "cargo_table_in_sync", validation_result = ctx.attrs.check[DefaultInfo].default_outputs[0]),
        ]))
    return info

_rust_analyzer_inputs = rule(
    impl = _impl,
    attrs = {
        "check": attrs.option(attrs.dep(), default = None),
        # member package -> one of its compiled units (each has the package's `extra_srcs`)
        "members": attrs.dict(attrs.string(), attrs.dep(providers = [RustCrateInfo]), default = {}),
        # unit id -> the workspace's own proc-macro unit
        "proc_macros": attrs.dict(attrs.string(), attrs.dep(providers = [RustCrateInfo]), default = {}),
        # unit id -> a registry or git library or proc-macro unit
        "registry": attrs.dict(attrs.string(), attrs.dep(providers = [RustCrateInfo]), default = {}),
        "runs": attrs.dict(attrs.string(), attrs.dep(providers = [BuildScriptInfo]), default = {}),
        "rust_analyzer": attrs.dep(),
        "rust_src": attrs.dep(),
        "rustc": attrs.string(),
        "sysroot": attrs.dep(),
        "units": attrs.list(attrs.string()),
    },
)

def _walk(table):
    """The unit ids of the rows: every unit the members' build and test roots reach, not descending into a registry or git crate's build-script run."""
    units = table["UNITS"]
    roots = []
    for m in table["MEMBERS"].values():
        roots += m["build"]["roots"] + m["test"]["roots"]
    seen = {}
    todo = list(roots)
    for _ in range(1000000):
        if not todo:
            break
        k = todo.pop()
        if k in seen:
            continue
        u = units[k]
        if u["mode"] == "run-custom-build" and u["source"] != "path":
            continue
        seen[k] = True
        for _ext, d in u["deps"]:
            todo.append(d)
    return sorted(seen)

def _refuse_impl(ctx):
    fail("{}: {}".format(ctx.label, ctx.attrs.why))

# Fails when built by name, and is skipped by a wildcard: it requires a constraint no platform has (as cargo.bzl's `:coverage`).
_refuse = rule(impl = _refuse_impl, attrs = {"why": attrs.string()})

def rust_analyzer_inputs(name, table, label_of, check):
    """Declares `name` from the table (cargo_workspace calls this).

    Args:
        label_of: unit id -> label (cargo.bzl `_label`); check: the `:check` target.
    """
    v = table["RUSTC"]
    row = RUST_VERSIONS.get(v, {})
    if "rust_src" not in row or "rust_analyzer" not in row:
        _refuse(
            name = name,
            why = ("rust-analyzer's inputs need rust-src and rust-analyzer pinned for rustc {}, and rules/rust/pins.bzl pins them only for " +
                   "{}; buildrules-pins.toml cannot pin them").format(v, ", ".join([k for k, r in RUST_VERSIONS.items() if "rust_src" in r and "rust_analyzer" in r])),
            target_compatible_with = ["buildrules//platforms:not_implemented"],
            visibility = ["PUBLIC"],
        )
        return
    from_pins = "toolchains//:{}_" + v.replace(".", "_")
    units = table["UNITS"]
    rows = _walk(table)
    registry, runs, proc_macros, members = {}, {}, {}, {}
    for uid in rows:
        u = units[uid]
        if u["source"] == "path" and u["mode"] == "build" and u["crate"] not in members:
            members[u["crate"]] = label_of(uid)
        if u["source"] != "path":
            if u["mode"] == "build" and u["target_kind"] != ["custom-build"]:
                registry[uid] = label_of(uid)
        elif u["mode"] == "run-custom-build":
            runs[uid] = label_of(uid)
        elif u["mode"] == "build" and "proc-macro" in u["crate_types"]:
            proc_macros[uid] = label_of(uid)
    _rust_analyzer_inputs(
        name = name,
        check = check,
        members = members,
        proc_macros = proc_macros,
        registry = registry,
        runs = runs,
        rust_analyzer = from_pins.format("rust_analyzer"),
        rust_src = from_pins.format("rust_src"),
        rustc = table["RUSTC"],
        sysroot = from_pins.format("sysroot"),
        units = rows,
        visibility = ["PUBLIC"],
    )
