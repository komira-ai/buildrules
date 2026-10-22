"""`cargo_unit`: one cargo unit (a row of the generated table) as one Buck2 target, and `crate_src`.

The table (`buildrules sync` writes it) holds one entry per distinct unit: package, target, mode, exec or target side, features,
profile fields and the units it depends on. `sync` writes one `cargo_unit` call per registry entry (the member macros make theirs), named
by the entry's content id. Two builds that share an entry share its target, and so share its action key: that is
the per-crate cache. Nothing in a key names the workspace member being edited.

  mode "build"            compile a library (`rlib`), proc-macro (`.so`) or binary (a build script's compiler).
  mode "test"             compile with `--test` and run the binary in an action; the output is a `.passed` marker.
  mode "run-custom-build" run a build script (built by the unit it depends on) and capture its directives.
  mode "lint"             run clippy-driver (`--emit=metadata`) on the unit named by `unit_mode`/`crate_type`, with the member's
                          `[lints]` flags; the output is the metadata file, and a lint that fires under `-D warnings` fails the action.

The build-script contract (decision.md 6.1) is implemented by `bs_runner.zig`; this file builds its command line:
  env       built from nothing: CARGO_MANIFEST_DIR, CARGO_MANIFEST_LINKS, CARGO_PKG_*, CARGO_FEATURE_*, CARGO_CFG_* (from
            `rustc --print=cfg`), CARGO_ENCODED_RUSTFLAGS, TARGET, HOST, OPT_LEVEL, DEBUG, PROFILE, NUM_JOBS, OUT_DIR,
            RUSTC / CC / CXX / AR (the pinned zig behind rustc_launch's shims, also as CC_<triple>), SOURCE_DATE_EPOCH,
            DEP_<LINKS>_<KEY> from direct dependencies with `links`, TMPDIR, a PATH naming an empty directory.
  honored   rustc-cfg, rustc-check-cfg, rustc-link-lib, rustc-link-search, rustc-flags (-l, -L), rustc-env, warning, error,
            rerun-if-* (recorded), metadata=K=V and the old cargo:K=V (-> DEP_*).
  refused   rustc-link-arg*, rustc-cdylib-link-arg and any other rustc-* key (the run fails), so nothing is dropped.
  links     `links` on the run unit sets CARGO_MANIFEST_LINKS; `link_deps` are the run units of dependencies that have it.
  stamp     `stamp_env` / `stamp_rustc_env`: a file's text fed to the script's environment, or into a rustc-env value.
  inputs    a registry script: the unpacked crate. A first-party script: the whole package directory (generated `srcs`).
  not yet   `rerun-if-*` narrowing of the input set.
"""

load("//rules:isa.bzl", "required_isa", "rustc_isa_flags", "test_exec_compatible_with")
load(":providers.bzl", "BuildScriptInfo", "RustCrateInfo", "RustToolchainInfo", "TestUnitInfo")
load(":select.bzl", "toolchain_for")
load(":test_run.bzl", "test_run")

_TOOLCHAIN = "toolchains//:rust"
_NONCE = read_config("buildrules", "unit_nonce", "")

def _file(dep):
    return dep[DefaultInfo].default_outputs[0]

# ---- sources ---------------------------------------------------------------------

