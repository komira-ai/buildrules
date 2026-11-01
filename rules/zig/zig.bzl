"""Hermetic Mojo toolchain.

Every tool an action runs is an input of that action: a static busybox (shell
and file utilities), the zig distribution (C link driver, and the compiler for
`conda_unpack`), and the compiler closure unpacked from the pinned `.conda`.
Actions never search the worker's PATH.
"""

def _on_tool_exec(rule_fn, targeted = False):
    """`rule_fn`, run on the tool execution platform (rules/core/platform.bzl, `TOOL_EXEC`: linux x86_64 on a farm, the Mac itself in local mode on macOS arm64) unless the call
    says otherwise. `targeted`: the rule has a zig `target`, which defaults to the one that platform runs (`TOOL_TARGET`) and is not written when it is the attribute's own
    default, so a farm's commands are what they always were."""
    def call(**kwargs):
        if "exec_compatible_with" not in kwargs:
            kwargs["exec_compatible_with"] = TOOL_EXEC
        if targeted and "target" not in kwargs and TOOL_TARGET != _DEFAULT_TARGET:
            kwargs["target"] = TOOL_TARGET
        return rule_fn(**kwargs)
    return call

# The `target` attribute's default of every zig rule below.
_DEFAULT_TARGET = "x86_64-linux-musl"

