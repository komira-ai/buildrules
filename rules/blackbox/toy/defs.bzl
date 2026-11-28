"""`toy_package`: the toy service (toy.zig) as a Debian package, built by the toy's own packer, for the blackbox tests of this repository: it has no released
service of its own to test, so its package is built in the same build (a `blackbox_test` takes a target label for that, defs.bzl)."""

def _impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".deb")
    ctx.actions.run(
        cmd_args(ctx.attrs._toy[RunInfo], "pack", "--out", out.as_output(), "--file", cmd_args(ctx.attrs.path, "=", ctx.attrs.program[RunInfo], delimiter = "")),
        category = "toy_package",
    )
    return [DefaultInfo(default_output = out)]

toy_package = rule(
    impl = _impl,
    attrs = {
        # The path of the program in the package.
        "path": attrs.string(),
        "program": attrs.dep(providers = [RunInfo]),
        "_toy": attrs.exec_dep(default = "buildrules//rules/blackbox/toy:toy", providers = [RunInfo]),
    },
)
