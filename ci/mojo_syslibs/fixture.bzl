"""A dependent that runs its tests through other rules, as the label that adopts a package hands it the package's system libraries.

`exported_system_lib` reads `MojoSystemLibsInfo` (rules/mojo/providers.bzl) of a gated library (`:lib` of a package) and makes the `index`th directory it lists a
`MojoSystemLibInfo`, which `mojo_test_run_rule` takes as a system library: a run given these is run with what the adopting label would hand to a dependent's run. A
library that lists fewer directories gives an empty one, so the run is given a directory that holds nothing and the probe says which library it did not find.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/mojo:providers.bzl", "MojoSystemLibsInfo")
load("//rules/mojo:system_libs.bzl", "MojoSystemLibInfo")

def _impl(ctx):
    dirs = ctx.attrs.lib[MojoSystemLibsInfo].dirs
    if ctx.attrs.index < len(dirs):
        dir = dirs[ctx.attrs.index]
    else:
        dir = ctx.actions.copied_dir("empty", {})
    return [DefaultInfo(default_output = dir), MojoSystemLibInfo(name = ctx.label.name, dir = dir)]

_exported = rule(impl = _impl, attrs = {"index": attrs.int(), "lib": attrs.dep(providers = [MojoSystemLibsInfo])})

def exported_system_lib(**kwargs):
    _exported(exec_compatible_with = LINUX_X86_64, **kwargs)
