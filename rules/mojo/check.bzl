"""`:check` of a Mojo package: is the committed table still what its inputs say? (docs/contract.md, section 12)

`buildrules mojo sync` made the table (`buildrules.mojo.lock.bzl`: mopm's unit graph, verbatim) from files the graph does not hash itself
(`MANIFEST_SHA256`: mopm.toml, mopm.lock, mopm-toolchain.toml, the mopm.toml of every member) and copied the graph's toolchain section into
toolchains/mojo_pins.bzl. A change to any of them without a sync leaves a table that describes another build. Every step of the package
(`:lib`, `:test`, `:build`, `:coverage`, the binaries, `:ci`) carries this target as a validation, so such a build is red:

    the files     an action (rules/mojo/tools/files_check.zig) hashes each file and compares it with the table's value
    the graph     `:table`, a target of its own (in //ci:all for every example): an action (rules/mojo/tools/table_check.zig) runs the pinned mopm's
                  `plan --unit-graph --locked` over the package and its path dependencies (laid out flat at their repository paths) and requires the
                  table's graph to be that output, byte for byte (the order of units, natives and dependencies, every sha256 of the package's own
                  sources), so a table that was edited, or left behind by a change, is red. A path dependency is held by identity only (id, version,
                  root, dependencies, outputs): its sources and keys are proved by its own `:table`, so editing one does not turn this one red
    the pins      at analysis: the toolchain the package builds with (`toolchains//:mojo_<v>`, declared from mojo_pins.bzl) must hold exactly
                  the toolchain section of the table's graph (version, cc_target, closure hash, the zig, every component)

The fix is always `buildrules mojo sync`.
"""

load(":providers.bzl", "MojoToolchainInfo", "MojoWorkspaceInfo")

def _differs(have, want):
    keys = {}
    for k in have:
        keys[k] = True
    for k in want:
        keys[k] = True
    return [k for k in sorted(keys.keys()) if have.get(k) != want.get(k)]

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    who = str(ctx.label.raw_target())
    if tc.version != ctx.attrs.mojo:
        fail("{}: the table is for Mojo {} but {} is Mojo {}: run `buildrules mojo sync`".format(who, ctx.attrs.mojo, ctx.attrs.toolchain.label, tc.version))
    bad = _differs(tc.facts, ctx.attrs.expect_toolchain)
    if bad:
        fail(("{}: toolchains/mojo_pins.bzl and the table's unit graph disagree about the Mojo {} toolchain ({}): the pins file or the table was " +
              "edited without a sync. Run `buildrules mojo sync`").format(who, ctx.attrs.mojo, ", ".join(bad)))
    out = ctx.actions.declare_output("table_in_sync")
    args = cmd_args(ctx.attrs._tool[RunInfo], out.as_output())
    for h, f, n in zip(ctx.attrs.hashes, ctx.attrs.files, ctx.attrs.names):
        args.add(h, f[DefaultInfo].default_outputs[0], n)
    ctx.actions.run(args, category = "mojo_table_check", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

mojo_check_rule = rule(
    impl = _impl,
    doc = "Fails unless every file the table was made from hashes to what the table recorded and the toolchain the package builds with is the one the table's graph names.",
    attrs = {
        # The toolchain section of the table's graph, without its `mojo` key: what toolchains/mojo_pins.bzl must hold for this version.
        "expect_toolchain": attrs.dict(attrs.string(), attrs.any()),
        "files": attrs.list(attrs.dep()),
        "hashes": attrs.list(attrs.string()),
        "mojo": attrs.string(),
        "names": attrs.list(attrs.string()),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "_tool": attrs.exec_dep(default = "buildrules//rules/mojo:files_check", providers = [RunInfo]),
    },
)

def repo_path(package, short_path):
    """The path from the repository root of a file of a Buck2 package (`short_path` is relative to the package)."""
    return package + "/" + short_path if package else short_path

def workspace_tree(package, files, member_trees):
    """The workspace of a package, flat: `{repository path: file}`. `files` are the package's own, as `(short_path, file)` pairs, and `member_trees`
    the same maps of the workspaces of the path dependencies it imports. Every file is at the path the repository has it, whatever the nesting of
    the packages, so a dependency that is a sibling is laid out like one below the package; a file two workspaces both hold (a dependency two
    others import) is one entry."""
    tree = {}
    for short_path, f in files:
        tree[repo_path(package, short_path)] = f
    for member in member_trees:
        for path, f in member.items():
            if path not in tree:
                tree[path] = f
    return tree

def _workspace_impl(ctx):
    # The workspace as the repository has it, in one directory: this package's files and the files of each path dependency's own workspace, every one
    # at its path from the repository root. mopm reads mopm.toml, mopm.lock and every source of them.
    tree = workspace_tree(
        ctx.label.package,
        [(f.short_path, f) for f in ctx.attrs.files],
        [m[MojoWorkspaceInfo].files for m in ctx.attrs.members],
    )
    return [
        DefaultInfo(default_output = ctx.actions.copied_dir("workspace", tree)),
        MojoWorkspaceInfo(files = tree),
    ]

mojo_workspace_rule = rule(
    impl = _workspace_impl,
    doc = "The files of a Mojo package and of its path dependencies' workspaces, flat, at their paths from the repository root (the input of `:table`).",
    attrs = {
        "files": attrs.list(attrs.source()),
        # The `:workspace` of every path dependency the package's graph names (a dependency's own dependencies are in its workspace; one that two share is
        # one entry).
        "members": attrs.list(attrs.dep(providers = [MojoWorkspaceInfo]), default = []),
    },
)

def _table_impl(ctx):
    out = ctx.actions.declare_output("table_is_mopms")
    cmd = cmd_args(ctx.attrs._tool[RunInfo])
    if ctx.attrs.workspace_root:
        # The graph's paths start at the repository root: mopm is told where it is (the staged workspace) and the table was made that way.
        cmd.add("--workspace-root")
    cmd.add(
        ctx.attrs.mopm[RunInfo],
        ctx.attrs.workspace[DefaultInfo].default_outputs[0],
        ctx.attrs.package_dir or ".",
        ctx.attrs.mojo,
        ctx.attrs.table,
        out.as_output(),
    )
    ctx.actions.run(cmd, category = "mojo_table", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

mojo_table_rule = rule(
    impl = _table_impl,
    doc = "Fails unless the committed graph (buildrules.mojo.lock.bzl) is, byte for byte, what the pinned mopm's `plan --unit-graph --locked` prints for the package and its path dependencies now (they are held by identity only: graph_norm.zig).",
    attrs = {
        "mojo": attrs.string(),
        "mopm": attrs.exec_dep(providers = [RunInfo]),
        # The package's directory from the repository root: where mopm runs inside the staged workspace.
        "package_dir": attrs.string(default = ""),
        "table": attrs.source(),
        "workspace": attrs.dep(),
        # The table was made by a mopm given --workspace-root (`MOPM.workspace_root`).
        "workspace_root": attrs.bool(default = False),
        "_tool": attrs.exec_dep(default = "buildrules//rules/mojo:table_check", providers = [RunInfo]),
    },
)
