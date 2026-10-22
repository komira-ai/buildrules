"""Stand-ins for a compiled Mojo library and for the run of one of its tests, so the gate (`mojo_gated_lib_rule`) is proven red and green without a compiler.

`gate_fixture_lib` provides `MojoLibInfo` over a file of known bytes. `gate_fixture_test` provides `MojoTestRunInfo`: like a real run
(rules/mojo/unit.bzl) it is a `check marker` action, which writes its marker only after the test succeeded; a test that fails exits non-zero with
no marker. The test is the toolbox's `true` or `false` (rules/toolbox).
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/mojo:providers.bzl", "MojoLibInfo", "MojoTestRunInfo")

def _lib_impl(ctx):
    mojoc = ctx.actions.write(ctx.attrs.package + ".mojoc", ctx.attrs.text)
    return [
        DefaultInfo(default_output = mojoc),
        MojoLibInfo(id = ctx.label.name, mojoc = mojoc, closure = {ctx.attrs.package: mojoc}, ids = {ctx.attrs.package: ctx.label.name}),
    ]

_gate_fixture_lib = rule(impl = _lib_impl, attrs = {
    "package": attrs.string(),
    "text": attrs.string(default = "stand-in for a compiled library\n"),
})

def _test_impl(ctx):
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._check_exe[RunInfo],
            "marker",
            "--out",
            marker.as_output(),
            "--",
            ctx.attrs._toolbox[RunInfo],
            "true" if ctx.attrs.passes else "false",
        ),
        category = "gate_fixture_test",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = marker), MojoTestRunInfo(marker = marker)]

_gate_fixture_test = rule(
    impl = _test_impl,
    attrs = {
        "passes": attrs.bool(),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
        "_toolbox": attrs.exec_dep(default = "buildrules//rules/toolbox:toolbox", providers = [RunInfo]),
    },
)

def gate_fixture_lib(**kwargs):
    _gate_fixture_lib(exec_compatible_with = LINUX_X86_64, **kwargs)

def gate_fixture_test(**kwargs):
    _gate_fixture_test(exec_compatible_with = LINUX_X86_64, **kwargs)