def _crate_src_impl(ctx):
    tc = ctx.attrs._toolchain[RustToolchainInfo]
    tgz = ctx.actions.declare_output(ctx.attrs.pkg + "-" + ctx.attrs.version + ".crate", has_content_based_path = False)
    ctx.actions.download_file(tgz.as_output(), ctx.attrs.url, sha256 = ctx.attrs.sha256, size_bytes = ctx.attrs.size_bytes)

    # The tarball's one top directory is `<name>-<version>`; an output declared with that name is
    # the directory busybox tar extracts it into, under the output's parent.
    out = ctx.actions.declare_output(ctx.attrs.pkg + "-" + ctx.attrs.version, dir = True)
    ctx.actions.run(
        cmd_args(tc.busybox, "tar", "-xzf", tgz, "-C", cmd_args(out.as_output(), parent = 1)),
        category = "crate_unpack",
        identifier = ctx.attrs.pkg + "-" + ctx.attrs.version,
    )
    if ctx.attrs.patch == None:
        return [DefaultInfo(default_output = out)]

    # `patch` (copy / sub / add, see crate_patch.zig) edits a copy of the unpacked crate. It replaces what the crate's build
    # script would have produced, for a crate whose native code is a buildrules target. A substitution that stops matching
    # after a version bump fails the build.
    p = ctx.attrs.patch
    where = str(ctx.label.raw_target())
    for k in p:
        if k not in ["add", "copy", "sub"]:
            fail("{}: patch has no `{}`; its keys are copy, sub and add".format(where, k))
    for e in p.get("sub", []):
        for k in ["file", "from", "to"]:
            if type(e.get(k)) != "string":
                fail("{}: every patch.sub entry needs a string `{}`: {}".format(where, k, repr(e)))
        if e["from"] == "":
            fail("{}: a patch.sub entry has an empty `from`".format(where))
    for e in p.get("add", []):
        for k in ["file", "content"]:
            if type(e.get(k)) != "string":
                fail("{}: every patch.add entry needs a string `{}`: {}".format(where, k, repr(e)))
    spec = ctx.actions.write("patch.json", json.encode(p))
    patched = ctx.actions.declare_output("patched-" + ctx.attrs.pkg + "-" + ctx.attrs.version, dir = True)
    ctx.actions.run(
        cmd_args(ctx.attrs._patch_tool[RunInfo], spec, out, patched.as_output()),
        category = "crate_patch",
        identifier = ctx.attrs.pkg + "-" + ctx.attrs.version,
    )
    return [DefaultInfo(default_output = patched)]

crate_src = rule(
    impl = _crate_src_impl,
    attrs = {
        "patch": attrs.option(attrs.dict(attrs.string(), attrs.any()), default = None),
        "pkg": attrs.string(),
        "sha256": attrs.string(),
        "size_bytes": attrs.int(),
        "url": attrs.string(),
        "version": attrs.string(),
        "_patch_tool": attrs.exec_dep(default = "buildrules//rules/rust:crate_patch"),
        "_toolchain": attrs.exec_dep(default = _TOOLCHAIN, providers = [RustToolchainInfo]),
    },
)

# ---- shared pieces ---------------------------------------------------------------

def _pkg_env(ctx):
    v = ctx.attrs.version.split("+")[0]
    core = v.split("-")[0]
    nums = (core.split(".") + ["0", "0", "0"])[:3]
    pre = v[len(core) + 1:] if "-" in v else ""
    return {
        "CARGO_CRATE_NAME": ctx.attrs.crate_name,
        "CARGO_PKG_AUTHORS": "",
        "CARGO_PKG_DESCRIPTION": "",
        "CARGO_PKG_HOMEPAGE": "",
        "CARGO_PKG_LICENSE": "",
        "CARGO_PKG_LICENSE_FILE": "",
        "CARGO_PKG_NAME": ctx.attrs.pkg,
        "CARGO_PKG_README": "",
        "CARGO_PKG_REPOSITORY": "",
        "CARGO_PKG_RUST_VERSION": "",
        "CARGO_PKG_VERSION": ctx.attrs.version,
        "CARGO_PKG_VERSION_MAJOR": nums[0],
        "CARGO_PKG_VERSION_MINOR": nums[1],
        "CARGO_PKG_VERSION_PATCH": nums[2],
        "CARGO_PKG_VERSION_PRE": pre,
    }

