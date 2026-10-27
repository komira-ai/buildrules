"""The committed unit graphs against the sources they list, as a build action (ci/lock_hashes_check.zig)."""

load("@buildrules//ci:no_shell.bzl", "CELL_DIR")

def _impl(ctx):
    out = ctx.actions.declare_output("lock_hashes_report.txt")
    args = cmd_args(ctx.attrs._tool[RunInfo], out.as_output())
    for r in ctx.attrs.require:
        args.add("--require", r)
    for dep in ctx.attrs.packages:
        where = CELL_DIR[dep.label.cell] + (dep.label.package + "/" if dep.label.package else "")
        for f in dep[DefaultInfo].default_outputs:
            args.add(where + f.short_path, f)
    ctx.actions.run(args, category = "lock_hashes")
    return [DefaultInfo(default_output = out)]

lock_hashes = rule(
    impl = _impl,
    doc = "Fails when a `buildrules.mojo.lock.bzl` declares a sha256 that is not its source file's, or lists a file that is not there. The report is the output.",
    attrs = {
        "packages": attrs.list(attrs.dep()),
        "require": attrs.list(attrs.string(), default = []),
        "_tool": attrs.exec_dep(default = "buildrules//ci:lock_hashes_exe", providers = [RunInfo]),
    },
)
