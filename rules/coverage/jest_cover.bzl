"""The floor a Node package's jest coverage is held to (README.md, "Jest coverage").

`jest_coverage_floor(name, coverage = ":test")` takes the target of a `jest_test(coverage = True)` (the `coverage` directory of the run) and holds the
lines and branches in its `coverage-summary.json` to the package's `coverage_floor.txt` (tools/cov_floor.zig): a fall below the floor fails; at or above it passes, and above it
the check says the floor may be raised.
"""

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")

def _impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    summary = cmd_args(ctx.attrs.coverage[DefaultInfo].default_outputs[0], "/coverage-summary.json", delimiter = "")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "--jest-summary",
            summary,
            "--floor",
            ctx.attrs.floor,
            "--label",
            ctx.label.package,
            "--out",
            out.as_output(),
        ),
        category = "jest_cov_floor",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

_jest_coverage_floor = rule(
    impl = _impl,
    doc = "Green only if the lines and branches of the jest run `coverage` are the floor in `floor`: lower fails, and so does higher until the floor is raised to it.",
    attrs = {
        "coverage": attrs.dep(),
        "floor": attrs.source(),
        "_tool": attrs.exec_dep(default = "buildrules//rules/coverage:cov_floor", providers = [RunInfo]),
    },
)

def jest_coverage_floor(name = "coverage_floor", coverage = ":test", floor = "coverage_floor.txt", **kwargs):
    _jest_coverage_floor(
        name = name,
        coverage = coverage,
        floor = floor,
        exec_compatible_with = LINUX_X86_64,
        visibility = ["//ci:"],
        **kwargs
    )