def _manifest_dir(ctx):
    """The package directory: the unpacked crate, or the member's own package directory (from the crate root source: the path from the project root,
    which is the package's path only when the package's cell is the root cell)."""
    if ctx.attrs.src:
        return _file(ctx.attrs.src)
    # The crate root is one of the sources: its path from the project root, less the root's own path in the package.
    for s in ctx.attrs.srcs:
        if s.short_path == ctx.attrs.root:
            return cmd_args(s, parent = len(ctx.attrs.root.split("/")))
    return ctx.label.package or "."

def _root(ctx):
    d = _manifest_dir(ctx)
    return cmd_args(d, "/" + ctx.attrs.root, delimiter = "")

def _inputs(ctx):
    h = list(ctx.attrs.srcs) + list(ctx.attrs.extra_srcs)
    if ctx.attrs.src:
        h.append(_file(ctx.attrs.src))
    return h

def _natives(ctx):
    """The native archives this unit links into a binary or test: its own `native_deps`, then its dependencies', each once."""
    out = []
    for n in ctx.attrs.native_deps:
        a = _file(n)
        if a not in out:
            out.append(a)
    for name, dep in ctx.attrs.deps.items():
        if BuildScriptInfo in dep or name.startswith("bin:"):
            continue
        for a in dep[RustCrateInfo].natives:
            if a not in out:
                out.append(a)
    return out

def _flags(ctx, crate_type, test):
    a = ctx.attrs
    f = [
        "--crate-name",
        a.build_script_name or a.crate_name,
        "--edition",
        a.edition,
        "--crate-type",
        crate_type,
        "-C",
        "metadata=" + a.crate_hash,
        "-C",
        "embed-bitcode=no",
        "-C",
        "opt-level=" + a.opt_level,
        "-C",
        "debuginfo=" + a.debuginfo,
        "-C",
        "debug-assertions=" + ("on" if a.debug_assertions else "off"),
        "-C",
        "overflow-checks=" + ("on" if a.overflow_checks else "off"),
    ]
    if a.panic != "unwind":
        f += ["-C", "panic=" + a.panic]
    if a.strip:
        f += ["-C", "strip=" + a.strip]
    if a.codegen_units:
        f += ["-C", "codegen-units=" + a.codegen_units]
    if test:
        f.append("--test")
    if a.cap_lints:
        f += ["--cap-lints", "allow"]
    for c in a.cfgs:
        f += ["--cfg", c]
    # The ISA level of the target platform (empty for a build script or proc-macro, which runs on the build host, and when the platform has none).
    f += list(a.isa_flags)
    f += list(a.rustc_flags)
    return f

