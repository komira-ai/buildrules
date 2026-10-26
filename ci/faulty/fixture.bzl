"""Stand-ins for a compiled Mojo test and for the Mojo toolchain, so the run of a Mojo test (`mojo_test_run_rule`) can be proven red without a compiler.

`faulty_mojo_exe` provides `MojoExeInfo` over a program that exits non-zero when it is started without arguments (the `check` executable, rules/check,
which says its usage and exits 2). `faulty_mojo_toolchain` provides `MojoToolchainInfo` with that same file for the directories the run reads.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/mojo:providers.bzl", "MojoExeInfo", "MojoToolchainInfo")

def _exe_impl(ctx):
    exe = ctx.attrs._program[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(default_output = exe),
        MojoExeInfo(id = ctx.label.name, dir = exe, exe = exe, name = "check"),
    ]

_faulty_mojo_exe = rule(impl = _exe_impl, attrs = {
    "_program": attrs.exec_dep(default = "buildrules//rules/check:check"),
})

def _toolchain_impl(ctx):
    file = ctx.attrs._program[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(default_output = file),
        MojoToolchainInfo(version = "0", closure_sha256 = "", cc_target = "", facts = {}, compiler = file, zig = file),
    ]

_faulty_mojo_toolchain = rule(impl = _toolchain_impl, attrs = {
    "_program": attrs.exec_dep(default = "buildrules//rules/check:check"),
})

def faulty_mojo_exe(**kwargs):
    _faulty_mojo_exe(exec_compatible_with = LINUX_X86_64, **kwargs)

def faulty_mojo_toolchain(**kwargs):
    _faulty_mojo_toolchain(exec_compatible_with = LINUX_X86_64, **kwargs)