# What a `zig_exe` was built for: zig's -target triple of the executable.
ZigExeInfo = provider(fields = {
    "target": provider_field(str),
    # The labels of the `zig_test` targets it waits for (`unit_tests`), sorted.
    "unit_tests": provider_field(list),
})
load("@buildrules//rules/core:test_runtime.bzl", "RUNNER_ENV", "data_map")
load(":checks.bzl", "check_exe_target", "check_exec_tool_name", "check_module_name", "check_optimize", "check_same_tests", "check_target_triple", "check_unique_dep_names", "check_unique_imports", "zig_closure")
load("@buildrules//rules/core:platform.bzl", "TOOL_EXEC", "TOOL_TARGET")
load("@buildrules//rules/core:unpack.bzl", "UNPACK", "unpack_cmd")
load("@buildrules//rules/core:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

# What a `zig_test` runs, for the rule that runs the same test under coverage (rules/coverage/zig_cover.bzl): the same root, zig, target, data and tools.
ZigTestInfo = provider(fields = {
    # The tools, data and env of a driver test; empty for a test without them.
    "data_manifest": provider_field(typing.Any),
    "env": provider_field(dict),
    # The compile's inputs other than the manifests: what the root names.
    "hidden": provider_field(list),
    # The root the compile is given: the source file, or the argument file naming the modules.
    "root": provider_field(typing.Any),
    "busybox": provider_field(typing.Any),
    # The paths, from the repository root, of the test's own source and of every file it is built from (its imports and its modules'), sorted.
    "sources": provider_field(list),
    "src": provider_field(str),
    "target": provider_field(str),
    "tools_manifest": provider_field(typing.Any),
    "zig": provider_field(typing.Any),
})

def busybox_sh(busybox, script, *args):
    """argv running `script` under the declared busybox shell.

    The script receives the busybox path as $1 so it can install applet links
    into a private directory and set PATH to that directory only.
    """
    return cmd_args(busybox, "sh", "-euc", script, "sh", busybox, *args)

_PRELUDE = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Private scratch. A remote action has its working directory to itself; a
# local one runs in the checkout root next to every other local action, so
# it takes the per-action scratch directory buck2 names in BUCK_SCRATCH_PATH.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.buildrules_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/buildrules" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/buildrules" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
"""

def _zig_dist_impl(ctx):
    out = ctx.actions.declare_output("zig", dir = True)

    # The archive holds one directory, `strip_prefix`, with the distribution in it: that directory is what is kept (`--strip-components` is its number of components).
    ctx.actions.run(
        unpack_cmd(
            ctx.label,
            ctx.attrs.unpack,
            ctx.attrs.archive[DefaultInfo].default_outputs[0],
            out,
            ctx.attrs.sha256,
            ctx.attrs.size_bytes,
            ctx.attrs.max_output,
            len(ctx.attrs.strip_prefix.split("/")),
            "tar.xz",
        ),
        category = "zig_unpack",
    )

    # `unpack` strips a number of components and does not look at what is left, so a `strip_prefix` of the wrong depth would give a tree with no `zig`, which fails only at its
    # first use. Copying `zig` out of the tree is the check that it is there (a missing source fails the action) and needs no program: the `check` tool cannot be used here,
    # because it is built by the zig this rule unpacks. It is a validation, so building the distribution (or anything that reads it) builds it. The executable bit is not read.
    has_zig = ctx.actions.copy_file(ctx.label.name + ".has_zig", out.project("zig"))
    return [
        DefaultInfo(default_output = out),
        ValidationInfo(validations = [ValidationSpec(name = "zig_dist_has_zig", validation_result = has_zig)]),
    ]

# A Zig distribution (`.tar.xz`) unpacked by the pinned `unpack` (rules/core/unpack.bzl), with the archive's `sha256` and `size_bytes` (the pin's) and the `max_output` it
# may decompress to. `strip_prefix` is the one directory the archive holds, as `a` or `a/b`; the distribution is that directory's content.
zig_dist_rule = rule(
    impl = _zig_dist_impl,
    attrs = {
        "archive": attrs.dep(),
        "max_output": attrs.int(),
        "sha256": attrs.string(),
        "size_bytes": attrs.int(),
        "strip_prefix": attrs.string(),
        "unpack": attrs.exec_dep(default = UNPACK, providers = [RunInfo]),
    },
)

# A Zig source file other Zig targets import by name: `@import("<name>")`
# in a `zig_exe` or `zig_test` that lists the target in `deps`. Zig refuses
# a relative `@import` of a file outside the importing file's directory, so a
# file shared by tools in two packages is passed to the compiler as a module
# of its own (`-M<name>=<root>`). A module may import other modules by name:
# its `deps` are `zig_module` targets, and a compile that imports it is given
# the whole closure, each module with the imports of its own `deps` only (as
# `zig build` wires `addImport`).
ZigModuleInfo = provider(fields = {
    # The import name: the target's name.
    "name": provider_field(str),
    # The module's root source file.
    "root": provider_field(typing.Any),
    # What a compile importing the module takes as inputs: the files `root`
    # imports by a relative name, and the `.passed` output of each of the
    # module's `unit_tests`, so nothing imports the module unless its tests
    # passed. (The same of its `deps` are in `closure`.)
    "inputs": provider_field(list),
    # The modules this one imports by name, as import names.
    "deps": provider_field(list),
    # The target's label, as a string (what two modules of one name are told
    # apart by).
    "label": provider_field(str),
    # Every module this one reaches through `deps`, direct ones first, each
    # once: structs of name, label, root, inputs and deps (import names).
    "closure": provider_field(list),
})

def _zig_module_impl(ctx):
    check_module_name(ctx.label.raw_target(), ctx.label.name)
    passed = [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.unit_tests]
    mods = [d[ZigModuleInfo] for d in ctx.attrs.deps]
    names = [m.name for m in mods]
    check_unique_imports(ctx.label.raw_target(), names)
    where = str(ctx.label.raw_target())
    return [
        DefaultInfo(default_output = ctx.attrs.src, other_outputs = passed),
        ZigModuleInfo(
            name = ctx.label.name,
            root = ctx.attrs.src,
            inputs = ctx.attrs.imports + passed,
            deps = names,
            label = where,
            closure = zig_closure(where, mods),
        ),
    ]

zig_module_rule = rule(
    impl = _zig_module_impl,
    attrs = {
        # `zig_module` targets `src` imports by name.
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        # Files `src` imports by a relative name (beside it).
        "imports": attrs.list(attrs.source(), default = []),
        "src": attrs.source(),
        # `zig_test` targets of the module; every importer waits for them.
        "unit_tests": attrs.list(attrs.dep(), default = []),
    },
)

def _package_of(label):
    """The package of a target label string (`cell//a/b:name` -> `a/b`)."""
    return label.split("//", 1)[1].split(":", 1)[0]

def _repo_path(package, artifact):
    return (package + "/" if package else "") + artifact.short_path

def _zig_sources(ctx):
    """The repository paths of the source files `ctx`'s zig test is built from: `src`, `imports`, the roots of its modules and the files
    those import. A build output (a module's `.passed`) is not a source."""
    package = ctx.label.package
    paths = [_repo_path(package, ctx.attrs.src)] + [_repo_path(package, i) for i in ctx.attrs.imports]
    for e in zig_closure(str(ctx.label.raw_target()), [d[ZigModuleInfo] for d in ctx.attrs.deps]):
        owner = _package_of(e.label)
        paths.append(_repo_path(owner, e.root))
        paths += [_repo_path(owner, i) for i in e.inputs if i.is_source]
    return sorted({p: True for p in paths if p.endswith(".zig")}.keys())

def _zig_root(ctx):
    """What the compile is given as its root: `src`; with `deps`, an argument
    file naming `src` as the root module and each module it may import (the
    `deps` and what they import, with the imports of each module declared
    before it; `@file` is zig's own argument file, read in place of the
    argument). Without `deps` the command line is the one it always was, so
    no existing action changes its key. Two deps of one import name (the
    same target twice, or two targets of one name) fail analysis rather
    than zig's compile."""
    if not ctx.attrs.deps:
        return ctx.attrs.src
    mods = [d[ZigModuleInfo] for d in ctx.attrs.deps]
    check_unique_dep_names(ctx.label.raw_target(), [(m.name, d.label.raw_target()) for d, m in zip(ctx.attrs.deps, mods)])
    closure = zig_closure(str(ctx.label.raw_target()), mods)
    args = [cmd_args("--dep", m.name) for m in mods]
    args.append(cmd_args(ctx.attrs.src, format = "-Mroot={}"))
    for e in closure:
        args += [cmd_args("--dep", n) for n in e.deps]
        args.append(cmd_args(e.root, format = "-M" + e.name + "={}"))
    argfile, _ = ctx.actions.write(ctx.label.name + ".zig_modules", cmd_args(args), allow_args = True)
    return cmd_args(argfile, format = "@{}", hidden = [ctx.attrs.src] + [e.root for e in closure] + [i for e in closure for i in e.inputs])

def _zig_optimize(ctx):
    check_optimize(ctx.label.raw_target(), ctx.attrs.optimize)
    return ctx.attrs.optimize

def _zig_exe_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name)
    script = _PRELUDE + """
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$1/zig" build-exe -OReleaseSafe -target TARGET -fstrip "$2" "-femit-bin=$3"
rm -rf "$T"
"""
    # The target, the optimization mode and the strip flag are written into
    # the script, so that with the defaults the command (and the action key)
    # of every zig_exe is what it was before the attributes existed.
    check_target_triple(ctx.label, ctx.attrs.target)
    script = script.replace("-OReleaseSafe -target TARGET -fstrip ", "-O{} -target {} {} ".format(_zig_optimize(ctx), ctx.attrs.target, "-fstrip" if ctx.attrs.strip else "-fno-strip"))
    cmd = busybox_sh(bb, script, zig, _zig_root(ctx), out.as_output())
    if ctx.attrs.imports:
        # Files `src` imports by a relative name: inputs at their paths, so
        # beside it, and not on the command line.
        cmd = cmd_args(cmd, hidden = ctx.attrs.imports)
    if ctx.attrs.unit_tests:
        # Each `zig_test`'s output is an input: the executable is not built
        # unless they passed.
        cmd = cmd_args(cmd, hidden = [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.unit_tests])
    ctx.actions.run(
        cmd,
        category = "zig_build_exe",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out)), ZigExeInfo(target = ctx.attrs.target, unit_tests = sorted([str(t.label.raw_target()) for t in ctx.attrs.unit_tests]))]