def _rustc(ctx, crate_type, out, test = False, lint = False):
    """Runs the pinned rustc on this unit. Returns (closure dict, run_dep or None)."""
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    closure = {}
    externs = []
    bs = None
    bin_exes = {}
    for name, dep in ctx.attrs.deps.items():
        if BuildScriptInfo in dep:
            bs = dep[BuildScriptInfo]
            continue
        info = dep[RustCrateInfo]
        if name.startswith("bin:"):
            # An integration test's dependency on its package's binary: cargo sets CARGO_BIN_EXE_<name>, it is not `--extern`.
            bin_exes[name[len("bin:"):]] = info.lib
            continue
        externs.append(cmd_args("--extern", cmd_args(name, info.lib, delimiter = "=")))
        closure[str(dep.label)] = info.lib
        if not info.is_proc_macro:
            # A proc-macro's own dependencies are not needed to load it, but an rlib that was built
            # with it records it and rustc must find its `.so` through -L (cargo's deps/ directory).
            closure.update(info.closure)
    cmd = cmd_args(tc.launcher, tc.sysroot, tc.zig, tc.cc_target, "--")
    if bs:
        # The launcher reads the script's rustc_args and rustc_env and sets OUT_DIR (see rustc_launch.zig).
        cmd.add("--br-run", bs.dir)
    cmd.add(_flags(ctx, crate_type, test))
    if lint:
        cmd.add("--emit=metadata")
        cmd.add(list(ctx.attrs.lint_flags))
        if ctx.attrs.deny_warnings:
            cmd.add("-D", "warnings")
    if crate_type == "proc-macro":
        cmd.add("--extern", "proc_macro")
    cmd.add(externs)
    for lib in closure.values():
        cmd.add(cmd_args(lib, format = "-Ldependency={}", parent = 1))
    natives = _natives(ctx) if crate_type == "bin" and not lint else []
    for n in natives:
        # Linked after the rlibs (a static archive resolves what the rlibs before it left undefined).
        cmd.add(cmd_args(n, format = "-Clink-arg={}"))
    cmd.add("-o", out.as_output(), _root(ctx))
    cmd.add(cmd_args(hidden = [tc.version_ok, _inputs(ctx), closure.values(), natives] + ([bs.dir] if bs else []) + ([tc.clippy] if lint else []) + bin_exes.values()))
    env = _pkg_env(ctx)
    env["CARGO_MANIFEST_DIR"] = _manifest_dir(ctx)
    env["BUILDRULES_NONCE"] = _NONCE
    if lint:
        env["BR_DRIVER"] = cmd_args(tc.clippy, "/bin/clippy-driver", delimiter = "")
        if ctx.attrs.conf_dir:
            env["CLIPPY_CONF_DIR"] = cmd_args(ctx.attrs.conf_dir, parent = 1)
    if test and ctx.attrs.target_kind == "test":
        # cargo gives an integration test a scratch directory (`env!("CARGO_TARGET_TMPDIR")`); the run action creates it.
        env["CARGO_TARGET_TMPDIR"] = "cargo_target_tmp/" + ctx.attrs.crate_hash
    if test:
        # A test binary reads `env!("CARGO_MANIFEST_DIR")` at run time (fixtures) with the working directory at the package, as under cargo:
        # the path baked into it must be absolute. Only test executables carry it; libraries keep the relative path (determinism).
        env["BR_ABS_MANIFEST"] = "1"
    for n, exe in bin_exes.items():
        env["CARGO_BIN_EXE_" + n] = cmd_args(exe)  # made absolute by the wrapper, as cargo's is
    if test or bin_exes:
        cmd = cmd_args(tc.busybox, "sh", "-c", _WRAP_ENV, "sh", tc.busybox, cmd)
    ctx.actions.run(cmd, category = "rustc", identifier = ctx.label.name, env = env)
    return closure, bin_exes.values()

# Makes the manifest dir, the test scratch dir and CARGO_BIN_EXE_* absolute, then runs the compiler. A build script's
# own outputs (rustc-env, OUT_DIR) reach rustc through the launcher's --br-run, not through this wrapper.
_WRAP_ENV = """set -eu
BB="$1"; shift
if [ -n "${BR_ABS_MANIFEST:-}" ]; then
    case "$CARGO_MANIFEST_DIR" in /*) ;; *) export CARGO_MANIFEST_DIR="$PWD/$CARGO_MANIFEST_DIR" ;; esac
    case "${CARGO_TARGET_TMPDIR:-}" in /*|"") ;; *) export CARGO_TARGET_TMPDIR="$PWD/$CARGO_TARGET_TMPDIR" ;; esac
fi
# `include!(concat!(env!("OUT_DIR"), ...))` resolves a relative path against the including file, so OUT_DIR is absolute
# (as in cargo). CARGO_MANIFEST_DIR stays relative: an absolute worker path baked into an rlib would differ by worker.
case "${OUT_DIR:-}" in /*|"") ;; *) export OUT_DIR="$PWD/$OUT_DIR" ;; esac
# CARGO_BIN_EXE_<bin>: an absolute path, baked into the test binary at compile time. The name may contain `-`, which `export`
# cannot set, so the variables go through `env`.
for kv in $("$BB" env | "$BB" grep '^CARGO_BIN_EXE_'); do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$v" in /*) ;; *) v="$PWD/$v" ;; esac
    set -- "$k=$v" "$@"
done
exec "$BB" env "$@"
"""

