"""`run_check`: runs an executable on the execution platform and compares its stdout exactly."""

load("//rules/rust:providers.bzl", "RustToolchainInfo")

_SCRIPT = """set -eu
EXE="$1"; WANT="$2"; OUT="$3"
GOT=$("$EXE")
if [ "$GOT" != "$WANT" ]; then
    echo "run_check: expected '$WANT' but $EXE printed '$GOT'" >&2
    exit 1
fi
echo "$GOT" > "$OUT"
"""

def _impl(ctx):
    bb = ctx.attrs._toolchain[RustToolchainInfo].busybox
    out = ctx.actions.declare_output(ctx.label.name + ".stdout")
    exe = ctx.attrs.exe[RunInfo]
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _SCRIPT, "sh", exe, ctx.attrs.expected_stdout, out.as_output()),
        category = "run_check",
    )
    return [DefaultInfo(default_output = out)]

run_check = rule(
    impl = _impl,
    attrs = {
        "exe": attrs.dep(providers = [RunInfo]),
        "expected_stdout": attrs.string(),
        "_toolchain": attrs.exec_dep(default = "toolchains//:rust", providers = [RustToolchainInfo]),
    },
)
