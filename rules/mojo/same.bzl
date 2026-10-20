"""`mojo_same`: two library targets built from the same sources at two paths have the same `.mojoc` bytes.

A `.mojoc` that records the directory it was staged in is a different file for every package path, which breaks sharing through the
remote cache and makes a dependent's key depend on where its dependency lives. This target fails its build unless the two files are
byte for byte equal (`cmp` of the pinned busybox), so the property is a gate and not a measurement made once.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load(":providers.bzl", "MojoLibInfo")

def _impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".same")
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", 'cmp "$1" "$2" && echo same > "$3"', "sh", ctx.attrs.a[MojoLibInfo].mojoc, ctx.attrs.b[MojoLibInfo].mojoc, out.as_output()),
        category = "mojo_same",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

_mojo_same = rule(
    impl = _impl,
    attrs = {
        "a": attrs.dep(providers = [MojoLibInfo]),
        "b": attrs.dep(providers = [MojoLibInfo]),
        "busybox": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
    },
)

def mojo_same(**kwargs):
    _mojo_same(exec_compatible_with = LINUX_X86_64, **kwargs)
