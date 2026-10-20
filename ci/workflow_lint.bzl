"""`actionlint_check`: the pinned actionlint over workflow files, as a build action (no network, no host tool)."""

load("@buildrules//rules/zig:zig.bzl", "busybox_sh")

# $1 busybox, $2 the actionlint tarball, $3 the marker to write, then the workflow files.
_SCRIPT = """
BB="$1"; TAR="$2"; OUT="$3"; shift 3
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.buildrules_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/buildrules" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/buildrules" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/al"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
tar -xzf "$TAR" -C "$T/al" actionlint
# No shellcheck or pyflakes on PATH: actionlint then checks the workflow syntax, expressions, action inputs and contexts, not the shell.
"$T/al/actionlint" -no-color "$@"
echo "actionlint: $# workflow(s) clean" > "$OUT"
rm -rf "$T"
"""

def _impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        busybox_sh(
            bb,
            _SCRIPT,
            ctx.attrs.actionlint[DefaultInfo].default_outputs[0],
            out.as_output(),
            *ctx.attrs.workflows
        ),
        category = "actionlint",
    )
    return [DefaultInfo(default_output = out)]

actionlint_check = rule(
    impl = _impl,
    doc = "Green only if actionlint accepts every listed workflow file. The marker names how many.",
    attrs = {
        "actionlint": attrs.dep(),
        "busybox": attrs.dep(default = "buildrules//rules/pins:busybox"),
        "workflows": attrs.list(attrs.source()),
    },
)
