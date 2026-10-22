"""`mojo_same`: two library targets built from the same sources at two paths have the same `.mojoc` bytes.

A `.mojoc` that records the directory it was staged in is a different file for every package path, which breaks sharing through the
remote cache and makes a dependent's key depend on where its dependency lives. This target fails its build unless the two files are
byte for byte equal (`check same`, rules/check), so the property is a gate and not a measurement made once.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load(":providers.bzl", "MojoLibInfo")

def _impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".same")
    ctx.actions.run(
        cmd_args(ctx.attrs._check_exe[RunInfo], "same", "--out", out.as_output(), ctx.attrs.a[MojoLibInfo].mojoc, ctx.attrs.b[MojoLibInfo].mojoc),
        category = "mojo_same",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

_mojo_same = rule(
    impl = _impl,
    attrs = {
        "a": attrs.dep(providers = [MojoLibInfo]),
        "b": attrs.dep(providers = [MojoLibInfo]),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
    },
)

def mojo_same(**kwargs):
    _mojo_same(exec_compatible_with = LINUX_X86_64, **kwargs)
