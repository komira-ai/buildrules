"""`test_run`: the run of a compiled test, a target of its own.

A rule instance has one execution platform. The compile of a test (any ISA) must stay on the ISA-agnostic platform, and the
RUN of a test built for x86-64-v3 must land on a worker that has v3. So the run is a separate target with its own
`exec_compatible_with` (rules/isa.bzl `test_exec_compatible_with()`), and it checks, while the build graph is analysed,
that the platform it was given reports at least the level the test was built for. A test at a level whose run target lost
`exec_compatible_with` fails here with the fix, instead of running on whatever worker is free and dying with SIGILL.
"""

load("//rules:isa.bzl", "isa_satisfies")
load(":providers.bzl", "ExecIsaInfo", "RustTestInfo", "TestUnitInfo")

def _impl(ctx):
    info = ctx.attrs.unit[TestUnitInfo]
    have = ctx.attrs._exec_isa[ExecIsaInfo].level
    want = ctx.attrs.required_isa
    if not isa_satisfies(have, want):
        fail(("{}: built for ISA {} but its execution platform reports ISA={}. A test at an ISA level must run on a platform " +
              "that has it: set exec_compatible_with = test_exec_compatible_with() (rules/isa.bzl), which the cargo_unit and rust_test " +
              "macros do, so the farm schedules the run on a worker of at least that level.").format(ctx.label, want, have))
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    check = ctx.attrs._check_exe[RunInfo]

    # `check marker` (rules/check): the marker is written only when the binary exited 0, and a failed run is the binary's output and its status.
    ctx.actions.run(
        cmd_args(check, "marker", "--out", marker.as_output(), info.marker, info.start, "--", info.exe, hidden = info.hidden),
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
            command = [cmd_args(check, "run", info.start, "--", info.exe, hidden = info.hidden)],
            env = info.env,
            labels = ["test"] + list(info.labels),
        ))
    return out

test_run = rule(
    impl = _impl,
    attrs = {
        "required_isa": attrs.string(default = ""),
        "unit": attrs.dep(providers = [TestUnitInfo]),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
        "_exec_isa": attrs.exec_dep(default = "buildrules//rules/rust:exec_isa", providers = [ExecIsaInfo]),
    },
)
