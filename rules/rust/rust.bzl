"""rust_library, rust_binary, rust_test.

Every compile runs the pinned rustc (`RUST_DEFAULT`, or the version a target platform selects: select.bzl) through `rustc_launch`, which
links through zig. A crate `C` compiled by target `T` produces `T/libC.rlib` (or `T/C` for a
binary); a library sits alone in its directory, the transitive closure reaches rustc as one
`-Ldependency=<dir>` per crate and direct dependencies as `--extern <crate>=<file>`.

Tests are part of the build: `gate_tests = [":x_test"]` (Buck2 reserves `tests`) makes the published artifact a copy taken
by an action whose inputs include every test's `.passed` marker, so the artifact cannot be
built unless its tests pass (the weld).
"""

load("//rules:isa.bzl", "required_isa", "rustc_isa_flags", "test_exec_compatible_with")
load(":providers.bzl", "RustCrateInfo", "RustToolchainInfo", "RustTestInfo", "TestUnitInfo")
load(":select.bzl", "toolchain_for")
load(":test_run.bzl", "test_run")

_TOOLCHAIN = "toolchains//:rust"

# Perturbs every rustc/test action key without changing any output: a determinism probe
# re-executes everything on the farm (`-c buildrules.nonce=2`) with the remote cache enabled.
_NONCE = read_config("buildrules", "nonce", "")

def _crate_name(ctx):
    return ctx.attrs.crate_name or ctx.label.name.replace("-", "_")

def _compile(ctx, crate_type, out, test = False):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    name = _crate_name(ctx)
    cmd = cmd_args(tc.launcher, tc.sysroot, tc.zig, tc.cc_target, "--")
    cmd.add(
        "--crate-name",
        name,
        "--edition",
        ctx.attrs.edition,
        "--crate-type",
        crate_type,
        "-C",
        "metadata=" + name,
        "-C",
        "opt-level=2",
        "-C",
        "debuginfo=0",
        "-C",
        "codegen-units=1",
    )
    if test:
        cmd.add("--test")
    closure = {}
    for dep in ctx.attrs.deps:
        info = dep[RustCrateInfo]
        cmd.add("--extern", cmd_args(info.crate_name, info.lib, delimiter = "="))
        closure.update(info.closure)
    for lib in closure.values():
        cmd.add(cmd_args(lib, format = "-Ldependency={}", parent = 1))
    cmd.add(ctx.attrs.isa_flags)
    for f in ctx.attrs.rustc_flags:
        cmd.add(f)
    cmd.add("-o", out.as_output(), ctx.attrs.crate_root)
    cmd.add(cmd_args(hidden = [tc.version_ok, ctx.attrs.srcs, closure.values()]))
    ctx.actions.run(cmd, category = "rustc", identifier = ctx.label.name + (" test" if test else ""), env = {"BUILDRULES_NONCE": _NONCE})
    return closure

def _weld(ctx, raw, out, markers):
    """`out` is a copy of `raw` taken by an action that also reads every marker."""
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    ctx.actions.run(
        cmd_args(tc.busybox, "cp", raw, out.as_output(), hidden = markers),
        category = "weld",
        identifier = ctx.label.name,
    )

def _markers(ctx):
    return [t[RustTestInfo].marker for t in ctx.attrs.gate_tests]

def _rust_library_impl(ctx):
    name = _crate_name(ctx)
    markers = _markers(ctx)
    final = ctx.actions.declare_output(ctx.label.name + "/lib" + name + ".rlib")
    raw = final if not markers else ctx.actions.declare_output(ctx.label.name + "_ungated/lib" + name + ".rlib")
    closure = _compile(ctx, "rlib", raw)
    if markers:
        _weld(ctx, raw, final, markers)
    closure[str(ctx.label)] = final
    return [
        DefaultInfo(default_output = final),
        RustCrateInfo(crate_name = name, lib = final, closure = closure),
    ]

def _rust_binary_impl(ctx):
    markers = _markers(ctx)
    final = ctx.actions.declare_output(ctx.label.name)
    raw = final if not markers else ctx.actions.declare_output(ctx.label.name + "_ungated/" + ctx.label.name)
    _compile(ctx, "bin", raw)
    if markers:
        _weld(ctx, raw, final, markers)
    return [DefaultInfo(default_output = final), RunInfo(args = cmd_args(final))]

_RUN_TEST = """set -eu
BIN="$1"; OUT="$2"
if "$BIN" > "$OUT.log" 2>&1; then
    echo passed > "$OUT"
else
    cat "$OUT.log"
    echo "TEST FAILED: $BIN" >&2
    exit 1
fi
"""

def _rust_test_impl(ctx):
    """Compiles the test binary; `test_run` (a target of its own, so it can ask for an ISA level) runs it."""
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    exe = ctx.actions.declare_output(ctx.label.name + "_bin/" + _crate_name(ctx))
    _compile(ctx, "bin", exe, test = True)
    return [
        DefaultInfo(default_output = exe),
        TestUnitInfo(exe = exe, hidden = [], env = {"BUILDRULES_NONCE": _NONCE}, busybox = tc.busybox, script = _RUN_TEST),
    ]

_COMMON = {
    "crate_name": attrs.option(attrs.string(), default = None),
    "crate_root": attrs.source(),
    "deps": attrs.list(attrs.dep(providers = [RustCrateInfo]), default = []),
    "edition": attrs.string(default = "2021"),
    # The target platform's ISA level as rustc flags (rules/isa.bzl); the macros below set it.
    "isa_flags": attrs.list(attrs.string(), default = []),
    "rustc_flags": attrs.list(attrs.string(), default = []),
    "srcs": attrs.list(attrs.source()),
    "toolchain": attrs.exec_dep(default = _TOOLCHAIN, providers = [RustToolchainInfo]),
}

_rust_library = rule(
    impl = _rust_library_impl,
    attrs = dict(_COMMON, gate_tests = attrs.list(attrs.dep(providers = [RustTestInfo]), default = [])),
)

_rust_binary = rule(
    impl = _rust_binary_impl,
    attrs = dict(_COMMON, gate_tests = attrs.list(attrs.dep(providers = [RustTestInfo]), default = [])),
)

_rust_test = rule(
    impl = _rust_test_impl,
    attrs = _COMMON,
)

def rust_library(rustc = None, **kwargs):
    """`rustc`: an exact Rust version of the toolchain table (None = the default); a `rust_version` platform overrides it."""
    _rust_library(toolchain = kwargs.pop("toolchain", toolchain_for(rustc)), isa_flags = rustc_isa_flags(), **kwargs)

def rust_binary(rustc = None, **kwargs):
    _rust_binary(toolchain = kwargs.pop("toolchain", toolchain_for(rustc)), isa_flags = rustc_isa_flags(), **kwargs)

def rust_test(name, rustc = None, **kwargs):
    """Two targets: `<name>__bin` compiles the test on the ISA-agnostic platform, `<name>` runs it on the platform of the target's ISA level."""
    _rust_test(
        name = name + "__bin",
        crate_name = kwargs.pop("crate_name", None) or name.replace("-", "_"),
        toolchain = kwargs.pop("toolchain", toolchain_for(rustc)),
        isa_flags = rustc_isa_flags(),
        visibility = ["PUBLIC"],
        **{k: v for k, v in kwargs.items() if k != "visibility"}
    )
    test_run(
        name = name,
        unit = ":" + name + "__bin",
        required_isa = required_isa(),
        exec_compatible_with = test_exec_compatible_with(),
        visibility = kwargs.get("visibility", []),
    )