# ---- mode build ------------------------------------------------------------------

def _build_impl(ctx):
    crate_type = ctx.attrs.crate_type
    name = ctx.attrs.build_script_name or ctx.attrs.crate_name
    if crate_type == "bin":
        # a package's binary keeps its cargo target name (`my-tool`); a build script's compiled form keeps its crate name
        out = ctx.actions.declare_output(ctx.label.name + "/" + (ctx.attrs.target_name if ctx.attrs.target_name and not ctx.attrs.build_script_name else name))
    elif crate_type == "proc-macro":
        out = ctx.actions.declare_output(ctx.label.name + "/lib" + name + ".so")
    else:
        out = ctx.actions.declare_output(ctx.label.name + "/lib" + name + ".rlib")
    closure, _bins = _rustc(ctx, crate_type, out)
    return [
        DefaultInfo(default_output = out),
        RustCrateInfo(crate_name = name, lib = out, closure = closure, is_proc_macro = (crate_type == "proc-macro"), natives = _natives(ctx)),
    ]

# ---- mode test -------------------------------------------------------------------

# The run, shared by the welded marker and `buck2 test`: the same pinned binary, the same environment, the working directory at the package. These
# are the options of `check marker` and `check run` (rules/check) that start it: TMPDIR is the action's scratch directory; CARGO_MANIFEST_DIR (and
# CARGO_TARGET_TMPDIR, made, for an integration test) is made absolute against the action's directory; the binary runs in CARGO_MANIFEST_DIR.
_START = ["--tmpdir", "--abs", "CARGO_MANIFEST_DIR", "--cwd-env", "CARGO_MANIFEST_DIR"]
_START_TARGET_TMPDIR = ["--abs", "CARGO_TARGET_TMPDIR", "--mkdir-env", "CARGO_TARGET_TMPDIR"]

# The build action's marker is the test's own output (stdout, then stderr): it says how many tests passed. A failed run shows that output.
# `buck2 test` has no marker: the binary's output goes to the runner's log, its exit status is the verdict.
_MARKER = ["--capture", "--stamp-log"]

def _test_impl(ctx):
    """Compiles the test binary. The run is `test_run` (a target of its own, so it can ask for an ISA level)."""
    name = ctx.attrs.crate_name
    exe = ctx.actions.declare_output(ctx.label.name + "_bin/" + name)
    _closure, bins = _rustc(ctx, "bin", exe, test = True)
    env = _pkg_env(ctx)
    env["CARGO_MANIFEST_DIR"] = _manifest_dir(ctx)
    env["BUILDRULES_NONCE"] = _NONCE
    if ctx.attrs.target_kind == "test":
        env["CARGO_TARGET_TMPDIR"] = "cargo_target_tmp/" + ctx.attrs.crate_hash
    return [
        DefaultInfo(default_output = exe),
        TestUnitInfo(
            exe = exe,
            hidden = _inputs(ctx) + list(ctx.attrs.run_data) + bins,
            env = env,
            start = _START + (_START_TARGET_TMPDIR if "CARGO_TARGET_TMPDIR" in env else []),
            marker = _MARKER,
            cli = True,
            labels = list(ctx.attrs.labels),
        ),
    ]

# ---- mode run-custom-build -------------------------------------------------------

