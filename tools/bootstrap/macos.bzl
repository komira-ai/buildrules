"""The checks of `unpack` on a farm's macOS arm64 workers (`.github/workflows/farm-macos.yml`): a program built on linux x86_64 and run on a Mac.

A `zig_test` compiles and runs its test in one action through its launcher (rules/zig), a linux x86_64 program, so it cannot run on a Mac.
A test that runs on a Mac is therefore two targets:

  zig_test_bin   on linux x86_64: the compile of an existing `zig_test` (its root, imports and zig, from its `ZigTestInfo`) for another `-target`, with
                 `--test-no-exec`: the test executable, built and not run, by the pinned zig with no script around it.
  host_run       on the execution platform the target names in `exec_compatible_with`: `check marker` (rules/check), built for the host that runs it
                 (`check_for_host`), starts the program with a private scratch directory of its own (`--private-scratch`: TMPDIR and HOME are fresh; with
                 `installed`, the default, its working directory is a fresh, writable `root` too) and writes the marker only when the program exited 0.

`macos_gate()` is the `target_compatible_with` of every target that runs on a Mac: while no macOS execution platform is registered (`[buildrules_re]
macos_aarch64_properties` is unset, or local mode on another machine; rules/platforms.bzl) the target requires a constraint no platform has, so it is
incompatible and a wildcard build skips it, instead of failing for want of an execution platform.
"""

load("@buildrules//rules:platforms.bzl", "exec_platform_ready")
load("@buildrules//rules/zig:zig.bzl", "ZigTestInfo")

# The label farm-macos.yml selects the targets by (`stage farm-macos`, tools/stage/macos_farm.zig).
MACOS_FARM = "macos-farm"

def macos_gate():
    """`target_compatible_with` of a target that runs on a Mac: nothing while a macOS execution platform is registered, else the value no platform has."""
    if exec_platform_ready("macos-aarch64"):
        return []
    return ["//tools/bootstrap:waiting_on_macos_workers"]

def _zig_test_bin_impl(ctx):
    if ctx.attrs.optimize not in ("Debug", "ReleaseSafe"):
        fail("{}: optimize is `{}`: it is `Debug` or `ReleaseSafe`".format(ctx.label.raw_target(), ctx.attrs.optimize))
    info = ctx.attrs.test[ZigTestInfo]
    exe = ctx.actions.declare_output(ctx.label.name + "/" + ctx.label.name)

    # The compile of `zig_test` (rules/zig/zig.bzl) with another `-target` and `--test-no-exec`: zig writes the test executable (`-femit-bin`) and runs
    # nothing. No script and no busybox: zig is the action's executable, and its caches are directories of the action's working directory, as
    # `zig_bootstrap_exe`'s are. The executable is alone in its directory, because `host_run` copies the directory that holds the program.
    cmd = cmd_args(cmd_args(info.zig, "/zig", delimiter = ""), "test")
    if ctx.attrs.optimize != "Debug":
        cmd.add("-O" + ctx.attrs.optimize)
    cmd.add(
        "-target",
        ctx.attrs.target,
        "--test-no-exec",
        info.root,
        cmd_args(exe.as_output(), format = "-femit-bin={}"),
    )
    ctx.actions.run(
        cmd_args(cmd, hidden = info.hidden),
        env = {"ZIG_GLOBAL_CACHE_DIR": ".zig-cache/global", "ZIG_LOCAL_CACHE_DIR": ".zig-cache/local"},
        category = "zig_test_bin",
    )
    return [DefaultInfo(default_output = exe), RunInfo(args = cmd_args(exe))]

zig_test_bin = rule(
    impl = _zig_test_bin_impl,
    attrs = {
        # zig's build mode of the test executable (zig's own default is Debug).
        "optimize": attrs.string(default = "Debug"),
        # zig's -target of the test executable.
        "target": attrs.string(),
        # The `zig_test` whose compile this is.
        "test": attrs.dep(providers = [ZigTestInfo]),
    },
)

def _host_run_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    cmd = cmd_args(ctx.attrs._check[RunInfo], "marker", "--out", out.as_output(), "--stamp", "passed", "--private-scratch")
    if ctx.attrs.installed:
        cmd.add("--installed")
    hidden = []
    for name, tool in sorted(ctx.attrs.env_tools.items()):
        path = tool[DefaultInfo].default_outputs[0]
        cmd.add("--env", cmd_args(name, path, delimiter = "="), "--abs", name)
        hidden.append(path)
    for name, value in sorted(ctx.attrs.env.items()):
        cmd.add("--env", "{}={}".format(name, value))
    cmd.add("--", ctx.attrs.exe[RunInfo], ctx.attrs.args)
    ctx.actions.run(cmd_args(cmd, hidden = hidden), category = "host_run")
    return [DefaultInfo(default_output = out)]

host_run = rule(
    impl = _host_run_impl,
    attrs = {
        "args": attrs.list(attrs.arg(), default = []),
        # name -> a value the program finds in its environment as it is.
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # name -> a built program or a pinned file the program is handed, in its environment as an absolute path.
        "env_tools": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "exe": attrs.dep(providers = [RunInfo]),
        # True: the program runs from a fresh, writable `root` (a test that makes files where it runs). False: in the action's working directory, where it reads
        # the files `args` names by their paths.
        "installed": attrs.bool(default = True),
        # What farm-macos.yml selects the target by (`MACOS_FARM`).
        "labels": attrs.list(attrs.string(), default = []),
        # `check` built for the host of the execution platform this target runs on (rules/check/BUCK).
        "_check": attrs.exec_dep(default = "buildrules//rules/check:check_for_host", providers = [RunInfo]),
    },
)
