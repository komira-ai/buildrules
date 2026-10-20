"""The compiler closure rule: the pinned `.conda` packages unpacked by `conda_unpack` (a newer copy than rules/zig's).

The wrapper (tools/mojo_compile.zig) refuses to run unless the closure's CLOSURE_MANIFEST lists
only non-empty files, and runs the compiler with an environment built from nothing. Nothing here knows a version or a hash:
toolchain.bzl passes the packages the unit graph names.
"""

def _closure_impl(ctx):
    tool = ctx.attrs.unpacker[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("compiler", dir = True)
    libs = []
    for member, package in sorted(ctx.attrs.libs.items()):
        libs.extend(["--lib", package[DefaultInfo].default_outputs[0], member])
    ctx.actions.run(
        cmd_args(tool, ctx.attrs.package[DefaultInfo].default_outputs[0], out.as_output(), libs),
        category = "conda_unpack",
    )
    return [DefaultInfo(default_output = out)]

# The compiler closure: bin/mojo, lib/, modular.cfg and CLOSURE_MANIFEST, plus the C++ runtime
# libraries (member under lib/ -> the pinned package it comes from).
mojo_closure_rule = rule(
    impl = _closure_impl,
    attrs = {
        "libs": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "package": attrs.dep(),
        "unpacker": attrs.exec_dep(),
    },
)
