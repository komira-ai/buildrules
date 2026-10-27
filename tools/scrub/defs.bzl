"""The files of one package, for `scrub_test` (tools/scrub/README.md).

Every package of the repository ends with `scrub_files()`: a target `:scrub_files` whose outputs are the package's own files (the files of
its subdirectories that have no BUCK file of their own), so that the scrub reads the whole tree and not only what some rule happens to name.
"""

def _files_impl(ctx):
    return [DefaultInfo(default_outputs = ctx.attrs.srcs)]

_files = rule(
    impl = _files_impl,
    doc = "The package's files, as the outputs of a target.",
    attrs = {"srcs": attrs.list(attrs.source())},
)

def scrub_files(extra = []):
    _files(
        name = "scrub_files",
        srcs = extra + native.glob(["**"], exclude = ["buck2", "buck-out/**", "**/__pycache__/**", "**/node_modules/**", ".buckconfig.local", "**/.buckconfig.local"]),
        visibility = ["PUBLIC"],
    )

def _scrub_impl(ctx):
    out = ctx.actions.declare_output("scrub_report.txt")
    args = cmd_args(ctx.attrs._tool[RunInfo], out.as_output())
    for r in ctx.attrs.require:
        args.add("--require", r)
    if len(ctx.attrs.packages) != len(ctx.attrs.prefixes):
        fail("scrub_test: packages and prefixes differ in length")
    for dep, prefix in zip(ctx.attrs.packages, ctx.attrs.prefixes):
        where = prefix + (dep.label.package + "/" if dep.label.package else "")
        for f in dep[DefaultInfo].default_outputs:
            args.add(where + f.short_path, f)
    ctx.actions.run(args, category = "scrub", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

scrub_rule = rule(
    impl = _scrub_impl,
    doc = "Fails when any file of any listed package holds what a public repository must not (tools/scrub/scrub.zig). The report is the output.",
    attrs = {
        "packages": attrs.list(attrs.dep()),
        "prefixes": attrs.list(attrs.string()),
        "require": attrs.list(attrs.string(), default = []),
        "_tool": attrs.exec_dep(default = "buildrules//tools/scrub:scrub_exe", providers = [RunInfo]),
    },
)

def scrub_test(name, packages, require = [], visibility = ["PUBLIC"]):
    """`packages`: labels of `:scrub_files` targets; a label in a cell other than the root cell names the directory the cell lives in."""
    scrub_rule(
        name = name,
        packages = packages,
        prefixes = ["examples/crates/" if p.startswith("crates//") else ("toolchains/" if p.startswith("toolchains//") else ("ci/rootcell/" if p.startswith("rootcell//") else "")) for p in packages],
        require = require,
        visibility = visibility,
    )
