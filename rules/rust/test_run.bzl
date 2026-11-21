"""`test_run`: the run of a compiled test, a target of its own.

A rule instance has one execution platform. The compile of a test (any ISA) must stay on the ISA-agnostic platform, and the
RUN of a test built for x86-64-v3 must land on a worker that has v3. So the run is a separate target with its own
`exec_compatible_with` (rules/isa.bzl `test_exec_compatible_with()`), and it checks, while the build graph is analysed,
that the platform it was given reports at least the level the test was built for. A test at a level whose run target lost
`exec_compatible_with` fails here with the fix, instead of running on whatever worker is free and dying with SIGILL.

A run given `postgres_url_env` (a cargo package that declares `postgres = { url-env = "NAME" }`, rules/postgres/README.md) runs under `pg_run`: it starts
a private Postgres from the pinned tree (`buildrules//rules/postgres:prefix`), listening only on a Unix socket in the action's TMPDIR (or /tmp, for a TMPDIR too long for a socket path), runs the `check`
command below with NAME set to the server's URL, and stops the server after it. A run without it is the command it always was.

`cov_run` is the run of a test built with coverage counters (cargo_unit.bzl, `coverage = True`; a member's `:coverage`, coverage.bzl): the same
command, the fixture included, with the profiles it writes kept as a second output.
"""

load("//rules:isa.bzl", "isa_satisfies")
load(":providers.bzl", "ExecIsaInfo", "RustCovRunInfo", "RustTestInfo", "TestUnitInfo")

def _check_isa(ctx):
    have = ctx.attrs._exec_isa[ExecIsaInfo].level
    want = ctx.attrs.required_isa
    if not isa_satisfies(have, want):
        fail(("{}: built for ISA {} but its execution platform reports ISA={}. A test at an ISA level must run on a platform " +
              "that has it: set exec_compatible_with = test_exec_compatible_with() (rules/isa.bzl), which the cargo_unit and rust_test " +
              "macros do, so the farm schedules the run on a worker of at least that level.").format(ctx.label, want, have))

def _impl(ctx):
    info = ctx.attrs.unit[TestUnitInfo]
    _check_isa(ctx)
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    check = ctx.attrs._check_exe[RunInfo]

    # `check marker` (rules/check): the marker is written only when the binary exited 0, and a failed run is the binary's output and its status.
    ctx.actions.run(
        cmd_args(_fixture(ctx), check, "marker", "--out", marker.as_output(), info.marker, info.start, "--", info.exe, hidden = info.hidden),
        category = "rust_test",
        identifier = ctx.label.name,
        env = info.env,
    )
    out = [
        DefaultInfo(default_output = marker, sub_targets = {"bin": [DefaultInfo(default_output = info.exe)]}),
        RustTestInfo(marker = marker),
    ]
    if info.cli:
        # `buck2 test` runs the same pinned binary with the same environment and working directory, outside the build (no marker).
        out.append(ExternalRunnerTestInfo(
            type = "custom",
            command = [cmd_args(_fixture(ctx), check, "run", info.start, "--", info.exe, hidden = info.hidden)],
            env = info.env,
            labels = ["test"] + list(info.labels),
        ))
    return out

def _fixture(ctx):
    """What the `check` command runs under: `pg_run ... --` for a run that declares the Postgres fixture, else nothing."""
    name = ctx.attrs.postgres_url_env
    if name == None:
        return []
    return [ctx.attrs._pg_run[RunInfo], "--prefix", ctx.attrs._pg_prefix[DefaultInfo].default_outputs[0], "--url-env", name, "--"]

_ATTRS = {
    # The variable the test reads the URL of its private Postgres from (rules/postgres/README.md); None: no server.
    "postgres_url_env": attrs.option(attrs.string(), default = None),
    "required_isa": attrs.string(default = ""),
    "unit": attrs.dep(providers = [TestUnitInfo]),
    "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
    "_exec_isa": attrs.exec_dep(default = "buildrules//rules/rust:exec_isa", providers = [ExecIsaInfo]),
    "_pg_prefix": attrs.exec_dep(default = "buildrules//rules/postgres:prefix"),
    "_pg_run": attrs.exec_dep(default = "buildrules//rules/postgres:pg_run", providers = [RunInfo]),
}

test_run = rule(
    impl = _impl,
    attrs = _ATTRS,
)

def _cov_impl(ctx):
    """The run of an instrumented test (cargo_unit.bzl, `coverage = True`): the same `check marker` command as `test_run`'s, with
    LLVM_PROFILE_FILE naming a directory that is an output of the action. Every instrumented program of the run writes its profile there, one file
    per process (`%p`, merged into one per program by `%m` when a pid is reused): the test binary, and a binary of the package it starts."""
    info = ctx.attrs.unit[TestUnitInfo]
    _check_isa(ctx)
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    profiles = ctx.actions.declare_output(ctx.label.name + ".profiles", dir = True)
    check = ctx.attrs._check_exe[RunInfo]

    # The directory is made before the test starts (`--mkdir-env`), so a run whose programs wrote nothing leaves it empty and `:coverage` says so.
    cmd = cmd_args(
        _fixture(ctx),
        check,
        "marker",
        "--out",
        marker.as_output(),
        info.marker,
        info.start,
        "--env",
        cmd_args("BR_PROFILE_DIR=", profiles.as_output(), delimiter = ""),
        "--abs",
        "BR_PROFILE_DIR",
        "--mkdir-env",
        "BR_PROFILE_DIR",
        "--env",
        cmd_args("LLVM_PROFILE_FILE=", profiles.as_output(), "/%p-%m.profraw", delimiter = ""),
        "--abs",
        "LLVM_PROFILE_FILE",
        "--",
        info.exe,
        hidden = info.hidden,
    )
    ctx.actions.run(cmd, category = "rust_cov_test", identifier = ctx.label.name, env = info.env)
    return [
        DefaultInfo(default_output = marker, other_outputs = [profiles], sub_targets = {"bin": [DefaultInfo(default_output = info.exe)], "profiles": [DefaultInfo(default_output = profiles)]}),
        RustCovRunInfo(profiles = profiles, objects = [info.exe] + list(info.bins), marker = marker),
    ]

# The run of a test built with coverage counters: its marker (written only when the test passed, as `test_run`'s) and its profiles.
cov_run = rule(
    impl = _cov_impl,
    attrs = _ATTRS,
)
