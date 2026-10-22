"""`run_check`: runs an executable on the execution platform and compares its stdout exactly."""

def _impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".stdout")
    exe = ctx.attrs.exe[RunInfo]

    # `check expect` (rules/check): the executable's stdout, without its trailing newlines, is `expected_stdout`; then, and only then, `out` holds
    # it and a newline. Anything else (a different stdout, a non-zero exit) is status 1 and no `out`.
    ctx.actions.run(
        cmd_args(ctx.attrs._check_exe[RunInfo], "expect", "--name", "run_check", "--want", ctx.attrs.expected_stdout, "--out", out.as_output(), "--", exe),
        category = "run_check",
    )
    return [DefaultInfo(default_output = out)]

run_check = rule(
    impl = _impl,
    attrs = {
        "exe": attrs.dep(providers = [RunInfo]),
        "expected_stdout": attrs.string(),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
    },
)