def _run_impl(ctx):
    """One run action per script: `bs_runner` (rules/rust/bs_runner.zig) is the contract, this builds its command line."""
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    exe = None
    for _name, dep in ctx.attrs.deps.items():
        if RustCrateInfo in dep:
            exe = dep[RustCrateInfo].lib
        else:
            fail("{}: a build-script run depends on its compiled script only; other build scripts come as link_deps".format(ctx.label))
    if not exe:
        fail("{}: no compiled build script".format(ctx.label))
    out = ctx.actions.declare_output(ctx.label.name + "_run", dir = True)
    a = ctx.attrs
    env = _pkg_env(ctx)
    env.pop("CARGO_CRATE_NAME")
    env.update({
        "CARGO_ENCODED_RUSTFLAGS": "",
        "DEBUG": "false" if a.debuginfo in ("0", "none") else "true",
        "NUM_JOBS": "1",
        "OPT_LEVEL": a.opt_level,
        "PROFILE": "debug" if a.debug_assertions else "release",
        "SOURCE_DATE_EPOCH": "0",
    })
    for c in a.cfgs:
        if c.startswith("feature="):
            env["CARGO_FEATURE_" + c[len("feature="):].strip("\"").upper().replace("-", "_")] = "1"
    cmd = cmd_args(
        tc.bs_runner,
        "--exe", exe,
        "--out", out.as_output(),
        "--manifest", _manifest_dir(ctx),
        "--sysroot", tc.sysroot,
        "--launcher", tc.launcher,
        "--zig", tc.zig,
        "--cc-target", tc.cc_target,
        "--triple", a.triple,
    )
    if a.links:
        cmd.add("--links", a.links)
    for k in sorted(env.keys()):
        cmd.add("--env", k + "=" + env[k])
    hidden = [tc.version_ok, _inputs(ctx)]
    for dep in a.link_deps:
        info = dep[BuildScriptInfo]
        if not info.links:
            fail("{}: depends on the build-script run {} which has no `links`".format(ctx.label, dep.label))
        cmd.add("--dep", cmd_args(info.links, "=", info.dir, "=", info.manifest, delimiter = ""))
        hidden += [info.dir] + info.files
    # The stamp: a commit (or any text) fed in as a file. It reaches the script's environment, and replaces a
    # rustc-env value the script emitted (a script that asks `git` gets nothing here, so it says "unknown").
    for name, f in a.stamp_env.items():
        cmd.add("--stamp-env", cmd_args(name, "=", _file(f), delimiter = ""))
        hidden.append(_file(f))
    for name, f in a.stamp_rustc_env.items():
        cmd.add("--stamp-rustc-env", cmd_args(name, "=", _file(f), delimiter = ""))
        hidden.append(_file(f))
    cmd.add(cmd_args(hidden = hidden))
    ctx.actions.run(cmd, category = "build_script", identifier = ctx.label.name, env = {"BUILDRULES_NONCE": _NONCE})
    return [
        DefaultInfo(default_output = out),
        BuildScriptInfo(dir = out, links = a.links or "", manifest = _manifest_dir(ctx), files = _inputs(ctx)),
    ]

# ---- mode lint -------------------------------------------------------------------

def _lint_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + "/" + ctx.attrs.crate_name + ".rmeta")
    _rustc(ctx, ctx.attrs.crate_type, out, test = (ctx.attrs.unit_mode == "test"), lint = True)
    return [DefaultInfo(default_output = out)]

def _impl(ctx):
    if ctx.attrs.mode == "lint":
        return _lint_impl(ctx)
    if ctx.attrs.mode == "build":
        return _build_impl(ctx)
    if ctx.attrs.mode == "test":
        return _test_impl(ctx)
    if ctx.attrs.mode == "run-custom-build":
        return _run_impl(ctx)
    fail("{}: mode {} is not a compile action (doctests are out of v0)".format(ctx.label, ctx.attrs.mode))