zig_exe_rule = rule(
    impl = _zig_exe_impl,
    attrs = {
        "busybox": attrs.dep(default = "buildrules//rules/pins:busybox"),
        # `zig_module` targets `src` imports by name.
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        "imports": attrs.list(attrs.source(), default = []),
        # zig's -O: the optimization mode.
        "optimize": attrs.string(default = "ReleaseSafe"),
        "src": attrs.source(),
        # Strip symbols and debug information from the executable.
        "strip": attrs.bool(default = True),
        # zig's -target: what the executable runs on (it is built on the
        # linux execution platform whatever this says).
        "target": attrs.string(default = _DEFAULT_TARGET),
        # `zig_test` targets the executable waits for.
        "unit_tests": attrs.list(attrs.dep(), default = []),
        "zig": attrs.dep(default = "buildrules//rules/pins:zig"),
    },
)

# Variables a driver test's action sets itself (tools/mojo/tools/zig_launch.zig).
_ZIG_TEST_OWN_ENV = ["XDG_CACHE_HOME", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "BUILDRULES_TEST_WORK"]

def _zig_test_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    # A test that runs tools (`env_tools`) is also a validation: a target
    # that hands a tool out lists the test that runs it (`kcov_tool`'s
    # `cases`), as the test cannot be an input of the tool it runs. Its
    # result is then a validation result; a test without tools writes
    # `passed`, as it always did.
    validation = bool(ctx.attrs.env_tools or ctx.attrs.exec_tools)
    out = ctx.actions.declare_output(ctx.label.name + (".json" if validation else ".passed"))
    stamp = '{"version": 1, "data": {"status": "success", "message": "zig test passed"}}\n' if validation else "passed\n"
    check_target_triple(ctx.label, ctx.attrs.target)
    # The launcher (tools/zig_launch.zig; no shell) gives the tests the busybox
    # applets as their PATH and a HOME, TMPDIR and caches of their own inside
    # the action's scratch directory, runs `zig test`, and writes the stamp
    # when it passed. `-O<mode>` is left out for `Debug`, zig's own default.
    cmd = cmd_args(
        ctx.attrs._launcher[RunInfo],
        "test",
        "--busybox",
        bb,
        "--zig",
        zig,
        "--out",
        out.as_output(),
        "--stamp",
        stamp,
    )
    # The pinned tools a test runs, as environment variables naming their
    # paths.
    env = {name: dep[DefaultInfo].default_outputs[0] for name, dep in ctx.attrs.env_tools.items()}
    env.update(rerun_env(ctx))
    hidden = list(ctx.attrs.imports)
    root = _zig_root(ctx)
    data_manifest = None
    tools_manifest = None
    driver_hidden = []
    if ctx.attrs.exec_tools or ctx.attrs.data:
        # A driver test: built tools by absolute path, fixtures in a writable
        # directory (BUILDRULES_TEST_WORK). Both come from manifests the launcher
        # reads, so a test without them is not a driver.
        where = str(ctx.label.raw_target())
        for name in ctx.attrs.exec_tools:
            check_exec_tool_name(where, name, RUNNER_ENV + _ZIG_TEST_OWN_ENV + list(ctx.attrs.env_tools.keys()))
        srcs = data_map(ctx, where, ctx.attrs.data)
        tools = {name: dep[DefaultInfo].default_outputs[0] for name, dep in ctx.attrs.exec_tools.items()}
        data_manifest, _ = ctx.actions.write(ctx.label.name + ".data", [cmd_args(d, a, delimiter = "\t") for d, a in sorted(srcs.items())], allow_args = True)
        tools_manifest, _ = ctx.actions.write(ctx.label.name + ".tools", [cmd_args(n, t, delimiter = "\t") for n, t in sorted(tools.items())], allow_args = True)
        cmd.add("--data", data_manifest, "--tools", tools_manifest)
        driver_hidden = srcs.values() + tools.values()
        hidden += driver_hidden
    cmd.add("--", "test")
    if _zig_optimize(ctx) != "Debug":
        cmd.add("-O" + ctx.attrs.optimize)
    cmd.add("-target", ctx.attrs.target, root)
    ctx.actions.run(
        cmd_args(cmd, hidden = hidden),
        category = "zig_test",
        env = env,
    )
    info = ZigTestInfo(
        busybox = bb,
        data_manifest = data_manifest,
        env = env,
        hidden = hidden,
        root = root,
        sources = _zig_sources(ctx),
        src = _repo_path(ctx.label.package, ctx.attrs.src),
        target = ctx.attrs.target,
        tools_manifest = tools_manifest,
        zig = zig,
    )
    if validation:
        return [
            DefaultInfo(default_output = out),
            ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = out)]),
            rerun_info(ctx),
            info,
        ]
    return [DefaultInfo(default_output = out), rerun_info(ctx), info]

