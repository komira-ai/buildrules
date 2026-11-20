"""`postgres_prefix`: the pinned Postgres of the Rust test fixture as one unpacked tree (README.md).

Every package of `POSTGRES_PACKAGES` (pins.bzl) is a `pinned_file`; one `pg_prefix` action unpacks them all into one directory, the layout conda
would install (bin/, lib/, share/), less what a server never reads (headers, static archives, manuals). The tree also holds
`buildrules-placeholder.txt`: the prefix conda-forge compiled into the server, which `pg_run` replaces in its private copy of the binaries.
"""

def _prefix_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    cmd = cmd_args(ctx.attrs._pg_prefix[RunInfo], "--out", out.as_output(), "--postgres", ctx.attrs.postgres[DefaultInfo].default_outputs[0])
    for p in ctx.attrs.packages:
        cmd.add(p[DefaultInfo].default_outputs[0])
    ctx.actions.run(cmd, category = "postgres_prefix", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

postgres_prefix = rule(
    impl = _prefix_impl,
    attrs = {
        # The other packages of the closure, in any order (a path two of them hold must be the same bytes).
        "packages": attrs.list(attrs.dep()),
        # The `postgresql` package itself: its info/paths.json names the placeholder of bin/postgres and bin/initdb.
        "postgres": attrs.dep(),
        "_pg_prefix": attrs.exec_dep(default = "buildrules//rules/postgres:pg_prefix", providers = [RunInfo]),
    },
)
