"""Stand-ins for a compiled Mojo library and for the run of one of its tests, so the gate (`mojo_gated_lib_rule`) is proven red and green without a compiler.

`gate_fixture_lib` provides `MojoLibInfo` over a file of known bytes. `gate_fixture_test` provides `MojoTestRunInfo`: like a real run
(rules/mojo/unit.bzl, `_RUN`) it writes its marker only after the test succeeded, and a test that fails exits non-zero with no marker.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/mojo:providers.bzl", "MojoLibInfo", "MojoTestRunInfo")

def _lib_impl(ctx):
    mojoc = ctx.actions.write(ctx.attrs.package + ".mojoc", "stand-in for a compiled library\n")
    return [
        DefaultInfo(default_output = mojoc),
        MojoLibInfo(id = ctx.label.name, mojoc = mojoc, closure = {ctx.attrs.package: mojoc}, ids = {ctx.attrs.package: ctx.label.name}),
    ]

_gate_fixture_lib = rule(impl = _lib_impl, attrs = {"package": attrs.string()})

def _test_impl(ctx):
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            "-c",
            'if [ "$1" = pass ]; then echo passed > "$2"; else echo "the planted failing test" >&2; exit 1; fi',
            "sh",
            "pass" if ctx.attrs.passes else "fail",
            marker.as_output(),
        ),
        category = "gate_fixture_test",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = marker), MojoTestRunInfo(marker = marker)]

_gate_fixture_test = rule(
    impl = _test_impl,
    attrs = {
        "busybox": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
        "passes": attrs.bool(),
    },
)

def gate_fixture_lib(**kwargs):
    _gate_fixture_lib(exec_compatible_with = LINUX_X86_64, **kwargs)

def gate_fixture_test(**kwargs):
    _gate_fixture_test(exec_compatible_with = LINUX_X86_64, **kwargs)