# `zig test` of `src` (and the `test` blocks of the files it imports, the
# `imports`), run as a build action: the target exists only if every test
# passed. A `zig_exe` names it in `unit_tests` to be built behind it. A test
# that runs tools names them in `env_tools`; it is then also a validation,
# which a target that hands a tool out lists (`kcov_tool`'s `cases`), as it
# cannot be an input of the executable it runs. It can still be in the
# `unit_tests` of an executable it does not run (cov_zig's unit tests run a
# stand-in zig and debug_relocate).
zig_test_rule = rule(
    impl = _zig_test_impl,
    attrs = {
        "busybox": attrs.dep(default = "buildrules//rules/pins:busybox"),
        # `zig_module` targets `src` imports by name.
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        # name -> a tool the tests run (its default output), in the
        # environment as its path. Configured for the execution platform like
        # the target that hands it out, so the same bytes. It may be a
        # directory of executables: the pinned zig
        # (buildrules//rules/pins:zig) is the directory holding `zig`.
        "env_tools": attrs.dict(attrs.string(), attrs.exec_dep(), default = {}),
        # Files a driver test reads and writes, copied into the writable
        # directory BUILDRULES_TEST_WORK: a list of sources (files or directories,
        # each at its path from the cell root) or {destination: source}.
        "data": attrs.one_of(attrs.list(attrs.source(allow_directory = True)), attrs.dict(attrs.string(), attrs.source(allow_directory = True)), default = []),
        # name -> a built tool the tests run, in the environment as its
        # ABSOLUTE path (env_tools' paths are relative to the action's
        # directory). Like env_tools, it makes the test a validation.
        "exec_tools": attrs.dict(attrs.string(), attrs.exec_dep(), default = {}),
        "imports": attrs.list(attrs.source(), default = []),
        # zig's -O: the optimization mode the tests are built with. `Debug`
        # is zig's own default (no flag is passed).
        "optimize": attrs.string(default = "Debug"),
        "src": attrs.source(),
        # zig's -target. The tests run as part of the action, so it must be a
        # target the execution platform runs (the default, or another libc
        # of its cpu).
        "target": attrs.string(default = _DEFAULT_TARGET),
        "zig": attrs.dep(default = "buildrules//rules/pins:zig"),
        # The runner of the action (tools/zig_launch.zig), built by the
        # pinned zig directly: no test needs a shell to run.
        "_launcher": attrs.exec_dep(default = "buildrules//rules/zig:zig_launch"),
    } | RERUN_ATTRS,
)

