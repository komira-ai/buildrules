"""Stand-ins for the tools the runner rules start, and the rule that starts one of the C/C++ toolchain's refusals.

`stand_in_zig` is a directory holding `zig`, which is the stand-in compiler (stand_in.zig): a rule built against it is green only if it gave zig the command
line and the environment it is meant to. `refusal_run` starts a tool the toolchain does not provide (`toolchains//:cxx`'s `nm`, its internal tools, or
`toolchains//:python_bootstrap`'s interpreter) with arguments, as the prelude's actions do, so the action's failure is the refusal's.
"""

load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load("@prelude//python_bootstrap:python_bootstrap.bzl", "PythonBootstrapToolchainInfo")
load("//rules/core:platform.bzl", "LINUX_X86_64")

def _stand_in_zig_impl(ctx):
    return [DefaultInfo(default_output = ctx.actions.copied_dir(ctx.label.name, {"zig": ctx.attrs.exe[DefaultInfo].default_outputs[0]}))]

stand_in_zig = rule(
    impl = _stand_in_zig_impl,
    attrs = {"exe": attrs.exec_dep()},
)

def _tool(ctx, what):
    """The refusal of `what` in the toolchain: a RunInfo (or, for the Python interpreter, the command)."""
    if what == "python":
        return ctx.attrs._python[PythonBootstrapToolchainInfo].interpreter
    cxx = ctx.attrs._cxx[CxxToolchainInfo]
    prelude_tools = getattr(cxx, "internal_tools")
    if what.startswith("dist_lto "):
        member = getattr(prelude_tools.dist_lto, what[len("dist_lto "):])
        return member[cxx.linker_info.type] if type(member) == "dict" else member
    if what in ["nm", "objcopy", "strip"]:
        return getattr(cxx.binary_utilities_info, what)
    return getattr(prelude_tools, what)

def _refusal_run_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name)

    # The arguments are what the prelude appends to a tool (flags, then an output): they must be ignored by the refusal, whose message is the whole point.
    ctx.actions.run(
        cmd_args(_tool(ctx, ctx.attrs.tool), "-c", "--flag=value", "input.o", out.as_output()),
        category = "refusal_run",
    )
    return [DefaultInfo(default_output = out)]

_refusal_run = rule(
    impl = _refusal_run_impl,
    attrs = {
        "tool": attrs.string(),
        "_cxx": attrs.toolchain_dep(default = "toolchains//:cxx", providers = [CxxToolchainInfo]),
        "_python": attrs.toolchain_dep(default = "toolchains//:python_bootstrap", providers = [PythonBootstrapToolchainInfo]),
    },
)

def refusal_run(**kwargs):
    _refusal_run(exec_compatible_with = LINUX_X86_64, **kwargs)
