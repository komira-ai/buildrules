"""`farm_probe_run`: the probe (main.zig) run as a build action, and, under `buck2 test`, as a test action (README.md)."""

def _impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    probe = ctx.attrs.probe[RunInfo]
    extra = []
    if ctx.attrs.egress:
        extra += ["--egress", ctx.attrs.egress]
    if ctx.attrs.run:
        extra += ["--run", ctx.attrs.run]

    # The build action: the report is its one output (and its stdout).
    ctx.actions.run(cmd_args(probe, "build", "--out", out.as_output(), extra), category = "farm_probe")
    return [
        DefaultInfo(default_output = out),
        # The test action: the same program, run by buck2's test runner, which shows a passing test's stdout.
        ExternalRunnerTestInfo(type = "custom", command = [cmd_args(probe, "test", extra)], labels = ["farm-probe"]),
    ]

farm_probe_run = rule(
    impl = _impl,
    attrs = {
        # `A.B.C.D:PORT`: the one outside address the probe tries a TCP connect to; empty: not tried.
        "egress": attrs.string(default = ""),
        "probe": attrs.exec_dep(providers = [RunInfo]),
        # Any text: a new value is a new command line, so the build action runs again instead of being a cache hit.
        "run": attrs.string(default = ""),
    },
)