def _zig_bootstrap_exe_impl(ctx):
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    check_target_triple(ctx.label, ctx.attrs.target)
    # No script, no busybox: zig is run as the action's executable. Its caches
    # are directories of the action's working directory (as zig_cc_launcher's).
    env = {"ZIG_GLOBAL_CACHE_DIR": ".zig-cache/global", "ZIG_LOCAL_CACHE_DIR": ".zig-cache/local"}
    zig_exe = cmd_args(zig, "/zig", delimiter = "")
    inputs = [ctx.attrs.src] + ([ctx.attrs.test_src] if ctx.attrs.test_src else []) + ctx.attrs.imports
    passed = [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.unit_tests]
    # `zig test` runs the tests of `test_src` and, given -femit-bin, leaves the
    # test executable behind: the output exists only if every test passed.
    # (Without a `test_src` the tests are the `unit_tests`: `zig_test` targets.)
    tested = []
    if ctx.attrs.test_src:
        tested = [ctx.actions.declare_output(ctx.label.name + ".tested")]
        ctx.actions.run(
            cmd_args(zig_exe, "test", "-target", ctx.attrs.target, ctx.attrs.test_src, cmd_args(tested[0].as_output(), format = "-femit-bin={}"), hidden = inputs),
            env = env,
            category = "zig_bootstrap_test",
        )
    out = ctx.actions.declare_output(ctx.label.name)
    ctx.actions.run(
        cmd_args(zig_exe, "build-exe", "-OReleaseSafe", "-target", ctx.attrs.target, "-fstrip", ctx.attrs.src, cmd_args(out.as_output(), format = "-femit-bin={}"), hidden = tested + passed + inputs),
        env = env,
        category = "zig_bootstrap_exe",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

# An executable built by the pinned zig with no shell and no busybox, behind
# the unit tests in `test_src` (which imports `src`): the launchers of the
# other rules are built this way, so those rules need no shell either. Built
# `-OReleaseSafe -fstrip` like `zig_exe`. A program built for another system
# than the one it is built on (`macos_applets`) has no `test_src` (`zig test`
# would run the tests on the system it is built for) and waits for `unit_tests`
# instead, `zig_test` targets that run on this one.
zig_bootstrap_exe_rule = rule(
    impl = _zig_bootstrap_exe_impl,
    attrs = {
        "imports": attrs.list(attrs.source(), default = []),
        "src": attrs.source(),
        "target": attrs.string(default = _DEFAULT_TARGET),
        "test_src": attrs.option(attrs.source(), default = None),
        "unit_tests": attrs.list(attrs.dep(), default = []),
        "zig": attrs.dep(default = "buildrules//rules/pins:zig"),
    },
)

def _conda_libs_impl(ctx):
    tool = ctx.attrs.unpacker[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("libs", dir = True)
    libs = []
    for member, package in sorted(ctx.attrs.libs.items()):
        libs.extend(["--lib", package[DefaultInfo].default_outputs[0], member])
    ctx.actions.run(
        cmd_args(tool, "--only-libs", out.as_output(), libs),
        category = "conda_unpack",
    )
    return [DefaultInfo(default_output = out)]

# Shared libraries taken out of pinned conda packages, for a tool that is not
# the Mojo compiler: `<out>/lib/<name>`, each a regular file (a library's
# SONAME link is resolved to the bytes it names).
conda_libs_rule = rule(
    impl = _conda_libs_impl,
    attrs = {
        # member path under lib/ -> the pinned package it is taken from.
        "libs": attrs.dict(attrs.string(), attrs.dep()),
        "unpacker": attrs.dep(),
    },
)


conda_libs = _on_tool_exec(conda_libs_rule)

# The distribution is unpacked on the tool execution platform: the pinned `unpack` of that platform runs it (rules/pins/BUCK, `:unpack`).
zig_dist = _on_tool_exec(zig_dist_rule)

zig_bootstrap_exe = _on_tool_exec(zig_bootstrap_exe_rule, targeted = True)
zig_exe = _on_tool_exec(zig_exe_rule, targeted = True)
zig_test = _on_tool_exec(zig_test_rule, targeted = True)
zig_module = zig_module_rule

def _zig_exe_target_test_impl(ctx):
    got = ctx.attrs.exe[ZigExeInfo].target
    check_exe_target(ctx.label.raw_target(), ctx.attrs.exe.label.raw_target(), got, ctx.attrs.expect)
    want_tests = ctx.attrs.same_tests_as[ZigExeInfo].unit_tests
    got_tests = ctx.attrs.exe[ZigExeInfo].unit_tests
    check_same_tests(ctx.label.raw_target(), ctx.attrs.exe.label.raw_target(), got_tests, ctx.attrs.same_tests_as.label.raw_target(), want_tests)
    return [DefaultInfo(default_output = ctx.actions.write(ctx.label.name + ".passed", "{} is built for {}\n".format(ctx.attrs.exe.label.raw_target(), got)))]

# An analysis test: green only if `exe` (a `zig_exe`) is built for the zig target triple `expect`. It builds nothing but a marker, so it is
# cheap; the executable's own bytes are checked by a `zig_test` that reads its file header (cli/header_test.zig).
# `same_tests_as` is required: it is also green only if `exe` waits for exactly the `unit_tests` of that executable (and that it has some), so a cross-built
# copy of a program cannot ship with fewer tests than the program that is tested. A test that does not say which program it copies does not load.
zig_exe_target_test = rule(
    impl = _zig_exe_target_test_impl,
    attrs = {
        "exe": attrs.dep(providers = [ZigExeInfo]),
        "expect": attrs.string(),
        # An executable whose `unit_tests` must be exactly those of this one (the same program for another target: the same tests gate it), and not none.
        # Required: with no default, a test that leaves it out is a load error and not a test that checks less.
        "same_tests_as": attrs.dep(providers = [ZigExeInfo]),
    },
)
