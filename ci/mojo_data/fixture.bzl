"""The stand-in test of ci/mojo_data: `MojoExeInfo` over a built program (the data probe), so `mojo_test_run_rule` can run it with staged data and variables
without a Mojo compiler (the toolchain stand-in is ci/faulty/fixture.bzl)."""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/mojo:providers.bzl", "MojoExeInfo")

def _impl(ctx):
    exe = ctx.attrs.program[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(default_output = exe),
        MojoExeInfo(id = ctx.label.name, dir = exe, exe = exe, name = "data_probe"),
    ]

_probe_test = rule(impl = _impl, attrs = {"program": attrs.exec_dep()})

def probe_test(**kwargs):
    """`name`, the compiled "test" that is `program`."""
    _probe_test(exec_compatible_with = LINUX_X86_64, **kwargs)
