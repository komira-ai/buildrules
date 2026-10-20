"""kcov built from source on the farm, the tools of a coverage build, and the rules around them (README.md).

`kcov_dist` runs kcov_build (tools/kcov_build.zig) in one build action: it unpacks the pinned kcov source archive and
conda packages, builds the embedded helper libraries and generated sources, and compiles and links kcov with the pinned zig. The output is a
directory: `bin/kcov`, `lib/libgcc_s.so.1` (the one library it loads besides glibc) and `share/licenses/`.

`cov_tool` is a tool of this family as other targets use it: the `zig_exe`'s outputs, with its cases (`zig_test` targets that run the
executable) as dependencies, so no build that uses the tool succeeds unless its cases pass. `cov_link` is the `--zig` directory of a
coverage build: `zig` (cov_zig), `debug_relocate`, and `real/`, the Mojo toolchain's own zig.
"""

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _dist_impl(ctx):
    # Sources are copied under buck-out first: a source's path in an action differs between a standalone checkout and a
    # repository that mounts buildrules as a cell, and so would the action's digest.
    staged = ctx.actions.copied_dir("build_srcs", {f.short_path: f for f in ctx.attrs.shim})
    out = ctx.actions.declare_output("kcov", dir = True)
    packages = [cmd_args(name, "=", _out(dep), delimiter = "") for name, dep in sorted(ctx.attrs.packages.items())]
    ctx.actions.run(
        cmd_args(
            ctx.attrs._build[RunInfo],
            _out(ctx.attrs._zig),
            _out(ctx.attrs.conda_payload),
            _out(ctx.attrs.elf_rpath),
            _out(ctx.attrs.archive),
            ctx.attrs.strip_prefix,
            ctx.attrs.version,
            ctx.attrs.zig_triple,
            staged.project("shim"),
            out.as_output(),
            packages,
        ),
        category = "kcov_build",
    )
    return [DefaultInfo(default_output = out)]

kcov_dist = rule(
    impl = _dist_impl,
    doc = "kcov built by kcov_build from `archive` (unpacked under `strip_prefix`) against the static libraries of the conda `packages`; the output is a directory holding `bin/kcov`, `lib/libgcc_s.so.1` and `share/licenses/`.",
    attrs = {
        "archive": attrs.dep(),
        "conda_payload": attrs.exec_dep(),
        "elf_rpath": attrs.exec_dep(),
        "packages": attrs.dict(attrs.string(), attrs.dep()),
        "shim": attrs.list(attrs.source()),
        "strip_prefix": attrs.string(),
        "version": attrs.string(),
        "zig_triple": attrs.string(),
        "_build": attrs.exec_dep(default = "buildrules//rules/coverage:kcov_build", providers = [RunInfo]),
        "_zig": attrs.exec_dep(default = "buildrules//rules/pins:zig"),
    },
)

def _tool_impl(ctx):
    exe = ctx.attrs.exe
    return [exe[DefaultInfo], exe[RunInfo]]

cov_tool = rule(
    impl = _tool_impl,
    doc = "The executable `exe` (configured for the execution platform), gated by the validations in `cases` and by the `zig_test` targets `exe` is built behind.",
    attrs = {
        "cases": attrs.list(attrs.dep(providers = [ValidationInfo]), default = []),
        "exe": attrs.exec_dep(providers = [RunInfo]),
    },
)

def _link_impl(ctx):
    out = ctx.actions.copied_dir("cov_link", {
        "debug_relocate": _out(ctx.attrs.relocate),
        "real": _out(ctx.attrs.zig),
        "zig": _out(ctx.attrs.cov_zig),
    })
    return [DefaultInfo(default_output = out)]

cov_link = rule(
    impl = _link_impl,
    doc = "The link directory of a coverage build: what mojo_compile takes as --zig=<dir>. It holds `zig` (cov_zig), `debug_relocate`, and `real/`, the toolchain's own zig, so a coverage link uses the zig a release link uses.",
    attrs = {
        "cov_zig": attrs.exec_dep(providers = [RunInfo], default = "buildrules//rules/coverage:cov_zig"),
        "relocate": attrs.exec_dep(providers = [RunInfo], default = "buildrules//rules/coverage:debug_relocate"),
        "zig": attrs.dep(),
    },
)