_cargo_unit = rule(
    impl = _impl,
    attrs = {
        "build_script_name": attrs.option(attrs.string(), default = None),
        "cap_lints": attrs.bool(default = False),
        "cfgs": attrs.list(attrs.string(), default = []),
        "codegen_units": attrs.option(attrs.string(), default = None),
        "crate_name": attrs.string(),
        "crate_type": attrs.string(default = "rlib"),
        "debug_assertions": attrs.bool(),
        "debuginfo": attrs.string(),
        "deps": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "edition": attrs.string(),
        "crate_hash": attrs.string(),
        "conf_dir": attrs.option(attrs.source(), default = None),
        # Files (or directories) of the source tree outside this package that `include_str!` and friends read: inputs only.
        "extra_srcs": attrs.list(attrs.source(allow_directory = True), default = []),
        # Targets whose default output is a static archive a binary or test links (a buildrules C library replacing a build script).
        "native_deps": attrs.list(attrs.dep(), default = []),
        "deny_warnings": attrs.bool(default = False),
        "lint_flags": attrs.list(attrs.string(), default = []),
        "link_deps": attrs.list(attrs.dep(), default = []),
        "isa_flags": attrs.list(attrs.string(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "links": attrs.option(attrs.string(), default = None),
        "mode": attrs.string(),
        "opt_level": attrs.string(),
        "overflow_checks": attrs.bool(),
        "panic": attrs.string(default = "unwind"),
        "pkg": attrs.string(),
        "root": attrs.string(),
        "run_data": attrs.list(attrs.source(allow_directory = True), default = []),
        "rustc_flags": attrs.list(attrs.string(), default = []),
        "side": attrs.string(default = "target"),
        "src": attrs.option(attrs.dep(), default = None),
        "srcs": attrs.list(attrs.source(), default = []),
        "stamp_env": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "stamp_rustc_env": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "strip": attrs.option(attrs.string(), default = None),
        "target_kind": attrs.string(default = ""),
        "target_name": attrs.string(default = ""),
        "unit_mode": attrs.string(default = "build"),
        "triple": attrs.string(default = "x86_64-unknown-linux-gnu"),
        "version": attrs.string(),
        "toolchain": attrs.exec_dep(default = _TOOLCHAIN, providers = [RustToolchainInfo]),
    },
)

def cargo_unit(name, rustc = None, **kwargs):
    """One cargo unit as a target (the rule is `_cargo_unit`).

    Args:
        rustc: the exact Rust version the unit compiles with (the table's `RUSTC`); None = the default (`RUST_DEFAULT`).
            A target platform with the `rust_version` constraint overrides it (select.bzl). The toolchain is an input of
            every action of the unit, so two versions never share a key.

    The target platform's ISA level (rules/isa.bzl) becomes rustc flags for units that run on the TARGET (`side = "target"`, not a
    proc-macro); build scripts and proc-macros run on the build host and never get them. A unit in mode `test` is two targets: `<name>__bin`
    compiles the binary on the ISA-agnostic platform, and `<name>` (test_run.bzl) runs it on the platform of the target's level.
    """
    if "toolchain" not in kwargs:
        kwargs["toolchain"] = toolchain_for(rustc)
    if kwargs.get("side", "target") == "target" and kwargs.get("crate_type") != "proc-macro" and "isa_flags" not in kwargs:
        kwargs["isa_flags"] = rustc_isa_flags()
    if kwargs.get("mode") != "test":
        _cargo_unit(name = name, **kwargs)
        return
    _cargo_unit(name = name + "__bin", **kwargs)
    test_run(
        name = name,
        unit = ":" + name + "__bin",
        required_isa = required_isa(),
        exec_compatible_with = test_exec_compatible_with(),
        visibility = kwargs.get("visibility", []),
    )

# ---- groups ----------------------------------------------------------------------

def _group_impl(ctx):
    outs = []
    for d in ctx.attrs.deps:
        outs += d[DefaultInfo].default_outputs
    return [DefaultInfo(default_outputs = outs)]

unit_group = rule(
    impl = _group_impl,
    attrs = {"deps": attrs.list(attrs.dep())},
)

# ---- stamps ----------------------------------------------------------------------

def _stamp_file_impl(ctx):
    return [DefaultInfo(default_output = ctx.attrs.src)]

# A text file that is an explicit input of the build-script runs that name it (`stamp_env`, `stamp_rustc_env`).
stamp_file = rule(
    impl = _stamp_file_impl,
    attrs = {"src": attrs.source()},
)
