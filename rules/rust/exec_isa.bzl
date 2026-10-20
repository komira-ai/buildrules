"""`exec_isa`: reports the ISA level of the execution platform it is configured for.

It is an `exec_dep` of `test_run`, so it is analysed in the configuration of the execution platform the run was placed on.
Only the execution platforms of platforms/exec carry an `exec_isa` constraint (platforms/BUCK), one per level.
"""

load(":providers.bzl", "ExecIsaInfo")

def _impl(ctx):
    return [DefaultInfo(), ExecIsaInfo(level = ctx.attrs.level)]

exec_isa = rule(impl = _impl, attrs = {"level": attrs.string()})
